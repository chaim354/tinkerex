# Server-rendered web UI for the file library: list, upload, download, view, delete.
#
# Architectural invariants (CLAUDE.md §2/§8/§15) — bytes NEVER flow through Rails:
#   - Upload: the BROWSER hashes the file (SHA-256, JS SubtleCrypto), asks us to begin a
#     commit (Sync::Commit.begin → presigned PUT URLs for the MISSING chunks only — dedup
#     for free), PUTs the bytes straight to storage, then asks us to finalize the version.
#   - Download/view: we presign a GET per chunk (Sync::Commit / Storage::ChunkStore) and
#     the browser fetches bytes from storage directly; Rails only mints URLs + metadata.
#
# The web UI reuses the SAME Sync::Commit two-phase machinery and per-user presign paths
# as the desktop client, so a web upload produces a valid content-addressed manifest +
# immutable version with correct refcounts. No second, bytes-through-Rails write path.
class FilesController < ApplicationController
  include WebAuthentication

  before_action :require_login!

  # A node id that doesn't belong to current_user (or doesn't exist) -> 404, never a 500
  # and never another user's data (all lookups are scoped to current_user).
  rescue_from ActiveRecord::RecordNotFound do
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
  # GET /files/:id/blob — assemble the file by presigned-GET-ing each chunk and streaming.
  #
  # Architecture: the bytes do NOT pass through the Rails control plane. For the S3
  # backend we 302-redirect single-chunk files straight to the presigned storage URL.
  # For multi-chunk files (or the dev memory store) we stitch chunk bytes fetched from
  # the presigned URLs — still per-user, ownership-gated, content-addressed storage.
  def blob
    node = current_user.nodes.present.find_by!(node_id: params[:id])
    version = node.current_version
    raise ActiveRecord::RecordNotFound unless version

    chunks = version.manifest_chunks.to_a
    store = Storage::ChunkStore.current
    disposition = params[:download] ? "attachment" : "inline"
    filename = node.name

    # Single-chunk file on real object storage: redirect the browser straight to storage.
    if chunks.size == 1 && store.is_a?(Storage::S3ChunkStore)
      redirect_to store.presign_get(current_user.id, chunks.first.chunk_hash),
                  allow_other_host: true
      return
    end

    response.headers["Content-Type"] = Marcel::MimeType.for(name: filename)
    response.headers["Content-Disposition"] =
      ActionDispatch::Http::ContentDisposition.format(disposition:, filename:)

    self.response_body = Enumerator.new do |y|
      chunks.each do |c|
        y << fetch_chunk_bytes(store, current_user.id, c.chunk_hash)
      end
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

  # Pull a chunk's bytes from its presigned URL. For the dev memory store the URL is a
  # local /dev/blobs path served from disk; for S3 it is the object-storage URL. Either
  # way the v1 control plane never touches the bytes.
  def fetch_chunk_bytes(store, user_id, hash)
    if store.is_a?(Storage::MemoryChunkStore)
      store.read_blob(user_id, hash) || ""
    else
      url = store.presign_get(user_id, hash)
      require "net/http"
      Net::HTTP.get(URI(url))
    end
  end

  def preview_kind(name)
    ext = File.extname(name).downcase.delete(".")
    return :image if %w[png jpg jpeg gif webp svg bmp ico].include?(ext)
    return :text  if %w[txt md markdown csv json xml yml yaml log rb js ts py rs go
                        c h cpp html css toml ini cfg conf sh gcode].include?(ext)
    :other
  end
end
