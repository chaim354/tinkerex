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

    def initialize(transport: nil)
      @transport = transport
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

      urls = presign(manifest.map(&:chunk_hash))
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

      urls = presign(manifest.map(&:chunk_hash))
      Delivery::Stream.new(enum: Enumerator.new { |y| manifest.each { |c| y << fetch_chunk(c, urls) } })
    end

    # ── WRITES ARE NOT HERE YET, AND THE ABSENCE IS DELIBERATE ────────────────────────────────
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
    def presign(hashes)
      body = transport.post("/v1/chunks/download", { hashes: hashes.uniq })
      body["urls"] || {}
    end

    # A HASH THE SERVER DECLINED TO PRESIGN IS NotFound, NOT a nil that concatenates into a
    # silently-short file. `manifest#download` omits any hash the user does not own, so an absent URL
    # means the chunk is gone or was never ours -- and a truncated download that reports success is
    # exactly the failure §14a records for a multi-chunk redirect.
    def fetch_chunk(chunk, urls)
      url = urls[chunk.chunk_hash]
      raise NotFound, "sync server did not presign chunk #{chunk.chunk_hash}" if url.blank?

      bytes = ChunkFetch.get(url)
      raise NotFound, "chunk #{chunk.chunk_hash} could not be fetched" if bytes.nil?

      bytes
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

    # Built lazily rather than in the constructor so that merely naming this class -- which the
    # architecture guards and `bin/rails runner` both do -- never demands a URL or a token.
    def transport
      @transport ||= Transport.new(
        base_url: ENV.fetch("CHUNK_REMOTE_URL"),
        token: ENV.fetch("CHUNK_REMOTE_TOKEN")
      )
    end
  end
end
