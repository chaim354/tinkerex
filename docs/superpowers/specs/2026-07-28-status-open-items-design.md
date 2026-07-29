# Design: closing the four open items from the project-page overhaul

**Date:** 2026-07-28
**Branch:** `claude/status-md-open-issues-92c847`
**Closes:** the four items recorded at the head of `docs/STATUS.md` (2026-07-28), which the
project-page overhaul (PR #91) deliberately left open.

| # | Item | Shape |
|---|---|---|
| 1 | `attachments="false"` is a UI restriction, not enforcement | A security-posture **decision**, now made: option (c) |
| 2 | Sheet `data` has no size limit anywhere | A defect with an obvious fix, plus a non-obvious controller half |
| 3 | Nothing in the suite executes JavaScript | A test-infrastructure gap; the harness already exists |
| 4 | The two file-type vocabularies disagree | A vocabulary **decision**, now made: one vocabulary |

---

## 1. Why

Each of the four was found by *running* something rather than reading it, and each was recorded
with its evidence precisely so it would not have to be rediscovered. Two are decisions that were
deferred to a human; both have now been made (§2). Two are defects whose fixes are small but whose
*failure modes* are not — in both cases the naive fix trades one silent failure for another.

Nothing here touches sync, the changelog, conflicts, locks, or the mounts. The file-layer split
design's §10 tripwire (`docs/superpowers/specs/2026-07-14-maker-file-layer-split-design.md`, cited
from CLAUDE.md §12 step 10) does not fire: items 1–3 are app-layer (Action Text, a maker model, a
browser test) and item 4 is a display vocabulary plus one enum value. The file layer port is not
involved in any of the four.

## 2. Decisions (settled — do not relitigate without new information)

1. **Item 1 takes option (c) — strip server-side AND gate the route.** Chosen by the user over (a),
   (b), and (d). It is the only combination that makes the overhaul's decision #2 rationale
   (§15, bytes out of Rails) actually true rather than merely intended.
2. **The direct-uploads route is REMOVED, not authenticated.** `direct_upload` / `DirectUpload`
   appears nowhere in `app/`, `config/`, or `lib/` — verified by grep — and attachments are off in
   both editors, so nothing in this app calls it. A dead route is honest; re-enabling it later
   should be a deliberate act, not an accident of it having been left half-open.
3. **Item 4 takes ONE vocabulary, with `role` extended by a new `document` value.** Chosen by the
   user. The argued alternative — keeping two vocabularies, on the grounds that `role` is a
   persisted classification driving behaviour while `EXT_FAMILIES` is a display grouping — was
   raised and set aside. **The known cost is accepted and recorded here rather than discovered
   later:** `document` is an API-visible enum value whose only consumer is display, and it needs a
   second data migration (§6.3). This paragraph exists so a future reader does not "discover" that
   cost and read it as an oversight.
4. **`pdf` stays `instructions`.** `Models::AttachmentsController` dispatches
   `ExtractPdfMetadataJob` on `att.role == "instructions"`. Folding pdf into `document` would
   silently stop the PDF metadata extraction.
5. **Bytesize, not row/column caps, bounds a sheet.** One number, and it is the quantity that
   actually hurts. Row/column caps reject legitimately-shaped sheets while still permitting a huge
   one.

## 3. Item 1 — enforce text-only rich text

### 3.1 What is actually broken

The client half is solid and stays as-is. Two server-side holes, both demonstrated by the overhaul's
own review rather than reasoned:

1. `POST /rails/active_storage/direct_uploads` is **live and unauthenticated**.
   `ActiveStorage::DirectUploadsController` descends from `ActiveStorage::BaseController`, not this
   app's `ApplicationController`, and adds no authentication. An anonymous write surface into
   storage through Rails — the shape §15 exists to prevent.
2. Neither `NotesController#create` (assigns `params.dig(:note, :body)` directly) nor
   `Projects::BuildLogEntriesController#create` (`permit(:body, …)`) filters attachment markup, and
   Action Text's sanitizer **preserves** `<action-text-attachment sgid="…">`.

### 3.2 Strip server-side

A concern — `app/models/concerns/maker/text_only_rich_text.rb` — included by `Maker::Note` and
`Maker::BuildLogEntry`. On `before_validation` it rewrites `body` with every attachment element
removed.

**A concern rather than two copies**, because this codebase's own recorded lesson (CLAUDE.md §12
step 9, the five-copies count) is that a verb more than one caller performs gets a name. There are
two `has_rich_text` models today and any third inherits the guarantee by including one module.

