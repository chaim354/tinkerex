# Server-rendered web UI for the file library: list, upload, download, view, EDIT, delete.
#
# `#update` is the newest of those and the only one that writes bytes it was handed as a STRING
# rather than as an upload — the editor's Save (tinkerex#178). It is working-tree-only on every
# backend, which is a product rule rather than a capability one; its own header carries the
# argument.
#
# Architectural invariants (CLAUDE.md §2/§8/§15) — bytes NEVER flow through Rails:
#   - Upload: the BROWSER hashes the file (SHA-256, JS SubtleCrypto), asks us to begin a
#     commit (FileLayer#begin_upload → presigned PUT URLs for the MISSING chunks only — dedup
#     for free), PUTs the bytes straight to storage, then asks us to finalize the version.
#   - Download/view: FileLayer#download answers with a Delivery, and §15 holds wherever the
#     backend has a URL signer — chunk and s3 both hand back a Redirect and the browser fetches
#     from storage directly.
#
# §15 DOES NOT HOLD ON THE SHARE BACKEND, and that is a decision rather than a gap here: a
# mounted directory has nothing to presign, so Rails serves the file (spec §2 decision 6 /
# §9's deliberate departure, scoped to storage we do not own). It is `send_file`, so the bytes
# stream from the path and a 2GB file never lands on the Rails heap — and where an operator does
# front the app with a proxy, x_sendfile_header hands the file off without Rails touching it at
# all. Do not "fix" this back to a presign: there is no URL to sign.
#
# The web UI reuses the SAME two-phase machinery and per-user presign paths as the desktop
# client — FileLayer#begin_upload/#finalize_upload, the port verbs Task 8 put in front of
# Sync::Commit's own two-phase flow, which is what this controller named directly before Task 8
# and does not any longer (see #begin_upload/#finalize_upload below) — so a web upload produces a
# valid content-addressed manifest + immutable version with correct refcounts. No second,
# bytes-through-Rails write path.
class FilesController < ApplicationController
  # ONE delivery switch, shared with the sessionless Public::FilesController (stage 3,
  # S3-4). It carries SAFE_INLINE_TYPES and the disposition policy; #blob below supplies
  # the node and the user. See app/controllers/concerns/file_delivery.rb.
  include FileDelivery

  # WHICH VIEWER, AND A .gbrjob's LAYER LIST — shared verbatim with the sessionless public file page
  # (stage 4, S4-5). See app/controllers/concerns/file_preview.rb; the three extension constants
  # below are re-exposed, not redefined.
  include FilePreview

  # ONE named mechanism for what this deployment can do, reachable from the views AND from the v1
  # API. Not two: a view reaching for FileLayer.current.capabilities inline while a controller
  # also sets @caps is how the two answers drift apart, which is §9a-3's complaint and Landmine
  # 1's whole shape. The `capabilities` helper this controller used to define privately now lives
  # in the concern -- the same argument that forbids two answers in a view forbids two ways to
  # reach them.
  include LibraryCapabilities

  # ?move_conflict=<id> — the prompt an attach leaves behind when the auto-move into the project
  # folder hit a name collision. Rendered here and on the project page; an attach can come from
  # either, so the resolution lives in one concern rather than in two actions.
  include MoveConflicts

  # The eager nudge (Task 11) — #intake_project_folder, called from #create and #finalize_upload
  # below. Shared with Projects::UploadsController, the project page's own inline uploader, which
  # needed the identical call once it stopped being the only other upload door; see the concern's
  # header for why that made it a concern rather than a second copy.
  include ProjectFolderIntake

  # "Edit in <Addon>" for a file an addon produced — #addon_origins_for, called from #index and
  # #show below and shared with ProjectsController#show, whose attachment tiles carry the same
  # right-click menu. See the concern for why the Registry lookup is second and conditional.
  include AddonOrigins

  # THE UPLOAD BRANCH. Two flows, one per deployment, and BOTH refusals are honest: neither
  # deployment can do the other's flow.
  #
  #   port_writable: false (chunk) -> the two-phase presigned flow below. Bytes go browser ->
  #     storage, never through Rails (§15).
  #   port_writable: true (share, s3) -> #create: the bytes come up in one multipart POST and
  #     land on the port.
  #
  # begin/finalize are gated on `syncable` rather than on `!port_writable`, and the difference is
  # the whole reason port_writable is a stated capability instead of an inference: these two
  # actions do not need "the port refuses writes", they need the sync engine's two-phase commit
  # flow -- FileLayer#begin_upload/#finalize_upload (Task 8; Sync::Commit itself, underneath) --
  # which is what `syncable` names, and which is the same gate V1::CommitsController uses for the
  # same machinery, one layer closer to Sync::Commit than this controller now reaches. A backend
  # with neither flow (port_writable false, syncable false) would be told "yes, use the two-phase
  # flow" by the derived gate and a NotImplementedError from Share/S3's own refusing stubs (still
  # a 500, just from a different, honestly-named door); the stated gate tells it the truth instead.
  # `port_writable` still selects which form the UI renders -- that is its one job, and it is a
  # different question from this one.
  require_capability! :syncable, only: %i[begin_upload finalize_upload],
                                 hint: "Upload through POST /files, which writes to this " \
                                       "deployment's library backend directly."
  require_capability! :port_writable, only: :create,
                                      hint: "Upload through POST /files/begin_upload then " \
                                            "POST /files/finalize_upload -- the two-phase " \
                                            "presigned flow. Chunk mode accepts uploads; it " \
                                            "just does not take the bytes through Rails (§15)."

  # THE RESCAN GATE, AND WHY IT IS NOT require_capability!. That concern renders a JSON 501 --
  # the v1 API's shape, right for a machine client. #rescan is a browser action reached from a
  # button, so its refusal is the SAME idiom every rescue_from below uses: redirect to files_path
  # with a flash alert. A human who somehow POSTs here (the button is hidden in chunk mode) gets a
  # page, not raw JSON. It still reads capabilities through the ONE named mechanism the concern
  # exposes (`capabilities`), so there is no second way to reach them (§9a-3). Defense in depth:
  # the hidden button is UX, this gate is the guarantee -- an ungated POST would enqueue a job
  # whose #perform then raises ArgumentError, since a chunk backend has no observer.
  before_action :require_scannable!, only: :rescan

  # THE ALLOWLIST MOVED TO `FileDelivery` (stage 3, S3-4) — the public file route applies the same
  # policy, and a second copy of it is the one-condition-two-answers divergence §14a forbids. This
  # name stays because it is cited from OUTSIDE this file (s3_delivery_test.rb, the renderer
  # contract's raster list, docs/invariants/addons.md), and it is the SAME frozen array, not a
  # second definition that could drift.
  SAFE_INLINE_TYPES = FileDelivery::SAFE_INLINE_TYPES

  # THE THREE PREVIEW VOCABULARIES MOVED TO `FilePreview` (stage 4, S4-5) FOR A REASON THAT IS NOT
  # TIDINESS: `#preview_kind` names all three, constant lookup inside a MODULE METHOD is LEXICAL,
  # and left here they would resolve to `FilePreview::MEASURABLE_EXTS` and raise NameError the first
  # time a .lbrn2 page rendered. These names stay because they are cited from OUTSIDE this file —
  # FilesHelper#kicad?, Maker::GerberArchive, Maker::PublicProject, and three test suites — and each
  # is the SAME frozen array, never a second definition that could drift. `SAFE_INLINE_TYPES`
  # directly above makes the identical move for the identical reason;
  # architecture_invariants_test.rb asserts object IDENTITY on all four, so a re-literal here
  # cannot pass while `assert_equal` would have.
  MEASURABLE_EXTS = FilePreview::MEASURABLE_EXTS
  KICANVAS_EXTS   = FilePreview::KICANVAS_EXTS
  GERBER_EXTS     = FilePreview::GERBER_EXTS

  # A node id that doesn't belong to current_user (or doesn't exist) -> 404, never a 500
  # and never another user's data (all lookups are scoped to current_user).
  # The port's answer for "that file is genuinely gone" (a tombstone, a storage_path that
  # escapes the library root, a version-less node). Mapped HERE rather than at the call site so
  # every action that touches the port gets one answer: the call-site rescue would have to be
  # repeated per action, and the one that gets forgotten 500s. FileLayer::NotFound is a
  # StandardError (unlike NotImplementedError, a ScriptError), so rescue_from reaches it.
  #
  # Deliberately the SAME shape as RecordNotFound above: from the browser's side "no such node"
  # and "no such bytes" are one condition, and the user cannot act on the difference.
  rescue_from ActiveRecord::RecordNotFound, FileLayer::NotFound do
    respond_to do |format|
      format.html { redirect_to files_path, alert: "File not found." }
      format.any  { head :not_found }
    end
  end

  # THE THREE PORT CONDITIONS, MAPPED IN ONE PLACE, AND THE POINT IS THAT THEY ARE DIFFERENT
  # ANSWERS. NotImplementedError is deliberately absent from all of them (see
  # LibraryCapabilities): it is a wiring bug, it should be a loud 500, and the gates above are
  # what keep it unreachable.
  #
  # FetchError = we could not reach the bytes RIGHT NOW: an unmounted share, a full NAS, a creds
  # blip, a 5xx from the bucket. 503 + a retry-shaped message, and above all NOT the 404 above:
  # "your file is gone" is terminal and this condition is not. Share#download raises this and
  # nothing caught it before this task, so an unmounted library 500'd -- the fix waited for here
  # deliberately, because a lone rescue in one action would have been a second copy of a mapping
  # that belongs at the controller.
  rescue_from FileLayer::FetchError do
    respond_to do |format|
      format.html { redirect_to files_path, alert: "Couldn't reach your library. Try again." }
      format.any  { render json: { error: "fetch_error" }, status: :service_unavailable }
    end
  end

  # UnsupportedOperation = the REQUEST is wrong for THIS node (share-mode delete on a directory).
  # A client condition, knowable only per-node at runtime, so Capabilities -- which is
  # per-deployment -- cannot gate it and 501 would be the wrong answer twice over.
  rescue_from FileLayer::UnsupportedOperation do |e|
    respond_to do |format|
      format.html { redirect_to files_path, alert: e.message }
      format.any  { render json: { error: e.message }, status: :unprocessable_entity }
    end
  end

  # GET /files — by default ONE folder's children (not the whole library), so the tree the backends
  # all build in `nodes.parent_node_id` is actually navigable instead of dumped flat.
  # `params[:folder]` is a parent node_id; absent/blank/invalid = the library root.
  #
  # `?ext=stl,3mf` IS THE ONE EXCEPTION, AND IT IS DELIBERATELY THE WHOLE LIBRARY, FLAT. "Show me
  # every .stl" is a question about the library, not about a folder, so that mode ignores
  # ?folder= outright rather than intersecting with it — and it is the only listing here with a
  # bound (FLAT_LIMIT), because a folder is self-limiting and a whole-library view is not.
  #
  # SCOPED BY parent_node_id, WHICH IS A node_id STRING, NOT the DB integer `id` — the same key
  # Node#children walks, and the same tree all three backends populate, so this filter is
  # backend-neutral (it never touches the port beyond the stat_all every row already needs).
  #
  # Size/content come from the PORT, not from Version — see #show, where the argument is made.
  # This action had the same bug in a second spelling: @versions_by_node came from
  # current_user.versions, which is empty on share and s3, so every Size cell was an em-dash.
  #
  # `stat_all`, NOT a loop over `stat`, and the difference was measured rather than assumed: the
  # loop cost one query per row on share/s3 and TWO on chunk (Node#current_version is a find_by,
  # not an association), which at 2000 nodes was 4000 queries and 527 ms of a 676 ms page — where
  # the Version-based code it replaced took 2 queries. Routing the views through the port was
  # correct and this is what it cost; the port answering the question the caller actually has
  # ("describe these N nodes") is what gives that back. See Chunk#stat_all. Folder scoping only
  # makes each page SMALLER — it does not replace stat_all, which is still the right shape for a
  # folder of 2000 children.
  #
  # The `select!` is the race, answered honestly: a node tombstoned between these two queries is
  # simply not listed. Looping `stat` raised NotFound there, and rescue_from turned one vanished
  # row into a 404 for the ENTIRE page. An absent key is stat_all's cross-backend contract
  # (test_contract_stat_all_omits_what_stat_raises_not_found_for), and this is what consumes it —
  # so `info` is never nil in the view.
  def index
    @view = resolve_view
    @sort, @dir = resolve_sort
    # Dot-prefixed entries are hidden unless asked for. Read BEFORE the two scopes below, which
    # both pass it, so one request cannot answer the question two ways across flat and folder mode
    # (§14a) — the same reason `.outside_repo_metadata` is on both.
    @show_hidden = resolve_hidden
    # FLAT MODE. An extension filter is a question about the LIBRARY, not about a folder, so
    # ?folder= is ignored outright rather than intersected -- "show me every .stl" that quietly
    # meant "in this folder" would be the wrong answer to the only question the chips can ask.
    @exts = resolve_exts
    @q = resolve_query
    # A search is flat for the same reason a type filter is: it is a question about the whole
    # library, not about one folder (spec §9). With no types active the base scope is every live
    # node, folders included — finding "desk-lamp" the folder is as useful as finding its files.
    @flat = @exts.any? || @q.present?
    if @flat
      @folder = nil
      @crumbs = []
      # NO FOLDER, SO NOTHING TO ADOPT AND NOBODY TO NAME — set beside @folder/@crumbs so the view
      # never reads an undefined ivar in this branch (stage 4, S4-6).
      @folder_project = nil
      # `.outside_repo_metadata` ON THE SCOPE, NOT ON THE `.order` BELOW, so @match_count is taken
      # from the same query as the rows and the banner cannot claim a file the page never shows.
      # A `.git` row reaches THIS scope only as a file — a `gitdir:` pointer, since flat mode
      # filters kind: "file" — but the rule is the catalog's, not the folder view's, and one
      # condition must not have two answers across the two scopes (§14a).
      scope = (@exts.any? ? flat_ext_scope(@exts) : current_user.nodes.present).visible_entries(@show_hidden)
      # LOWER on both sides: SQLite's LIKE is case-insensitive for ASCII and Postgres's is not,
      # and this app runs on both (§14e). sanitize_sql_like makes % and _ literal -- BUT ONLY WITH
      # `ESCAPE '\'`, which is LIKE_EXT's rule below and is load-bearing here for the same reason:
      # SQLite has NO default escape character, so without it the backslash sanitize_sql_like
      # inserts is matched as a LITERAL backslash and the sanitising is a no-op on self-host.
      # Measured on this connection: '100%-done.txt' LIKE '%\%%' -> 0 (no name holds a backslash,
      # so a search for "%" finds NOTHING), and the same with ESCAPE '\' -> 1.
      scope = scope.where("LOWER(name) LIKE ? ESCAPE '\\'",
                          "%#{Node.sanitize_sql_like(@q.downcase)}%") if @q
      @match_count = scope.count
      # ORDERED BY THE USER'S SORT, NOT BY NAME, BECAUSE HERE THE ORDER *SELECTS* -- see
      # flat_order. This line used to be `.order(:name)`, and the LIMIT then took the alphabetical
      # head of the library while the page displayed it under whatever heading the user had
      # clicked.
      # flat_order's "type" ranking is a CASE over the active extensions and has nothing to rank
      # with none active, so a search without types sorts by name instead.
      sort_key = (@exts.empty? && @sort == "type") ? "name" : @sort
      @nodes = scope.order(flat_order(@exts, sort_key, @dir)).limit(FLAT_LIMIT).to_a
      @truncated = @match_count > FLAT_LIMIT
    else
      @folder = current_folder
      @crumbs = folder_crumbs(@folder)
      # WHO, IF ANYONE, ALREADY CLAIMS THIS FOLDER (stage 4, S4-6). ONE query, constant in N, and
      # only on the folder view — the flat view is a question about the library and has no folder
      # to adopt. It buys two things at once: the menu offers "Open project X" instead of a verb
      # that would 302 straight back with "already a project", and the same row names the project
      # in that refusal if a stale page posts anyway.
      #
      # UNSCOPED ON STATUS, like every other reader of this claim (Maker::ProjectDiscovery#adoptable,
      # Maker::ModelIntake.claimed_folders): an ARCHIVED project still owns its folder, and a page
      # that pretended otherwise would offer to make a second project for it.
      #
      # THE COST IS NAMED RATHER THAN WAVED AT: this is the app's busiest page (§12.8 tracks its
      # render cost), and `folder_node_id` carries no index — but the scan is over the user's own
      # projects, of which the measured real library has nine. page_query_budget_test.rb's folder
      # view asserts constancy in N and now actually visits a folder, so a per-row version of this
      # could not hide.
      @folder_project = @folder && current_user.maker_projects.find_by(folder_node_id: @folder.node_id)
      # `.outside_repo_metadata` here for the same reason it is on the flat scope above, and on
      # the scope rather than the orders below so @child_count paginates what is actually shown.
      scope = current_user.nodes.present.where(parent_node_id: @folder&.node_id)
                          .visible_entries(@show_hidden)
      # PAGED ONLY UNDER THE NAME SORT — see #paged_folder? for why the other two cannot be.
      @paged = paged_folder?
      if @paged
        @child_count = scope.count
        @pages = [ (@child_count / FOLDER_PAGE.to_f).ceil, 1 ].max
        @page = resolve_page(@pages)
        @nodes = scope.order(folder_page_order(@dir))
                      .offset((@page - 1) * FOLDER_PAGE).limit(FOLDER_PAGE).to_a
      else
        @nodes = scope.order(kind: :desc, name: :asc).to_a
        @pages = 1
        @page = 1
      end
      @truncated = false
    end
    @info_by_node = FileLayer.current.stat_all(current_user, node_ids: @nodes.map(&:node_id))
    @nodes.select! { |node| @info_by_node.key?(node.node_id) }
    # AFTER select!, so a node that vanished between the two queries is gone before it can be
    # given a sort position (and before sort_key asks @info_by_node for an mtime it does not
    # have); BEFORE the note/thumbnail loads, which only need the final list.
    #
    # FLAT MODE IS ALREADY SORTED, BY SQL, AND RE-SORTING IT HERE WOULD BE THE BUG IN MINIATURE.
    # There the ORDER BY is what the LIMIT selects with, so SQL is the authority; running a second
    # comparator over the slice would be safe only for as long as the two agreed exactly, forever,
    # including on ties. One authority per mode is cheaper than that promise -- and the promise
    # that DOES have to hold (the two mean the same thing) is pinned by a test that asks for the
    # same files both ways and compares the two orders.
    #
    # A PAGED FOLDER IS SORTED BY SQL, FOR THE SAME REASON FLAT MODE IS: once a LIMIT exists the
    # ORDER BY is what SELECTS the rows, so SQL is the authority and a second comparator over the
    # slice is redundant work at best.
    #
    # STATED HONESTLY, because it was mutation-checked and the obvious claim is too strong: leaving
    # the Ruby sort in place here does NOT currently break anything. folder_page_order reproduces
    # sort_key's order exactly, and sort_nodes is stable, so re-running it over an already-ordered
    # page is a no-op — removing this `|| @paged` keeps every test green. The reason to skip it is
    # that having two authorities agree by coincidence is precisely the arrangement that rots: the
    # danger is real and lives in folder_page_order (dropping its LOWER() DOES scatter rows across
    # page boundaries, and files_pagination_test.rb goes red when you do), so the invariant worth
    # keeping is "one order, expressed once", not "this line is load-bearing today".
    @nodes = sort_nodes(@nodes, @info_by_node, @sort, @dir) unless @flat || @paged
    # Only the flat view needs it — a folder view already tells you where you are, and this is a
    # query the folder view would pay for and never read.
    @folder_paths = @flat ? folder_paths_for(@nodes) : {}
    # Note counts for the badge — one grouped query, never N+1.
    @note_counts = current_user.maker_notes.where(node_id: @nodes.map(&:node_id)).group(:node_id).count
    # "Edit in <Addon>" for whichever of these files an addon produced. AFTER the select!/sort, so
    # it is asked about exactly the rows that will render, and — like @note_counts beside it — a
    # whole page at a time rather than per row (page_query_budget_test.rb asserts the constancy).
    # Both list and grid read it, so it is set here rather than in either branch above.
    @addon_origins = addon_origins_for(@nodes.map(&:node_id))
    # Current-version, current-build thumbnails, plus a bounded backfill of the ones that have no
    # row yet. ONE call, and it is the same class the Models and Projects pages go through: this
    # controller held the only copy of both rules (the renderer-revision filter and the backfill),
    # which is exactly how those pages came to have neither. `@info_by_node` is passed in rather
    # than re-stat'd — on share a second stat_all is a filesystem stat per node, doubled.
    @thumb_by_node = Maker::Previews::ThumbnailMap.from_info(current_user, @nodes.map(&:node_id),
                                                            @info_by_node, backfill: true)
    # The current project's folder, for the upload button's default-into-project wiring (spec
    # 2026-07-23). `current_project_folder_node_id` (CurrentProject concern) is deliberately NOT a
    # helper_method — like ProjectsController#show's @upload_parent_node_id, a view must not create
    # a project folder as a side effect of merely being rendered; the owning action opts in
    # explicitly and hands the view an ivar. nil when no project is current (its own rescue already
    # covers an ensure failure, same as ProjectsController#show's).
    @current_project_folder_node_id = current_project_folder_node_id
    # The type filter's options — see #ext_facets. Library-wide in BOTH modes, deliberately: it is
    # the control for choosing a whole-library type view, so scoping it to the folder you happen to
    # be standing in would hide the types the filter exists to reach.
    @ext_facets = ext_facets
  end

  # GET /files/thumbnails?ids=a,b,c (JSON) — the current-version thumbnail state for each node id,
  # for the grid's poll-until-ready. Session-authed (this is the web UI, not the device-token v1
  # API), user-scoped. Shape: { "<node_id>": { status:, url: } }. A node with no thumbnail row is
  # simply absent from the payload.
  #
  # `backfill: false`, and it is the one caller that opts out. This runs every 2 seconds for up to
  # 40 tries per open page; enqueueing here would be a per-node write on every tick for work the
  # page render that produced these spinners has already done. The rows it is polling for are the
  # ones #index created.
  def thumbnails
    ids = params[:ids].to_s.split(",").first(200) # bound the batch
    nodes = current_user.nodes.present.where(node_id: ids).to_a
    info = FileLayer.current.stat_all(current_user, node_ids: nodes.map(&:node_id))
    map = Maker::Previews::ThumbnailMap.from_info(current_user, nodes.map(&:node_id), info,
                                                 backfill: false)

    # A NODE WITH NO ROW MUST STILL GET AN ANSWER, AND THIS LINE IS WHY THE SPINNER USED TO RUN
    # FOREVER. This was `next unless p`, which OMITS the key — and `thumbs_controller`'s
    # `if (!entry) continue` then leaves that cell spinning AND in the poll set, so it burned all
    # 40 tries and the spinner stayed on screen permanently afterwards. The failure has been worked
    # around THREE times at the callers (`_list`, `_grid`, and `_hero_poster`, whose comment
    # describes this exact loop), and was still live in `projects/_attachment_group`, which renders
    # a poll cell for any attachment. Answering here fixes every caller at once, including the two
    # cover cards that hold no filename and so cannot guard themselves.
    #
    # THE TWO NO-ROW CASES ARE NOT THE SAME QUESTION, and collapsing them would trade a hung
    # spinner for a wrong one:
    #   - nothing will EVER render this name (no renderer, or the node is not live) -> `unsupported`,
    #     a terminal answer the client resolves to a static badge. A tombstone lands here too, which
    #     is what `_hero_poster` had to guard against by hand.
    #   - the name IS renderable and the row simply has not been created yet -> OMIT, so the client
    #     keeps polling. `backfill: false` above means this door never creates one, so saying
    #     "unsupported" here would freeze a thumbnail that is genuinely on its way.
    live = nodes.index_by(&:node_id)
    out = ids.each_with_object({}) do |id, h|
      node = live[id]
      preview = node && map.thumb(id)
      if preview
        h[id] = { status: preview.status,
                  url: (preview.status == "ready" && preview.asset.attached? ? url_for(preview.asset) : nil) }
      elsif node.nil? || Maker::Previews::Registry.for_filename(node.name).nil?
        h[id] = { status: "unsupported", url: nil }
      end
    end
    render json: out
  end

  # GET /files/scan_status (JSON) — when this user's last library scan FINISHED, or null.
  #
  # ONE KEY, AND THE CLIENT OWNS THE COMPARISON. The page renders the stamp it was built with into
  # `data-scanreload-since-value`; the poller reloads when this answer is present and different.
  # That is the whole mechanism, and it needs nothing else to be correct: a scan that finished and
  # changed nothing still advances the stamp, and reloading to see "nothing new" is the honest
  # outcome of pressing Rescan.
  #
  # `running:` IS DELIBERATELY ABSENT, AND BOTH SOURCES FOR IT WERE REJECTED RATHER THAN OVERLOOKED.
  # (1) Solid Queue's semaphore: Library::ScanJob's `limits_concurrency` duration is ONE HOUR, a
  # safety valve for a dead worker rather than a runtime, so after a crash it would answer "running"
  # for an hour — and those tables do not exist under the test adapter, so no assertion here could
  # ever catch that. (2) A cache flag set at the top of #perform: §14e's rate-limit lesson exactly —
  # the test env's store would make the flag unfalsifiable, so its guard would pass for the wrong
  # reason. A key that can lie is worse than a key that is missing; the client bounds its own wait
  # instead and says something true when it gives up.
  #
  # NOT GATED ON `scannable`. require_scannable! answers a browser button with a redirect and a
  # flash, which is right for #rescan and nonsense for a poller. chunk_remote renders no element
  # that polls this, and null is its true answer forever.
  def scan_status
    render json: { scanned_at: current_user.library_scanned_stamp }
  end

  # GET /files/:id/geometry (JSON) — the coordinate payload behind the .lbrn2 Measure view.
  #
  # Enqueue-and-report, NOT render-and-wait. Parsing means reading the whole file out of the
  # file layer, and the biggest .lbrn2 files are photo engravings — 24 MB on disk for two shapes —
  # so doing it inline would block a browser request on a multi-megabyte fetch. The job already
  # owns that work, along with the MAX_PREVIEW_BYTES ceiling, the FetchError retry policy, and
  # commit_if_current's version-race guard.
  #
  # Same response shape as #thumbnails so the client's polling code is a known quantity — INCLUDING
  # never redirecting. The class-level `rescue_from ActiveRecord::RecordNotFound` a few lines up
  # branches on request format and answers a plain `get` (html, the default with no Accept header)
  # with a 302 to files_path — right for #show/#blob, which render a page, and wrong here: a JSON
  # poller reading a redirect's body would see neither a status key nor a 404. Caught locally so
  # this action's shape holds regardless of what the caller's Accept header happens to be.
  #
  # LOOKS UP THE EXISTING ROW BEFORE CALLING Enqueue, RATHER THAN CALLING IT UNCONDITIONALLY. This
  # is not the same shape as #enqueue_preview's eager, upload-time call: Enqueue.call resets a
  # `failed` row to "pending" and re-enqueues WHENEVER it is called (documented — "when it
  # previously `failed`"), which is exactly right for a one-shot nudge at upload time and exactly
  # wrong for a passive poll. Calling it on every GET would mean a client polling a permanently
  # broken file (the parse will fail again, unchanged) re-enqueues a doomed render on every poll —
  # the retry storm `Unsupported` exists elsewhere in this file to avoid — and would make the
  # "failed" branch below DEAD CODE, since preview.status could never still read "failed" by the
  # time this method reads it. Reading the row first and only falling through to Enqueue when
  # nothing exists YET for the current content_token keeps Enqueue as the one-time trigger for the
  # first render (or a re-render after content genuinely changes, via Enqueue's own staleness
  # check) while leaving a terminal ready/failed/unsupported status alone to be reported as is.
  def geometry
    node = current_user.nodes.present.find_by!(node_id: params[:id])
    token = FileLayer.current.stat(current_user, node_id: node.node_id)&.content_token
    return render json: { status: "pending" } if token.nil?

    # BOTH STALENESS AXES, ASKED OF `Enqueue` RATHER THAN SPELLED OUT HERE. This lookup exists to
    # stop a poll re-enqueueing a TERMINAL row (see the comment above), but neither an artifact of
    # SUPERSEDED CONTENT nor one made by an OLDER BUILD is terminal — both are stale, and finding
    # either here would serve its payload back unchanged forever. The revision half is the one
    # with a scar: a file's content never has to change for the code that renders it to, which is
    # exactly what happened when the thinning fix deployed — four already-measured files kept
    # serving mangled curves until they were destroyed by hand. Missing the row sends this through
    # Enqueue, which repoints it and re-renders. It also means bumping a revision un-sticks a
    # `failed` row — right, because the code that failed is not the code running now.
    #
    # `kind` IS NAMED ONCE. It used to be written twice — once to look up the revision, once in
    # the `find_by` — with nothing coupling them, so mis-spelling either half made this lookup
    # silently never match (a re-enqueue on every poll, forever) or match on the wrong kind's
    # revision. `#current_thumbnail` carried the identical three lines 330 lines below, differing
    # only in that string. Note the finder answers WHICH ROW IS CURRENT and nothing more: what
    # this action does with the answer — never reading `status` before deciding to enqueue — is
    # deliberately the OPPOSITE of `#current_thumbnail`'s choice, and §14h forbids unifying that.
    preview = Maker::Previews::Enqueue.current_preview(user: current_user, node_id: node.node_id,
                                                       name: node.name, version_id: token,
                                                       kind: "geometry")
    # NOTHING CURRENT EXISTS -> TRIGGER A BUILD AND SAY "pending", WITHOUT CONSULTING THE ROW'S
    # STATUS. Enqueue deliberately leaves a `ready` artifact visible through a renderer-only
    # rebuild, because a thumbnail is a PICTURE of this same file — blanking it would put a spinner
    # over a correct picture for the whole render (and, before S4-3's page poll, until someone
    # reloaded). Geometry is the opposite on both counts: it is
    # the DATA the client measures and draws from, so an older build's payload is wrong rather than
    # merely old, and this endpoint's client polls, so "pending" costs nothing and resolves itself.
    # Reading `preview.status` here instead would hand back the stale blob URL — exactly the bug
    # the revision check exists to stop.
    if preview.nil?
      Maker::Previews::Enqueue.call(user: current_user, node_id: node.node_id,
                                    name: node.name, version_id: token, kind: "geometry")
      return render json: { status: "pending" }
    end
    case preview.status
    when "ready"
      render json: { status: "ready",
                     url: (url_for(preview.asset) if preview.asset.attached?) }
    when "failed", "unsupported"
      render json: { status: preview.status, error: preview.error }
    else
      render json: { status: "pending" }
    end
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end

  # GET /files/:node_id — view/preview a single file + metadata.
  #
  # THE PORT, NOT Version, AND THAT IS THE SAME FIX AS #blob RATHER THAN SCOPE CREEP. `Version`
  # is a chunk-mode concept: on share and s3 `node.current_version` is nil, and a view that
  # branches on it renders Size "—", Current version "—" and "No content yet." for a file with
  # bytes on the user's NAS -- next to a Download button that now works. Each half is defensible
  # alone and the combination is incoherent, which is exactly why it had to be one task.
  #
  # FileInfo is backend-neutral by construction; being the one object every adapter must answer
  # with is the port's whole job.
  def show
    @node = current_user.nodes.present.find_by!(node_id: params[:id])
    @info = FileLayer.current.stat(current_user, node_id: @node.node_id)
    @kind = preview_kind(@node.name)
    # Editing appears exactly where committing could — one walk, one answer, nothing to keep in
    # sync between the two surfaces.
    @repo_root = Library::WorkingTree.new(current_user).root_for(@node)
    @editable  = @kind == :text && @repo_root.present? && editable?(@node)
    # THE WAY INTO THE COMMIT BOX. Without these two the box is reachable only by typing its URL --
    # which is exactly what shipped on 2026-08-28 and was found by a person using the app, not by
    # the suite: every test navigates straight to repo_commit_path, so nothing was ever asked
    # whether a page LINKS there. `committable_here` is the capability, not a repo check: on a
    # backend without local_worktree the edit is still saved, it is just committed on the machine
    # that holds the repository.
    @committable_here = @repo_root.present? && FileLayer.current.capabilities.local_worktree?
    @pending_count = @repo_root && Maker::RepoEdit.pending_for(current_user, @repo_root.node_id).count
    token = @info&.content_token
    @thumbnail = token && current_thumbnail(@node, token)
    # A ZIP IS A BOARD WHEN ITS CONTENTS SAY SO — the one preview kind decided by a READ rather than
    # by the name. `preview_kind` answers from the name for the whole vocabulary and stays that way;
    # this branch lives here beside `gerber_layers_for`'s `.gbrjob` read, the other server read a
    # Gerber page makes. One port read, bounded and cached (Maker::GerberArchive).
    @gerber_archive = Maker::GerberArchive.archive?(@node.name) &&
                      Maker::GerberArchive.for(user: current_user, node: @node)
    @kind = :gerber if @gerber_archive
    # WHAT THE 3D VIEWER'S IMPORTER CANNOT KNOW — the slicer's per-object filament colours and the
    # model's declared unit, which three.js's 3MFLoader ignores. nil for everything that is not a
    # 3MF (`for` refuses by NAME before it looks at anything else), so this is safe to call for any
    # file and costs a non-3MF nothing. On a 3MF it is the second read this action can make, beside
    # the Gerber one above: ONE port read, bounded on the catalog's size column and cached by
    # content token, so it is one query per view of one file and nothing after the first.
    @viewer_manifest = Maker::ThreeMfManifest.for(user: current_user, node: @node)
    # THE :gerber BRANCH'S LAYER LIST, BUILT HERE BECAUSE ONLY A `.gbrjob` NEEDS A QUERY AND A READ.
    # An ordinary layer is its own whole answer; a job file's page renders the BOARD it names, which
    # means resolving its siblings. Nil for every other kind, so the view's branch and this one
    # cannot disagree about whether the page has a Gerber on it.
    #
    # A ZIPPED EXPORT IS ONE ENTRY — the zip's own URL plus the member paths the BROWSER extracts —
    # built through `FilesHelper#gerber_archive_entry`, the one place that shape is spelled, so that
    # no second literal of keys only a browser reads can drift: nothing on the server would report
    # the two spellings diverging.
    @gerber_layers =
      if @gerber_archive
        [ helpers.gerber_archive_entry(name: @node.name,
                                       url: named_blob_file_path(@node.node_id, filename: @node.name),
                                       members: @gerber_archive.stacked) ]
      elsif @kind == :gerber
        # THE OWNER IS THE VISITOR HERE AND THE URL IS THIS PAGE'S — both are arguments since the
        # sibling walk became shared with the public file page (stage 4, S4-5). The lambda never
        # answers nil on this side: every live node of current_user has a private byte route.
        gerber_layers_for(user: current_user, node: @node,
                          url: ->(n) { named_blob_file_path(n.node_id, filename: n.name) })
      end
    # THE STACKUP/SINGLE CHOICE IS THIS ONE FACT, decided once here rather than re-derived in the
    # template from the size of the list above: a folder holding exactly one layer beside a job file
    # would then read as "single" and lose its Top/Bottom toggle, which is a different question from
    # the one the page is answering.
    #
    # AN ARCHIVE IS NEVER SINGLE, for the `.gbrjob` reason: a zip is a whole export, so the honest
    # render is the BOARD, with Top and Bottom.
    @gerber_single = @kind == :gerber && !gerber_job?(@node.name) && !@gerber_archive
    # THE ATTACH CONTROL'S TWO HALVES. `@attached_projects` is what the file is already in — a
    # file can be in several projects, and until now the page gave no sign it was in any. The
    # dropdown then offers the REST: re-attaching to a project it is already in is a no-op, so
    # listing it would be an option that does nothing.
    attachments = current_user.maker_file_attachments
                              .where(node_id: @node.node_id, attachable_type: "Maker::Project")
                              .includes(:attachable).to_a
    @attached_projects = attachments.filter_map { |a|
      [ a.attachable, a ] if a.attachable && a.attachable.status != "archived"
    }.sort_by { |project, _| name_key(project) }
    scope = current_user.maker_projects.where.not(status: "archived")
    # Guarded: `where.not(id: [])` is a no-op clause in Rails, but writing it unconditionally
    # invites the reader to assume it filters. Say what happens.
    attached_ids = attachments.map(&:attachable_id)
    scope = scope.where.not(id: attached_ids) if attached_ids.any?
    # BOTH LISTS SORT IN RUBY, and NO TEST LEG CAN CATCH A REGRESSION HERE. The chips must sort
    # in Ruby (they come from attachments, not a query), so an SQL `order(:name)` on the dropdown
    # beside them would mean two collations on one line: SQLite is binary and agrees, but
    # production is managed Postgres, where ORDER BY under a non-C locale is effectively
    # case-insensitive — chips reading "Alpha, Bravo, beta" next to a dropdown reading "Alpha,
    # beta, Bravo". One comparator, applied to both.
    @projects = scope.to_a.sort_by { |p| name_key(p) }
    @notes = current_user.maker_notes.where(node_id: @node.node_id).order(created_at: :desc).to_a
    @new_note = current_user.maker_notes.new(node_id: @node.node_id)
    # THE CONNECTED PANEL, BOTH DIRECTIONS IN ONE QUERY (stage 4, S4-8). `touching` is
    # `from_node_id = :n OR to_node_id = :n`; asking twice would be two queries for one panel, and
    # both halves are indexed (the unique index leads on from_node_id, a second index covers
    # to_node_id).
    links = current_user.maker_file_links.touching(@node.node_id).order(:created_at).to_a
    # LIVENESS IS ANSWERED HERE AND NEVER BY THE ROW (§14a). ONE `nodes.present` lookup over every
    # other end; a link whose partner is a tombstone has no entry and the four filter_maps drop it.
    # Maker::AttachmentReaper destroys those rows once the partner's undo window closes — hiding is
    # instant because hiding is reversible, destroying waits because it is not (Maker::DeadNodes).
    partners = current_user.nodes.present
                           .where(node_id: links.flat_map { |l| [ l.from_node_id, l.to_node_id ] }.uniq)
                           .index_by(&:node_id)
    # FOUR LISTS, ONE PER SENTENCE THE PANEL SAYS — resolved here rather than in the template,
    # because the direction rule (Maker::FileLink's KINDS comment) has one home and a view that
    # re-derived it could disagree with the door that wrote the row.
    @derived_from = pick_links(links, partners, "derived_from", :from) # this file's sources
    @derived      = pick_links(links, partners, "derived_from", :to)   # what came out of this file
    @photos       = pick_links(links, partners, "photo_of",     :to)   # pictures OF this file
    @depicts      = pick_links(links, partners, "photo_of",     :from) # what this picture shows
    # ONE ThumbnailMap FOR THE PHOTO CELLS, the shape projects/_photos already uses. `for`
    # backfills on a GET, bounded at BACKFILL_LIMIT — its documented door contract, not a new
    # liberty — and this list is at most the number of photos of one file.
    @link_thumbs = Maker::Previews::ThumbnailMap.for(current_user, @photos.map { |_l, n| n.node_id })
    # The same lookup #index makes for a whole page, asked about one node. Keyed by node_id either
    # way so the view reads it identically; a file no addon produced is simply an absent key.
    @addon_origins = addon_origins_for([ @node.node_id ])
    @move_conflict = move_conflict_prompt
    # WHERE THIS FILE IS, IN THE LIBRARY'S OWN TERMS (stage 4, S4-3; story 2.10). The SAME reader
    # #index uses for its folder column (#folder_paths_for) — Maker::LibraryTree is ONE pluck of
    # this user's dir rows and an in-memory walk: constant in QUERY COUNT and in the number of
    # FILES, linear in the number of DIRECTORIES (a 10k-folder library materialises 10k tuples per
    # file page, the same price #index already pays), and no port read at all. Asking
    # `folder_crumbs`-style, one find_by per level, would be a query per ancestor for the same answer.
    #
    # NIL WHEN THE CHAIN IS BROKEN, AND THE VIEW RENDERS NOTHING THEN. `path_for` answers nil for a
    # tombstoned or missing ancestor (its own contract: "nil IS AN ANSWER, NOT AN ERROR"), and
    # falling back to the bare name would say the file sits at the library root — a confident wrong
    # answer to the one question this row exists to answer.
    #
    # ROOT-RELATIVE, WITH NO SCHEME. `path_for(nil)` is "" for a file at the root, so the join
    # drops it. This app cannot know what the share is mounted as on the maker's machine, so an
    # smb:// or file:// here would be a guess printed as a fact; the maker pastes this into
    # whatever their own Finder/Explorer path is.
    folder_path = Maker::LibraryTree.new(current_user).path_for(@node.parent_node_id)
    @library_path = folder_path && [ folder_path.presence, @node.name ].compact.join("/")
  end

  # PATCH /files/:id — the editor's Save.
  #
  # WORKING TREE ONLY, ON EVERY BACKEND. Share and s3 are current-state only (§14a), so outside a
  # repository a save destroys the previous bytes with nothing to recover from — while on
  # chunk_remote it would be an ordinary new version. One condition with two answers across
  # backends is the shape §14a forbids, so the answer is the same everywhere: git is the undo, and
  # no repository means no editing. Spec part 2 records what reverses this.
  #
  # THE TOKEN CHECK IS NOT OPTIMISTIC POLITENESS. `base_token` is the content_token the editor
  # loaded with; if the file has moved on, the maker edited it in vim meanwhile and a
  # last-write-wins save destroys that edit silently. 409, and nothing written.
  def update
    node = current_user.nodes.present.find_by!(node_id: params[:id])
    root = Library::WorkingTree.new(current_user).root_for(node)
    return render_save_error(:unprocessable_entity, "Only files inside a git repository can be edited.") if root.nil?
    return render_save_error(:unprocessable_entity, "This file is too large to edit here.") unless editable?(node)

    # THE SHARED SAVE (stage 4, S4-4). The stale check, the `replace: true` write that REUSES the
    # node, the pending git edit AND the preview re-enqueue (S4-3's rule: the picture of this file
    # is now wrong, and the save is where that is said) all live in Maker::TextSave, so the project
    # page's README door gets every one of them too. THIS door keeps its own two rules: the size
    # cap above (the SERVER is what enforces it — git-editing.md) and the FetchError → 503 below.
    # `#enqueue_preview` further down stays for the two UPLOAD doors, which share no save.
    result = Maker::TextSave.call(user: current_user, node:, parent_node_id: node.parent_node_id,
                                  name: node.name, body: params[:content], base_token: params[:base_token],
                                  repo_root_node_id: root.node_id)
    return render_save_error(result.status, result.error) unless result.ok

    render json: { ok: true, content_token: result.content_token }
  rescue FileLayer::FetchError => e
    render_save_error(:service_unavailable, e.message)
  end

  # GET /files/:id/history — JSON, fetched by history_controller.js AFTER the page renders. The
  # file page must not wait on a git walk: measured on the live share deployment against a
  # 333-commit repository over its real CIFS mount, a capped walk is ~104 ms cold and a full one is
  # 4,917 ms (tinkerex#178, spec part 3 rule 2).
  #
  # `stopped` REACHES THE WIRE VERBATIM, AND THAT IS THIS ENDPOINT'S WHOLE HONESTY. Path filtering
  # is sparse -- 1 of the last 50 commits touched README.md in the measured repository, against 28
  # of all 333 -- so an empty `entries` usually means "we stopped looking", not "nothing happened".
  # Only "exhausted" licenses the panel to say a file has no earlier history. Report a constant
  # here, or collapse this to a boolean, and the UI starts lying quietly with nothing going red.
  def history
    node, root = repo_context!
    walker, code, reason = open_history(root)
    return render json: no_history(code, reason) if walker.nil?

    rel = repo_relative_path(node, root)
    return render json: no_history("no_repo", "This file's folder is no longer in the library.") if rel.nil?

    result = walker.for_path(rel, walk_limit: history_walk_limit)
    render json: {
      stopped: result.stopped.to_s,
      walked: result.walked,
      # STRUCTURALLY TRUE HERE -- open_history refuses "no_worktree" above -- and asked of the
      # capability anyway rather than written as a literal, so it cannot become a lie if that gate
      # is ever loosened. The panel reads this one key in every response shape.
      restorable: FileLayer.current.capabilities.local_worktree?,
      entries: result.entries.map { |e|
        { oid: e.oid, short_oid: e.short_oid, subject: e.subject,
          author: e.author_name, time: e.time.iso8601 }
      }
    }
  end

  # GET /files/:id/history/:oid — this file's bytes at that commit, as text, for the diff view. The
  # server ships two blobs and diffs neither, exactly as RepoCommitsController#head_blob does.
  #
  # 404 COVERS ALL THREE WAYS TO MISS -- an absent path at that commit, an oid this repository does
  # not contain, and an oid belonging to some other repository -- because every one of them is a
  # URL parameter naming something that is not there, and the caller cannot act on the difference.
  def history_blob
    node, root = repo_context!
    walker, = open_history(root)
    rel = walker && repo_relative_path(node, root)
    content = rel && walker.blob_at(params[:oid], rel)
    return head :not_found if content.nil?

    render plain: content, content_type: "text/plain"
  end

  # POST /files/:id/restore/:oid — put an old version back as a PENDING EDIT. It does not commit;
  # the maker reviews it in the commit box like any other change (spec part 6), which is what makes
  # an accidental restore one click from undone rather than a second commit to write.
  def restore
    node, root = repo_context!
    return render_save_error(:unprocessable_entity, "Only files inside a git repository can be restored.") if root.nil?

    # GATED ON local_worktree? EVEN THOUGH THE PORT WRITES ON EVERY BACKEND. A restore is undone by
    # committing or reverting it, and neither is possible where the repository is not on this box --
    # so a restore the maker cannot then commit is a trap, not a feature. chunk_remote MIRRORS a
    # repository's `.git` directory into the catalog (§14b), so this is a state a real deployment
    # reaches, not a hypothetical.
    #
    # IT IS NOT THE LINE THAT KEEPS THIS OFF `FileLayer::Share#absolute_path` -- probed, not
    # assumed: `LocalRepo#refusal` below asks the same capability FIRST and returns before touching
    # `workdir`, so deleting this block answers 422 either way, in the COMMIT box's words. What
    # this states is the product rule, at the door it belongs to, naming the verb the maker used.
    # (The line that genuinely must not move is `Maker::Git::History.new`, which dereferences
    # `local.rugged` in its constructor -- hence the refusal check strictly before it.)
    unless FileLayer.current.capabilities.local_worktree?
      return render_save_error(:unprocessable_entity, "Restoring needs a library on a local filesystem.")
    end

    local = Maker::Git::LocalRepo.open(current_user, root)
    return render_save_error(:unprocessable_entity, local.refusal) if local.refusal

    rel = repo_relative_path(node, root)
    content = rel && Maker::Git::History.new(local).blob_at(params[:oid], rel)
    return head :not_found if content.nil?

    if content.bytesize > EDITABLE_MAX_BYTES
      return render_save_error(:unprocessable_entity, "That version is too large to restore here.")
    end
    # A NO-OP RESTORE IS REFUSED RATHER THAN PERFORMED. Writing identical bytes creates a pending
    # edit that RepoCommitsController#reconcile immediately drops as :unchanged -- so the button
    # appears to do nothing, which is indistinguishable from the feature being broken. Refusing
    # says what happened.
    if content == FileLayer.current.read(current_user, node_id: node.node_id)
      return render_save_error(:unprocessable_entity, "That version is already what is on disk.")
    end

    # THE SAME DOOR THE EDITOR'S SAVE USES, with `replace: true`, which REUSES the node -- a
    # delete-then-create passes any bytes-oriented test while orphaning every attachment, BOM line
    # and tag pointing at it (§14a).
    Maker::Addons::LibraryOutput.write_bytes!(current_user, parent_node_id: node.parent_node_id,
                                              name: node.name, bytes: content, replace: true)
    Maker::RepoEdit.record!(user: current_user, repo_root_node_id: root.node_id, node_id: node.node_id)
    redirect_to file_path(node.node_id), notice: "Restored. Review it in the commit box."
  rescue FileLayer::FetchError => e
    render_save_error(:service_unavailable, e.message)
  end

  # POST /files — the share/s3 upload: bytes up in one multipart POST, straight to the port.
  #
  # This is the flow §15 does not describe, on the deployments §15 was not aimed at: a mounted
  # directory has nothing to presign, so the bytes must pass through Rails to reach it (spec §2
  # decision 6). S3 could presign a PUT and one day should (spec §5.2, not this phase), which is
  # why the capability is `port_writable` and not `share?`.
  #
  # No FileLayer::Chunk path here, and no server-side chunk-and-commit either: Chunk#write raises
  # on purpose, the gate above is what makes that unreachable, and a second write path into the
  # chunk store would duplicate Sync::Commit, move bytes through Rails, and reach into the sync
  # engine (spec §10).
  def create
    upload = params.require(:file)
    info = FileLayer.current.write(current_user, parent_node_id: params[:parent_node_id],
                                   name: upload.original_filename, io: upload)
    enqueue_preview(node_id: info.node_id, name: upload.original_filename)
    intake_result = intake_project_folder(info.node_id)
    # format.json for the importer (app/javascript/controllers/importer_controller.js via
    # lib/chunk_upload's uploadPortFile): it needs the new node_id to attach in the SAME request
    # that uploaded it. A followed redirect can't carry that back -- fetch() resolves to the
    # redirect TARGET's response, whose Location header is null, so parsing "the redirect" from
    # the client side was always dead code (caught in review, never landed working). Answering
    # JSON directly here is also what let this deployment's OWN 406 bug surface: #show has no
    # JSON responder, so a followed redirect carrying Accept: application/json 406'd on every
    # single port upload -- this format.json branch is what makes the request succeed WITHOUT
    # ever reaching #show.
    #
    # THE CONFLICT FACT (ProjectFolderIntake#left_unfiled_by_conflict?) IS THREADED INTO THIS JSON
    # BRANCH AS OF STAGE 4, S4-3, AND THIS COMMENT USED TO ARGUE THE OPPOSITE. Its argument was
    # sound and its precondition is gone: the omission was justified because `uploadPortFile`'s one
    # caller (importer_controller.js) always targets a MODEL's bundle folder, so
    # #intake_project_folder answered nil on this path regardless. Save-to-library (measure_
    # controller.js) targets the SOURCE FILE'S OWN parent, which is routinely a project folder —
    # so the sweep really can leave a save at the project root, and a caller with a readout really
    # can say so. The old comment's own instruction is what this follows: "#left_unfiled_by_conflict?
    # / #project_intake_notice already exist for it — wire it in here rather than reinventing the
    # check." ONE sentence, built by the concern, identical to the HTML branch's.
    respond_to do |format|
      format.html do
        redirect_to file_path(info.node_id), notice: project_intake_notice(intake_result, upload.original_filename)
      end
      format.json do
        render json: { node_id: info.node_id,
                       notice: project_intake_notice(intake_result, upload.original_filename) },
               status: :created
      end
    end
  end

  # --- Upload: phase 1 (begin) -------------------------------------------------
  # POST /files/begin_upload (JSON)
  #   { name, size, parent_node_id?, manifest: [{hash, offset, length}, ...] }
  # -> { commit_id, node_id, put_urls: { hash => url }, missing }
  # Calls FileLayer#begin_upload (Task 8): records the pending commit + presigns ONLY missing
  # chunks. This controller no longer names Sync::Commit at all -- the port wraps it.
  def begin_upload
    name = params.require(:name)
    # THE NAME CHECK THIS DOOR NEVER HAD — both halves of it, and it was the WEAKEST of the three
    # web doors that mint a name rather than the strongest. `name` went straight to
    # Sync::Commit.begin, which validates the MANIFEST exhaustively and the name not at all, and
    # Node validates `name` for presence only. Probed through the real two-phase flow: begin=200,
    # finalize=200, and a live node called "../../escape.txt" in the changelog, bound for every
    # device's real mount — the exact defect §14c records as closed at the addon door, still open
    # here. `.DS_Store` / `.trash` / `.maker-tmp-x` went the same way.
    #
    # THIS DOOR IS CHUNK-ONLY (`syncable`-gated), which is why nothing cross-backend could catch
    # it: there is no share/s3 leg whose port `leaf!`/`observable!` would have refused these and
    # made the divergence visible. The one guard is the one written here.
    #
    # AT `begin`, NOT `finalize`, because this is where a name enters the system — #finalize_upload
    # is handed a commit_id and never sees a name. Refusing before FileLayer#begin_upload also
    # means no PendingCommit row is written for a name that can never become a legal node.
    #
    # STAYS AT THIS DOOR, NOT MOVED INTO THE PORT (Task 8's own design question, argued rather than
    # assumed): CLAUDE.md §14c's recorded failure shape is exactly "a guard that exists on two
    # backends and silently does not on the third", born from re-implementing one check PER
    # ADAPTER. Share and S3 already validate names inside their OWN `leaf!`; a THIRD, independent
    # copy inside Chunk#begin_upload would be that failure shape again, not a fix for it — the
    # actual fix (2026-08-10) was making every web door that MINTS a name call this SAME shared
    # pairing before choosing a backend at all, which is what already happens here. Moving it into
    # the port would also strand it: LibraryOutput's own save door (Tools::AddonsController#
    # parse_files) already runs the identical pairing before EVER reaching FileLayer, so a copy
    # inside Chunk#begin_upload would run a second time for that caller and never for this one
    # gaining anything — the door is the layer that knows a name is about to be minted; the port
    # does not.
    #
    # Same pairing as Tools::AddonsController#parse_files and LibraryBrowseController#create_folder:
    # syntax first, then the library's own reserved namespace. See Library::ReservedNames.
    unless Maker::MoveNode.valid_leaf_name?(name) && !Library::ReservedNames.reserved?(name)
      return render json: { error: "#{name.inspect} is not a valid file name" },
                    status: :unprocessable_entity
    end
    manifest = (params[:manifest] || []).map { |c| c.permit(:hash, :offset, :length).to_h }

    result = FileLayer.current.begin_upload(
      current_user, device: web_device, name:, parent_node_id: params[:parent_node_id],
      size: params.require(:size).to_i, mtime: (Time.current.to_f * 1e9).to_i, manifest:
    )

    render json: {
      commit_id: result.commit_id, node_id: result.node_id,
      put_urls: result.put_urls, missing: result.missing
    }
    # No `rescue FileLayer::UnsupportedOperation` here -- a malformed manifest raises it now
    # (Chunk#begin_upload re-raises Sync::Commit::InvalidManifest as this), and the controller's
    # own class-level `rescue_from FileLayer::UnsupportedOperation` (above) already renders
    # `{ error: e.message }` at 422, byte-identical to what this action's old per-action rescue
    # produced. A second, redundant rescue here would only ever shadow that one.
  end

  # --- Upload: phase 2 (finalize) ---------------------------------------------
  # POST /files/finalize_upload (JSON) { commit_id }
  # Calls FileLayer#finalize_upload (Task 8; verify: true — confirm the bytes actually landed in
  # storage before creating the immutable version + changelog entry).
  #
  # THE BROADCAST IS THE PORT'S, not this action's, and this comment used to say the opposite.
  # An earlier draft delegated the nudge to each caller because the two that exist happen to want
  # different things; that reopened §14f's "N doors that must all agree" shape, where a third
  # caller forgets and a device silently never hears about a commit. The port now broadcasts by
  # default and Maker::Addons::LibraryOutput opts out explicitly, which is the same behaviour with
  # a safe floor. Nothing to do here.
  def finalize_upload
    result = FileLayer.current.finalize_upload(
      current_user, commit_id: params.require(:commit_id), verify: true
    )
    # THE SAME SENTENCE AS #create's, FOR THE SAME REASON AND SINCE THE SAME SLICE (stage 4, S4-3).
    # This comment previously recorded that the fact was deliberately not surfaced because
    # `uploadChunkFile` "never reads a single key from its response body" — true then, false now:
    # Save-to-library reads `notice` off both doors, and lib/chunk_upload.js returns it from both,
    # so a chunk_remote maker gets the same feedback a share maker gets. Two doors, one wording,
    # which is what stops them drifting (§14a's one-condition-two-answers).
    notice = nil
    if result.info
      enqueue_preview(node_id: result.info.node_id, name: result.info.name)
      notice = project_intake_notice(intake_project_folder(result.info.node_id), result.info.name)
    end
    render json: { version_id: result.version_id, seq: result.seq, notice: }
  rescue FileLayer::ChunksMissing => e
    render json: { error: "chunks_missing", missing: e.hashes }, status: :unprocessable_entity
  end

  # --- Download / view bytes ---------------------------------------------------
  # GET /files/:id/blob — hand the browser the file's bytes, however THIS deployment holds them.
  #
  # THE DELIVERY SWITCH AND THE DISPOSITION POLICY ARE `FileDelivery`'s (stage 3, S3-4), shared
  # verbatim with the sessionless public file route. What is left HERE is the one thing that
  # cannot be shared: which node this request is allowed to see. A node id that doesn't belong to
  # current_user (or doesn't exist) → 404 via the rescue_from at the top of this class, never a
  # 500 and never another user's data.
  def blob
    node = current_user.nodes.present.find_by!(node_id: params[:id])
    deliver_file(current_user, node, download: params[:download].present?)
  end

  # DELETE /files/:id — remove the file from the library, however THIS deployment holds it.
  #
  # ONE DOOR since Stage 2. This branched on port_writable? -- a third of CLAUDE.md 14d's five
  # copies -- because the port refused delete in chunk mode: Chunk#delete now goes through the
  # sync engine itself (Sync::SubtreeDelete.call, under Chunk#delete), so every backend answers
  # this ONE call to FileLayer.current.delete, the same as mkdir/move before it.
  #
  # THE TOMBSTONE ALONE IS ONLY HALF A DELETE ON SHARE/S3, AND THE PORT IS WHAT HOLDS BOTH HALVES
  # TOGETHER. On share/s3 the bytes are a file on the user's NAS or an object in their bucket, and
  # a bare tombstone does not move them: the file stays exactly where it was, the next scan
  # observes it, and Reconciler#create_or_revive! revives the tombstone by storage_path. Share#delete
  # and S3#delete move the bytes to `.trash` FIRST and tombstone after, which is what makes that
  # revive unable to fire. On chunk, Sync::SubtreeDelete IS the whole delete: the bytes belong to
  # the sync engine and the (cascaded) tombstone is the whole truth.
  #
  # A DIRECTORY is refused on share/s3 and cascades on chunk. That is `dir_deletable`, and the
  # refusal arrives as UnsupportedOperation, which this controller already maps to 422. The Delete
  # button IS rendered for directories, so this is the ordinary path, not an edge -- on chunk it is
  # Sync::SubtreeDelete cascading under one lock, never Sync::Mutation.apply(op: "delete"), which
  # tombstones only the node it is handed and would orphan a directory's children.
  def destroy
    node = current_user.nodes.find_by!(node_id: params[:id])
    FileLayer.current.delete(current_user, node_id: node.node_id)
    redirect_to files_path, notice: "Deleted #{node.name}."
  end

  # POST /files/rescan — trigger an immediate reconcile of a share/s3 library instead of waiting
  # for the 15-minute recurring Library::ScanJob.
  #
  # ENQUEUE, NOT INLINE. A scan walks the whole NAS or lists the whole bucket; running it in the
  # request would block Puma and could time out on a large library. The enqueue hands it to Solid
  # Queue (which runs in Puma via SOLID_QUEUE_IN_PUMA -- the same worker the recurring sweep
  # already relies on), and the user refreshes in a moment. The gate above (require_scannable!) is
  # what keeps this off chunk mode, where #perform would raise ArgumentError for want of an
  # observer.
  #
  # THROUGH .enqueue_for, WHICH IS THE PER-USER DOOR -- ScanJob.scan_all! is the all-users SCHEDULE
  # gate, and a bare perform_later here is not a shortcut past either one, it is a DIFFERENT
  # ENQUEUE. `.enqueue_for` is the one place that decides what may be serialized into the queue's
  # database, and it decides two things this action would otherwise get wrong in opposite
  # directions: a share scan must carry its `root:`, because that is the only thing telling an
  # operator reading the failed-jobs table WHICH root refused; an s3 scan must carry none, because
  # an s3 library's target is a bucket plus the credentials to reach it and those must never be
  # written there. This button was a third enqueuer naming neither, so a failed rescan from the
  # Files page was anonymous on exactly the deployment where the root is the useful half.
  #
  # The redirect returns the user to WHAT THEY WERE LOOKING AT, folder or type filter, because the
  # button carries files_query_base and landing at the unfiltered root after a rescan is a lost
  # place. `ext` goes back through resolve_exts rather than being echoed from params: the same
  # whitelist that guards #index guards this, so a hand-edited value cannot ride a redirect.
  def rescan
    Library::ScanJob.enqueue_for(current_user)
    where = { folder: params[:folder].presence, ext: resolve_exts.presence&.join(",") }.compact
    # `scanning: 1` IS WHAT THE PAGE READS to render the poll element, exactly as the project page's
    # own scan door does (Projects::ScansController#enqueue_scan) — one marker, one meaning, two
    # doors. The element's own url is this same path WITHOUT the marker, which is what stops the
    # reloaded page polling again.
    #
    # THE FLASH NO LONGER SAYS "refresh in a moment" (stage 4, S4-3): it said that because nothing
    # here knew when a scan ended. Now something does, and promising a refresh the page will
    # actually perform is the difference story 2.11 named.
    redirect_to files_path(where.merge(scanning: 1)),
                notice: "Scanning your library. This page refreshes when the scan finishes."
  end

  private

  # The ONE comparator behind both halves of the attach control (see #show). Case-insensitive so
  # the Ruby sort matches what a reader expects from Postgres' default collation, with the raw
  # name as the tie-break so "beta"/"Beta" still order deterministically.
  def name_key(project) = [ project.name.downcase, project.name ]

  # The live partner nodes of `links` for one kind, where `@node` is the named END of the pair.
  # `end_` is :from when @node is the link's from_node_id (so the partner is its `to`), and :to
  # when it is the to_node_id. Nothing here queries — `partners` is the one lookup #show made, so
  # the panel costs ONE link query and ONE node query however many links a file has.
  def pick_links(links, partners, kind, end_)
    mine, theirs = end_ == :from ? %i[from_node_id to_node_id] : %i[to_node_id from_node_id]
    links.filter_map { |l|
      partners[l.public_send(theirs)] && [ l, partners[l.public_send(theirs)] ] if
        l.kind == kind && l.public_send(mine) == @node.node_id
    }
  end

  # The thumbnail for THIS content AND this build of its renderer, enqueueing when there is none.
  #
  # #show USED TO ONLY READ, and that is why a bumped revision never reached the detail page: the
  # only thing enqueueing thumbnails is the index's backfill, so a file whose page you opened
  # directly kept rendering an older build's metadata until you happened to visit the list. The
  # Laser Settings panel is drawn from that metadata, which is how a deploy that added layer
  # colours left them invisible on 172 of 174 files.
  #
  # Enqueue returns the repointed row (status "pending", so the view shows "Generating preview…"
  # rather than an older artifact labelled as current) or nil when nothing can render this name.
  def current_thumbnail(node, token)
    row = Maker::Previews::Enqueue.current_preview(user: current_user, node_id: node.node_id,
                                                   name: node.name, version_id: token,
                                                   kind: "thumbnail")
    return row if row

    Maker::Previews::Enqueue.call(user: current_user, node_id: node.node_id,
                                  name: node.name, version_id: token, kind: "thumbnail")
  end

  # Eagerly render a thumbnail for a file whose bytes just landed. Backend-neutral: content_token
  # is the per-backend content id that keys maker_previews.version_id (FileLayer::FileInfo), so a
  # new content supersedes. Never raises into the request -- a preview is best-effort UX, not part
  # of the write's success; a vanished/unmounted file just means the scan will catch up later.
  def enqueue_preview(node_id:, name:)
    info = FileLayer.current.stat(current_user, node_id:)
    return unless info&.content_token

    ::Maker::Previews::Enqueue.call(user: current_user, node_id:, name:, version_id: info.content_token)
  rescue FileLayer::NotFound, FileLayer::FetchError
    nil
  end

  # Chunk mode's catalog is the sync engine's changelog; a manual scan is meaningless there. Reads
  # the SAME `capabilities` the views and the v1 gate read (no second path to the answer), but
  # answers the WEB way -- a redirect with an alert, not the concern's JSON 501.
  def require_scannable!
    return if capabilities.scannable?

    redirect_to files_path,
                alert: "This library doesn't support manual rescans."
  end

  # List or grid. An explicit `?view=` wins and is remembered in a cookie (so it persists as the
  # user navigates folders); otherwise the last remembered choice; otherwise `list`. Only the two
  # known values are ever honored — a junk `?view=` or a tampered cookie falls back to the default
  # rather than reaching the view as an arbitrary string.
  VIEWS = %w[list grid].freeze
  DEFAULT_VIEW = "list".freeze

  def resolve_view
    requested = params[:view].presence
    if VIEWS.include?(requested)
      cookies[:files_view] = { value: requested, expires: 1.year }
      return requested
    end
    saved = cookies[:files_view]
    VIEWS.include?(saved) ? saved : DEFAULT_VIEW
  end

  # Whether dot-prefixed entries are shown. THE SAME WHITELIST-AND-COOKIE IDIOM AS resolve_view,
  # and a cookie for a reason a param cannot cover: the choice has to survive clicking INTO a
  # folder, and folder links are plain `files_path(folder: …)` in the breadcrumb, the list's folder
  # rows and the grid's folder cards. Threading `hidden` through every one of them is the shape
  # that goes stale the first time somebody adds another link — which is exactly why `view` and
  # `sort` are cookies rather than members of `files_query_base`.
  #
  # `requested == "1"` IS WHAT MAKES THE CONTROL TWO-WAY, and it is the line to leave alone. The
  # "Hide" link emits `?hidden=0`, which is `present?` — so the first draft of this, a bare
  # `@show_hidden = params[:hidden].present?`, read that as SHOW and the toggle could turn dot-files
  # on and never off again. Pinned by files_git_marker_test's `?hidden=0` case.
  #
  # THE WHITELIST IS THE SMALLER CLAIM AND IS DESCRIBED HONESTLY: it bounds what can be WRITTEN
  # into the cookie, so a hand-edited `?hidden=banana` does not persist junk for a year. It is not
  # what makes `?hidden=0` behave — swapping it for `present?` leaves every behaviour here
  # unchanged (mutation-checked; nothing went red), so it earns a sentence, not a warning.
  HIDDEN_VALUES = %w[0 1].freeze

  def resolve_hidden
    requested = params[:hidden].presence
    if HIDDEN_VALUES.include?(requested)
      cookies[:files_hidden] = { value: requested, expires: 1.year }
      return requested == "1"
    end
    cookies[:files_hidden] == "1"
  end

  # Sort key + direction. THE SAME WHITELIST IDIOM AS resolve_view, and for the same reason: an
  # unknown `?sort=` or a tampered cookie must fall back to the default rather than reach the
  # sorter as an arbitrary string. Stored as one "key:dir" cookie value, so the choice survives
  # navigation exactly as the list/grid choice does.
  #
  # `?dir=` alone (no `?sort=`) is ignored, matching resolve_view: a direction with nothing to
  # direct is not a choice. Both selects in the grid's sort form submit together, and every header
  # link carries both, so nothing in the UI can produce that shape.
  SORTS = %w[name type modified].freeze
  DEFAULT_SORT = "name".freeze
  DIRS = %w[asc desc].freeze

  # Rows per folder page. The folder view had NO bound at all — flat mode was capped at FLAT_LIMIT
  # because "a folder is self-limiting and a whole-library view is not", which is true of a tidy
  # library and false of a NAS directory with ten thousand children: measured at 2000 children the
  # page is 225–307 ms of which 175–278 ms is ERB, on 5 queries and ~0 ms of database, so the cost
  # is per-ROW rendering and the only fix is to render fewer rows. 250 keeps a page comfortably
  # under 40 ms of that render while still being a screenful for anyone paging by hand.
  #
  # A CAP WOULD HAVE BEEN WRONG HERE even though it is right for flat mode: a truncated SEARCH is
  # "your top matches", but a truncated FOLDER hides children in the app's primary navigation
  # surface, with no way to reach them. Paging bounds the render without hiding anything.
  FOLDER_PAGE = 250
  DEFAULT_DIR = "asc".freeze

  def resolve_sort
    requested = params[:sort].presence
    if SORTS.include?(requested)
      dir = DIRS.include?(params[:dir]) ? params[:dir] : DEFAULT_DIR
      cookies[:files_sort] = { value: "#{requested}:#{dir}", expires: 1.year }
      return [ requested, dir ]
    end
    key, dir = cookies[:files_sort].to_s.split(":")
    return [ key, dir ] if SORTS.include?(key) && DIRS.include?(dir)

    [ DEFAULT_SORT, DEFAULT_DIR ]
  end

  # IN RUBY, NOT IN SQL, AND THAT IS A DECISION (spec §5.2). "type" means the file's EXTENSION,
  # and there is no expression for it portable across SQLite (self-host) and Postgres (managed) --
  # substr/instr vs substring/position. The alternative, a denormalized `ext` column on `nodes`,
  # would have to be populated by Sync::Commit and Sync::Mutation: writing to the sync layer to
  # serve a web view, which is the maker/file-layer split's §10 tripwire. So all three keys sort
  # the same way, uniformly, and none is more exact than another. The cost is the shape this
  # action already has (it loads the folder with .to_a and select!s in memory).
  #
  # Ruby's sort is NOT STABLE, so the comparator carries the input index as an explicit last
  # resort -- without it, equal keys (two .stl files, two nodes with the same mtime) shuffle
  # between page loads. The input order is the query's `name: :asc`, so equal keys stay
  # alphabetical.
  #
  # THE TIEBREAK RUNS ASCENDING IN BOTH DIRECTIONS, and that is a deliberate difference from the
  # `sort ascending then reverse!` this used to be. Reversing flips the ties too, so "sort by Type
  # descending" reordered files *within* one extension for no reason the user asked for -- and it
  # made the folder view disagree with the flat view, whose SQL breaks ties ascending (flat_order).
  # Negating the comparison instead reverses only what the user chose to reverse.
  #
  # Directories stay grouped AFTER files. `partition` rather than a second sort: it is O(n) and
  # stable by construction, where the sort it replaced was stable only because it hand-carried an
  # index. SYMLINKS GROUP WITH FILES here, deliberately -- this pass asks only "is it a directory",
  # and a symlink is not one, so it belongs in the file block rather than above every real file
  # (which is where the `kind: :desc` ordering this replaced put it, purely because "symlink" >
  # "file" alphabetically -- an accident of a column, not a design). WHERE IT SITS INSIDE THAT
  # BLOCK IS sort_key's ANSWER, AND IT IS "WITH THE OTHER SYMLINKS", NOT "WITH THE EXTENSION IT IS
  # NAMED AFTER" -- see the type branch there. The two are separate questions and an earlier
  # reading of this paragraph ("they are usually symlinks TO files") was used to answer both.
  def sort_nodes(nodes, info, key, dir)
    sign = (dir == "desc") ? -1 : 1
    ordered = nodes.each_with_index.sort { |(a, ai), (b, bi)|
      ((sort_key(a, info, key) <=> sort_key(b, info, key)) * sign).nonzero? || (ai <=> bi)
    }.map(&:first)
    files, dirs = ordered.partition { |node| !node.dir? }
    files + dirs
  end

  # One key per node, and every branch must answer the SAME Ruby type for a given key or the
  # comparison raises: a nil mtime (a directory, an un-stat'd row) becomes 0, not nil.
  #
  # "type" IS THE Type COLUMN'S OWN LABEL, DOWNCASED -- the extension for a file, and the literal
  # "symlink" for a symlink, which is what FilesHelper#file_type_label renders in the cell. That
  # helper states the agreement as an invariant ("MUST AGREE WITH WHAT THE 'Type' HEADER SORTS BY")
  # and this is the half that holds it up.
  #
  # A SYMLINK IS ITS OWN TYPE, NOT THE EXTENSION IT HAPPENS TO END IN, and keying it on the
  # extension CONTRADICTED the column two lines below the invariant. Reproduced with aaa.stl,
  # bbb.stl, ccc.3mf and a symlink mid.stl: `?sort=type&dir=asc` rendered Type cells reading
  # ["3MF", "Symlink", "STL", "STL"] -- a row labelled Symlink sitting inside the STL block, under
  # a header claiming to sort by exactly what the cells show. `symlink` is a first-class
  # Node::KIND that git-on-mount depends on, so this is a real row, not a curiosity.
  #
  # THE LITERAL "symlink", NOT A SENTINEL THAT SORTS FIRST OR LAST: the group then lands where the
  # word "Symlink" falls among the other labels, which is what someone reading the column expects,
  # and it needs no rule about which end symlinks belong at. (The `kind: :desc` ordering the
  # grouping pass replaced put them first, above every real file, purely because "symlink" sorts
  # after "file" -- an accident of a different column, which is why an explicit end would be one
  # too.)
  #
  # GROUPING WITH FILES RATHER THAN FOLDERS IS A DIFFERENT QUESTION, still answered the same way in
  # sort_nodes' partition: a symlink is not a directory. Its own type key decides where it sits
  # INSIDE the file block.
  #
  # Two cases where the key and the label part company, both left alone deliberately: an
  # extension-less file keeps the EMPTY key while its cell shows an em-dash (so it sorts with the
  # other no-type files at whichever end "" falls, rather than at whichever end "—" falls -- both
  # group, and "" is the one already shipped), and a DIRECTORY is keyed on its extname, which is
  # read only for dir-against-dir order since sort_nodes partitions them out afterwards.
  # ONLY THE NAME SORT PAGES, AND THE OTHER TWO ARE NOT AN OVERSIGHT.
  #
  # Paging means SQL chooses the rows, so SQL has to be able to express the display order. Of the
  # three sorts only `name` maps to a column:
  #   - `type` is COMPUTED — File.extname(...).downcase minus the dot, except a symlink, which
  #     keys on the literal "symlink". FilesHelper states the agreement between that key and the
  #     rendered Type cell as an invariant, and reproducing it in SQL means reproducing it twice
  #     (SQLite and Postgres) and keeping all three in step forever.
  #   - `modified` reads the PORT's mtime out of @info_by_node, not `nodes.mtime`. Those are
  #     different authorities by design — the whole reason stat_all exists — and quietly swapping
  #     one for the other in an ORDER BY would change what "Modified" means, per backend, with
  #     nothing to say so.
  # So those two keep today's full-folder load. The ceiling is therefore fixed for the DEFAULT
  # view and still open for a user who has clicked Type or Modified; that is a deliberate,
  # stated limit, not a claim to have bounded the page in general.
  def paged_folder? = @sort == DEFAULT_SORT

  # The display order, IN SQL, for the name sort — it must match what sort_nodes would have
  # produced or paging drops and duplicates rows across page boundaries.
  #
  # Three parts, each mirroring one line of the Ruby it replaces: directories LAST (sort_nodes ends
  # `files + dirs`, and a symlink counts as a file there, so the test is `kind = 'dir'`, not a
  # three-way order); then the name, CASE-INSENSITIVELY, because sort_key downcases; then `name`
  # itself as a deterministic tie-break so two names differing only in case cannot swap places
  # between two requests and shuffle a row across a page edge.
  #
  # Arel, not string interpolation: `dir` is user input off the query string. It is already
  # constrained to DIRS by resolve_sort, so this is defence in depth rather than the only guard —
  # but an ORDER BY built by interpolating a param is exactly the shape Brakeman flags and the
  # shape that is one refactor away from being unguarded.
  def folder_page_order(dir)
    nodes = Node.arel_table
    descending = dir == "desc"
    name_key = Arel::Nodes::NamedFunction.new("LOWER", [ nodes[:name] ])
    [
      Arel::Nodes::Grouping.new(nodes[:kind].eq("dir")).asc,
      descending ? name_key.desc : name_key.asc,
      descending ? nodes[:name].desc : nodes[:name].asc
    ]
  end

  # Clamped, never trusted: a page number out of range must land on a real page rather than an
  # empty one, so `?page=999` on a two-page folder shows page 2 and `?page=0`/garbage shows page 1.
  # An out-of-range page rendering blank is how a paged list gets reported as "my files vanished".
  # `to_s` FIRST (tinkerex#290): Rack hands `?page[]=2` over as an Array and `?page[a]=2` as
  # Parameters, and `to_i` on either is a NoMethodError — a 500 for a hand-edited URL. The same
  # shape Public::UsersController#requested_page fixed for the anonymous page in PR #342.
  def resolve_page(pages)
    params[:page].to_s.to_i.clamp(1, pages)
  end

  def sort_key(node, info, key)
    case key
    when "type"     then node.symlink? ? "symlink" : File.extname(node.name).downcase.delete(".")
    when "modified" then info[node.node_id]&.mtime || 0
    else                 node.name.downcase
    end
  end

  # Query params every in-page link must carry so sorting never drops the user's folder or filter.
  # `view` is deliberately absent: it is cookie-persisted, so a link that pinned it would freeze a
  # choice the user can still change from the toggle -- and `sort`/`dir` are absent for the same
  # reason, except on the header links and the grid form, which are the controls that SET them.
  #
  # `folder` and `ext` are never both present: flat mode NILs @folder (see #index), so this is one
  # key or the other, never an intersection the rest of the page would have to make sense of.
  helper_method :files_query_base
  def files_query_base
    { folder: @folder&.node_id, ext: @exts.presence&.join(","), q: @q }.compact
  end

  # A file extension is 1-8 lowercase alphanumerics. ANYTHING ELSE IS DROPPED, not escaped and not
  # rejected with an error: this arrives in a URL a user can hand-edit or a crawler can mangle, and
  # falling back to the ordinary folder view is the honest answer to "that isn't an extension".
  # The whitelist is also what bounds the LIKE below -- sanitize_sql_like alone would still let a
  # 4KB `ext` build a query with hundreds of OR clauses, and it would still let LIKE's own
  # wildcards (`%`, `_`) through as characters the escape then has to neutralise one by one.
  EXT_RE = /\A[a-z0-9]{1,8}\z/
  MAX_EXTS = 8
  # The one bound this page has ever had. The folder view is still unbounded (a folder is
  # self-limiting; a whole-library type view is not), and the truncation is ANNOUNCED -- a silent
  # cut reads as "that's all your STLs", which is the same class of lie as a paginated listing
  # mistaken for a snapshot. Pagination is the follow-up if a real library hits this.
  FLAT_LIMIT = 2000

  # The library search (spec §9). Stripped and bounded; blank is nil so `if @q` reads as "a search
  # is active". 80 characters is longer than any name the list shows without an ellipsis, and it
  # bounds the LIKE the same way EXT_RE bounds the type filter's.
  QUERY_MAX = 80

  def resolve_query
    params[:q].to_s.strip.first(QUERY_MAX).presence
  end

  # EVERY EXTENSION THE USER'S LIBRARY ACTUALLY HOLDS, with how many files carry it:
  # { "stl" => 42, "lbrn2" => 17, ... }. This is what the type filter offers.
  #
  # THE CONTROL IT REPLACED LISTED THE VOCABULARY, NOT THE LIBRARY. `FilesHelper::EXT_FAMILIES`
  # is derived from `ROLE_BY_EXT`, so the chip row offered `.sldasm`, `.ngc` and `.fcstd` to
  # someone who has never owned one, in a wall of ~35 chips, while a `.kicad`-shaped extension the
  # user really did have appeared nowhere and had to be typed into a free-text box beside it. A
  # dropdown built from this hash has the opposite property in both directions: everything offered
  # exists, and everything that exists is offered.
  #
  # IN RUBY, AND §5.2 IS WHY: there is no expression for "the file's extension" portable across
  # SQLite and Postgres (substr/instr vs substring/position), and a denormalised `ext` column would
  # have to be written by Sync::Commit and Sync::Mutation — the maker/file-layer §10 tripwire, to
  # serve a filter. So this is ONE query returning N short strings, tallied here.
  #
  # THE COST IS UNBOUNDED IN N, stated because it is a real property of this page rather than a
  # hypothetical. MEASURED on this box (SQLite, one user, 13 extensions):
  #
  #     20,000 files -> 14.4 ms total, of which 3.1 ms is the query
  #    100,000 files -> 86.2 ms total, of which 11.3 ms is the query
  #
  # So the database is not the cost — the per-row `File.extname` in Ruby is, ~7/8ths of it. For
  # scale, the same page already spends 175-278 ms of ERB rendering 2000 rows (see FOLDER_PAGE),
  # which is why this is not cached: a cache would add a second query and a staleness window to
  # shave a tenth of what the render costs. It is ONE query whatever N is, which is the property
  # page_query_budget_test.rb actually asserts. A library big enough for the milliseconds to matter
  # will have hit CLAUDE.md §12 item 8 (the render cost) long before it notices this.
  #
  # FILTERED BY EXT_RE, so the options can only ever be extensions #resolve_exts will accept. A
  # `.tar.gz` or a name ending in a 30-character suffix is simply not offered, rather than
  # rendering an option that links and silently does nothing — the exact defect `ext_slots_left?`
  # exists to prevent one control over.
  def ext_facets
    current_user.nodes.present.where(kind: "file").pluck(:name)
                .each_with_object(Hash.new(0)) do |name, tally|
      ext = File.extname(name.to_s).downcase.delete(".")
      tally[ext] += 1 if ext.match?(EXT_RE)
    end
  end

  # `add_ext` is the type dropdown's own param; it simply joins the list, so there is one filter
  # param and one code path rather than two ways to say the same thing. (It was the free-text field
  # beside the chips before the dropdown replaced both.) `.to_s` on each, because `?ext[]=a` and
  # `?ext[x]=y` hand us an Array and a Parameters -- both stringify into something the whitelist
  # below then drops, which is the point.
  def resolve_exts
    [ params[:ext], params[:add_ext] ].compact_blank.map(&:to_s).join(",")
      .downcase.split(",").map(&:strip).select { |e| e.match?(EXT_RE) }.uniq.first(MAX_EXTS)
  end

  # Every file in the library whose name ends in one of `exts`. One OR-ed LIKE per extension, all
  # bound -- the interpolation is the CLAUSE (a fixed string repeated), never a value.
  #
  # `kind: "file"` EXCLUDES SYMLINKS AS WELL AS DIRECTORIES, AND THE SYMLINK HALF IS A DECISION,
  # not a spillover from the directory one. Spec §6.3 argues only the directory ("a directory has
  # no extension and never appears in a type view"); this is the missing sentence. A type filter
  # asks "show me my STLs", and a symlink named alias.stl is NOT an STL -- its content is a path to
  # one. That is the same answer the Type column and sort_key give it (both say "Symlink", not
  # "STL"), so admitting it here would put a row in the results whose own Type cell contradicts the
  # filter that selected it.
  #
  # A DELIBERATE DIVERGENCE FROM THE FOLDER VIEW, WHICH DOES LIST THEM -- do not "fix" it back. The
  # two views answer different questions: a folder view shows what is IN a folder, so omitting a
  # symlink would hide something that is really there, while a type view shows what you asked for
  # and this is not that type. Where the link points inside the library the real file is already in
  # the results on its own row; where it points outside, there is no file of that type to list.
  # It is also why flat_order needs no symlink branch to match sort_key's: its CASE only ever ranks
  # rows this scope admitted, and no symlink is one.
  #
  # LOWER(name), not a bare LIKE: SQLite's LIKE is ASCII-case-insensitive and Postgres' is not, so
  # the bare form would answer differently on self-host and managed. `exts` is already downcased.
  def flat_ext_scope(exts)
    clause = Array.new(exts.size, LIKE_EXT).join(" OR ")
    current_user.nodes.present.where(kind: "file").where(clause, *exts.map { |e| like_pattern(e) })
  end

  # `ESCAPE '\'` IS NOT DECORATION, AND WITHOUT IT sanitize_sql_like BELOW IS A NO-OP ON HALF THE
  # DEPLOYMENTS. Postgres treats backslash as LIKE's escape character by default; SQLite has NO
  # default escape character at all, so the backslash sanitize_sql_like inserts is matched as a
  # LITERAL backslash and `_` stays a wildcard. Verified on this repo's connection:
  #
  #   'x.st\l' LIKE '%.st\_'                -> 1   (self-host: escaping did nothing)
  #   'x.st\l' LIKE '%.st\_' ESCAPE '\'     -> 0
  #
  # So the earlier version of this comment promised a second layer that only existed on managed
  # Postgres. EXT_RE makes both unreachable today -- it drops `%` and `_` outright -- but "fails
  # closed by accident on one database" is not defense in depth, and the two would have disagreed
  # the moment the whitelist was loosened. One clause, both databases, same answer.
  LIKE_EXT = "LOWER(name) LIKE ? ESCAPE '\\'".freeze

  # The ONE place the match pattern is built. The WHERE and the ORDER BY below must agree about
  # what "ends in .stl" means -- if they ever drifted, the CASE would rank a row the WHERE had
  # admitted on different grounds, which is a wrong sort with no error anywhere.
  def like_pattern(ext) = "%.#{ActiveRecord::Base.sanitize_sql_like(ext)}"

  # THE PAGE'S ORDER BY, IN SQL, AND IN FLAT MODE THAT IS NOT AN OPTIMISATION -- IT IS THE
  # SELECTION. `LIMIT` takes rows in whatever order the query is already in, so ordering by name
  # and then re-sorting the slice in Ruby hands the user the alphabetical head of their library
  # under a banner that says "the first N". Measured before the fix: 30 .stl files, FLAT_LIMIT 5,
  # `?ext=stl&sort=modified&dir=asc` rendered the five NEWEST and called them the first five.
  #
  # §5.2 STILL HOLDS; THIS IS NOT A CONTRADICTION OF IT. That decision says there is no expression
  # for "the file's extension" portable across SQLite and Postgres, and there still isn't. Flat
  # mode does not need one: it already knows every extension a matching row can have (`exts`, at
  # most MAX_EXTS of them), so ranking them is a CASE over the same patterns the WHERE uses --
  # ordinary ANSI SQL. The folder view has no such list (its extensions are whatever is on disk),
  # which is why it still sorts in Ruby and sort_nodes stays the one comparator there.
  def flat_order(exts, key, dir)
    direction = (dir == "desc") ? "DESC" : "ASC"
    # `name` then `node_id`, always, and both ASCENDING whichever way the key runs.
    #
    # BARE `name`, NOT `LOWER(name)`, AND ONLY BECAUSE THAT IS WHAT THE FOLDER VIEW ALREADY DOES.
    # Its query is `order(kind: :desc, name: :asc)` and sort_nodes breaks ties by that input order,
    # so matching it verbatim is what makes the two views agree about ties on whichever database
    # is underneath -- binary on SQLite, locale-collated on Postgres, but the SAME on both sides of
    # the comparison. A case-insensitive tie order would read better; it would also have to change
    # the folder view in the same commit, and this one is not that.
    #
    # `node_id` last is what makes the order TOTAL: names repeat across folders, so `order(:name)`
    # alone -- which is what this replaced -- left the row that lands on the truncation boundary up
    # to the query planner.
    tail = "name ASC, node_id ASC"
    sql, *args =
      case key
      when "modified"
        # COALESCE, because a NULL mtime sorts FIRST on SQLite and LAST on Postgres -- the very
        # split §5.2 is about. sort_key reads a nil mtime as 0; this is the same reading.
        [ "COALESCE(mtime, 0) #{direction}, #{tail}" ]
      when "type"
        ranked = exts.sort
        whens = ranked.each_with_index.map { |_, i| "WHEN #{LIKE_EXT} THEN #{i}" }
        # The ELSE is unreachable -- every row here matched one of these same patterns in the
        # WHERE -- but it must be written anyway: a CASE with no ELSE yields NULL, and NULL
        # ordering is the SQLite/Postgres split a third time.
        [ "CASE #{whens.join(' ')} ELSE #{ranked.size} END #{direction}, #{tail}",
          *ranked.map { |e| like_pattern(e) } ]
      else
        # LOWER, not bare `name`: sort_key downcases, and a binary ORDER BY files "Bracket.stl"
        # before "apple.stl". Matching it is what lets the two views agree.
        [ "LOWER(name) #{direction}, #{tail}" ]
      end
    Arel.sql(ActiveRecord::Base.sanitize_sql_array([ sql, *args ]))
  end

  # node_id -> "cad/sub" for the flat view's Folder column, because a flat list of 200 STLs with no
  # location is unnavigable. ONE query for the user's dirs (a library has few, even with a great
  # many files), assembled in Ruby -- never a parent walk per row, which is the shape this page
  # can least afford: its row count is the size of the library, not the size of a folder.
  #
  # THE ANCESTRY WALK IS Maker::LibraryTree'S, NOT A THIRD COPY. This page used to carry its own
  # cycle guard -- an "…" written into the cache before recursing -- and folder_crumbs still
  # carries a `visited` Set for the same reason, but a marker is a GUARD, not an ANSWER: it
  # terminated the recursion and then rendered a literal ellipsis into the middle of the path as
  # where the user's file lives. `path_for` answers nil for any unresolvable chain (cycle,
  # tombstoned or missing ancestor), and _list.html.erb already renders nil as "Files" while the
  # folder link goes to node.parent_node_id either way, so navigation is untouched and the label
  # stops claiming a folder that is not there. Same one query; only the flat view calls this.
  def folder_paths_for(nodes)
    tree = Maker::LibraryTree.new(current_user)
    nodes.to_h { |n| [ n.node_id, tree.path_for(n.parent_node_id) ] }
  end

  # `params[:folder]` is USER INPUT in a URL. Accept it ONLY when it names a `dir` the
  # current_user owns and has not deleted; anything else — absent, blank, a file, a foreign or
  # nonexistent id — falls back to the library root (nil). `find_by` returns nil rather than
  # raising, so a bogus id renders root instead of a 500, and the `current_user.nodes` scope is
  # what makes a foreign id un-findable rather than a leak. The whole tree lives under one user,
  # so there is nothing to escape into once the lookup is user-scoped.
  def current_folder
    id = params[:folder].presence
    return nil if id.nil?

    current_user.nodes.present.find_by(node_id: id, kind: "dir")
  end

  # The path from the library root down to `folder`, root-most first, for the breadcrumb. Walks
  # up parent_node_id — the SAME string key #index scopes on — re-scoping every hop to
  # current_user so a foreign or broken parent stops the walk (it resolves to nil) rather than
  # leaking a node or the loop running off the user's tree. A `visited` set stops a cycle a
  # corrupt row could introduce from spinning forever. `folder` nil (root) yields [].
  def folder_crumbs(folder)
    crumbs = []
    visited = Set.new
    node = folder
    while node && visited.add?(node.node_id)
      crumbs.unshift(node)
      node = node.parent_node_id &&
             current_user.nodes.present.find_by(node_id: node.parent_node_id, kind: "dir")
    end
    crumbs
  end

  # A TRUNCATED BUFFER IS NEVER EDITABLE, and this is the reason the cap is duplicated on the
  # server rather than trusted from the client. codeview_controller fetches at most MAX_BYTES and
  # appends "… (truncated)"; saving that buffer would TRUNCATE THE FILE. The browser already
  # refuses to mount an editor over the cap, but a refusal that only lives in JavaScript is a
  # refusal an unmodified `curl` walks straight past.
  EDITABLE_MAX_BYTES = 200_000

  def editable?(node)
    return false unless Maker::FileAttachment.text?(node.name)

    size = FileLayer.current.stat(current_user, node_id: node.node_id)&.size
    size.present? && size <= EDITABLE_MAX_BYTES
  end

  def render_save_error(status, message)
    render json: { ok: false, error: message }, status:
  end

  # --- History and restore (tinkerex#178) -----------------------------------------------------

  def repo_context!
    node = current_user.nodes.present.find_by!(node_id: params[:id])
    [ node, Library::WorkingTree.new(current_user).root_for(node) ]
  end

  # [Maker::Git::History, nil, nil] for a repository this deployment can read, or
  # [nil, code, sentence] saying why not. The code is what the panel branches on; the sentence is
  # what it shows.
  #
  # THE CAPABILITY IS ASKED FOR ITS OWN CODE, not for safety: `LocalRepo#refusal` below asks it
  # first too and would answer anyway. The panel needs to tell "this deployment holds no working
  # tree" (nothing to offer, ever) from "this repository is busy right now" (come back), and one
  # sentence cannot say both. chunk_remote MIRRORS a repository's `.git` directory into the catalog
  # (§14b), so `root` is non-nil there and this is a live path rather than a hypothetical.
  #
  # THE ORDER OF THE LAST TWO LINES IS THE ONE THAT MATTERS. `Maker::Git::History.new` dereferences
  # `local.rugged` in its constructor, which resolves the port's `absolute_path` -- and
  # FileLayer::Share is the only adapter that has one, so constructing it before the refusal check
  # is a NoMethodError 500 rather than a refusal.
  #
  # THE REFUSAL IS THE COMMIT BOX'S OWN rather than a second opinion about one repository (§14a:
  # one condition, one answer). It is also what turns a `.git` row over a directory git cannot open
  # into a sentence instead of an unrescued Rugged error -- and it is deliberately the WHOLE
  # refusal, lock files and half-finished merges included: a page whose first affordance overwrites
  # a working tree mid-rebase is not one this app should render, however readable the history
  # behind it happens to be.
  def open_history(root)
    return [ nil, "no_repo", "This file is not inside a git repository." ] if root.nil?

    unless FileLayer.current.capabilities.local_worktree?
      return [ nil, "no_worktree", "History needs a library on a local filesystem." ]
    end

    local = Maker::Git::LocalRepo.open(current_user, root)
    return [ nil, "unavailable", local.refusal ] if local.refusal

    [ Maker::Git::History.new(local), nil, nil ]
  end

  # The SAME KEYS as a successful walk, so the panel reads one shape whatever happened. `stopped`
  # is never "exhausted" here: that value alone licenses "this file has no earlier history", and
  # none of these conditions has established anything of the kind.
  def no_history(code, reason)
    { stopped: code, reason:, walked: 0, restorable: false, entries: [] }
  end

  # The path git knows this file by. DERIVED FROM THE CATALOG, never rebuilt from names: it is the
  # same source RepoCommitsController#reconcile resolves against, so the history panel and the
  # commit box cannot disagree about what a file is called.
  #
  # `Maker::LibraryTree` INDEXES DIRECTORIES ONLY, so the tree is asked about the PARENT and the
  # file's own name is appended -- asking it about the file's own node_id answers nil for every
  # file in the library.
  #
  # NIL IS AN ANSWER, NOT A CRASH. `path_for` answers nil for a broken ancestor chain (a tombstoned
  # intermediate directory), which Library::WorkingTree's own walk does not refuse; without the
  # guard the interpolation below builds "/name", `delete_prefix("/")` turns it into a
  # plausible-looking path at the repository ROOT, and git answers about a different file.
  def repo_relative_path(node, root)
    tree = Maker::LibraryTree.new(current_user)
    parent = tree.path_for(node.parent_node_id)
    root_path = tree.path_for(root.node_id)
    return nil if parent.nil? || root_path.nil?

    full = "#{parent}/#{node.name}"
    full.start_with?("#{root_path}/") ? full.delete_prefix("#{root_path}/") : nil
  end

  # Bounded by the service's own ceiling, so a caller cannot ask for an unbounded walk however they
  # spell the parameter -- the cap is a correctness rule, not an optimisation (spec part 3). A
  # missing, zero, negative or junk value is the DEFAULT rather than an error: this is a query
  # string, and the honest response to junk is the ordinary page.
  def history_walk_limit
    requested = params[:walk_limit].to_i
    return Maker::Git::History::DEFAULT_WALK_LIMIT if requested <= 0

    requested.clamp(1, Maker::Git::History::MAX_WALK_LIMIT)
  end
end
