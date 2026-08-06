module Tools
  # Shared "save into which library folder?" helpers for addon controllers. Extracted from
  # BoxesController so Boxes and Generators share ONE copy (DRY). Both methods are private helpers
  # for the including controller.
  module LibraryFolders
    ROOT_LABEL = "/ (library root)".freeze

    private

    # The human path of ONE folder ("/Projects/harbor"), for the chooser's trigger button.
    #
    # NOT `folder_options.rassoc(id)`, which is the obvious version and the wrong shape: that
    # plucks EVERY dir the user owns and builds a label for each, to use one of them. The chooser
    # asks the server for a level at a time, so the whole tree is precisely what it no longer needs
    # — paying for it anyway would leave the flat picker's cost on a page that dropped the picker.
    # O(depth) parent hops instead, and depth is a path, not a library.
    def folder_path_label(node_id)
      return ROOT_LABEL if node_id.blank?

      names = []
      seen  = Set.new # a parent cycle is not reachable through the app's own doors; do not hang if one is
      node  = current_user.nodes.present.find_by(node_id:, kind: "dir")
      while node && seen.add?(node.node_id)
        names.unshift(node.name)
        node = node.parent_node_id &&
               current_user.nodes.present.find_by(node_id: node.parent_node_id, kind: "dir")
      end
      names.any? ? "/#{names.join('/')}" : ROOT_LABEL
    end

    # The folder the user picked to save into, or nil (= library root). SCOPED to the user's own
    # live dirs, so a forged/foreign node_id can't write into someone else's tree and a stale or
    # blank one simply falls back to root.
    def chosen_parent_node_id
      id = params[:parent_node_id].presence
      return nil unless id

      current_user.nodes.present.find_by(node_id: id, kind: "dir")&.node_id
    end

    # Existing folders to offer in the "save to" picker, as [label, node_id] pairs with the library
    # root first. Restricted to folders that ALREADY exist: creating folders on save needs a
    # cross-backend mkdir story we haven't built. Paths are built in Ruby (one pluck of the user's
    # own dirs — a bounded set) rather than a recursive SQL CTE, to stay SQLite/Postgres-agnostic.
    def folder_options
      rows = current_user.nodes.present.where(kind: "dir").pluck(:node_id, :parent_node_id, :name)
      by_id = rows.index_by(&:first)
      labels = {}
      label = lambda do |nid|
        return labels[nid] if labels.key?(nid)

        _id, parent, name = by_id[nid]
        prefix = parent && by_id[parent] ? label.call(parent) : ""
        labels[nid] = "#{prefix}/#{name}"
      end
      folders = rows.map { |nid, _p, _n| [ label.call(nid), nid ] }.sort_by(&:first)
      [ [ ROOT_LABEL, "" ] ] + folders
    end
  end
end
