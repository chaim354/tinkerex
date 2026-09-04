module Projects
  # The bill of materials' full page (stage 2, S2-4) — every line, where the project page's panel
  # shows only Projects::BomLinesController::PANEL_CAP. Read-only: the doors that write are
  # Projects::BomLinesController. A GET here never creates a bom — Maker::Project#current_bom
  # answers nil for a project with none yet, and the view renders the empty state plus the
  # composer, exactly like the panel does.
  class BomsController < ApplicationController
    # The page's own live-node index for design-file line targets (PageNodes — same concern
    # ProjectsController uses for its one page-wide union; this page has its own, smaller union).
    include PageNodes

    def show
      @project = current_user.maker_projects.find_by!(slug: params[:project_id])
      @bom = @project.current_bom
      @lines = @bom ? @bom.lines.includes(:inventory_item, :supplier).to_a : []
      @line_nodes = live_nodes_for(@lines.filter_map(&:node_id))
      @rollup = Maker::BomRollup.new(@lines)
      @items = current_user.maker_inventory_items.order(:name).pluck(:name, :id)
      @suppliers = current_user.maker_suppliers.order(:name).pluck(:name, :id)
    end
  end
end