**`app/models/concerns/` does not exist yet** and will be created. It is already in Rails' default
eager-load paths; no configuration change.

**The tag name is verified, not assumed.** The implementation reads the actual serialized form off a
saved record rather than hard-coding a guess: the acceptance condition is
`body.attachments.empty?` *and* no attachment element in the stored HTML, which holds regardless of
which element name Action Text and Lexxy settle on.

**A deliberate consequence to state up front:** `Maker::Note` and `Maker::BuildLogEntry` both
`validates :body, presence: true`. Stripping on `before_validation` means a body consisting of
*nothing but* an attachment becomes blank and **fails validation**. That is correct — the user
submitted only a thing this app does not accept, so they submitted nothing — but it is a behaviour
change reachable only by a hand-crafted request, and it must be tested rather than found.

### 3.3 Gate the route

**Constraint, established rather than assumed:** `Maker::Preview` uses `has_one_attached :asset` and
`Previews` serves it with `url_for(p.asset)`. Active Storage's blob routes are therefore
load-bearing, and `config.active_storage.draw_routes = false` is **out** — it would take the preview
pipeline down with it. The gate must be surgical: one path, everything else intact.

Three mechanisms, and the choice is settled by a **probe at implementation time, not by argument**:

| | Mechanism | Trade-off |
|---|---|---|
| **(i)** | Intercept the path in `config/routes.rb` | Most greppable; no framework patch. **Depends on app routes out-prioritising engine-appended ones — this is exactly the kind of claim this repo requires be run rather than reasoned.** |
| (ii) | `to_prepare` initializer adding a `before_action` to `ActiveStorage::DirectUploadsController` | Certain to work; patches a framework class |
| (iii) | Rack middleware matching the path | Works; buries the rule where nobody looks for it |

**Preference order (i) → (ii).** (iii) only if both fail. Whichever lands, the *test* is the same
and is what actually pins the behaviour, so a fallback does not weaken the outcome.

### 3.4 Tests

- **Model, both models:** assign a hand-built attachment fragment (the same shape the overhaul's
  review demonstrated), save, reload → `body.attachments` empty, no attachment element in the
  stored HTML.
- **Model, both models:** an attachment-only body fails `presence` validation (§3.2's stated
  consequence — pinned, not left to be discovered).
- **Model, both models:** ordinary formatted text (bold, links, lists) survives untouched. Without
  this the strip could be over-broad and the suite would not notice.
- **Integration:** `POST /rails/active_storage/direct_uploads` **signed out** → not 2xx, and
  `ActiveStorage::Blob.count` unchanged.
- **Integration:** the same POST **signed in** → also not 2xx. This is what pins *removed* rather
  than *auth-gated*; without it, a future change to (ii)-with-authentication would pass.
- **Integration:** a project page and a file page still render, and previews still resolve their
  asset URLs. The gate must not have taken the blob routes with it.

## 4. Item 2 — bound sheet `data`

### 4.1 The limit

`Maker::Sheet` validates `data.to_json.bytesize` ≤ **1 MB**.

The arithmetic, recorded so the number is not mistaken for a guess:

- `blank_data` (20 × 6) ≈ **600 bytes**.
- A large but genuinely plausible sheet — 1000 rows × 20 columns, cells averaging 8 characters —
  ≈ **220 KB**.
- 1 MB is therefore ~4.5× the largest sheet a single-user maker workflow plausibly produces, while
  still bounding the page: `projects/sheets/show.html.erb` embeds the whole blob into the HTML on
  **every view**, with no truncation, so the blob size *is* the page size.

### 4.2 The controller half — the part that is not obvious

`SheetsController#update` calls `update!`. Adding the validation without touching the controller
turns an over-limit autosave into `ActiveRecord::RecordInvalid` → **500**, which the grid's debounced
JSON autosave surfaces as nothing at all.

That would trade *silent unbounded growth* for *a silent failed save* — no better, and arguably
worse, since the user keeps typing into a grid that has stopped persisting. So `#update` gains a
rescue rendering **422 with a JSON error message**, and `sheet_controller.js` shows it through the
status indicator's existing error state (the indicator was built with an error state, not just
Saving/Saved — see the overhaul design's risk table).

### 4.3 Tests

- Model: at the limit passes; over the limit fails with a useful message; `blank_data` passes
  comfortably.
