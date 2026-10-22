module Maker
  module Xlsx
    # A LIST OF OPERATIONS, APPLIED TO A WORKBOOK'S BYTES — the whole of what a save does.
    #
    #   { sheet:, op: "set", row:, col:, value: }        one cell, as typed (0-based row/col)
    #   { sheet:, op: "insert_rows", at:, count: }        `count` empty rows before grid row `at`
    #   { sheet:, op: "delete_rows", at:, count: }        grid rows at .. at+count-1
    #
    # `sheet` is the index in workbook.xml's own order; `row`/`col`/`at` are the grid's 0-based
    # coordinates, which are the file's 1-based rows and columns minus one (SheetReader keeps that
    # map exact). Operations apply IN ORDER, against the state the previous ones left, because that is
    # the order the maker made them in and the indices each carries are only true at that moment.
    #
    # WHAT IT NEVER DOES: rewrite a cell nobody touched, or a part nobody touched. A cell edit keeps
    # the cell's style (`s`); a part no operation reached is copied from the package as it was read.
    # The exceptions are stated: workbook.xml gains `fullCalcOnLoad` (formula results this editor
    # cannot compute are recalculated by the next Excel or LibreOffice to open the file), and the
    # calcChain is removed with its relationship and content type, because it lists formula cells
    # and goes stale the moment one is overwritten — Excel reports a stale chain as a repaired file
    # and rebuilds a missing one silently.
    #
    # EVERY REFUSAL IS A `Refused` RAISED BEFORE ANYTHING IS WRITTEN — the bytes are rebuilt only
    # after the last operation applied — so a half-applied list never reaches the store.
    class Edit
      MAX_OPS = 5_000
      MAX_VALUE = 32_767 # Excel's own limit for one cell
      MAX_ROWS_PER_OP = 1_000
      NS = { "m" => MAIN_NS }.freeze
      # Characters XML 1.0 cannot carry at all. A cell cannot hold them in Excel either.
      INVALID_XML = /[\u0000-\u0008\u000B\u000C\u000E-\u001F￾￿]/

      def self.apply(bytes, ops) = new(Package.open(bytes)).apply(ops)

      def initialize(package)
        @pkg = package
        @wb = Workbook.new(package)
        @docs = {}
        @dirty = Set.new
        @unshared_all = false
      end

      def apply(ops)
        normalize(ops).each { |op| send(:"apply_#{op[:op]}", op) }
        @pkg.write(replace: replacements, remove: removals)
      end

      private

      # --- operations ----------------------------------------------------------------------

      def apply_set(op)
        sheet, row, col, value = op.values_at(:sheet, :row, :col, :value)
        name = Xlsx.cell_name(row, col)
        if @wb.locked_areas(sheet).any? { |t, l, b, r| row.between?(t, b) && col.between?(l, r) }
          raise Refused, "#{sheet.name}!#{name} is part of an array formula, which can only be changed in Excel."
        end

        cell = find_cell(sheet, row, col)
        unshare!(sheet, only: cell.at_xpath("m:f", NS)["si"]) if cell && shared_master?(cell)
        if value.empty?
          clear_cell(sheet, cell) if cell
        else
          cell ||= create_cell(sheet, row, col)
          write_value(sheet, cell, value, name)
          grow_dimension(sheet, row, col)
        end
        @dirty << sheet.index
      end

      def apply_insert_rows(op) = shift_rows(op[:sheet], op[:at], op[:count])
      def apply_delete_rows(op) = shift_rows(op[:sheet], op[:at], -op[:count])

      # --- cells ----------------------------------------------------------------------------

      # What a typed value becomes — Excel's own reading of what someone typed, cut down to what a
      # plain grid can mean without changing the cell's format: see the plan's decision 5.
      def write_value(sheet, cell, raw, name)
        clear_value(cell)
        kind = @wb.format_kind(cell["s"])
        # A Text-formatted cell takes what is typed as text, `=` included — Excel's rule, and the
        # reason a maker formats a part-number column as Text in the first place.
        if raw.start_with?("'")
          inline_string(cell, raw[1..])
        elsif kind == :text
          inline_string(cell, raw)
        elsif raw.start_with?("=") && raw.length > 1
          formula = raw[1..]
          check_formula!(formula, "#{sheet.name}!#{name}", raw)
          add(cell, "f", formula)
        elsif raw.match?(/\A(true|false)\z/i)
          cell["t"] = "b"
          add(cell, "v", raw.casecmp?("true") ? "1" : "0")
        elsif (number = number_for(raw, kind, @wb.format_code(cell["s"])))
          add(cell, "v", number)
        else
          inline_string(cell, raw)
        end
      end

      def number_for(raw, kind, code)
        text = raw.strip
        if %i[date datetime].include?(kind) && (serial = date_serial(text))
          return serial
        end
        if kind == :time && (m = /\A(\d{1,2}):(\d{2})(?::(\d{2}))?\z/.match(text))
          return canonical((m[1].to_i * 3600 + m[2].to_i * 60 + m[3].to_i) / 86_400.0)
        end

        scale = 1
        if kind == :percent && text.end_with?("%")
          text = text.delete_suffix("%").strip
          scale = 100
        end
        symbol = CellFormat.currency_symbol(code.to_s.split(";").first.to_s)
        text = text.sub(/\A(-?)#{Regexp.escape(symbol)}/, '\1') if symbol.present?
        return nil unless text.match?(/\A[-+]?(\d{1,3}(,\d{3})+|\d+)?(\.\d+)?([eE][-+]?\d+)?\z/) && text.match?(/\d/)

        canonical(BigDecimal(text.delete(",")) / scale)
      rescue ArgumentError
        nil
      end

      # nil for a number a double cannot hold (`1e400`): `<v>` is an xsd:double, and "Infinity"
      # there is a file Excel repairs, so the caller keeps what was typed as text instead.
      def canonical(n)
        d = n.is_a?(BigDecimal) ? n : BigDecimal(n.to_s)
        return d.to_i.to_s if d.frac.zero? && d.abs < 1e15

        f = d.to_f
        f.finite? && !(f.zero? && !d.zero?) ? f.to_s : nil
      end

      def date_serial(text)
        m = /\A(\d{4})-(\d{2})-(\d{2})(?:[ T](\d{1,2}):(\d{2})(?::(\d{2}))?)?\z/.match(text) or return nil
        date = Date.new(m[1].to_i, m[2].to_i, m[3].to_i)
        days = @wb.date1904 ? (date - Date.new(1904, 1, 1)).to_i : (date - Date.new(1899, 12, 30)).to_i
        days -= 1 if !@wb.date1904 && date < Date.new(1900, 3, 1)
        return nil if days.negative?

        secs = m[4].to_i * 3600 + m[5].to_i * 60 + m[6].to_i
        canonical(BigDecimal(days) + BigDecimal(secs) / 86_400)
      rescue Date::Error
        nil
      end

      # NOT A PARSER — Excel's grammar is not reproduced here. What it catches is the formula that
      # would make Excel REPAIR the file on open (an unclosed bracket or quote, a dangling operator):
      # a formula Excel merely cannot evaluate is a valid file showing #NAME?, and that is Excel's
      # answer to give.
      def check_formula!(formula, where, raw)
        depth = 0
        quote = nil
        formula.each_char do |ch|
          if quote
            quote = nil if ch == quote
          elsif ch == '"' || ch == "'"
            quote = ch
          elsif ch == "("
            depth += 1
          elsif ch == ")"
            depth -= 1
            break if depth.negative?
          end
        end
        return if depth.zero? && quote.nil? && !formula.rstrip.match?(%r{[-+*/^&=<>,(:]\z})

        raise Refused, "#{where}: the formula #{raw} looks unfinished. Finish it, or start it with an " \
                       "apostrophe to keep it as text."
      end

      def inline_string(cell, text)
        text = text.gsub(INVALID_XML, "").gsub(/_(?=x[0-9A-Fa-f]{4}_)/, "_x005F_")
        cell["t"] = "inlineStr"
        is = element(cell.document, "is")
        t = element(cell.document, "t")
        t.content = text
        t["xml:space"] = "preserve" if text.match?(/\A\s|\s\z|\n/)
        is.add_child(t)
        insert_value_child(cell, is)
      end

      def add(cell, name, text)
        node = element(cell.document, name)
        node.content = text.gsub(INVALID_XML, "")
        insert_value_child(cell, node)
      end

      # CT_Cell is a SEQUENCE (f, v, is, extLst), so a value goes before an extension list.
      def insert_value_child(cell, node)
        ext = cell.at_xpath("m:extLst", NS)
        ext ? ext.add_previous_sibling(node) : cell.add_child(node)
      end

      def clear_value(cell)
        cell.xpath("m:f|m:v|m:is", NS).each(&:remove)
        %w[t cm vm].each { |a| cell.remove_attribute(a) }
      end

      # A cell with a style keeps it (an empty, formatted cell is a real thing in a sheet); one
      # without goes, so a cleared cell leaves nothing behind.
      def clear_cell(_sheet, cell)
        clear_value(cell)
        cell.remove if cell["s"].nil? && cell.element_children.empty?
      end

      def shared_master?(cell)
        f = cell.at_xpath("m:f", NS)
        f && f["t"] == "shared" && f["ref"].present?
      end

      # A SHARED FORMULA IS STORED ONCE, on its master cell, and every dependent cell names only the
      # group (`si`). Overwriting the master would leave the others pointing at nothing, so the group
      # is first written out longhand: each dependent cell gets its own text (the master's translated
      # by the offset, Excel's rule) and the master becomes an ordinary formula. Same values, same
      # meaning, a larger file. `only:` limits it to one group; nil does every group on the sheet.
      def unshare!(sheet, only: nil)
        doc = doc_for(sheet)
        fs = doc.xpath("//m:sheetData/m:row/m:c/m:f[@t='shared']", NS)
        masters = fs.select { |f| f["ref"].present? && f.text.present? }.index_by { |f| f["si"] }
        return if masters.empty?

        fs.each do |f|
          si = f["si"]
          next if only && si != only
          next if (master = masters[si]).nil? || f.equal?(master)

          mr, mc = Xlsx.parse_cell(master.parent["r"])
          cr, cc = Xlsx.parse_cell(f.parent["r"])
          text = FormulaRefs.translate(master.text, rows: cr - mr, cols: cc - mc)
          %w[t si ref].each { |a| f.remove_attribute(a) }
          f.content = text
        end
        masters.each do |si, m|
          next if only && si != only

          %w[t si ref].each { |a| m.remove_attribute(a) }
        end
        @dirty << sheet.index
      rescue FormulaRefs::Unsupported
        raise Refused, "#{sheet.name} has a shared formula this editor cannot rewrite. Edit it in Excel."
      end

      # --- rows -----------------------------------------------------------------------------

      def shift_rows(sheet, at, count)
        refusal = @wb.row_ops_refusal(sheet) and raise Refused, refusal

        unshare_everywhere!
        @wb.worksheets.each do |ws|
          next unless ws.index == sheet.index || @docs.key?(ws.index) || @wb.sheet_xml(ws).match?(/<(?:[\w.-]+:)?f\b/)

          doc_for(ws).xpath("//m:sheetData/m:row/m:c/m:f", NS).each do |f|
            next if f.text.empty?

            shifted = FormulaRefs.shift_rows(f.text, home_sheet: ws.name, target_sheet: sheet.name, at:, count:)
            next if shifted == f.text

            f.content = shifted
            @dirty << ws.index
          end
        end
        move_rows(sheet, at, count)
        @dirty << sheet.index
      rescue FormulaRefs::Unsupported
        raise Refused, "A formula in this workbook refers to a table or another workbook, so rows can't be " \
                       "added or deleted here. Editing cells still works."
      end

      def unshare_everywhere!
        return if @unshared_all

        @wb.worksheets.each { |ws| unshare!(ws) if @wb.sheet_xml(ws).match?(/\bt=["']shared["']/) || @docs.key?(ws.index) }
        @unshared_all = true
      end

      def move_rows(sheet, at, count)
        doc = doc_for(sheet)
        rows = doc.xpath("//m:sheetData/m:row", NS)
        if count.negative?
          last = at - count - 1
          rows.each { |r| r.remove if r["r"].to_i.between?(at, last) }
        elsif rows.any? { |r| r["r"].to_i >= at && r["r"].to_i + count > MAX_ROW }
          raise Refused, "There is no room below the last row of #{sheet.name} to insert more rows."
        end

        # Every row from here down moves by `count`: the old row `at` on an insert, the first row
        # after the deleted block on a delete.
        from = count.positive? ? at : at - count
        doc.xpath("//m:sheetData/m:row", NS).each do |r|
          n = r["r"].to_i
          next if n < from

          moved = n + count
          r["r"] = moved.to_s
          r.xpath("m:c", NS).each { |c| c["r"] = "#{c["r"][/\A[A-Za-z]+/]}#{moved}" }
        end

        doc.xpath("//m:mergeCells/m:mergeCell", NS).each do |m|
          area = Xlsx.parse_area(m["ref"]) or next
          moved = shift_area(area, at, count)
          moved ? m["ref"] = Xlsx.area_name(*moved) : m.remove
        end
        if (merges = doc.at_xpath("//m:mergeCells", NS))
          kept = merges.xpath("m:mergeCell", NS).size
          kept.zero? ? merges.remove : merges["count"] = kept.to_s
        end

        if (dim = doc.at_xpath("//m:dimension", NS)) && (area = Xlsx.parse_area(dim["ref"]))
          moved = shift_area(area, at, count)
          dim["ref"] = moved ? Xlsx.area_name(*moved) : "A1"
        end
      end

      # Excel's rule for an area under a row insert (it grows when the insert is inside it) or a row
      # delete (it shrinks; nil when every row of it went). FormulaRefs applies the same rule to a
      # formula's references; the two are kept in step by the row-operation tests, which drive both.
      def shift_area((top, left, bottom, right), at, count)
        if count.positive?
          top += count if top >= at
          bottom = [ bottom + count, MAX_ROW ].min if bottom >= at
        else
          n = -count
          last = at + n - 1
          return nil if top >= at && bottom <= last

          top = top < at ? top : (top > last ? top - n : at)
          bottom = bottom > last ? bottom - n : (bottom >= at ? at - 1 : bottom)
          return nil if top > bottom
        end
        [ top, left, bottom, right ]
      end

      # --- the sheet's XML ------------------------------------------------------------------

      def doc_for(sheet)
        @docs[sheet.index] ||= begin
          doc = @wb.xml(sheet.path)
          name_cells!(doc)
          doc
        end
      end

      # A row or cell may legally omit `r` and mean "the next one". Every lookup and every move here
      # is by `r`, so the omitted ones are written out first — the same address, now explicit.
      def name_cells!(doc)
        row = 0
        doc.xpath("//m:sheetData/m:row", NS).each do |r|
          row = r["r"] ? r["r"].to_i : row + 1
          r["r"] = row.to_s
          col = 0
          r.xpath("m:c", NS).each do |c|
            col = (c["r"] && Xlsx.parse_cell(c["r"])&.last) || col + 1
            c["r"] = Xlsx.cell_name(row, col)
          end
        end
      end

      def sheet_data(sheet)
        doc_for(sheet).at_xpath("//m:sheetData", NS) || raise(Unreadable, "This workbook is damaged and cannot be read here.")
      end

      def find_row(sheet, row) = sheet_data(sheet).at_xpath("m:row[@r='#{row}']", NS)

      def find_cell(sheet, row, col)
        find_row(sheet, row)&.at_xpath("m:c[@r='#{Xlsx.cell_name(row, col)}']", NS)
      end

      def create_cell(sheet, row, col)
        r = find_row(sheet, row) || create_row(sheet, row)
        c = element(r.document, "c")
        c["r"] = Xlsx.cell_name(row, col)
        after = r.xpath("m:c", NS).find { |x| Xlsx.parse_cell(x["r"]).last > col }
        if after
          after.add_previous_sibling(c)
        else
          ext = r.at_xpath("m:extLst", NS)
          ext ? ext.add_previous_sibling(c) : r.add_child(c)
        end
        # `spans` is an optional hint about which columns a row uses; a cell outside it is legal
        # but the hint is then wrong, so a row that grows past it drops it rather than lie.
        if (spans = r["spans"]) && spans.split(/\s+/).none? { |s| a, b = s.split(":").map(&:to_i); col.between?(a, b) }
          r.remove_attribute("spans")
        end
        c
      end

      def create_row(sheet, row)
        data = sheet_data(sheet)
        r = element(data.document, "row")
        r["r"] = row.to_s
        after = data.xpath("m:row", NS).find { |x| x["r"].to_i > row }
        after ? after.add_previous_sibling(r) : data.add_child(r)
        r
      end

      def grow_dimension(sheet, row, col)
        dim = doc_for(sheet).at_xpath("//m:dimension", NS) or return
        top, left, bottom, right = Xlsx.parse_area(dim["ref"]) || [ row, col, row, col ]
        dim["ref"] = Xlsx.area_name([ top, row ].min, [ left, col ].min, [ bottom, row ].max, [ right, col ].max)
      end

      # A new element in the document's spreadsheet namespace, under whatever prefix the file uses.
      def element(doc, name)
        node = Nokogiri::XML::Node.new(name, doc)
        node.namespace = doc.root.namespace
        node
      end

      # --- the package ----------------------------------------------------------------------

      def replacements
        out = @dirty.to_a.to_h { |i| sheet = @wb.sheet(i); [ sheet.path, serialize(@docs.fetch(i)) ] }
        out[@wb.workbook_path] = workbook_with_full_calc
        if calc_chain
          out[@wb.rels_path] = without_calc_chain_rel
          out["[Content_Types].xml"] = without_calc_chain_type
        end
        out
      end

      def removals = [ calc_chain ].compact

      def calc_chain
        return @calc_chain if defined?(@calc_chain)

        path = @wb.part_for("calcChain")
        @calc_chain = path && @pkg.key?(path) ? path : nil
      end

      # `fullCalcOnLoad` on the workbook's calcPr, creating one in its schema position if absent
      # (after the last of sheets / functionGroups / externalReferences / definedNames).
      def workbook_with_full_calc
        doc = @wb.workbook_doc
        calc = doc.at_xpath("//m:calcPr", NS)
        unless calc
          calc = element(doc, "calcPr")
          anchor = %w[definedNames externalReferences functionGroups sheets]
                     .lazy.filter_map { |n| doc.at_xpath("/m:workbook/m:#{n}", NS) }.first
          anchor ? anchor.add_next_sibling(calc) : doc.root.add_child(calc)
        end
        calc["fullCalcOnLoad"] = "1"
        serialize(doc)
      end

      def without_calc_chain_rel
        doc = @wb.xml(@wb.rels_path)
        doc.xpath("//r:Relationship", "r" => PKG_REL_NS).each { |r| r.remove if r["Type"].to_s.end_with?("/calcChain") }
        serialize(doc)
      end

      def without_calc_chain_type
        doc = @wb.xml("[Content_Types].xml")
        doc.xpath("//t:Override", "t" => CT_NS).each { |o| o.remove if o["PartName"] == "/#{calc_chain}" }
        serialize(doc)
      end

      def serialize(doc) = doc.to_xml(save_with: Nokogiri::XML::Node::SaveOptions::AS_XML)

      # --- input ----------------------------------------------------------------------------

      def normalize(ops)
        list = ops.respond_to?(:to_ary) ? ops.to_ary : nil
        raise Refused, "Nothing to save." if list.blank?
        raise Refused, "Too many changes in one save (at most #{MAX_OPS})." if list.size > MAX_OPS

        list.map { |raw| normalize_op(raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw) }
      end

      def normalize_op(raw)
        raise Refused, "That change could not be read." unless raw.is_a?(Hash)

        op = raw.transform_keys(&:to_s)
        sheet = @wb.sheet(int(op["sheet"], 0, @wb.sheets.size - 1))
        refusal = @wb.edit_refusal(sheet) and raise Refused, refusal

        case op["op"]
        when "set"
          value = op["value"].nil? ? "" : op["value"]
          raise Refused, "That change could not be read." unless value.is_a?(String) || value.is_a?(Numeric)

          value = value.to_s
          raise Refused, "A cell can hold at most #{MAX_VALUE} characters." if value.length > MAX_VALUE

          { op: "set", sheet:, row: int(op["row"], 0, MAX_ROW - 1) + 1, col: int(op["col"], 0, MAX_COL - 1) + 1, value: }
        when "insert_rows", "delete_rows"
          at = int(op["at"], 0, MAX_ROW - 1) + 1
          count = int(op["count"], 1, MAX_ROWS_PER_OP)
          raise Refused, "That change could not be read." if op["op"] == "delete_rows" && at + count - 1 > MAX_ROW

          { op: op["op"], sheet:, at:, count: }
        else
          raise Refused, "That change could not be read."
        end
      end

      def int(value, min, max)
        n = Integer(value, exception: false) if value.is_a?(Integer) || value.is_a?(String)
        raise Refused, "That change could not be read." unless n&.between?(min, max)

        n
      end
    end
  end
end
