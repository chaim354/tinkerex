module Maker
  # What a project's folder holds — the read-only half of "the folder is the truth" (stage 2,
  # S2-2; the tree, stage 3, S3-1).
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
  # marker child is a WORKING TREE — flagged, but ENTERED rather than stopped at (stage 3, S3-1):
  # a checked-out firmware repo is a section like any other, expandable in place with its own
  # files and its own nested subfolders, because the catalog holds a repo's files on every backend
  # (only `.git`'s own contents are unobserved).
  #
  # SECTIONS ARE THE REAL SUBFOLDERS ON DISK, NOT A ROLE DERIVED FROM THE FILENAME. `#tree` nests
  # the folder's direct subfolders (each with its own `children` and `files`); `#loose` is the
  # folder's OWN root files — the sweep's inbox. `Row#role` still reads the filename
  # (Maker::FileAttachment.role_for) because Backups still needs it (see `#backups` below) and
  # nothing about the extension map lives here — that per-user answer is Maker::ProjectFolders /
  # Maker::FilingRules, read only by the SWEEP, never by this reader.
  #
  # BACKUPS ARE PULLED OUT OF THE TREE, NOT LEFT IN PLACE — the one deliberate exception to "a
  # section is a real subfolder": a LightBurn/MillMage rescue copy (Maker::FileAttachment.backup?)
  # is still physically wherever it sits, but it is diverted into the flat, cross-cutting
  # `#backups` list so the panel can fold it into one closed section instead of scattering rescue
  # copies through every folder that happens to hold one (S2-2's rule, carried into the tree).
  #
  # `Row#section` IS THE DISPLAY PATH, RELATIVE TO THIS FOLDER, "" FOR A ROOT/LOOSE ROW — computed
  # once while building the tree, never re-derived by a caller walking node_id chains a second
  # time. `#path_for` answers the same question for a node OUTSIDE this folder (the Linked group),
  # from the SAME tree instance, at no extra query — that tree already indexes every live dir the
  # user owns, not just this folder's.
  class ProjectFolderListing
    FILE_CAP = 300   # tiles the panel will render; the rest is a count and a link to the folder
    DIR_CAP  = 500   # dirs the walk will enter; bounds the IN (...) list on SQLite

    # One tile/row. `attachment` is nil for a folder file (the folder is the relation); a Linked
    # row (a file attached to the project but living OUTSIDE its folder) carries its row so the
    # tile can offer Detach and Move-into-project. `linked` is the folder test, not the row's
    # presence. `section` is the list view's Section column — a display path relative to this
    # folder ("" reads as "Loose"), or whatever the caller supplies for a row this class did not
    # itself place (Linked).
    Row = Data.define(:node, :attachment, :linked, :section) do
      def node_id = node.node_id
      def role = Maker::FileAttachment.role_for(node.name)
      def backup? = Maker::FileAttachment.backup?(node.name)
      def linked? = linked
    end

    # One real subfolder, nested. `path` is the FULL library path (the same convention `Repo` has
    # always used — @tree.path_for costs nothing extra, the tree already indexes it). `repo?`
    # marks a working tree: entered rather than stopped at, so its `files` and `children` are
    # exactly like any other folder's, plus the panel's link to its commit/history pages. `files`
    # are this dir's OWN direct files only, backups already diverted out (see `#backups`).
    Dir = Data.define(:node_id, :name, :path, :repo?, :children, :files)

    # A FLATTENED, DERIVED VIEW OF `#tree`'s repo dirs — kept as its own list because it is the
    # natural shape for "every repository this folder holds", independent of how deep each one
    # nests. Nothing outside this class reads it today (the panel renders a repo as a tree
    # section, not a separate group — S3-1 retired the old standalone Repositories group), but the
    # link targets (name/path/node_id) are exactly what a future caller — or a test — wants
    # without re-walking the nested structure by hand.
    Repo = Data.define(:node_id, :name, :path)

    attr_reader :folder_id, :path, :total

    # `load_files: false` answers `total` (and `repos`) without the files query — Home's hero.
    # `file_cap:` is the PAGE's render budget by default (FILE_CAP); a caller that must see the
    # whole folder — Maker::ReleaseSnapshot, whose record is permanent — passes its own, and
    # `truncated?` answers against whichever cap was given (stage 3, S3-5's review).
    def initialize(user, project, tree: nil, load_files: true, file_cap: FILE_CAP)
      @file_cap = file_cap
      @user = user
      @tree = tree || Maker::LibraryTree.new(user)
      @folder_id = project.folder_node_id.presence
      @folder_id = nil unless @folder_id && @tree.dir?(@folder_id)
      @path = @folder_id && @tree.path_for(@folder_id)
      @repo_root_ids = Set.new
      @backups = []
      @dir_cap_hit = false
      dir_ids = @folder_id ? collect_dirs(@folder_id) : []
      @dir_ids_set = dir_ids.to_set
      scope = dir_ids.empty? ? user.nodes.none : files_in(dir_ids)
      @total = dir_ids.empty? ? 0 : scope.count
      rows = load_files && !dir_ids.empty? ? scope.order(:name, :node_id).limit(@file_cap + 1).to_a : []
      # TRUNCATED READS TRUE ON EITHER CAP, not the file one alone: a folder can blow past DIR_CAP
      # with only a handful of files in each of its many subfolders and never come near FILE_CAP,
      # and that walk is exactly as incomplete as an over-long file list is. @dir_cap_hit is set by
      # collect_dirs, the only place that knows whether the walk stopped because it ran out of tree
      # or because it ran out of budget.
      @truncated = rows.size > @file_cap || @dir_cap_hit
      # THE CAP APPLIES TO THE WHOLE FOLDER, BEFORE THE ROWS ARE SORTED INTO THEIR DIRS — unchanged
      # from before the tree existed: a folder past FILE_CAP can render a subfolder with only part
      # of its files, exactly as the old flat list could render only part of the folder.
      by_parent = rows.first(@file_cap).group_by(&:parent_node_id)
      @loose = bucket(by_parent[@folder_id] || [], "")
      @tree_dirs = @folder_id ? build_dirs(@folder_id, by_parent, "") : []
    end

    def available? = !@folder_id.nil?
    def truncated? = @truncated
    # The walk ran out of DIR_CAP before it ran out of tree — the panel words that differently from
    # "more files than tiles", since `total` counts only the dirs that WERE walked.
    def dir_cap_hit? = @dir_cap_hit

    # The folder's direct subfolders, nested — Dir objects with their own `children`/`files`.
    def tree = @tree_dirs

    # Files at the folder's OWN root — the sweep's inbox.
    def loose = @loose

    # Every backup-flagged Row anywhere in the folder (root or any depth of subfolder), pulled out
    # of `tree`/`loose` so the panel can fold them into one closed section instead of scattering
    # rescue copies across every folder that happens to hold one. Each still carries its OWN
    # `section` — where it really sits — because Backups is a cross-cutting group, unlike a plain
    # subfolder section where every row would trivially share the same value.
    def backups = @backups

    # Every Row this listing holds anywhere — loose, backups, or any depth of the tree, in no
    # particular order. THE ONE PLACE THAT KNOWS THE FULL SET, so a caller that needs to find a
    # folder row by its node_id (the Generated group: which of the folder's OWN rows did
    # Maker::AddonOrigin.for match, complete with the section it actually sits in) reads it from
    # here rather than reconstructing a Row from a node looked up elsewhere on the page — a
    # PageNodes index built from attachments/photos/BOM lines has no reason to contain a plain
    # folder file that nothing ever attached.
    def all_rows = @all_rows ||= loose + backups + flatten_files(tree)

    # Every node_id this listing holds anywhere. ThumbnailMap/AddonOrigins need this for EVERY tile
    # the panel can render, backups included.
    def node_ids = @node_ids ||= all_rows.map(&:node_id)
    def node_id_set = @node_id_set ||= node_ids.to_set

    # The listing's OWN Row for one node_id, or nil if this listing does not hold it (outside the
    # folder, past FILE_CAP, or inside a repository DIR_CAP never entered). O(1) after the first
    # call; built once from `all_rows`, never per lookup.
    def row_for(node_id) = (@rows_by_id ||= all_rows.index_by(&:node_id))[node_id]

    # Full library path => node_id for every row this listing holds (loose, any subfolder, any
    # repo), built ONCE per listing: a README's relative links resolve through it, and a page with
    # several repository cards must not rebuild it per card (review, S3-2). Pure string arithmetic
    # on the catalog's own paths — never the disk.
    def path_index
      @path_index ||= all_rows.index_by { |row| "#{path_for(row.node)}/#{row.node.name}" }.transform_values(&:node_id)
    end

    # The node's full library path — NOT scoped to this folder, unlike `Row#section`. Used for the
    # Linked group's Section column: those rows live anywhere in the user's library, and the tree
    # already indexes every live dir the user owns, so this costs no extra query.
    def path_for(node) = @tree.path_for(node.parent_node_id)

    # Every repository this folder holds, flattened out of the tree. See the Repo class comment.
    def repos = @repos ||= flatten_dirs(tree).select(&:repo?).map { |d| Repo.new(node_id: d.node_id, name: d.name, path: d.path) }

    # Is this node INSIDE the folder — anywhere beneath it, listed or not? Answered from the tree's
    # ancestor chain, never from `node_ids`: the listing is capped at FILE_CAP, so a file past the
    # cap, or inside a repository the walk never entered (DIR_CAP), is not in the list yet is not
    # "linked from elsewhere" either — it is in the folder, and the truncation line stands for it.
    # In memory, no query. A broken chain answers false (the caller then treats the row as linked,
    # which at least renders it).
    def contains?(node)
      return false unless @folder_id
      parent = node.parent_node_id
      return false if parent.nil?
      chain = @tree.ancestors_of(parent)
      chain.present? && chain.include?(@folder_id)
    end

    private

    def files_in(dir_ids)
      @user.nodes.present.where(kind: "file", parent_node_id: dir_ids).visible_entries(false)
    end

    # Splits one dir's (or the root's) already-fetched file nodes into ordinary Rows and backups,
    # diverting the latter into the flat `@backups` list instead of `out` — S2-2's rule, carried
    # into the tree. `section` is the display path for every row built here (constant for a single
    # dir's own files, "" for loose) since a FILE has no descendants of its own to disagree about.
    # Sorted by name here rather than trusted from the SQL order: the cap upstream sorts across
    # the WHOLE folder by name, which happens to keep a single dir's own slice name-ordered too,
    # but that is the SQL order's business, not this method's — sorting explicitly is what "files
    # by name" (Step 1) means regardless of how the caller got its rows.
    def bucket(nodes, section)
      nodes.sort_by { |n| n.name.to_s }.each_with_object([]) do |node, out|
        row = Row.new(node:, attachment: nil, linked: false, section:)
        row.backup? ? @backups << row : out << row
      end
    end

    def build_dirs(parent_id, by_parent, parent_path)
      @tree.children_of(parent_id)
           .reject { |d| d.name.start_with?(".") }
           .select { |d| @dir_ids_set.include?(d.node_id) } # only dirs the walk actually entered (DIR_CAP)
           .sort_by { |d| d.name.to_s }
           .map do |d|
        child_path = parent_path.empty? ? d.name : "#{parent_path}/#{d.name}"
        Dir.new(node_id: d.node_id, name: d.name, path: @tree.path_for(d.node_id),
                repo?: @repo_root_ids.include?(d.node_id),
                files: bucket(by_parent[d.node_id] || [], child_path),
                children: build_dirs(d.node_id, by_parent, child_path))
      end
    end

    def flatten_files(dirs)
      dirs.flat_map { |d| d.files + flatten_files(d.children) }
    end

    def flatten_dirs(dirs)
      dirs.flat_map { |d| [ d ] + flatten_dirs(d.children) }
    end

    # Breadth-first from the folder itself (always entered, even when it is a working tree — a
    # project that IS a repo still lists its files). A `seen` set is the cycle guard the tree's
    # own ancestor walk has for the same reason: a cycle is unrepresentable on a mount and perfectly
    # representable in a row set.
    #
    # A WORKING TREE IS FLAGGED, NOT STOPPED AT (stage 3, S3-1) — it is entered and queued exactly
    # like any other dir, so its own files and its own subfolders are walked (bounded by DIR_CAP
    # like everything else); only its `.git` MARKER CHILD is skipped, by the same dot-name check
    # every dot-dir gets, never observed.
    def collect_dirs(root_id)
      out = [ root_id ]
      queue = [ root_id ]
      seen = Set[root_id]
      until queue.empty? || out.size >= DIR_CAP
        parent = queue.shift
        @tree.children_of(parent).each do |child|
          next unless seen.add?(child.node_id)
          next if child.name.start_with?(".")
          @repo_root_ids << child.node_id if working_tree?(child.node_id)
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
