module V1
  module Maker
    class TagsController < V1::BaseController
      def index
        tags = current_user.maker_tags.order(:name)
        render json: { tags: tags.map { |t| { id: t.id, name: t.name, color: t.color } } }
      end

      def create
        tag = current_user.maker_tags.create!(params.require(:tag).permit(:name, :color))
        render json: { id: tag.id, name: tag.name, color: tag.color }, status: :created
      end

      def destroy
        current_user.maker_tags.find(params[:id]).destroy!
        head :no_content
      end
    end
  end
end
