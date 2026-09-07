# Server-rendered web UI for the maker Projects hub: list, create, edit, and a detail page
# tying together a build log, attached design files, and tasks.
#
# Maker data is backend-neutral: it does not live in the file library, so the file backend being
# unreachable degrades design-file THUMBNAILS (see Maker::Previews::ThumbnailMap) but never the
# page. This controller stays on the maker side of the FileLayer port — it only READS file
# metadata (never writes/moves/deletes bytes), so none of the §10 tripwire surfaces are touched.
class ProjectsController < ApplicationController
  before_action :set_project, only: %i[show edit update destroy unarchive]

  # Exposes the `capabilities` helper the attachments panel's upload control branches on
  # (chunk two-phase vs. share/s3 multipart). Read-only here — no action is capability-gated.
  include LibraryCapabilities

  # ?move_conflict=<id> — the prompt an attach leaves behind when the auto-move into this
  # project's folder hit a name collision. The same prompt renders on the file page; an attach can
  # come from either.
  include MoveConflicts

  # "Edit in <Addon>" for an attached file an addon produced — the attachment tiles carry the same
  # right-click menu as the Files page, so they need the same attribute. Read-only, like everything
  # else this controller does with the library.
  include AddonOrigins

  # The page's ONE live-node index. `#show` renders two surfaces off the library — the attachment
  # tiles and the build-log photos — and both ask the same question of the same table.
  include PageNodes

  QUERY_MAX = 80

  # One flat list of live projects, newest activity first. `?archived=1` swaps in the archived
  # ones. The web reads `status` as archived-or-not and never shows or sets the other four values
  # (spec decision #1) — the column, its validation and the v1 API are deliberately untouched.
  def index
    # `== "1"`, not `.present?`: a checkbox submits "0" for off, and `.present?` would read that as
    # "show me the archive" — the opposite page.
    @archived_view = params[:archived] == "1"
    # `?tag=` (stage 2, S2-5): the same tagged_with idiom ModelsController and
    # InventoryItemsController use. Applied BEFORE the archived partition below, so a tag filter
    # narrows both views rather than only whichever one the partition happens to build first.
    @tag = params[:tag].presence
    # `?q=` (stage 2, S2-5): the Files search idiom (FilesController#index / resolve_query) --
    # LOWER(name) LIKE ... ESCAPE '\', because SQLite has no default LIKE escape character and
    # sanitize_sql_like alone is inert there. This page has no visible search box of its own (the
    # Files toolbar owns that); this exists so SearchController's "See all" link into
    # projects_path(q:) narrows the same way the results preview did.
    @q = params[:q].to_s.strip.first(QUERY_MAX).presence
    scope = current_user.maker_projects.includes(:file_attachments)
    scope = scope.tagged_with(@tag) if @tag
    if @q
      scope = scope.where("LOWER(name) LIKE ? ESCAPE '\\'", "%#{Maker::Project.sanitize_sql_like(@q.downcase)}%")
    end
    all = scope.order(updated_at: :desc).to_a
    archived, live = all.partition { |p| p.status == "archived" }
    @projects = @archived_view ? archived : live
    @archived_count = archived.size
    @covers = Maker::Previews::ThumbnailMap.for(current_user, @projects.filter_map(&:cover_node_id))
    # Tags in use across the user's projects, for the filter chips below the toolbar -- ONE query,
    # not one per candidate tag. Mirrors InventoryItemsController#index's @item_tags.
    @project_tags = current_user.maker_tags.joins(:taggings)
                                .where(maker_taggings: { taggable_type: "Maker::Project" })
                                .distinct.order(:name).pluck(:name)
  end

  def show
    # A FILE DELETED FROM THE LIBRARY LEAVES THE PROJECT, IMMEDIATELY. It used to sit here forever
    # as a "⚠️ (file unavailable)" tile with a per-file Remove button: `Library::Reconciler`
    # TOMBSTONES rather than destroys (deliberately — it is what makes a NAS reorganisation
    # survivable), so no `dependent:` callback fires and nothing swept these.
    #
    # HIDING IS THE INSTANT HALF; DESTROYING IS `Maker::AttachmentReaper`'s AND IT WAITS. A
    # tombstone is one undo away from returning with the SAME node_id, and the attachment is keyed
    # on that id — so destroying inside the undo window would turn "restore from Trash" into
    # "restore, then re-file this into every project by hand". Hiding is reversible, so it is
    # instant; destroying is not, so it waits out the grace window.
    #
    # `.present` is what makes the nil mean something: nil here is "this user has no LIVE node with
    # that id", i.e. tombstoned or hard-gone, which is exactly the set that should not render.
    # ONE index and ONE ThumbnailMap over the page's whole union (PageNodes) — the attachment tiles
    # and the build-log photos ask the same two questions of the same rows, and asking twice cost a
    # duplicated `nodes` query, a second `stat_all` and a second `maker_previews` read — FOUR fewer
    # STATEMENTS per render, measured on chunk (19 → 15 on one attachment plus one build-log photo).
    # Three THINGS, four STATEMENTS: chunk's `stat_all` is two statements, not one (`nodes` +
    # `versions` — §14a pins the count as constant-in-N rather than a literal, and records that
    # chunk needs 2 where share/s3 need 1). An earlier version of this comment said THREE by
    # counting the things and calling them statements; a reviewer re-measured. The absolute numbers
    # are fixture-dependent and the DELTA is the portable claim, so trust the delta.
    # A CONSTANT-FACTOR saving, not a complexity change, which is why page_query_budget_test.rb's
    # constancy-in-N assertion stays green either way and is NOT the guard for this: the guard is
    # page_nodes_test.rb, and the reason for the merge is the liveness hole, not the queries.
    # It also halves the enqueue budget the page can spend:
    # ThumbnailMap::BACKFILL_LIMIT is PER CALL, so this is 100 for the page rather than 100 + 100.
    # Self-healing across renders, and the honest trade for the union being deduped.
    all_attachments = @project.file_attachments.order(:position).to_a
    # :rich_text_body is Action Text's association for `has_rich_text :body`. Without it, each
    # entry's body is its own query — 15 entries cost 15 extra round-trips. Pinned by
    # test/integration/web/page_query_budget_test.rb. Loaded HERE, above the index, because its
    # photos are half of the union below.
    @entries = @project.build_log_entries
                       .includes(:file_attachments, :rich_text_body)
                       .reorder(logged_at: :desc).to_a
    entry_photo_ids = @entries.flat_map { |e| e.file_attachments.map(&:node_id) }
    # THE BOM PANEL (stage 2, S2-4). Loaded here, above the union below, so a file-line's target
    # joins the page's ONE PageNodes union instead of costing its own query -- the same argument
    # this method already makes for entry_photo_ids two lines up. @bom_lines holds every line (the
    # rollup wants all of them); @bom_lines_shown is the panel's capped slice, sliced IN RUBY so the
    # rollup and the cap can never disagree about which lines exist. Maker::Project#current_bom is
    # the one definition of "latest revision" -- Projects::BomLinesController and
    # Projects::BomsController both call it too rather than repeating the ORDER clause.
    @bom = @project.current_bom
    @bom_lines = @bom ? @bom.lines.includes(:inventory_item, :supplier).to_a : []
    @bom_lines_shown = @bom_lines.first(Projects::BomLinesController::PANEL_CAP)
    @bom_rollup = Maker::BomRollup.new(@bom_lines)
    @items = current_user.maker_inventory_items.order(:name).pluck(:name, :id)
    @suppliers = current_user.maker_suppliers.order(:name).pluck(:name, :id)
    # THE COVER JOINS THE UNION (stage 4, S4-1): the hero renders it, and liveness is answered by
    # nodes.present like every other tile — a chosen cover is a raw column nothing validates (see
    # project_params), so a tombstoned cover renders NOTHING, not a poll cell that spins forever.
    # Maker::Project#cover_node_id derives one from the attachments when none is chosen: a constant
    # handful of queries regardless of N.
    cover_id = @project.cover_node_id
    @page_nodes = live_nodes_for(all_attachments.map(&:node_id) + entry_photo_ids +
                                 @bom_lines.filter_map(&:node_id) + [ cover_id ].compact)
    @cover_node = cover_id && @page_nodes[cover_id]
    @attachments, missing = all_attachments.partition { |a| @page_nodes.key?(a.node_id) }
    # NOT SILENT. The panel says how many left and points at the Trash, because a user who deleted
    # a file by accident and watched their project change otherwise has no thread to pull. It
    # disappears on its own when the reaper clears the rows.
    @missing_attachment_count = missing.size

    # The folder project-view uploads go into. Best-effort (re-ensured here so a folder the user
    # deleted is recreated); nil → uploads fall back to the library root rather than 500 the page.
    # AND IT RUNS BEFORE THE LISTING BELOW, which reads the folder_node_id this (re)writes —
    # looking at a folder must never be what mints it (docs/invariants/project-intake.md).
    @upload_parent_node_id = begin
      @project.ensure_library_folder!(current_user).node_id
    rescue StandardError
      nil
    end

    # THE FOLDER IS WHAT THE PANEL SHOWS; @attachments stay the file→project RELATION (detach,
    # cover, addon origin, the missing count). Maker::ProjectFolderListing reads folder_node_id and
    # never mints a folder — the ensure above is the one writer, and it runs first. An attachment
    # whose node is not among the listing's own (capped) ids is Linked: attached to this project but
    # living somewhere else in the library, so it gets its own group with Detach and a move-in
    # button instead of the plain folder tile.
    @listing = Maker::ProjectFolderListing.new(current_user, @project)
    # THE REPOSITORY CARD (stage 3, S3-2): one per repo Dir anywhere in the folder's tree — the
    # README rendered, the latest commit, the current tag, links to the commit/history pages.
    # Keyed by node_id so `_file_tree_section.html.erb` (recursive, one call per Dir) can look its
    # own card up without re-walking anything. `repo_dirs` collects the FULL Dir objects (not
    # @listing.repos, which flattens away `#files`/`#children` — exactly what the card needs to
    # find a README and resolve relative links).
    #
    # ONE BATCHED QUERY FOR EVERY REPO ON THE PAGE, NEVER ONE PER REPO: Maker::RepoCard.for needs
    # the repo dir's own Node (LocalRepo.open dereferences its storage_path through the port), and
    # @listing's Dir struct does not carry one. page_query_budget_test.rb's seed already grows the
    # NUMBER of repo? dirs with N (a `.git` marker per iteration, for its own unrelated nesting
    # coverage) — an O(repos) `find_by` here would turn that pre-existing growth into a query-count
    # regression the moment a project holds more than one repository, which it already does by the
    # time this runs at "large".
    repo_dirs = collect_repo_dirs(@listing.tree)
    # THE FOLDER'S OWN NODE RIDES THE SAME BATCHED QUERY (stage 4, S4-1) — the root's card needs
    # it exactly as a nested repo's card does, and a second `find_by` here would be the O(repos)
    # shape the comment above forbids, one row bigger.
    repo_roots = current_user.nodes.present
                             .where(node_id: repo_dirs.map(&:node_id) + [ @listing.folder_id ].compact, kind: "dir")
                             .index_by(&:node_id)
    @repo_cards = repo_dirs.index_by(&:node_id).transform_values do |dir|
      Maker::RepoCard.for(user: current_user, dir:, root_node: repo_roots[dir.node_id],
                          listing: @listing, capabilities:)
    end
    # THE ROOT'S OWN CARD (stage 4, S4-1). A project whose folder IS the working tree had no card
    # and no Commits/History anywhere on its page — every real repository on the share deployment
    # is one (measured 2026-09-07). The root is a synthetic Dir: its files are the loose rows, its
    # children the tree, its path the folder's — exactly what Maker::RepoCard reads to find a README
    # and resolve its relative links. A plain folder's README renders through the same reader with
    # no git facts. Neither costs a query: the node came out of the batch above, and the README is a
    # bounded PORT read (Maker::Readme's own caps), never SQL.
    @root_card = nil
    @readme = nil
    if @listing.available?
      if @listing.root_repo?
        root_dir = Maker::ProjectFolderListing::Dir.new(node_id: @listing.folder_id, name: @project.name,
                                                        path: @listing.path, repo?: true,
                                                        children: @listing.tree, files: @listing.loose)
        @root_card = Maker::RepoCard.for(user: current_user, dir: root_dir, root_node: repo_roots[@listing.folder_id],
                                         listing: @listing, capabilities:)
      else
        @readme = Maker::Readme.for(user: current_user, rows: @listing.loose, base_path: @listing.path,
                                    listing: @listing, link: Maker::RepoCard::DEFAULT_LINK)
      end
    end
    # RELEASES (stage 3, S3-5). `includes(:files, :rich_text_notes)` because the panel reads both
    # for every release it renders -- :rich_text_notes is the association Action Text gives
    # `has_rich_text :notes`, and without it a page of ten releases costs ten extra round-trips,
    # the exact regression page_query_budget_test.rb exists for.
    @releases = @project.releases.includes(:files, :rich_text_notes).to_a
    # ONE `stat_all` OVER EVERY FILE OF EVERY RELEASE SHOWN, never one `stat` per file: "changed
    # since this release" is a comparison against what the port reports NOW, and asking per row is
    # how that panel becomes linear in the number of files a project has ever released. An absent
    # key is the port's answer for a node that is no longer live (§14a), which is what the panel
    # renders as "no longer in the library".
    release_node_ids = @releases.flat_map { |r| r.files.map(&:node_id) }.uniq
    @release_tokens = release_node_ids.empty? ? {} : FileLayer.current.stat_all(current_user, node_ids: release_node_ids)
    # The tag picker reads tags only where the library is a local folder -- the repo card's own rule
    # (docs/invariants/git-editing.md), asked of the CAPABILITY and never of an adapter class.
    # Elsewhere the composer takes a tag as free text and the snapshot records it unverified.
    # Reuses the dirs and root nodes the repository cards above already collected, so a folder full
    # of repositories still costs the one batched `nodes` query it already paid.
    @release_repos = capabilities.local_worktree? ? release_repo_tags(repo_dirs, repo_roots) : []
    # Tiles or list (stage 3, S3-1) — the same whitelist-and-cookie idiom FilesController#resolve_view
    # uses, with its own values and its own cookie: this page's default is tiles, the Files page's
    # is list, and the two toggles must not read each other's choice.
    @view = resolve_project_view
    # GENERATED (stage 3, S3-1): a file inside the folder that an addon produced is listed ONCE, in
    # its own group below, never repeated inside the section it happens to sit in. Scoped to
    # @listing.node_ids ONLY — never `tile_ids` a few lines down, which also carries Linked rows:
    # a Linked file that is also addon output stays in Linked (unchanged since S2-2), because
    # Generated is about how THIS FOLDER files itself, not about every addon-produced node the page
    # renders anywhere. One query pair (Maker::AddonOrigin.for's own contract), regardless of N.
    @generated = Maker::AddonOrigin.for(user: current_user, node_ids: @listing.node_ids)
    @generated_ids = @generated.keys.to_set
    # "Linked" is a FOLDER question, asked of the tree, not a LIST question: the listing is capped
    # at FILE_CAP, so an attached file past the cap, or inside a repository the walk never entered
    # (DIR_CAP), is absent from `node_ids` while sitting squarely in the folder — it must not
    # reappear as "linked from elsewhere". `section` is the file's own library path (not scoped to
    # this folder, since a Linked file lives somewhere else in it entirely) — @listing.path_for
    # reads the same tree this listing already built, so this costs no extra query either.
    @linked_rows = @attachments.reject { |a| @listing.contains?(@page_nodes[a.node_id]) }
                               .map { |a|
                                 node = @page_nodes[a.node_id]
                                 Maker::ProjectFolderListing::Row.new(node:, attachment: a, linked: true,
                                                                       section: @listing.path_for(node))
                               }
    # Dead ids never reach either list: @listing only ever holds live nodes, and @attachments has
    # already dropped anything @page_nodes could not find — `stat_all` would answer nothing for a
    # gone id anyway, but it would still spend a slot in the ORDERED walk BACKFILL_LIMIT bounds.
    #
    # A CLOSED REPOSITORY'S FILES ARE NOT TILES, SO THEY ARE NOT IN THIS UNION (2026-09-07). Since
    # `_file_tree_section` stopped drawing tiles inside a repo — the Finder-style browser navigates
    # it instead — every id beneath one is a thumbnail this page renders nowhere, and
    # `ThumbnailMap.for` does not merely LOOK: it BACKFILLS, creating a preview row and enqueueing a
    # render job per missing id. Probed in review: a project whose repository holds 60 files
    # enqueued 60 GeneratePreviewJobs from a page that shows none of them, spending the bounded
    # BACKFILL_LIMIT budget the visible tiles are what it exists for. EXCEPT @generated_ids — a
    # generated file INSIDE a repository still renders as a tile in the Generated group below, so
    # its thumbnail must stay in the map. The subtree walk is the listing's own
    # (Maker::ProjectFolderListing#repo_subtree_ids): in memory over the tree it already built, so
    # this costs no query and page_query_budget_test.rb stays flat.
    hidden_in_repos = @listing.repo_subtree_ids - @generated_ids
    tile_ids = @listing.node_ids.reject { |id| hidden_in_repos.include?(id) } +
               @linked_rows.map(&:node_id)
    @page_thumbs = Maker::Previews::ThumbnailMap.for(
      current_user, tile_ids + entry_photo_ids.select { |id| @page_nodes.key?(id) } + (@cover_node ? [ cover_id ] : [])
    )
    # PHOTOS (stage 4, S4-1): the public page's own definition, on the maker's page too. In memory
    # over @listing, @entries and @page_nodes — all already loaded above — so nothing here queries,
    # and every row's thumbnail is already in @page_thumbs (folder rows through tile_ids, entry
    # photos through entry_photo_ids).
    @photo_rows = Maker::ProjectPhotos.rows(listing: @listing, entries: @entries, page_nodes: @page_nodes)
    # TILE_IDS ONLY, NOT THE BUILD-LOG PHOTOS. Every tile this page can render — a folder section,
    # Backups, Generated, Linked — carries `contextmenu->filemenu#open`;
    # `_log_entry`'s photos are spans driven by the `thumbs` controller alone, with no menu to add
    # an entry to — so an origin resolved for one would be work nothing reads. That is why entry
    # photos are not merged into this union either.
    @addon_origins = addon_origins_for(tile_ids)
    @tasks = @project.tasks.order(:position, :created_at).to_a
    @sheets = @project.sheets.to_a
    # THE WIRING TABLE (stage 3, S3-3). ONE query -- Maker::Project#connections already orders by
    # position, like #sheets above, so no further .order() is needed here.
    @connections = @project.connections.to_a
    # The entry form binds to a real object: `rich_text_area` reads its value from the form's
    # object, and Action Text's form helper is not built for the object-less `fields_for` the plain
    # textarea used.
    @new_entry = @project.build_log_entries.new
    @move_conflict = move_conflict_prompt
    # `== "1"`, not `.present?` — the same reading #index applies to `archived`. Set by
    # Projects::ScansController's async branch; it is a one-shot render hint, not state, which is
    # why it rides in the url rather than in the session: the reload navigates to the param-free
    # url and the hint is gone by construction.
    @scan_started = params[:scanning] == "1"
  end

  def new
    @project = current_user.maker_projects.new(status: "planning")
  end

  def create
    @project = current_user.maker_projects.new(project_params)
    if @project.save
      ensure_project_folder(@project)
      redirect_to project_path(@project), notice: "Project created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit; end

  def update
    if @project.update(project_params)
      redirect_to project_path(@project), notice: "Project updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  # Soft archive — the model's lifecycle op (keeps the record + its history). Hard delete is a
  # deliberately deferred secondary affordance.
  def destroy
    @project.archive!
    redirect_to projects_path, notice: "Archived #{@project.name}."
  end

  # The inverse of #destroy (which archives). Redirects to the live list, where the project has
  # just reappeared — landing back on the archived view it left would read as a no-op.
  def unarchive
    @project.unarchive!
    redirect_to projects_path, notice: "Restored #{@project.name}."
  end

  private

  def set_project
    @project = current_user.maker_projects.find_by!(slug: params[:id])
  end

  # Tiles or list (stage 3, S3-1) — the same whitelist-and-cookie idiom as
  # FilesController#resolve_view: an explicit `?view=` wins and is remembered for a year; otherwise
  # the last remembered choice; otherwise tiles. A DIFFERENT cookie (`project_view`, not
  # `files_view`) and a DIFFERENT default (tiles, not list) — this page and the Files page must not
  # read each other's remembered choice, and tiles is what the panel has always defaulted to.
  PROJECT_VIEWS = %w[tiles list].freeze
  DEFAULT_PROJECT_VIEW = "tiles".freeze

  def resolve_project_view
    requested = params[:view].presence
    if PROJECT_VIEWS.include?(requested)
      cookies[:project_view] = { value: requested, expires: 1.year }
      return requested
    end
    saved = cookies[:project_view]
    PROJECT_VIEWS.include?(saved) ? saved : DEFAULT_PROJECT_VIEW
  end

  # Every repo? Dir anywhere in the tree, at any depth — mirrors
  # Maker::ProjectFolderListing#flatten_dirs (private there, and rightly so: that walk is the
  # LISTING's business, this one is the CARD's). @listing.repos already flattens the same set, but
  # throws away #files/#children into a bare node_id/name/path Repo struct; Maker::RepoCard needs
  # the full Dir to find a README among a repo's own root files.
  def collect_repo_dirs(dirs)
    dirs.flat_map { |d| (d.repo? ? [ d ] : []) + collect_repo_dirs(d.children) }
  end

  # [[dir name, dir node_id, [tag names]]] for the release composer's picker (stage 3, S3-5), over
  # the repo dirs and root nodes #show already collected for the cards -- no query and no second
  # walk. A repository with no tags is dropped rather than rendered as an empty optgroup.
  #
  # RESCUED PER REPOSITORY, NOT AROUND THE LOOP: one unreadable working tree (a corrupt .git, a
  # file vanished under us) must cost its own tags, not every other repository's. `refusal` is
  # asked FIRST, before rugged, which is the order every caller of Maker::Git::LocalRepo keeps --
  # constructing anything past it dereferences the port's workdir on the way to libgit2, and a
  # locked repository is refused rather than opened (docs/invariants/git-editing.md).
  def release_repo_tags(dirs, roots)
    dirs.filter_map do |dir|
      root = roots[dir.node_id]
      next if root.nil?

      tags = begin
        local = Maker::Git::LocalRepo.open(current_user, root)
        local.refusal ? [] : local.tags.map(&:name)
      rescue StandardError => e
        Rails.logger.warn("[releases] tags unreadable for #{dir.name}: #{e.class} #{e.message}")
        []
      end
      tags.any? ? [ dir.name, dir.node_id, tags ] : nil
    end
  end

  # Best-effort: a project MUST save even if the library backend can't make its folder right now
  # (unmounted NAS, bucket blip). The folder is re-ensured on the next upload. Never fail creation
  # on a folder hiccup — hence the broad rescue.
  def ensure_project_folder(project)
    project.ensure_library_folder!(current_user)
  rescue StandardError => e
    Rails.logger.warn("[projects] folder ensure failed for #{project.slug}: #{e.class} #{e.message}")
  end

  # `cover_clear` is the form's way back to the automatic pick — see `_form.html.erb`. It is NOT a
  # column, so it is stripped here rather than permitted: `permit`ting it would hand `update` an
  # unknown attribute and raise.
  #
  # CLEARING WINS OVER CHOOSING when a submit somehow carries both, and the order of these two lines
  # is the whole of that rule. It is the safe way round: a stray blank clears a cover the user can
  # re-pick in two clicks, where the reverse would silently ignore a Clear they explicitly ticked.
  #
  # `cover_node_id` IS NOT VALIDATED AGAINST A LIVE NODE, deliberately. The chooser only offers the
  # user's own files, and a hand-posted id belonging to someone else is not a leak: every surface
  # that renders a cover looks it up through `current_user` (`Maker::Previews::ThumbnailMap`), so a
  # foreign id resolves to nothing and the card falls back to its placeholder. Adding a validation
  # would buy a nicer error for a case nobody reaches through the UI, at the price of a query on
  # every project save.
  def project_params
    attrs = params.require(:project).permit(:name, :description, :status, :cover_node_id, :tag_list,
                                            :visibility, :license, :autofile)
    attrs[:cover_node_id] = nil if params[:project][:cover_clear] == "1"
    attrs
  end
end
