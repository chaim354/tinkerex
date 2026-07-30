module V1
  module Maker
    # Thin CRUD + enqueue, scoped through current_user. The asset BYTES are served via the
    # ActiveStorage blob URL returned in the JSON (off Rails) — consistent with CLAUDE.md
    # §8/§15 ("keep bytes out of Rails").
    class PreviewsController < V1::BaseController
      def index
        previews = current_user.maker_previews
                     .for_node(params[:node_id])
                     .for_version(params[:version_id])
                     .of_kind(params[:kind])
                     .order(updated_at: :desc)
        render json: { previews: previews.map { |p| preview_json(p) } }
      end

      # Enqueue (or return the existing) preview for a node/kind. Idempotent: re-POSTing returns
      # the existing record.
      #
      # IDEMPOTENT PER (node, KIND) NOW, not per (node, version, kind) — there is one row per
      # (node, kind) and it is repointed as the content moves
      # (20260730001500_one_preview_per_node_and_kind.rb). `version_id` is therefore no longer a
      # thing a client CHOOSES; it records which content the stored asset was rendered from.
      def create
        attrs = preview_params
        return if refuse_stale_version!(attrs)

        preview = current_user.maker_previews
                    .find_or_initialize_by(node_id: attrs[:node_id],
                                           kind: attrs.fetch(:kind, "thumbnail"))
        new_record = preview.new_record?
        stale = preview.version_id != attrs[:version_id]
        # Reset to pending on first create, when the content moved, or to re-attempt a failure.
        if new_record || stale || preview.status == "failed"
          preview.version_id = attrs[:version_id]
          preview.status = "pending"
        end
        preview.save!

        # Reads the in-memory status after save (set above) to decide whether to enqueue.
        if new_record || preview.status == "pending"
          ::Maker::GeneratePreviewJob.perform_later(preview.id, filename: attrs[:filename])
        end

        render json: preview_json(preview), status: (new_record ? :created : :ok)
      end

      private

      # 422 rather than silently repointing the live row at content the library has moved past.
      #
      # With one row per (node, kind), honouring a request for an OLD version would throw away the
      # current render and replace it with a historical one — and on share/s3, where the library is
      # current-state only, the bytes it names do not exist at all, so the render would then fail
      # and leave the node with no preview. Refusing is the honest answer, and it names the version
      # the client should have asked for.
      #
      # ONLY WHEN WE CAN ACTUALLY TELL. The port is the only thing that knows the current token, so
      # a node the backend cannot resolve — never synced, already deleted, an unmounted share —
      # gives no basis to refuse anything, and the request falls through to the normal repoint. A
      # gate that guessed here would reject legitimate first-time renders for a node the API client
      # is about to create.
      def refuse_stale_version!(attrs)
        return false if attrs[:version_id].blank?

        current = FileLayer.current.stat(current_user, node_id: attrs[:node_id])&.content_token
        return false if current.blank? || current == attrs[:version_id]

        render json: { error: "stale_version", current_version_id: current },
               status: :unprocessable_entity
        true
      rescue FileLayer::NotFound, FileLayer::FetchError
        false
      end

      def preview_params
        params.require(:preview).permit(:node_id, :version_id, :kind, :filename)
      end

      def preview_json(p)
        {
          id: p.id, node_id: p.node_id, version_id: p.version_id, kind: p.kind,
          status: p.status, error: p.error, width: p.width, height: p.height,
          url: (p.asset.attached? ? url_for(p.asset) : nil),
          created_at: p.created_at, updated_at: p.updated_at
        }
      end
    end
  end
end
