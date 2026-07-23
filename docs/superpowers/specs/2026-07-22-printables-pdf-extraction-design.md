# Printables PDF Metadata Extraction — Design

**Date:** 2026-07-22
**Status:** Approved (brainstorm), ready for implementation plan
**Builds on:** the model library (PR #77) + follow-up (PR #78).

---

## 1. Use case

A Printables model bundle's **instructions PDF** contains rich, structured metadata — designer,
license, description, tags, source, and print settings. Today the user re-types the designer /
license / etc. by hand. This feature **parses that PDF on import and auto-fills the model's empty
fields**, so the data that's already in the PDF just appears.

Grounded in a real example (the "Honeycomb storage wall" PDF, `152592-…​.pdf`), whose text yields:
designer `RostaP`; license `Creative Commons — Attribution-NonCommercial 4.0`; a summary; tags
`organizer wall hooks storrage`; and a print-stat row `3.88 hrs · 0.28 mm layer · 0.40 mm nozzle ·
PET · 58 g · Prusa MINI`.

## 2. Settled decisions (from brainstorm)

- **Print settings live in ONE JSON column** (`print_settings`) on `Maker::Model`, rendered as a
  key/value panel — not rigid columns, not just notes.
- **Auto on import, fill blanks only** — a background job parses the PDF and fills fields that are
  currently EMPTY. It **never overwrites** anything the user typed. No review step.
- **pdfium for text** — the bundled `pdfium` CLI (klippa, MIT/BSD, already shipped for thumbnails)
  has a `text` subcommand. **No poppler/pdftotext (GPL, §9), no new gem.**
- **Printables-format parser** — tuned to Printables' PDF layout; a non-Printables PDF just yields
  little, gracefully.

## 3. Data model

Add `print_settings` to `maker_models`:

```ruby
t.json :print_settings   # Hash, e.g. { "layer_height" => "0.28 mm", "material" => "PET",
                         #   "nozzle" => "0.40 mm", "filament" => "58 g", "print_time" => "3.88 hrs",
                         #   "printer" => "Prusa MINI / MINI+", "category" => "Household › …" }
```

`t.json` works on both SQLite (self-host) and Postgres (managed) — AR returns a Hash. Default `{}`
is avoided (nil = "not parsed yet"; an empty Hash = "parsed, nothing found"). Existing fields
(`designer`, `license`, `source_url`, `notes`, `tags`) are the other fill targets — no new columns.

The detail page gains a **"Print settings" panel** (sidebar) that renders `print_settings` as
key/value rows, shown only when present.

## 4. Extraction — `Maker::PrintablesPdf` (pure text → hash)

A **pure function** for testability: `Maker::PrintablesPdf.extract(text:, filename:) -> Hash`,
returning only the keys it found:

```ruby
{ designer:, license:, source_url:, description:, tags: [...], print_settings: {...} }
```

Parsing rules (each field INDEPENDENT and best-effort — a miss omits the key, never raises):
- **designer** — the author line directly under the title block.
- **license** — the text after the `License` heading, normalized (e.g. "Creative Commons …
  Attribution-NonCommercial" → `CC BY-NC 4.0`) via a small lookup; unknown → the raw phrase.
- **tags** — the `Tags:` line, whitespace-split.
- **description** — the `Summary` section body (up to the stat row / next heading).
- **print_settings** — the stat row parsed positionally (`<n> hrs`, `<n> pcs`, `<n> mm` ×2 =
  layer+nozzle, a material word, `<n> g`, then the printer), plus the `category` line (`A › B`).
- **source_url** — from the **filename's leading model id** (`152592-…​.pdf` →
  `https://www.printables.com/model/152592`). The filename is Printables' reliable naming; a
  `printables.com/model/N` in the body is often a *linked* model, so the filename wins. Best-effort.
- **title** — parsed but **NOT applied** (the import already set a title from the zip; §2 "fill
  blanks" leaves it). Kept in the return hash for possible future use / tests.

Title is deliberately not auto-applied to avoid churn; everything else fills only-if-blank.

## 5. Text extraction — `Maker::PdfText`

A thin helper wrapping the bundled pdfium (mirrors `Maker::Previews::Pdf`'s `available?`/`BIN`):

```ruby
Maker::PdfText.available?          # pdfium present?
Maker::PdfText.extract(path) -> String | nil   # `pdfium text <path>`; nil if unavailable/errors
```

Runs `pdfium text` on a local temp path, returns the text. No poppler. If pdfium is missing the
whole feature degrades to a no-op (same graceful path Stl/Mesh/Pdf previews take).

## 6. Flow — `Maker::ExtractPdfMetadataJob`

- **Trigger:** in `Models::AttachmentsController#create`, when the attached node's derived role is
  `instructions` (a PDF), enqueue `Maker::ExtractPdfMetadataJob.perform_later(model_id:, node_id:)`.
  The importer attaches files one-by-one, so this fires when the PDF lands. Idempotent, so a
  re-enqueue is harmless.
- **Job `perform(model_id:, node_id:)`:**
  1. Load the user's model + node (scoped; bail if gone).
  2. Read the PDF bytes via `FileLayer.current` (the same server-side read the preview jobs do —
     chunk hydrates, share/s3 read the file) into a tempfile. `FetchError` → retry/no-op.
  3. `text = Maker::PdfText.extract(tempfile)`; blank/nil → done (nothing to do).
  4. `data = Maker::PrintablesPdf.extract(text:, filename: node.name)`.
  5. **Fill blanks only:** for each of `designer`/`license`/`source_url`/`notes(description)`, set it
     iff the model's current value is blank. Set `print_settings` iff currently nil. Merge `tags`
     into the model's tag set (union — additive, since tags aren't a single "blank" value).
  6. Save. Re-running later fills any still-blank fields (idempotent).

Reads the bytes for PROCESSING only (like previews); no writes to the library, no sync coupling
(**§10/§15 hold** — this is the maker layer reading + updating its own Model record).

## 7. UI

- **"Print settings" panel** on the detail page (sidebar, above or near the files box): renders
  `print_settings` key/value pairs (humanized keys: "Layer height", "Material", …). Hidden when
  `print_settings` is blank.
- The filled `designer`/`license`/`source_url`/`tags`/`notes` surface in the EXISTING metadata `dl`
  and notes section — no new UI for those.
- No loading spinner needed for v1: the job typically finishes within a second or two of landing on
  the page; a manual refresh shows the filled data. (A live-update via Turbo Stream is a possible
  later polish, not v1.)

## 8. Robustness & degradation

- Printables-format parser; a non-Printables PDF yields sparse/empty data — the job fills what it
  can and leaves the rest. No raise on unexpected layouts (each field guarded).
- pdfium missing → `PdfText.extract` nil → job no-ops.
- Port read fails (unmounted NAS) → `FetchError`, ActiveJob retry (bounded), then give up quietly.
- Fill-blanks-only means the feature can never corrupt user-entered data.

## 9. Testing

- **Parser unit tests** (`Maker::PrintablesPdf`) — feed the **real honeycomb PDF text as a fixture**
  (`test/fixtures/files/printables_honeycomb.txt`), assert every extracted field: designer=`RostaP`,
  license=`CC BY-NC 4.0`, tags include `organizer`/`wall`/`hooks`, `print_settings` has
  `layer_height`/`material=PET`/`printer`/`print_time`, `source_url` from the filename, description
  present. Plus a "garbage / non-Printables text yields an (almost) empty hash, no raise" test.
- **Job test** — model + a PDF node; stub `PdfText.extract` to return the fixture text (so the test
  doesn't need pdfium); run job → fields filled; set `designer` first, re-run → NOT overwritten;
  `print_settings` populated. Runs on the default + `LIBRARY_BACKEND=share` legs.
- **`PdfText`** — gated behind `available?`; a smoke test that `pdfium text` returns text for a
  fixture PDF, skipped when pdfium isn't installed (CI has it — the thumbnail jobs use it).
- Full suite green on chunk / share / s3.

## 10. Out of scope (later, if wanted)

- Live Turbo-Stream update of the page as the job finishes (v1 = refresh).
- A structured-fields migration / filtering by material or printer (the JSON blob is display-only
  for now).
- Non-Printables PDF parsers (Thingiverse/MakerWorld have different or no PDFs).
- Re-parsing / a manual "re-extract" button.
- Applying the PDF title over the zip-derived title.

## 11. Invariants

- **§9** — pdfium (permissive) for text; no poppler/GPL, no new gem.
- **§10** — the job reads via the FileLayer port and updates a maker Model; it never touches sync,
  the changelog, or mounts.
- **§15** — bytes are read server-side only for parsing (exactly as the preview jobs already do);
  no new data-plane path.
