module Maker
  # Ensure a library folder PATH exists and return its leaf dir Node, find-or-creating each segment.
  #
  # THE ONE PLACE the cross-backend folder-creation branch lives — controllers/models call this and
  # never touch Sync:: or the port's mkdir directly (that seam is what keeps §10 honest):
  #   port_writable? (share/s3) → FileLayer.current.mkdir per missing segment
  #   else (chunk)              → Sync::Mutation.apply(op: "mkdir") per missing segment — the same
  #                               sync-engine door V1::NodesController#mkdir and the web upload use.
  #
  # "Find" is by (parent_node_id, name, kind) against `nodes.present`, the shared catalog on every
  # backend — so an already-existing folder is reused, not duplicated (this is called repeatedly:
  # once per project-create, again per upload).
  class LibraryFolder
    def self.ensure_path!(user, segments)
      new(user).ensure_path!(segments)
    end

    def self.create_child!(user, parent_node_id:, name:)
      new(user).create_child!(parent_node_id:, name:)
    end

    def initialize(user)
      @user = user
      @port_writable = FileLayer.current.capabilities.port_writable?
    end

    def ensure_path!(segments)
      parent = nil # nil = library root
      segments.each { |name| parent = ensure_segment(parent&.node_id, name) }
      parent
    end

    # Create (or find) ONE child dir under `parent_node_id` (nil = library root). The single-segment
    # sibling of ensure_path!, for the chooser's "New Folder" — same cross-backend branch, one segment.
    def create_child!(parent_node_id:, name:)
      ensure_segment(parent_node_id, name)
    end

    private

    def ensure_segment(parent_node_id, name)
      existing = @user.nodes.present.find_by(parent_node_id:, name:, kind: "dir")
      return existing if existing

      @port_writable ? port_mkdir(parent_node_id, name) : chunk_mkdir(parent_node_id, name)
    end

    # share/s3: the port owns the store, so mkdir creates the real dir/marker + the dir node.
    def port_mkdir(parent_node_id, name)
      info = FileLayer.current.mkdir(@user, parent_node_id:, name:)
      @user.nodes.find_by!(node_id: info.node_id)
    end

    # chunk: the sync engine owns the tree (the port refuses mkdir). Mirrors V1::NodesController#mkdir.
    def chunk_mkdir(parent_node_id, name)
      node = @user.nodes.new(
        node_id: SecureRandom.uuid, parent_node_id:, name:, kind: "dir",
        deleted: false, mode: 0o755, mtime: (Time.current.to_f * 1e9).to_i
      )
      seq = Sync::Mutation.apply(user: @user, node:, op: "mkdir")
      LibraryChannel.broadcast_change(@user, seq)
      node
    end
  end
end
