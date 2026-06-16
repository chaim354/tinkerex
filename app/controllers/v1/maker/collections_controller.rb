module V1
  module Maker
    class CollectionsController < V1::BaseController
      def index
        render json: { collections: current_user.maker_collections.order(:name).map { |c| collection_json(c) } }
      end

      def create
        c = current_user.maker_collections.create!(params.require(:collection).permit(:name, :description))
        render json: collection_json(c), status: :created
      end

      def update
        c = current_user.maker_collections.find(params[:id])
        c.update!(params.require(:collection).permit(:name, :description))
        render json: collection_json(c)
      end

      def destroy
        current_user.maker_collections.find(params[:id]).destroy!
        head :no_content
      end

      # GET /v1/maker/collections/:id/items
      def items
        c = current_user.maker_collections.find(params[:id])
        render json: { items: c.items.map { |i| { id: i.id, title: i.title, item_type: i.item_type } } }
      end

      # POST /v1/maker/collections/:id/items { item_id }
      def add_item
        c = current_user.maker_collections.find(params[:id])
        item = current_user.maker_items.find(params.require(:item_id))
        c.collection_items.find_or_create_by!(user: current_user, item: item)
        head :created
      end

      # DELETE /v1/maker/collections/:id/items/:item_id
      def remove_item
        c = current_user.maker_collections.find(params[:id])
        c.collection_items.where(item_id: params[:item_id]).destroy_all
        head :no_content
      end

      private

      def collection_json(c)
        { id: c.id, name: c.name, description: c.description,
          item_count: c.collection_items.count, updated_at: c.updated_at }
      end
    end
  end
end
