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

      # AN ABSENT `bom` KEY CREATES A DEFAULTED BOM; AN EXPLICIT `null` IS A MALFORMED BODY.
      # `fetch`'s default fires on ABSENCE ONLY, so `{"bom": null}` returned nil and `.permit`
      # raised `NoMethodError: undefined method 'permit' for nil` — the one UNRESCUED 500 in the
      # v1 maker controllers, since `V1::BaseController` maps `ParameterMissing`/`RecordInvalid`
      # and nothing maps that.
      #
      # THE ABSENT HALF IS DELIBERATE AND STAYS: a BOM needs no attributes (`{"bom": {}}` and a
      # bodyless POST both create one, name "BOM", revision 1), so `require(:bom)` outright would
      # turn today's 201 into a 400 for a request that is fine. Only the null arm moves.
      #
      # 400, NOT 422, AND THAT WAS PROBED RATHER THAN REASONED. Every sibling body-param
      # controller here (`projects`, `items`, `tasks`, `suppliers`, …) uses `params.require` and
      # answers 400 `param is missing…` for an explicit null — identical to absent. The 422s
      # elsewhere in this family come from a MODEL validation refusing a nil SCALAR
      # (`inventory_items#adjust`'s `fetch(:reason, "adjusted")` → "Reason is not included in the
      # list"); `bom` is an attributes hash with no such validation waiting for it — `{"bom": {}}`
      # saves — so there would be nothing for a 422 to name. Answering 422 here would make this
      # the only endpoint in the API giving one condition a second answer, CLAUDE.md §14a's
      # recorded failure shape.
      def bom_params
        (params.fetch(:bom, {}) || params.require(:bom)).permit(:name, :revision)
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
