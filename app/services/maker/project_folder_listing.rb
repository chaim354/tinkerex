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
  # Two rules shape the walk: a dir is skipped when it is dot-prefixed OR build output
  # (`Library::BuildOutput` — `node_modules`, `__pycache__`), the same display rules
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
    Dir = Data.define(:node_id, :name, :path, :repo?, :children, :files) do
      # THE WHOLE SUBTREE, NOT THIS DIR'S OWN FILES — the two questions a REPOSITORY asks, and both
      # exist because a repo renders CLOSED with a browser inside it (2026-09-07) instead of a
      # section per subdirectory. In memory, over the tree this listing already built: no query, and
      # nothing to keep in step with the walk.
      #
      # `subtree_file_count` is what the section's summary shows for a repo. `visible.size` — this
      # dir's OWN files — was right while the rest of the repo rendered as nested sections below;
      # with the browser there instead it reads "(3)" over a repository holding 203 files.
      #
      # `subtree_file_ids` is the set ProjectsController#show subtracts from the TILE TERM of its
      # thumbnail map for each Dir its #dirs_without_tiles names (a hidden panel, a browsed folder, a
      # nested repository): that subtree draws no tiles, so a preview row and a render job per file
      # would be work for a picture no tile shows. OUT OF THE TILE TERM, NOT OUT OF THE MAP: the map
      # is the union of what the page paints, so an image in such a subtree comes back through the
      # Photos term (Photos paints every image at any depth), and a generated file is excepted from
      # the subtraction itself, because the Generated group tiles it wherever it physically sits
      # (F-S15-1). BACKUPS ARE NOT IN EITHER ANSWER, and that is correct rather
      # than an oversight — `#bucket` diverts a backup out of `files` into the cross-cutting
      # `#backups` list, which the panel DOES render as tiles wherever the file physically sits, so
      # a rescue copy inside an untiled folder must keep its thumbnail.
      def subtree_file_ids = files.map(&:node_id) + children.flat_map(&:subtree_file_ids)
      # This dir and every dir beneath it — what #recent_files leaves out for a dir it is told to skip.
      def subtree_dir_ids = [ node_id ] + children.flat_map(&:subtree_dir_ids)
      def subtree_file_count = files.size + children.sum(&:subtree_file_count)
    end

    # A FLATTENED, DERIVED VIEW OF `#tree`'s repo dirs — kept as its own list because it is the
    # natural shape for "every repository this folder holds", independent of how deep each one
    # nests. Nothing outside this class reads it today (the panel renders a repo as a tree
    # section, not a separate group — S3-1 retired the old standalone Repositories group), but the
    # link targets (name/path/node_id) are exactly what a future caller — or a test — wants
    # without re-walking the nested structure by hand.
    Repo = Data.define(:node_id, :name, :path)

    attr_reader :folder_id, :path, :total

    # `file_cap:` is the PAGE's render budget by default (FILE_CAP); a caller that must see the
    # whole folder — Maker::ReleaseSnapshot, whose record is permanent — passes its own, and
    # `truncated?` answers against whichever cap was given (stage 3, S3-5's review).
    def initialize(user, project, tree: nil, file_cap: FILE_CAP)
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
      # Kept for #recent_files, which asks the same subtree a second, differently ordered question.
      @dir_ids = dir_ids
      # THE ROOT ITSELF (stage 4, S4-1). collect_dirs ENTERS the folder but flags only its
      # children, so a project whose folder IS the working tree — every real repository on the
      # share deployment, measured 2026-09-07 — answered repo? nowhere on its page: no card, no
      # Commits, no History. Asked once here, in memory, of the same tree the walk reads.
      @root_repo = @folder_id ? working_tree?(@folder_id) : false
      @dir_ids_set = dir_ids.to_set
      scope = dir_ids.empty? ? user.nodes.none : files_in(dir_ids)
      @total = dir_ids.empty? ? 0 : scope.count
      rows = dir_ids.empty? ? [] : scope.order(:name, :node_id).limit(@file_cap + 1).to_a
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

    # THE NEWEST FILES ANYWHERE UNDER THE FOLDER (structural redesign §6, slice 6: the Files panel's
    # "Recently changed" row). ONE query over the same subtree `files_in` already scopes — the same
    # visible-entries rule, the same dirs the walk entered (DIR_CAP) — ordered by `updated_at`, with
    # `node_id` as the tiebreak an ordering needs on two adapters. [] when the folder is unavailable,
    # without a query. DELIBERATELY NOT PART OF THE NAME-ORDERED, CAPPED LISTING: a folder with 301
    # files keeps its newest ones wherever the name order puts them, which may be past FILE_CAP, so
    # this cannot be answered by sorting `all_rows`. Reads; never mints (project-intake.md).
    #
    # The row shows only what the page would otherwise show OPENLY, so two kinds of file stay out,
    # both IN the query so the limit still counts files the row can show:
    #   * `skip:` takes Dirs from `#tree` whose WHOLE subtree is left out — the page's answer to
    #     "which folders draw no tile" (a hidden panel, a browsed folder, a nested repository;
    #     ProjectsController#dirs_without_tiles decides, and the page's thumbnail union reads the
    #     same Dirs).
    #   * BACKUPS. LightBurn rewrites `<stem>_backup.lbrn2` on every save, so a laser project's
    #     newest files are half rescue copies — exactly what `#backups` folds into one closed
    #     section to keep off the panel's eye level (S2-2). #backup_names_sql is that rule in SQL.
    def recent_files(limit = 8, skip: [])
      dirs = @dir_ids - skip.flat_map(&:subtree_dir_ids)
      return [] if dirs.empty?

      files_in(dirs).where.not(*backup_names_sql)
                    .order(updated_at: :desc, node_id: :asc).limit(limit).to_a
    end

    # Is the project's folder ITSELF a working tree (a `.git` marker child of folder_node_id)?
    # False when the folder is not available. S4-4's README editor and S4-6's adoption read this.
    def root_repo? = @root_repo

    def truncated? = @truncated
    # The walk ran out of DIR_CAP before it ran out of tree — the panel words that differently from
    # "more files than tiles", since `total` counts only the dirs that WERE walked.
    def dir_cap_hit? = @dir_cap_hit

    # The folder's direct subfolders, nested — Dir objects with their own `children`/`files`.
    def tree = @tree_dirs

    # Files at the folder's OWN root — the sweep's inbox.
    def loose = @loose

    # THE PANEL LAYOUT'S VOCABULARY OF FOLDERS: `[[node_id, repo?, shelf], …]` for the DEPTH-ONE
    # subfolders. Depth one is the whole rule (2026-09-08, folder panels; spec decision 3): a
    # nested folder renders inside its parent's panel, so a key for one must never reach the
    # layout, and this reader is where that is decided — `tree` and not `flatten_dirs(tree)`.
    #
    # `shelf` IS THE FOLDER'S Maker::Shelves::Entry BY NAME, or nil (2026-10-20): its default view
    # and its group. ORDER: ungrouped folders first in `tree`'s order (by name — the disk order),
    # then each group's folders together, by group position, so a group's panels are adjacent in
    # the DEFAULT arrangement and one heading can stand over them. A maker's saved order still
    # wins (ProjectKind.stored_order).
    #
    # ONE QUERY, memoised on the listing (Maker::Shelves.by_name), constant in the folder count —
    # so ProjectsController#show, Projects::LayoutScoped and Maker::PublicProject each pay it once
    # per request, whatever the number of panels.
    def panel_folders
      tree.each_with_index
          .sort_by { |d, i| e = shelf_entries[d.name]; [ e&.group ? 1 : 0, e&.group_position || 0, e&.group.to_s, i ] }
          .map { |d, _i| [ d.node_id, d.repo?, shelf_entries[d.name] ] }
    end

    def shelf_entries = @shelf_entries ||= Maker::Shelves.by_name(@user)

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

    # Maker::FileAttachment.backup? as a WHERE fragment: the name ends in BACKUP_SUFFIX then one of
    # BACKUP_EXTS, case-insensitively — composed from those two constants, never a copy of the
    # strings. `_` is a LIKE wildcard, so the pattern is sanitized, and the ESCAPE clause is what
    # makes that sanitizing do anything on SQLite, which has no default escape character (the same
    # rule SearchController records).
    def backup_names_sql
      patterns = Maker::FileAttachment::BACKUP_EXTS.map do |ext|
        "%#{Node.sanitize_sql_like("#{Maker::FileAttachment::BACKUP_SUFFIX}.#{ext}")}"
      end
      [ patterns.map { "LOWER(name) LIKE ? ESCAPE '\\'" }.join(" OR "), *patterns ]
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
           .reject { |d| hidden_dir?(d.name) }
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
    # like everything else); only its `.git` MARKER CHILD is skipped, by the same #hidden_dir?
    # check every dot-dir gets, never observed.
    def collect_dirs(root_id)
      out = [ root_id ]
      queue = [ root_id ]
      seen = Set[root_id]
      until queue.empty? || out.size >= DIR_CAP
        parent = queue.shift
        @tree.children_of(parent).each do |child|
          next unless seen.add?(child.node_id)
          next if hidden_dir?(child.name)
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

    # THE TWO QUESTIONS EVERY DIR-SKIPPING SITE IN THIS WALK ASKS, ASKED ONCE (stage 4, S4-2).
    # `collect_dirs` and `build_dirs` both had `d.name.start_with?(".")` inline and now both need
    # the build-output rule too — two copies of a two-part rule is three chances to drift.
    # The NAMES themselves live in Library::BuildOutput and nowhere else; this composes, it does
    # not re-list, which is the shape `Library::ReservedNames` already uses for its own union.
    def hidden_dir?(name)
      name.to_s.start_with?(".") || Library::BuildOutput.dir?(name)
    end
  end
end
