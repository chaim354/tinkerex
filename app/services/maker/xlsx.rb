module Maker
  # AN .xlsx WORKBOOK, READ FOR THE FILE PAGE'S GRID AND EDITED IN PLACE (2026-10-21; plan
  # docs/superpowers/plans/2026-10-21-xlsx-view-and-edit.md; files-preview.md "The workbook viewer").
  #
  # EDITED AS OOXML, NEVER THROUGH A SPREADSHEET OBJECT MODEL, AND THAT IS THE WHOLE DESIGN. A save
  # rewrites the XML of the sheets an operation touched (plus workbook.xml's calcPr and the calcChain
  # it removes) and copies every other part of the zip as it was. A library that loads a workbook
  # into objects and writes it back out keeps only what its model has a field for: rubyXL 3.4.38,
  # measured against test/support/xlsx_fixture.rb, dropped every `x14ac:dyDescent` row attribute and
  # the workbook's `mc:Ignorable` and rewrote styles.xml after a one-cell edit. Here a chart, a
  # comment, a pivot table or an extension nobody has heard of survives because nothing reads it.
  #
  #   Package    — the zip, opened under three bounds, written back verbatim where untouched.
  #   Workbook   — what the grid shows: sheets, values Excel last calculated, and the policy
  #                (which sheets may be edited, which may gain or lose rows, and why not).
  #   CellFormat — the text a cached number is shown as (dates, percentages, fixed decimals).
  #   FormulaRefs— a formula's references, shifted for a row insert/delete or translated for a
  #                shared formula's dependent cell.
  #   Edit       — a list of operations applied to the bytes.
  module Xlsx
    # THE ONE ERROR A VIEWER SHOWS: the file is not a workbook this app can open (encrypted, the old
    # binary format, Strict OOXML, over a bound, corrupt). Its message is a sentence for the maker.
    class Unreadable < StandardError; end

    # AN EDIT THIS EDITOR WILL NOT MAKE — a protected sheet, a cell inside an array formula, a row
    # operation on a sheet whose other row-addressed structures it cannot move. Raised before a byte
    # is written; its message is a sentence for the maker (the door answers 422).
    class Refused < StandardError; end

    MAIN_NS = "http://schemas.openxmlformats.org/spreadsheetml/2006/main".freeze
    STRICT_NS = "http://purl.oclc.org/ooxml/spreadsheetml/main".freeze
    REL_NS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships".freeze
    PKG_REL_NS = "http://schemas.openxmlformats.org/package/2006/relationships".freeze
    CT_NS = "http://schemas.openxmlformats.org/package/2006/content-types".freeze

    MAX_ROW = 1_048_576
    MAX_COL = 16_384

    # "B12" <-> [12, 2]. Columns and rows are 1-based, as in the file.
    def self.col_letters(col)
      s = +""
      while col.positive?
        col, rem = (col - 1).divmod(26)
        s.prepend((65 + rem).chr)
      end
      s
    end

    def self.col_index(letters)
      letters.upcase.each_char.reduce(0) { |n, ch| (n * 26) + (ch.ord - 64) }
    end

    def self.cell_name(row, col) = "#{col_letters(col)}#{row}"

    # nil for anything that is not a plain A1 cell name (a range, a whole column, junk).
    def self.parse_cell(ref)
      m = /\A\$?([A-Za-z]{1,3})\$?(\d+)\z/.match(ref.to_s) or return nil
      row = m[2].to_i
      col = col_index(m[1])
      return nil unless row.between?(1, MAX_ROW) && col.between?(1, MAX_COL)

      [ row, col ]
    end

    # "A6:C6" -> [6, 1, 6, 3] (top, left, bottom, right); a single cell is a one-cell area.
    def self.parse_area(ref)
      a, b = ref.to_s.split(":", 2)
      first = parse_cell(a) or return nil
      last = b ? parse_cell(b) : first
      return nil unless last

      [ [ first[0], last[0] ].min, [ first[1], last[1] ].min, [ first[0], last[0] ].max, [ first[1], last[1] ].max ]
    end

    def self.area_name(top, left, bottom, right)
      first = cell_name(top, left)
      [ top, left ] == [ bottom, right ] ? first : "#{first}:#{cell_name(bottom, right)}"
    end
  end
end
