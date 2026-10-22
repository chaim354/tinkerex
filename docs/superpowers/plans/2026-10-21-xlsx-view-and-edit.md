# .xlsx: view a workbook, make basic edits, save it back — Implementation Plan

**Goal:** an `.xlsx` file's page shows its workbook as a grid, one tab per worksheet, with the
values Excel last calculated; the maker edits cell values and adds or deletes rows; Save writes the
`.xlsx` back to the SAME library node on all three backends, refusing a stale save, and keeps
everything the maker did not touch.

**Owner's words (2026-10-21):** "should be able to view and do basic edits". No thumbnail, no
import into project Sheets, no Sheet export. CSV/TSV unchanged.

**Architecture:** the workbook is edited AS OOXML, not through a spreadsheet object model.
`Maker::Xlsx::Package` opens the zip under three bounds; `Maker::Xlsx::Workbook` reads workbook.xml,
the shared strings, the styles and each sheet into a bounded JSON payload for the grid (streamed
with `Nokogiri::XML::Reader`, stopping at the row cap); `Maker::Xlsx::Edit` applies a list of cell
and row OPERATIONS to the sheet XML with Nokogiri and writes a new zip in which every part it did
not edit is copied verbatim. The save door is `Files::SpreadsheetsController#update`, which hands
the new bytes to **`Maker::TextSave`** — the existing shared save (stale check on the catalog and
the store, `replace: true` so the node survives, the pending git edit inside a working tree, the
preview re-enqueue). The browser draws the grid with the Jspreadsheet CE bundle already vendored
for project Sheets, loaded on demand by a new `spreadsheet` Stimulus controller.

**Tech stack:** Rails 8, Nokogiri + rubyzip (both already direct dependencies — no new gem),
Stimulus, Jspreadsheet CE 5.0.4 + jsuites 5.13.5 (vendored, MIT).

---

## Decisions made without the owner

1. **Not rubyXL — direct OOXML editing with Nokogiri.** Verified, not assumed: rubyXL 3.4.38
   round-tripped the fixture (`test/support/xlsx_fixture.rb`) with an edit to one cell and DROPPED
   every `x14ac:dyDescent` row attribute and the workbook's `mc:Ignorable`, and re-serialised
   `styles.xml` (not byte-identical) — it rebuilds every part from its object model. Editing the
   XML of the one sheet that changed and copying every other part as it was keeps charts, comments,
   pivot tables, images and anything else this app has never heard of byte-for-byte, with no new
   dependency. Nokogiri's serialisation of an unedited sheet differs from the input by one trailing
   newline (measured). SheetJS CE was not considered for saving (it drops styles on write).
2. **A new role, `spreadsheet`, not `document`.** `document` is in `TEXT_ROLES`, so an `xlsx`
   `document` would have made `Maker::FileAttachment.text?("x.xlsx")` true: the file page would have
   opened the zip in the code viewer and `Maker::Previews::Registry` would have registered TextThumb
   for it (a "thumbnail" of zip bytes). `TEXT_ROLES` means "every file of this role is text", and an
   `.xlsx` is not. The new role files into `docs/` (the folder `document` already uses, like
   `instructions`), is labelled "Spreadsheets", and joins `Maker::ModelIntake::EXCLUDED_ROLES` (a
   parts list in a model folder is not part of the model, like `document`).
3. **The filing half reaches existing users by a top-up migration** (`xlsx → docs` for users who
   already hold filing rules), the shape every widening since S3-1 has used. Consequence the owner
   should know before deploying: the intake sweep re-sorts project files sitting in `other/` whose
   extension now has a rule, so an `.xlsx` in a project's `other/` folder MOVES to `docs/` after the
   deploy (never inside a git working tree; intake never files those). The role half needs nothing:
   `classify_unclassified!` re-reads `other` rows daily.
4. **Edits are OPERATIONS, never a whole-grid upload.** The browser sends
   `[{sheet, op: "set", row, col, value}, {sheet, op: "insert_rows"|"delete_rows", at, count}]`,
   logged from the grid's own events in the order they happened. The server applies them to the
   bytes it reads at save time. A cell the maker did not touch is never rewritten, so a truncated
   sheet (only the first N rows shown) is safe to edit: rows past the window are untouched.
   Jspreadsheet's undo/redo fire NO events (they set `ignoreEvents`), so history is switched off
   per worksheet (`ignoreHistory = true`); there is no undo in the grid, and the page says Save
   writes what you see.
5. **What a typed value becomes** (Excel's own rules, cut down): `=…` a formula (no cached value;
   `fullCalcOnLoad` makes Excel/LibreOffice compute it on open); `'…` forced text; `TRUE`/`FALSE` a
   boolean; a number (thousands commas, a leading currency symbol and a trailing `%` understood) a
   number — unless the cell's format is Text (`@`), then a string; `YYYY-MM-DD[ HH:MM[:SS]]` in a
   date-formatted cell a date serial; anything else an inline string. Empty clears the value and
   keeps the cell's style. The cell's style (`s`) always survives an edit.
6. **Formulas the maker did not overwrite are kept**, including shared formulas: overwriting the
   MASTER of a shared formula first materialises each dependent cell's own formula (translated by
   offset), so the others keep working. A cell inside an array or data-table formula's range is
   read-only (Excel refuses that edit too).
