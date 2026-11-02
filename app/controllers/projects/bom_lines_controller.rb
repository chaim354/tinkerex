module Projects
  # The bill of materials' three write doors (stage 2, S2-4). Session-authed, like every
  # Projects::* controller — the same Maker::Bom / Maker::BomLine models the v1 BomLines API
  # writes, never the device-token API. ONE bom per project on the web: the latest revision
  # (Maker::Project#current_bom), created here by the FIRST line's POST and never by a reader —
  # ProjectsController#show and Projects::BomsController#show both only ever READ current_bom.
  # Consume is the ledger's one door, Maker::InventoryTransaction.apply!, posted with the project
  # so the transaction records what it was for.
  #
  # PLAIN FORMS + REDIRECTS ON SUCCESS, no turbo_stream — unlike Projects::TasksController, which
  # answers twice to avoid a full-page repaint on every check-off. A BOM line is added, removed or
  # consumed far less often than a task is toggled, so the no-JS path IS the path here, not a
  # fallback. A REFUSED LINE KEEPS WHAT WAS TYPED (2026-11-02, the UX audit's B3): it comes back as
  # the open composer with its error and every field as posted (Projects::ComposerRefusal), 422 —
  # where a redirect with an alert used to hand back an empty form, the part name gone.
  class BomLinesController < ApplicationController
    include Projects::ComposerRefusal

    # The project panel's row cap — ProjectsController#show slices @bom_lines to this many for the
    # table and points "Showing N of M" at the full page. Shared with the panel view via this
    # constant rather than a duplicated literal.
    PANEL_CAP = 8
    TARGETS = %w[stock file text].freeze

    def create
      project = current_user.maker_projects.find_by!(slug: params[:project_id])
      # `posted` IS WHAT THE MAKER TYPED, KEPT WHOLE for a refusal to hand back; `attrs` is what
      # the line is built from, with the unchosen targets dropped below.
      posted = line_params.to_h.symbolize_keys
      attrs = posted.dup
      kind = params.dig(:bom_line, :target_kind).to_s
      unless TARGETS.include?(kind)
        return refuse(project, posted, kind, "Pick what the line points at: stock, a file, or a part name.")
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
        # The composer's unit field is for file and text lines. A stock line is counted in its
        # item's unit, which Maker::BomLine#unit reads from the item at every door (audit F-S16-2),
        # so nothing is looked up or copied here; a foreign item is the model's to refuse.
        return refuse(project, posted, kind, "Pick a stock item.") if attrs[:inventory_item_id].blank?
      when "file"
        # SCOPED TO THIS USER'S LIVE NODES, not a bare Node.find_by — an unscoped lookup would let
        # a crafted node_id point a line at another tenant's file (CLAUDE.md §8).
        node = current_user.nodes.present.find_by(node_id: attrs[:node_id], kind: "file")
        return refuse(project, posted, kind, "That file isn't in your library. Choose another.") unless node
      when "text"
        return refuse(project, posted, kind, "Enter a part name.") if attrs[:part_name].blank?
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
        refuse(project, posted, kind, "Not added: #{line.errors.full_messages.to_sentence}.")
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
    # The ledger decides what it will post. A line's quantity passes BomLine's greater_than: 0 and can
    # still be one the ledger refuses (Infinity does), so the refusal comes back here as the alert.
    rescue ActiveRecord::RecordInvalid => e
      back_to(project, alert: "Nothing was consumed: #{e.record.errors.full_messages.to_sentence}.")
    end

    private

    # The composer again, open, holding what was posted — the draft line (never saved, never
    # attached to a bom), the chosen radio, and the chosen file's name for the chooser's label. Its
    # two pick lists are re-read here, the queries the panel's own render pays.
    def refuse(project, posted, kind, error)
      file_name = posted[:node_id].presence && current_user.nodes.present.find_by(node_id: posted[:node_id])&.name
      refuse_in_composer(project, id: "bom-composer", partial: "projects/bom_composer",
                         locals: { project:, draft: Maker::BomLine.new(posted), kind:, file_name:, error:,
                                   items: current_user.maker_inventory_items.order(:name).pluck(:name, :id),
                                   suppliers: current_user.maker_suppliers.order(:name).pluck(:name, :id) },
                         title: "Add a line to the bill of materials")
    end

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
