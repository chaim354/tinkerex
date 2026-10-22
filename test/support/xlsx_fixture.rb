# REAL .xlsx PACKAGES, BUILT IN RUBY, for the workbook viewer and its save door (Maker::Xlsx).
#
# BUILT, NOT COMMITTED, for three_mf_fixture.rb's reason: an .xlsx is a ZIP OF XML PARTS THAT
# REFER TO EACH OTHER — a cell's `s` names a cellXfs entry, a `t="s"` value is an index into the
# shared strings, a sheet is reached from workbook.xml through a relationship id — and what the
# editor must not disturb is exactly those cross-references. Written out, every one of them is
# visible beside the cell that depends on it.
#
# SHAPED LIKE WHAT EXCEL WRITES, NOT LIKE THE SMALLEST LEGAL FILE: `mc:Ignorable` with
# `x14ac:dyDescent` on the rows, an `<extLst>` the editor has never heard of, a calcChain, a
# merged range, custom column widths, a rich-text shared string, a date and a percentage format,
# a cross-sheet formula. Each is a thing a re-serialising library is known to drop, and the
# round-trip test asserts each one survives a save.
require "zip"

module XlsxFixture
  MAIN_NS = "http://schemas.openxmlformats.org/spreadsheetml/2006/main".freeze
  REL_NS  = "http://schemas.openxmlformats.org/officeDocument/2006/relationships".freeze
  PKG_REL = "http://schemas.openxmlformats.org/package/2006/relationships".freeze
  DECL = %(<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n).freeze
  WS_OPEN = %(<worksheet xmlns="#{MAIN_NS}" xmlns:r="#{REL_NS}" ) +
            %(xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" mc:Ignorable="x14ac" ) +
            %(xmlns:x14ac="http://schemas.microsoft.com/office/spreadsheetml/2009/9/ac">).freeze

  # THE STANDARD FIXTURE: "Parts" (a small BOM with formulas, styles, a merge and a total row) and
  # "Notes" (one cross-sheet formula pointing back into Parts). `extra_parts` adds zip entries
  # verbatim — how a test plants a chart, a table or a comment part without this module modelling
  # them. `parts_sheet:` / `notes_sheet:` replace a sheet's XML outright; `workbook_extra:` is
  # spliced into workbook.xml before `<calcPr>` (a `<definedNames>` block, say).
  def xlsx_bytes(parts_sheet: parts_sheet_xml, notes_sheet: notes_sheet_xml, extra_parts: {},
                 workbook_extra: "", sheet_names: %w[Parts Notes], content_types_extra: "")
    entries = {
      "[Content_Types].xml" => content_types_xml(content_types_extra),
      "_rels/.rels" => root_rels_xml,
      "docProps/app.xml" => app_xml,
      "docProps/core.xml" => core_xml,
      "xl/workbook.xml" => workbook_xml(sheet_names, workbook_extra),
      "xl/_rels/workbook.xml.rels" => workbook_rels_xml,
      "xl/styles.xml" => styles_xml,
      "xl/sharedStrings.xml" => shared_strings_xml,
      "xl/theme/theme1.xml" => theme_xml,
      "xl/calcChain.xml" => calc_chain_xml,
      "xl/worksheets/sheet1.xml" => parts_sheet,
      "xl/worksheets/sheet2.xml" => notes_sheet
    }.merge(extra_parts)
    zip_bytes(entries)
  end

  def zip_bytes(entries)
    Zip::OutputStream.write_buffer(StringIO.new) { |zos|
      entries.each { |name, body| zos.put_next_entry(name); zos.write(body) }
    }.string
  end

  # name => bytes, for asserting on what a save wrote.
  def xlsx_entries(bytes)
    out = {}
    Zip::File.open_buffer(StringIO.new(bytes)) { |z| z.each { |e| out[e.name] = e.get_input_stream.read } }
    out
  end

  def content_types_xml(extra = "")
    ov = ->(part, type) { %(<Override PartName="#{part}" ContentType="application/vnd.openxmlformats-#{type}"/>) }
    DECL + %(<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">) +
      %(<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>) +
      %(<Default Extension="xml" ContentType="application/xml"/>) +
      ov.("/xl/workbook.xml", "officedocument.spreadsheetml.sheet.main+xml") +
      ov.("/xl/worksheets/sheet1.xml", "officedocument.spreadsheetml.worksheet+xml") +
      ov.("/xl/worksheets/sheet2.xml", "officedocument.spreadsheetml.worksheet+xml") +
      ov.("/xl/theme/theme1.xml", "officedocument.theme+xml") +
      ov.("/xl/styles.xml", "officedocument.spreadsheetml.styles+xml") +
      ov.("/xl/sharedStrings.xml", "officedocument.spreadsheetml.sharedStrings+xml") +
      ov.("/xl/calcChain.xml", "officedocument.spreadsheetml.calcChain+xml") +
      ov.("/docProps/core.xml", "package.core-properties+xml") +
      ov.("/docProps/app.xml", "officedocument.extended-properties+xml") +
      extra + %(</Types>)
  end

  def root_rels_xml
    DECL + %(<Relationships xmlns="#{PKG_REL}">) +
      %(<Relationship Id="rId3" Type="#{REL_NS}/extended-properties" Target="docProps/app.xml"/>) +
      %(<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>) +
      %(<Relationship Id="rId1" Type="#{REL_NS}/officeDocument" Target="xl/workbook.xml"/>) +
      %(</Relationships>)
  end

  def app_xml
    DECL + %(<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties">) +
      %(<Application>Microsoft Excel</Application><DocSecurity>0</DocSecurity></Properties>)
  end

  def core_xml
    DECL + %(<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" ) +
      %(xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:creator>Fixture</dc:creator></cp:coreProperties>)
  end

  def workbook_xml(names, extra)
    sheets = names.each_with_index.map { |n, i|
      %(<sheet name="#{n.encode(xml: :attr)[1..-2]}" sheetId="#{i + 1}" r:id="rId#{i + 1}"/>)
    }.join
    DECL + %(<workbook xmlns="#{MAIN_NS}" xmlns:r="#{REL_NS}" ) +
      %(xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" mc:Ignorable="x15" ) +
      %(xmlns:x15="http://schemas.microsoft.com/office/spreadsheetml/2010/11/main">) +
      %(<fileVersion appName="xl" lastEdited="7" lowestEdited="7" rupBuild="27328"/>) +
      %(<workbookPr defaultThemeVersion="166925"/>) +
      %(<bookViews><workbookView xWindow="0" yWindow="0" windowWidth="28800" windowHeight="12300"/></bookViews>) +
      %(<sheets>#{sheets}</sheets>#{extra}<calcPr calcId="191029"/></workbook>)
  end

  def workbook_rels_xml
    rel = ->(id, type, target) { %(<Relationship Id="#{id}" Type="#{REL_NS}/#{type}" Target="#{target}"/>) }
    DECL + %(<Relationships xmlns="#{PKG_REL}">) +
      rel.("rId6", "calcChain", "calcChain.xml") +
      rel.("rId5", "sharedStrings", "sharedStrings.xml") +
      rel.("rId4", "styles", "styles.xml") +
      rel.("rId3", "theme", "theme/theme1.xml") +
      rel.("rId2", "worksheet", "worksheets/sheet2.xml") +
      rel.("rId1", "worksheet", "worksheets/sheet1.xml") +
      %(</Relationships>)
  end

  # cellXfs: 0 default · 1 bold · 2 yellow fill · 3 date (built-in 14) · 4 "0.0%" (custom 164).
  def styles_xml
    DECL + %(<styleSheet xmlns="#{MAIN_NS}">) +
      %(<numFmts count="1"><numFmt numFmtId="164" formatCode="0.0%"/></numFmts>) +
      %(<fonts count="2"><font><sz val="11"/><name val="Calibri"/><family val="2"/></font>) +
      %(<font><b/><sz val="11"/><name val="Calibri"/><family val="2"/></font></fonts>) +
      %(<fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill>) +
      %(<fill><patternFill patternType="solid"><fgColor rgb="FFFFFF00"/><bgColor indexed="64"/></patternFill></fill></fills>) +
      %(<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>) +
      %(<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>) +
      %(<cellXfs count="5"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>) +
      %(<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>) +
      %(<xf numFmtId="0" fontId="0" fillId="2" borderId="0" xfId="0" applyFill="1"/>) +
      %(<xf numFmtId="14" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>) +
      %(<xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/></cellXfs>) +
      %(<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>) +
      %(</styleSheet>)
  end

  # 0 Part · 1 Qty · 2 Unit cost · 3 Total · 4 Ordered · 5 Bolt M3 · 6 Nut M3 · 7 rich "Spacer 5mm"
  # · 8 Summary · 9 Ordered from.
  def shared_strings_xml
    plain = %w[Part Qty Unit\ cost Total Ordered Bolt\ M3 Nut\ M3].map { |s| "<si><t>#{s}</t></si>" }.join
    rich = %(<si><r><rPr><b/><sz val="11"/></rPr><t>Spacer</t></r><r><t xml:space="preserve"> 5mm</t></r></si>)
    DECL + %(<sst xmlns="#{MAIN_NS}" count="12" uniqueCount="10">#{plain}#{rich}) +
      %(<si><t>Summary</t></si><si><t>Ordered from</t></si></sst>)
  end

  def theme_xml
    DECL + %(<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Office Theme">) +
      %(<a:themeElements><a:clrScheme name="Office"><a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1>) +
      %(<a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1></a:clrScheme></a:themeElements></a:theme>)
  end

  def calc_chain_xml
    DECL + %(<calcChain xmlns="#{MAIN_NS}"><c r="D2" i="1"/><c r="D3"/><c r="D4"/><c r="B5"/><c r="D5"/>) +
      %(<c r="D6"/><c r="B2" i="2"/></calcChain>)
  end

  # Parts!A1:E6. Row 1 bold headers at a custom height; rows 2-4 parts with a formula total each;
  # row 5 the sums; row 6 a merged A6:C6 label and a percentage formula. E2/E3 are dates.
  def parts_sheet_xml(rows: nil, merges: %(<mergeCells count="1"><mergeCell ref="A6:C6"/></mergeCells>),
                      extra_before_margins: "", sheet_pr: "")
    rows ||= parts_rows_xml
    DECL + WS_OPEN + sheet_pr +
      %(<dimension ref="A1:E6"/>) +
      %(<sheetViews><sheetView tabSelected="1" workbookViewId="0"><selection activeCell="B2" sqref="B2"/></sheetView></sheetViews>) +
      %(<sheetFormatPr defaultRowHeight="15" x14ac:dyDescent="0.25"/>) +
      %(<cols><col min="1" max="1" width="24.7109375" customWidth="1"/><col min="2" max="4" width="12.7109375" customWidth="1"/></cols>) +
      %(<sheetData>#{rows}</sheetData>) +
      merges + extra_before_margins +
      %(<pageMargins left="0.7" right="0.7" top="0.75" bottom="0.75" header="0.3" footer="0.3"/>) +
      %(<extLst><ext uri="{TINKEREX-FIXTURE}" xmlns:x14="http://schemas.microsoft.com/office/spreadsheetml/2009/9/main">) +
      %(<x14:fixtureMarker keep="1"/></ext></extLst>) +
      %(</worksheet>)
  end

  def parts_rows_xml
    %(<row r="1" spans="1:5" ht="20.25" customHeight="1" x14ac:dyDescent="0.25">) +
      %(<c r="A1" s="1" t="s"><v>0</v></c><c r="B1" s="1" t="s"><v>1</v></c><c r="C1" s="1" t="s"><v>2</v></c>) +
      %(<c r="D1" s="1" t="s"><v>3</v></c><c r="E1" s="1" t="s"><v>4</v></c></row>) +
      %(<row r="2" spans="1:5" x14ac:dyDescent="0.25"><c r="A2" t="s"><v>5</v></c><c r="B2"><v>10</v></c>) +
      %(<c r="C2"><v>0.12</v></c><c r="D2"><f>B2*C2</f><v>1.2</v></c><c r="E2" s="3"><v>45000</v></c></row>) +
      %(<row r="3" spans="1:5" x14ac:dyDescent="0.25"><c r="A3" t="s"><v>6</v></c><c r="B3"><v>20</v></c>) +
      %(<c r="C3"><v>0.05</v></c><c r="D3"><f>B3*C3</f><v>1</v></c><c r="E3" s="3"><v>45001</v></c></row>) +
      %(<row r="4" spans="1:5" x14ac:dyDescent="0.25"><c r="A4" t="s"><v>7</v></c><c r="B4"><v>5</v></c>) +
      %(<c r="C4" s="2"><v>1.5</v></c><c r="D4"><f>B4*C4</f><v>7.5</v></c></row>) +
      %(<row r="5" spans="1:5" x14ac:dyDescent="0.25"><c r="A5" s="1" t="s"><v>3</v></c>) +
      %(<c r="B5"><f>SUM(B2:B4)</f><v>35</v></c><c r="D5"><f>SUM(D2:D4)</f><v>9.7</v></c></row>) +
      %(<row r="6" spans="1:5" x14ac:dyDescent="0.25"><c r="A6" t="s"><v>8</v></c><c r="B6"/><c r="C6"/>) +
      %(<c r="D6" s="4"><f>D5/B5</f><v>0.27714285714285714</v></c></row>)
  end

  # Notes!A1:B2 — a label, an inline string, and B2 = Parts!D5 (the cross-sheet reference a row
  # insert or delete in Parts has to move).
  def notes_sheet_xml(rows: nil)
    rows ||= %(<row r="1"><c r="A1" t="s"><v>9</v></c><c r="B1" t="inlineStr"><is><t>Hardware store</t></is></c></row>) +
             %(<row r="2"><c r="A2" t="str"><f>"Total: "&amp;TEXT(Parts!D5,"0.00")</f><v>Total: 9.70</v></c>) +
             %(<c r="B2"><f>Parts!D5</f><v>9.7</v></c></row>)
    DECL + WS_OPEN + %(<dimension ref="A1:B2"/>) +
      %(<sheetViews><sheetView workbookViewId="0"/></sheetViews>) +
      %(<sheetFormatPr defaultRowHeight="15" x14ac:dyDescent="0.25"/>) +
      %(<sheetData>#{rows}</sheetData>) +
      %(<pageMargins left="0.7" right="0.7" top="0.75" bottom="0.75" header="0.3" footer="0.3"/></worksheet>)
  end
end
