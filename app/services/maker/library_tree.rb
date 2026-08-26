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
    end

    # "" for the library root (node_id nil). nil when the chain is broken -- a tombstoned or
    # missing ancestor, or a cycle. NIL IS AN ANSWER, NOT AN ERROR: a caller sweeping a whole
    # library must skip an unresolvable node, not abort the pass over the other ten thousand.
    def path_for(node_id)
      segments = []
      each_ancestor(node_id) do |entry|
        # BOTH CALLERS MUST CHECK THE SENTINEL, AND FORGETTING IT FAILS QUIETLY HERE. `:broken`
        # answers `.name` too (Ruby 3+), so an unchecked sentinel becomes an ordinary-looking path
        # segment rather than an error -- a wrong path, silently. In ancestors_of the same omission
        # raises NoMethodError instead. Both are mutation-checked.
        return nil if entry == :broken

        segments.unshift(entry.name)
      end
      segments.join("/")
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
