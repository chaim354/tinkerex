# Server-rendered web UI for the file library: list, upload, download, view, delete.
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

  # Content types safe to render inline in the app origin. Raster images only — deliberately
  # NO image/svg+xml (SVG can carry <script>) and NO text/html, which would be stored XSS.
  SAFE_INLINE_TYPES = %w[
    image/png image/jpeg image/gif image/webp image/bmp
    image/x-icon image/vnd.microsoft.icon
  ].freeze

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
    # FLAT MODE. An extension filter is a question about the LIBRARY, not about a folder, so
    # ?folder= is ignored outright rather than intersected -- "show me every .stl" that quietly
    # meant "in this folder" would be the wrong answer to the only question the chips can ask.
    @exts = resolve_exts
    @flat = @exts.any?
    if @flat
      @folder = nil
      @crumbs = []
      # `.outside_repo_metadata` ON THE SCOPE, NOT ON THE `.order` BELOW, so @match_count is taken
      # from the same query as the rows and the banner cannot claim a file the page never shows.
      # A `.git` row reaches THIS scope only as a file — a `gitdir:` pointer, since flat mode
      # filters kind: "file" — but the rule is the catalog's, not the folder view's, and one
      # condition must not have two answers across the two scopes (§14a).
      scope = flat_ext_scope(@exts).outside_repo_metadata
      @match_count = scope.count
      # ORDERED BY THE USER'S SORT, NOT BY NAME, BECAUSE HERE THE ORDER *SELECTS* -- see
      # flat_order. This line used to be `.order(:name)`, and the LIMIT then took the alphabetical
      # head of the library while the page displayed it under whatever heading the user had
      # clicked.
      @nodes = scope.order(flat_order(@exts, @sort, @dir)).limit(FLAT_LIMIT).to_a
      @truncated = @match_count > FLAT_LIMIT
    else
      @folder = current_folder
      @crumbs = folder_crumbs(@folder)
      # `.outside_repo_metadata` here for the same reason it is on the flat scope above, and on
      # the scope rather than the orders below so @child_count paginates what is actually shown.
      scope = current_user.nodes.present.where(parent_node_id: @folder&.node_id)
                          .outside_repo_metadata
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

    out = nodes.each_with_object({}) do |n, h|
      p = map.thumb(n.node_id)
      next unless p

      h[n.node_id] = { status: p.status, url: (p.status == "ready" && p.asset.attached? ? url_for(p.asset) : nil) }
    end
    render json: out
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
    # rebuild, because a thumbnail is a PICTURE of this same file and the detail page does not poll
    # — blanking it would strand a spinner there. Geometry is the opposite on both counts: it is
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
    token = @info&.content_token
    @thumbnail = token && current_thumbnail(@node, token)
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
    # The same lookup #index makes for a whole page, asked about one node. Keyed by node_id either
    # way so the view reads it identically; a file no addon produced is simply an absent key.
    @addon_origins = addon_origins_for([ @node.node_id ])
    @move_conflict = move_conflict_prompt
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
    # THE CONFLICT FACT (ProjectFolderIntake#left_unfiled_by_conflict?) IS NOT THREADED INTO THIS
    # JSON BRANCH, and that is a considered omission, not an oversight: uploadPortFile reads only
    # `data.node_id` from the response (see lib/chunk_upload.js), and its one caller
    # (importer_controller.js) always targets a MODEL's bundle folder, never a PROJECT's -- so
    # #intake_project_folder answers nil on this path today regardless, and the fact this comment
    # is about cannot arise for it. The HTML branch below is the one door here that a project-folder
    # upload actually reaches (see project_folder_intake_test.rb's ShareTest), and it is the one
    # that gets the restored notice.
    respond_to do |format|
      format.html do
        redirect_to file_path(info.node_id), notice: project_intake_notice(intake_result, upload.original_filename)
      end
      format.json { render json: { node_id: info.node_id }, status: :created }
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
    if result.info
      enqueue_preview(node_id: result.info.node_id, name: result.info.name)
      # THE SAME CONFLICT FACT AS THE OTHER TWO DOORS (ProjectFolderIntake#left_unfiled_by_conflict?)
      # IS DELIBERATELY NOT SURFACED IN THE JSON BELOW, checked rather than assumed. This endpoint's
      # only caller, lib/chunk_upload.js's uploadChunkFile, awaits this POST purely for its side
      # effect and never reads a single key from its response body -- not even version_id or seq,
      # which have been here all along (see that function: the result of
      # `await postJSON(finalizeUrl, ...)` is never assigned to anything). Adding a THIRD key next to
      # two nobody reads would be inventing a key nobody reads, not restoring feedback anyone would
      # see -- so #intake_project_folder still runs and still files what it can, but nothing here
      # asks #left_unfiled_by_conflict? about the result. If a JSON consumer of this endpoint ever
      # needs the fact, #left_unfiled_by_conflict?/#project_intake_notice already exist for it --
      # wire it in here rather than reinventing the check.
      intake_project_folder(result.info.node_id)
    end
    render json: { version_id: result.version_id, seq: result.seq }
  rescue FileLayer::ChunksMissing => e
    render json: { error: "chunks_missing", missing: e.hashes }, status: :unprocessable_entity
  end

  # --- Download / view bytes ---------------------------------------------------
  # GET /files/:id/blob — hand the browser the file's bytes, however THIS deployment holds them.
  #
  # THE SPLIT THIS METHOD EXISTS TO KEEP: the disposition policy below is the CONTROLLER's and
  # must not vary by backend — the same button gives the same answer on chunk, share and s3, or
  # the shared contracts are pinning adapters that the web layer then diverges anyway. HOW the
  # bytes travel does vary, and that is FileLayer#download's answer, not ours. The controller
  # owns the policy; the adapter owns the mechanism.
  def blob
    node = current_user.nodes.present.find_by!(node_id: params[:id])
    filename = node.name
    content_type = Marcel::MimeType.for(name: filename)
    # Serve user-uploaded bytes inline ONLY for a small allowlist of raster image types.
    # Everything else — notably SVG and HTML, which the browser would execute in the app
    # origin (stored XSS in the user's own session) — is forced to a download. `nosniff`
    # stops the browser second-guessing the declared type. `?download=1` always attaches.
    # PDF is inline-safe too, even though SAFE_INLINE_TYPES is raster-only: the browser hands
    # application/pdf to its built-in viewer (PDFium/pdf.js), which sandboxes any embedded PDF
    # JavaScript — a PDF is never executed as page script in the app origin the way SVG/HTML are.
    # nosniff (set on the send_file/Stream branches) stops the browser re-sniffing it as HTML.
    inline_ok = !params[:download] &&
                (SAFE_INLINE_TYPES.include?(content_type) || content_type == "application/pdf")
    disposition = inline_ok ? "inline" : "attachment"

    delivery = FileLayer.current.download(current_user, node_id: node.node_id,
                                          disposition:, content_type:)

    # No `else`: an unhandled variant raises NoMatchingPatternError, which is what a new
    # Delivery variant with no consumer here should do. A silent fallthrough would serve a
    # blank 200 with the right filename.
    case delivery
    in FileLayer::Delivery::Redirect(url:)
      # NO Content-Disposition / Content-Type / nosniff on this branch, and the asymmetry is
      # deliberate rather than an omission: they would be headers on a 302 that the browser
      # discards on its way to the store. The policy travels SIGNED INTO THE URL instead
      # (FileLayer::S3#download) — the same answer, applied by the only party that can apply it.
      redirect_to url, allow_other_host: true
    in FileLayer::Delivery::SendFile(path:)
      # `path` is CONSUMED, never built and never re-validated: it was resolved through
      # Share#absolute_path's escape guard, which is the single choke point #read uses too.
      # A File.join / Pathname / ".." check here would either bypass that guard or become a
      # second copy of it that drifts (§9a-3). See share_delivery_test.rb's poisoned-row tests.
      response.headers["X-Content-Type-Options"] = "nosniff"
      send_file path, disposition:, type: content_type, filename:
    in FileLayer::Delivery::Stream(enum:)
      response.headers["X-Content-Type-Options"] = "nosniff"
      response.headers["Content-Type"] = content_type
      response.headers["Content-Disposition"] =
        ActionDispatch::Http::ContentDisposition.format(disposition:, filename:)
      self.response_body = enum
    end
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
  # request would block Puma and could time out on a large library. perform_later hands it to
  # Solid Queue (which runs in Puma via SOLID_QUEUE_IN_PUMA -- the same worker the recurring sweep
  # already relies on), and the user refreshes in a moment. This is a COMMAND for one user, so it
  # calls #perform with `user_id:` directly -- ScanJob.scan_all! is the all-users schedule gate,
  # not the per-user door. The gate above (require_scannable!) is what keeps this off chunk mode,
  # where #perform would raise ArgumentError for want of an observer.
  #
  # The redirect returns the user to WHAT THEY WERE LOOKING AT, folder or type filter, because the
  # button carries files_query_base and landing at the unfiltered root after a rescan is a lost
  # place. `ext` goes back through resolve_exts rather than being echoed from params: the same
  # whitelist that guards #index guards this, so a hand-edited value cannot ride a redirect.
  def rescan
    Library::ScanJob.perform_later(user_id: current_user.id)
    where = { folder: params[:folder].presence, ext: resolve_exts.presence&.join(",") }.compact
    redirect_to files_path(where), notice: "Rescan started — refresh in a moment."
  end

  private

  # The ONE comparator behind both halves of the attach control (see #show). Case-insensitive so
  # the Ruby sort matches what a reader expects from Postgres' default collation, with the raw
  # name as the tie-break so "beta"/"Beta" still order deterministically.
  def name_key(project) = [ project.name.downcase, project.name ]

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
  def resolve_page(pages)
    params[:page].to_i.clamp(1, pages)
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
    { folder: @folder&.node_id, ext: @exts.presence&.join(",") }.compact
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
  # The "…" written into `cache` before recursing is a CYCLE GUARD, and it is here for the same
  # reason folder_crumbs carries its `visited` Set: a corrupt parent chain (a dir whose ancestry
  # loops back to it) must stop rather than recurse until the stack gives out. Re-entering an id
  # already in progress returns the marker instead of descending again.
  def folder_paths_for(nodes)
    dirs = current_user.nodes.present.where(kind: "dir").pluck(:node_id, :parent_node_id, :name)
    by_id = dirs.to_h { |id, parent, name| [ id, [ parent, name ] ] }
    cache = {}
    resolve = lambda do |id|
      return "" if id.nil? || !by_id.key?(id)
      return cache[id] if cache.key?(id)

      cache[id] = "…" # cycle marker: re-entering this id returns it instead of recursing
      parent, name = by_id[id]
      cache[id] = [ resolve.call(parent), name ].reject(&:blank?).join("/")
    end
    nodes.to_h { |n| [ n.node_id, resolve.call(n.parent_node_id) ] }
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

  # Extensions whose detail page offers the interactive Measure view (measure_controller.js).
  #
  # THE SET IS THE FORMATS A GEOMETRY PAYLOAD CAN BE BUILT FOR, and it is written out rather than
  # derived from `Registry` — a renderer being registered says only that it makes a THUMBNAIL, and
  # ten of them do exactly that. Asking `payload_revision` instead would be no better: every
  # renderer answers it (via `Enqueue.revision_for`'s fallback), so the question it answers is not
  # the one being asked. Pinned by a test that drives the real `render(..., kind: "geometry")` for
  # each entry, so the list cannot claim a format the renderers do not actually measure.
  MEASURABLE_EXTS = %w[lbrn lbrn2 mage dxf svg].freeze

  def preview_kind(name)
    ext = File.extname(name).downcase.delete(".")
    # BEFORE the :image branch, which .svg would otherwise take. An SVG is still shown as an image
    # at rest — the Measure branch uses it as its own poster (see _measure.html.erb) — so this
    # reorders which branch OWNS the page, not what the page displays when nothing is clicked.
    #
    # Measure SUPERSEDES the static preview the way :model3d does for meshes, and for the same
    # reason: it is a button, not a replacement. The resting picture stays whatever the format's
    # own render is (LightBurn's and MillMage's are in colour; ours are outlines).
    return :measure if MEASURABLE_EXTS.include?(ext)

    return :image if %w[png jpg jpeg gif webp bmp ico].include?(ext)
    # PDF before the :thumbnail branch: the detail view EMBEDS the whole PDF for the browser's own
    # viewer (a full, scrollable preview), while pdf is ALSO in Registry for a page-1 grid thumbnail.
    return :pdf   if ext == "pdf"
    # DERIVED FROM THE ONE VOCABULARY (§14d), not a second list beside it. This was an inline set
    # of 26 extensions sitting next to Maker::FileAttachment::ROLE_BY_EXT, and it had already
    # drifted: five of its entries (xml log ini cfg conf) were in no ROLE_BY_EXT entry at all, so
    # the two tables disagreed about what those files even were. Adding an extension is now a
    # one-line edit to ROLE_BY_EXT and nothing here has to hear about it.
    #
    # ORDER IS LOAD-BEARING and this line must stay below the three branches above: an .svg is a
    # text file too, and the measure/image/pdf branches own those pages on purpose.
    # OR'd with TEXT_EXTS, which is NOT a second list creeping back in — both constants live in
    # Maker::FileAttachment, beside ROLE_BY_EXT, and the second one exists because role and content
    # type are different questions: `.scad` is cad_source for FILING and source code for VIEWING.
    # That file carries the full argument and the two rejected alternatives.
    return :text  if Maker::FileAttachment::TEXT_ROLES.include?(Maker::FileAttachment.role_for(name)) ||
                     Maker::FileAttachment::TEXT_EXTS.include?(ext)
    # Mesh formats the browser can parse itself -> the interactive client-side 3D viewer
    # (modelviewer_controller.js), which supersedes the static thumbnail on the detail page. The
    # thumbnail is still generated (Registry has these) and serves as the viewer's fallback poster.
    return :model3d if %w[stl 3mf obj].include?(ext)
    # A file we can render a server-side thumbnail for (step, stp, iges, igs, ...) but
    # that the browser can't display raw. The :thumbnail branch in show.html.erb reads @thumbnail.
    return :thumbnail if Maker::Previews::Registry.for(ext)
    :other
  end
end
