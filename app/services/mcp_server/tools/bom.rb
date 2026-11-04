# frozen_string_literal: true

module McpServer
  module Tools
    # THE BILL OF MATERIALS: read one with its rollup (Maker::BomRollup, over lines loaded WITH their
    # items so it issues no query), add a line, change a line. A line's target rules are the
    # model's (Maker::BomLine#exactly_one_target), answered in its own words.
    module Bom
      def self.all = [ GetBom, AddBomLine, UpdateBomLine ]

      LINE_FIELDS = {
        quantity: { type: "number", exclusiveMinimum: 0 },
        unit: { type: "string", enum: Maker::BomLine::UNITS },
        reference: { type: "string", maxLength: 100 },
        notes: { type: "string" },
        part_name: { type: "string", maxLength: 200, description: "A free-text part, for a line with no inventory item." },
        inventory_item_id: { type: "integer", description: "A stock line, counted in the item's unit." },
        supplier_id: { type: "integer" }
      }.freeze

      class GetBom < McpServer::Tool
        tool_name "get_bom"
        description "A project's bill of materials: every BOM it has, and the lines of one of them " \
                    "(bom_id, else the first) -- each line's target (an inventory item with stock on " \
                    "hand, a free-text part, or a design file), which stock lines are short, and the " \
                    "estimated cost."
        input_schema(
          properties: { project: { type: "string", description: "The project's slug." }, bom_id: { type: "integer" } },
          required: %w[project], additionalProperties: false
        )
        reads!

        def self.perform(user, project:, bom_id: nil)
          p = project!(user, project)
          boms = p.boms.order(:id).to_a
          counts = Maker::BomLine.where(bom_id: boms.map(&:id)).group(:bom_id).count
          bom = bom_id ? boms.find { |b| b.id == bom_id } : boms.first
          raise NotFound, "No BOM with id #{bom_id} on project #{p.slug.inspect}." if bom_id && bom.nil?

          answer = { project: p.slug, boms: boms.map { |b| Render.bom(b, lines: counts.fetch(b.id, 0)) } }
          return answer.merge(bom: nil) if bom.nil?

          lines = bom.lines.includes(:inventory_item, :supplier).to_a
          rollup = Maker::BomRollup.new(lines)
          answer.merge(bom: Render.bom(bom, lines: lines.size).merge(
            lines: lines.map { |l| Render.line(l) },
            short: rollup.short.map do |s|
              { line_id: s.line.id, item: s.line.inventory_item.name,
                needed: Render.number(s.line.quantity), on_hand: Render.number(s.on_hand) }
            end,
            estimated_cost: Render.number(rollup.estimated_cost)
          ))
        end
      end

      class AddBomLine < McpServer::Tool
        tool_name "add_bom_line"
        description "Add a line to a project's BOM (its first, or bom_id). Exactly one of " \
                    "inventory_item_id (a stock line, counted in the item's unit) or part_name (a " \
                    "free-text part). A project with no BOM gets one. quantity defaults to 1."
        input_schema(
          properties: { project: { type: "string", description: "The project's slug." }, bom_id: { type: "integer" } }.merge(LINE_FIELDS),
          required: %w[project], additionalProperties: false
        )
        writes!

        # ONE TRANSACTION: a project with no BOM gets one here, and a line the model then refuses must
        # not leave that empty BOM behind -- a refused call changes nothing (spec §7).
        def self.perform(user, project:, bom_id: nil, **fields)
          p = project!(user, project)
          Maker::Bom.transaction do
            bom =
              if bom_id
                p.boms.find_by(id: bom_id) || raise(NotFound, "No BOM with id #{bom_id} on project #{p.slug.inspect}.")
              else
                p.boms.order(:id).first || p.boms.create!(user: user)
              end
            line = bom.lines.create!(fields.merge(user: user))
            { bom_id: bom.id, line: Render.line(line) }
          end
        end
      end

      class UpdateBomLine < McpServer::Tool
        tool_name "update_bom_line"
        description "Change a BOM line's quantity, unit, reference, notes, part name, inventory item " \
                    "or supplier; only the fields given change."
        input_schema(
          properties: { id: { type: "integer" } }.merge(LINE_FIELDS),
          required: %w[id], additionalProperties: false
        )
        writes!(idempotent: true)

        def self.perform(user, id:, **fields)
          line = bom_line!(user, id)
          line.update!(fields)
          { line: Render.line(line) }
        end
      end
    end
  end
end
