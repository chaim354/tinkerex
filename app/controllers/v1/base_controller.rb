module V1
  class BaseController < ActionController::API
    include Authentication

    rescue_from ActiveRecord::RecordNotFound, with: :not_found
    rescue_from ActionController::ParameterMissing, with: :bad_request
    rescue_from ActiveRecord::RecordInvalid, with: :unprocessable
    rescue_from Sync::Commit::InvalidManifest, with: :unprocessable
    # A rejected-but-well-formed request (a malformed manifest hash, a move that would create
    # a cycle, a version that isn't part of the named conflict — all raise ArgumentError) is a
    # client error (422), not a server error (500). Keep the raisers narrow so this never masks
    # a genuine bug.
    rescue_from ArgumentError, with: :unprocessable
    # Changing an existing node's kind, or two devices racing to insert the same node_id, is a
    # conflict (409) — a clean, retriable result — not a 500.
    rescue_from Sync::Commit::KindConflict, with: :conflict
    rescue_from ActiveRecord::RecordNotUnique, with: :conflict

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
    def conflict(e) = render(json: { error: e.message }, status: :conflict)
  end
end
