# Server-rendered web UI for the file library: list, upload, download, view, delete.
#
# Architectural invariants (CLAUDE.md §2/§8/§15) — bytes NEVER flow through Rails:
#   - Upload: the BROWSER hashes the file (SHA-256, JS SubtleCrypto), asks us to begin a
#     commit (Sync::Commit.begin → presigned PUT URLs for the MISSING chunks only — dedup
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
# The web UI reuses the SAME Sync::Commit two-phase machinery and per-user presign paths
# as the desktop client, so a web upload produces a valid content-addressed manifest +
# immutable version with correct refcounts. No second, bytes-through-Rails write path.
class FilesController < ApplicationController
  before_action :authenticate_user!

  # ONE named mechanism for what this deployment can do, reachable from the views AND from the v1
  # API. Not two: a view reaching for FileLayer.current.capabilities inline while a controller
  # also sets @caps is how the two answers drift apart, which is §9a-3's complaint and Landmine
  # 1's whole shape. The `capabilities` helper this controller used to define privately now lives
  # in the concern -- the same argument that forbids two answers in a view forbids two ways to
  # reach them.
  include LibraryCapabilities

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
  # actions do not need "the port refuses writes", they need Sync::Commit -- which is what
  # `syncable` names, and which is the same gate V1::CommitsController uses for the same
  # machinery. A backend with neither flow (port_writable false, syncable false) would be told
  # "yes, use the two-phase flow" by the derived gate and 500 in Sync::Commit; the stated one
  # tells it the truth. `port_writable` still selects which form the UI renders -- that is its
  # one job, and it is a different question from this one.
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

  # GET /files — ONE folder's children (not the whole library), so the tree the backends all
  # build in `nodes.parent_node_id` is actually navigable instead of dumped flat. `params[:folder]`
  # is a parent node_id; absent/blank/invalid = the library root.
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
    @folder = current_folder
    @crumbs = folder_crumbs(@folder)
    @nodes = current_user.nodes.present.where(parent_node_id: @folder&.node_id)
                         .order(kind: :desc, name: :asc).to_a
    @info_by_node = FileLayer.current.stat_all(current_user, node_ids: @nodes.map(&:node_id))
    @nodes.select! { |node| @info_by_node.key?(node.node_id) }
    # Note counts for the badge — one grouped query, never N+1.
    @note_counts = current_user.maker_notes.where(node_id: @nodes.map(&:node_id)).group(:node_id).count
    @thumb_by_node = thumbnails_for(@nodes, @info_by_node)
    backfill_thumbnails(@nodes, @info_by_node, @thumb_by_node)
    # The current project's folder, for the upload button's default-into-project wiring (spec
    # 2026-07-23). `current_project_folder_node_id` (CurrentProject concern) is deliberately NOT a
    # helper_method — like ProjectsController#show's @upload_parent_node_id, a view must not create
    # a project folder as a side effect of merely being rendered; the owning action opts in
    # explicitly and hands the view an ivar. nil when no project is current (its own rescue already
    # covers an ensure failure, same as ProjectsController#show's).
    @current_project_folder_node_id = current_project_folder_node_id
  end

  # GET /files/thumbnails?ids=a,b,c (JSON) — the current-version thumbnail state for each node id,
  # for the grid's poll-until-ready. Session-authed (this is the web UI, not the device-token v1
  # API), user-scoped. Shape: { "<node_id>": { status:, url: } }. A node with no thumbnail row is
  # simply absent from the payload.
  def thumbnails
    ids = params[:ids].to_s.split(",").first(200) # bound the batch
    nodes = current_user.nodes.present.where(node_id: ids).to_a
    info = FileLayer.current.stat_all(current_user, node_ids: nodes.map(&:node_id))
    by_node = thumbnails_for(nodes, info)

    out = nodes.each_with_object({}) do |n, h|
      token = info[n.node_id]&.content_token
      p = token && by_node[[ n.node_id, token ]]
      next unless p

      h[n.node_id] = { status: p.status, url: (p.status == "ready" && p.asset.attached? ? url_for(p.asset) : nil) }
    end
    render json: out
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
    @thumbnail = token && current_user.maker_previews
                            .find_by(node_id: @node.node_id, version_id: token, kind: "thumbnail")
    # THE ATTACH CONTROL'S TWO HALVES. `@attached_projects` is what the file is already in — a
    # file can be in several projects, and until now the page gave no sign it was in any. The
    # dropdown then offers the REST: re-attaching to a project it is already in is a no-op, so
    # listing it would be an option that does nothing.
    attachments = current_user.maker_file_attachments
                              .where(node_id: @node.node_id, attachable_type: "Maker::Project")
                              .includes(:attachable).to_a
    @attached_projects = attachments.filter_map { |a|
      [ a.attachable, a ] if a.attachable && a.attachable.status != "archived"
    }.sort_by { |project, _| project.name }
    scope = current_user.maker_projects.where.not(status: "archived")
    # Guarded: `where.not(id: [])` is a no-op clause in Rails, but writing it unconditionally
    # invites the reader to assume it filters. Say what happens.
    attached_ids = attachments.map(&:attachable_id)
    scope = scope.where.not(id: attached_ids) if attached_ids.any?
    @projects = scope.order(:name).to_a
    @notes = current_user.maker_notes.where(node_id: @node.node_id).order(created_at: :desc).to_a
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
    # format.json for the importer (app/javascript/controllers/importer_controller.js via
    # lib/chunk_upload's uploadPortFile): it needs the new node_id to attach in the SAME request
    # that uploaded it. A followed redirect can't carry that back -- fetch() resolves to the
    # redirect TARGET's response, whose Location header is null, so parsing "the redirect" from
    # the client side was always dead code (caught in review, never landed working). Answering
    # JSON directly here is also what let this deployment's OWN 406 bug surface: #show has no
    # JSON responder, so a followed redirect carrying Accept: application/json 406'd on every
    # single port upload -- this format.json branch is what makes the request succeed WITHOUT
    # ever reaching #show.
    respond_to do |format|
      format.html { redirect_to file_path(info.node_id), notice: "Uploaded #{upload.original_filename}." }
      format.json { render json: { node_id: info.node_id }, status: :created }
    end
  end

  # --- Upload: phase 1 (begin) -------------------------------------------------
  # POST /files/begin_upload (JSON)
  #   { name, size, parent_node_id?, manifest: [{hash, offset, length}, ...] }
  # -> { commit_id, node_id, put_urls: { hash => url }, get_base }
  # Reuses Sync::Commit.begin: records the pending commit + presigns ONLY missing chunks.
  def begin_upload
    name = params.require(:name)
    manifest = (params[:manifest] || []).map { |c| c.permit(:hash, :offset, :length).to_h }
    commit_id = SecureRandom.uuid
    node_id   = SecureRandom.uuid

    result = Sync::Commit.begin(
      user: current_user, device: web_device,
      commit_id:, node_id:, parent_node_id: params[:parent_node_id],
      name:, base_version_id: nil, size: params.require(:size).to_i,
      mtime: (Time.current.to_f * 1e9).to_i, manifest:
    )

    render json: {
      commit_id: result.commit_id, node_id:,
      put_urls: result.put_urls, missing: result.missing
    }
  rescue Sync::Commit::InvalidManifest => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # --- Upload: phase 2 (finalize) ---------------------------------------------
  # POST /files/finalize_upload (JSON) { commit_id }
  # Reuses Sync::Commit.finalize (verify: true — confirm the bytes actually landed in
  # storage before creating the immutable version + changelog entry).
  def finalize_upload
    version, seq = Sync::Commit.finalize(
      user: current_user, commit_id: params.require(:commit_id), verify: true
    )
    LibraryChannel.broadcast_change(current_user, seq)
    node = current_user.nodes.find_by(node_id: version.node_id)
    enqueue_preview(node_id: version.node_id, name: node&.name || version.node_id) if node
    render json: { version_id: version.version_id, seq: }
  rescue Sync::Commit::ChunksMissing => e
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
  # THE SAME BRANCH THE UPLOAD MAKES, ON THE SAME CAPABILITY, AND FOR THE SAME REASON: a delete
  # is a write, so `port_writable` — "which door do bytes go in?" — already answers it. The read
  # contract pins that answer to what the adapters really do (Task 1's
  # test_contract_port_writable_agrees_with_what_delete_and_move_actually_do), so this is not an
  # inference: false here means Chunk#delete raises, true means the port implements it.
  #
  # THE TOMBSTONE IS ONLY HALF A DELETE, AND ON SHARE/S3 THE WRONG HALF ALONE UNDOES ITSELF. This
  # action used to call Sync::Mutation unconditionally. In chunk mode that IS the delete — the
  # bytes are the sync engine's and the tombstone is the whole truth. On share/s3 the bytes are a
  # file on the user's NAS or an object in their bucket, and a tombstone does not move them: the
  # file stays exactly where it was, THE NEXT SCAN OBSERVES IT, and Reconciler#create_or_revive!
  # revives the tombstone by storage_path. The user deletes a file, watches it disappear, and it
  # comes back within the scan interval. Verified before this fix.
  #
  # FileLayer#delete is the whole delete: it moves the bytes to `.trash/<node_id>/<name>` FIRST
  # and tombstones after (2b's order — reversed, a failed move leaves a tombstone the scan
  # resurrects), and NULLs storage_path, which is what makes that revive unable to fire and what
  # makes `undelete` the only way back. See TrashController, which is the other end of it.
  #
  # THE CHUNK BRANCH IS Sync::SubtreeDelete, NOT Sync::Mutation.apply(op: "delete"), AND THE
  # DIFFERENCE IS A DIRECTORY'S CHILDREN. Mutation tombstones only the node it is handed, so on a
  # directory it orphans the descendants: /v1/tree serves children pointing at a deleted parent
  # (reproduced), while a changelog-following device drops the whole subtree client-side -- the two
  # views diverge. The Delete button IS rendered for directories, so this is the ordinary path, not
  # an edge. SubtreeDelete cascades under one lock and, on a childless file, collects exactly one
  # node and does the identical single tombstone. V1::NodesController#destroy has always used it;
  # this action had the copy that did not, which is exactly what Chunk::DELETE_MSG names as the
  # right door -- three lines above a branch that used the wrong one.
  #
  # No broadcast on the port branch: there is no changelog to advance and no devices to nudge
  # (syncable: false). Both sync-engine doors return a seq -- SubtreeDelete returns the LAST one
  # it minted, which is the one that leaves head_seq where the nudge must point.
  def destroy
    node = current_user.nodes.find_by!(node_id: params[:id])
    if capabilities.port_writable?
      FileLayer.current.delete(current_user, node_id: node.node_id)
    else
      seq = Sync::SubtreeDelete.call(user: current_user, node:)
      LibraryChannel.broadcast_change(current_user, seq)
    end
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
  def rescan
    Library::ScanJob.perform_later(user_id: current_user.id)
    redirect_to files_path(folder: params[:folder].presence),
                notice: "Rescan started — refresh in a moment."
  end

  private

  # Current-version thumbnail per node, in ONE query (never N+1). Keyed by [node_id, content_token]
  # where content_token is what @info_by_node already carries, so we show the thumbnail for the
  # version on screen, not a stale one. `nodes` is an Array, `info` a Hash (FileInfo per node_id).
  def thumbnails_for(nodes, info)
    tokens = nodes.filter_map { |n| info[n.node_id]&.content_token }
    return {} if tokens.empty?

    current_user.maker_previews
                .where(kind: "thumbnail", node_id: nodes.map(&:node_id), version_id: tokens)
                .index_by { |p| [ p.node_id, p.version_id ] }
  end

  # LAZY BACKFILL. The eager seams (upload/commit/scan) only cover files that arrive AFTER the
  # feature shipped; a library indexed before it has files but no preview rows. Without this, every
  # such file shows a spinner the grid polls forever (a job is never coming). So when a folder is
  # viewed, enqueue a thumbnail for each renderable file that has no row for its current version.
  # Idempotent (Enqueue no-ops on an existing non-failed row) and renderable-only (non-renderable
  # names get no row and render as a static icon, never a spinner). `existing` is @thumb_by_node,
  # already loaded — the new pending rows aren't in it, so the view shows nil -> spinner, which is
  # now truthful because a job IS coming.
  def backfill_thumbnails(nodes, info, existing)
    nodes.each do |node|
      next unless node.file?

      token = info[node.node_id]&.content_token
      next if token.nil? || existing.key?([ node.node_id, token ])
      next if Maker::Previews::Registry.for_filename(node.name).nil?

      ::Maker::Previews::Enqueue.call(user: current_user, node_id: node.node_id,
                                      name: node.name, version_id: token)
    end
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

  def preview_kind(name)
    ext = File.extname(name).downcase.delete(".")
    return :image if %w[png jpg jpeg gif webp svg bmp ico].include?(ext)
    # PDF before the :thumbnail branch: the detail view EMBEDS the whole PDF for the browser's own
    # viewer (a full, scrollable preview), while pdf is ALSO in Registry for a page-1 grid thumbnail.
    return :pdf   if ext == "pdf"
    return :text  if %w[txt md markdown csv json xml yml yaml log rb js ts py rs go
                        c h cpp html css toml ini cfg conf sh gcode].include?(ext)
    # Mesh formats the browser can parse itself -> the interactive client-side 3D viewer
    # (modelviewer_controller.js), which supersedes the static thumbnail on the detail page. The
    # thumbnail is still generated (Registry has these) and serves as the viewer's fallback poster.
    return :model3d if %w[stl 3mf obj].include?(ext)
    # A file we can render a server-side thumbnail for (dxf, lbrn2, step, stp, iges, igs, ...) but
    # that the browser can't display raw. The :thumbnail branch in show.html.erb reads @thumbnail.
    return :thumbnail if Maker::Previews::Registry.for(ext)
    :other
  end
end
