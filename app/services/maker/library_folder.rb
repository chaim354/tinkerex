module Maker
  # Ensure a library folder PATH exists and return its leaf dir Node, find-or-creating each segment.
  #
  # ONE DOOR, on every backend, for a MISSING segment: FileLayer.current.mkdir — controllers/models
  # call this and never touch Sync:: or the port's mkdir directly (that seam is what keeps §10
  # honest). Until Stage 2 this class branched here too (port_writable? (share/s3) called the
  # port; chunk mode called Sync::Mutation.apply(op: "mkdir") inline, mirroring
  # V1::NodesController#mkdir) because the port refused mkdir in chunk mode. It no longer does —
  # Chunk#mkdir now delegates to the sync engine itself — so that branch has nothing left to
  # decide, and it stays gone.
  #
  # An ALREADY-EXISTING segment — the dominant case at every real call site, since this is called
  # repeatedly (once per project-create, again per upload, once per unique subfolder in a bulk
  # import) — never reaches the port at all: ensure_segment short-circuits on its own catalog
  # lookup first. See ensure_segment for why that is load-bearing and not a leftover.
  class LibraryFolder
    def self.ensure_path!(user, segments)
      new(user).ensure_path!(segments)
    end

    def self.create_child!(user, parent_node_id:, name:)
      new(user).create_child!(parent_node_id:, name:)
    end

    def initialize(user)
      @user = user
    end

    def ensure_path!(segments)
      parent = nil # nil = library root
      segments.each { |name| parent = ensure_segment(parent&.node_id, name) }
      parent
    end

    # Create (or find) ONE child dir under `parent_node_id` (nil = library root). The single-segment
    # sibling of ensure_path!, for the chooser's "New Folder" — same one door, one segment.
    def create_child!(parent_node_id:, name:)
      ensure_segment(parent_node_id, name)
    end

    private

    # ONE DOOR to the PORT, once a segment is missing. This used to branch on port_writable? --
    # one of the five copies CLAUDE.md 14d counts -- because the port refused mkdir in chunk mode.
    # It no longer does, so THAT branch has nothing left to decide, and stays gone.
    #
    # THE EXISTENCE CHECK BELOW IS NOT THAT BRANCH BACK, AND IT IS NOT A SECOND COPY OF THE
    # ADAPTER'S OWN IDEMPOTENCE CHECK -- it is here for query cost, not correctness. Every
    # adapter's mkdir is ALREADY idempotent (Chunk/Share/S3 each look an existing dir up
    # themselves), so this class would still be correct without it. It is not fast without it:
    # skipping straight to FileLayer.current.mkdir makes the caller pay for a port round trip --
    # and, once the chunk backend moves out of this process, an HTTP one -- on the path taken on
    # almost every call, since the dominant case at every real call site is that the segment
    # ALREADY EXISTS (ModelsController#ensure_folders walks this once per unique subfolder in a
    # bulk import; Maker::ProjectIntake#place calls it from inside the eager nudge, whose own
    # EAGER_MAX_MOVES cap already treats latency here as tight enough to bound separately). Measured
    # on a 2-segment already-exists walk: dropping this cost 2 queries -> 4 on chunk, 2 -> 7 on
    # share/s3 (the port's own idempotence lookup, PLUS this method's find_by! re-fetch on top of
    # it, for every segment). See library_folder_test.rb's query-cost guard, which pins the
    # relationship rather than either backend's absolute count.
    def ensure_segment(parent_node_id, name)
      existing = @user.nodes.present.find_by(parent_node_id:, name:, kind: "dir")
      return existing if existing

      info = FileLayer.current.mkdir(@user, parent_node_id:, name:)
      @user.nodes.find_by!(node_id: info.node_id)
    end
  end
end
