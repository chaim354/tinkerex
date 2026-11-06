module Maker
  class Readme
    module Live
      # `bom` (spec §4): Ref / Part / Qty / Supplier over the current revision's lines, in position
      # order. Part is the line's target (BomLine#target_kind): the inventory item's name, a design file
      # linked by its relative path when it is in the folder, or the free-text name.
      module BomTable
        HEADERS = %w[Ref Part Qty Supplier].freeze

        def self.call(_args, context:, mode:)
          lines = context.bom_lines
          return Live.note("No bill of materials yet.") if lines.empty?

          Live.table(HEADERS, lines.map do |line|
            [ Live.cell(line.reference), part(line, context),
              Live.cell("#{quantity(line)} #{line.unit}"), Live.cell(line.supplier&.name) ]
          end)
        end

        def self.part(line, context)
          case line.target_kind
          when :inventory_item then Live.cell(line.inventory_item&.name || line.part_name)
          when :design_file
            row = context.row(line.node_id)
            # In the folder: a link. Elsewhere in the library: its name, from the context's ONE batched
            # lookup (spec §4). Gone: said so, the way the public BOM table says it.
            row ? Live.link(row.node.name, context.relative_path(row)) : Live.cell(context.node_name(line.node_id) || "a file no longer in the library")
          else Live.cell(line.part_name)
          end
        end

        # 4.000 reads as 4 and 0.500 as 0.5 — the BOM panel's own spelling (projects/_bom_lines).
        def self.quantity(line)
          ActiveSupport::NumberHelper.number_to_rounded(line.quantity, precision: 3, strip_insignificant_zeros: true)
        end
      end
    end
  end
end
