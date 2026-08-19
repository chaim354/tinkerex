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
      # scannable: true — the bucket is the user's, and s3 mv / Cyberduck / rclone / the console
      # all write to it without telling us. Library::S3Observer is the poll. Answering this
      # honestly is the whole of Phase 3's trap: the gate used to be `is_a?(FileLayer::Share)`,
      # which answered false for this adapter and silently never indexed the library.
      #
      # port_writable: true ALONGSIDE presignable: true, which looks like a contradiction and is
      # not: presignable is about handing the browser a URL to READ from, port_writable about
      # which door bytes come IN. A bucket could presign the upload too — spec §5.2 defers that —
      # so until it does, the UI POSTs to the port and #write puts the object.
      Capabilities.new(versioned: false, syncable: false, presignable: true, scannable: true,
                       port_writable: true)
    end

    # Mirrors Share#stat exactly: answered from the NODE, never from the bucket. A stat is what
    # a browse view calls per row, so asking S3 would put a billed round-trip behind every file
    # in a listing. The node carries everything the port promises, because the observer put it
    # there — and `mtime` is already unix NANOSECONDS by the time it lands in the column
    # (FileInfo's contract: adapters CONVERT, they do not pass a Time through; the observer is
    # where an S3 last_modified, which is a second-granularity Time, becomes nanos).
    def stat(user, node_id:)
      file_info(live_node!(user, node_id))
    end

    # ONE query for the whole list, and NO bucket call — see Chunk#stat_all for why this is a port
    # verb and why a missing node is an absent key rather than a raise, and #stat above for why
    # the bucket is not asked. The billing argument #stat makes ("a stat is what a browse view
    # calls per row") is what this method is: a HEAD per row was never on the table, but a DB
    # round-trip per row was, and 2000 of them cost 271 ms of a 444 ms page.
    def stat_all(user, node_ids:)
      user.nodes.present.where(node_id: node_ids).to_h { |n| [ n.node_id, file_info(n) ] }
    end

    # What is in this deployment's trash: the objects WE copied to the trash prefix, which
    # `undelete` can copy back.
    #
    # `storage_path: nil` is the filter, for the reason Share#trashed argues at length: it reads
    # the two-tombstone-kinds distinction (2b Landmine 2), which this backend inherits exactly —
    # `delete` NULLs the path, the Reconciler's scan tombstone keeps it, and only the first has
    # bytes anywhere `undelete` can find them. Listing a scan tombstone would offer a Restore
    # button that cannot work.
    #
    # DUPLICATED FROM Share#trashed RATHER THAN SHARED, and the duplication is this file's
    # standing trade (live_node!, leaf!, join_rel, nanos all make it): Share and S3 implement the
    # same port independently, and a base class between them is the one place one backend's
    # assumptions could leak into the other. Six lines is the cheaper trade. The READ CONTRACT is
    # what keeps the two answers the same, which is why it is asserted there and not here.
    def trashed(user)
      user.nodes.where(deleted: true, storage_path: nil).order(updated_at: :desc, name: :asc)
          .map do |n|
        TrashEntry.new(node_id: n.node_id, name: n.name, kind: n.kind,
                       size: n.size, deleted_at: n.updated_at)
      end
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

    # Hand the browser this file's bytes — as a SIGNED URL, so they never touch Rails. This is
    # where §15 survives on a no-history backend, and it is what presignable: true buys (see
    # #capabilities): a bucket has a URL signer, which is precisely what a mounted directory
    # lacks. Phase 4's Redirect is built on it.
    #
    # NO NETWORK AND NO BYTES: presigning is local HMAC (CLAUDE.md §14 — you can verify a URL is
    # correct without the store being reachable). A `get_object` here would defeat the entire
    # purpose, so #read stays the server-side path (preview jobs) and this stays the user's.
    #
    # THE DISPOSITION IS SIGNED IN, AND THAT IS THE POINT OF THE `disposition:` KEYWORD.
    #
    # A redirect bypasses every header the controller would otherwise set — the attachment
    # disposition FilesController forces for SVG and HTML (which a browser executes), the
    # nosniff, and the ?download=1 control. The browser leaves for the bucket and gets whatever
    # Content-Type the object carries. Left alone, the SAME UI button behaves differently
    # depending on the deployment's backend, which is the divergence the contracts exist to
    # prevent. (Be accurate about the severity: the redirect goes to the bucket's ORIGIN, so an
    # SVG executes there and not in our session — this is behavioral parity plus defense in
    # depth for a self-host that fronts its bucket on a sibling domain, not stored XSS.)
    #
    # response-content-disposition / response-content-type are S3's own overrides, and SigV4
    # signs the whole canonical query string — so they are TAMPER-PROOF rather than merely
    # present: a user editing `attachment` to `inline` in the URL bar invalidates the signature
    # and the store refuses the request. That is the difference between this and appending the
    # params to a finished URL, which would 403 every download instead.
    #
    # THE CONTROLLER OWNS THE POLICY, THIS OWNS THE MECHANISM. Which types may render inline is
    # SAFE_INLINE_TYPES — a web concern that has no business in a storage adapter — so it arrives
    # as an argument. A nil content_type means "no opinion, serve the object's own type", and the
    # SDK omits the param entirely rather than signing an empty string (verified).
    #
    # `disposition:` IS REQUIRED, on all three adapters, and the ArgumentError is the feature.
    # ContentDisposition.format(disposition: nil) returns "; filename=..." — a header with NO
    # disposition type — which a browser resolves by falling back to inline. So a caller who
    # forgot it would ship exactly the SVG-executes-at-the-bucket case above, silently, on this
    # backend only, while chunk and share (which ignore the value) stayed correct. A default here
    # would make the port's own signature the source of a cross-backend divergence.
    def download(user, node_id:, disposition:, content_type: nil)
      # The same liveness guard read applies, and key_for is the same escape guard: a presigned
      # URL for an escaped key is a signed GRANT to read outside the library prefix, which is
      # worse than a failed read.
      node = live_node!(user, node_id)
      params = {
        bucket: @bucket, key: key_for(node), expires_in: DOWNLOAD_EXPIRES_IN,
        response_content_disposition:
          ActionDispatch::Http::ContentDisposition.format(disposition:, filename: node.name)
      }
      params[:response_content_type] = content_type if content_type.present?
      Delivery::Redirect.new(url: presigner.presigned_url(:get_object, **params))
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
    # `replace: true` — see FileLayer::Share#write's header for the full argument; it is the port's
    # contract, not this adapter's, and adapter_write_contract.rb pins that the two answer alike.
    # The short version: it is the opt-in the clobber refusal is the default for, it MUST reuse the
    # existing node (a new node_id orphans every attachment, §14a), and on a vacant path it is an
    # ordinary create.
    #
    # CHEAPER HERE THAN ON SHARE, not more dangerous: put_object is atomic and overwrites by
    # definition, so a replace skips the head-then-put CHECK and adds nothing. There is no
    # temp-key dance to add either — §14a records why S3#write has none.
    def write(user, parent_node_id: nil, name: nil, io: nil, replace: false)
      leaf!(name)
      rel = join_rel(parent_dir_rel!(user, parent_node_id), name)
      observable!(rel)
      key = key_for_rel(rel)
      existing = (user.nodes.present.find_by(storage_path: rel, kind: "file") if replace)
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
        # AND IT ASKS BOTH NAMESPACES, because this backend has two. An exact-key HEAD cannot see
        # a DIR node holding this same rel (its marker is `<key>/`), and the index that actually
        # refuses the row is kind-agnostic — so the bucket question alone let a file written over
        # a folder's name reach a raw RecordNotUnique with the object already put. `replace:`
        # waives only the file it was told about; destination_vacant! carries the whole argument,
        # including the fail-safe rule for a HEAD that fails for some OTHER reason.
        destination_vacant!(user, rel, key, kind: "file", replace:)

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
      attrs = {
        size: bytes.bytesize, mtime: nanos(head.last_modified),
        # Through ObjectIdentity.for — the ONE normalizer, the same call the observer makes.
        # NEVER the raw ETag: S3 wraps every one in literal quotes, in put responses exactly as in
        # listings, so a write storing the quoted form and a scan storing the stripped one give
        # one object two identities. Every written file then reads as changed on the next pass and
        # move-pairing never pairs — the phase's headline promise, inverted by two quotes.
        content_hash: ObjectIdentity.for(etag: put.etag)
      }
      node =
        if existing
          # UPDATE, so node_id survives (see the header). A replace resolves to the SAME rel, so
          # name/storage_path/parent are already this object's and only the content facts move.
          existing.update!(**attrs)
          existing
        else
          user.nodes.create!(node_id: SecureRandom.uuid, name:, kind: "file", deleted: false,
                             storage_path: rel, parent_node_id:, **attrs)
        end
      stat(user, node_id: node.node_id)
    end

    # Create ONE directory under `parent_node_id`. On S3 a "directory" is a zero-byte dir-MARKER
    # object `<key>/` (the shape the console mints and S3Observer reads as a dir, not a phantom
    # file) plus a dir node. The marker is what makes an EMPTY folder survive a scan: with no object
    # under the prefix the reconciler has nothing to pair the dir node to and tombstones it. Reuses
    # write's guards (leaf!/observable!). Idempotent — a live dir already at this rel is returned.
    def mkdir(user, parent_node_id: nil, name: nil)
      leaf!(name)
      rel = join_rel(parent_dir_rel!(user, parent_node_id), name)
      observable!(rel)
      existing = user.nodes.present.find_by(kind: "dir", storage_path: rel)
      return stat(user, node_id: existing.node_id) if existing

      key = key_for_rel(rel)
      marker = "#{key}/"
      begin
        # STRICTLY AFTER the idempotence short-circuit above, never before it: a repeat mkdir must
        # keep returning the same dir node rather than start refusing itself. What is left for this
        # to catch is the CROSS-KIND case — a live FILE node, or a file object, at this exact rel —
        # which this verb asked nothing about at all until now (it looked up `kind: "dir"` only)
        # and answered with a raw RecordNotUnique plus a stray marker.
        destination_vacant!(user, rel, key, kind: "dir")
        @client.put_object(bucket: @bucket, key: marker, body: "")
        head = @client.head_object(bucket: @bucket, key: marker)
      rescue ::Aws::S3::Errors::ServiceError, ::Seahorse::Client::NetworkingError => e
        raise FetchError, "#{rel.inspect}: #{e.class} (#{e.message})"
      end
      node = user.nodes.create!(
        node_id: SecureRandom.uuid, name:, kind: "dir", deleted: false,
        storage_path: rel, parent_node_id:, mtime: nanos(head.last_modified)
      )
      stat(user, node_id: node.node_id)
    end

    # Copy the object out of the indexed keyspace into `.trash/<node_id>/<name>` and tombstone the
    # node. Keyed by node_id, not name: two `bracket.stl` from different folders must not collide,
    # and `undelete` needs one unambiguous place to look. On S3 that is a KEY PREFIX rather than a
    # directory — there is nothing to mkdir, which is the one way this is simpler than Share.
    #
    # THE ORDER IS THE WHOLE TASK: copy -> confirm -> delete -> confirm -> TOMBSTONE LAST.
    #
    # Spec §6 says "tombstone only after the copy confirms". That is correct AND NOT ENOUGH, and
    # the gap is only visible by reading it together with 2b's Landmine 2 — a landmine settled in
    # a DIFFERENT PHASE — which nulls storage_path on a trash tombstone so that revive-by-path
    # cannot fire for it. Trace the two survivable-looking orders:
    #
    #   copy -> TOMBSTONE -> delete, delete fails: the object is still live at its key. The node is
    #     tombstoned with storage_path NULL, so the next scan observes the key, finds no live node
    #     claiming it, and CANNOT revive by path — there is no tombstone at that path any more.
    #     It creates a NEW node with a NEW node_id. EVERY ATTACHMENT ORPHANED, by a scan that did
    #     nothing wrong, with no error anywhere.
    #   copy -> delete -> TOMBSTONE, delete fails: no tombstone. The object is at its key, the node
    #     is live and matches by path, the next scan is a no-op. The delete simply did not happen
    #     and the user retries. CONSISTENT.
    #
    # The complementary half says the same thing from the other side: a tombstone with the bytes
    # still in place is a file the user cannot see and the scan resurrects. Both halves: the
    # tombstone goes LAST.
    #
    # "delete_object on a missing key SUCCEEDS" (S3 is idempotent, 204) does not weaken this. It
    # means the absence of an error cannot prove the object was there to begin with — but this
    # ordering never needs that. It needs the converse: an ERROR proves the key may still be live,
    # and that is exactly when we decline to tombstone. Idempotence only makes a RETRY safe, which
    # is the behavior the failure path above hands the user.
    #
    # NO TRANSACTION, for Share's reason: a copy and a delete cannot be rolled back, so a
    # `transaction do` around both would roll back the ROW while leaving the bytes in .trash —
    # manufacturing exactly the silent resurrection this ordering exists to avoid. `node.update!`
    # is a single statement and already atomic, which is the only atomicity this needs.
    def delete(user, node_id: nil)
      node = live_node!(user, node_id)
      trashable_file!(node)
      copyable_size!(node)
      src_key = key_for(node) # read BEFORE the update nulls storage_path
      dest_key = trash_key(node)

      begin
        copy!(src_key, dest_key, if_match: etag_precondition(node.content_hash))
        @client.delete_object(bucket: @bucket, key: src_key)
      rescue ::Aws::S3::Errors::ServiceError, ::Seahorse::Client::NetworkingError => e
        # EVERY S3 failure here is a FetchError and NOTHING IS TOMBSTONED. Same fail-safe direction
        # as read's rescue, and the same refusal to enumerate: this backend points at any
        # S3-compatible store, so the DEFAULT must be the recoverable answer. Includes the
        # over-cap copy the size guard could not see coming (see COPY_MAX_BYTES).
        raise FetchError, "#{node_id.inspect}: #{e.class} (#{e.message})"
      end

      # `deleted: true` is what keeps a UI delete out of the mass-deletion guard's numerator:
      # vanished_paths reads the `present` scope, so a tombstoned node is invisible to it and
      # deleting most of a library can never make the next scan refuse itself (2b Landmine 1).
      #
      # `storage_path: nil` RELEASES the path (2b Landmine 2), and is not merely tidy:
      # Reconciler#create_or_revive! revives a tombstone BY storage_path, so a trash tombstone that
      # kept its path would hand a NEW, unrelated object dropped at that key the trashed node's
      # node_id — and with it every attachment, BOM link and tag — while the old bytes sat in
      # .trash awaiting an undelete that would then collide. Nulling it is what makes that revive
      # unable to fire. It is also why `undelete` must exist as a fourth verb rather than being
      # "a move back": there is no storage_path left to move from.
      node.update!(deleted: true, storage_path: nil)
      nil
    end

    # Rename and/or re-parent a node, keeping its node_id — the port's whole promise.
    #
    # S3 HAS NO RENAME, so this is copy + delete + update, and the row goes LAST. A failure between
    # the copy and the delete is self-healing rather than silent: both keys exist, so the next scan
    # pairs old->new by (content_hash, size) and re-homes the node with its node_id intact. There
    # is no tombstone to get wrong here, which is precisely why `delete` is the dangerous twin.
    #
    # KNOWN API AMBIGUITY, inherited from the port's signature (Share documents it too):
    # `new_parent_node_id: nil` means THE ROOT, so this cannot distinguish "rename in place" from
    # "move to the root" — a caller who omits it while meaning a rename moves the file to the top
    # of the library. A caller renaming must pass the current parent_node_id.
    #
    # A MOVE CHANGES THE FILE'S MODIFICATION DATE, and Share's does not. A copy IS a new object, so
    # the destination carries a fresh Last-Modified; the next scan observes it and rewrites
    # nodes.mtime, and the user sees a file they moved report as modified today. Share#move is one
    # rename() and preserves it. Inherent — S3 has no rename, and no way to set Last-Modified —
    # and self-healing (the date is merely newer, never wrong about the bytes). Recorded so it is
    # not rediscovered as a bug; not worth a copy-back or a stored original.
    def move(user, node_id: nil, new_parent_node_id: nil, new_name: nil)
      leaf!(new_name)
      node = live_node!(user, node_id)
      movable_file!(node)
      copyable_size!(node)
      src_key = key_for(node)
      rel = join_rel(parent_dir_rel!(user, new_parent_node_id), new_name)
      observable!(rel)
      dest_key = key_for_rel(rel)

      begin
        # Refuse rather than replace, and check BEFORE copying. Every backend here is
        # current-state-only, so a clobber is the user's file permanently gone — there is no
        # version to restore. A CHECK, NOT A LOCK: head-then-copy is TOCTOU and S3 has no portable
        # conditional put (R2/SeaweedFS/Ceph), so a concurrent create at the destination can still
        # be clobbered. What this stops is the ORDINARY case — a user moving onto a name that is
        # already there. It does not claim an atomicity S3 does not offer. (write's clobber check
        # makes the identical argument; the port cannot tolerate the two diverging on it.)
        #
        # BOTH NAMESPACES (see destination_vacant!). This verb is where the bucket-only question
        # was worst: the HEAD passed over a dir node's rel, the copy ran, the SOURCE WAS DELETED,
        # and `node.update!` below then raised RecordNotUnique — bytes moved, row still naming a
        # key that no longer exists. §14a's copy -> delete -> orphan landmine, in the ordinary UI.
        destination_vacant!(user, rel, dest_key, kind: "file")

        copied = copy!(src_key, dest_key, if_match: etag_precondition(node.content_hash))
        @client.delete_object(bucket: @bucket, key: src_key)
      rescue ::Aws::S3::Errors::ServiceError, ::Seahorse::Client::NetworkingError => e
        raise FetchError, "#{node_id.inspect}: #{e.class} (#{e.message})"
      end

      # THE COPY'S ETAG, NOT THE SOURCE'S — and this refresh is what keeps the row's identity one
      # a real bucket agrees with. A store re-tags a copy whenever the source ETag was not
      # md5(bytes): multipart-origin objects (rung 3, `etag:`) and SSE-KMS objects (which wear a
      # 32-hex ETag and are therefore misfiled on rung 2). Leave content_hash naming the SOURCE's
      # ETag and it names an ETag no object has, so the NEXT delete or move sends it as
      # copy_source_if_match, gets PreconditionFailed, and answers FetchError -> 503 "try again"
      # until Library::ScanJob's 15-minute pass repairs the row. Single-part unencrypted objects
      # re-derive the same md5 and are unaffected — which is exactly why this stayed invisible.
      #
      # FROM THE RESPONSE WE ALREADY HOLD. Never a HEAD afterwards: that is a billed request for a
      # value copy_object handed us, and #etag_precondition's own note already refuses the
      # HEAD-for-the-current-ETag move.
      #
      # ACCEPTED CONSEQUENCE, on a re-tagging store only: content_hash IS content_token
      # (see #file_info), so a moved object gets a new token and re-renders its thumbnail once even
      # though its bytes did not change. The scan produced exactly that re-render 15 minutes later
      # anyway — this only moves it earlier, and it is the price of the row being true NOW.
      #
      # PRESENCE-GUARDED, and the guard is load-bearing rather than defensive. ObjectIdentity.for
      # RAISES ArgumentError on a blank ETag (deliberately — see its normalize_etag), ArgumentError
      # is NOT a ServiceError so the rescue above would not catch it, and by this line
      # delete_object has ALREADY removed the source. An unguarded call against a store that
      # answers no ETag would raise with the bytes only at the new key and the row still naming the
      # old one — the orphaning landmine, from a store being merely unhelpful. Absent an ETag we
      # keep the PREVIOUS value (never nil: Reconciler#plan_moves DROPS a nil-hash observation, so
      # the object would never be indexed at all) and let the scan correct it.
      #
      # mtime is deliberately NOT refreshed here. copy_object's response carries no last_modified,
      # and the fake returns none either — so a "refresh" of it would be reading nil through
      # nanos() and would be green against the fake and wrong against every real store, which is
      # the exact defect this change exists to close. The header above already records that the
      # scan owns a moved object's mtime.
      attrs = { storage_path: rel, name: new_name, parent_node_id: new_parent_node_id }
      copied_etag = copied&.copy_object_result&.etag
      attrs[:content_hash] = ObjectIdentity.for(etag: copied_etag) if copied_etag.present?

      node.update!(**attrs)
      stat(user, node_id: node.node_id)
    end

    # Copy the bytes back out of `.trash` and revive the node — the inverse of `delete`, and a
    # FOURTH PORT VERB rather than "a move back" (spec §3.2 calls it that): `move` starts with
    # live_node! and resolves its source through `key_for(node)` -> node.storage_path, which
    # `delete` NULLS. The bytes live somewhere only a trash-aware verb can find.
    #
    # ORDER: copy -> revive -> sweep the trash copy, BEST-EFFORT. This DIVERGES from Share, whose
    # order is move-then-revive, and the divergence is forced by the primitive rather than chosen:
    # File.rename cannot leave the bytes in two places, so Share must pick which end to risk. A
    # copy can, and having both copies beats having neither.
    #
    # Copy -> delete-trash -> revive (the order that mirrors Share most closely) is LANDMINE 3
    # WEARING ANOTHER HAT: a failed delete-trash raises with the bytes already at their real key
    # and the node still trashed, so the next scan observes an unclaimed path, cannot revive by
    # path (storage_path is NULL), and mints a NEW node — orphaning every attachment. So the
    # destructive act — dropping the only other copy — goes LAST, exactly as delete's tombstone
    # does, and it does not raise: by then the user's file is back and a leftover trash object is
    # the purge job's problem, not a reason to fail an operation that succeeded.
    #
    # The remaining race is Share's, unchanged and accepted: a scan landing between the copy and
    # the revive indexes the observed path under a NEW node_id, and the revive then collides with
    # the partial unique index on (user_id, storage_path) WHERE deleted = false. Every ordering
    # that closes it opens the strictly worse one above.
    def undelete(user, node_id: nil)
      # NOT live_node!: this operates on a tombstone by definition. `deleted: true` in the lookup
      # is what makes undeleting a live node a clean NotFound instead of a confusing copy.
      node = user.nodes.find_by(node_id:, deleted: true) ||
             raise(NotFound, "node #{node_id.inspect} is not in the trash")
      src_key = trash_key(node)
      # Reconstructed from parent + name, because delete released storage_path (Landmine 2).
      # live: false — see parent_dir_rel!.
      rel = join_rel(parent_dir_rel!(user, node.parent_node_id, live: false), node.name)
      observable!(rel)
      dest_key = key_for_rel(rel)

      begin
        unless object_exists?(src_key)
          # THE ONLY PLACE BESIDES `read` WHERE THIS ADAPTER MINTS A "YOUR FILE IS GONE", and it
          # must ask the same question first, for the same reason. S3's equivalent of Share's
          # unmounted NAS is a credentials outage / a wrong bucket / a mistyped prefix — which is
          # exactly what FetchError already means, and which makes EVERY object 404 at once.
          # NotFound is TERMINAL, so answering it while the store is merely unreachable tells the
          # user their file is permanently lost when it is sitting safely in the bucket.
          unless library_present?
            raise FetchError, "#{node_id.inspect}: the trashed bytes are missing and the library " \
                              "prefix looks empty"
          end
          # The library is there and the bytes are not. The purge job took them, or this is a SCAN
          # tombstone, which never had bytes in .trash to begin with. Both terminal, both the same
          # answer to the user: it is gone.
          raise NotFound, "#{node_id.inspect}: its trashed bytes are gone (purged?)"
        end

        # BOTH NAMESPACES (see destination_vacant!), and the same sentence the other three verbs
        # answer with. It used to have its own ("is occupied — undelete must not clobber"), which
        # is one condition wearing two answers inside one adapter — the thing §14a forbids — and
        # its bucket-only half let a restore onto a folder's name copy the bytes back, raise
        # RecordNotUnique on the revive, and leave the object stray with the trash copy still held.
        destination_vacant!(user, rel, dest_key, kind: "file")

        # No if_match: the trashed bytes are ours, written by our own delete, and their identity is
        # not what node.content_hash records (that is the identity of the object at its ORIGINAL
        # key). There is nothing to match against and nothing racing us for a key named after a
        # node_id.
        copy!(src_key, dest_key)
      rescue ::Aws::S3::Errors::ServiceError, ::Seahorse::Client::NetworkingError => e
        raise FetchError, "#{node_id.inspect}: #{e.class} (#{e.message})"
      end

      # Re-stat: the bytes are the same, but mtime/size are what the next scan compares against,
      # and a stale pair would make it re-index the object for nothing. HEAD the DESTINATION —
      # that is the object the next scan will list. A failure here is not worth failing a restore
      # the user can already see: the next scan corrects mtime/size on its own.
      node.update!(deleted: false, storage_path: rel, **restored_stat(dest_key))
      sweep_trash(src_key)
      stat(user, node_id: node.node_id)
    end

    # nil prefix means the whole bucket. The trailing slash is what keeps a prefix a DIRECTORY
    # boundary: without it, prefix "cad" would also match the sibling "cadence/..." keyspace.
    #
    # PUBLIC because Library::S3Observer lists this library and must list exactly the keyspace this
    # adapter addresses. The alternative is the observer composing "#{adapter.prefix}/" itself —
    # a second copy of the trailing-slash rule above, in the one place where disagreeing with it
    # means indexing a neighbouring prefix's objects as if they were the user's library.
    def listing_prefix = @prefix && "#{@prefix}/"

    private

    # How long a download URL stays good. Matches Storage::S3ChunkStore#presign_get's hour, which
    # is the same question answered for the same reason: long enough that a big file over a slow
    # link finishes, short enough that a URL pasted into a chat is not a lasting grant.
    DOWNLOAD_EXPIRES_IN = 3600

    # Built LAZILY, not in the constructor, and that is a boot-path rule rather than a style
    # choice: `aws-sdk-s3` is `require: false` in the Gemfile and #build_client is what requires
    # it, so an injected `client:` (the test seam) never loads the gem. Constructing a Presigner
    # eagerly would drag the require back into every path, including the ones that inject.
    #
    # Local HMAC — no network, no round-trip, nothing to memoize for performance. It is memoized
    # because there is no reason to rebuild it.
    def presigner
      @presigner ||= begin
        require "aws-sdk-s3"
        ::Aws::S3::Presigner.new(client: @client)
      end
    end

    # 5 GiB — `copy_object`'s hard cap. It ERRORS above it; it does not truncate. Both `delete` and
    # `move` are copy-then-delete, so this is the size above which neither can run. Multipart copy
    # is deliberately not reached for (the plan says so, and it would put a resumable, multi-request
    # state machine behind a UI verb).
    #
    # CHECKED AGAINST node.size BEFORE THE REQUEST rather than by catching the store's error, and
    # that is not a preference — THE PLAN'S INSTRUCTION HERE CANNOT BE SATISFIED. It says to
    # "verify the exact error class against the SDK". aws-sdk-s3 mints error classes on demand via
    # const_missing, so `Aws::S3::Errors::TotallyMadeUpNonsenseError` resolves exactly as readily
    # as `Aws::S3::Errors::InvalidRequest` (verified — both answer to `<= ServiceError`). "The
    # class exists" is not a check; the assertion is unfalsifiable. And an S3-COMPATIBLE store
    # (SeaweedFS/MinIO/Ceph) is free to answer an over-cap copy with any code it likes anyway.
    #
    # So nothing here depends on the name. The size guard catches it up front from data we already
    # have (free, no request, exact), and whatever the store actually says lands in the rescues
    # above as a ServiceError -> FetchError -> NOTHING TOMBSTONED. Both roads end in the safe
    # direction, which is the property the landmine actually asks for.
    COPY_MAX_BYTES = 5 * 1024**3

    # `.trash/<node_id>/<name>`, as a KEY PREFIX rather than a directory — there is no mkdir here,
    # and no way for it to collide with a `.trash` object the way Share's EEXIST could.
    #
    # Composed through key_for_rel so the escape guard covers it: node.name is written by our own
    # observer, but a poisoned name ("../../etc/passwd") would otherwise compose a trash key
    # outside the prefix, and update_column bypasses every validation there is. NOT through
    # observable!, which asks a different question — that guard refuses `.trash` as a WRITE
    # DESTINATION for the user, and this key is the one legitimate exception to it.
    #
    # Library::Scanner::TRASH_PREFIX rather than a second ".trash" literal: the observer's skip and
    # this layout are ONE FACT, and two copies of it is how the trash quietly starts getting
    # indexed (Share#trash_dir shares the constant for the identical reason).
    def trash_key(node)
      key_for_rel("#{Library::Scanner::TRASH_PREFIX}/#{node.node_id}/#{node.name}")
    end

    # copy_object, with the encoding that is the difference between a working delete and silent
    # data loss. See #copy_source.
    def copy!(src_key, dest_key, if_match: nil)
      params = { bucket: @bucket, key: dest_key, copy_source: copy_source(src_key) }
      # Omitted entirely rather than passed as nil: an explicit nil is a param the SDK serializes.
      params[:copy_source_if_match] = if_match if if_match
      @client.copy_object(**params)
    end

    # "<bucket>/<key>", URL-ENCODED — and the encoder is load-bearing in a way no test against a
    # fake can show, so it is asserted at the wire instead (see the adapter's suite).
    #
    # aws-sdk-s3 does NOT escape copy_source. It puts this string into `x-amz-copy-source`
    # verbatim (verified by capturing the header at the :sign step), so the caller must encode it.
    #
    # NOT CGI.escape, which is the obvious reach and is WRONG: it is FORM encoding
    # (application/x-www-form-urlencoded), where a space becomes "+". Real S3 decodes the copy
    # source per RFC 3986, where "+" is a LITERAL PLUS. So CGI.escape("Bracket v2.stl") sends
    # "Bracket+v2.stl" and the store looks up a key the user does not have. In #delete that is not
    # an error the user ever sees: the copy reads the wrong key, the delete removes the RIGHT key,
    # the tombstone follows the delete, and the file is permanently gone with someone else's bytes
    # in its trash slot. A space in a filename is the most ordinary thing in a CAD library.
    #
    # It is also invisible to the suite: FakeS3 decodes with CGI.unescape, and CGI.escape/unescape
    # are inverses — so the wrong encoder is GREEN against the fake and broken against every real
    # store. That is the shape to watch for whenever a fake and the code under test share an
    # assumption.
    #
    # Per SEGMENT, joined on "/": ERB::Util.url_encode escapes everything outside RFC 3986's
    # unreserved set, INCLUDING "/", and the separators between key segments must survive as
    # separators (that is also how every SDK example writes a copy source). split("/", -1) keeps
    # trailing empties, so a key ending in "/" does not quietly lose it.
    def copy_source(key)
      "#{@bucket}/#{key.split('/', -1).map { |s| ERB::Util.url_encode(s) }.join('/')}"
    end

    # The node's identity as an ETAG PRECONDITION, or nil when it is not one.
    #
    # If the object changed between our listing and our copy, an unconditional copy would trash
    # bytes the user never meant to lose and then delete them from their key. copy_source_if_match
    # makes the copy refuse instead. BEST-EFFORT BY DESIGN: a store that ignores the header just
    # gets the unconditional behavior it would have had anyway, so this is free where it works.
    #
    # THE RUNGS ARE NOT INTERCHANGEABLE HERE (FileLayer::S3::ObjectIdentity):
    #   md5:<hex>  -> a single-part ETag IS that md5. Match it.
    #   etag:<raw> -> whatever the store called it. It is still the ETag. Match it.
    #   sha256:<b64> -> a CHECKSUM, NOT an ETag. Sending it as one would make If-Match fail every
    #                 time, so every delete and every move of such an object would refuse forever.
    #                 Send nothing.
    #
    # The plan offered "either HEAD for the current ETag first or skip the precondition" for that
    # last rung. SKIP, and the reason is that the HEAD version is precondition theater: the window
    # worth guarding is between the SCAN and the DELETE — hours — and an ETag fetched milliseconds
    # before the copy would cheerfully match an overwrite that landed an hour ago, which is exactly
    # the state this precondition exists to refuse to trash. It would buy a billed request and a
    # false sense of safety.
    #
    # QUOTED, because that is the form S3 emits an ETag in and therefore the form it compares
    # against (the quotes ObjectIdentity strips, put back deliberately — this is a wire value, not
    # an identity). Real S3 is lenient about them; not every S3-compatible store need be.
    def etag_precondition(identity)
      case identity.to_s
      when /\Amd5:(.+)\z/, /\Aetag:(.+)\z/ then %Q("#{Regexp.last_match(1)}")
      end
    end

    # Deleting or moving a DIRECTORY, refused — and the argument is NOT Share's, which is why
    # Share named its guard deletable_file! per-op rather than by kind and told this task to reach
    # its own answer.
    #
    # CAN a dir node even get here? YES. Task 7's observer synthesizes dir nodes from key prefixes,
    # so a user can click delete on a folder in the browse UI.
    #
    # SHARE refuses delete because File.rename on a directory SUCCEEDS — it moves the whole subtree
    # into .trash while leaving every child node live at a path that no longer exists, and the scan
    # cannot pair them because .trash is skipped. Its danger is that the primitive works too well.
    # SHARE ALLOWS move for the mirror reason: one atomic rename() carries the bytes, the children
    # stay OBSERVABLE at the new path, and the next scan re-homes them with their node_ids.
    #
    # NEITHER ARGUMENT SURVIVES HERE, because the primitive does not: there is no directory and
    # there is no rename. A dir node's storage_path is "cad", so key_for composes "library/cad" —
    # a key that does not exist. Unguarded, the copy 404s, that maps to FetchError (correctly), and
    # the user is told to RETRY, forever, an operation that can never succeed. A lie, not a refusal.
    #
    # The alternative is a cascade, and Share's objection transfers and gets worse: "a cascade whose
    # inverse does not exist is a delete the user cannot undo" (undelete restores ONE path under ONE
    # parent; there is no subtree story). On S3 it is additionally N copies + N deletes with no
    # atomicity across them — a failure at object 400 of 1000 leaves half the subtree in .trash and
    # half live, and no undo for either half. For move, the tempting cheap version (rewrite the dir
    # node's storage_path, touch no keys) is silent corruption: the children's KEYS stay at cad/*,
    # their nodes still say cad/*, and the next scan re-synthesizes a dir node at the cad/ prefix —
    # the tree then claims a folder the bytes are not in.
    #
    # So BOTH verbs refuse, from ONE fact, where Share needed two arguments to reach two different
    # answers. That is a real capability regression against Share for move, and it is the honest
    # one: a user renaming a folder in their own S3 console performs the same 2N copies, and the
    # observer pairs every child back by (content_hash, size). We decline to ORIGINATE the
    # operation, not to survive it.
    #
    # Kept as two per-op names for Share's reason: a future subtree story might land for one verb
    # and not the other, and one shared guard would make the other's message lie.
    def trashable_file!(node) = files_only!(node, "delete")
    def movable_file!(node) = files_only!(node, "move")

    def files_only!(node, verb)
      return if node.file?
      # UnsupportedOperation, not NotImplementedError: a user clicked #{verb} on a folder, so this
      # is a CLIENT condition (Phase 4 -> 409/422) and it must stay catchable by
      # `rescue StandardError`. NotImplementedError is a ScriptError and means the DEPLOYMENT is
      # mis-wired -> 501.
      raise UnsupportedOperation,
            "#{node.node_id.inspect} is a #{node.kind}: s3-mode #{verb} is files only — S3 has no " \
            "directory to #{verb} and no rename, so this would mean a non-atomic cascade over " \
            "every key under the prefix, with no undo for a half-finished one"
    end

    # copy_object's 5GiB cap, refused from data we already hold rather than from an error class we
    # cannot verify (see COPY_MAX_BYTES). UnsupportedOperation, not FetchError: this is a PERMANENT
    # property of this node on this backend, and FetchError would tell the user to retry something
    # that can never succeed. Not NotFound either — the file is right there.
    #
    # Nothing is tombstoned and no request is sent, mirroring 2b's EXDEV: a clear error, never a
    # silent half-delete.
    #
    # node.size is what the scan last saw, so it is STALE if the object has grown since. The
    # store's own refusal is the backstop and it lands in the same safe place — a ServiceError, so
    # FetchError, so no tombstone.
    def copyable_size!(node)
      return if node.size.to_i <= COPY_MAX_BYTES
      raise UnsupportedOperation,
            "#{node.node_id.inspect} is #{node.size} bytes: over S3's 5GiB copy cap, and both " \
            "delete and move are copy-then-delete here. Refusing rather than half-deleting it."
    end

    # The restored object's own size/mtime/identity, so the next scan skips it instead of
    # re-indexing. Best-effort: the undelete has already succeeded by the time this runs, and a
    # HEAD blip is not worth failing a restore the user can see — the next scan corrects all three
    # columns anyway. The SIZE comes from the HEAD too rather than from the node, because the
    # node's may predate a change we never saw.
    #
    # THE IDENTITY IS PART OF "the restored object's own", for the same reason as the other two and
    # with a sharper failure: undelete is copy-then-revive, and a store re-tags a copy whenever the
    # source ETag was not md5(bytes) (multipart-origin, SSE-KMS). Return only size/mtime and the
    # revived row names the ETag the object carried at its ORIGINAL key — so the next delete or
    # move sends it as copy_source_if_match and gets PreconditionFailed -> FetchError -> 503, and
    # Reconciler#unchanged? tests content_hash FIRST, so its own stated purpose ("the next scan
    # skips it") is defeated by the very column it omits. The HEAD is already made and already
    # carries `.etag`; this adds no request.
    #
    # PRESENCE-GUARDED for the same reason as #move's: ObjectIdentity.for raises ArgumentError on a
    # blank ETag, which no rescue here is written for, and the undelete has already put the bytes
    # back by the time this runs. No ETag -> keep the previous value (never nil) and let the scan
    # correct it, which is what the rest of this method already does on a HEAD blip.
    def restored_stat(key)
      head = @client.head_object(bucket: @bucket, key:)
      attrs = { size: head.content_length, mtime: nanos(head.last_modified) }
      attrs[:content_hash] = ObjectIdentity.for(etag: head.etag) if head.etag.present?
      attrs
    rescue ::Aws::S3::Errors::ServiceError, ::Seahorse::Client::NetworkingError
      {}
    end

    # Drop the trash copy once the node is live again. Best-effort BY DESIGN, not by laziness: the
    # undelete has succeeded — the bytes are at their real key and the node points at them — so
    # raising here would fail an operation that worked, and the user's retry would then find the
    # node no longer `deleted: true` and get a baffling "not in the trash". A leftover trash object
    # is the purge job's to sweep. This is the same rule as delete's tombstone, from the other end:
    # the destructive act goes LAST, and here it is the only one that can be given up on.
    def sweep_trash(key)
      @client.delete_object(bucket: @bucket, key:)
    rescue ::Aws::S3::Errors::ServiceError, ::Seahorse::Client::NetworkingError
      nil
    end

    # IS THIS DESTINATION FREE? Asked in BOTH namespaces, once, by all four mutating verbs.
    #
    # THIS BACKEND HAS TWO NOTIONS OF OCCUPANCY AND THEY DO NOT SEE EACH OTHER. `nodes` is the
    # catalog every verb writes a row into, and what actually refuses a duplicate there is ONE
    # partial index — index_nodes_on_user_id_and_storage_path, UNIQUE, WHERE deleted = false, and
    # KIND-AGNOSTIC (there is no model-level uniqueness, so it surfaces as a raw
    # ActiveRecord::RecordNotUnique, i.e. a 500). The bucket is a flat keyspace where a file lives
    # at `<key>` and a directory at `<key>/`, so object_exists? — an EXACT-key HEAD — structurally
    # cannot see the other kind. Ask only the bucket and every cross-kind collision passes the
    # check and then explodes at the row write, with the object already put.
    #
    # NEITHER HALF IS SUFFICIENT ALONE, which is why this ADDS to the bucket question instead of
    # moving authority to the DB. The catalog cannot see an object that is in the bucket and not
    # yet indexed — a bucket the user already had is this backend's whole premise — and the bucket
    # cannot see the cross-kind collision the index enforces.
    #
    # STILL A CHECK, NOT A LOCK. Asking a second namespace changes nothing about that: see
    # #write's own paragraph for the full argument (TOCTOU; S3 has no portable conditional put on
    # R2/SeaweedFS/Ceph). The row write is later still, so `move` can ALSO race to
    # RecordNotUnique with the source already deleted — this narrows the ordinary case, one user
    # onto a destination that is already taken, and claims no atomicity.
    #
    # `.present`, NEVER an unscoped lookup. A SCAN tombstone KEEPS its storage_path (§14a's two
    # tombstone kinds) and the partial index ignores it, so a tombstone at this rel is not an
    # occupant — blocking on one would refuse every re-upload over a file the scan tombstoned,
    # which is the ordinary repair path, on every write in the library.
    #
    # `kind:` IS REQUIRED because the two callers genuinely disagree about what occupies a
    # destination, and both wrong answers are real. For a FILE destination a dir marker at
    # `<key>/` is a collision. For `mkdir` it is the SAME kind — its idempotence short-circuit
    # owns that case — and refusing it would make creating a folder over an UNINDEXED bucket
    # prefix impossible, which is the on-ramp this backend exists for.
    #
    # A HEAD that fails for any OTHER reason (AccessDenied, a 5xx) must not read as "vacant" and
    # clobber: object_exists? lets those through to the caller's rescue. Fail safe.
    #
    # ONE CONDITION, ONE ANSWER, ONE MESSAGE (§14a). UnsupportedOperation — never NotFound (the
    # occupant is right there, and "File not found." about a file in the list is the answer this
    # port already had to correct once) and never FetchError (a clobber never succeeds on retry).
    #
    # RESIDUAL, recorded rather than argued away: an UNINDEXED directory that exists in the bucket
    # as a bare PREFIX with no marker object (`<key>/x.stl` and no `<key>/`) is invisible to a
    # HEAD, so a file written at `<key>` still lands beside it. Only until the scan runs — after
    # that there is a dir node and the catalog half answers — and closing it before then needs a
    # LIST per write rather than a HEAD, which is a cost this file has already refused elsewhere.
    def destination_vacant!(user, rel, key, kind:, replace: false)
      occupant = user.nodes.present.find_by(storage_path: rel)
      # A replace waives what it was told about and nothing else: the FILE at this rel, and with
      # it the bucket half, since that key holds that very node's object. A DIR node is NEVER the
      # file a caller confirmed replacing — replacing a folder with a file is not a replace — and
      # a replace onto a vacant rel stays an ordinary create, as it is on Share.
      return if replace && (occupant.nil? || occupant.kind == "file")

      taken = occupant.present? || object_exists?(key) ||
              (kind == "file" && object_exists?("#{key}/"))
      raise UnsupportedOperation, "#{rel.inspect} already exists" if taken
    end

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
      # TRASH_PREFIX is root-anchored (a nested `cad/.trash` is the user's own folder). OS clutter
      # (.DS_Store, ._*, __MACOSX/, macOS volume metadata) is any-depth and rejected via the SAME
      # Library::OsClutter predicate the S3Observer skips on — so an object the write path creates
      # can never sit at a key the scan will never observe. TEMP_PREFIX stays absent here: it is a
      # Share concept (this adapter writes no temp keys, see #write).
      return unless rel.to_s.split("/").first == Library::Scanner::TRASH_PREFIX ||
                    Library::OsClutter.ignore?(rel)
      raise NotFound, "#{rel.inspect} is a reserved path the library scan does not index"
    end

    def join_rel(dir_rel, name) = dir_rel.blank? ? name.to_s : "#{dir_rel}/#{name}"

    # Blank means THE ROOT — join_rel turns a nil dir into a bare name, which is what lets
    # `parent_node_id: nil` be a real destination (the write contract's convention throughout).
    #
    # `live: false` relaxes the lookup to include TOMBSTONED directories, and it exists for
    # `undelete` alone — but S3 needs it MORE than Share does, not less. On a share an emptied
    # directory still EXISTS on disk, so a scan observes it and never tombstones it; the flag is
    # only reached when the user then removes the folder in Finder. Here dir nodes are SYNTHESIZED
    # FROM KEY PREFIXES (Task 7), so trashing the last file under a prefix makes that prefix
    # vanish and the very next scan tombstones the dir. Refusing here would make the last file in
    # any folder permanently unrestorable — the common case, not an edge one.
    #
    # And it is safe here for a reason Share had to work for: Share needs mkdir_p to recreate the
    # folder, and leans on a recreated folder being positive evidence that revives the dir node by
    # storage_path. S3 has no directories at all — writing the key makes the prefix exist again,
    # and the observer revives that same dir node from it. Nothing to create, nothing to undo.
    #
    # The WRITE path keeps live: true, and the asymmetry is the point: writing a NEW file into a
    # folder that is gone is a request to reconsider, while restoring a file that was already in
    # there is a request to undo.
    def parent_dir_rel!(user, parent_node_id, live: true)
      return nil if parent_node_id.blank?
      scope = live ? user.nodes.present : user.nodes
      parent = scope.find_by(node_id: parent_node_id, kind: "dir") ||
               raise(NotFound, "parent #{parent_node_id.inspect} is not a " \
                               "#{'live ' if live}directory")
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

    # The liveness guard both stat and read apply — a tombstoned node is GONE on every backend
    # (contract: test_contract_read_raises_not_found_for_a_deleted_node). Duplicated from Share
    # rather than shared: they are independent implementations of one port, and a common base
    # class is the one place another backend's assumptions could leak back into it.
    def live_node!(user, node_id)
      user.nodes.present.find_by(node_id:) ||
        raise(NotFound, "node #{node_id.inspect} is deleted or does not exist")
    end

    # The one place a node becomes a FileInfo, shared by stat and stat_all — the browse view and
    # the detail view answering differently about the same file is the §9a-1 bug in a new
    # spelling, and one copy makes it impossible rather than unlikely. Duplicated from
    # Share#file_info rather than shared, which is this file's standing trade (see #trashed): the
    # READ CONTRACT is what keeps the two answers equal, which is why it is asserted there.
    def file_info(node)
      FileInfo.new(
        node_id: node.node_id,
        name: node.name,
        kind: node.kind,
        size: node.size.to_i,
        mtime: node.mtime,
        content_token: node.content_hash
      )
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
