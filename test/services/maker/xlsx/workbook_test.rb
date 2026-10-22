require "test_helper"
require "support/xlsx_fixture"

# WHAT THE GRID IS HANDED, read from a real (built) workbook: the values Excel last calculated, shown
# the way Excel shows them, and the policy that decides what the page offers.
class Maker::Xlsx::WorkbookTest < ActiveSupport::TestCase
  include XlsxFixture

  def workbook(bytes = xlsx_bytes) = Maker::Xlsx::Workbook.new(Maker::Xlsx::Package.open(bytes))
  def sheet_payload(bytes = xlsx_bytes, name: "Parts") = workbook(bytes).payload[:sheets].find { |s| s[:name] == name }

  test "every worksheet is a tab, in workbook order, with its index" do
    sheets = workbook.payload[:sheets]
    assert_equal [ [ 0, "Parts" ], [ 1, "Notes" ] ], sheets.map { |s| [ s[:index], s[:name] ] }
  end

  test "cells show the values Excel stored, formatted the way Excel shows them" do
    rows = sheet_payload[:rows]
    assert_equal [ "Part", "Qty", "Unit cost", "Total", "Ordered" ], rows[0]
    assert_equal "Bolt M3", rows[1][0], "a shared string"
    assert_equal "10", rows[1][1]
    assert_equal "0.12", rows[1][2]
    assert_equal "1.2", rows[1][3], "a formula shows its cached result, not its text"
    assert_equal "2023-03-15", rows[1][4], "a date-formatted serial is a date"
    assert_equal "Spacer 5mm", rows[3][0], "a rich-text string is its runs joined"
    assert_equal "27.7%", rows[5][3], "a 0.0% format"
    assert_equal "", rows[5][1], "an empty styled cell inside a merge"
  end

  test "formulas are reported by their text, keyed by 0-based row and column" do
    formulas = sheet_payload[:formulas]
    assert_equal "=B2*C2", formulas["1,3"]
    assert_equal "=SUM(B2:B4)", formulas["4,1"]
    assert_nil formulas["1,1"], "a plain value has no formula"
  end

  test "an inline string and a string-valued formula on another sheet" do
    notes = sheet_payload(name: "Notes")
    assert_equal [ "Ordered from", "Hardware store" ], notes[:rows][0]
    assert_equal "Total: 9.70", notes[:rows][1][0]
    assert_equal "=Parts!D5", notes[:formulas]["1,1"]
  end

  test "column widths come from the sheet, in pixels" do
    widths = sheet_payload[:widths]
    assert_equal 5, widths.size
    assert_equal (24.7109375 * 8 + 12).round, widths[0]
    assert_equal (12.7109375 * 8 + 12).round, widths[1]
    assert_equal (8.43 * 8 + 12).round, widths[4], "an unlisted column takes the default width"
  end

  test "a formula with no stored result shows as its own text" do
    rows = %(<row r="1"><c r="A1"><v>2</v></c><c r="B1"><f>A1*3</f></c></row>)
    payload = sheet_payload(xlsx_bytes(parts_sheet: parts_sheet_xml(rows:)))
    assert_equal "=A1*3", payload[:rows][0][1]
  end

  test "a shared formula's dependent cell reports the master's text translated" do
    rows = %(<row r="1"><c r="A1"><v>1</v></c><c r="B1"><f t="shared" ref="B1:B3" si="0">A1*2</f><v>2</v></c></row>) +
           %(<row r="2"><c r="A2"><v>2</v></c><c r="B2"><f t="shared" si="0"/><v>4</v></c></row>) +
           %(<row r="3"><c r="A3"><v>3</v></c><c r="B3"><f t="shared" si="0"/><v>6</v></c></row>)
    payload = sheet_payload(xlsx_bytes(parts_sheet: parts_sheet_xml(rows:)))
    assert_equal [ "2", "4", "6" ], payload[:rows].map { |r| r[1] }
    assert_equal "=A3*2", payload[:formulas]["2,1"]
  end

  test "a gap in the rows is shown as empty rows so grid row N is file row N" do
    rows = %(<row r="1"><c r="A1"><v>1</v></c></row><row r="4"><c r="C4"><v>9</v></c></row>)
    payload = sheet_payload(xlsx_bytes(parts_sheet: parts_sheet_xml(rows:)))
    assert_equal 4, payload[:shown_rows]
    assert_equal [ "", "", "9" ], payload[:rows][3]
    assert_equal [ "", "", "" ], payload[:rows][1]
  end

  test "a long sheet is cut at the row cap and says how long it really is" do
    rows = (1..30).map { |r| %(<row r="#{r}"><c r="A#{r}"><v>#{r}</v></c></row>) }.join
    sheet = parts_sheet_xml(rows:).sub(%(<dimension ref="A1:E6"/>), %(<dimension ref="A1:A30"/>))
    payload = with_const(Maker::Xlsx::Workbook, :ROW_CAP, 10) { sheet_payload(xlsx_bytes(parts_sheet: sheet)) }
    assert_equal 10, payload[:rows].size
    assert payload[:more_rows]
    assert_equal 30, payload[:total_rows]
    assert_equal "10", payload[:rows].last[0]
  end

  test "a cut sheet without a dimension does not invent a total" do
    rows = (1..30).map { |r| %(<row r="#{r}"><c r="A#{r}"><v>#{r}</v></c></row>) }.join
    sheet = parts_sheet_xml(rows:).sub(%(<dimension ref="A1:E6"/>), "")
    payload = with_const(Maker::Xlsx::Workbook, :ROW_CAP, 10) { sheet_payload(xlsx_bytes(parts_sheet: sheet)) }
    assert payload[:more_rows]
    assert_nil payload[:total_rows]
  end

  test "a hidden sheet is a tab marked hidden; a very hidden one is not shown at all" do
    entries = xlsx_entries(xlsx_bytes)
    wb_xml = entries["xl/workbook.xml"].sub(%(name="Notes" sheetId="2"), %(name="Notes" state="hidden" sheetId="2"))
    hidden = workbook(zip_bytes(entries.merge("xl/workbook.xml" => wb_xml))).payload[:sheets]
    assert hidden.find { |s| s[:name] == "Notes" }[:hidden]

    wb_xml = entries["xl/workbook.xml"].sub(%(name="Notes" sheetId="2"), %(name="Notes" state="veryHidden" sheetId="2"))
    very = workbook(zip_bytes(entries.merge("xl/workbook.xml" => wb_xml))).payload[:sheets]
    assert_equal [ "Parts" ], very.map { |s| s[:name] }
  end

  # --- policy ------------------------------------------------------------------------------

  test "an ordinary sheet is editable" do
    assert_nil sheet_payload[:read_only_reason]
  end

  test "a protected sheet is read-only and says why" do
    sheet = parts_sheet_xml(extra_before_margins: "").sub("<sheetData>", %(<sheetData>)).sub(
      "</sheetData>", %(</sheetData><sheetProtection sheet="1" objects="1" scenarios="1"/>)
    )
    payload = sheet_payload(xlsx_bytes(parts_sheet: sheet))
    assert_match(/protected/, payload[:read_only_reason])
  end

  test "rows can move on a plain sheet" do
    assert_nil sheet_payload(xlsx_bytes(parts_sheet: parts_sheet_xml(ext: false)))[:row_ops_reason]
  end

  test "an extension list keeps the rows where they are, and says so" do
    assert_match(/Excel extensions/, sheet_payload[:row_ops_reason])
    assert_nil sheet_payload[:read_only_reason], "cell edits still work"
  end

  test "conditional formatting keeps the rows where they are" do
    cf = %(<conditionalFormatting sqref="B2:B4"><cfRule type="cellIs" dxfId="0" priority="1" operator="greaterThan">) +
         %(<formula>5</formula></cfRule></conditionalFormatting>)
    sheet = parts_sheet_xml(ext: false).sub("</mergeCells>", "</mergeCells>#{cf}")
    assert_match(/conditional formatting/, sheet_payload(xlsx_bytes(parts_sheet: sheet))[:row_ops_reason])
  end

  test "a chart anywhere in the workbook keeps every sheet's rows where they are" do
    bytes = xlsx_bytes(parts_sheet: parts_sheet_xml(ext: false), extra_parts: { "xl/charts/chart1.xml" => "<c/>" })
    assert_match(/charts/, sheet_payload(bytes)[:row_ops_reason])
    assert_match(/charts/, sheet_payload(bytes, name: "Notes")[:row_ops_reason])
  end

  test "a defined name that points at the sheet keeps its rows where they are" do
    names = %(<definedNames><definedName name="Prices">Parts!$C$2:$C$4</definedName></definedNames>)
    bytes = xlsx_bytes(parts_sheet: parts_sheet_xml(ext: false), workbook_extra: names)
    assert_match(/named ranges/, sheet_payload(bytes)[:row_ops_reason])
    assert_nil sheet_payload(bytes, name: "Notes")[:row_ops_reason], "a name about Parts does not freeze Notes"
  end

  test "an array formula locks its cells and keeps the rows where they are" do
    rows = parts_rows_xml.sub(%(<c r="B5"><f>SUM(B2:B4)</f><v>35</v></c>),
                              %(<c r="B5"><f t="array" ref="B5">SUM(B2:B4)</f><v>35</v></c>))
    payload = sheet_payload(xlsx_bytes(parts_sheet: parts_sheet_xml(rows:, ext: false)))
    assert_includes payload[:locked], "4,1"
    assert_match(/array formulas/, payload[:row_ops_reason])
  end

  test "a formula naming a table keeps every sheet's rows where they are" do
    rows = parts_rows_xml.sub("<f>SUM(B2:B4)</f>", "<f>SUM(Table1[Qty])</f>")
    payload = sheet_payload(xlsx_bytes(parts_sheet: parts_sheet_xml(rows:, ext: false)))
    assert_match(/table or another workbook/, payload[:row_ops_reason])
  end

  # --- refusals to open --------------------------------------------------------------------

  test "an encrypted workbook or an old .xls is refused by name" do
    error = assert_raises(Maker::Xlsx::Unreadable) { Maker::Xlsx::Package.open("\xD0\xCF\x11\xE0\xA1\xB1\x1A\xE1rest".b) }
    assert_match(/password-protected or saved in the old \.xls format/, error.message)
  end

  test "bytes that are not a zip are refused" do
    assert_raises(Maker::Xlsx::Unreadable) { Maker::Xlsx::Package.open("hello") }
    assert_raises(Maker::Xlsx::Unreadable) { Maker::Xlsx::Package.open("PK\x03\x04garbage".b) }
  end

  test "a Strict Open XML workbook is refused rather than misread" do
    entries = xlsx_entries(xlsx_bytes)
    strict = entries["xl/workbook.xml"].sub(Maker::Xlsx::MAIN_NS, Maker::Xlsx::STRICT_NS)
    error = assert_raises(Maker::Xlsx::Unreadable) { workbook(zip_bytes(entries.merge("xl/workbook.xml" => strict))) }
    assert_match(/Strict/, error.message)
  end

  test "the declared size is checked before anything is inflated" do
    error = with_const(Maker::Xlsx::Package, :MAX_INFLATED, 1_000) do
      assert_raises(Maker::Xlsx::Unreadable) { Maker::Xlsx::Package.open(xlsx_bytes) }
    end
    assert_match(/too large/, error.message)
  end

  # THE PRE-CHECK REFUSES BEFORE ANYTHING IS INFLATED — the point of having one beside the capped
  # read, which on its own would inflate up to the budget first. Any part read at all is a failure.
  test "an oversized declaration is refused without inflating a single part" do
    entry = Zip::Entry.instance_method(:get_input_stream)
    Zip::Entry.define_method(:get_input_stream) { |*| raise "a part was inflated before the declared sizes were checked" }
    with_const(Maker::Xlsx::Package, :MAX_INFLATED, 1_000) do
      assert_raises(Maker::Xlsx::Unreadable) { Maker::Xlsx::Package.open(xlsx_bytes) }
    end
  ensure
    Zip::Entry.define_method(:get_input_stream, entry)
  end

  # A ZIP CAN LIE ABOUT ITS SIZES, so the capped read is the bound and the declaration only a
  # pre-check (files-preview.md's GerberZip rule). This archive declares 10 bytes per part and
  # inflates each to the whole XML; the declared sum passes, the read must not.
  test "the capped read refuses a zip whose declared sizes understate what it inflates to" do
    lying = understated_sizes(xlsx_bytes)
    error = with_const(Maker::Xlsx::Package, :MAX_INFLATED, 3_000) do
      assert_raises(Maker::Xlsx::Unreadable) { Maker::Xlsx::Package.open(lying) }
    end
    assert_match(/too large|not a readable/, error.message)
  end

  test "too many parts are refused" do
    extra = (1..20).to_h { |i| [ "customXml/item#{i}.xml", "<x/>" ] }
    with_const(Maker::Xlsx::Package, :MAX_ENTRIES, 15) do
      assert_raises(Maker::Xlsx::Unreadable) { Maker::Xlsx::Package.open(xlsx_bytes(extra_parts: extra)) }
    end
  end

  private

  def with_const(mod, name, value)
    old = mod.const_get(name)
    mod.send(:remove_const, name)
    mod.const_set(name, value)
    yield
  ensure
    mod.send(:remove_const, name)
    mod.const_set(name, old)
  end

  # Rewrites every local header's and central-directory entry's uncompressed-size field to 10.
  def understated_sizes(bytes)
    out = bytes.dup.b
    [ [ "PK\x03\x04".b, 22 ], [ "PK\x01\x02".b, 24 ] ].each do |sig, offset|
      i = 0
      while (i = out.index(sig, i))
        out[i + offset, 4] = [ 10 ].pack("V")
        i += 4
      end
    end
    out
  end
end
