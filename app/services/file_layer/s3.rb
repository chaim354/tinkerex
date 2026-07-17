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

    # Store new bytes at `name` under `parent_node_id` and index the result, so the node exists
    # the instant the caller can attach to it rather than up to a scan-interval later. The mirror
    # of Share#write, and FileLayerWritableContract is what holds the two to the same answers.
    #
    # NO TEMP-AND-RENAME, and its ABSENCE is the thing to read carefully here, because a reader who
    # knows Share#write will see a missing step and "restore" it. Share writes to a temp file and
    # renames because a half-written file is VISIBLE in the share the whole time it is being
    # written — a scan landing in that window indexes a torn file, and S3 has no such window:
    # put_object is atomic, the object appears whole or not at all. There is nothing to protect
    # against, and inventing a temp key here would add a second, unobservable key (the exact ghost
    # class 2b documents at length) to solve a problem this backend does not have.
    #
    # NO TRANSACTION, for Share's reason: the put cannot be rolled back, so wrapping the create!
    # in one buys nothing and only widens the window in which the object has landed and the row
    # has not. That failure is self-healing — the next scan indexes the object.
    #
    # COST, stated rather than hidden: one HEAD (the clobber check) + one PUT + one HEAD (the
    # mtime — see below). Two billed HEADs per write. The first is what the write contract
    # requires; the second is what the store's own clock costs.
    def write(user, parent_node_id: nil, name: nil, io: nil)
      leaf!(name)
      rel = join_rel(parent_dir_rel!(user, parent_node_id), name)
      observable!(rel)
      key = key_for_rel(rel)
      # Read BEFORE the clobber check, deliberately: reading up to 256MB between the HEAD and the
      # PUT would widen the very race the check already cannot win (below). The bytes are needed
      # either way, and buffering them for a write that is about to be refused costs nothing but
      # memory we were going to spend.
      bytes = read_capped!(io)

      begin
        # REFUSE AN OCCUPIED DESTINATION. This is a write-contract rule, not this adapter's taste,
        # and it matters MORE here than it would in chunk mode: every backend the contract covers
        # is current-state-only (spec decision 3), so a clobber is the user's file PERMANENTLY
        # gone from a name collision in an upload form — there is no version to restore. Share
        # refuses (share.rb:89); an S3 adapter that put straight over it would diverge from its
        # sibling on the one axis this port cannot tolerate.
        #
        # IT IS A CHECK, NOT A LOCK, and saying so is the point of this paragraph. head-then-put
        # is TOCTOU: a concurrent writer between the two still wins, and S3 has no portable
        # conditional put (R2/SeaweedFS/Ceph), so there is no primitive here that would close it.
        # What this stops is the ORDINARY case — a user re-uploading a name that is already there
        # — which is the case that actually destroys data. It does not claim atomicity.
        #
        # A HEAD that fails for any OTHER reason (AccessDenied, a 5xx) must not read as "vacant"
        # and clobber: object_exists? lets those through to the rescue below. Fail safe.
        raise NotFound, "#{rel.inspect} already exists" if object_exists?(key)

        put = @client.put_object(bucket: @bucket, key:, body: bytes)
        # The ONLY source of the object's mtime. put_object's response carries no last_modified
        # (verified against the SDK's PutObjectOutput members — the plan offered "the put response
        # / a HEAD" and only the HEAD exists), and Time.now is NOT an acceptable substitute: the
        # next scan compares the node against what the STORE reports, so a clock we guessed makes
        # every written file look changed on the very next pass. FileInfo's contract pins the unit
        # — unix NANOSECONDS, converted by the adapter — and seconds-as-nanos has shipped twice in
        # this codebase.
        head = @client.head_object(bucket: @bucket, key:)
      rescue ::Aws::S3::Errors::ServiceError, ::Seahorse::Client::NetworkingError => e
        # A failed write is TRANSIENT — the caller retries. Never NotFound: a full/throttled/
        # unreachable store does not mean "this file is gone", and NotFound is terminal. Same
        # direction as read's rescue and Share#write's, for the same reason.
        raise FetchError, "#{rel.inspect}: #{e.class} (#{e.message})"
      end

      # INDEX ONLY AFTER THE PUT LANDS. The order is the point: a node indexed for bytes that
      # never arrived is an attachment resolving to a permanent NotFound, which is strictly worse
      # than no attachment at all — the user can retry an upload that failed loudly, and cannot
      # fix a file that browses fine and 404s forever. Pinned by the write contract.
      node = user.nodes.create!(
        node_id: SecureRandom.uuid, name:, kind: "file", deleted: false,
        storage_path: rel, parent_node_id:,
        size: bytes.bytesize, mtime: nanos(head.last_modified),
        # Through ObjectIdentity.for — the ONE normalizer, the same call the observer makes.
        # NEVER the raw ETag: S3 wraps every one in literal quotes, in put responses exactly as in
        # listings, so a write storing the quoted form and a scan storing the stripped one give
        # one object two identities. Every written file then reads as changed on the next pass and
        # move-pairing never pairs — the phase's headline promise, inverted by two quotes.
        content_hash: ObjectIdentity.for(etag: put.etag)
      )
      stat(user, node_id: node.node_id)
    end

    private

    # Does an object already live at this key? NotFound/NoSuchKey mean vacant — the fake and the
    # real SDK both answer a missing key with Errors::NotFound on a HEAD (there is no body to
    # carry a NoSuchKey code), and both are named because an S3-compatible store may pick either.
    # EVERY other error propagates to the caller's rescue: an AccessDenied read as "vacant" is how
    # a credentials blip turns into an overwrite of the user's file.
    def object_exists?(key)
      @client.head_object(bucket: @bucket, key:)
      true
    rescue ::Aws::S3::Errors::NotFound, ::Aws::S3::Errors::NoSuchKey
      false
    end

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
      key_for_rel(rel)
    end

    # The guard itself, on a RELATIVE path rather than a node, because the write path composes a
    # rel from a parent + a leaf and has no node to hand it until after the put. One copy: two
    # copies of a security check drift, and this file already makes that argument for live_node!.
    def key_for_rel(rel)
      rel = rel.to_s
      if rel.start_with?("/") || rel.split("/").include?("..")
        raise NotFound, "storage_path escapes the library prefix: #{rel.inspect}"
      end
      [ @prefix, rel ].compact.join("/")
    end

    # A leaf name is a leaf; the directory is parent_node_id's job. Mirrors Share#leaf!, including
    # its reason for naming `.` and `..` explicitly: they are SEPARATOR-FREE, so File.basename
    # passes them, and they are the only leaf values that could compose a key outside the prefix.
    # Refusing them here is what makes it true that no `name` can ever reach the escape guard —
    # which is why the guard's own test has to come through a poisoned PARENT.
    def leaf!(name)
      return unless name.blank? || File.basename(name.to_s) != name.to_s || %w[. ..].include?(name.to_s)
      raise NotFound, "#{name.inspect} is not a leaf name (the directory is parent_node_id's job)"
    end

    # The write path must never create a key the observer SKIPS. `leaf!` asks a different question
    # — "is this one path segment?" — and `.trash` is a perfectly good leaf.
    #
    # NOT IN THE PLAN, and added deliberately: this is the structural blind spot 2b hit FOUR times
    # on the share, and it transfers to S3 with one half amputated and the other intact. The half
    # that does NOT transfer: S3 has no directories, so a `.trash` OBJECT cannot collide with the
    # `.trash/<node_id>/<name>` KEYS that Task 6's delete writes — nothing here breaks every delete
    # in the library the way Share's EEXIST did. The half that DOES: Task 7's observer skips the
    # `.trash` prefix, so an object written there is a live node at a key the scan never observes
    # -> unpairable ghost -> tombstone -> the mass-deletion guard refuses that scan AND EVERY SCAN
    # AFTER IT. One ordinary-looking upload, permanent.
    #
    # Library::Scanner::TRASH_PREFIX rather than a second ".trash" literal — the skip and this
    # guard are ONE FACT, and two copies of it is how the trash quietly starts getting indexed
    # (Share#trash_dir and Share#observable! share the constant for the identical reason). Task 7's
    # observer is told to mirror the same constant.
    #
    # Root-anchored: a nested `cad/.trash` is the user's own folder, is indexed, and is none of our
    # business. TEMP_PREFIX is deliberately NOT checked here — it is a Share concept (this adapter
    # writes no temp keys, see #write) and the S3 observer has no reason to skip it, so an object
    # named `.maker-tmp-x` is observable and therefore harmless.
    #
    # NOTE FOR TASK 6: `move`'s destination needs this same guard. 2b's retracted sentence — "a
    # move is self-healing because the bytes stay observable" — is false exactly when the
    # DESTINATION is the unobservable one.
    def observable!(rel)
      return unless rel.to_s.split("/").first == Library::Scanner::TRASH_PREFIX
      raise NotFound, "#{rel.inspect} is a reserved path the library scan does not index"
    end

    def join_rel(dir_rel, name) = dir_rel.blank? ? name.to_s : "#{dir_rel}/#{name}"

    # Blank means THE ROOT — join_rel turns a nil dir into a bare name, which is what lets
    # `parent_node_id: nil` be a real destination (the write contract's convention throughout).
    # Mirrors Share#parent_dir_rel!, minus its `live:` flag: that exists for undelete alone, which
    # is Task 6's.
    def parent_dir_rel!(user, parent_node_id)
      return nil if parent_node_id.blank?
      parent = user.nodes.present.find_by(node_id: parent_node_id, kind: "dir") ||
               raise(NotFound, "parent #{parent_node_id.inspect} is not a live directory")
      # Blank means the root, so a path-less parent would silently relocate the file to the TOP of
      # the library rather than fail. Of everything this adapter can get wrong, a silent
      # misplacement is the one it has no later way to detect. (Share argues this at length.)
      raise NotFound, "parent #{parent_node_id.inspect} has no storage_path" if parent.storage_path.blank?
      parent.storage_path
    end

    # Read the cap PLUS ONE byte, for the reason #read's ranged GET gives: reading exactly
    # MAX_BYTES cannot distinguish "exactly at the cap" from "truncated at the cap", so an oversize
    # upload would be silently cut in half and stored as a valid-looking file. NotFound for "too
    # big" matches Share and #read — the shared wart (spec 9a-5), not a local choice.
    def read_capped!(io)
      bytes = io.read(MAX_BYTES + 1).to_s.b
      raise NotFound, "file exceeds #{MAX_BYTES} bytes" if bytes.bytesize > MAX_BYTES
      bytes
    end

    # S3's last_modified is a second-granularity Time; the column is unix NANOSECONDS. This is the
    # conversion FileInfo's contract requires of every adapter, and it is the exact formula the
    # observer applies to a listing's last_modified — the two must agree or every written file
    # looks changed on the next scan.
    def nanos(time) = time.to_i * 1_000_000_000 + time.nsec

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
