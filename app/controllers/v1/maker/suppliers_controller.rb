module V1
  module Maker
    class SuppliersController < V1::BaseController
      def index
        render json: { suppliers: current_user.maker_suppliers.order(:name).map { |s| supplier_json(s) } }
      end

      def show
        render json: supplier_json(current_user.maker_suppliers.find(params[:id]))
      end

      def create
        sup = current_user.maker_suppliers.create!(supplier_params)
        render json: supplier_json(sup), status: :created
      end

      def update
        sup = current_user.maker_suppliers.find(params[:id])
        sup.update!(supplier_params)
        render json: supplier_json(sup)
      end

      def destroy
        current_user.maker_suppliers.find(params[:id]).destroy!
        head :no_content
      end

      private

      def supplier_params
        params.require(:supplier).permit(:name, :url, :notes)
      end

      def supplier_json(sup)
        { id: sup.id, name: sup.name, url: sup.url, notes: sup.notes,
          created_at: sup.created_at, updated_at: sup.updated_at }
      end
    end
  end
end
