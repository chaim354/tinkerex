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
  # THE INPUT GUARDS BELOW EXIST BECAUSE ONLY ONE DOOR HAS ANY. The port resolves its own
  # arguments — Share#move takes a node_id through `live_node!` and a parent through
  # `parent_dir_rel!`, so a tombstoned source, a missing parent, a parent that is a FILE, and
  # another user's node all raise FileLayer::NotFound there. The chunk door is handed the object
  # and assigns the columns, so every one of those SUCCEEDS: it reparents under an id that may
  # exist on no device, and then broadcasts a changelog `move` telling every device to do the
  # same. A class whose whole job is to hide the difference between the doors cannot let them
  # disagree about what is valid, so the checks are here, before the branch, in the same class the
  # port already uses.
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

    # The requested name is not a single path segment (see #leaf!). An ArgumentError SUBCLASS, so
    # every existing `rescue ArgumentError` keeps catching it — but a caller that wants to answer
    # "that name is not allowed" can now do so WITHOUT also swallowing arity drift in a port
    # adapter, a kwarg rename in this class, or a nil reaching File.extname somewhere below.
    # Projects::AttachmentsController rescues this one and lets bare ArgumentError 500, which is
    # what a programming error should do; that distinction is only available because of this line.
    InvalidName = Class.new(ArgumentError)

    # The HIGHEST SUFFIX tried, not a count — `(2..HIGHEST_SUFFIX)` offers eight names, "(2)"
    # through "(9)". Named for the boundary rather than the quantity because the quantity is the
    # thing nobody can read off the loop, and the earlier name (MAX_SUGGESTIONS) claimed the one
    # that is wrong by one.
    HIGHEST_SUFFIX = 9

    def self.call(user, node:, new_parent_node_id:, new_name: nil)
      new(user).call(node:, new_parent_node_id:, new_name:)
    end

    # The first free "<base> (n)<ext>" under `parent_node_id`, or nil if every suffix up to
    # HIGHEST_SUFFIX is taken. Lives here because collision naming is this class's knowledge; the
    # conflict prompt reads it to label its button.
    def self.available_name(user, parent_node_id:, name:)
      ext  = File.extname(name)
      base = File.basename(name, ext)
      taken = user.nodes.present.where(parent_node_id:).pluck(:name).to_set
      (2..HIGHEST_SUFFIX).each do |i|
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
      own_live_node!(node)
      live_dir!(new_parent_node_id)
      leaf!(name)
      collision!(node, new_parent_node_id, name)

      @port_writable ? port_move(node, new_parent_node_id, name) : chunk_move(node, new_parent_node_id, name)
      node
    end

    private

    # The source must be THIS user's, and live.
    #
    # `call` takes a node OBJECT while the port takes a node_id, and that difference is the whole
    # hole: the port's lookup is user-scoped, so another tenant's id is simply not there, whereas
    # an object arrives already loaded and no scope is consulted. Handed one, the chunk door
    # mutates the victim's row AND appends the changelog entry to the CALLER's log — so the
    # victim's devices are never told, and their trees diverge from the server's permanently.
    # (Maker::LibraryFolder, the model for this class, cannot be misused this way: it takes a user
    # and path segments, and looks everything else up itself.)
    #
    # NotFound rather than ArgumentError, though a foreign node IS a caller error: it is the class
    # the port already answers for this input, and FilesController maps it to a 404 — which is the
    # right thing to tell someone holding another tenant's id. The tombstone case is NotFound for
    # the plainer reason that a deleted node is gone on every backend.
    def own_live_node!(node)
      unless node.user_id == @user.id
        raise FileLayer::NotFound, "node #{node.node_id.inspect} does not belong to this user"
      end
      return unless node.deleted?
      raise FileLayer::NotFound, "node #{node.node_id.inspect} is deleted"
    end

    # nil means THE LIBRARY ROOT — a real destination on every backend, with nothing to look up.
    # Anything else must be a live DIRECTORY of this user's, which is exactly what the share door's
    # `parent_dir_rel!` enforces and the chunk door does not: without this, a typo'd or stale
    # parent id reparents the node under something no device has, and the broadcast tells every
    # device to do the same. A parent naming a FILE is the same failure wearing a valid id.
    def live_dir!(parent_node_id)
      return if parent_node_id.blank?
      return if @user.nodes.present.exists?(node_id: parent_node_id, kind: "dir")
      raise FileLayer::NotFound, "parent #{parent_node_id.inspect} is not a live directory"
    end

    # A name is a single path segment. The port adapters check this themselves (leaf!), but the
    # chunk door does not, and a name with a slash there would put a separator inside a node's
    # `name` column — a path that exists in no tree and that no mount can reproduce.
    def leaf!(name)
      return if name.present? && !name.include?("/") && !name.include?("\0") &&
                name != "." && name != ".."

      raise InvalidName, "#{name.inspect} is not a valid file name"
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
    #
    # THE RELOAD IS THE RETURN VALUE, not tidiness. The port resolves the node_id into its OWN
    # instance and updates that, so the caller's object still holds the pre-move name, parent and
    # storage_path — while the chunk door assigns the caller's object in place. Without this the
    # two doors return different things for the same call, and a caller who renders `node.name`
    # after a rename (a flash, a turbo frame) prints the OLD name on share/s3 only.
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
    end
  end
end
