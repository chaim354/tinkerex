# DEV/TEST ONLY blob endpoint backing the MemoryChunkStore's presigned URLs.
#
# In PRODUCTION (STORAGE_BACKEND=s3) presigned URLs point straight at object storage and
# this controller/route is NOT mounted — chunk bytes flow browser <-> storage directly.
# Locally there is no off-box storage to presign to, so the memory store presigns to
# these routes so the browser's PUT-then-GET upload/download flow actually round-trips
# bytes. This stands in for object storage; it is not the Rails v1 control plane.
class DevBlobsController < ActionController::Base
  skip_forgery_protection # presigned-style PUT from fetch(); not a form post

  before_action :ensure_memory_store

  # PUT /dev/blobs/*key  — store the raw chunk bytes (the "presigned PUT").
  # The browser uploader sends raw bytes (no form content-type), so request.body is the
  # chunk. raw_post is used as a fallback in case middleware already read the stream.
  def update
    bytes = request.body.read
    bytes = request.raw_post if bytes.nil? || bytes.empty?
    @store.write_blob_key(params[:key], bytes.to_s)
    head :ok
  end

  # GET /dev/blobs/*key  — return the raw chunk bytes (the "presigned GET").
  def show
    data = @store.read_blob_key(params[:key])
    return head(:not_found) if data.nil?
    send_data data, type: "application/octet-stream", disposition: "inline"
  end

  private

  def ensure_memory_store
    @store = Sync::Storage::ChunkStore.current
    head :not_found unless @store.is_a?(Sync::Storage::MemoryChunkStore)
  end
end
