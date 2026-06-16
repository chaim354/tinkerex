module V1
  module Maker
    class TaggingsController < V1::BaseController
      # POST /v1/maker/items/:item_id/taggings { name: "printed" }
      def create
        item = current_user.maker_items.find(params[:item_id])
        tag  = current_user.maker_tags.find_or_create_by!(name: params.require(:name))
        item.taggings.find_or_create_by!(user: current_user, tag: tag)
        render json: { tag: tag.name }, status: :created
      end

      # DELETE /v1/maker/taggings/:id  (id = tagging id)
      def destroy
        current_user.maker_taggings.find(params[:id]).destroy!
        head :no_content
      end
    end
  end
end
