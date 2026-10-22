require "cgi"
require "nokogiri"

module Maker
  module Xlsx
    # WHAT THE GRID SHOWS, AND WHAT A SAVE IS ALLOWED TO DO — read from a Package, never written.
    #
    # THE VALUES ARE THE ONES EXCEL LAST CALCULATED. A formula cell's `<v>` is the result Excel (or
    # LibreOffice) stored when it last saved the file, and that is what the grid shows; nothing here
    # evaluates a formula, which is why a save asks the next Excel to recalculate on open
    # (Edit's `fullCalcOnLoad`) instead of writing a result. A formula with no stored result — one
    # this editor wrote — shows as its own text.
    #
    # BOUNDED BY ROWS, COLUMNS AND A WHOLE-WORKBOOK CELL BUDGET. A sheet is streamed with
    # Nokogiri::XML::Reader and the read stops at the row cap, so a 200,000-row log costs the first
    # thousand rows, not a DOM of the lot; the payload says how many rows the file has so the page
    # can say "showing the first 1,000". The budget keeps ten big sheets from becoming one huge page.
    #
    # THE POLICY IS DERIVED HERE AND ENFORCED BY Edit, and the grid only reflects it. A sheet is
    # editable unless it is protected or is not a worksheet; it may gain or lose rows only where every
    # row-addressed thing in it is something Edit knows how to move (#row_ops_refusal says which).
    class Workbook
      ROW_CAP = 1_000
      COL_CAP = 60
      CELL_BUDGET = 150_000

      Sheet = Data.define(:index, :name, :path, :kind, :state)

      SHEET_KINDS = {
        "worksheet" => :worksheet, "chartsheet" => :chartsheet,
        "dialogsheet" => :dialogsheet, "xlMacrosheet" => :macrosheet
      }.freeze

      # EVERY PART A ROW OPERATION CAN LEAVE ALONE. A chart, a pivot table, a table, a drawing or a
      # comment addresses cells by row, and Edit moves only cells, merges, the dimension and
      # formulas — so a workbook holding any other part keeps its rows where they are (cell edits
      # still work: they move nothing). An ALLOWLIST rather than a list of the dangerous parts,
      # because the part a list forgot is the one that ends up pointing at the wrong row.
      ROW_SAFE_PARTS = [
        %r{\A\[Content_Types\]\.xml\z}, %r{\A_rels/\.rels\z}, %r{\AdocProps/[^/]+\z}, %r{\AcustomXml/},
        %r{\Axl/workbook\.xml\z}, %r{\Axl/_rels/workbook\.xml\.rels\z}, %r{\Axl/styles\.xml\z},
        %r{\Axl/sharedStrings\.xml\z}, %r{\Axl/theme/[^/]+\z}, %r{\Axl/calcChain\.xml\z},
        %r{\Axl/worksheets/[^/]+\.xml\z}, %r{\Axl/worksheets/_rels/[^/]+\.rels\z},
        %r{\Axl/printerSettings/[^/]+\z}, %r{\Axl/metadata\.xml\z}, %r{\Axl/persons/[^/]+\z}
      ].freeze

      PART_LABELS = {
        %r{\Axl/charts/} => "charts", %r{\Axl/chartsheets/} => "chart sheets",
        %r{\Axl/drawings/} => "drawings or images", %r{\Axl/comments} => "comments",
        %r{\Axl/threadedComments/} => "comments", %r{\Axl/tables/} => "tables",
        %r{\Axl/pivot} => "pivot tables", %r{\Axl/externalLinks/} => "links to other workbooks",
        %r{\Axl/queryTables/} => "query tables", %r{\Axl/slicer} => "slicers",
        %r{\Axl/timeline} => "timelines", %r{\Axl/connections\.xml\z} => "data connections",
        %r{\Axl/vbaProject\.bin\z} => "macros"
      }.freeze

      # EVERY ELEMENT A ROW OPERATION CAN LEAVE ALONE OR MOVE, anywhere in a worksheet's XML: the
      # worksheet's own structure, the cell grammar inside sheetData, merges, page set-up. The same
      # allowlist argument as the parts: conditional formatting, data validation, hyperlinks, a
      # filter, page breaks, an extension list all hold row numbers Edit does not rewrite.
      ROW_SAFE_ELEMENTS = %w[
        worksheet sheetPr tabColor outlinePr pageSetUpPr dimension sheetViews sheetView pane
        selection sheetFormatPr cols col sheetData row c v f is t r rPr rPh phoneticPr b i u strike
        sz color rFont family charset outline shadow condense extend vertAlign scheme sheetCalcPr
        mergeCells mergeCell printOptions pageMargins pageSetup headerFooter oddHeader oddFooter
        evenHeader evenFooter firstHeader firstFooter
      ].to_set.freeze

      ELEMENT_LABELS = {
        "conditionalFormatting" => "conditional formatting", "dataValidations" => "data validation",
        "hyperlinks" => "hyperlinks", "autoFilter" => "a filter", "sortState" => "a sort",
        "drawing" => "drawings or charts", "legacyDrawing" => "comments", "tableParts" => "a table",
        "rowBreaks" => "page breaks", "colBreaks" => "page breaks", "extLst" => "Excel extensions",
        "protectedRanges" => "protected ranges", "scenarios" => "scenarios",
        "ignoredErrors" => "ignored-error markers", "dataConsolidate" => "data consolidation",
        "customSheetViews" => "custom views", "oleObjects" => "embedded objects", "controls" => "form controls",
        "picture" => "a background picture", "cellWatches" => "cell watches", "smartTags" => "smart tags",
        "webPublishItems" => "web publishing items", "sheetProtection" => "sheet protection"
      }.freeze

      attr_reader :package, :sheets, :workbook_path, :workbook_doc, :rels_path, :date1904

      def initialize(package)
        @package = package
        @workbook_path = office_document_path
        @workbook_doc = xml(@workbook_path)
        root = @workbook_doc.root
        if root&.namespace&.href == STRICT_NS
          raise Unreadable, "This workbook is saved as Strict Open XML, which this viewer cannot open. " \
                            "Save it as a standard Excel Workbook to view it here."
        end
        raise Unreadable, "This file is not a readable .xlsx workbook." unless root&.name == "workbook"

        @rels_path = rels_path_for(@workbook_path)
        @rels = relationships(@rels_path)
        @date1904 = %w[1 true].include?(at("workbookPr")&.[]("date1904"))
        @sheets = read_sheets
      end

      def worksheets = sheets.select { |s| s.kind == :worksheet }
      def sheet(index) = sheets.fetch(index) { raise Refused, "That sheet is not in this workbook." }
      def sheet_xml(sheet) = package[sheet.path] || raise(Unreadable, "This workbook is missing a sheet.")

      # The workbook-relative part a relationship of `type` names (sharedStrings, styles, calcChain).
      def part_for(type)
        rel = @rels.find { |r| r[:type].end_with?("/#{type}") }
        rel && resolve(@workbook_path, rel[:target])
      end

      def relationship_for(type) = @rels.find { |r| r[:type].end_with?("/#{type}") }

      # --- values ------------------------------------------------------------------------------

      def shared_strings
        @shared_strings ||= begin
          path = part_for("sharedStrings")
          path && package[path] ? read_shared_strings(package[path]) : []
        end
      end

      # The number-format code of cellXfs entry `index` (nil = General).
      def format_code(index)
        xf = styles[:xfs][index.to_i] or return nil
        CellFormat.code_for(xf, styles[:custom])
      end

      def format_kind(index) = CellFormat.kind(format_code(index))

      # --- the payload ------------------------------------------------------------------------

      def payload
        budget = CELL_BUDGET
        out = sheets.reject { |s| s.state == "veryHidden" }.map do |s|
          entry = { index: s.index, name: s.name, hidden: s.state == "hidden", kind: s.kind.to_s,
                    read_only_reason: edit_refusal(s), row_ops_reason: row_ops_refusal(s) }
          next entry.merge(rows: [], formulas: {}, locked: []) unless s.kind == :worksheet

          row_cap = [ ROW_CAP, budget / COL_CAP ].min
          if row_cap < 1
            next entry.merge(rows: [], formulas: {}, locked: [], skipped: true,
                             read_only_reason: "This workbook is too large to show every sheet at once.")
          end
          grid = SheetReader.new(self, s).read(row_cap:, col_cap: COL_CAP)
          budget -= grid[:rows].size * [ grid[:shown_cols], 1 ].max
          entry.merge(grid)
        end
        { sheets: out }
      end

      # --- policy -----------------------------------------------------------------------------

      # nil when the sheet's cells may be edited, else the sentence the page shows.
      def edit_refusal(sheet)
        return "This is a chart sheet, which this viewer does not draw." if sheet.kind == :chartsheet
        return "This sheet type is shown in Excel only." unless sheet.kind == :worksheet
        return "This sheet is protected in Excel, so it is shown read-only here." if protected?(sheet)

        nil
      end

      # nil when rows may be inserted or deleted on this sheet, else the sentence the page shows.
      def row_ops_refusal(sheet)
        edit_refusal(sheet) || (@row_ops_refusals ||= {})[sheet.index] ||= begin
          label = workbook_row_blocker || sheet_row_blocker(sheet)
          label && "Rows can't be added or deleted on this sheet because the workbook has #{label}, " \
                   "which this editor can't move. Editing cells still works."
        end
      end

      def protected?(sheet)
        sheet_xml(sheet).scan(/<(?:[\w.-]+:)?sheetProtection\b[^>]*>/).any? { |tag| tag.match?(/\bsheet=["'](1|true)["']/) }
      end

      # Every A1 area an array or data-table formula on this sheet covers — cells Excel will not let
      # you edit one at a time, and neither will this.
      def locked_areas(sheet)
        (@locked_areas ||= {})[sheet.index] ||=
          sheet_xml(sheet).scan(/<(?:[\w.-]+:)?f\b([^>]*)>/).filter_map do |(attrs)|
            next unless attrs.match?(/\bt=["'](array|dataTable)["']/)

            ref = attrs[/\bref=["']([^"']+)["']/, 1]
            ref && Xlsx.parse_area(ref)
          end
      end

      # The formula text of every `<f>` in every worksheet, unescaped — what the row-operation check
      # asks FormulaRefs about.
      def formula_texts(sheet)
        sheet_xml(sheet).scan(%r{<(?:[\w.-]+:)?f\b[^>]*>([^<]*)</(?:[\w.-]+:)?f>}).map { |(t)| unescape(t) }
      end

      def defined_names
        @workbook_doc.xpath("//m:definedNames/m:definedName", "m" => MAIN_NS)
      end

      def resolve(base_part, target)
        return target.delete_prefix("/") if target.start_with?("/")

        parts = File.dirname(base_part).split("/").reject { |p| p == "." }
        target.split("/").each { |seg| seg == ".." ? parts.pop : parts << seg }
        parts.join("/")
      end

      def rels_path_for(part) = File.join(File.dirname(part), "_rels", "#{File.basename(part)}.rels").delete_prefix("./")

      def relationships(path)
        doc = package[path] ? xml(path) : nil
        return [] unless doc

        doc.xpath("//r:Relationship", "r" => PKG_REL_NS).map do |r|
          { id: r["Id"], type: r["Type"].to_s, target: r["Target"].to_s, external: r["TargetMode"] == "External" }
        end
      end

      def xml(path)
        Nokogiri::XML(package[path] || raise(Unreadable, "This file is not a readable .xlsx workbook.")) { |c| c.strict.nonet }
      rescue Nokogiri::XML::SyntaxError
        raise Unreadable, "This workbook is damaged and cannot be read here."
      end

      def unescape(text) = CGI.unescapeHTML(text)

      private

      def at(name) = @workbook_doc.at_xpath("//m:#{name}", "m" => MAIN_NS)

      def office_document_path
        rels = relationships("_rels/.rels")
        rel = rels.find { |r| r[:type].end_with?("/officeDocument") }
        raise Unreadable, "This file is not a readable .xlsx workbook." unless rel

        resolve("", rel[:target])
      end

      def read_sheets
        by_id = @rels.index_by { |r| r[:id] }
        @workbook_doc.xpath("//m:sheets/m:sheet", "m" => MAIN_NS).each_with_index.map do |node, i|
          rel = by_id[node.attribute_with_ns("id", REL_NS)&.value]
          kind = rel ? SHEET_KINDS.fetch(rel[:type].split("/").last, :other) : :other
          path = rel && !rel[:external] ? resolve(@workbook_path, rel[:target]) : nil
          kind = :other if path.nil? || !package.key?(path)
          Sheet.new(index: i, name: node["name"].to_s, path:, kind:, state: node["state"].presence || "visible")
        end
      end

      def styles
        @styles ||= begin
          path = part_for("styles")
          doc = path && package[path] ? xml(path) : nil
          if doc
            ns = { "m" => MAIN_NS }
            custom = doc.xpath("//m:numFmts/m:numFmt", ns).to_h { |n| [ n["numFmtId"].to_i, n["formatCode"].to_s ] }
            xfs = doc.xpath("//m:cellXfs/m:xf", ns).map { |x| x["numFmtId"].to_i }
            { custom:, xfs: }
          else
            { custom: {}, xfs: [] }
          end
        end
      end

      # STREAMED, because the shared-string table is the one part that grows with the whole workbook.
      # A rich-text string is its runs joined; a phonetic guide (`rPh`) is not part of the text.
      def read_shared_strings(xml_bytes)
        out = []
        buf = nil
        capture = false
        in_rph = false
        Nokogiri::XML::Reader(xml_bytes).each do |n|
          case n.node_type
          when Nokogiri::XML::Reader::TYPE_ELEMENT
            case n.local_name
            when "si" then buf = +""; out << "" if n.empty_element?
            when "rPh" then in_rph = true unless n.empty_element?
            when "t" then capture = !in_rph && !n.empty_element?
            end
          when Nokogiri::XML::Reader::TYPE_TEXT, Nokogiri::XML::Reader::TYPE_CDATA,
               Nokogiri::XML::Reader::TYPE_SIGNIFICANT_WHITESPACE
            buf << n.value if capture && buf
          when Nokogiri::XML::Reader::TYPE_END_ELEMENT
            case n.local_name
            when "t" then capture = false
            when "rPh" then in_rph = false
            when "si" then out << SheetReader.decode(buf.to_s); buf = nil
            end
          end
        end
        out
      rescue Nokogiri::XML::SyntaxError
        raise Unreadable, "This workbook is damaged and cannot be read here."
      end

      def workbook_row_blocker
        return @workbook_row_blocker if defined?(@workbook_row_blocker)

        @workbook_row_blocker =
          if (part = package.names.find { |n| ROW_SAFE_PARTS.none? { |re| re.match?(n) } })
            PART_LABELS.find { |re, _| re.match?(part) }&.last || "parts this editor does not know"
          elsif worksheets.any? { |s| formula_texts(s).any? { |f| !FormulaRefs.supported?(f) } }
            "a formula that refers to a table or another workbook"
          end
      end

      def sheet_row_blocker(sheet)
        xml = sheet_xml(sheet)
        names = xml.scan(/<(?:[A-Za-z_][\w.-]*:)?([A-Za-z_][\w.-]*)[\s>\/]/).flatten.uniq
        odd = names.find { |n| !ROW_SAFE_ELEMENTS.include?(n) }
        return ELEMENT_LABELS.fetch(odd, "#{odd} entries") if odd
        return "array formulas" if locked_areas(sheet).any?
        return "named ranges on this sheet" if names_mention?(sheet)

        nil
      end

      # A defined name scoped to this sheet, or one whose formula names it. Read generously: a
      # name that only LOOKS like it mentions the sheet (`MyParts!` for a sheet `Parts`) costs the
      # maker the row buttons on that sheet, where missing a real one would leave a name pointing at
      # the wrong rows.
      def names_mention?(sheet)
        quoted = Regexp.escape("'#{sheet.name.gsub("'", "''")}'!")
        bare = Regexp.escape("#{sheet.name}!")
        pattern = /#{quoted}|#{bare}/i
        defined_names.any? { |n| n["localSheetId"].to_s == sheet.index.to_s || n.text.match?(pattern) }
      end
    end
  end
end
