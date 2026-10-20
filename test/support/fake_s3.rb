require "aws-sdk-s3"
# Explicit, because #do_copy's URI::DEFAULT_PARSER is the one thing in this file that must not
# quietly depend on someone else having required it — see the decoder note there.
require "uri"

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

  # What a store can put on the wire for "no ETag": the field absent, present and empty, or S3's
  # quotes around nothing — or around whitespace, which the ONE unquoting leaves just as blank. Only
  # the first two fail the `present?` test the adapter's refresh sites used, and the last also got
  # past the ladder's own `empty?`, minting `etag: ` — one identity shared by every such object.
  BLANK_ETAGS = { "absent" => nil, "empty" => "", "quoted-empty" => '""',
                  "quoted-whitespace" => '" "' }.freeze

  # The four responses the adapter derives an identity from; `answer_etag!` refuses any other.
  ETAG_ANSWERS = %i[put_object head_object copy_object list_objects_v2].freeze
  # The two whose Last-Modified the adapter stores over a value it already holds — #restored_stat's
  # HEAD and #move's copy result; `answer_last_modified!` refuses any other. (A PUT's response has
  # no such field at all, which is why #write HEADs; a listing's is the observer's, not in scope.)
  LAST_MODIFIED_ANSWERS = %i[head_object copy_object].freeze

  def initialize
    @objects = {}
    @calls = Hash.new(0)
    @faults = {}
    @faults_after = {}
    @answers = {}
  end

  # Force an operation to fail. `error` is an SDK error name ("NoSuchKey", "AccessDenied",
  # "InternalError") or an exception instance -- the transient/terminal split is what the
  # contract's most consequential test turns on.
  def fault!(operation, error) = @faults[operation] = error

  # Force an operation to fail only AFTER it has succeeded `calls` times -- i.e. MID-PAGINATION.
  #
  # THIS EXISTS BECAUSE `fault!` CANNOT TEST LANDMINE 4, and the distinction is the landmine.
  # Faulting every call makes page 1 fail, which yields ZERO observations -- and zero observations
  # trips the Reconciler's mass-deletion guard all on its own. So a test built on `fault!` passes
  # whether or not the observer aborts: remove the abort entirely and the guard raises the same
  # UnsafeScan, from a different place, for a different reason. A test that cannot fail.
  #
  # The real shape is a listing that dies on page 19 of 20: most of the library IS observed, the
  # missing share lands UNDER the threshold, and the guard waves it through while the observer's
  # abort is the only thing standing between the user and a silent tombstoning. That needs a fault
  # that arrives partway, which needs this.
  #
  # `calls` counts from NOW, not from the fake's birth -- the baseline is folded in here. A test
  # that scans once to seed and then scans again to break has already spent a dozen list calls by
  # the time it says "fail after 9 more", and reading the counter absolutely would fault instantly
  # on the second scan's FIRST page: back to a page-1 failure, i.e. back to the vacuous test this
  # method exists to escape, silently.
  def fault_after!(operation, calls, error)
    @faults_after[operation] = [ @calls[operation] + calls, error ]
  end

  # Make EVERY response of `operation`, for every key, ANSWER `value` for one field on the wire in
  # place of the object's own — nil included, which is the field absent — until clear_faults!. It
  # models a store that always answers that operation this way, not one bad response, so a test
  # whose setup HEADs or copies after setting it gets the same answer there too. THE OBJECTS KEEP
  # THEIR REAL VALUES, and that is the honest half: what is modelled is one operation answering
  # unhelpfully (the audit's shape — a blank ETag on a COPY or HEAD, real ones on LIST; a HEAD with
  # no Last-Modified), not a store whose objects lack them. So every OTHER operation still reports
  # the truth unless it, too, is told otherwise, and every other field stays real.
  def answer_etag!(operation, etag) = answer!(operation, :etag, etag, ETAG_ANSWERS)

  def answer_last_modified!(operation, time)
    answer!(operation, :last_modified, time, LAST_MODIFIED_ANSWERS)
  end

  def clear_faults!
    @faults.clear
    @faults_after.clear
    @answers.clear
  end

  def client
    @client ||= Aws::S3::Client.new(
      stub_responses: true, region: "us-east-1",
      access_key_id: "ak", secret_access_key: "sk"
    ).tap { |c| stub_all(c) }
  end

  # Seed an object as if some other tool had put it there -- which is the whole premise of
  # this backend: the bucket already has the user's files in it.
  #
  # `checksum_sha256`/`checksum_type` HAVE NO CALLER as of Task 7, and that is a finding rather
  # than rot. They model the real API faithfully (head_object returns the checksum VALUE;
  # list_objects_v2 returns only the ALGORITHM -- see do_head/do_list), and the ladder's rung 1
  # needs the value. But the value is reachable only via a HEAD per object, which is
  # LIBRARY_S3_HEAD_FOR_CHECKSUM and is not implemented, so NO production path mints a `sha256:`
  # identity today: Library::S3Observer lists (no checksum) and FileLayer::S3#write reads
  # put_object's ETag. s3_test.rb used to pass these to its create_file! and thereby implied a scan
  # could yield `sha256:`; replacing that fixture with the real observer is what proved it could
  # not. Kept because they are the correct shape for whoever implements that rung -- not because
  # anything asserts on them.
  # `etag:` overrides the derived one, and models the object a real bucket is full of: anything
  # uploaded MULTIPART carries "<hex>-<parts>", which is an md5-of-md5s and not the content's md5
  # at all. Default is the single-part truth (the ETag IS the md5), so only a test that means to
  # exercise rung 3 has to say so.
  def seed!(key, body, last_modified: Time.at(1_700_000_000), etag: nil, checksum_sha256: nil,
            checksum_type: nil)
    # The ETag is QUOTED, and those two literal quotes are the point rather than a typo: S3 wraps
    # every ETag in them, in list, head AND put responses (Landmine 2). A fake that handed back a
    # bare hex string would let the adapter skip normalization and stay green, then unpair every
    # move in production. FileLayer::S3::ObjectIdentity is the one place they come off. An
    # overridden etag is quoted here too, for the same reason and by the same rule.
    @objects[key] = Obj.new(body.b, last_modified, %Q("#{etag || Digest::MD5.hexdigest(body)}"),
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
    return @faults[op] if @faults[op]

    # `@calls[op]` was just incremented, so `> after` makes call number after+1 the first to fail:
    # fault_after!(:list_objects_v2, 9, ...) lets nine pages through and kills the tenth.
    after, error = @faults_after[op]
    error if after && @calls[op] > after
  end

  def answer!(operation, field, value, allowed)
    raise ArgumentError, "#{operation} carries no #{field} the adapter reads" unless allowed.include?(operation)

    @answers[[ operation, field ]] = value
  end

  # `fetch`, not `[]`: an answer of nil (the field absent) must win over the object's own value.
  def wire(op, field, real) = @answers.fetch([ op, field ], real)

  def do_put(ctx)
    body = ctx.params[:body]
    body = body.read if body.respond_to?(:read)
    seed!(ctx.params[:key], body.b, last_modified: Time.now)
    { etag: wire(:put_object, :etag, @objects[ctx.params[:key]].etag) }
  end

  def do_get(ctx)
    o = @objects[ctx.params[:key]] or return "NoSuchKey"
    { body: o.body, content_length: o.body.bytesize, etag: o.etag, last_modified: o.last_modified }
  end

  def do_head(ctx)
    o = @objects[ctx.params[:key]] or return "NotFound"
    { content_length: o.body.bytesize, etag: wire(:head_object, :etag, o.etag),
      last_modified: wire(:head_object, :last_modified, o.last_modified),
      checksum_sha256: o.checksum_sha256, checksum_type: o.checksum_type }
  end

  def do_delete(ctx)
    @objects.delete(ctx.params[:key])
    {}
  end

  def do_copy(ctx)
    src = ctx.params[:copy_source].to_s.split("/", 2).last
    # PERCENT-DECODING, NOT FORM-DECODING, and the difference is the bug this fake already hid
    # once. `x-amz-copy-source` is decoded per RFC 3986, where "+" is a LITERAL PLUS; CGI.unescape
    # is form decoding (application/x-www-form-urlencoded), where "+" means SPACE.
    #
    # CGI.unescape here made this fake THE EXACT INVERSE OF THE ADAPTER'S OLD BUG: the adapter
    # encoded with CGI.escape ("Bracket Mount.stl" -> "Bracket+Mount.stl"), this decoded it back
    # to a space, the object was found, and 79/80 tests were green while every real store missed
    # the key. A fake whose decoder is the inverse of the WRONG encoder cannot fail on the one
    # thing it most needs to catch.
    #
    # VERIFIED AGAINST A REAL STORE (SeaweedFS 4.39, 2026-07-17), not reasoned: copy_source
    # "<bucket>/plus/Bracket+Mount.stl" against a bucket holding "plus/Bracket Mount.stl" is
    # REFUSED (Aws::S3::Errors::InvalidArgument) — the store does not read "+" as a space. This
    # parser reproduces that: URI::DEFAULT_PARSER.unescape("Bracket+Mount.stl") is unchanged,
    # while "%20" decodes to a space and "%C3%96" to "Ö", exactly as the store does.
    #
    # The adapter's per-segment ERB::Util.url_encode round-trips through this for every name
    # tried on the real store (space, "+", "%", unicode, "&", "#", "?"). The wire-level assertion
    # in s3_test.rb ("the copy source is URL-encoded the way REAL S3 decodes it") remains the
    # primary guard; this makes the fake agree with the store rather than quietly forgive it.
    src = URI::DEFAULT_PARSER.unescape(src)
    o = @objects[src] or return "NoSuchKey"
    # copy_source_if_match is the conditional that makes the trash copy safe against a
    # concurrent overwrite. Honor it, or the test that pins it would pass vacuously.
    if (want = ctx.params[:copy_source_if_match]) && want != o.etag
      return "PreconditionFailed"
    end
    # A COPY IS A NEW OBJECT, so it gets a NEW Last-Modified -- real S3, and every store this
    # backend points at (SeaweedFS/MinIO/R2/Ceph). Carrying the source's timestamp forward is not a
    # harmless simplification: `delete` is copy-to-.trash-then-delete-original and
    # TrashPurgeJob#purge_s3! ages an entry on the TRASH OBJECT's last_modified -- which on a real
    # store IS the delete time. Inherit it and a two-year-old file deleted today is born aged, and a
    # 30-day window purges it the same day, inside the window the operator configured, with no
    # version to restore. The bytes are the ETag's; the timestamp is the copy's.
    #
    # AND THE RESPONSE CARRIES THAT DATE, as the real wire does: aws-sdk-s3's CopyObjectResult has
    # `last_modified`, mapped from <LastModified> (types.rb, client_api.rb). This fake once left it
    # out, and FileLayer::S3#move's comment then cited the fake to argue copy_object reports no
    # date and declined to store it: §14e's fake that shares the code's misunderstanding.
    #
    # AND A COPY MINTS ITS OWN ETAG FROM ITS OWN BYTES, which is the SAME LESSON one field over
    # and was left inherited when last_modified was fixed. `seed!`/`do_put` derive the ETag as the
    # md5 of the body; only `do_copy` inherited it -- two contradictory rules for one field, and
    # the inherited one happened to be the adapter's own unstated assumption, so neither the bug
    # nor its fix was observable (`FileLayer::S3#move` leaving `content_hash` stale read exactly
    # like fixing it). That is the CGI.escape shape again, on the third of these five fields.
    # Real S3 re-tags a copy whenever the source ETag is not md5(bytes) -- multipart-origin and
    # SSE-KMS objects, which is precisely the population this backend exists to serve. A seeded
    # `etag:` override models such a source; it must NOT survive the copy, because on a real store
    # it does not.
    #
    # `checksum_sha256`/`checksum_type` are STILL inherited, deliberately and not by oversight: no
    # production path mints a `sha256:` identity today (LIBRARY_S3_HEAD_FOR_CHECKSUM is not
    # implemented — see seed!'s note above), and no seed! call in the suite passes either field, so
    # changing them here would be unobservable in both directions. Two fields re-derived, two
    # inherited on an argument, and this comment is the argument.
    copy = o.dup.tap do |c|
      c.last_modified = Time.now
      c.etag = %Q("#{Digest::MD5.hexdigest(o.body)}")
    end
    @objects[ctx.params[:key]] = copy
    { copy_object_result: { etag: wire(:copy_object, :etag, copy.etag),
                            last_modified: wire(:copy_object, :last_modified, copy.last_modified) } }
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
        { key: k, size: o.body.bytesize, etag: wire(:list_objects_v2, :etag, o.etag),
          last_modified: o.last_modified,
          checksum_algorithm: (o.checksum_sha256 ? [ "SHA256" ] : nil),
          checksum_type: o.checksum_type }
      },
      is_truncated: (page + per) < keys.size,
      next_continuation_token: ((page + per) < keys.size ? (page + per).to_s : nil) }
  end
end