- Controller: an over-limit JSON autosave returns **422** *and* leaves the stored blob unchanged.
  The second half matters — a partial write would be worse than a rejection.
- Controller: an ordinary autosave still returns 200 and persists (guards against the rescue
  swallowing the happy path).

## 5. Item 3 — the first JS-executing test

### 5.1 Why the grid, and why a browser

STATUS.md item 3 names the test and the reason: 1587 green tests across three backends caught
neither grid bug, because both were client-side only and therefore *structurally invisible* to a
server-side suite.

`test/system/sheet_grid_test.rb` does what STATUS.md prescribes: sign in, open a sheet, type a
formula with its operands, **assert the computed value**, reload, **assert the raw formula
persisted**.

Both shipped bugs fail this test:

- The **async-workbook** bug (a flat `{data, columns}` throws inside an uncatchable promise) renders
  a permanently empty grid — the typing step has nothing to type into.
- The **`data-turbo-track="reload"`** bug leaves `window.jspreadsheet` undefined when Stimulus
  connects — same empty grid.

**The test must reach the sheet page by a Turbo visit — clicking through from the project page, not
`visit`-ing the URL directly.** A direct `visit` is a hard load, which is the one path where the
second bug does *not* reproduce. This is the single most important detail in the test and the
easiest to lose in a later edit.

### 5.2 Pattern and wiring

Follows `test/system/tray_layout_test.rb`, the repo's existing (and until now only) system test —
including its `assert_current_path` wait after login, whose comment records that without it the next
`visit` races the Turbo redirect and 401s into the login page, "which reads exactly like the editor
failing to render."

**No CI change is needed.** `test/system` is excluded from `bin/rails test` — which is precisely why
the 1587 count never covered it — but a `system-test` job already exists on a self-hosted linux
runner running `bin/rails db:test:prepare test:system` (`.github/workflows/ci.yml:238`), with
failure screenshots uploaded. The new test lands inside an existing gate.

## 6. Item 4 — one file-type vocabulary

### 6.1 The new role

`document` → **`txt`, `md`, `markdown`, `json`, `csv`**.

**Derived from what the app already believes, not invented.** `Maker::Previews::Registry` already
routes `txt`/`md`/`markdown`/`json` to `TextThumb`, and `EXT_FAMILIES` already groups `txt`/`md`/
`csv` as "Documents". The union is the set above: `csv` gains a role it lacked, `markdown` and
`json` gain chips they lacked, and no extension is classified by a judgement call made here.

`ROLE_LABELS` gains `"document" => "Documents"`; `ROLES` derives from `ROLE_LABELS.keys`, so the
inclusion validation follows with no separate edit. Placement in `ROLE_LABELS` sets the panel
heading order — `document` goes after `instructions`, before `vector`.

### 6.2 `EXT_FAMILIES` becomes derived

`FilesHelper::EXT_FAMILIES` stops being a hand-written literal and becomes a projection of
`Maker::FileAttachment::ROLE_BY_EXT`: grouped by role, ordered and labelled by `ROLE_LABELS`, with
**`other` dropped** — it is a fallback for unrecognised extensions, not an extension set, and has
nothing to render chips from.

The resulting families, 5 → **8**:

| Family | Extensions |
|---|---|
| Models | stl 3mf obj step stp |
| Images | png jpg jpeg gif webp bmp |
| Instructions | pdf |
| Documents | txt md markdown json csv |
| Vector | svg dxf lbrn2 |
| CAD source | scad f3d fcstd sldprt sldasm |
| G-code | gcode gco |
| Archives | zip |

**This is a visible Files-page change**, stated rather than slipped in: the chip row grows, today's
"Machine" family splits into G-code and Archives, and `.svg`/`.dxf`/`.lbrn2` now read "Vector" on
both pages instead of "2D / laser" on one and "Vector" on the other — which was the reported
complaint.

`FilesController::MAX_EXTS = 8` caps **active extensions**, not families, so it is untouched and
`ext_slots_left?` keeps working unchanged.

### 6.3 The second migration

A data migration re-deriving rows currently sitting in `other` whose extension is now `document`.

Self-contained in the house style of `20260728124303_rederive_vector_and_cad_source_roles.rb`: no
app models, no call to `role_for`, its own `MigrationAttachment`/`MigrationNode` classes, and its
own **copied** extension list.

