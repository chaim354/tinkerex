module Tools
  # Shared "save into which library folder?" helpers for addon controllers. Extracted from
  # BoxesController so Boxes and Generators share ONE copy (DRY). Both methods are private helpers
  # for the including controller.
  module LibraryFolders
    ROOT_LABEL = "/ (library root)".freeze

    private

    # ONE index of this user's live dirs per request, shared by both label derivations below.
    #
    # Tools::AddonsController#show runs folder_options and folder_path_label in the same breath, so
    # a second pluck (or the per-hop `find_by` walk folder_path_label used to do) recomputes an
    # answer this pluck already holds: the pair measured 3 queries at depth 2 and 9 at depth 8,
    # against 1 at both. THE COST WAS LINEAR IN THE CHOSEN FOLDER'S DEPTH, which is why
    # library_folders_test.rb asserts constancy in depth over the pair rather than a number (§14e --
    # a literal pins one LIBRARY_BACKEND leg and fails the other two).
    # More importantly, TWO DERIVATIONS OF ONE LABEL IS TWO ANSWERS — the pre-share pair disagreed
    # on a parent cycle, folder_options blowing the stack (a 500 on the page) where folder_path_label
    # printed a partial path. Maker::LibraryTree owns the walk, its cycle guard and the `:broken`
    # sentinel (§14k, docs/invariants/model-intake.md).
    def library_tree = @library_tree ||= Maker::LibraryTree.new(current_user)

    # The human path of ONE folder ("/Projects/harbor"), for the chooser's trigger button.
    def folder_path_label(node_id)
      return ROOT_LABEL if node_id.blank?

      folder_label(node_id)
    end

    # THE ONE LENIENT SPELLING of a folder's label for this surface, called by both methods above
    # and below so they cannot drift.
    #
    # `path_for` answers nil for an unresolvable chain, and the primitive is right to: a sweep must
    # skip such a node. THIS SURFACE MAY NOT SKIP IT — a folder missing from the picker is a folder
    # the user cannot save into, a functional regression where a cosmetic one will do — so an
    # unresolvable chain degrades to the BARE LEAF, which is what both derivations produced before
    # they were folded together. Never ROOT_LABEL for a real folder: that would put a live node id
    # under a label reading "/ (library root)", wrong in the direction that looks like it worked.
    # ROOT_LABEL is only for an id that names no folder of this user's at all (a file, a foreign or
    # a stale id) — the same fallback chosen_parent_node_id makes for the same inputs.
    def folder_label(node_id)
      path = library_tree.path_for(node_id)
      return "/#{path}" if path.present?

      name = library_tree.name_of(node_id)
      name ? "/#{name}" : ROOT_LABEL
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
    #
    # THE WIRE SHAPE IS FROZEN — [[ROOT_LABEL, ""], ["/a/b", id], …], sorted by label with root
    # first. `data-addon-folders-value` is one of the nine attributes §14c pins for the life of
    # api_version "1" (docs/invariants/addons.md), published bundles read it, and Rails is never
    # rebuilt when a bundle is: a leading-slash or sort-order change breaks only someone else's
    # browser, against a green suite here.
    def folder_options
      folders = library_tree.dir_ids.map { |nid| [ folder_label(nid), nid ] }.sort_by(&:first)
      [ [ ROOT_LABEL, "" ] ] + folders
    end
  end
end
