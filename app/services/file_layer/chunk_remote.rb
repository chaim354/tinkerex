# frozen_string_literal: true

module FileLayer
  # THE MAKER APP AS A SYNC CLIENT — Stage 4, design doc §6. Not yet selectable: `LibraryBackend`
  # offers chunk, share and s3 only, and `FileLayer.build` has no "chunk_remote" arm. This class and
  # its Transport land first so the wire and its error vocabulary can be built and tested against a
  # real server before anything can route traffic at them. Adding the arm is the LAST step of the
  # arc, not the first, so a half-implemented adapter can never be reached by a deployment.
  #
  # WHY IT IS NOT A SUBCLASS OF `FileLayer::Chunk`, WHICH IS THE OBVIOUS-LOOKING MOVE. Chunk ships
  # in the tinkerex-sync gem, and a chunk_remote deployment does not load that gem at all -- it
  # talks to a sync server over HTTP, so it wants the engine in-process no more than share does
  # (that is exactly what Arc A made possible). Inheriting would reintroduce the dependency this
  # backend exists to remove.
  #
  # READS ARE LOCAL SQL, WRITES GO OVER THE WIRE. The design's resolution of the `nodes` straddler:
  # the maker app pulls changelog deltas and applies them to its OWN `nodes`, exactly as
  # `apply_remote` does in Rust, so `stat`/`stat_all`/`trashed` never touch the WAN and §14a's
  # constant-in-N query guarantee survives. CLAUDE.md §2's "the WAN is never in the metadata path"
  # becomes true of the maker app for the first time.
  #
  # A MEASURED CONSEQUENCE FOR WHOEVER BUILDS THE APPLY LOOP: `nodes.size` already EXISTS and is
  # NULL on chunk today -- only Library::Reconciler (share/s3) ever writes it, and Chunk#stat_all
  # reads sizes from `versions` instead, costing a second query. Verified against a live row:
  # node.size=nil while version.size=12. The apply loop should populate it, which makes stat_all
  # here ONE query rather than two -- better than the backend it replaces, not merely equal.
  class ChunkRemote
    # IDENTICAL TO CHUNK'S, AND THAT IS THE POINT: what changes in remote mode is WHERE the work
    # happens, not what the deployment can do. `port_writable` stays FALSE (§14a's most-misread
    # name: the UI drives the two-phase presigned flow, which is how a chunk_remote upload happens
    # -- it is not "cannot accept uploads"), and `dir_deletable` stays TRUE because the server's
    # SubtreeDelete cascades exactly as it does in-process.
    # `presignable: FALSE`, WHICH IS THE ONE PLACE THIS DIVERGES FROM CHUNK, AND THE CONTRACT IS
    # WHAT FORCED THE QUESTION. It read `true` here until `FileLayerAdapterContract` was wired and
    # asserted the only thing the flag actually means: `presignable? == download returns a Redirect`,
    # with the store given every chance to mint a URL.
    #
    # This adapter cannot redirect, and the reason is §14a's own. `Chunk#download` redirects a
    # single-chunk file ONLY when it can prove the store is real S3, because memory and local stores
    # presign to URLs RAILS ITSELF serves. ChunkRemote cannot make that check: the URL is signed by
    # ANOTHER server whose store this app has no visibility into, so a `local`-backed sync server
    # would have us redirect a browser into someone else's Rails with no way to know we had. The
    # remote also signs no disposition or filename for us, and redirecting a MULTI-chunk file is
    # silent truncation.
    #
    # So the honest answer is false: THIS ADAPTER cannot hand a browser a URL. That the remote can
    # presign for our own inbound fetch is a different question -- exactly the distinction §14a
    # already draws when it notes `manifest#download` gates on `syncable`, NOT `presignable`. Nothing
    # in the app gates on this flag today (checked), so the cost is a stream where a redirect might
    # have served, which is stated in `#download` rather than hidden.
    CAPABILITIES = Capabilities.new(
      versioned: true, syncable: true, presignable: false,
      scannable: false, port_writable: false, dir_deletable: true
    ).freeze

    # `write` EXISTS IN ORDER TO REFUSE, and its absence was a real omission the contract caught.
    # The port requires every adapter to answer this verb; a chunk-family backend answers by
    # refusing, because `write` takes an IO and a server-side byte write would push bytes through
    # Rails (§15). The upload path is the two-phase presigned pair instead. NotImplementedError is
    # deliberate and must stay UN-RESCUED -- it is a ScriptError, so `rescue => e` does not catch it,
    # and a 501 here would be factually wrong: the caller used the wrong door (§14a).
    WRITE_MSG = "chunk_remote uploads go through begin_upload/finalize_upload, not write"

    def write(_user, parent_node_id: nil, name: nil, io: nil, replace: false)
      raise NotImplementedError, WRITE_MSG
    end

    # `chunk_fetch:` IS INJECTABLE FOR THE SAME REASON `transport:` IS, and it is a second seam
    # rather than a convenience. The two talk to DIFFERENT servers -- the transport to the sync
    # server with a device token, this to object storage with no credential of ours -- so a test
    # that can substitute one and not the other can only exercise half the round trip. A sync
    # server backed by a memory or local store presigns URLs IT serves, which is exactly the case
    # this seam lets a suite reach without standing up object storage.
    #
    # `transport:`, INJECTED, IS THE SAME OBJECT FOR EVERY USER -- ARC C TASK 4 CHANGED WHAT THAT
    # MEANS. Before this arc it was fine because there was only ever ONE token in the whole
    # deployment to inject. Now a real (non-injected) transport is PER-USER (see #transport below),
    # so injecting one here is deliberately an escape hatch for tests that want to exercise every
    # OTHER verb without also exercising per-user token resolution -- every existing test in this
    # tree that constructs `ChunkRemote.new(transport: ...)` does exactly that, and none of them
    # needed to change for Task 4, which is the point of keeping this seam's contract unchanged.
    # `provisioning:` is the analogous seam for the ONE thing `transport:` alone cannot fake --
    # lazily provisioning a user who has no token yet (#device_token_for below); see Provisioning's
    # own header for why it is safe to hold as ordinary shared state where `transport:` is not.
    def initialize(transport: nil, chunk_fetch: ChunkFetch, provisioning: nil)
      @transport = transport
      @chunk_fetch = chunk_fetch
      @provisioning = provisioning
    end

    def capabilities = CAPABILITIES

    # ── METADATA READS: LOCAL SQL, NO WIRE ────────────────────────────────────────────────────
    #
    # This is the design's central claim made real (§6). ChangelogSync has already mirrored the
    # server's tree into this app's own `nodes`, so these three answer from the database the request
    # is already talking to. No HTTP, no timeout, no FetchError — a sync server that is down does not
    # make the library page hang or fail; it makes it STALE, which is the correct failure for a
    # local-first system and the whole reason CLAUDE.md §2 exists.

    def stat(user, node_id:)
      file_info(live_node!(user, node_id))
    end

    # ONE QUERY, WHERE Chunk#stat_all NEEDS TWO. Chunk reads sizes from `versions` because
    # `nodes.size` is NULL there; ChangelogSync records the size on the node at apply time, so there
    # is nothing to join. The contract's requirement is that the count be CONSTANT in N -- it does
    # not have to be the same constant as another backend's, and asserting a literal would pin one
    # leg and fail the others (§14a).
    #
    # A MISSING NODE IS AN ABSENT KEY, NOT A RAISE: `stat` is asked about one node so NotFound is its
    # whole answer, but a bulk caller holds a LIST, and a row tombstoned mid-page must not 404 the
    # page.
    def stat_all(user, node_ids:)
      user.nodes.present.where(node_id: node_ids).to_h { |n| [ n.node_id, file_info(n) ] }
    end

    # `Sync::Trash.list` is `user.nodes.where(deleted: true)` and nothing more -- checked, not
    # assumed -- so this needs no engine and is the same question asked of the same table.
    def trashed(user)
      user.nodes.where(deleted: true).order(updated_at: :desc, name: :asc).map do |n|
        TrashEntry.new(node_id: n.node_id, name: n.name, kind: n.kind,
                       size: n.size, deleted_at: n.updated_at)
      end
    end

    # ── BYTE READS: THE MANIFEST IS LOCAL, THE BYTES ARE NOT ─────────────────────────────────
    #
    # ChangelogSync mirrored the manifest, so naming the manifest costs no round trip. Fetching them
    # does: POST /v1/chunks/download presigns the hashes, and the bytes come straight from object
    # storage. §15 holds -- the sync server never proxies a byte, and neither do we on the way in.

    def read(user, node_id:, content_token: nil)
      node = live_node!(user, node_id)
      version_id = content_token.presence || node.current_version_id
      manifest = manifest_for(user, version_id)
      raise NotFound, "no manifest for #{node_id.inspect} at #{version_id.inspect}" if manifest.empty?

      # THE PORT'S CAP (FileLayer::MAX_BYTES), KEPT THE ONLY WAY THIS BACKEND CAN KEEP IT -- AND IT
      # COSTS NOTHING. Share stats the file and S3 bounds a ranged GET; neither mechanism exists
      # here, but the manifest already in hand carries every chunk's `length` (null: false), so the
      # EXACT byte count of the String below is known before a single chunk is presigned. Refusing
      # here also SAVES the POST /v1/chunks/download an over-cap file would otherwise pay for.
      #
      # SUMMED OVER ENTRIES, NEVER OVER UNIQUE HASHES. Chunking dedupes, which is why `presign`
      # uniques the hashes one line down; uniquing HERE would under-count a file with repeated
      # blocks and let it through. And not `node.size` either: that is the CURRENT version's size,
      # while `content_token` may name an older one -- exactly the case version-keyed manifests
      # exist to serve.
      #
      # NotFound for "too big" is the KNOWN WART shared with Share and S3 (the port's taxonomy has
      # no name for terminal-but-present), not a local choice -- see s3.rb's note at the same raise.
      raise NotFound, "file exceeds #{MAX_BYTES} bytes" if manifest.sum(&:length) > MAX_BYTES

      urls = presign(user, manifest.map(&:chunk_hash))
      +"".b.tap { |buf| manifest.each { |c| buf << fetch_chunk(c, urls) } }
    end

    # ALWAYS STREAMS; NEVER REDIRECTS, AND THAT IS NOT AN OVERSIGHT COPIED FROM THE WRONG SIBLING.
    # `Chunk#download` redirects a single-chunk file only when it can PROVE the store is real S3
    # (`store.is_a?(S3ChunkStore)`), because §14a records that memory and local stores presign to
    # URLs Rails itself serves -- redirecting there sends the browser back through the app.
    #
    # ChunkRemote cannot perform that check. The URL is signed by ANOTHER server, whose store this
    # app has no visibility into; a `local`-backed sync server hands back a URL pointing at its own
    # Rails, and we would be redirecting a browser into someone else's app with no idea we had done
    # it. Two further reasons the same way: the remote signs no disposition or filename for us
    # (§14a's silent inline-vs-attachment divergence), and redirecting a MULTI-chunk file hands the
    # browser its first chunk with a 200 and the right name -- silent truncation.
    #
    # THE COST IS STATED, NOT HIDDEN: download bytes pass through this app, a departure from §15 of
    # the same kind share makes for the same kind of reason (there is nothing here we can safely
    # presign). The INBOUND fetch is still direct-from-storage, so the sync server proxies nothing.
    def download(user, node_id:, disposition:, content_type: nil)
      node = live_node!(user, node_id)
      manifest = manifest_for(user, node.current_version_id)
      raise NotFound, "no manifest for node #{node_id.inspect}" if manifest.empty?

      urls = presign(user, manifest.map(&:chunk_hash))
      Delivery::Stream.new(enum: Enumerator.new { |y| manifest.each { |c| y << fetch_chunk(c, urls) } })
    end

    # ── METADATA MUTATIONS: DECIDED LOCALLY, PERFORMED REMOTELY ──────────────────────────────
    #
    # THE COLLISION CHECKS RUN AGAINST THE LOCAL MIRROR, WHICH IS WHERE CHUNK RUNS THEM TOO. The
    # server's own endpoints do not check: `mkdir` is `find_or_initialize_by(node_id:)` and takes
    # the name it is given. Chunk calls `destination_vacant!` before `Sync::Mutation.apply` for that
    # reason, and this adapter has to make the same call against the tree ChangelogSync mirrored.
    #
    # SO IT IS A CHECK, NOT A LOCK -- the same TOCTOU §14a already records for `S3#write`, widened
    # by however stale the mirror is. Another device can take the name between our check and the
    # server's write. That is a property of the protocol, not of this class: the server is the only
    # thing that could hold such a lock, and asking it to would be a new endpoint the design forbids.
    #
    # EVERY MUTATION PULLS AFTERWARDS rather than guessing at the new local state. The endpoints
    # answer `{seq:}`, not a node, and inventing the row we think we just made is how a mirror
    # drifts from its source -- one round trip is the honest price of the server being authoritative.
    # `#move` is the one deliberate exception, and only from inside `#batch` -- see both for why.

    # `#batch` IS LibraryBroadcast's `chunk_remote` ARM (app/services/library_broadcast.rb), reached
    # whenever the engine is not loaded but FileLayer.current is this class. That file's own comment
    # explains why share/s3 stay a bare `yield` (no changelog, nothing to coalesce) and why the
    # argument stops there: this backend's changelog is real, just remote, so the per-call price
    # `#refresh_or_defer!` pays on every `#move` is exactly the cost Sync::LibraryChannel.batch was
    # written to coalesce for embedded chunk -- and per THAT class's own comment ("once the engine
    # is remote... coalescing becomes the remote adapter's concern"), this is that adapter.
    #
    # THE SHAPE DELIBERATELY MIRRORS Sync::LibraryChannel.batch: a `Thread.current` frame, not an
    # ivar on `self`. FileLayer.current memoizes ONE adapter instance for the whole process
    # (`FileLayer.current ||= build`), shared across every Puma thread, so per-batch state living on
    # this object would let one request's batch leak into a concurrent request's unrelated
    # mutation. A batch re-entered by the SAME user JOINS the open one -- Maker::ProjectIntake.for_user
    # wraps a loop over projects, and each project's own #call wraps its own file_all, both for the
    # SAME user, and the inner one must contribute to the outer's single deferred pull rather than
    # triggering one of its own. A DIFFERENT user's batch is not a shape this app produces, but is
    # handled honestly anyway: it pushes its own frame and the first is restored on the way out,
    # rather than being silently absorbed into it.
    #
    # THE PULL RUNS IN `ensure`, ON ANY EXIT, NOT ONLY THE HAPPY PATH. A deferral that only pulls
    # when the block succeeds is worse than no deferral at all: every move that ran before an
    # exception has already committed on the SERVER (each is its own request), so a batch that
    # raises partway through leaves the mirror stale at precisely the moment something has gone
    # wrong and a caller is most likely to read it next.
    BATCH_KEY = :chunk_remote_refresh_batch

    def batch(user)
      outer = Thread.current[BATCH_KEY]
      return yield if outer && outer[:user_id] == user.id

      Thread.current[BATCH_KEY] = { user_id: user.id, dirty: false }
      begin
        yield
      ensure
        active = Thread.current[BATCH_KEY]
        Thread.current[BATCH_KEY] = outer
        refresh!(user) if active && active[:dirty]
      end
    end

    def mkdir(user, parent_node_id: nil, name: nil)
      existing = user.nodes.present.find_by(parent_node_id:, name:, kind: "dir")
      return file_info(existing) if existing

      destination_vacant!(user, parent_node_id, name)
      node_id = SecureRandom.uuid
      transport(user).post("/v1/nodes", { node_id:, parent_node_id:, name:, mode: 0o755,
                                          mtime: (Time.current.to_f * 1e9).to_i })
      refresh!(user)
      stat(user, node_id:)
    end

    # THE ONE CALLER OF `#refresh_or_defer!` -- DELIBERATELY NOT `mkdir`/`delete`/`undelete`/
    # `finalize_upload` TOO, which would be the more "uniform" reading of #batch's job. Those four
    # all hand a caller state read back IMMEDIATELY, in the same call, from the very mirror row
    # `#refresh!` is what creates or updates: `mkdir`'s only production caller,
    # Maker::LibraryFolder#ensure_segment, does `info = mkdir(...); user.nodes.find_by!(node_id:
    # info.node_id)` right after -- a query against a row that, for a freshly-created folder, exists
    # NOWHERE ELSE until a pull applies it (RefreshAfterWriteTest's "mkdir returns state the server
    # reported, which only a pull could have supplied" pins exactly this, with the local database
    # starting empty). Deferring that pull would turn an ordinary new category folder, created
    # mid-sweep the first time a project sees a category it has not filed before, into an
    # ActiveRecord::RecordNotFound.
    #
    # `move` has no equivalent reader. Its return value is discarded by every caller today,
    # including Maker::MoveNode#apply_move -- whose own comment says outright that the RELOAD is
    # the return value: `node.reload` reads the local mirror directly rather than trusting what
    # this method hands back, so a `stat` answering pre-move state while a batch is still open is a
    # value nothing consumes, not a silent wrong answer something acts on. That is what makes
    # deferring safe here and only here -- it is not merely "the call this arc's test happens to
    # cover."
    def move(user, node_id: nil, new_parent_node_id: nil, new_name: nil)
      live_node!(user, node_id)
      destination_vacant!(user, new_parent_node_id, new_name, except_node_id: node_id)
      transport(user).post("/v1/nodes/#{node_id}/move",
                           { new_parent_node_id:, new_name: })
      refresh_or_defer!(user)
      stat(user, node_id:)
    end

    # Returns nil, matching Chunk. `dir_deletable` is true because the server's SubtreeDelete
    # cascades the whole subtree in one call exactly as it does in-process -- the cascade is the
    # server's, so remote mode inherits it rather than reimplementing it.
    def delete(user, node_id: nil)
      live_node!(user, node_id)
      transport(user).delete("/v1/nodes/#{node_id}")
      refresh!(user)
      nil
    end

    # NotFound for a node that never existed, matching Chunk -- and note it checks `exists?`, NOT
    # `present`, because the node being deleted is the whole precondition.
    def undelete(user, node_id: nil)
      user.nodes.exists?(node_id:) || raise(NotFound, "node #{node_id.inspect} does not exist")
      transport(user).post("/v1/trash/#{node_id}/restore", {})
      refresh!(user)
      stat(user, node_id:)
    end

    # ── THE TWO-PHASE UPLOAD ─────────────────────────────────────────────────────────────────
    #
    # THIS IS WHERE §15 IS EARNED IN REMOTE MODE. `begin_upload` asks the sync server to presign PUT
    # URLs for whichever chunks it is missing; the CALLER puts the bytes straight at storage and then
    # finalizes. Neither this app nor the sync server ever holds a byte -- which is exactly the flow
    # `port_writable: false` selects in the UI, and why "cannot accept uploads" is the wrong reading
    # of that flag (§14a).
    #
    # `device:` IS ACCEPTED AND UNUSED, DELIBERATELY. The port hands it over because Chunk needs one
    # to attribute the commit; here the server derives the device from the bearer token this app
    # authenticates with, so passing ours would be telling the server about a device it does not
    # have. Dropping the kwarg instead would break the shared port signature for every caller.
    def begin_upload(user, name:, size:, manifest:, device: nil, parent_node_id: nil,
                     node_id: nil, base_version_id: nil, mtime: nil, mode: nil)
      node_id ||= SecureRandom.uuid
      body = transport(user).post("/v1/commit", {
        commit_id: SecureRandom.uuid, node_id:, parent_node_id:, name:, base_version_id:,
        size:, mtime: mtime || (Time.current.to_f * 1e9).to_i, mode:, manifest:
      })

      UploadBegun.new(commit_id: body["commit_id"], node_id:,
                      put_urls: body["put_urls"] || {}, missing: Array(body["missing"]))
    end

    # WRITES ONE CHUNK'S BYTES -- `FileLayer::Chunk#put_chunk`'s remote sibling, and the reason
    # `#put_chunk` is a PORT VERB rather than a helper either caller could share. Arc B Task 2:
    # before this existed, `Maker::Addons::LibraryOutput` called
    # `Sync::Storage::ChunkStore.current.put` directly -- CLAUDE.md §14c's one sanctioned
    # chunk-internals reference, and a `NameError` on any deployment (this one included) that does
    # not load the sync engine. Every addon save on chunk_remote raised, measured against a live
    # standalone server.
    #
    # THE TWO ADAPTERS CANNOT SHARE ONE IMPLEMENTATION, which is the whole argument for a port verb
    # instead of a shared helper. On EMBEDDED chunk, a presigned URL for the memory or local store
    # points BACK AT THIS SAME RAILS PROCESS (`DevBlobsController` -- there is no off-box store to
    # presign to locally), so a server-side PUT to it would be a LOOPBACK call into the same Puma
    # pool: CLAUDE.md §14e's recorded reentrancy bug, measured at 14-24 second stalls and outright
    # 404s. That is why `FileLayer::Chunk#put_chunk` writes its store IN-PROCESS instead of PUTting
    # to a URL of its own. On chunk_remote there is no in-process store to write -- the presigned
    # URL always points at the STANDALONE sync server's object storage, never at this app -- so an
    # ordinary outbound HTTP PUT is not merely safe here, it is the only way these bytes can move
    # without this app becoming a relay for them (§15). Only the ADAPTER knows which situation it
    # is in; the caller (`Maker::Addons::LibraryOutput`) must not have to.
    #
    # `begun:` is the SAME `UploadBegun` `#begin_upload` already returned to the caller -- this
    # reads `put_urls`, the field `Chunk#put_chunk` has no use for (it reads `hash` straight
    # against its own store instead). One signature across the port, each adapter reading the part
    # it needs, matching how `device:`/`broadcast:` are accepted-and-unused on the arms that don't
    # need them.
    #
    # `.fetch(hash)` is bare and UNRESCUED on purpose: `begin_upload`'s own contract
    # (`FileLayer::UploadBegun`'s header) guarantees `put_urls` is keyed by exactly the entries in
    # `missing`, and every production caller iterates `missing` to get `hash` in the first place
    # (see `Maker::Addons::LibraryOutput#write_chunk`) -- so a miss here is a caller passing a hash
    # that was never in `missing`, a LOCAL contract violation, not a wire condition to translate
    # into the port's vocabulary the way `#fetch_chunk` (the download side) does for a hash the
    # SERVER legitimately declined to presign.
    def put_chunk(_user, begun:, hash:, bytes:)
      @chunk_fetch.put(begun.put_urls.fetch(hash), bytes)
    end

    # `broadcast:` IS ACCEPTED AND UNUSED for the same reason `device:` is: the SERVER broadcasts to
    # the devices attached to it when the commit lands, and this app is one of those devices rather
    # than the thing doing the notifying. Maker::Addons::LibraryOutput passes `broadcast: false`
    # (§14a) and gets what it asked for either way -- there is nothing here to suppress.
    def finalize_upload(user, commit_id:, verify: true, broadcast: true)
      body = transport(user).post("/v1/commit/#{commit_id}/finalize", { verify: })
      version_id = body["version_id"]
      refresh!(user)

      # FINDS THE NODE BY THE VERSION THE SERVER JUST MADE, not by a commit_id this app would have to
      # remember. The mirror has just been pulled, so `current_version_id` is the server's own answer
      # to "which node did that commit belong to" -- one fewer piece of local state to keep correct.
      node = user.nodes.present.find_by(current_version_id: version_id)
      UploadFinalized.new(version_id:, seq: body["seq"], info: node ? file_info(node) : nil)
    end
    #
    # `mkdir`, `move`, `delete`, `undelete`, `begin_upload` and `finalize_upload` each already have
    # a server endpoint (design §6) and are the next piece. `write` will never appear: chunk-family
    # backends are not `port_writable`, and an upload goes through the two-phase presigned pair.
    #
    # They are left UNDEFINED rather than stubbed to raise. A stub answering NotFound would be a lie
    # about a file that exists, and NotImplementedError is a ScriptError that `rescue => e` does not
    # catch (§14a). Undefined means an incomplete adapter fails loudly as exactly what it is -- and
    # it cannot be reached anyway: FileLayer.build has no arm for it.

    private

    def manifest_for(user, version_id)
      return [] if version_id.blank?

      RemoteManifestChunk.where(user_id: user.id).for_version(version_id).to_a
    end

    # ONE ROUND TRIP FOR THE WHOLE FILE, not one per chunk. The endpoint takes an array and answers
    # a hash, and a 40-chunk file would otherwise be 40 sequential requests before the first byte.
    def presign(user, hashes)
      body = transport(user).post("/v1/chunks/download", { hashes: hashes.uniq })
      body["urls"] || {}
    end

    # A HASH THE SERVER DECLINED TO PRESIGN IS NotFound, NOT a nil that concatenates into a
    # silently-short file. `manifest#download` omits any hash the user does not own, so an absent URL
    # means the chunk is gone or was never ours -- and a truncated download that reports success is
    # exactly the failure §14a records for a multi-chunk redirect.
    def fetch_chunk(chunk, urls)
      url = urls[chunk.chunk_hash]
      raise NotFound, "sync server did not presign chunk #{chunk.chunk_hash}" if url.blank?

      bytes = @chunk_fetch.get(url)
      raise NotFound, "chunk #{chunk.chunk_hash} could not be fetched" if bytes.nil?

      bytes
    end

    # `#move`'S OWN DEFERRAL CHECK, KEPT OUT OF `#refresh!` ITSELF SO `#refresh!` STAYS THE ONE
    # THING EVERY OTHER CALLER CAN TRUST TO BE UNCONDITIONAL -- see `#move`'s own comment for why
    # mkdir/delete/undelete/finalize_upload must NOT get this treatment. Marks the open batch dirty
    # and returns without touching the network when one is open for THIS user; otherwise behaves
    # exactly as `#refresh!` always has. Outside any `#batch` call `Thread.current[BATCH_KEY]` is
    # nil, so every existing caller -- RefreshAfterWriteTest, the mutation contract, every
    # `adapter.move` in the shared adapter suites -- sees IDENTICAL behaviour to before this method
    # existed.
    def refresh_or_defer!(user)
      batch = Thread.current[BATCH_KEY]
      if batch && batch[:user_id] == user.id
        batch[:dirty] = true
      else
        refresh!(user)
      end
    end

    # PULLS THE CHANGELOG AFTER A WRITE, so the local mirror reflects what the server actually did
    # rather than what we asked for. It is also what makes the returned FileInfo trustworthy: `stat`
    # reads the mirror, so without this it would answer from the state before our own mutation.
    def refresh!(user)
      ChangelogSync.new(user, transport: transport(user)).call
    end

    # The same rule Chunk enforces, against the mirror. `except_node_id` is what makes a move onto a
    # node's OWN current name a no-op rather than a self-collision -- the defect §14a records for
    # Share and S3, which both shipped it.
    def destination_vacant!(user, parent_node_id, name, except_node_id: nil)
      taken = user.nodes.present.where(parent_node_id:, name:)
      taken = taken.where.not(node_id: except_node_id) if except_node_id
      return unless taken.exists?

      raise UnsupportedOperation, "#{name.inspect} already exists in that folder"
    end

    def live_node!(user, node_id)
      user.nodes.present.find_by(node_id:) ||
        raise(NotFound, "node #{node_id.inspect} is deleted or does not exist")
    end

    # `content_token` IS THE VERSION ID, matching Chunk exactly. It has to: the token is what a
    # caller hands back to `read`, and what maker_previews stores to decide whether an artifact is
    # stale. A different spelling here would silently invalidate every preview on a deployment that
    # switched to chunk_remote.
    def file_info(node)
      FileInfo.new(
        node_id: node.node_id, name: node.name, kind: node.kind,
        size: node.size.to_i, mtime: node.mtime, content_token: node.current_version_id
      )
    end

    # ARC C TASK 4 -- PER-USER, AND DELIBERATELY NOT MEMOIZED ON `self`. This used to be
    # `@transport ||= Transport.new(token: ENV.fetch("CHUNK_REMOTE_TOKEN"))` -- one token, shared by
    # every request, because there was only ever one device in the whole deployment. That is THE
    # DEFECT this arc closes (this file's own header, and CLAUDE.md §14a): `FileLayer.current` is
    # ONE adapter instance shared by every Puma thread (`FileLayer.current ||= build`), so an ivar
    # memo here is not a per-request cache, it is PROCESS-WIDE STATE -- the first user to call this
    # method after boot would decide the token every OTHER user's request uses until the process
    # restarts. Two maker users would share one remote library and see each other's files, which is
    # a cross-tenant credential leak, not a correctness nit.
    #
    # THE FIX IS NOT `Thread.current`, EVEN THOUGH `#batch` ABOVE USES EXACTLY THAT FOR A SIMILAR-
    # LOOKING PROBLEM. `#batch`'s frame exists to COALESCE STATE ACROSS SEVERAL CALLS within one
    # logical operation (deferring `refresh!` until a batch closes) -- there is real work to cache.
    # A per-user Transport has NOTHING to cache: `Transport.new` is four ivar assignments and opens
    # no connection (every request it makes is its own fresh `Net::HTTP.start` block, in
    # transport.rb), so building one fresh on every call costs nothing measurable. Thread-local
    # memoization would ALSO be strictly worse here, not merely unnecessary: Puma reuses threads
    # across unrelated requests, so a `Thread.current`-cached transport would go on serving a LATER
    # request for a DIFFERENT user with the FIRST user's token until that specific thread happened
    # to rotate back to the first user -- a smaller, sneakier version of the same leak, and one that
    # would also serve a since-rotated token forever. Building fresh every time has no cache to go
    # stale and no shared slot for a second user to land in. (This is also why the mutation-check
    # for this method is "put `@transport ||=` back", not "add a wrong kind of cache": ANY caching
    # keyed on less than the user is the shape of the bug, `Thread.current` included.)
    #
    # `@transport` (the CONSTRUCTOR-INJECTED value, note: NOT the old ivar this replaced -- same
    # name, different job) IS THE ONE EXCEPTION, and it stays exactly as unconditional as it always
    # was: a test that injects a transport gets THAT OBJECT for every user, on purpose, so every
    # existing test in this tree that never touches per-user resolution at all keeps working
    # unchanged. See this class's own constructor comment for why that is the right contract rather
    # than a gap.
    def transport(user)
      return @transport if @transport

      Transport.new(base_url: ENV.fetch("CHUNK_REMOTE_URL"), token: device_token_for(user))
    end

    # Reads this user's own device token, provisioning a fresh remote library on their first write
    # if they have never had one (Arc C Task 5; FileLayer::ChunkRemote::Provisioning). `.presence`,
    # not a bare read: `sync_device_token` is nil until provisioned, never "".
    def device_token_for(user)
      user.sync_device_token.presence || provisioning.call(user)
    end

    # MEMOIZED ON `self`, AND THIS ONE IS SAFE TO BE -- the distinction from `@transport`/
    # `Thread.current` above is worth stating explicitly rather than trusting a reader to rederive
    # it. `Provisioning` holds no PER-USER state of its own: its one lazily-built collaborator (the
    # admin transport) carries SYNC_ADMIN_TOKEN, a single deployment-wide operator credential that
    # is, BY DESIGN, the same value for every user this process ever provisions -- unlike a device
    # token, there is no "whose admin token is it" question for a shared instance to get wrong.
    # Every call still takes `user` as an argument and reads/writes THAT row; nothing here is
    # cached per-user.
    def provisioning
      @provisioning ||= Provisioning.new
    end
  end
end
