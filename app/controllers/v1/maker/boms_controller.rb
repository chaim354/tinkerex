module V1
  module Maker
    class BomsController < V1::BaseController
      def index
        project = current_user.maker_projects.find(params[:project_id])
        render json: { boms: project.boms.order(:revision).map { |b| bom_json(b) } }
      end

      def create
        project = current_user.maker_projects.find(params[:project_id])
        bom = project.boms.new(bom_params.merge(user: current_user))
        bom.save!
        render json: bom_json(bom), status: :created
      end

      def show
        render json: bom_json(current_user.maker_boms.find(params[:id]), full: true)
      end

      def update
        bom = current_user.maker_boms.find(params[:id])
        bom.update!(bom_params)
        render json: bom_json(bom, full: true)
      end

      def destroy
        current_user.maker_boms.find(params[:id]).destroy!
        head :no_content
      end

      # GET /v1/maker/boms/:id/rollup — every line with its resolved target.
      def rollup
        bom = current_user.maker_boms.find(params[:id])
        render json: {
          bom: bom_json(bom),
          lines: bom.lines.map { |line| rollup_line_json(line) }
        }
      end

      private

      def bom_params
        params.fetch(:bom, {}).permit(:name, :revision)
      end

      def bom_json(bom, full: false)
        base = { id: bom.id, project_id: bom.project_id, name: bom.name, revision: bom.revision,
                 created_at: bom.created_at, updated_at: bom.updated_at }
        return base unless full
        base.merge(line_count: bom.lines.count)
      end

      def rollup_line_json(line)
        { id: line.id, reference: line.reference, quantity: line.quantity, unit: line.unit,
          notes: line.notes, position: line.position,
          target_kind: line.target_kind, target: line.resolved_target }
      end
    end
  end
end
