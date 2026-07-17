require "aws-sdk-s3"

# A stateful, hermetic S3 for the suite: real Aws::S3::Client, real request/response
# serialization, real error classes -- backed by a Hash instead of a network.
#
# stub_responses accepts a lambda (verified), so this is the SDK doing its own marshalling
# rather than a double that would happily accept a call signature the real client rejects.
# No network, no credentials, no SeaweedFS in CI.
#
# VERIFIED, because the whole error half of the adapter's suite rests on it: a lambda that
# RETURNS A STRING makes the SDK raise the error of that name -- `"NoSuchKey"` really does
# raise Aws::S3::Errors::NoSuchKey, `"AccessDenied"` really does raise
# Aws::S3::Errors::AccessDenied. Had that not been true the fake would have been inert and
# every terminal-vs-transient test would have passed vacuously. Note the raised error's
# `message` is the SDK's own "stubbed-response-error-message" and NOT the name -- so an
# assertion that wants to see WHICH failure must read the error CLASS, which is why the
# adapter puts `e.class` in its FetchError message.
#
# It models ONLY what the adapter uses. A method the adapter calls but this does not stub
# raises from the SDK -- which is the correct, loud outcome: extend the fake deliberately.
class FakeS3
  Obj = Struct.new(:body, :last_modified, :etag, :checksum_sha256, :checksum_type)

  attr_reader :objects, :calls

  def initialize
    @objects = {}
    @calls = Hash.new(0)
    @faults = {}
  end

  # Force an operation to fail. `error` is an SDK error name ("NoSuchKey", "AccessDenied",
  # "InternalError") or an exception instance -- the transient/terminal split is what the
  # contract's most consequential test turns on.
  def fault!(operation, error) = @faults[operation] = error
  def clear_faults! = @faults.clear

  def client
    @client ||= Aws::S3::Client.new(
      stub_responses: true, region: "us-east-1",
      access_key_id: "ak", secret_access_key: "sk"
    ).tap { |c| stub_all(c) }
  end

  # Seed an object as if some other tool had put it there -- which is the whole premise of
  # this backend: the bucket already has the user's files in it.
  def seed!(key, body, last_modified: Time.at(1_700_000_000), checksum_sha256: nil, checksum_type: nil)
    # The ETag is QUOTED, and those two literal quotes are the point rather than a typo: S3 wraps
    # every ETag in them, in list, head AND put responses (Landmine 2). A fake that handed back a
    # bare hex string would let the adapter skip normalization and stay green, then unpair every
    # move in production. FileLayer::S3::ObjectIdentity is the one place they come off.
    @objects[key] = Obj.new(body.b, last_modified, %Q("#{Digest::MD5.hexdigest(body)}"),
                            checksum_sha256, checksum_type)
  end

  private

  def stub_all(c)
    c.stub_responses(:put_object, ->(ctx) { guard(:put_object) || do_put(ctx) })
    c.stub_responses(:get_object, ->(ctx) { guard(:get_object) || do_get(ctx) })
    c.stub_responses(:head_object, ->(ctx) { guard(:head_object) || do_head(ctx) })
    c.stub_responses(:delete_object, ->(ctx) { guard(:delete_object) || do_delete(ctx) })
    c.stub_responses(:copy_object, ->(ctx) { guard(:copy_object) || do_copy(ctx) })
    c.stub_responses(:list_objects_v2, ->(ctx) { guard(:list_objects_v2) || do_list(ctx) })
  end

  def guard(op)
    @calls[op] += 1
    @faults[op]
  end

  def do_put(ctx)
    body = ctx.params[:body]
    body = body.read if body.respond_to?(:read)
    seed!(ctx.params[:key], body.b, last_modified: Time.now)
    { etag: @objects[ctx.params[:key]].etag }
  end

  def do_get(ctx)
    o = @objects[ctx.params[:key]] or return "NoSuchKey"
    { body: o.body, content_length: o.body.bytesize, etag: o.etag, last_modified: o.last_modified }
  end

  def do_head(ctx)
    o = @objects[ctx.params[:key]] or return "NotFound"
    { content_length: o.body.bytesize, etag: o.etag, last_modified: o.last_modified,
      checksum_sha256: o.checksum_sha256, checksum_type: o.checksum_type }
  end

  def do_delete(ctx)
    @objects.delete(ctx.params[:key])
    {}
  end

  def do_copy(ctx)
    src = ctx.params[:copy_source].to_s.split("/", 2).last
    src = CGI.unescape(src)
    o = @objects[src] or return "NoSuchKey"
    # copy_source_if_match is the conditional that makes the trash copy safe against a
    # concurrent overwrite. Honor it, or the test that pins it would pass vacuously.
    if (want = ctx.params[:copy_source_if_match]) && want != o.etag
      return "PreconditionFailed"
    end
    @objects[ctx.params[:key]] = o.dup
    { copy_object_result: { etag: o.etag } }
  end

  # Pagination is REAL here, at 2 keys a page: a fake that returns everything in one page
  # cannot exercise the partial-listing landmine, which is the whole risk of the observer.
  # (A real list_objects_v2 defaults to 1000. Two is deliberately hostile -- the adapter must
  # never depend on a page size, and Task 7's observer must page.)
  def do_list(ctx)
    prefix = ctx.params[:prefix].to_s
    keys = @objects.keys.select { |k| k.start_with?(prefix) }.sort
    page = Integer(ctx.params[:continuation_token] || 0)
    per = ctx.params[:max_keys] || 2
    slice = keys[page, per] || []
    { contents: slice.map { |k|
        o = @objects[k]
        { key: k, size: o.body.bytesize, etag: o.etag, last_modified: o.last_modified,
          checksum_algorithm: (o.checksum_sha256 ? [ "SHA256" ] : nil),
          checksum_type: o.checksum_type }
      },
      is_truncated: (page + per) < keys.size,
      next_continuation_token: ((page + per) < keys.size ? (page + per).to_s : nil) }
  end
end