**It carries the same caveat as its predecessor, stated in its own comment rather than papered
over:** because the list is a copy, an extension added to `ROLE_BY_EXT` *after* this migration runs
will never re-derive rows already sitting in `other`, and closing that gap needs a third migration.
That is the acknowledged cost of the self-contained style, not a defect of it — this migration
exists only because its predecessor made the same trade.

`down` returns every `document` row to `other`, with the same exactness caveat the predecessor
records: it has no record of which rows `up` moved, and `role_for` is already live in four
controllers, so organic `document` rows can exist before `up` ever runs. Acceptable for the same
reason — the pair is self-healing, since the mapping is a pure function of the current filename.

### 6.4 Cross-checks already done

- **The desktop client will not break.** `client/sync-client/src/maker.rs:71` declares
  `pub role: String` — an open string, not an enum. Unlike `status` (the constraint that shaped the
  overhaul's decision #1), a new `role` value is not a deserialize error for a shipped client.
  `client/` keeps a zero-line diff.
- **`ROLE_BY_EXT` has one behavioural reader per role that matters:** cover selection
  (`Maker::Project#cover_node_id`, `Maker::Model`) reads `image` and `model`; PDF metadata
  extraction reads `instructions`. `document` is read by neither, which is exactly the cost §2
  decision 3 records.

### 6.5 Tests

- `EXT_FAMILIES` covers every extension in `ROLE_BY_EXT` and contains no `other` key — the test that
  makes "one vocabulary" a property rather than a coincidence, and that fails if someone re-adds a
  hand-written family later.
- `role_for` returns `document` for each of the five extensions.
- Migration test: a row in `other` pointing at a `.csv` node moves to `document`; a row in `other`
  pointing at an extension with no role stays put.
- The Files page renders all eight families; the project attachments panel renders a "Documents"
  heading when a document is attached.

## 7. Testing bar

The standing bar for this repo, unchanged: **`bin/rails test` green and identical on all three
backends** — default (chunk), `LIBRARY_BACKEND=share`, `LIBRARY_BACKEND=s3` — plus
`bin/rails test:system` green.

Item 3 adds the second member of a suite that has been effectively unused; items 1, 2 and 4 are all
covered by the default suite.

## 8. Not in scope

- **Rate limiting or a global request-body cap.** There is no rack-attack and no Rails 8
  `rate_limit` anywhere in this app. Item 2 is about one unbounded column, and a per-model bound is
  the honest fix for it. A general request-size policy is a separate, larger decision.
- **A normalized cells table for sheets.** The overhaul's risk table already records this as the fix
  *if* blob size ever bites; a 1 MB cap is the cheaper answer and slots out of the way if it does.
- **Broader system-test coverage.** Item 3 asks for the pattern plus the test that would have caught
  the two known bugs. Backfilling browser tests across the app is separate work.
- **Auditing other Action Text surfaces.** There are exactly two `has_rich_text` models and both are
  covered.

## 9. Risks

| Risk | Mitigation |
|---|---|
| Route interception (i) does not out-prioritise the engine's route | Verified by probe before being relied on; (ii) is the fallback and the tests are identical either way |
| The gate removes more Active Storage routes than intended, breaking previews | An explicit test that preview asset URLs still resolve and pages still render (§3.4) |
| The attachment strip is over-broad and eats ordinary formatting | A test that bold/links/lists survive (§3.4) |
| An attachment-only body now fails validation | Deliberate (§3.2), tested, and stated here so it is not read later as a regression |
| 1 MB rejects a real user's sheet | ~4.5× the largest plausible sheet (§4.1); the limit is one constant, and the 422 tells the user rather than failing silently |
| The 5 → 8 chip change surprises | Called out as a visible change (§6.2); it is the direct consequence of the chosen option and closes the reported inconsistency |
| `document` is an enum value that drives no behaviour | Accepted, recorded in §2 decision 3 as a known cost of the chosen option, not an oversight |
| A third migration is eventually needed for the same reason | Stated in the migration's own comment (§6.3) rather than left for rediscovery |

## 10. Definition of done

1. All four STATUS.md open items are closed, and **the open-items section at the head of
   `docs/STATUS.md` is rewritten to match reality** — a stale open list is worse than none, which is
   a lesson this file's own predecessor records.
2. `bin/rails test` green and byte-identical on chunk, share and s3.
3. `bin/rails test:system` green, with the new grid test in it.
4. `client/` has a zero-line diff.
5. `docs/STATUS.md` and, where the architecture moved, `CLAUDE.md` updated (CLAUDE.md §15's standing
   instruction).
