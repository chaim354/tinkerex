module Projects
  # The bill of materials' three write doors (stage 2, S2-4). Session-authed, like every
  # Projects::* controller — the same Maker::Bom / Maker::BomLine models the v1 BomLines API
  # writes, never the device-token API. ONE bom per project on the web: the latest revision
  # (Maker::Project#current_bom), created here by the FIRST line's POST and never by a reader —
  # ProjectsController#show and Projects::BomsController#show both only ever READ current_bom.
  # Consume is the ledger's one door, Maker::InventoryTransaction.apply!, posted with the project
  # so the transaction records what it was for.
  #
  # PLAIN FORMS + REDIRECTS ONLY, no turbo_stream — unlike Projects::TasksController, which answers
  # twice to avoid a full-page repaint on every check-off. A BOM line is added, removed or consumed
  # far less often than a task is toggled, so the no-JS path IS the path here, not a fallback.
  class BomLinesController < ApplicationController
    # The project panel's row cap — ProjectsController#show slices @bom_lines to this many for the
    # table and points "Showing N of M" at the full page. Shared with the panel view via this
    # constant rather than a duplicated literal.
    PANEL_CAP = 8
    TARGETS = %w[stock file text].freeze

    def create
      project = current_user.maker_projects.find_by!(slug: params[:project_id])
      attrs = line_params.to_h.symbolize_keys
      kind = params.dig(:bom_line, :target_kind).to_s
      unless TARGETS.include?(kind)
        return back_to(project, alert: "Pick what the line points at: stock, a file, or a part name.")
      end
      # EXACTLY ONE TARGET, CHOSEN BY THE RADIO: the other two inputs are dropped here so a
      # filled-in but unchosen field can never make the model's exactly_one_target refuse a line
      # the user meant (e.g. an item left selected from a previous add while "Part name" is what
      # was actually filled in and chosen this time).
      attrs[:inventory_item_id] = nil unless kind == "stock"
      attrs[:node_id] = nil unless kind == "file"
      attrs[:part_name] = nil unless kind == "text"
      case kind
      when "stock"
        return back_to(project, alert: "Pick a stock item.") if attrs[:inventory_item_id].blank?
        # A STOCK LINE IS COUNTED IN ITS ITEM'S UNIT. Consume subtracts `quantity` from the item, so a
        # line that said "2 kg" of an item stocked in "each" would take 2 each while the row read kg
        # (found in review). The composer's unit field is for file and text lines; a stock line takes
        # the item's. A foreign item resolves to nothing here and is left for the model to refuse.
        item = current_user.maker_inventory_items.find_by(id: attrs[:inventory_item_id])
        attrs[:unit] = item.unit if item
      when "file"
        # SCOPED TO THIS USER'S LIVE NODES, not a bare Node.find_by — an unscoped lookup would let
        # a crafted node_id point a line at another tenant's file (CLAUDE.md §8).
        node = current_user.nodes.present.find_by(node_id: attrs[:node_id], kind: "file")
        return back_to(project, alert: "That file isn't in your library.") unless node
      when "text"
        return back_to(project, alert: "Enter a part name.") if attrs[:part_name].blank?
      end

      # THE BOM AND ITS FIRST LINE LAND TOGETHER OR NOT AT ALL. The bom is minted lazily by the
      # first line, so a line the MODEL refuses (a foreign item or supplier — the doors above catch
      # only the shapes they can see) must not leave an empty bom behind: the create and the save
      # share one transaction, rolled back when the line fails.
      line = nil
      Maker::Bom.transaction do
        bom = project.current_bom || project.boms.create!(user: current_user)
        line = bom.lines.new(attrs.merge(user: current_user, position: (bom.lines.maximum(:position) || -1) + 1))
        raise ActiveRecord::Rollback unless line.save
      end
      if line.persisted?
        back_to(project, notice: "Added #{line_label(line)}.")
      else
        back_to(project, alert: line.errors.full_messages.to_sentence)
      end
    end

    def destroy
      line = current_user.maker_bom_lines.find(params[:id])
      project = line.bom.project
      label = line_label(line)
      line.destroy!
      back_to(project, notice: "Removed #{label}.")
    end

    def consume
      line = current_user.maker_bom_lines.includes(:inventory_item, bom: :project).find(params[:id])
      project = line.bom.project
      item = line.target_kind == :inventory_item ? line.inventory_item : nil
      return back_to(project, alert: "Only a stock line can be consumed.") unless item

      Maker::InventoryTransaction.apply!(item:, user: current_user, delta: -line.quantity, reason: "consumed",
                                         project_id: project.id, note: "BOM: #{line_label(line)}")
      back_to(project, notice: "Consumed #{fmt_qty(line.quantity)} #{item.unit} of #{item.name} for #{project.name}.")
    end

    private

    def line_params
      params.require(:bom_line).permit(
        :reference, :quantity, :unit, :inventory_item_id, :node_id, :part_name, :supplier_id, :notes
      )
    end

    def back_to(project, **flash_args) = redirect_back_or_to(project_path(project), **flash_args)

    # The name a flash/ledger-note uses for a line: the reference if the user gave one (already a
    # complete label they chose), else the target's own name with the quantity folded in — "NEMA17
    # ×2" — so a note reads as "BOM: NEMA17 ×2" rather than an ambiguous "BOM: NEMA17" that cannot
    # say how much of it this particular consumption was for.
    def line_label(line)
      return line.reference if line.reference.present?
      target = case line.target_kind
      when :inventory_item then line.inventory_item&.name || "item"
      when :design_file then (current_user.nodes.present.find_by(node_id: line.node_id)&.name || "file")
      when :free_text then line.part_name
      else "line"
      end
      "#{target} ×#{fmt_qty(line.quantity)}"
    end

    # "2" rather than "2.0" for a whole quantity, "1.5" for a fractional one — the same
    # strip-insignificant-zeros rule the views use (ActiveSupport::NumberHelper needs no view
    # context, so the flash can format the identical way without rendering through a helper).
    def fmt_qty(qty)
      ActiveSupport::NumberHelper.number_to_rounded(qty, precision: 3, strip_insignificant_zeros: true)
    end
  end
end
