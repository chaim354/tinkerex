module V1
  class BaseController < ActionController::API
    include Authentication

    rescue_from ActiveRecord::RecordNotFound, with: :not_found
    rescue_from ActionController::ParameterMissing, with: :bad_request
    rescue_from ActiveRecord::RecordInvalid, with: :unprocessable

    # For the local (filesystem) chunk store: when no CHUNK_PUBLIC_URL is set, presigned blob URLs
    # point back at the host the client is actually talking to (zero-config single-box). Harmless
    # no-op for the S3/memory backends.
    before_action :stash_request_base_url

    private

    def stash_request_base_url
      if Storage::ChunkStore.current.is_a?(Storage::LocalChunkStore)
        Storage::LocalChunkStore::PUBLIC_URL_OVERRIDE.value = request.base_url
      end
    end

    def not_found(_e) = render(json: { error: "not_found" }, status: :not_found)
    def bad_request(e) = render(json: { error: e.message }, status: :bad_request)
    def unprocessable(e) = render(json: { error: e.message }, status: :unprocessable_entity)
  end
end
