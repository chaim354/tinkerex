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
    CAPABILITIES = Capabilities.new(
      versioned: true, syncable: true, presignable: true,
      scannable: false, port_writable: false, dir_deletable: true
    ).freeze

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

    # ── BYTE READS ARE NOT HERE YET, AND THE ABSENCE IS DELIBERATE ────────────────────────────
    #
    # `read` and `download` need a MANIFEST -- the chunk hashes and offsets that
    # POST /v1/chunks/download turns into presigned URLs. Manifests arrive in /v1/changes and
    # /v1/tree payloads, and ChangelogSync currently discards them; persisting them locally is a
    # schema addition and its own piece of work. There is no per-node manifest endpoint to fetch one
    # on demand (checked against `bin/rails routes`), and inventing one would break the design's
    # "zero new sync-server endpoints".
    #
    # They are left UNDEFINED rather than stubbed to raise. A stub that answers NotFound would be a
    # lie about a file that exists, and one that raises NotImplementedError would be a ScriptError
    # that `rescue => e` does not catch (§14a). Undefined means an incomplete adapter fails loudly
    # as exactly what it is -- and it cannot be reached anyway: FileLayer.build has no arm for it.

    private

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
