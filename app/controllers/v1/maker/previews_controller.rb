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

      # Enqueue (or return the existing) preview for a node/version/kind. Idempotent:
      # re-POSTing the same (node, version, kind) returns the existing record.
      def create
        attrs = preview_params
        preview = current_user.maker_previews
                    .find_or_initialize_by(node_id: attrs[:node_id],
                                           version_id: attrs[:version_id],
                                           kind: attrs.fetch(:kind, "thumbnail"))
        new_record = preview.new_record?
        # Reset to pending on first create or to re-attempt a previously failed render.
        preview.status = "pending" if new_record || preview.status == "failed"
        preview.save!

        if new_record || preview.status == "pending"
          ::Maker::GeneratePreviewJob.perform_later(preview.id, filename: attrs[:filename])
        end

        render json: preview_json(preview), status: (new_record ? :created : :ok)
      end

      private

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
