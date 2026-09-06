require "csv"

module Maker
  # THE PUBLIC BILL OF MATERIALS AS CSV (stage 3, S3-6) — five columns and nothing else.
  #
  # IT IS THE PUBLIC PARTIAL'S RULE, IN A SECOND MEDIUM, WHICH IS EXACTLY THE PAIR THAT DRIFTS.
  # `public/projects/_bom.html.erb` decides what a line's PART is worth saying, and it makes one
  # decision that is a privacy rule rather than a display choice: a design-file line whose node the
  # project does NOT permit is rendered as the line's own free text or a dash, NEVER as the node's
  # name — because a BOM line may point anywhere in the owner's library, and naming a file the
  # route would 404 publishes a private filename. This class repeats that rule and nothing else;
  # `pub.permits?` is the same object the page and the file route ask, so the three cannot disagree.
  #
  # NO STOCK, NO SUPPLIER, NO NOTES, for the partial's own reasons: how many the maker has on hand
  # is their inventory, who they buy from is a private business relationship, and neither is this
  # project's description. A CSV is the easiest place for one of them to be added back "because it
  # was in the model anyway", which is why the column list is a frozen constant and the test asserts
  # the header exactly.
  #
  # AN EMPTY BOM IS A HEADER-ONLY FILE, not an empty one: a spreadsheet that opens on named columns
  # says "this project publishes no parts", where zero bytes says "something went wrong".
  class BomCsv
    HEADERS = %w[reference part quantity unit file].freeze

    def self.render(lines, pub) = new(lines, pub).render

    def initialize(lines, pub)
      @lines = lines
      @pub = pub
    end

    def render
      CSV.generate do |csv|
        csv << HEADERS
        @lines.each { |line| csv << row_for(line) }
      end
    end

    private

    def row_for(line)
      node = permitted_node(line)
      # `file` NAMES THE PATH INSIDE THE BUNDLE where the listing holds this node, so a row of the
      # CSV points at a file sitting beside it in the same zip. A permitted file the listing does
      # not hold (attached from elsewhere in the library, or past FILE_CAP) still gets its name.
      file = node && (@pub.bundle_path_for(node.node_id) || node.name)
      [ defuse(line.reference), defuse(part_for(line, node)), line.quantity, defuse(line.unit), defuse(file) ]
    end

    # A STRANGER OPENS THIS FILE IN A SPREADSHEET. A cell beginning `=`, `+`, `-`, `@`, a tab or a
    # carriage return is a FORMULA to Excel and Sheets, so a published part name of `=HYPERLINK(…)`
    # would run in the visitor's sheet. A leading apostrophe makes it text again — the standard
    # defusal — and only this export needs it: `Maker::Sheet#to_csv` preserves formulas on purpose,
    # because that is the owner downloading their own sheet (S3-6's review).
    FORMULA_LEAD = /\A[=+\-@\t\r]/

    def defuse(value)
      return value unless value.is_a?(String) && value.match?(FORMULA_LEAD)

      "'#{value}"
    end

    # The node this line points at, ONLY when the project permits it. Resolved through the page's
    # own live-node index (`page_nodes`), which is where the partial resolves it too.
    def permitted_node(line)
      return nil unless line.target_kind == :design_file

      node = @pub.page_nodes[line.node_id]
      node && @pub.permits?(node) ? node : nil
    end

    def part_for(line, node)
      case line.target_kind
      when :inventory_item then line.inventory_item&.name || line.part_name
      when :design_file    then node&.name || line.part_name
      when :free_text      then line.part_name
      end
    end
  end
end
