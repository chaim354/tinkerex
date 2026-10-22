module Maker
  module Xlsx
    # ONE WORKSHEET, STREAMED INTO THE GRID'S PAYLOAD AND STOPPED AT THE ROW CAP.
    #
    # Rows and cells are addressed by their own `r` attributes where the file gives them, and by
    # position where it does not (both are legal OOXML; Excel always writes them, some generators
    # do not). Gaps are real: row 7 after row 3 means rows 4-6 are empty, and the grid shows them
    # empty so its row 7 is the file's row 7 — the edit operations depend on that one-to-one map.
    #
    # Every cell is shown as Excel would show its stored value (Workbook's header). A formula is
    # also reported by its text so the page can show it; a SHARED formula's dependent cells carry
    # no text of their own, so theirs is the master's translated by the offset — Excel's own rule.
    class SheetReader
      ELEMENT = Nokogiri::XML::Reader::TYPE_ELEMENT
      END_ELEMENT = Nokogiri::XML::Reader::TYPE_END_ELEMENT
      TEXTS = [ Nokogiri::XML::Reader::TYPE_TEXT, Nokogiri::XML::Reader::TYPE_CDATA,
                Nokogiri::XML::Reader::TYPE_SIGNIFICANT_WHITESPACE ].freeze
      DEFAULT_COL_CHARS = 8.43

      # OOXML escapes a character XML cannot carry as `_xHHHH_`, and a literal `_x…_` as `_x005F_x…_`.
      def self.decode(text) = text.gsub(/_x([0-9A-Fa-f]{4})_/) { Regexp.last_match(1).hex.chr(Encoding::UTF_8) }

      def initialize(workbook, sheet)
        @wb = workbook
        @sheet = sheet
      end

      def read(row_cap:, col_cap:)
        @cells = {}
        @formulas = {}
        @masters = {}
        @widths = {}
        @default_chars = DEFAULT_COL_CHARS
        @max_row = 0
        @max_col = 0
        @more_rows = false
        @more_cols = false
        @dimension = nil
        stream(row_cap, col_cap)
        assemble(row_cap, col_cap)
      rescue Nokogiri::XML::SyntaxError
        raise Unreadable, "This workbook is damaged and cannot be read here."
      end

      private

      def stream(row_cap, col_cap)
        row = 0
        col = 0
        cell = nil
        capture = nil
        in_is = false
        in_rph = false
        Nokogiri::XML::Reader(@wb.sheet_xml(@sheet)).each do |n|
          if n.node_type == ELEMENT
            case n.local_name
            when "dimension" then @dimension = Xlsx.parse_area(n.attribute("ref"))
            when "sheetFormatPr"
              @default_chars = n.attribute("defaultColWidth")&.to_f || @default_chars
            when "col" then record_width(n, col_cap)
            when "row"
              row = n.attribute("r")&.to_i || (row + 1)
              col = 0
              if row > row_cap
                @more_rows = true
                break
              end
            when "c"
              ref = n.attribute("r") && Xlsx.parse_cell(n.attribute("r"))
              col = ref ? ref[1] : col + 1
              cell = { row:, col:, t: n.attribute("t"), s: n.attribute("s"), v: nil, f: nil, f_attrs: nil, is: +"" }
              if n.empty_element?
                finish(cell, col_cap)
                cell = nil
              end
            when "v" then capture = :v unless n.empty_element?
            when "f"
              next unless cell

              cell[:f_attrs] = { t: n.attribute("t"), ref: n.attribute("ref"), si: n.attribute("si") }
              cell[:f] = +""
              capture = :f unless n.empty_element?
            when "is" then in_is = true unless n.empty_element?
            when "rPh" then in_rph = true unless n.empty_element?
            when "t" then capture = :is if in_is && !in_rph && !n.empty_element?
            end
          elsif TEXTS.include?(n.node_type)
            next unless capture && cell

            if capture == :v
              (cell[:v] ||= +"") << n.value
            else
              cell[capture] << n.value
            end
          elsif n.node_type == END_ELEMENT
            case n.local_name
            when "v", "f", "t" then capture = nil
            when "is" then in_is = false
            when "rPh" then in_rph = false
            when "c"
              finish(cell, col_cap) if cell
              cell = nil
            when "sheetData" then break
            end
          end
        end
      end

      def record_width(node, col_cap)
        chars = node.attribute("width")&.to_f or return
        min = node.attribute("min").to_i
        max = [ node.attribute("max").to_i, col_cap ].min
        (min..max).each { |c| @widths[c] = chars }
      end

      def finish(cell, col_cap)
        r, c = cell.values_at(:row, :col)
        @max_row = r if r > @max_row
        if c > col_cap
          @more_cols = true
          return
        end
        @max_col = c if c > @max_col

        formula = formula_text(cell)
        text = display(cell)
        text = "=#{formula}" if text.empty? && formula && cell[:v].nil?
        @cells[[ r, c ]] = text unless text.empty?
        @formulas[[ r, c ]] = formula ? "=#{formula}" : "(shared formula)" if cell[:f_attrs] && (formula || cell[:f_attrs][:t] == "shared")
      end

      def formula_text(cell)
        attrs = cell[:f_attrs] or return nil
        text = cell[:f].to_s
        if attrs[:t] == "shared"
          if text.present? && attrs[:si]
            @masters[attrs[:si]] = [ cell[:row], cell[:col], text ]
          elsif (master = @masters[attrs[:si]])
            mr, mc, mtext = master
            return FormulaRefs.translate(mtext, rows: cell[:row] - mr, cols: cell[:col] - mc)
          end
        end
        text.presence
      rescue FormulaRefs::Unsupported
        nil
      end

      def display(cell)
        v = cell[:v]
        case cell[:t]
        when "s" then @wb.shared_strings[v.to_i].to_s
        when "inlineStr" then SheetReader.decode(cell[:is])
        when "str", "e", "d" then SheetReader.decode(v.to_s)
        when "b" then v.to_s.strip == "1" ? "TRUE" : "FALSE"
        else v.nil? ? "" : CellFormat.display(v.strip, @wb.format_code(cell[:s]), date1904: @wb.date1904)
        end
      end

      def assemble(row_cap, col_cap)
        dim_bottom = @dimension ? @dimension[2] : 0
        dim_right = @dimension ? @dimension[3] : 0
        shown_rows = [ [ @max_row, (@more_rows ? row_cap : 0) ].max, row_cap ].min
        shown_cols = [ @max_col, col_cap ].min
        locked = @wb.locked_areas(@sheet).flat_map do |top, left, bottom, right|
          (top..[ bottom, shown_rows ].min).flat_map { |r| (left..[ right, shown_cols ].min).map { |c| "#{r - 1},#{c - 1}" } }
        end
        {
          rows: Array.new(shown_rows) { |r| Array.new(shown_cols) { |c| @cells.fetch([ r + 1, c + 1 ], "") } },
          formulas: @formulas.to_h { |(r, c), text| [ "#{r - 1},#{c - 1}", text ] },
          locked:,
          shown_rows:, shown_cols:,
          # nil when the read stopped early and the file's own `<dimension>` cannot say how far it
          # goes: "the first 1,000 rows" is true, "of 1,001" would not be.
          total_rows: @more_rows ? (dim_bottom > row_cap ? dim_bottom : nil) : @max_row,
          total_cols: @more_cols ? (dim_right > col_cap ? dim_right : nil) : @max_col,
          more_rows: @more_rows, more_cols: @more_cols,
          widths: Array.new(shown_cols) { |c| px(@widths.fetch(c + 1, @default_chars)) }
        }
      end

      # Excel's column width is in characters of the default font's widest digit (7px for 11pt
      # Calibri, plus 5px of padding). The grid draws in the app's own 13px UI face, a little wider,
      # so a character is 8px and the padding the cell's own: an ISO date fits the default column.
      def px(chars) = (chars * 8 + 12).round.clamp(40, 400)
    end
  end
end