7. **Row insert/delete is offered only where it is provably safe, per sheet.** It moves the cells,
   the merged ranges, the dimension, and every formula in the workbook that points at the sheet
   (Excel's insert/delete semantics: a range grows when a row is inserted inside it, shrinks on
   delete, a reference to a deleted cell becomes `#REF!`). Anything else that addresses rows cannot
   be moved by this editor, so its presence switches row operations OFF for that sheet (cell edits
   still work) with a note saying why: any worksheet element outside a small allowlist
   (conditional formatting, data validation, hyperlinks, autofilter, drawings, comments, tables,
   page breaks, extLst, …), an array formula, a defined name mentioning the sheet, a workbook part
   outside an allowlist (charts, pivot tables, external links, …), or a formula the reference
   shifter cannot parse (structured or external references).
8. **View-only sheets:** a protected sheet (`<sheetProtection sheet="1">`) is shown but not editable
   — saving would bypass the maker's own protection. A chart sheet has no grid and is listed only.
9. **Bounds.** Not opened at all (the viewer says so and offers Download): over 20 MB on the
   catalog's own size, over 2,000 zip entries, over 100 MB declared OR actually inflated (two
   checks, files-preview.md's GerberZip rule: the declared sizes are the pre-check, the capped read
   is the bound), an encrypted (OLE compound) file, Strict OOXML. Shown: the first 1,000 rows × 60
   columns of each sheet, with a "Showing the first N of M rows" note; at most 200 operations and
   32,767 characters a value per save (Excel's own cell limit).
10. **The viewer is the maker's.** The public file page keeps the download fallback (no public data
    route), and the model page's pane shows the grid read-only (`save: false`, as for every viewer).
11. **The no-history note shows on the editable grid** (`shared/_no_history_note`, keyed on
    `versioned?`), and an `.xlsx` is editable OUTSIDE a git working tree on every backend — the
    owner asked for exactly this. Inside a working tree the save records a pending edit for the
    commit box, through `Maker::TextSave`, like any other edit there.
12. **`calcChain.xml` is removed on every save** (with its relationship and content-type override):
    it lists formula cells and goes stale the moment one is overwritten, and Excel reports a stale
    chain as a repaired file. Excel rebuilds it.

---

## File map

| file | what |
|---|---|
| `app/models/maker/file_attachment.rb` | `"xlsx" => "spreadsheet"`, role label "Spreadsheets" |
| `app/services/maker/project_folders.rb` | `"spreadsheet" => "docs"` |
| `app/services/maker/model_intake.rb` | `spreadsheet` in `EXCLUDED_ROLES` |
| `db/migrate/20261021…_seed_spreadsheet_filing_rule.rb` | top-up `xlsx → docs` |
| `app/controllers/concerns/file_preview.rb` | `SPREADSHEET_EXTS` (derived), `:spreadsheet` kind |
| `app/services/maker/xlsx/package.rb` | bounded zip open + verbatim re-write |
| `app/services/maker/xlsx/workbook.rb` | parts, shared strings, styles, policy, payload |
| `app/services/maker/xlsx/cell_format.rb` | display text for a cached value (dates, %, decimals) |
| `app/services/maker/xlsx/formula_refs.rb` | tokenise a formula; shift rows; translate |
| `app/services/maker/xlsx/edit.rb` | apply operations to the package |
| `app/controllers/files/spreadsheets_controller.rb` | GET payload JSON, PATCH save |
| `config/routes.rb` | `resource :spreadsheet` under the file |
| `app/views/files/_viewer.html.erb`, `app/views/files/viewers/_spreadsheet.html.erb` | the branch + partial |
| `app/javascript/controllers/spreadsheet_controller.js` | tabs, grid, op log, Save |
| `app/assets/stylesheets/pages/preview.css` or a new page sheet, `vendor-overrides.css` | tokens only |
| `docs/invariants/files-preview.md`, `git-editing.md` | the rules this earned |
| tests | `test/services/maker/xlsx/*`, `test/integration/web/spreadsheet_*`, `test/system/spreadsheet_test.rb` |

## Tasks

1. **Vocabulary.** Role, label, folder, model-intake exclusion, migration, `preview_kind`. Run the
   vocabulary tests (`file_attachment_test`, `files_helper_test`, `registry_test`,
   `filing_rules`/`project_folders` tests, `model_intake_classify_test`).
2. **`FormulaRefs`** (pure, unit-tested; can run in parallel with 3).
3. **`Package` / `Workbook` / `CellFormat`** with unit tests over the fixture.
4. **`Edit`** with the round-trip test (styled, multi-sheet, formula-bearing fixture: every untouched
   part byte-identical; the edited sheet's other cells, merges, widths, extLst and formulas intact;
   `fullCalcOnLoad`; calcChain gone) and the row-operation tests.
5. **Door** — controller, routes, request tests on all three legs: view JSON, save reuses the node,
   409 on a stale token (catalog arm and store arm), 422 on refused operations, pending git edit
   inside a working tree.
6. **Viewer** — partial, Stimulus controller, CSS (light + dark), hygiene guards, system test.
7. **Docs** — invariants, then bare `bin/ci`, PR, record, merge.
