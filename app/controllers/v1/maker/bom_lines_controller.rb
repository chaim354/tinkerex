module V1
  module Maker
    class BomLinesController < V1::BaseController
      # A stock line's `unit` is read from its item (Maker::BomLine#unit), so the items load with the
      # lines rather than one query per stock line.
      def index
        bom = current_user.maker_boms.find(params[:bom_id])
        render json: { bom_lines: bom.lines.includes(:inventory_item).map { |l| line_json(l) } }
      end

      def create
        bom = current_user.maker_boms.find(params[:bom_id])
        line = bom.lines.new(line_params.merge(user: current_user))
        line.save!
        render json: line_json(line), status: :created
      end

      def update
        line = current_user.maker_bom_lines.find(params[:id])
        line.update!(line_params)
        render json: line_json(line)
      end

      def destroy
        current_user.maker_bom_lines.find(params[:id]).destroy!
        head :no_content
      end

      private

      def line_params
        params.require(:bom_line).permit(
          :reference, :quantity, :unit, :inventory_item_id, :node_id,
          :part_name, :supplier_id, :notes, :position
        )
      end

      def line_json(line)
        { id: line.id, bom_id: line.bom_id, reference: line.reference,
          quantity: line.quantity, unit: line.unit, notes: line.notes, position: line.position,
          inventory_item_id: line.inventory_item_id, node_id: line.node_id,
          part_name: line.part_name, supplier_id: line.supplier_id,
          target_kind: line.target_kind, created_at: line.created_at, updated_at: line.updated_at }
      end
    end
  end
end
