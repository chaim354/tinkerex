module Maker
  # What a project's folder holds — the read-only half of "the folder is the truth" (stage 2, S2-2).
  #
  # RESOLVES THE FOLDER FROM `folder_node_id` AND NOTHING ELSE. It never calls
  # Project#ensure_library_folder!: looking at a folder must not mkdir one (the #relocate bug
  # docs/invariants/project-intake.md records), so a project with no live folder simply lists
  # nothing and answers `available? == false`. Liveness is answered by the LibraryTree, which holds
  # LIVE dirs only — no extra query.
  #
  # THE WALK IS IN MEMORY OVER ONE PLUCK OF THE USER'S DIRS, then ONE files query and ONE count, so
  # the cost is constant in the number of files and folders (page_query_budget_test.rb pins it).
  # Two rules shape the walk: a dot-prefixed dir is skipped, the same display rule
  # Node.visible_entries applies to entries (never a scan skip — §14b); and a dir holding a `.git`
  # marker child is a WORKING TREE, listed as ONE Repo and never entered, because a checked-out
  # firmware repo is one thing in a project, not three hundred source files under "Code".
  #
  # ROLE COMES FROM THE FILENAME (Maker::FileAttachment.role_for), never a stored column: most
  # folder files have no attachment row at all, and a row's role is a snapshot (ProjectFolders).
  class ProjectFolderListing
    FILE_CAP = 300   # tiles the panel will render; the rest is a count and a link to the folder
    DIR_CAP  = 500   # dirs the walk will enter; bounds the IN (...) list on SQLite

    # One tile. `attachment` is nil for a folder file (the folder is the relation); a Linked row
    # (a file attached to the project but living OUTSIDE its folder) carries its row so the tile
    # can offer Detach and Move-into-project. `linked` is the folder test, not the row's presence.
    Row = Data.define(:node, :attachment, :linked) do
      def node_id = node.node_id
      def role = Maker::FileAttachment.role_for(node.name)
      def backup? = Maker::FileAttachment.backup?(node.name)
      def linked? = linked
    end

    Repo = Data.define(:node_id, :name, :path)

    attr_reader :folder_id, :path, :files, :repos, :total

    # `load_files: false` answers `total` (and `repos`) without the files query — Home's hero.
    def initialize(user, project, tree: nil, load_files: true)
      @user = user
      @tree = tree || Maker::LibraryTree.new(user)
      @folder_id = project.folder_node_id.presence
      @folder_id = nil unless @folder_id && @tree.dir?(@folder_id)
      @path = @folder_id && @tree.path_for(@folder_id)
      @repos = []
      @dir_cap_hit = false
      dir_ids = @folder_id ? collect_dirs(@folder_id) : []
      scope = dir_ids.empty? ? user.nodes.none : files_in(dir_ids)
      @total = dir_ids.empty? ? 0 : scope.count
      rows = load_files && !dir_ids.empty? ? scope.order(:name, :node_id).limit(FILE_CAP + 1).to_a : []
      # TRUNCATED READS TRUE ON EITHER CAP, not the file one alone: a folder can blow past DIR_CAP
      # with only a handful of files in each of its many subfolders and never come near FILE_CAP,
      # and that walk is exactly as incomplete as an over-long file list is. @dir_cap_hit is set by
      # collect_dirs, the only place that knows whether the walk stopped because it ran out of tree
      # or because it ran out of budget.
      @truncated = rows.size > FILE_CAP || @dir_cap_hit
      @files = rows.first(FILE_CAP).map { |n| Row.new(node: n, attachment: nil, linked: false) }
    end

    def available? = !@folder_id.nil?
    def truncated? = @truncated
    def node_ids = @files.map(&:node_id)
    def node_id_set = @node_id_set ||= node_ids.to_set

    private

    def files_in(dir_ids)
      @user.nodes.present.where(kind: "file", parent_node_id: dir_ids).visible_entries(false)
    end

    # Breadth-first from the folder itself (always entered, even when it is a working tree — a
    # project that IS a repo still lists its files). A `seen` set is the cycle guard the tree's
    # own ancestor walk has for the same reason: a cycle is unrepresentable on a mount and perfectly
    # representable in a row set.
    def collect_dirs(root_id)
      out = [ root_id ]
      queue = [ root_id ]
      seen = Set[root_id]
      until queue.empty? || out.size >= DIR_CAP
        parent = queue.shift
        @tree.children_of(parent).each do |child|
          next unless seen.add?(child.node_id)
          next if child.name.start_with?(".")
          if working_tree?(child.node_id)
            @repos << Repo.new(node_id: child.node_id, name: child.name, path: @tree.path_for(child.node_id))
            next
          end
          out << child.node_id
          queue << child.node_id
        end
      end
      # `queue` still holds unexplored dirs exactly when the loop stopped on the CAP arm of the
      # `until` rather than draining naturally — the precise signal, not a size comparison against
      # DIR_CAP: a flat folder whose last parent's last child happens to land `out.size` exactly on
      # DIR_CAP, with nothing left queued, walked its WHOLE tree and must not read as truncated.
      @dir_cap_hit = !queue.empty?
      out
    end

    def working_tree?(dir_id)
      @tree.children_of(dir_id).any? { |d| Library::RepoMetadata.marker?(d.name) }
    end
  end
end
