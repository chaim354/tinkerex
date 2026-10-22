require "test_helper"
require "support/xlsx_fixture"

# A SAVE, ASSERTED ON THE BYTES IT WRITES. The fixture is styled, has two sheets, formulas with
# cached results, a merge, custom column widths, a calcChain, an extension list and Excel's
# `x14ac`/`mc:Ignorable` markup — each something a re-serialising library is known to drop — and
# "lossless where untouched" is asserted part by part and cell by cell rather than by re-reading
# values, because a value-level reader cannot see a dropped attribute.
class Maker::Xlsx::EditTest < ActiveSupport::TestCase
  include XlsxFixture

  NS = { "m" => Maker::Xlsx::MAIN_NS }.freeze

  def edit(ops, bytes = xlsx_bytes) = Maker::Xlsx::Edit.apply(bytes, ops)
  def set(row, col, value, sheet: 0) = { "sheet" => sheet, "op" => "set", "row" => row, "col" => col, "value" => value }
  def sheet_doc(bytes, n = 1) = Nokogiri::XML(xlsx_entries(bytes).fetch("xl/worksheets/sheet#{n}.xml"))
  def cell(doc, ref) = doc.at_xpath("//m:c[@r='#{ref}']", NS)
  # The node as the file holds it — `to_xml` alone pretty-prints, which the written file is not.
  def x(node) = node&.to_xml(save_with: Nokogiri::XML::Node::SaveOptions::AS_XML)
  def grid(bytes, name = "Parts")
    Maker::Xlsx::Workbook.new(Maker::Xlsx::Package.open(bytes)).payload[:sheets].find { |s| s[:name] == name }
  end

  # --- lossless where untouched ------------------------------------------------------------

  test "a one-cell edit leaves every part it did not need byte-for-byte as it was" do
    before = xlsx_entries(xlsx_bytes)
    after = xlsx_entries(edit([ set(1, 1, "12") ]))

    untouched = before.keys - %w[xl/worksheets/sheet1.xml xl/workbook.xml xl/_rels/workbook.xml.rels
                                 [Content_Types].xml xl/calcChain.xml]
    assert_equal %w[docProps/app.xml docProps/core.xml xl/sharedStrings.xml xl/styles.xml
                    xl/theme/theme1.xml xl/worksheets/sheet2.xml _rels/.rels].sort, untouched.sort
    untouched.each { |part| assert_equal before[part], after[part], "#{part} changed" }
    assert_equal before.keys - [ "xl/calcChain.xml" ], after.keys, "same parts, same order, calcChain gone"
  end

  test "the edited sheet keeps every other cell, the merge, the widths, the formulas and the markup" do
    before = sheet_doc(xlsx_bytes)
    after = sheet_doc(edit([ set(1, 1, "12") ]))

    before.xpath("//m:c", NS).each do |c|
      next if c["r"] == "B2"

      assert_equal x(c), x(cell(after, c["r"])), "#{c["r"]} changed"
    end
    %w[//m:cols //m:mergeCells //m:sheetViews //m:sheetFormatPr //m:pageMargins //m:extLst].each do |path|
      assert_equal x(before.at_xpath(path, NS)), x(after.at_xpath(path, NS)), "#{path} changed"
    end
    assert_equal before.xpath("//m:row", NS).map { |r| r.attributes.transform_values(&:value) },
                 after.xpath("//m:row", NS).map { |r| r.attributes.transform_values(&:value) },
                 "row attributes (heights, spans, x14ac:dyDescent) changed"
    assert_equal before.root.namespace_definitions.map(&:href), after.root.namespace_definitions.map(&:href)
    assert_equal "x14ac", after.root["mc:Ignorable"]
    assert_equal %(<c r="B2"><v>12</v></c>), x(cell(after, "B2"))
  end

  test "the workbook asks Excel to recalculate on open and keeps the rest of workbook.xml" do
    wb = Nokogiri::XML(xlsx_entries(edit([ set(1, 1, "12") ]))["xl/workbook.xml"])
    calc = wb.at_xpath("//m:calcPr", NS)
    assert_equal "1", calc["fullCalcOnLoad"]
    assert_equal "191029", calc["calcId"]
    assert_equal "x15", wb.root["mc:Ignorable"]
    assert_equal %w[Parts Notes], wb.xpath("//m:sheet", NS).map { |s| s["name"] }
  end

  test "a workbook with no calcPr gets one in its schema position" do
    entries = xlsx_entries(xlsx_bytes)
    names = %(<definedNames><definedName name="Rate">0.2</definedName></definedNames>)
    wb_xml = entries["xl/workbook.xml"].sub(%(<calcPr calcId="191029"/>), "").sub("</sheets>", "</sheets>#{names}")
    wb = Nokogiri::XML(xlsx_entries(edit([ set(1, 1, "12") ], zip_bytes(entries.merge("xl/workbook.xml" => wb_xml))))["xl/workbook.xml"])
    assert_equal %w[fileVersion workbookPr bookViews sheets definedNames calcPr], wb.root.element_children.map(&:name)
    assert_equal "1", wb.at_xpath("//m:calcPr", NS)["fullCalcOnLoad"]
  end

  test "the calcChain goes with its relationship and its content type" do
    entries = xlsx_entries(edit([ set(1, 1, "12") ]))
    assert_nil entries["xl/calcChain.xml"]
    assert_not_includes entries["xl/_rels/workbook.xml.rels"], "calcChain"
    assert_not_includes entries["[Content_Types].xml"], "calcChain"
    assert_includes entries["xl/_rels/workbook.xml.rels"], "sharedStrings.xml", "the other relationships stay"
  end

  # --- what a typed value becomes ----------------------------------------------------------

  test "text keeps the cell's style and needs no shared string" do
    doc = sheet_doc(edit([ set(3, 2, "about 1.5") ]))
    assert_equal %(<c r="C4" s="2" t="inlineStr"><is><t>about 1.5</t></is></c>), x(cell(doc, "C4"))
  end

  test "leading and trailing spaces in text are kept" do
    doc = sheet_doc(edit([ set(1, 0, " Bolt ") ]))
    assert_equal "preserve", cell(doc, "A2").at_xpath(".//m:t", NS)["xml:space"]
    assert_equal " Bolt ", grid(edit([ set(1, 0, " Bolt ") ]))[:rows][1][0]
  end

  test "a formula is written without a result for Excel to calculate" do
    doc = sheet_doc(edit([ set(1, 1, "=C2*100") ]))
    assert_equal %(<c r="B2"><f>C2*100</f></c>), x(cell(doc, "B2"))
  end

  test "an overwritten formula cell becomes a plain value and keeps its style" do
    doc = sheet_doc(edit([ set(5, 3, "0.5") ]))
    assert_equal %(<c r="D6" s="4"><v>0.5</v></c>), x(cell(doc, "D6"))
  end

  test "a percentage typed into a percentage cell is the fraction" do
    doc = sheet_doc(edit([ set(5, 3, "25%") ]))
    assert_equal "0.25", cell(doc, "D6").at_xpath("m:v", NS).text
  end

  test "a date typed into a date cell is a date serial" do
    doc = sheet_doc(edit([ set(1, 4, "2023-03-16") ]))
    assert_equal %(<c r="E2" s="3"><v>45001</v></c>), x(cell(doc, "E2"))
  end

  test "numbers, booleans, forced text and plain text" do
    bytes = edit([ set(1, 1, "1,234.5"), set(2, 1, "007"), set(3, 1, "'007"), set(1, 2, "TRUE"), set(2, 2, "n/a") ])
    doc = sheet_doc(bytes)
    assert_equal %(<c r="B2"><v>1234.5</v></c>), x(cell(doc, "B2"))
    assert_equal %(<c r="B3"><v>7</v></c>), x(cell(doc, "B3"))
    assert_equal %(<c r="B4" t="inlineStr"><is><t>007</t></is></c>), x(cell(doc, "B4"))
    assert_equal %(<c r="C2" t="b"><v>1</v></c>), x(cell(doc, "C2"))
    assert_equal %(<c r="C3" t="inlineStr"><is><t>n/a</t></is></c>), x(cell(doc, "C3"))
  end

  # A Text-formatted cell is where a maker keeps part numbers: Excel stores `007` there as typed.
  test "a number typed into a Text-formatted cell stays text" do
    rows = parts_rows_xml.sub(%(<c r="B3"><v>20</v></c>), %(<c r="B3" s="5"/>))
    doc = sheet_doc(edit([ set(2, 1, "007") ], xlsx_bytes(parts_sheet: parts_sheet_xml(rows:))))
    assert_equal %(<c r="B3" s="5" t="inlineStr"><is><t>007</t></is></c>), x(cell(doc, "B3"))
  end

  test "an equals sign typed into a Text-formatted cell is text, not a formula" do
    rows = parts_rows_xml.sub(%(<c r="B3"><v>20</v></c>), %(<c r="B3" s="5"/>))
    doc = sheet_doc(edit([ set(2, 1, "=B2") ], xlsx_bytes(parts_sheet: parts_sheet_xml(rows:))))
    assert_equal %(<c r="B3" s="5" t="inlineStr"><is><t>=B2</t></is></c>), x(cell(doc, "B3"))
  end

  test "a number too large for a double is kept as the text that was typed" do
    doc = sheet_doc(edit([ set(1, 1, "1e400"), set(2, 1, "1e-400") ]))
    assert_equal %(<c r="B2" t="inlineStr"><is><t>1e400</t></is></c>), x(cell(doc, "B2"))
    assert_equal %(<c r="B3" t="inlineStr"><is><t>1e-400</t></is></c>), x(cell(doc, "B3"))
  end

  test "clearing a cell keeps a styled cell and removes a plain one" do
    doc = sheet_doc(edit([ set(1, 4, ""), set(1, 1, "") ]))
    assert_equal %(<c r="E2" s="3"/>), x(cell(doc, "E2"))
    assert_nil cell(doc, "B2")
  end

  test "a cell in a new row lands in order and grows the dimension" do
    doc = sheet_doc(edit([ set(8, 1, "42") ]))
    assert_equal %w[1 2 3 4 5 6 9], doc.xpath("//m:row", NS).map { |r| r["r"] }
    assert_equal "A1:E9", doc.at_xpath("//m:dimension", NS)["ref"]
  end

  test "a new cell in an existing row lands in column order and drops a span it falls outside" do
    doc = sheet_doc(edit([ set(1, 6, "x") ]))
    assert_equal %w[A2 B2 C2 D2 E2 G2], doc.xpath("//m:row[@r='2']/m:c", NS).map { |c| c["r"] }
    assert_nil doc.at_xpath("//m:row[@r='2']", NS)["spans"]
    assert_equal "1:5", doc.at_xpath("//m:row[@r='3']", NS)["spans"], "an untouched row keeps its span"
  end

  test "an unfinished formula is refused before anything is written" do
    error = assert_raises(Maker::Xlsx::Refused) { edit([ set(1, 1, "=SUM(B2") ]) }
    assert_match(/Parts!B2.*looks unfinished/, error.message)
    assert_raises(Maker::Xlsx::Refused) { edit([ set(1, 1, "=B2+") ]) }
    assert_raises(Maker::Xlsx::Refused) { edit([ set(1, 1, %(="abc)) ]) }
  end

  test "a protected sheet refuses an edit" do
    sheet = parts_sheet_xml.sub("</sheetData>", %(</sheetData><sheetProtection sheet="1"/>))
    error = assert_raises(Maker::Xlsx::Refused) { edit([ set(1, 1, "1") ], xlsx_bytes(parts_sheet: sheet)) }
    assert_match(/protected/, error.message)
  end

  test "a cell inside an array formula refuses an edit" do
    rows = parts_rows_xml.sub(%(<c r="B5"><f>SUM(B2:B4)</f><v>35</v></c>), %(<c r="B5"><f t="array" ref="B5">SUM(B2:B4)</f><v>35</v></c>))
    error = assert_raises(Maker::Xlsx::Refused) { edit([ set(4, 1, "1") ], xlsx_bytes(parts_sheet: parts_sheet_xml(rows:))) }
    assert_match(/array formula/, error.message)
  end

  test "malformed operations are refused" do
    [ [], nil, [ { "op" => "explode", "sheet" => 0 } ], [ set(1, 1, "x", sheet: 7) ], [ set(-1, 0, "x") ],
      [ { "sheet" => 0, "op" => "set", "row" => "1.5", "col" => 0, "value" => "x" } ],
      [ set(1, 1, "x" * 32_768) ], [ { "sheet" => 0, "op" => "delete_rows", "at" => 1, "count" => 0 } ] ].each do |ops|
      assert_raises(Maker::Xlsx::Refused, ops.inspect[0, 80]) { edit(ops) }
    end
  end

  # --- shared formulas -----------------------------------------------------------------------

  SHARED_ROWS = %(<row r="1"><c r="A1"><v>1</v></c><c r="B1"><f t="shared" ref="B1:B3" si="0">A1*2</f><v>2</v></c></row>) +
                %(<row r="2"><c r="A2"><v>2</v></c><c r="B2"><f t="shared" si="0"/><v>4</v></c></row>) +
                %(<row r="3"><c r="A3"><v>3</v></c><c r="B3"><f t="shared" si="0"/><v>6</v></c></row>)

  test "overwriting a shared formula's master gives every dependent cell its own formula" do
    doc = sheet_doc(edit([ set(0, 1, "100") ], xlsx_bytes(parts_sheet: parts_sheet_xml(rows: SHARED_ROWS))))
    assert_equal %(<c r="B1"><v>100</v></c>), x(cell(doc, "B1"))
    assert_equal %(<c r="B2"><f>A2*2</f><v>4</v></c>), x(cell(doc, "B2"))
    assert_equal %(<c r="B3"><f>A3*2</f><v>6</v></c>), x(cell(doc, "B3"))
  end

  test "overwriting a dependent cell leaves the shared group alone" do
    doc = sheet_doc(edit([ set(1, 1, "100") ], xlsx_bytes(parts_sheet: parts_sheet_xml(rows: SHARED_ROWS))))
    assert_equal "shared", cell(doc, "B1").at_xpath("m:f", NS)["t"]
    assert_equal %(<c r="B3"><f t="shared" si="0"/><v>6</v></c>), x(cell(doc, "B3"))
  end

  # --- rows ----------------------------------------------------------------------------------

  def plain = xlsx_bytes(parts_sheet: parts_sheet_xml(ext: false))
  def insert(at, count = 1, sheet: 0) = { "sheet" => sheet, "op" => "insert_rows", "at" => at, "count" => count }
  def delete(at, count = 1, sheet: 0) = { "sheet" => sheet, "op" => "delete_rows", "at" => at, "count" => count }

  # Grid row 3 is file row 4 (the Spacer). Inserting there pushes it and everything below down one,
  # and every formula that pointed at the moved rows follows them — on this sheet and on Notes.
  test "inserting a row moves the cells below, grows the ranges around it, and follows every reference" do
    bytes = edit([ insert(3) ], plain)
    doc = sheet_doc(bytes)
    assert_equal %w[1 2 3 5 6 7], doc.xpath("//m:row", NS).map { |r| r["r"] }
    assert_equal %(<c r="D5"><f>B5*C5</f><v>7.5</v></c>), x(cell(doc, "D5"))
    assert_equal "SUM(B2:B5)", cell(doc, "B6").at_xpath("m:f", NS).text, "the total grows to take the new row"
    assert_equal "D6/B6", cell(doc, "D7").at_xpath("m:f", NS).text
    assert_equal "A7:C7", doc.at_xpath("//m:mergeCell", NS)["ref"]
    assert_equal "A1:E7", doc.at_xpath("//m:dimension", NS)["ref"]
    notes = sheet_doc(bytes, 2)
    assert_equal "Parts!D6", cell(notes, "B2").at_xpath("m:f", NS).text
    assert_equal %("Total: "&TEXT(Parts!D6,"0.00")), cell(notes, "A2").at_xpath("m:f", NS).text
  end

  test "deleting a row moves the cells below up and shrinks the ranges it crossed" do
    bytes = edit([ delete(2) ], plain) # file row 3, the Nut
    doc = sheet_doc(bytes)
    assert_equal %w[1 2 3 4 5], doc.xpath("//m:row", NS).map { |r| r["r"] }
    assert_equal "Spacer 5mm", grid(bytes)[:rows][2][0]
    assert_equal "SUM(B2:B3)", cell(doc, "B4").at_xpath("m:f", NS).text
    assert_equal "A5:C5", doc.at_xpath("//m:mergeCell", NS)["ref"]
    assert_equal "A1:E5", doc.at_xpath("//m:dimension", NS)["ref"]
    assert_equal "Parts!D4", cell(sheet_doc(bytes, 2), "B2").at_xpath("m:f", NS).text
  end

  test "deleting a row another sheet points at makes that reference #REF!" do
    bytes = edit([ delete(4) ], plain) # file row 5, the totals
    assert_equal "Parts!#REF!", cell(sheet_doc(bytes, 2), "B2").at_xpath("m:f", NS).text
    assert_equal "#REF!/#REF!", cell(sheet_doc(bytes), "D5").at_xpath("m:f", NS).text
  end

  test "deleting every row of a merge removes the merge" do
    doc = sheet_doc(edit([ delete(5) ], plain))
    assert_nil doc.at_xpath("//m:mergeCells", NS)
  end

  test "operations apply in the order they were made" do
    bytes = edit([ insert(1), set(1, 0, "Washer"), set(2, 1, "11") ], plain)
    rows = grid(bytes)[:rows]
    assert_equal [ "Part", "Washer", "Bolt M3" ], rows[0..2].map(&:first)
    assert_equal "11", rows[2][1]
  end

  test "a row operation unshares shared formulas first, then moves them" do
    rows = %(<row r="1"><c r="A1"><v>1</v></c><c r="B1"><f t="shared" ref="B1:B3" si="0">A1*2</f><v>2</v></c></row>) +
           %(<row r="2"><c r="A2"><v>2</v></c><c r="B2"><f t="shared" si="0"/><v>4</v></c></row>) +
           %(<row r="3"><c r="A3"><v>3</v></c><c r="B3"><f t="shared" si="0"/><v>6</v></c></row>)
    doc = sheet_doc(edit([ insert(1) ], xlsx_bytes(parts_sheet: parts_sheet_xml(rows:, ext: false, merges: ""))))
    assert_equal %w[A1*2 A3*2 A4*2], doc.xpath("//m:c/m:f", NS).map(&:text)
    assert_empty doc.xpath("//m:f[@t]", NS)
  end

  test "a row operation the sheet cannot take is refused with the reason" do
    error = assert_raises(Maker::Xlsx::Refused) { edit([ insert(1) ]) } # the fixture's extLst
    assert_match(/Excel extensions/, error.message)
  end

  test "an insert that would push a row off the bottom of the sheet is refused" do
    rows = parts_rows_xml + %(<row r="1048576"><c r="A1048576"><v>1</v></c></row>)
    assert_raises(Maker::Xlsx::Refused) { edit([ insert(2) ], xlsx_bytes(parts_sheet: parts_sheet_xml(rows:, ext: false))) }
  end

  test "a written workbook reads back" do
    bytes = edit([ set(1, 1, "12"), insert(3), set(3, 0, "Washer") ], plain)
    rows = grid(bytes)[:rows]
    assert_equal "12", rows[1][1]
    assert_equal "Washer", rows[3][0]
    assert_equal "Spacer 5mm", rows[4][0]
  end
end
