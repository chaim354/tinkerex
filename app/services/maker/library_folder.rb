module Maker
  # Ensure a library folder PATH exists and return its leaf dir Node, find-or-creating each segment.
  #
  # ONE DOOR, on every backend: FileLayer.current.mkdir per missing segment — controllers/models
  # call this and never touch Sync:: or the port's mkdir directly (that seam is what keeps §10
  # honest). Until Stage 2 this class branched here too (port_writable? (share/s3) called the
  # port; chunk mode called Sync::Mutation.apply(op: "mkdir") inline, mirroring
  # V1::NodesController#mkdir) because the port refused mkdir in chunk mode. It no longer does —
  # Chunk#mkdir now delegates to the sync engine itself — so the branch has nothing left to decide.
  #
  # Every adapter's mkdir is idempotent, so an already-existing folder is reused, not duplicated —
  # which is what lets this be called repeatedly (once per project-create, again per upload)
  # without minting a duplicate directory.
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

    # ONE DOOR. This used to branch on port_writable? -- one of the five copies CLAUDE.md 14d
    # counts -- because the port refused mkdir in chunk mode. It no longer does, so the branch
    # has nothing left to decide.
    def ensure_segment(parent_node_id, name)
      info = FileLayer.current.mkdir(@user, parent_node_id:, name:)
      @user.nodes.find_by!(node_id: info.node_id)
    end
  end
end
