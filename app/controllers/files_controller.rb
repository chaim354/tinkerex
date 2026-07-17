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

  # GET /files — flat list of the user's (non-deleted) files + dirs.
  def index
    @nodes = current_user.nodes.present.order(kind: :desc, name: :asc).to_a
    @versions_by_node = current_user.versions
      .where(node_id: @nodes.map(&:node_id))
      .index_by(&:version_id)
  end

  # GET /files/:node_id — view/preview a single file + metadata.
  def show
    @node = current_user.nodes.present.find_by!(node_id: params[:id])
    @version = @node.current_version
    @kind = preview_kind(@node.name)
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

  # DELETE /files/:id — soft-delete (tombstone); versions + chunks are kept (GC sweeps).
  def destroy
    node = current_user.nodes.find_by!(node_id: params[:id])
    seq = Sync::Mutation.apply(user: current_user, node:, op: "delete") { |n| n.deleted = true }
    LibraryChannel.broadcast_change(current_user, seq)
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
