module V1
  class BaseController < ActionController::API
    include Authentication
    # Brings `require_capability!` to the subclasses that need it. Included HERE rather than
    # per-controller so the 501 has one shape across the API; WHICH controllers gate is decided
    # per controller, by what each one actually does in share mode. Auth is included first and so
    # runs first: an unauthenticated request to a gated endpoint gets 401, not a 501 that would
    # disclose the deployment's backend to a stranger.
    include LibraryCapabilities

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

    # GATED ON `syncable`, AND WITHOUT THE GATE A SHARE/S3 DEPLOYMENT'S ENTIRE v1 API IS A 500.
    # `is_a?` cannot be asked without BUILDING the store, and STORAGE_BACKEND defaults to `s3`
    # outside test -> S3ChunkStore.from_env -> ENV.fetch("CHUNK_BUCKET") -> KeyError. A share
    # operator sets LIBRARY_*, not CHUNK_*, so EVERY v1 request raised here, before routing to
    # anything: login, /v1/maker/*, and every gated endpoint -- which answered 500 instead of the
    # 501 this phase exists to give them.
    #
    # The gate is the honest guard rather than a workaround, and the reason is that this is a
    # CHUNK-DATA-PLANE affordance: it exists so LocalChunkStore can presign at the host the
    # client is talking to. `syncable` is the capability that names a deployment having a chunk
    # data plane at all (see LibraryCapabilities::CAPABILITY_ABSENT: "no changelog, no chunks, no
    # devices"), so asking a chunk store to materialize where there is none is the bug, not the
    # KeyError. Note what it does NOT hide: in chunk mode `syncable` is true, the store is built,
    # and a genuinely missing CHUNK_BUCKET still raises on the first request, exactly as loudly.
    #
    # NOT `rescue KeyError` and NOT a lazier ChunkStore: the first swallows a real chunk-mode
    # misconfiguration, and the second makes every caller pay for a store this deployment will
    # never have.
    def stash_request_base_url
      return unless FileLayer.current.capabilities.syncable?
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
