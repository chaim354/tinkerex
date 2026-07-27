module Maker
  # Move a library node to a new parent (optionally under a new name), whichever way THIS
  # deployment holds its bytes.
  #
  # THE ONE PLACE the cross-backend move branch lives — the sibling of Maker::LibraryFolder, and
  # written to be read next to it:
  #   port_writable? (share/s3) → FileLayer.current.move — renames the real file/object AND
  #                               updates the node row (see FileLayer::Share#move).
  #   else            (chunk)   → Sync::Mutation.apply(op: "move") — the door Chunk::MOVE_MSG
  #                               names and the one V1::NodesController#move already uses.
  # Controllers call this and never reach into Sync:: or the port themselves; that seam is what
  # keeps the maker/file-layer split's §10 boundary honest.
  #
  # THE node_id NEVER CHANGES. That is the port's stated promise and the whole reason a move is
  # safe to perform on the user's behalf: every project attachment, BOM link and tag keeps
  # pointing at the same file.
  #
  # COLLISION IS DETECTED HERE, IN THE CATALOG, BEFORE EITHER DOOR IS OPENED, and it is a raise
  # rather than a clobber. Both port adapters already refuse to replace (Share#move raises
  # UnsupportedOperation, "…already exists"), but chunk mode has no such guard — Sync::Mutation
  # would happily create two live siblings with one name. Checking `nodes` is the only check that
  # is true on all three backends, and it is the catalog every backend actually reads.
  #
  # WHAT THIS DOES NOT CHECK, stated so it is not mistaken for covered: a CYCLE — moving a
  # directory under one of its own descendants. Every caller today moves a FILE (a file has no
  # descendants, so it cannot be its own ancestor), which is why the guard is absent rather than
  # forgotten. The first caller that can pass a `dir` must bring one: V1::NodesController#move has
  # `would_create_cycle?`, and the reason it is not optional there is that an uncaught cycle makes
  # the WITH RECURSIVE search CTE spin unboundedly — fatal on SQLite, which has no statement
  # timeout.
  class MoveNode
    # A live node already holds the destination name. The caller decides what to do about it —
    # the attach flow turns it into the "rename or leave it" prompt.
    Collision = Class.new(StandardError)

    MAX_SUGGESTIONS = 9

    def self.call(user, node:, new_parent_node_id:, new_name: nil)
      new(user).call(node:, new_parent_node_id:, new_name:)
    end

    # The first free "<base> (n)<ext>" under `parent_node_id`, or nil if every variant up to
    # MAX_SUGGESTIONS is taken. Lives here because collision naming is this class's knowledge; the
    # conflict prompt reads it to label its button.
    def self.available_name(user, parent_node_id:, name:)
      ext  = File.extname(name)
      base = File.basename(name, ext)
      taken = user.nodes.present.where(parent_node_id:).pluck(:name).to_set
      (2..MAX_SUGGESTIONS).each do |i|
        candidate = "#{base} (#{i})#{ext}"
        return candidate unless taken.include?(candidate)
      end
      nil
    end

    def initialize(user)
      @user = user
      @port_writable = FileLayer.current.capabilities.port_writable?
    end

    def call(node:, new_parent_node_id:, new_name: nil)
      name = new_name.presence || node.name
      leaf!(name)
      collision!(node, new_parent_node_id, name)

      @port_writable ? port_move(node, new_parent_node_id, name) : chunk_move(node, new_parent_node_id, name)
      node
    end

    private

    # A name is a single path segment. The port adapters check this themselves (leaf!), but the
    # chunk door does not, and a name with a slash there would put a separator inside a node's
    # `name` column — a path that exists in no tree and that no mount can reproduce.
    def leaf!(name)
      return if name.present? && !name.include?("/") && !name.include?("\0") &&
                name != "." && name != ".."

      raise ArgumentError, "#{name.inspect} is not a valid file name"
    end

    # `where.not(node_id:)` is what makes a no-op move (already in the folder, same name) legal
    # rather than a collision with itself. Tombstones are excluded by `.present` — a deleted
    # sibling holds no name.
    def collision!(node, parent_node_id, name)
      taken = @user.nodes.present.where(parent_node_id:, name:)
                   .where.not(node_id: node.node_id).exists?
      raise Collision, name if taken
    end

    # share/s3: the port owns the store, so it renames the bytes and writes the row.
    def port_move(node, new_parent_node_id, name)
      FileLayer.current.move(@user, node_id: node.node_id,
                             new_parent_node_id:, new_name: name)
      node.reload
    end

    # chunk: the sync engine owns the tree (the port refuses move). Mirrors
    # V1::NodesController#move, broadcast included — a device following the changelog has to hear
    # about this or its tree diverges from the server's.
    def chunk_move(node, new_parent_node_id, name)
      seq = Sync::Mutation.apply(user: @user, node:, op: "move") do |n|
        n.parent_node_id = new_parent_node_id
        n.name = name
      end
      LibraryChannel.broadcast_change(@user, seq)
      node
    end
  end
end
