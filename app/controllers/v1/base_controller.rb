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
    # A rejected-but-well-formed request (a malformed manifest hash, a move that would create
    # a cycle, a version that isn't part of the named conflict — all raise ArgumentError) is a
    # client error (422), not a server error (500). Keep the raisers narrow so this never masks
    # a genuine bug.
    rescue_from ArgumentError, with: :unprocessable
    rescue_from ActiveRecord::RecordNotUnique, with: :conflict

    # STAGE 3a TASK 5 (boundary design §3). This class used to also carry
    # `rescue_from Sync::Commit::InvalidManifest`, `rescue_from Sync::Commit::KindConflict`, and a
    # `before_action :stash_request_base_url` that referenced Storage::ChunkStore /
    # Storage::LocalChunkStore -- three Sync::/Storage:: references on the ONE class all fourteen
    # v1/maker/* controllers inherit from. `rescue_from` resolves its argument to the actual
    # exception CLASS OBJECT at the moment this class body runs, not when the exception would be
    # raised, so simply parsing this file forced the whole sync engine to autoload -- the maker
    # API's own base class named the engine before a single request had been routed. That is the
    # exact mirror of the boundary design's concern about the engine needing the host's User/Node.
    #
    # Both rescues are reachable ONLY from Sync::Commit.begin/.finalize (confirmed by grepping
    # every v1 controller for `Sync::Commit.` before moving anything), and the only caller of
    # either method is V1::CommitsController -- so they now live directly on that controller,
    # which is where they belong: it is the one file that can raise them. Stage 2 set the
    # precedent for moving a rescue to where its raiser actually is: FileLayer::Chunk re-raises
    # Sync::Commit::InvalidManifest/ChunksMissing through FileLayer's own vocabulary so ITS
    # caller (FilesController) never has to name a sync class either. This is the same move one
    # layer up, for the two errors this file was still naming directly.
    #
    # stash_request_base_url moved into V1::StashRequestBaseUrl (app/controllers/concerns/v1/),
    # included only by V1::CommitsController and V1::ChunksController -- the only two controllers
    # that ever presign a chunk URL. See that file for the full argument, including why the
    # `syncable` gate inside it survives the move unconditionally.
    #
    # NO OBSERVABLE BEHAVIOUR CHANGES FOR ANY OF THE OTHER TWENTY-SEVEN v1 CONTROLLERS. This
    # before_action was already an internal no-op for every maker request on a share/s3
    # deployment (`return unless capabilities.syncable?`), and on a chunk deployment no maker
    # endpoint ever reads the thread-local it set (grepped: zero Storage::/presign references
    # anywhere under app/controllers/v1/maker/). Removing it from the inherited chain removes a
    # dead write, not a behaviour.

    private

    def not_found(_e) = render(json: { error: "not_found" }, status: :not_found)
    def bad_request(e) = render(json: { error: e.message }, status: :bad_request)
    def unprocessable(e) = render(json: { error: e.message }, status: :unprocessable_entity)
    def conflict(e) = render(json: { error: e.message }, status: :conflict)
  end
end
