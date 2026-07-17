module FileLayer
  # The user's own S3-compatible bucket as a library: no chunks and no versions -- the object
  # IS the truth (spec decision 3, the same trade as Share). Phase 3.
  #
  # THIS FILE IS THE NAMESPACE, and it has to exist for that reason alone before it has any
  # behavior. Zeitwerk builds an implicit namespace from a DIRECTORY as a *module*, so with
  # `app/services/file_layer/s3/` present and no `s3.rb`, `FileLayer::S3` resolves to a module
  # and every `class S3` reopening it -- in object_identity.rb and in the tests -- dies with
  # "S3 is not a class (TypeError)". Verified, not reasoned: that is the exact error.
  #
  # So the ladder's namespace cannot be declared by the ladder's own file. This file must remain
  # `class S3`, not `module S3`, for that reason — see the ladder in s3/object_identity.rb.
  class S3
    # Mirrors Storage::S3ChunkStore.from_env's SHAPE, deliberately without touching or subclassing
    # it: that class is the SYNC engine's chunk store, keyed by CHUNK_*, and a library pointed at
    # the user's own bucket is a different deployment concern that must be configurable
    # independently. Same shape so an operator who has configured one can configure the other.
    #
    # The knobs are validated by LibraryBackendCheck.check! BEFORE this runs (FileLayer.build calls
    # it), which is what makes these fetches' bare KeyError unreachable in practice — the guard
    # names every missing knob at once instead of one per restart.
    def self.from_env(env = ENV)
      new(
        bucket:            env.fetch("LIBRARY_S3_BUCKET"),
        region:            env.fetch("LIBRARY_S3_REGION", "auto"),
        access_key_id:     env.fetch("LIBRARY_S3_ACCESS_KEY_ID"),
        secret_access_key: env.fetch("LIBRARY_S3_SECRET_ACCESS_KEY"),
        endpoint:          env["LIBRARY_S3_ENDPOINT"],
        prefix:            env["LIBRARY_S3_PREFIX"]
      )
    end

    attr_reader :bucket, :prefix, :client

    # `client:` is the TEST SEAM: injecting a stubbed Aws::S3::Client is what lets the adapter's
    # suite run hermetically, with no network and no credentials. Defaulted from the other args so
    # production never passes it.
    #
    # NOTHING HERE MAY TOUCH THE NETWORK. The factory runs this at boot, so a construct-time
    # round-trip would put a third party's uptime in our boot path — the same rule the boot guard
    # keeps, and it would be pointless to hold there and break here. Verified against the real
    # SDK: Aws::S3::Client.new with a closed-port endpoint constructs without connecting (it is
    # lazy), and presigning is local HMAC.
    def initialize(bucket:, region:, access_key_id:, secret_access_key:, endpoint: nil,
                   prefix: nil, client: nil)
      @bucket = bucket
      # Normalized HERE, once, because it is a CONFIG concern: "models/" and "models" are the same
      # intent typed two ways, and letting both through means every key-composing caller (Task 4
      # onward) either strips it again or silently addresses a different prefix than its neighbour.
      # Blank ("" or unset) means the whole bucket, which is a legitimate choice, not a mistake.
      @prefix = prefix.presence&.sub(%r{/+\z}, "").presence
      @client = client || build_client(region:, access_key_id:, secret_access_key:, endpoint:)
    end

    # THE ONE BACKEND WHERE presignable IS TRUE AND versioned IS FALSE — and that combination is
    # the point of this adapter, not an oversight.
    #
    # Every other backend has the two agreeing (chunk: true/true; share: false/false), so a reader
    # could reasonably infer they co-vary and collapse one into the other. S3 is the counterexample
    # that forbids it. They answer unrelated questions:
    #
    #   versioned?   -> can we hand back OLD bytes? NO. The object IS the truth; the user's own
    #                   overwrite in the AWS console destroys what was there (spec decision 3), so
    #                   CLAUDE.md §5's "keep versions so restore always works" does NOT survive
    #                   here. Restore stays a chunk-mode feature.
    #   presignable? -> can we hand back a URL instead of proxying the bytes through Rails? YES.
    #                   A bucket has a URL signer, which is exactly what a mounted directory lacks
    #                   (hence Share's false). So §15's "keep bytes out of Rails" DOES survive
    #                   here — and it survives precisely where it was aimed, at managed/WAN egress.
    #                   Phase 4's Redirect is built on this being true.
    #
    # syncable? is false: this is the web-over-your-own-storage product, with no sync engine, no
    # changelog and no devices (§10 tripwire).
    def capabilities
      Capabilities.new(versioned: false, syncable: false, presignable: true)
    end

    # Mirrors Share#stat exactly: answered from the NODE, never from the bucket. A stat is what
    # a browse view calls per row, so asking S3 would put a billed round-trip behind every file
    # in a listing. The node carries everything the port promises, because the observer put it
    # there — and `mtime` is already unix NANOSECONDS by the time it lands in the column
    # (FileInfo's contract: adapters CONVERT, they do not pass a Time through; the observer is
    # where an S3 last_modified, which is a second-granularity Time, becomes nanos).
    def stat(user, node_id:)
      node = live_node!(user, node_id)
      FileInfo.new(
        node_id: node.node_id,
        name: node.name,
        kind: node.kind,
        size: node.size.to_i,
        mtime: node.mtime,
        content_token: node.content_hash
      )
    end

    # The SERVER-SIDE read: preview jobs and the like, which genuinely need the bytes here.
    # It is NOT the download path — S3 is presignable (see #capabilities), so Phase 4's Delivery
    # hands the user a signed URL and the bytes never touch Rails (§15). Chunk mode draws the
    # same line between its `read` and its presigned download.
    def read(user, node_id:, content_token: nil)
      node = live_node!(user, node_id)

      # S3 mode keeps no history (the object IS the truth), so a token that is not the current
      # content is simply gone. Must raise rather than silently serve current bytes: previews key
      # on this token, so answering with different content than was asked for is a correctness bug.
      if content_token.present? && content_token != node.content_hash
        raise NotFound, "content #{content_token.inspect} is not current (s3 keeps no history)"
      end

      key = key_for(node)

      # Read the cap PLUS ONE byte, via a ranged GET, and this is not the shape it first looks
      # like. `get_object` BUFFERS THE WHOLE BODY INTO A StringIO BEFORE IT RETURNS (verified),
      # so inspecting `resp.content_length` on the way out is too late to protect the host: the
      # 2GB is already resident. The range is what actually bounds it, at MAX_BYTES + 1 — the
      # exact exposure Share#read_capped! already accepts, and for the same reason it reads cap+1
      # rather than cap: reading exactly MAX_BYTES cannot distinguish "exactly at the cap" from
      # "truncated at the cap", so an oversize object would be silently halved and served as a
      # valid-looking file. It also costs no extra request, which a HEAD-then-GET would.
      resp = @client.get_object(bucket: @bucket, key:, range: "bytes=0-#{MAX_BYTES}")
      bytes = resp.body.read.to_s.b
      # NotFound for "too big" matches Share, and it is a KNOWN WART shared with it rather than a
      # local choice: the port's taxonomy has no name for terminal-but-present (spec §9a-5), and
      # inventing a third answer HERE would make the two backends disagree about the same file.
      raise NotFound, "file exceeds #{MAX_BYTES} bytes" if bytes.bytesize > MAX_BYTES
      bytes
    rescue ::Aws::S3::Errors::NoSuchKey, ::Aws::S3::Errors::NotFound => e
      # The ONLY terminal branch, and even it has to ask a second question first. A wrong/empty
      # bucket, a mistyped prefix, or a bucket the credentials can no longer see makes EVERY
      # object 404 at once — indistinguishable from "this one was deleted" if we only look at the
      # key. NotFound is terminal, so when the whole library appears to have evaporated, prefer
      # the retryable answer: a genuinely emptied library retried is harmless; a live library
      # burned to "failed" is not. Exactly Share's unmounted-NAS trade, same direction (spec §6).
      #
      # The probe is on the ERROR path only — one billed list_objects_v2(max_keys: 1), never in
      # the hot path.
      unless library_present?
        raise FetchError, "#{node_id.inspect}: #{e.class} and the library prefix looks empty"
      end
      # The library is there and this one object is not. Genuinely gone: terminal.
      raise NotFound, "#{node_id.inspect}: #{e.class}"
    rescue ::Aws::S3::Errors::ServiceError, ::Seahorse::Client::NetworkingError => e
      # EVERYTHING else is transient. This is the single most consequential line in the adapter,
      # and the direction is deliberate: AccessDenied (the credentials outage that caused the
      # original production incident), InternalError, a 5xx, a timeout, a network blip — none of
      # them means "this file is gone", and answering NotFound burns a healthy object's preview
      # to a permanent "failed" in GeneratePreviewJob's `rescue StandardError`, while FetchError
      # is caught by its retry_on and backs off.
      #
      # FAIL SAFE RATHER THAN ENUMERATE, and do NOT "improve" this into a whitelist of the errors
      # we think can happen: this backend points at ANY S3-compatible store (SeaweedFS, MinIO,
      # Ceph, R2), which are free to emit codes AWS never will, so the DEFAULT must be the
      # recoverable answer. Share's read makes this argument at length after its own errno
      # whitelist failed open; do not re-derive it, and do not reverse it.
      #
      # e.class is in the message on purpose: a stubbed/real SDK error's `message` does not name
      # the code, so the CLASS is the only place an operator learns WHICH failure this was.
      raise FetchError, "#{node_id.inspect}: #{e.class} (#{e.message})"
    end

    private

    # prefix + storage_path, and the guard that makes that concatenation safe.
    #
    # REJECT, NEVER NORMALIZE, and this is the one place where copying Share's Pathname reasoning
    # would be a bug rather than a shortcut. An S3 key is a flat byte string, not a filesystem
    # path: Pathname#expand_path would turn "a/../b" into a PERFECTLY VALID key and we would read
    # the wrong object, silently, with no error anywhere. Refusing the input is the only answer
    # that cannot resolve to something the caller did not ask for.
    #
    # It is not theoretical on this backend even though S3 itself never normalizes keys. We sign
    # PATH-STYLE URLs (force_path_style — SeaweedFS/MinIO need it), so a ".." segment lands in the
    # URL path as `endpoint/bucket/library/../etc/passwd`, and any proxy, gateway or store that
    # normalizes the request path resolves it OUT of our bucket. A leading "/" is named separately
    # because a `..`-only check misses it — it is the same class of escape wearing another shape.
    #
    # Checked per SEGMENT, not as a substring: "v1..2.stl" is an ordinary filename and must stay
    # readable. A storage_path is written by our own observer, but the audit that preceded this
    # work found exactly this bug class in client-supplied values used as storage keys, and
    # update_column bypasses every validation there is.
    def key_for(node)
      rel = node.storage_path.to_s
      raise NotFound, "node #{node.node_id.inspect} has no storage_path" if rel.blank?
      if rel.start_with?("/") || rel.split("/").include?("..")
        raise NotFound, "storage_path escapes the library prefix: #{rel.inspect}"
      end
      [ @prefix, rel ].compact.join("/")
    end

    # Is there a library at this prefix at all? The mirror of Share#library_present?, and the
    # emptiness signal is the same one: a wrong bucket/prefix or a revoked credential is an empty
    # listing, exactly as an unmounted share is an empty directory.
    #
    # max_keys: 1 — the question is "any object at all?", so one key answers it and we pay for
    # one request rather than a page of 1000.
    def library_present?
      @client.list_objects_v2(bucket: @bucket, prefix: listing_prefix, max_keys: 1).contents.any?
    rescue ::Aws::S3::Errors::ServiceError, ::Seahorse::Client::NetworkingError
      # Can't even list: definitely not a healthy library, so the caller's answer is the retryable
      # one. Same as Share, where an unlistable root answers false for the same reason. Failing
      # OPEN here would be the bug — it would promote the outage to "your file is gone".
      false
    end

    # nil prefix means the whole bucket. The trailing slash is what keeps a prefix a DIRECTORY
    # boundary: without it, prefix "cad" would also match the sibling "cadence/..." keyspace.
    def listing_prefix = @prefix && "#{@prefix}/"

    # The liveness guard both stat and read apply — a tombstoned node is GONE on every backend
    # (contract: test_contract_read_raises_not_found_for_a_deleted_node). Duplicated from Share
    # rather than shared: they are independent implementations of one port, and a common base
    # class is the one place another backend's assumptions could leak back into it.
    def live_node!(user, node_id)
      user.nodes.present.find_by(node_id:) ||
        raise(NotFound, "node #{node_id.inspect} is deleted or does not exist")
    end

    def build_client(region:, access_key_id:, secret_access_key:, endpoint:)
      # Required lazily, matching Storage::S3ChunkStore: the gem is `require: false` in the
      # Gemfile, so a chunk- or share-mode deployment never loads it. An injected `client:` skips
      # this entirely, which is what keeps the adapter's tests free of the dependency too.
      require "aws-sdk-s3"
      opts = { region:, access_key_id:, secret_access_key:, force_path_style: true }
      # force_path_style: matches S3ChunkStore. SeaweedFS/MinIO need it, and R2 accepts it.
      opts[:endpoint] = endpoint if endpoint.present?
      Aws::S3::Client.new(**opts)
    end
  end
end
