module V1
  module Maker
    class LocationsController < V1::BaseController
      def index
        render json: { locations: current_user.maker_locations.order(:name).map { |l| location_json(l) } }
      end

      def show
        render json: location_json(current_user.maker_locations.find(params[:id]))
      end

      def create
        loc = current_user.maker_locations.new(location_params)
        loc.save!
        render json: location_json(loc), status: :created
      end

      def update
        loc = current_user.maker_locations.find(params[:id])
        loc.update!(location_params)
        render json: location_json(loc)
      end

      def destroy
        current_user.maker_locations.find(params[:id]).destroy!
        head :no_content
      end

      private

      def location_params
        params.require(:location).permit(:name, :description, :parent_id)
      end

      def location_json(loc)
        { id: loc.id, name: loc.name, description: loc.description, parent_id: loc.parent_id,
          created_at: loc.created_at, updated_at: loc.updated_at }
      end
    end
  end
end
