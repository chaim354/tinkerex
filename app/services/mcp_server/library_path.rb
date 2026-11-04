# frozen_string_literal: true

module McpServer
  # LIBRARY-RELATIVE PATHS, BOTH WAYS (spec §5). A model names a file or folder as
  # "Projects/lamp/README.md"; this resolves that to the live node, one query per segment, and
  # writes the path of a node it lists back from the folder it was asked about.
  #
  # REJECTS, NEVER NORMALISES: `.` and `..` are refused outright rather than resolved (§14a's
  # `key_for` rule -- a normalised `a/../b` is a valid path to the wrong file). Depth is capped so a
  # pathological path costs at most MAX_SEGMENTS queries.
  #
  # ONLY THE CATALOG IS READ. `nodes` is populated on every backend (§5), so this answers the same on
  # share, s3 and chunk_remote, and nothing here touches the port or the changelog (§2).
  module LibraryPath
    MAX_SEGMENTS = 32

    module_function

    def segments(path)
      segs = path.to_s.split("/").reject(&:empty?)
      if segs.any? { |s| s == "." || s == ".." }
        raise Refused, "A path is library-relative, like \"Projects/lamp/README.md\": no \".\" or \"..\" segments."
      end
      raise Refused, "That path is deeper than #{MAX_SEGMENTS} folders." if segs.size > MAX_SEGMENTS

      segs
    end

    # The live node at `path`; nil for the library root (a blank path or "/"). Raises NotFound for
    # anything that does not resolve, naming the path as given.
    def resolve!(user, path)
      node = nil
      segments(path).each do |name|
        node = user.nodes.present.find_by(parent_node_id: node&.node_id, name: name)
        raise NotFound, "No file or folder at #{path.to_s.inspect}." if node.nil?
      end
      node
    end

    # The normalised spelling of a path the model gave ("" for the root), so listings join on it.
    def normalize(path) = segments(path).join("/")

    def join(base, name) = base.empty? ? name : "#{base}/#{name}"

    # A node's path from the tree the caller built; nil when an ancestor is tombstoned or missing
    # (Maker::LibraryTree#path_for's "nil is an answer"), rendered as `path: null`, never guessed.
    def of(tree, node)
      parent = tree.path_for(node.parent_node_id)
      parent && join(parent, node.name)
    end
  end
end
