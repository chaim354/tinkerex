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

  # GET /files — flat list of the user's (non-deleted) files + dirs.
  #
  # Size/content come from the PORT, not from Version — see #show, where the argument is made.
  # This action had the same bug in a second spelling: @versions_by_node came from
  # current_user.versions, which is empty on share and s3, so every Size cell was an em-dash.
  def index
    @nodes = current_user.nodes.present.order(kind: :desc, name: :asc).to_a
    @info_by_node = @nodes.index_by(&:node_id).transform_values do |node|
      FileLayer.current.stat(current_user, node_id: node.node_id)
    end
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
    redirect_to file_path(info.node_id), notice: "Uploaded #{upload.original_filename}."
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
    inline_ok = !params[:download] && SAFE_INLINE_TYPES.include?(content_type)
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

  private

  def preview_kind(name)
    ext = File.extname(name).downcase.delete(".")
    return :image if %w[png jpg jpeg gif webp svg bmp ico].include?(ext)
    return :text  if %w[txt md markdown csv json xml yml yaml log rb js ts py rs go
                        c h cpp html css toml ini cfg conf sh gcode].include?(ext)
    :other
  end
end
