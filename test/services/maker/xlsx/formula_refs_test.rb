require "test_helper"

# The subject is what a formula's TEXT becomes when rows move or a shared formula is materialised.
# Every case is a whole formula in and a whole formula out, because the failure that matters is a
# silent one: a reference left pointing at the wrong row, or a name or literal rewritten as though it
# were a cell.
class Maker::Xlsx::FormulaRefsTest < ActiveSupport::TestCase
  Refs = Maker::Xlsx::FormulaRefs

  def insert(formula, at:, count: 1, home: "Parts", target: "Parts")
    Refs.shift_rows(formula, home_sheet: home, target_sheet: target, at:, count:)
  end

  def delete(formula, at:, count: 1, home: "Parts", target: "Parts")
    Refs.shift_rows(formula, home_sheet: home, target_sheet: target, at:, count: -count)
  end

  # --- insert ---------------------------------------------------------------------------------

  test "an insert inside an area grows it" do
    assert_equal "SUM(B2:B5)", insert("SUM(B2:B4)", at: 3)
  end

  test "an insert at an area's top row moves the whole area down" do
    assert_equal "SUM(B3:B5)", insert("SUM(B2:B4)", at: 2)
  end

  test "an insert below an area leaves it alone" do
    assert_equal "SUM(B2:B4)", insert("SUM(B2:B4)", at: 5)
  end

  test "an insert at a cell's own row moves the cell down" do
    assert_equal "B6", insert("B5", at: 5)
    assert_equal "B5", insert("B5", at: 6)
  end

  test "an insert of several rows moves by the count" do
    assert_equal "SUM(B2:B7)*C9", insert("SUM(B2:B4)*C6", at: 3, count: 3)
  end

  test "absolute references shift on an insert too" do
    assert_equal "$A$3", insert("$A$2", at: 1)
    assert_equal "SUM($B$2:$B$5)", insert("SUM($B$2:$B$4)", at: 3)
  end

  test "lowercase references are references and keep their letters' case" do
    assert_equal "a3+B3", insert("a2+B2", at: 1)
  end

  test "a whole-column area never changes on a row insert" do
    assert_equal "SUM(A:A)+SUM($B:$D)", insert("SUM(A:A)+SUM($B:$D)", at: 1, count: 4)
  end

  test "a whole-row area follows the area rule" do
    assert_equal "SUM(2:6)", insert("SUM(2:5)", at: 3)
    assert_equal "SUM($3:$6)", insert("SUM($2:$5)", at: 1)
  end

  test "an area reaching the last row stays at the last row" do
    assert_equal "SUM(A1:A1048576)", insert("SUM(A1:A1048576)", at: 5)
    assert_equal "SUM(A6:A1048576)", insert("SUM(A5:A1048576)", at: 5)
  end

  test "an area written bottom-first moves the right end and keeps its order" do
    assert_equal "SUM(B5:B2)", insert("SUM(B4:B2)", at: 3)
  end

  test "a cell pushed off the bottom of the sheet becomes #REF!" do
    assert_equal "#REF!", insert("A1048576", at: 1)
  end

  # --- delete ---------------------------------------------------------------------------------

  test "a delete inside an area shrinks it" do
    assert_equal "SUM(D2:D3)", delete("SUM(D2:D4)", at: 3)
  end

  test "a delete of a cell's own row makes it #REF!" do
    assert_equal "#REF!", delete("D3", at: 3)
    assert_equal "D2*#REF!*D3", delete("D2*D3*D4", at: 3)
  end

  test "a deleted cell on another sheet keeps its sheet prefix" do
    assert_equal "Parts!#REF!", delete("Parts!D3", at: 3, home: "Notes", target: "Parts")
  end

  test "deleting every row an area covers makes it #REF!" do
    assert_equal "SUM(#REF!)", delete("SUM(D2:D4)", at: 2, count: 3)
  end

  test "a delete above a cell moves it up" do
    assert_equal "D4", delete("D5", at: 3)
    assert_equal "$D$4", delete("$D$5", at: 3)
  end

  test "a delete covering an area's top keeps the surviving rows from the deletion point" do
    assert_equal "SUM(D3:D5)", delete("SUM(D4:D7)", at: 3, count: 2)
    assert_equal "SUM(D2:D2)", delete("SUM(D2:D5)", at: 3, count: 3)
  end

  test "a delete below an area leaves it alone" do
    assert_equal "SUM(D2:D4)", delete("SUM(D2:D4)", at: 5, count: 2)
  end

  # --- which sheet ----------------------------------------------------------------------------

  test "a reference to the target sheet from another sheet shifts" do
    assert_equal "Parts!D6", insert("Parts!D5", at: 2, home: "Notes", target: "Parts")
  end

  test "an unqualified reference on another sheet does not shift" do
    assert_equal "D5", insert("D5", at: 2, home: "Notes", target: "Parts")
  end

  test "a sheet prefix applies to the whole area and not to the next reference" do
    assert_equal "SUM(Parts!B2:B5)+B3", insert("SUM(Parts!B2:B4)+B3", at: 3, home: "Notes", target: "Parts")
  end

  test "sheet names compare case-insensitively" do
    assert_equal "'My Sheet'!A3", insert("'My Sheet'!A2", at: 1, home: "Notes", target: "my sheet")
  end

  test "a quoted sheet name with an escaped quote matches the real name" do
    assert_equal "'It''s'!A3", insert("'It''s'!A2", at: 1, home: "Notes", target: "It's")
  end

  test "a reference to some other sheet does not shift" do
    assert_equal "Bom!A2+'Other Sheet'!A2", insert("Bom!A2+'Other Sheet'!A2", at: 1, target: "Parts")
  end

  test "an existing #REF! keeps its prefix and stays put" do
    assert_equal "Parts!#REF!+A3", insert("Parts!#REF!+A2", at: 1)
  end

  # --- things that are not references ---------------------------------------------------------

  test "string literals are never read as references" do
    assert_equal %("A1"&A2), insert(%("A1"&A1), at: 1)
    assert_equal %("say ""B2"""&B3), insert(%("say ""B2"""&B2), at: 1)
  end

  test "a reference inside a function with a format string shifts and the format does not" do
    assert_equal %("Total: "&TEXT(Parts!D6,"0.00")), insert(%("Total: "&TEXT(Parts!D5,"0.00")), at: 5, home: "Notes")
  end

  test "a function whose name looks like a cell is a function" do
    assert_equal "LOG10(A3)", insert("LOG10(A2)", at: 1)
    assert_equal "ATAN2(A2,B2)", insert("ATAN2(A1,B1)", at: 1)
  end

  test "a defined name with digits in it is a name" do
    assert_equal "Rate1x*2", insert("Rate1x*2", at: 1)
    assert_equal "A1B+_xlfn.XLOOKUP(A3,B2:B6,C2:C6)", insert("A1B+_xlfn.XLOOKUP(A2,B1:B5,C1:C5)", at: 1)
  end

  test "a number's exponent is not a cell" do
    assert_equal "1E5+A2", insert("1E5+A1", at: 1)
    assert_equal "2.5e3*E6", insert("2.5e3*E5", at: 1)
  end

  test "letters glued to the end of something else are not a reference" do
    assert_equal "12A1+A2", insert("12A1+A1", at: 1)
    assert_equal "$$A1+A2", insert("$$A1+A1", at: 1)
  end

  test "booleans and error literals pass through" do
    assert_equal "IF(TRUE,A2,#N/A)+IFERROR(B2,#DIV/0!)", insert("IF(TRUE,A1,#N/A)+IFERROR(B1,#DIV/0!)", at: 1)
  end

  test "the last column is a column and the one after it is a name" do
    assert_equal "XFD2+XFE1", insert("XFD1+XFE1", at: 1)
  end

  test "a formula that references nothing on the target sheet comes back unchanged" do
    formula = %(SUM(Bom!A1:A9)*Rate+"x")
    assert_equal formula, insert(formula, at: 1)
  end

  # --- refused --------------------------------------------------------------------------------

  test "structured references are refused" do
    assert_raises(Refs::Unsupported) { insert("SUM(Table1[Col])", at: 1) }
    assert_raises(Refs::Unsupported) { Refs.translate("Table1[[#Headers],[Col]]", rows: 1, cols: 0) }
  end

  test "external workbook references are refused" do
    assert_raises(Refs::Unsupported) { insert("[1]Sheet1!A1", at: 1) }
    assert_raises(Refs::Unsupported) { insert("'[1]Sheet 1'!A1", at: 1) }
  end

  test "3-D references are refused, quoted or not" do
    assert_raises(Refs::Unsupported) { insert("SUM('S1:S3'!A1)", at: 1) }
    assert_raises(Refs::Unsupported) { insert("SUM(Sheet1:Sheet3!A1)", at: 1) }
  end

  test "an unterminated string is refused rather than guessed at" do
    assert_raises(Refs::Unsupported) { insert(%("abc&A1), at: 1) }
  end

  test "supported? answers false exactly where the rewrites refuse" do
    refute Refs.supported?("SUM(Table1[Col])")
    refute Refs.supported?("[1]Sheet1!A1")
    refute Refs.supported?("SUM('S1:S3'!A1)")
    assert Refs.supported?(%(SUM(Parts!B2:B4)*'My Sheet'!$A$1+"[not a ref]"))
    assert Refs.supported?("LOG10(A1)+1E5")
  end

  # --- translate ------------------------------------------------------------------------------

  test "translate moves relative rows" do
    assert_equal "B3*C3", Refs.translate("B2*C2", rows: 1, cols: 0)
  end

  test "translate leaves absolute parts where they are" do
    assert_equal "$B$2*D3", Refs.translate("$B$2*C2", rows: 1, cols: 1)
    assert_equal "SUM(B$2:B6)", Refs.translate("SUM(B$2:B4)", rows: 2, cols: 0)
    assert_equal "$A3+B$1", Refs.translate("$A1+A$1", rows: 2, cols: 1)
  end

  test "translate past the top of the sheet is #REF!" do
    assert_equal "#REF!", Refs.translate("A1", rows: -1, cols: 0)
    assert_equal "#REF!", Refs.translate("XFD1", rows: 0, cols: 1)
  end

  test "translate keeps the sheet prefix, both when moving and when it falls off" do
    assert_equal "Parts!A2", Refs.translate("Parts!A1", rows: 1, cols: 0)
    assert_equal "'My Sheet'!#REF!", Refs.translate("'My Sheet'!A1", rows: -1, cols: 0)
  end

  test "translate moves whole columns by columns only and whole rows by rows only" do
    assert_equal "SUM(B:B)+SUM(3:3)", Refs.translate("SUM(A:A)+SUM(2:2)", rows: 1, cols: 1)
  end

  test "translate across a column boundary writes the new letters" do
    assert_equal "AA1+$Z1", Refs.translate("Z1+$Z1", rows: 0, cols: 1)
  end

  test "translate does not touch strings, names or numbers" do
    assert_equal %(LOG10(A2)&"A1"&1E5), Refs.translate(%(LOG10(A1)&"A1"&1E5), rows: 1, cols: 0)
  end
end
