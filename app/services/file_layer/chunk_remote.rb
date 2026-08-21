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
