module V1
  module Maker
    class ItemsController < V1::BaseController
      def index
        items = current_user.maker_items.order(updated_at: :desc)
        render json: { items: items.map { |i| item_json(i) } }
      end

      def show
        item = current_user.maker_items.find(params[:id])
        render json: item_json(item, full: true)
      end

      def create
        item = current_user.maker_items.new(item_params)
        item.save!
        render json: item_json(item, full: true), status: :created
      end

      def update
        item = current_user.maker_items.find(params[:id])
        item.update!(item_params)
        render json: item_json(item, full: true)
      end

      def destroy
        current_user.maker_items.find(params[:id]).destroy!
        head :no_content
      end

      private

      def item_params
        params.require(:item).permit(
          :title, :summary, :description, :instructions, :item_type, :origin,
          :source_url, :source_name, :primary_node_id, :favorited
        )
      end

      def item_json(item, full: false)
        base = {
          id: item.id, title: item.title, summary: item.summary,
          item_type: item.item_type, origin: item.origin, source_url: item.source_url,
          source_name: item.source_name, primary_node_id: item.primary_node_id,
          favorited: item.favorited, created_at: item.created_at, updated_at: item.updated_at
        }
        return base unless full
        base.merge(
          description: item.description,
          instructions: item.instructions,
          file_attachments: item.file_attachments.map { |a| attachment_json(a) },
          tags: item.tags.map(&:name)
        )
      end

      def attachment_json(att)
        { id: att.id, node_id: att.node_id, version_id: att.version_id,
          role: att.role, label: att.label, position: att.position }
      end
    end
  end
end
