module Maker
  # An in-memory index of one user's live DIRECTORY nodes, built with ONE pluck.
  #
  # WHY IT EXISTS: Maker::ModelIntake has to ask "what is the nearest shelf above this file" for
  # every model-role file in the library. Walking parent_node_id per file is a query per level per
  # file. Dirs are a small fraction of any library, so loading all of them once and walking in
  # memory makes the sweep's query count constant in the number of files.
  #
  # IT READS `nodes`, THE CATALOG ALL THREE BACKENDS POPULATE, and touches the port not at all.
  class LibraryTree
    Entry = Data.define(:node_id, :parent_node_id, :name)

    def initialize(user)
      rows = user.nodes.present.where(kind: "dir")
                 .pluck(:node_id, :parent_node_id, :name)
      @dirs = rows.to_h { |id, parent, name| [ id, Entry.new(node_id: id, parent_node_id: parent, name:) ] }
      @paths = {}
    end

    # Every live dir the user owns. THE PICKER'S SET, so a caller that already holds a tree never
    # needs a second `where(kind: "dir")` pluck to enumerate the same rows this one indexed.
    def dir_ids = @dirs.keys

    # The dir Entries directly under one dir (nil = the library root). Built ONCE, lazily, from the
    # rows the constructor already plucked — a second `where(parent_node_id:)` per level is exactly
    # the per-file query this class exists to avoid. Order is the pluck's; callers that care sort.
    def children_of(node_id)
      @children ||= @dirs.values.group_by(&:parent_node_id)
      @children.fetch(node_id, [])
    end

    # "" for the library root (node_id nil). nil when the chain is broken -- a tombstoned or
    # missing ancestor, or a cycle. NIL IS AN ANSWER, NOT AN ERROR: a caller sweeping a whole
    # library must skip an unresolvable node, not abort the pass over the other ten thousand.
    #
    # MEMOIZED, AND THE MEMO'S SHAPE IS THE WHOLE RISK. Resolve the chain FIRST, then write the
    # answer for every id the walk visited at once -- never per hop. A per-hop write caches a
    # PARTIAL PREFIX, so a folder whose grandparent is tombstoned reads back as a top-level folder
    # that does not exist: the same quiet-wrong-path failure the sentinel comment below describes,
    # arriving through the cache instead. Every id on one walk shares that walk's suffix, so on
    # success each gets its own path and on `:broken` every one of them gets nil.
    def path_for(node_id)
      return @paths[node_id] if @paths.key?(node_id)

      segments = []
      visited  = []
      broken   = false
      each_ancestor(node_id) do |entry|
        # BOTH CALLERS MUST CHECK THE SENTINEL, AND FORGETTING IT FAILS QUIETLY HERE. `:broken`
        # answers `.name` too (Ruby 3+), so an unchecked sentinel becomes an ordinary-looking path
        # segment rather than an error -- a wrong path, silently. In ancestors_of the same omission
        # raises NoMethodError instead. Both are mutation-checked.
        if entry == :broken
          broken = true
          next
        end

        visited << entry.node_id
        segments.unshift(entry.name)
      end

      if broken
        visited.each { |id| @paths[id] = nil }
        return @paths[node_id] = nil
      end

      # visited runs nearest-first and segments furthest-first, so the i-th visited id owns the
      # first (size - i) segments -- its OWN path, not the leaf's.
      visited.each_with_index { |id, i| @paths[id] = segments.first(segments.size - i).join("/") }
      @paths[node_id] = segments.join("/")
    end

    # Nearest-first, ending with nil for the library root: ["d-parts", "d-enc", "d-models", nil].
    # An unresolvable chain answers nil, for the same reason path_for does.
    def ancestors_of(node_id)
      out = []
      each_ancestor(node_id) do |entry|
        return nil if entry == :broken

        out << entry.node_id
      end
      out << nil
      out
    end

    def dir?(node_id) = @dirs.key?(node_id)

    # The LEAF name of one dir, nil for an id this index does not hold. For the one caller that
    # cannot skip an unresolvable chain (Tools::LibraryFolders' picker) and needs something to
    # label the folder with anyway; nil is how it tells "a folder with a broken chain" from "not a
    # folder of this user's at all", which are different answers on that surface.
    def name_of(node_id) = @dirs[node_id]&.name

    # The PARENT of one dir: nil for a dir at the library root, and nil for an id this index does not
    # hold. One step at a time, for a caller whose walk must STOP at a dir it knows rather than reach
    # the root. `#ancestors_of` answers nil for the whole chain when ANY ancestor is missing,
    # including one above the dir that caller stops at (Maker::PublicProject.depth_one_dir).
    def parent_of(node_id) = @dirs[node_id]&.parent_node_id

    private

    # Climbs parent_node_id, yielding each dir Entry nearest-first, stopping at the root. Yields
    # :broken exactly once instead if the chain hits a missing dir or revisits a node -- a cycle is
    # unrepresentable on a mount but perfectly representable in a row set, and an unguarded walk
    # HANGS the sweep rather than failing it.
    def each_ancestor(node_id)
      seen = Set.new
      current = node_id
      while current
        return yield(:broken) if seen.include?(current)

        seen << current
        entry = @dirs[current]
        return yield(:broken) unless entry

        yield entry
        current = entry.parent_node_id
      end
    end
  end
end
