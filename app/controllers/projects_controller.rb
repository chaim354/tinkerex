# Server-rendered web UI for the maker Projects hub: list, create, edit, and a detail page
# tying together a build log, attached design files, and tasks.
#
# Maker data is backend-neutral: it does not live in the file library, so the file backend being
# unreachable degrades design-file THUMBNAILS (see Maker::Previews::ThumbnailMap) but never the
# page. This controller stays on the maker side of the FileLayer port — it only READS file
# metadata (never writes/moves/deletes bytes), so none of the §10 tripwire surfaces are touched.
class ProjectsController < ApplicationController
  before_action :set_project, only: %i[show edit update destroy unarchive preview]

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

  SORTS = { "recent" => { updated_at: :desc }, "name" => { name: :asc },
            "status" => { status: :asc, name: :asc } }.freeze

  QUERY_MAX = 80

  # ON-DEMAND PANELS (structural redesign §6, slice 6): absent from the maker's normal page while
  # empty, unless this request opens one with ?add=<key> ("+ Add panel"). Nothing else is on demand:
  # Files and Publish always show, Photos and Schematics already render nothing when empty, and an
  # empty folder panel stays quiet (docs/invariants/design-system.md rule 14).
  ON_DEMAND = %w[build_log tasks bom wiring releases sheets].freeze

  # The sentence #demo_may_publish? refuses with (Tinkerex::Demo; the argument is at the method).
  DEMO_PUBLISH_REFUSAL = "The shared demo can't publish projects: everything made here stays " \
                         "private and is reset every night.".freeze

  # One flat list of live projects, newest activity first. `?archived=1` swaps in the archived
  # ones. ARCHIVED IS THE ONE STATUS THAT DECIDES WHICH LIST A PROJECT IS IN; the other four are
  # shown and set rather than filtered on — the form offers active, paused and done (stage 4,
  # S4-6), the project page badges them, and each card here badges them beside the link (slice 6).
  # `planning` is the column default and is never badged.
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
    # `?kind=` (stage 4, S4-7): the same whitelist-and-filter shape `@tag` uses one line up, over a
    # closed vocabulary rather than the user's own rows -- `presence_in` is what makes an unknown
    # value read as "no filter" rather than as an empty page.
    @kind = params[:kind].presence_in(Maker::Project::KINDS)
    scope = current_user.maker_projects.includes(:file_attachments)
    scope = scope.tagged_with(@tag) if @tag
    scope = scope.where(kind: @kind) if @kind
    if @q
      scope = scope.where("LOWER(name) LIKE ? ESCAPE '\\'", "%#{Maker::Project.sanitize_sql_like(@q.downcase)}%")
    end
    # `?sort=` (UI-cohesion slice 4): this page was the one list page with NO sort at all, always
    # ordered by `updated_at: :desc`. Same `SORTS.fetch` idiom as ModelsController, including the
    # secondary key on `status` — an ordering with no tiebreak reorders equals differently per
    # adapter, and this codebase runs on two.
    @sort = params[:sort].presence_in(SORTS.keys) || "recent"
    all = scope.order(SORTS.fetch(@sort)).to_a
    archived, live = all.partition { |p| p.status == "archived" }
    @projects = @archived_view ? archived : live
    @archived_count = archived.size
    @covers = Maker::Previews::ThumbnailMap.for(current_user, @projects.filter_map(&:cover_node_id))
    # Tags in use across the user's projects, for the filter chips below the toolbar -- ONE query,
    # not one per candidate tag. Mirrors InventoryItemsController#index's @item_tags.
    @project_tags = current_user.maker_tags.joins(:taggings)
                                .where(maker_taggings: { taggable_type: "Maker::Project" })
                                .distinct.order(:name).pluck(:name)
    # THE KINDS THIS USER ACTUALLY HAS, for the filter chips -- ONE query, constant in N, and the
    # same "only when there is something to filter by" rule @project_tags follows. `other` is
    # dropped because it is the column default and a chip for "everything nobody typed" filters
    # nothing useful (S4-6's own rule: badging a default is noise). Asked of the user's own
    # projects rather than of `scope`, or filtering by one kind would leave one chip and no way
    # back.
    @project_kinds = current_user.maker_projects.distinct.order(:kind).pluck(:kind) - [ "other" ]
  end

  def show
    # FIRST OPEN (stage 4, S4-6; stories 1.1 and 4.4). Stamped once, here, because this action is
    # already scoped to `current_user.maker_projects` — the owner is the only person who can reach
    # it, so there is no "whose view was this" to ask. Paired with `discovered_at`, it is the "New"
    # badge: the app made this and I have not looked at it yet.
    #
    # `update_column`: no validation, no callback, and NO `updated_at` BUMP — deliberately. Both
    # projects#index and Recent order by `updated_at`, so bumping it would make merely OPENING a
    # project reorder every list, which is a change nobody asked for wearing a feature.
    #
    # A WRITE ON A GET, and an established one here: ensure_library_folder! below already writes
    # folder_node_id on this same render, and ThumbnailMap backfills. It runs at most once per
    # project ever, and page_query_budget_test.rb's warm-up render absorbs it.
    @project.update_column(:opened_at, Time.current) if @project.opened_at.nil?

    # The project's folder, ensured best-effort: a project whose folder was never minted (the form
    # path, an ensure that failed at create time) gets one here; a port failure leaves the page
    # rendering with no folder rather than a 500. AND IT RUNS BEFORE THE LISTING BELOW, which reads
    # the folder_node_id this (re)writes — looking at a folder must never be what mints it
    # (docs/invariants/project-intake.md). Its answer is no longer kept: the top bar's Upload reads
    # the LISTING's folder (use_folder_destination below), so the page shows and uploads into one
    # folder by construction.
    # nil IS AN ANSWER (decision 2, stage 4, S4-6): a project whose folder is in the trash gets nil
    # here, on purpose, and the rescue below is for PORT failures only. Nothing is called on the
    # result any more, so the routine nil case cannot ride through that rescue as a NoMethodError —
    # the reason this line used to carry `&.node_id` rather than `.node_id`.
    begin
      @project.ensure_library_folder!(current_user)
    rescue StandardError
      nil
    end

    # THE FOLDER IS WHAT THE PANEL SHOWS; @attachments stay the file→project RELATION (detach,
    # cover, addon origin, the missing count). Maker::ProjectFolderListing reads folder_node_id and
    # never mints a folder — the ensure above is the one writer, and it runs first. An attachment
    # whose node is not among the listing's own (capped) ids is Linked: attached to this project but
    # living somewhere else in the library, so it gets its own group with Detach and a move-in
    # button instead of the plain folder tile.
    #
    # THE LISTING NOW COMES BEFORE THE PANEL LAYOUT, AND THAT ORDER IS LOAD-BEARING (2026-09-08,
    # folder panels): every direct subfolder is a PANEL, so the layout cannot be computed until the
    # tree that names them exists. It used to be the first thing #show did; it is still read before
    # every load that a hidden panel skips (@bom/@releases/@connections below), which is the
    # property that mattered about being early — being FIRST was never the point.
    @listing = Maker::ProjectFolderListing.new(current_user, @project)
    # Upload targets the project's folder (spec §6). A folder in the trash or unreachable this render
    # gives no destination, and the top bar asks with the chooser rather than guess the root.
    use_folder_destination(@listing.folder_id, path: @listing.path, primary: true) if @listing.available?

    # THE PAGE'S PANEL LIST (stage 4, S4-7; story 6.5): this project's kind's preset with its own
    # overrides on top, over a vocabulary that now includes this folder's own depth-one subfolders
    # (Maker::ProjectKind's header). Two columns off the row `set_project` already loaded, plus
    # `panel_folders` — the tree above plus ONE shelves query (2026-10-20, Maker::Shelves.by_name),
    # memoised on the listing and constant in the number of folders.
    # CONTENT BLOCKS (2026-09-09; spec §2). ONE query, and ONE read: the layout's `blocks:` pairs
    # and the index the partials render from come from the same array, so a block created between
    # two reads can never reach the loop as a key with no kind — which `render "projects/#{key}"`
    # would then be handed. Read here, above the layout that orders them and above the union that
    # answers their pictures' liveness.
    @blocks = @project.blocks.to_a
    @blocks_by_key = @blocks.index_by(&:layout_key)
    @panel_layout = @project.panel_layout(folders: @listing.panel_folders,
                                          blocks: @blocks.map { |b| [ b.key, b.kind ] })
    # WHAT THE CHOOSER CALLS EACH PANEL. The ten fixed labels plus one per folder — its own name,
    # which is the only label a folder key could honestly carry. Built here rather than in the
    # chooser because the chooser has no listing of its own, and a label map assembled in a view
    # would be a second definition the panels door could not reuse. A key with no entry cannot
    # reach the chooser: the layout is total against exactly these folders.
    # A BLOCK'S LABEL IS WHAT IT IS PLUS WHAT IT SAYS (content blocks): the strip has no folder name
    # and no fixed label to fall back on, and "Text block" alone on eight of them names none of
    # them. The heading, where there is one, is the only thing that tells two apart at a glance.
    @panel_labels = Maker::Project::PANEL_LABELS.merge(
      @listing.tree.to_h { |dir| [ Maker::ProjectKind.folder_key(dir.node_id), dir.name ] }
    ).merge(@blocks.to_h { |b| [ b.layout_key, helpers.block_label(b) ] })

    # EDIT MODE (2026-09-09, the page editor; spec §5). `editing` arrives only as the DEFAULT of the
    # two `layout` routes; it turns on the chrome and nothing else — every load below is the same,
    # which is what lets page_query_budget_test.rb pin the edit page with the page's own budget.
    # `path_parameters`, NOT `params`: route defaults land in the path parameters and a query string
    # never does, so `?editing=1` on the plain URL cannot switch the chrome on (found in review).
    @editing = request.path_parameters[:editing] == "1"
    # ONE PANEL FOR A VIEW THE DRAFT CHOSE BUT HAS NOT SAVED (`layout/panel`). The layout is
    # overridden IN MEMORY for this render alone — Data#with, never a write — and only for a panel
    # that offers views and a view it offers; anything else is a 404, because the only client is
    # our own controller and a wrong pair from it is a bug to surface, not a page to render.
    if @editing && params[:panel].present?
      # THE KEY THAT REACHES `render` IS THE LAYOUT'S OWN ELEMENT, NEVER THE PARAMETER'S STRING:
      # `find` hands back the vocabulary's copy, so what _panel_body interpolates into a partial
      # name came from the model. Brakeman's dynamic-render check reads it the same way, and it is
      # the honest data flow rather than an ignore entry beside a check (found by `bin/ci scan`).
      asked = params[:panel].to_s
      @panel_key = @panel_layout.order.find { |k| k == asked }
      wanted = params[:view].to_s
      raise ActiveRecord::RecordNotFound unless @panel_key && Maker::ProjectKind.offered_views(@panel_key).include?(wanted)

      @panel_layout = @panel_layout.with(views: @panel_layout.views.merge(@panel_key => wanted))
    end

    # THE FILES PANEL'S "RECENTLY CHANGED" ROW (structural redesign §6, slice 6): the 8 newest files
    # under the folder, ONE query, and [] with no query when the folder is unavailable. AFTER THE
    # LAYOUT AND THE EDIT FLAG, because it leaves out the subfolders this render draws no file cells
    # for (#dirs_without_tiles): a panel the maker hid takes its files off the page with it, and a
    # browsed folder's files must not come back as tiles here. `no_tiles` IS KEPT: the thumbnail
    # union below subtracts the SAME Dirs, so the row and the union cannot disagree about which
    # folders this render paints (F-S15-1). The row's ids join the page's one ThumbnailMap and its
    # one addon-origin lookup below, so each stays one call.
    no_tiles = dirs_without_tiles
    @recent_files = @listing.recent_files(skip: no_tiles)

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
    #
    # SKIPPED WHEN THE PANEL IS HIDDEN (stage 4, S4-7) — four queries: the bom, its lines, the item
    # names and the supplier names, the last two of which exist only for the panel's composer.
    #
    # WHY THIS ONE IS SAFE TO SKIP AND `@tasks`/`@sheets`/`@entries` ARE NOT: `@bom_lines` does feed
    # the page's ONE PageNodes union below, but ONLY so projects/_bom_lines can resolve a file
    # line's node — nothing else on the page reads a BOM node id out of that union, so an empty
    # list narrows it and changes no other panel. `@tasks` and `@sheets` are counted by the STATS
    # LINE and `@entries` is read by Maker::ProjectPhotos through entry_photo_ids, so skipping any
    # of those three would change a surface other than its own panel.
    bom_shown = @panel_layout.visible?("bom")
    @bom = bom_shown ? @project.current_bom : nil
    @bom_lines = @bom ? @bom.lines.includes(:inventory_item, :supplier).to_a : []
    @bom_lines_shown = @bom_lines.first(Projects::BomLinesController::PANEL_CAP)
    @bom_rollup = Maker::BomRollup.new(@bom_lines)
    @items = bom_shown ? current_user.maker_inventory_items.order(:name).pluck(:name, :id) : []
    @suppliers = bom_shown ? current_user.maker_suppliers.order(:name).pluck(:name, :id) : []
    # THE COVER JOINS THE UNION (stage 4, S4-1): the hero renders it, and liveness is answered by
    # nodes.present like every other tile — a chosen cover is a raw column nothing validates (see
    # project_params), so a tombstoned cover renders NOTHING, not a poll cell that spins forever.
    # Maker::Project#cover_node_id derives one from the attachments when none is chosen: a constant
    # handful of queries regardless of N.
    cover_id = @project.cover_node_id
    # AN IMAGE BLOCK'S PICTURE JOINS THE UNION TOO (content blocks): the block renders NOTHING when
    # its node is not live, which is the same derived-content rule the cover follows one line up —
    # a file dragged out of the folder must leave the page, not become a poll cell that never
    # resolves. Asked of the SAME index, so the page still asks `nodes` once.
    @page_nodes = live_nodes_for(all_attachments.map(&:node_id) + entry_photo_ids +
                                 @bom_lines.filter_map(&:node_id) + @blocks.filter_map(&:node_id) +
                                 [ cover_id ].compact)
    @cover_node = cover_id && @page_nodes[cover_id]
    @attachments, missing = all_attachments.partition { |a| @page_nodes.key?(a.node_id) }
    # NOT SILENT. The panel says how many left and points at the Trash, because a user who deleted
    # a file by accident and watched their project change otherwise has no thread to pull. It
    # disappears on its own when the reaper clears the rows.
    @missing_attachment_count = missing.size
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
    # THE README THE EDITOR EDITS (stage 4, S4-4), resolved ONCE from the same rows both cards
    # render — Maker::Readme.row_in is the one definition of the preference order, so the card that
    # shows a README and the door that saves it cannot disagree about which file that is. In memory
    # over @listing: no query, no port call.
    #
    # `@readme_editable` IS TRUE WITH NO README AT ALL — that is the "Write a README" case, which is
    # the whole of story 5.3 for the 9 of 9 measured projects that have none. The size cap is read
    # from FilesController's constant rather than spelled again (git-editing.md: the SERVER is what
    # enforces it, and two copies of a number is how they drift).
    @readme_row = @listing.available? ? Maker::Readme.row_in(@listing.loose) : nil
    @readme_editable = @listing.available? &&
                       (@readme_row.nil? || @readme_row.node.size.to_i <= FilesController::EDITABLE_MAX_BYTES)
    # RELEASES (stage 3, S3-5). `includes(:files, :rich_text_notes)` because the panel reads both
    # for every release it renders -- :rich_text_notes is the association Action Text gives
    # `has_rich_text :notes`, and without it a page of ten releases costs ten extra round-trips,
    # the exact regression page_query_budget_test.rb exists for.
    #
    # SKIPPED WHEN HIDDEN (stage 4, S4-7), and this is the most expensive of the three: the
    # releases query, the ONE `stat_all` over every file of every release — a PORT round trip, and
    # a WAN one on chunk_remote — and, where the library is a local folder, a git tag read per
    # repository in the folder. `release_node_ids` is empty when @releases is, so `stat_all` already
    # short-circuits; only @release_repos needs the gate spelled out.
    releases_shown = @panel_layout.visible?("releases")
    @releases = releases_shown ? @project.releases.includes(:files, :rich_text_notes).to_a : []
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
    @release_repos = releases_shown && capabilities.local_worktree? ? release_repo_tags(repo_dirs, repo_roots) : []
    # GENERATED (stage 3, S3-1): a file inside the folder that an addon produced is listed ONCE, in
    # its own group below, never repeated inside the section it happens to sit in. Scoped to
    # @listing.node_ids ONLY — never `tile_ids` a few lines down, which also carries Linked rows:
    # a Linked file that is also addon output stays in Linked (unchanged since S2-2), because
    # Generated is about how THIS FOLDER files itself, not about every addon-produced node the page
    # renders anywhere. One query pair (Maker::AddonOrigin.for's own contract), regardless of N.
    @generated = Maker::AddonOrigin.for(user: current_user, node_ids: @listing.node_ids)
    @generated_ids = @generated.keys.to_set
    # THE MODELS PANEL (2026-10-21; docs/superpowers/specs/2026-10-20-attach-model-to-project-design.md):
    # the models in this project's folder plus the ones attached from elsewhere, derived from rows
    # that already exist (Maker::ProjectModels). ONLY WHEN THE PANEL SHOWS — and that condition is
    # load-bearing, not a saving: a carded model's files leave "Linked from elsewhere" below, so with
    # the panel hidden they would be on the page nowhere at all.
    @project_models = if @panel_layout.visible?("models")
      Maker::ProjectModels.for(current_user, @project, attached_node_ids: @attachments.map(&:node_id))
    end
    carded = @project_models&.owned_node_ids || Set.new
    # "Linked" is a FOLDER question, asked of the tree, not a LIST question: the listing is capped
    # at FILE_CAP, so an attached file past the cap, or inside a repository the walk never entered
    # (DIR_CAP), is absent from `node_ids` while sitting squarely in the folder — it must not
    # reappear as "linked from elsewhere". `section` is the file's own library path (not scoped to
    # this folder, since a Linked file lives somewhere else in it entirely) — @listing.path_for
    # reads the same tree this listing already built, so this costs no extra query either.
    @linked_rows = @attachments.reject { |a| @listing.contains?(@page_nodes[a.node_id]) || carded.include?(a.node_id) }
                               .map { |a|
                                 node = @page_nodes[a.node_id]
                                 Maker::ProjectFolderListing::Row.new(node:, attachment: a, linked: true,
                                                                       section: @listing.path_for(node))
                               }
    # Dead ids never reach either list: @listing only ever holds live nodes, and @attachments has
    # already dropped anything @page_nodes could not find — `stat_all` would answer nothing for a
    # gone id anyway, but it would still spend a slot in the ORDERED walk BACKFILL_LIMIT bounds.
    #
    # THE UNION IS WHAT THIS RENDER PAINTS, ONE TERM PER PAINTING SURFACE (F-S15-1, 2026-10-19).
    # `ThumbnailMap.for` does not merely LOOK: it BACKFILLS, creating a preview row and enqueueing a
    # render job for every id it is handed that has none. An id no surface paints is a job for a
    # picture nobody sees, spent from the bounded BACKFILL_LIMIT budget the visible cells exist for
    # (probed in review: a project whose repository held 60 files enqueued 60 GeneratePreviewJobs
    # from a page showing none of them). A painted id the union misses spins for its polls and ends
    # as a badge, and on chunk_remote it stays that way: nothing but a backfill creates a row there.
    #
    # THE TILES: every file the listing holds, minus every file beneath `no_tiles`, the SAME Dirs the
    # recent row skipped above. The union used to derive its own exclusion keyed on `repo?`, and it
    # disagreed with the row in four reachable cases: it backfilled a hidden panel, a browsed plain
    # folder and a repository nested in a tiles-view panel, none of which draws a tile, and it never
    # backfilled an image inside a browsed repository, which Photos paints (project_page_test.rb pins
    # all four). EXCEPT @generated_ids: a generated file renders as a tile in the Generated group
    # wherever it physically sits. Backups need no exception: Dir#subtree_file_ids never holds one,
    # and the Backups group draws them all. In memory over the tree the listing already built, so
    # this costs no query and page_query_budget_test.rb stays flat.
    untiled = no_tiles.flat_map(&:subtree_file_ids).to_set - @generated_ids
    tile_ids = @listing.node_ids.reject { |id| untiled.include?(id) } +
               @linked_rows.map(&:node_id)
    # PHOTOS (stage 4, S4-1): the public page's own definition, on the maker's page too, and ITS OWN
    # TERM IN THE UNION, which is why it is computed here, above it. The panel is always shown
    # (Maker::ProjectKind::ALWAYS) and paints every image in the folder at any depth, a hidden
    # panel's and a browsed repository's included, so `tile_ids` cannot stand in for it. Its entry
    # half is every live build-log photo, exactly what projects/_log_entry paints. In memory over
    # @listing, @entries and @page_nodes, all loaded above, so nothing here queries.
    @photo_rows = Maker::ProjectPhotos.rows(listing: @listing, entries: @entries, page_nodes: @page_nodes)
    # THE PICKERS' OWN ROWS, IN EDIT MODE ONLY (content blocks; spec §2): the image block's picker
    # and the page intro's cover picker both draw the FOLDER'S images as thumbnails. They need no
    # union term: they are exactly the folder half of @photo_rows, which the union already holds.
    @folder_images = @editing ? @listing.all_rows.select { |row| row.role == "image" } : []
    # AN IMAGE BLOCK'S PICTURE, ONLY WHERE IT IS LIVE: `@page_nodes` has already answered that, and
    # a dead id here would spend a slot in the backfill budget for a block that renders nothing.
    block_thumb_ids = @blocks.filter_map(&:node_id).select { |id| @page_nodes.key?(id) }
    # THE RECENT ROW'S TILES ARE TILES TOO, and they are not all in `tile_ids`: a recent file can sit
    # past FILE_CAP, and a tile this map never backfilled spins for its 41 polls. Usually they ARE
    # already there — ThumbnailMap and AddonOrigin both take a union, so a duplicate costs nothing.
    # FIRST IN THE UNION, because BACKFILL_LIMIT is spent in the order given and this row is the top
    # of the Files panel: behind 300 listed tiles, a recent file past the cap would wait renders for
    # a slot (project_attachments_test.rb).
    recent_ids = @recent_files.map(&:node_id)
    @page_thumbs = Maker::Previews::ThumbnailMap.for(
      current_user, recent_ids + tile_ids + @photo_rows.map(&:node_id) + block_thumb_ids +
                    (@cover_node ? [ cover_id ] : []) +
                    (@project_models ? @project_models.models.filter_map(&:cover_node_id) : [])
    )
    # TILE_IDS ONLY, NOT THE PHOTO ROWS. Every tile this page can render — a folder section,
    # Backups, Generated, Linked — carries `contextmenu->filemenu#open`; `_log_entry`'s photos and
    # the Photos panel's cells are driven by the `thumbs` controller alone, with no menu to add an
    # entry to — so an origin resolved for one would be work nothing reads. That is why the photo
    # rows join the thumbnail union above and not this one.
    @addon_origins = addon_origins_for((recent_ids + tile_ids).uniq)
    @tasks = @project.tasks.order(:position, :created_at).to_a
    @sheets = @project.sheets.to_a
    # THE WIRING TABLE (stage 3, S3-3). ONE query -- Maker::Project#connections already orders by
    # position, like #sheets above, so no further .order() is needed here.
    #
    # SKIPPED WHEN HIDDEN (stage 4, S4-7) — one query, and projects/_wiring is its only reader.
    @connections = @panel_layout.visible?("wiring") ? @project.connections.to_a : []
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
    # WHICH ON-DEMAND PANELS LEAVE THE PAGE (structural redesign §6, slice 6), decided HERE and never
    # in Maker::ProjectKind.layout_for: the layout is shared with the public page, its feed, its
    # bundle and its BOM CSV (Maker::PublicProject#layout), which already omit an empty panel in
    # their own partials — and an empty BOM's header-only CSV is a different answer from a hidden
    # one's 404. Last, because every panel's data is loaded by now.
    #   A panel the maker HID stays hidden: the menu asks `visible?` first and the page loop draws
    #   from `visible`, so neither ?add= nor the menu can bring one back. (The `visible?` on
    #   @add_panel is belt and braces: mutation-checked, dropping it changes nothing on the page,
    #   because the loop never yields a hidden key whatever @add_panel holds.) The editor
    #   (@editing) shows every panel, so none of this runs there.
    #   ?add= opens one panel for THIS request and writes nothing; a non-String (`add[]=`) or a key
    #   that is not a visible on-demand panel is ignored.
    unless @editing
      requested = params[:add] if params[:add].is_a?(String)
      @add_panel = requested if ON_DEMAND.include?(requested) && @panel_layout.visible?(requested)
      @absent_panels = ON_DEMAND.select do |key|
        @panel_layout.visible?(key) && key != @add_panel && !panel_has_rows?(key)
      end
    end
    # `layout/panel` renders the one body and stops; the whole page is the default render.
    render partial: "projects/panel_body", locals: { key: @panel_key, extra: {} }, layout: false if @panel_key
  end

  # GET /projects/:id/preview — what a visitor sees, at any visibility, for the owner (story 5.1).
  #
  # THE SAME OBJECT THE PUBLIC PAGE USES, BUILT DIRECTLY. Maker::PublicProject takes the project
  # alone, reads `project.user` for every query and port call, and consults no session anywhere —
  # so building one here needs no change to Public::BaseController and no session-aware branch
  # inside it. What this route does NOT do is relax the public gate: /u/:handle/:slug still 404s a
  # private project to everyone, its owner included, and project_preview_test.rb asserts both
  # halves in the same file so the pair cannot drift.
  #
  # THE LINKS ARE THE VISITOR'S, NOT THE OWNER'S. `Maker::PublicProject#file_url_for` is the ONE
  # answer to "where does this file's link point" — the reason that class exists — so the preview
  # does not rewrite them to /files/:id. For an unlisted or public project they work identically
  # for the maker and for a stranger, which is the case a maker previews for; for a private one
  # they 404, which is precisely what a visitor gets, and the banner says so.
  #
  # NO HANDLE, NO PREVIEW. Every URL on the page is /u/<handle>/<slug>, and `public_file_path(nil,
  # …)` raises UrlGenerationError against the route's own handle constraint. Maker::Project already
  # refuses to PUBLISH without a handle; refusing to preview is the same rule, and the alert points
  # at the panel that claims one rather than at a dead end.
  def preview
    if current_user.handle.blank?
      return redirect_to project_path(@project),
                         alert: "Choose a handle first — a public page lives at /u/<handle>/#{@project.slug}. " \
                                "You can claim one in the Publish panel."
    end

    @pub = Maker::PublicProject.new(@project)
  end

  def new
    @project = current_user.maker_projects.new(status: "planning")
  end

  def create
    @project = current_user.maker_projects.new(project_params)
    if demo_may_publish?(@project) && @project.save
      failure = ensure_project_folder(@project)
      redirect_to project_path(@project), notice: created_notice(@project, failure)
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit; end

  # ASSIGN, THEN ASK, THEN SAVE -- `update` in two steps so the demo's refusal below sees the state
  # the save would leave and can stop it reaching the database. What `update` adds is a transaction
  # around the assignment, and assigning these attributes writes nothing (a tag list is held until
  # after save, Maker::Taggable).
  def update
    @project.assign_attributes(project_params)
    if demo_may_publish?(@project) && @project.save
      redirect_to project_path(@project), notice: publish_notice
    else
      # THE PANEL POSTS THE SAME TWO FIELDS AS THE EDIT FORM (stage 4, S4-4), and there is no edit
      # page behind it — a refusal that re-rendered :edit would bounce a maker off the page they
      # clicked on, into a form whose visibility field no longer exists. `return_to` is NOT a URL:
      # it is the literal string "project", resolved here to THIS project's own path, so there is
      # nothing to sanitise and no open redirect to get wrong (the same reason
      # ApplicationHelper#back_target_path refuses to take a URL param, §14d).
      return redirect_to project_path(@project), alert: @project.errors.full_messages.to_sentence if
        params[:return_to] == "project"

      render :edit, status: :unprocessable_entity
    end
  end

  # Soft archive — the model's lifecycle op (keeps the record + its history). Hard delete is a
  # deliberately deferred secondary affordance.
  #
  # "NOT A PROJECT" AND "ARCHIVE" ARE ONE WRITE AND TWO SENTENCES (stage 4, S4-6; story 1.6).
  # Archiving IS the dismissal mechanism — the claim lookup in Maker::ProjectDiscovery#adoptable is
  # unscoped, so an archived project keeps folder_node_id and the sweep passes over its folder
  # forever (docs/invariants/project-intake.md). That was true and undocumented; the maker had to
  # discover that "Archive" also meant "stop offering me this folder". A SECOND ROUTE performing
  # the same write would be the drift this codebase refuses, so `dismiss` changes the FLASH and
  # nothing else — the write is identical by construction, not by two callers agreeing.
  def destroy
    dismissing = params[:dismiss] == "1"
    @project.archive!
    notice = if dismissing
      "“#{@project.name}” is not a project. Its folder stays in your library, and the app " \
      "won't adopt it again."
    else
      "Archived #{@project.name}."
    end
    redirect_to projects_path, notice:
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

  # THE SHARED DEMO PUBLISHES NOTHING (Tinkerex::Demo), so this server never hosts a visitor's project
  # at /u/demo/... -- refused on create (a hand-posted value; the new form has no visibility field)
  # and on update (the Publish panel and the edit form), through the same failure branch a validation
  # error takes, so each surface shows the sentence where it shows any other refusal. It asks about
  # the state the save would LEAVE, not about the change: a demo project published by any other route
  # cannot be edited while it stays published, and saving it private always works. Every other
  # account is answered by the model exactly as before.
  def demo_may_publish?(project)
    return true unless project.published? && Tinkerex::Demo.demo?(current_user)

    project.errors.add(:base, DEMO_PUBLISH_REFUSAL)
    false
  end

  # DOES THIS ON-DEMAND PANEL HOLD A ROW? Read off what #show already loaded, so it costs no query.
  # BOM, Wiring and Releases are loaded only when visible, and #show asks only about a visible key
  # (`visible?` short-circuits first); hidden or empty, each ivar is [] and never nil, so the one
  # `any?` reads all six. An empty BOM REVISION is no row: its lines are the rows.
  def panel_has_rows?(key)
    case key
    when "build_log" then @entries.any?
    when "tasks" then @tasks.any?
    when "bom" then @bom_lines.any?
    when "wiring" then @connections.any?
    when "releases" then @releases.any?
    when "sheets" then @sheets.any?
    end
  end

  # THE PAGE-WIDE VIEW COOKIE IS GONE (2026-09-08, folder panels; spec decision 6). `project_view`
  # answered for every section at once, so a maker could not have their models as tiles and their
  # firmware checkout as the Finder browser; the view is now per PANEL and persisted in
  # `panels["views"]` (Maker::Project::VIEWS, written by Projects::PanelsController#update's
  # `view[<key>]` branch and read through Layout#view_for). `?view=` on this action is inert, and
  # the cookie is simply never read again — nothing has to clear it.

  # Every repo? Dir anywhere in the tree, at any depth — mirrors
  # Maker::ProjectFolderListing#flatten_dirs (private there, and rightly so: that walk is the
  # LISTING's business, this one is the CARD's). @listing.repos already flattens the same set, but
  # throws away #files/#children into a bare node_id/name/path Repo struct; Maker::RepoCard needs
  # the full Dir to find a README among a repo's own root files.
  def collect_repo_dirs(dirs)
    dirs.flat_map { |d| (d.repo? ? [ d ] : []) + collect_repo_dirs(d.children) }
  end

  # THE SUBFOLDERS THIS RENDER DRAWS NO FILE CELLS FOR (slice 6; ONE answer since F-S15-1): the Dirs
  # whose whole subtree the recent row leaves out of its query AND the thumbnail union leaves out of
  # its backfill. #show calls this once and hands the same Dirs to both. Three kinds:
  #   * a depth-one folder panel the maker HID, which is absent from the page, files and all
  #     (project_page_test.rb). EXCEPT IN EDIT MODE: the editor's loop is `order`, and a hidden
  #     panel renders ghosted WITH its tiles (projects/_panel_slot), so on that render it is painted.
  #     That reading puts a ghost's files on the editor's recent row too, and it is the owner's to
  #     confirm (F-S15-1): dropping `!@editing &&` keeps the editor's row identical to the page's,
  #     at the price of the ghost's tiles never being backfilled.
  #   * a depth-one panel in the BROWSER view, repository or plain folder: the Finder-style browser
  #     replaces its tiles, its rows and its nested sections (projects/_folder_panel).
  #   * every repository nested inside any other panel, which is always a closed browser section
  #     (projects/_file_tree_section).
  # THE PANEL'S VIEW DECIDES, NEVER `repo?` ALONE (slice 6 review): a plain folder in the browser
  # draws no tiles, and a repository in tiles or list draws its own. Asked of Dirs rather than file
  # ids so the recent query can subtract them before its LIMIT; the union reads their
  # Dir#subtree_file_ids. In memory over the listing's tree; no query.
  def dirs_without_tiles
    @listing.tree.flat_map do |dir|
      key = Maker::ProjectKind.folder_key(dir.node_id)
      dropped = (!@editing && !@panel_layout.visible?(key)) || @panel_layout.view_for(key) == "browser"
      dropped ? [ dir ] : collect_repo_dirs(dir.children)
    end
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
  #
  # IT RETURNS THE FAILURE NOW RATHER THAN SWALLOWING IT (stage 4, S4-6; story 1.2). "Project
  # created." over a folder that was never made is the one flash a maker cannot act on: the next
  # save from LightBurn goes to a directory that does not exist, and the only record was a log
  # line. The CLASS NAME is what the sentence carries, because FileLayer::FetchError (try again)
  # and FileLayer::UnsupportedOperation (never succeeds on retry) are different problems.
  def ensure_project_folder(project)
    project.ensure_library_folder!(current_user)
    nil
  rescue StandardError => e
    Rails.logger.warn("[projects] folder ensure failed for #{project.slug}: #{e.class} #{e.message}")
    e.class.name
  end

  # THE FOLDER IS NAMED FROM THE SLUG, NOT LOOKED UP — and that is exact rather than approximate
  # HERE and only here: #create always reaches ensure_library_folder!'s minting branch (a brand-new
  # project has no folder_node_id), and that branch builds [ROOT, slug] literally. A project ADOPTED
  # in place never comes through this action, so no sentence built here can name the wrong path.
  def created_notice(project, failure)
    if failure
      "Project created, but its folder could not be made (#{failure}). It will be retried the " \
        "next time you upload."
    else
      "Project created. Its folder is #{Maker::ProjectFolders::ROOT}/#{project.slug}."
    end
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
                                            :visibility, :license, :autofile, :kind)
    attrs[:cover_node_id] = nil if params[:project][:cover_clear] == "1"
    # ARCHIVING IS A BUTTON, NOT A FORM VALUE (stage 4, S4-6). #archive! also stamps archived_at,
    # and the form's own select never offers `archived` — so a hand-posted one would set the column
    # WITHOUT the timestamp, leaving a row in the archived list that #unarchive cannot reason about.
    # Stripped rather than un-permitted, because the other four values are legitimate.
    attrs.delete(:status) if attrs[:status] == "archived"
    attrs
  end

  # WHAT A VISIBILITY CHANGE ACTUALLY DID, IN THE MAKER'S TERMS (stage 4, S4-4; story 5.2). "Project
  # updated." was the whole feedback for publishing until now — no URL, and no word about the fact
  # that EVERY visible file in the project's folder — and every file attached to the project or its
  # build log, wherever it lives — became downloadable (Maker::PublicProject#permits?). A maker
  # cannot consent to what nobody told them.
  #
  # `saved_change_to_visibility?` RATHER THAN `published?`: the sentence is about the CHANGE, so a
  # save that touched the name must not re-announce a publication that happened last week.
  def publish_notice
    return "Project updated." unless @project.saved_change_to_visibility?
    return "#{@project.name} is private again. Its public page is gone." unless @project.published?

    url = public_project_url(@project.user.handle, @project.slug,
                             **(@project.unlisted? ? { k: @project.unlisted_token } : {}))
    who = @project.unlisted? ? "anyone with that link" : "anyone"
    "Published at #{url}. Everything in the project's folder, and every file attached to it, is now downloadable by #{who}."
  end
end
