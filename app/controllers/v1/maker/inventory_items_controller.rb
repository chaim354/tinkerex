module V1
  module Maker
    class InventoryItemsController < V1::BaseController
      def index
        items = current_user.maker_inventory_items.order(:name)
        items = items.where(category: params[:category]) if params[:category].present?
        items = items.where(location_id: params[:location_id]) if params[:location_id].present?
        render json: { inventory_items: items.map { |i| item_json(i) } }
      end

      def show
        render json: item_json(current_user.maker_inventory_items.find(params[:id]), full: true)
      end

      def create
        item = current_user.maker_inventory_items.new(item_params)
        item.save!
        render json: item_json(item, full: true), status: :created
      end

      def update
        item = current_user.maker_inventory_items.find(params[:id])
        item.update!(item_params)
        render json: item_json(item, full: true)
      end

      def destroy
        current_user.maker_inventory_items.find(params[:id]).destroy!
        head :no_content
      end

      # POST /v1/maker/inventory_items/:id/adjust { delta, reason, project_id?, note? }
      def adjust
        item = current_user.maker_inventory_items.find(params[:id])
        ::Maker::InventoryTransaction.apply!(
          item: item, user: current_user,
          delta: params.require(:delta), reason: params.fetch(:reason, "adjusted"),
          project_id: params[:project_id], note: params[:note]
        )
        render json: item_json(item.reload, full: true), status: :created
      end

      # GET /v1/maker/inventory_items/:id/transactions
      def transactions
        item = current_user.maker_inventory_items.find(params[:id])
        ledger = item.transactions.reorder(created_at: :desc, id: :desc)
        render json: { transactions: ledger.map { |t| txn_json(t) } }
      end

      # GET /v1/maker/inventory_items/low_stock
      def low_stock
        items = current_user.maker_inventory_items.low_stock.order(:name)
        render json: { inventory_items: items.map { |i| item_json(i) } }
      end

      private

      def item_params
        params.require(:inventory_item).permit(
          :name, :part_number, :category, :unit, :min_quantity, :unit_cost,
          :location_id, :supplier_id, :notes
        )
      end

      def item_json(item, full: false)
        base = {
          id: item.id, name: item.name, part_number: item.part_number, category: item.category,
          unit: item.unit, quantity_cached: item.quantity_cached, min_quantity: item.min_quantity,
          location_id: item.location_id, supplier_id: item.supplier_id,
          updated_at: item.updated_at
        }
        return base unless full
        base.merge(unit_cost: item.unit_cost, notes: item.notes, created_at: item.created_at)
      end

      def txn_json(t)
        { id: t.id, delta: t.delta, reason: t.reason, project_id: t.project_id,
          note: t.note, created_at: t.created_at }
      end
    end
  end
end
