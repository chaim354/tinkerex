# Stage 4, S4-2: filing that matches the bench — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. **In this repo `.claude/commands/execute-plan.md` overrides the generic loop:** batch by file, dispatch disjoint tasks in parallel, no spec-compliance stage, one capped quality review per task with its mutations run and their output reported.

**Goal:** Deliver S4-2 of `docs/superpowers/specs/2026-09-07-stage-4-bench-maker-design.md` (§5's S4-2 row). `.mage`, `.lbrn` and `.ai` become part of the one file-type vocabulary and stop filing into `other/`; an `.ai` saved with PDF compatibility gets a thumbnail through pdfium; `kicad_sch`/`kicad_pcb` earn a filing rule they can never earn a role; a `.zip` the Gerber reader recognises as a board files into `pcb/`, not `archives/`; `/settings/filing` becomes one card per folder instead of 130 extension rows; a project can opt out of the sweep; and the sweep finally says what it did — on the project page and in the flash. Plus one display rule that hides `build/`, `node_modules/` and `__pycache__/` beside the dot-dirs.

**Stories moved:** 2.3, 2.4, 2.8, 4.1, 4.3, 4.8, and 1.5's filing half.

**Architecture:** `ROLE_BY_EXT` stays the ONE file-type vocabulary and gains three extensions plus one role (`cnc_design` → `cnc/`); `Maker::FilingRule::KEY_RE` is the filing map's own, wider key rule so a key the vocabulary cannot carry can still carry a destination; the board-zip question is a CONTENT question and lives in `Maker::ProjectIntake` alone, reading `Maker::GerberArchive.for` — the same bounded, cached reader the zip's own file page uses; `Maker::ProjectIntake::Result` gains a `conflicts` map so the flash names the folder the sweep actually tried rather than re-deriving it; the sweep stamps `maker_projects.last_swept_at`/`last_sweep_moves` from ONE writer at the end of `#call`, which every entry point already funnels through; and `Library::BuildOutput` is a DISPLAY-only name list — never an observer skip, never a write guard (§14b).

**Tech Stack:** Rails 8, Hotwire (no new Stimulus controller), Minitest, two migrations, `page_query_budget_test.rb`, `template_hygiene_test.rb`, `css_hygiene_test.rb`.

---

## Amendments (orchestrator review, 2026-09-07) — these override the task text below

1. **Task D: TWO names, not three.** `Library::BuildOutput::NAMES = %w[node_modules __pycache__]`.
   `build` is deliberately NOT hidden: a lowercase `build/` is a plausible folder a maker made
   themselves (assembly photos), it never appeared in the measured library (the ~440 files were
   under `.pio/`, already a dot-dir), and the project page has no "Show hidden" control. Write the
   `NAMES` comment to say so, and use `node_modules` wherever the tests below say `build` (the
   "a FILE named build is still visible" case becomes a file named `node_modules`). Open question 1
   is thereby closed: no `show_hidden` pass-through on the project panel in this slice.
2. **Task F: no per-chip move select.** A chip carries its extension and Remove only; moving an
   extension is Remove on one card, Add on another (rare, two clicks). Drop the `filing-move` form
   from `_folder_card.html.erb`, drop the `select` rule from the CSS, and do not assert a select in
   `settings_filing_test.rb`; keep every route and the `#update` action (still reachable by a
   future control, and its tests stay). Open question 2 is thereby closed.
3. **Task E: `record_sweep!` runs only on a pass that was ALLOWED to move** (`@move` true and not
   a dry run). An attach-only pass (`move: false`) is not a sweep and must not overwrite a real
   "Sweep filed 3 files" with 0. When `autofile` is off the stamp still happens (moved 0) — that
   pass DID run as a sweep and chose not to move. Reshape `#call`: guard on `@move` first
   (attach-only → return without stamping), then on `@project.autofile?` (stamp 0 and return).
   Add one test: `for_project(..., move: false)` (or whatever the attach-only entry is — read it)
   leaves a prior `last_sweep_moves` untouched.

Everything else stands as written. When a step below conflicts with an amendment, the amendment wins.

## Before you start

- Branch from `main` (or from `claude/user-stories-ux-c52143` if the stage-4 docs PR has not merged). Never push to `main`.
- Tests: `export LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d)`; style `bin/ci style`; one full-suite run at a time; from a worktree `TINKEREX_SYNC_DIR=/Users/charlesschwartz/Desktop/repos/tinkerex-sync bin/ci`. The three backend legs (`test`, `test-s3`, `test-chunk-remote`) must report identical run counts.
- **Read first, in full:** `docs/invariants/files-preview.md` (the ONE vocabulary; `EXT_RE`; why `kicad_sch`/`kicad_pcb` cannot earn a `ROLE_BY_EXT` entry; the "Filing is untouched" sentence about Gerber zips this slice falsifies; "Dot-files are a DISPLAY filter, never a scan skip"), `docs/invariants/project-intake.md` (root = inbox, the two collision checks, the two caps, the eager nudge's call-site rule, "prediction and behaviour cannot disagree"), `docs/invariants/model-intake.md` (`EXCLUDED_ROLES` is a denylist), and CLAUDE.md §14b (`Node.visible_entries` / `.git`) and §14d (Stimulus, form `scope:`).
- **`app/views/projects/_attachments.html.erb` is being edited RIGHT NOW by S4-1's Task B** (the root README/repo card slot, the `repo` badge, Commits/History links, the working-tree caption). Task E of this plan adds ONE block to that file — take S4-1's committed version as the base, and if the file has moved under you, re-anchor on the `panel-head` closing `</div>` rather than on line numbers.
- Fixtures: a project folder in a request test is `project_folder_rows!(user, project)` — never `ensure_library_folder!` (a real mkdir; red on s3 and chunk_remote). `test/services/maker/project_intake_test.rb` is the exception and owns a real share library (`use_fresh_share_library!`), which is what makes it identical on all three legs.
- `git add` a new file before a mutation check; restore with `git checkout -- <file>`; clear `tmp/cache/bootsnap*` after an equal-length restore; `git status --porcelain` before the next run.
- Helpers and facts you will rely on, each verified by reading:
  - `Maker::ProjectFolders.ext_of(name)` is `File.extname(name).downcase.delete(".")` — **probed: `File.extname("board.kicad_sch")` is `".kicad_sch"`, so `ext_of` answers `"kicad_sch"`** and no new extraction is needed for KiCad (`app/services/maker/project_folders.rb:119-121`).
  - `Maker::GerberArchive.archive?(name)` is **name-only** (`ext == "zip"`, `app/services/maker/gerber_archive.rb:67`). The content question is `Maker::GerberArchive.for(user:, node:)` (`:83-91`), which refuses a nil or over-`READ_LIMIT` size before any read and caches the answer — **nil included** — by `(node_id, content token)`. The spec sentence "a zip that `archive?` recognises as a board" names the wrong method; use `.for`.
  - A renderer signals a deliberate terminal non-error by raising `::Maker::GeneratePreviewJob::Unsupported` (`gerber.rb:89`, `gerber_zip.rb:58`). `Maker::Previews::Pdf.available?` takes no bytes, so **the `%PDF-` refusal cannot live in `available?`** — it lives in `render`. The spec's "`available?`/render path" is loose; say so in the code comment.
  - `nodes.kind` is `null: false` (`db/schema.rb:446`), so a raw `NOT (kind = 'dir' AND …)` predicate has no three-valued surprise.
  - `Maker::ProjectIntake::Result` is constructed at 3 sites in `project_intake.rb` and 3 in `test/integration/web/project_scan_button_test.rb`. A `Data.define` member with a default (`def initialize(conflicts: {}, **) = super`) leaves all six untouched.

## File structure

| path | responsibility | task |
|---|---|---|
| `app/models/maker/file_attachment.rb` (`ROLE_LABELS` + `cnc_design`, `ROLE_BY_EXT` + `mage`/`lbrn`/`ai`, the `BACKUP_EXTS` comment), `app/services/maker/project_folders.rb` (`ROLE_FOLDERS` + `cnc_design`), `app/services/maker/model_intake.rb` (`EXCLUDED_ROLES`); `test/models/maker/file_attachment_test.rb`, `test/services/maker/project_folders_test.rb`, `test/helpers/files_helper_test.rb`, `test/services/maker/model_intake_classify_test.rb` | the vocabulary | **A** |
| `app/services/maker/previews/pdf.rb`, `app/services/maker/previews/registry.rb`; new `test/services/maker/previews/pdf_test.rb`, `test/services/maker/previews/registry_test.rb`, `test/controllers/files_controller_preview_kind_test.rb` | `.ai` through pdfium | **B** |
| `app/models/maker/filing_rule.rb` (`KEY_RE`), `app/services/maker/filing_rules.rb` (`BEYOND_ROLE_BY_EXT`), new `db/migrate/20260907120000_add_sweep_fields_to_maker_projects.rb`, new `db/migrate/20260907120100_seed_bench_filing_rules_and_rederive_roles.rb`, `db/schema.rb`; `test/models/maker/filing_rule_test.rb`, `test/services/maker/filing_rules_test.rb`, new `test/models/maker/seed_bench_filing_rules_migration_test.rb` | keys, the seed, both migrations, the schema | **C** |
| new `app/services/library/build_output.rb`, `app/models/node.rb`, `app/services/maker/project_folder_listing.rb`, `app/controllers/search_controller.rb` (comment), `app/controllers/library_browse_controller.rb` (comment); `test/models/node_test.rb`, `test/services/maker/project_folder_listing_test.rb`, `test/integration/web/files_search_test.rb`, `test/integration/web/search_test.rb` | build output is a display rule | **D** |
| `app/services/maker/project_intake.rb`, `app/controllers/concerns/project_folder_intake.rb`, `app/controllers/projects/scans_controller.rb`, `app/controllers/projects_controller.rb` (`project_params`), `app/models/maker/project.rb` (comment), `app/views/projects/_form.html.erb`, `app/views/projects/_attachments.html.erb`, `app/assets/stylesheets/pages/projects.css`; `test/services/maker/project_intake_test.rb`, `test/integration/web/project_folder_intake_test.rb`, `test/integration/web/project_scan_button_test.rb`, `test/integration/web/project_attachments_test.rb`, `test/integration/web/projects_test.rb`, `test/integration/web/template_hygiene_test.rb` | the sweep: board zips, autofile, and what it did | **E** |
| `app/controllers/settings/filing_rules_controller.rb`, `app/views/settings/filing_rules/index.html.erb`, new `app/views/settings/filing_rules/_folder_card.html.erb`, `app/assets/stylesheets/pages/settings.css`; `test/integration/web/settings_filing_test.rb`, `test/integration/web/page_query_budget_test.rb` | `/settings/filing`, one card per folder | **F** |
| `docs/invariants/files-preview.md`, `docs/invariants/project-intake.md`, `docs/invariants/model-intake.md` | the documents this slice falsifies | **G** |
| `docs/user-stories.md` (re-tag 2.3, 2.4, 2.8, 4.1, 4.3, 4.8, 1.5), `docs/superpowers/plans/2026-09-07-stage-4-00-overview.md` (S4-2 row) | close-out | **H** |

**Dependencies and batches.**

1. **A, B, D in parallel** — disjoint file sets, no shared test file.
2. **C** — after A (its migration test asserts the migration's hard-coded copy still equals the model's vocabulary).
3. **E and F in parallel** — both after C (E needs the two `maker_projects` columns; F needs `KEY_RE` and the widened seed count).
4. **G**, then **H**.

**Why one documentation task instead of "the same task sweeps".** CLAUDE.md's rule is that a change sweeps every file that documents it *in the same change*. Four of the six implementing tasks falsify a sentence in `docs/invariants/files-preview.md` alone. Parallel agents editing one file in one worktree is a recorded hazard (memory: `parallel-agents-one-worktree-rules`), and serialising four tasks to protect one Markdown file would cost the whole batch. Task G is in the SAME plan and the SAME PR, and every implementing task's last step names, verbatim, the sentence it falsified — the rule's purpose (the sweep is not deferred to "later") is kept; only the typing is pooled. Do not let G slip out of this PR.

---

### Task A: the vocabulary — `.mage`, `.lbrn`, `.ai`, and a `cnc_design` role

**Files:**
- Modify: `app/models/maker/file_attachment.rb`, `app/services/maker/project_folders.rb`, `app/services/maker/model_intake.rb`
- Test: `test/models/maker/file_attachment_test.rb`, `test/services/maker/project_folders_test.rb`, `test/helpers/files_helper_test.rb`, `test/services/maker/model_intake_classify_test.rb`

- [ ] **Step 1: the failing role tests.** Append inside `test/models/maker/file_attachment_test.rb`'s existing class:

```ruby
    # STAGE 4, S4-2 — THE THREE FORMATS THE BENCH ACTUALLY PRODUCES THAT THE VOCABULARY HAD NEVER
    # HEARD OF. All three had a full page and no role, so all three filed into `other/`: `.mage`
    # has Measure and a CNC operations panel, `.lbrn` has the LightBurn thumbnail and Measure
    # (Registry has claimed it since the Lbrn2 renderer landed), and `.ai` had nothing at all.
    # share, 2026-09-07: 23 .mage, 25 .ai.
    test "MillMage, LightBurn v1 and Illustrator files have roles" do
      assert_equal "cnc_design", Maker::FileAttachment.role_for("catan.mage")
      assert_equal "cnc_design", Maker::FileAttachment.role_for("CATAN5.MAGE")
      assert_equal "laser",      Maker::FileAttachment.role_for("tray.lbrn")
      assert_equal "vector",     Maker::FileAttachment.role_for("logo.ai")
    end

    # `cnc_design` IS NOT `gcode`, AND THE SPLIT IS THE POINT. `.nc`/`.tap`/`.ngc`/`.gcode` are the
    # machine's OUTPUT — the toolpath you send; a `.mage` is the PROJECT you go back and edit, the
    # CNC sibling of `.lbrn2`. They share a FOLDER (`cnc/`) because that is where a maker looks for
    # their CNC work, and they must not share a ROLE, because a role is also what
    # Maker::ModelIntake denies a model and what a panel heading reads.
    test "a MillMage project is not g-code" do
      assert_not_equal Maker::FileAttachment.role_for("catan.mage"),
                       Maker::FileAttachment.role_for("catan.nc")
      assert_equal "CNC design", Maker::FileAttachment::ROLE_LABELS.fetch("cnc_design")
      assert_includes Maker::FileAttachment::ROLES, "cnc_design"
    end

    # `.mage` IS NOT TEXT, though it is XML — its page is Measure, exactly like `.lbrn2`'s. The
    # guard is on the CONSTANT because preview_kind's `:measure` branch returns first and would
    # stay green if the role ever joined TEXT_ROLES (the argument `pcb` already carries here).
    test "the CNC design role is not a text role" do
      assert_not_includes Maker::FileAttachment::TEXT_ROLES, "cnc_design"
      refute Maker::FileAttachment.text?("catan.mage")
    end
```

- [ ] **Step 2: run, expect three failures.** `bin/rails test test/models/maker/file_attachment_test.rb` → FAIL: `Expected: "cnc_design" Actual: "other"` and `KeyError: key not found: "cnc_design"`.

- [ ] **Step 3: `ROLE_LABELS`.** In `app/models/maker/file_attachment.rb`, insert immediately after the `"gcode" => "G-code",` line (so `EXT_FAMILIES`'s dropdown order puts the CNC pair together, and `laser` stays immediately after `vector` — `file_attachment_test.rb` pins that adjacency):

```ruby
      # THE CNC PROJECT FILE, AS OPPOSED TO ITS OUTPUT (stage 4, S4-2). `.mage` is MillMage's
      # editable project — the CNC sibling of `.lbrn2` — and it files into the SAME folder as
      # g-code (`cnc/`) while keeping its own role, for the reason `vector`/`laser` are two roles
      # sharing nothing: a role is also what Maker::ModelIntake denies a model and what a panel
      # heading says. Folding it into `gcode` would make "G-code" the label on a file that is not
      # g-code; giving it its own folder would scatter one workbench across two directories.
      "cnc_design"     => "CNC design",
```

- [ ] **Step 4: `ROLE_BY_EXT`.** Extend the laser/vector block (currently `"svg" => "vector", "dxf" => "vector", "lbrn2" => "laser",`) to:

```ruby
      # `.lbrn` IS LIGHTBURN v1 AND IS THE SAME KIND OF FILE AS `.lbrn2` (stage 4, S4-2). It has
      # had a THUMBNAIL and a Measure page since the Lbrn2 renderer landed (Registry claims both
      # extensions, and MEASURABLE_EXTS lists both) — the only thing it lacked was a role, so a
      # v1 file filed into `other/` while the v2 file beside it filed into `laser/`. `.ai` is
      # Illustrator: `vector` beside `.svg`/`.dxf`, because that is what it is and where a maker
      # keeps it (share, 2026-09-07: 25 files, every one of them in `other/`).
      "svg" => "vector", "dxf" => "vector", "ai" => "vector",
      "lbrn2" => "laser", "lbrn" => "laser",
      # MillMage. See ROLE_LABELS' own note for why this is not `gcode`.
      "mage" => "cnc_design",
```

- [ ] **Step 5: sweep the comment this falsifies — in this file, this task.** `BACKUP_EXTS`' comment says "`.lbrn` (v1) is included alongside `.lbrn2` even though **only `.lbrn2` is in ROLE_BY_EXT**". Replace that sentence with:

```ruby
    # `.lbrn` (v1) sits here beside `.lbrn2` and `.mage`, and since stage 4, S4-2 all three are in
    # ROLE_BY_EXT too — this list predates that and was written when only `.lbrn2` was. It stays a
    # list of its own regardless: the question here is "did LightBurn/MillMage write this as a
    # rescue copy", which is about the vendor's naming convention, not about a role.
```

- [ ] **Step 6: `ROLE_FOLDERS`.** In `app/services/maker/project_folders.rb`, add beneath `"gcode" => "cnc",`:

```ruby
      # THE SAME FOLDER AS `gcode`, DELIBERATELY — two roles, one directory, exactly as
      # `instructions` and `document` both name `docs`. A maker's CNC work is one place on the NAS:
      # the MillMage project and the toolpath it exports belong side by side. `ROLE_FOLDERS.values
      # .uniq` is what /settings/filing renders a card per, so this adds no card.
      "cnc_design"     => "cnc",
```

Also extend the header's sentence naming the four "deliberate renames" — it lists `cnc` as "(not "G-code")"; add: "and `cnc` now answers for two roles, `gcode` and `cnc_design`, the same way `docs` answers for `instructions` and `document`."

- [ ] **Step 7: `EXCLUDED_ROLES`.** In `app/services/maker/model_intake.rb`:

```ruby
    EXCLUDED_ROLES = %w[cnc_design code document gcode laser vector].freeze
```

and extend that constant's comment's sentence, which currently reads "`code` is a firmware or script tree, `gcode` is sliced OUTPUT", with:

```ruby
    # `cnc_design` (a MillMage project) joins `laser` and `vector` on the same line those two are
    # already on: a 2D cut job that merely shares a folder with a mesh is not part of the model.
    # ADDED IN THE SAME CHANGE AS THE ROLE ITSELF (stage 4, S4-2) — this list is a DENYLIST, so a
    # new role joins models BY DEFAULT and the omission would have been silent: `Projects/catan/`
    # holding one `.stl` and twenty `.mage` files would have catalogued all twenty into that model.
```

- [ ] **Step 8: run, expect PASS.** `bin/rails test test/models/maker/file_attachment_test.rb test/services/maker/project_folders_test.rb test/helpers/files_helper_test.rb test/services/maker/model_intake_classify_test.rb`.

`project_folders_test.rb`'s "every role has a folder" and `model_intake_classify_test.rb`'s "every excluded role is a real role" both pass without edits — they are derived. `files_helper_test.rb`'s "EXT_FAMILIES flattens to exactly ROLE_BY_EXT's keys" is derived too. **If any of the three goes red, the derivation is what is wrong, not the assertion.**

- [ ] **Step 9: add the folder assertions that are NOT derived.** In `test/services/maker/project_folders_test.rb`, inside "the categories the folders were named for":

```ruby
      assert_equal "cnc",      Maker::ProjectFolders.default_folder_for("catan.mage")
      assert_equal "laser",    Maker::ProjectFolders.default_folder_for("tray.lbrn")
      assert_equal "design",   Maker::ProjectFolders.default_folder_for("logo.ai")
```

and a new test beneath it:

```ruby
    # TWO ROLES, ONE FOLDER — the `docs` shape, pinned so a later "tidy-up" that gives cnc_design
    # its own directory has to argue with a test instead of with a hash.
    test "the MillMage project and its g-code output share the cnc folder and not the role" do
      assert_equal Maker::ProjectFolders.default_folder_for("catan.mage"),
                   Maker::ProjectFolders.default_folder_for("catan.nc")
      assert_equal "cnc_design", Maker::FileAttachment.role_for("catan.mage")
      assert_equal "gcode",      Maker::FileAttachment.role_for("catan.nc")
    end
```

Run the four files again → PASS.

- [ ] **Step 10: add the chip assertion.** In `test/helpers/files_helper_test.rb`, beside the existing "CAD source" membership test:

```ruby
  test "the bench formats have a filter chip family" do
    assert_includes FilesHelper::EXT_FAMILIES["Vector"], "ai"
    assert_includes FilesHelper::EXT_FAMILIES["Laser"],  "lbrn"
    assert_includes FilesHelper::EXT_FAMILIES["CNC design"], "mage"
  end
```

Run → PASS. (The file's existing "every EXT_FAMILIES entry satisfies `EXT_RE`" loop covers all three for free: `mage` 4, `lbrn` 4, `ai` 2 characters.)

- [ ] **Step 11: mutation checks — three, each with its expected failure.**
  1. Remove `"cnc_design" => "cnc",` from `ROLE_FOLDERS`; run `bin/rails test test/services/maker/project_folders_test.rb` → FAILS on "every role has a folder": `add the new role to ROLE_FOLDERS — a role with no folder is ever seeded`. Restore.
  2. Remove `cnc_design` from `EXCLUDED_ROLES`; run `bin/rails test test/services/maker/model_intake_classify_test.rb` → this stays GREEN, because the denylist has no case naming a `.mage`. **That is the whole reason for the next line**: add a case to `model_intake_classify_test.rb`'s fixture — a `.mage` file inside a model folder — asserting `refute_includes classify.files_for("d-enc"), "f-mage"`, re-run the mutation, and report it going RED. A guard that could not fail is not a guard (§15).
  3. Change `"ai" => "vector"` to `"ai" => "other"`; run `bin/rails test test/models/maker/file_attachment_test.rb` → FAILS on `Expected: "vector" Actual: "other"`. Restore; re-run → PASS. Report all outputs.

- [ ] **Step 12: commit.**

```bash
git add app/models/maker/file_attachment.rb app/services/maker/project_folders.rb app/services/maker/model_intake.rb test/models/maker/file_attachment_test.rb test/services/maker/project_folders_test.rb test/helpers/files_helper_test.rb test/services/maker/model_intake_classify_test.rb
git commit -m "The bench's own formats join the vocabulary: MillMage projects, LightBurn v1 and Illustrator"
```

- [ ] **Step 13: hand Task G its sentence.** Record for G: `docs/invariants/files-preview.md`'s "ONE file-type vocabulary" section says nothing false yet, but the `.lbrn`/`.mage`/`.ai` additions need naming there, and `docs/invariants/model-intake.md`'s `EXCLUDED_ROLES` bullet lists the excluded roles by name and now omits `cnc_design`.

---

### Task B: `.ai` through pdfium, and a non-PDF `.ai` is `unsupported`

**Files:**
- Modify: `app/services/maker/previews/pdf.rb`, `app/services/maker/previews/registry.rb`
- Test: new `test/services/maker/previews/pdf_test.rb`, `test/services/maker/previews/registry_test.rb`, `test/controllers/files_controller_preview_kind_test.rb`

- [ ] **Step 1: the failing renderer test.** Create `test/services/maker/previews/pdf_test.rb`:

```ruby
require "test_helper"

module Maker
  module Previews
    # THE PDF RENDERER, AND THE ONE THING IT LEARNED IN STAGE 4, S4-2: an Adobe Illustrator file is
    # a PDF when Illustrator saved it as one. "Create PDF Compatible File" has been the default for
    # two decades, so a `.ai` off a maker's disk begins `%PDF-` with Illustrator's private data
    # appended, and pdfium renders page 1 of it like any other PDF. A file saved with that option
    # OFF is a bare PostScript stream, which pdfium cannot open at all — and the difference is
    # invisible from the name, so it has to be read from the bytes.
    #
    # NO NEW FIXTURE. The PDF-compatible case IS `sample.pdf` — that is precisely the claim ("an
    # `.ai` is a PDF") — and the incompatible case is a literal PostScript header, which is what
    # Illustrator writes and is three bytes' worth of test data rather than a committed binary.
    class PdfTest < ActiveSupport::TestCase
      def pdf_bytes = File.binread(Rails.root.join("test/fixtures/files/sample.pdf"))

      # `%!PS-Adobe-3.0` + Illustrator's own header comment, verbatim from a non-PDF-compatible
      # save. Not a PDF, not corrupt — a different format wearing the same extension.
      POSTSCRIPT_AI = "%!PS-Adobe-3.0\n%%Creator: Adobe Illustrator(R) 28.0\n%%BoundingBox: 0 0 612 792\n".b

      test "the renderer claims .ai as well as .pdf, and the registry agrees" do
        assert_equal %w[pdf ai], Maker::Previews::Pdf::EXTENSIONS
        assert_equal Maker::Previews::Pdf, Maker::Previews::Registry.for("ai")
        assert_equal Maker::Previews::Pdf, Maker::Previews::Registry.for_filename("logo.AI")
      end

      # UNSUPPORTED, NOT FAILED, AND THE CLASS IS THE ASSERTION. `failed` is what
      # Maker::Previews::Enqueue treats as "retry me", so a PostScript `.ai` would re-render on
      # every scan forever and wear an error badge over a file with nothing wrong with it. This is
      # Gerber's "a layer that plots nothing is unsupported" rule, in the same words.
      test "a PostScript .ai is unsupported, not failed" do
        error = assert_raises(Maker::GeneratePreviewJob::Unsupported) do
          Maker::Previews::Pdf.render(POSTSCRIPT_AI, size: 128)
        end
        assert_match(/%PDF-/, error.message)
      end

      # THE CHECK IS ON THE BYTES, NOT ON THE EXTENSION, so a `.pdf` that is not a PDF gets the
      # same honest terminal state instead of pdfium's exit code in an error badge. That is a
      # behaviour change for `.pdf` and it is the right one: nothing about that file will ever
      # render, and `unsupported` is the state that says so once.
      test "a .pdf that is not a PDF gets the same answer" do
        assert_raises(Maker::GeneratePreviewJob::Unsupported) do
          Maker::Previews::Pdf.render("not a pdf at all".b, size: 128)
        end
      end

      test "a real PDF still renders when pdfium is on this box" do
        skip "pdfium not installed" unless Maker::Previews::Pdf.available?

        result = Maker::Previews::Pdf.render(pdf_bytes, size: 128)
        assert_equal "image/png", result[:content_type]
        assert result[:bytes].bytesize.positive?
      end

      # AN .ai WITH PDF COMPATIBILITY IS BYTE-FOR-BYTE A PDF AS FAR AS THIS RENDERER IS CONCERNED —
      # the point of the whole change, driven rather than argued.
      test "a PDF-compatible .ai renders exactly as the PDF does" do
        skip "pdfium not installed" unless Maker::Previews::Pdf.available?

        assert Maker::Previews::Pdf.render(pdf_bytes, size: 128)[:bytes].bytesize.positive?
      end
    end
  end
end
```

- [ ] **Step 2: run it, expect failures.** `bin/rails test test/services/maker/previews/pdf_test.rb` → FAIL: `Expected: ["pdf", "ai"] Actual: ["pdf"]`, and `Maker::GeneratePreviewJob::Unsupported expected but nothing was raised` (or a `RenderError` where pdfium exists).

- [ ] **Step 3: `Pdf`.** In `app/services/maker/previews/pdf.rb`, replace `EXTENSIONS` and open `render` with:

```ruby
      # `.ai` IS A PDF WHEN ILLUSTRATOR SAVED IT AS ONE, AND ONLY THEN (stage 4, S4-2; story 2.3).
      # "Create PDF Compatible File" is Illustrator's default and has been for two decades, so the
      # `.ai` files on a real share (25 of them, 2026-09-07) begin `%PDF-` with Illustrator's own
      # private stream appended — pdfium renders page 1 of one exactly as it renders any PDF. The
      # extension alone cannot tell that from a bare PostScript save, so the bytes decide (below).
      #
      # THIS IS THE GRID/POSTER THUMBNAIL ONLY. `FilesController#preview_kind` answers `:thumbnail`
      # for `.ai` (nothing above it claims the extension) rather than `:pdf`: the `:pdf` branch
      # embeds the file for the BROWSER's own viewer, and a browser handed `application/…` bytes
      # named `.ai` downloads it. Rendering the first page as a picture is the honest offer.
      EXTENSIONS = %w[pdf ai].freeze

      # Byte 0. The PDF spec puts the header there; every Illustrator export this was checked
      # against does too. A tolerant "somewhere in the first 1024 bytes" scan was considered and
      # refused: it buys a file nobody has produced and costs the ability to say plainly what this
      # renderer accepts.
      MAGIC = "%PDF-".b.freeze
```

and, as the first statement inside `def render(pdf_bytes, size: 512)`:

```ruby
        # UNSUPPORTED, NOT FAILED, AND THE DIFFERENCE IS WHETHER IT RETRIES FOREVER.
        # Maker::Previews::Enqueue treats `failed` as "retry me", so a PostScript `.ai` would
        # re-render on every scan, forever, wearing an error badge over a file with nothing wrong
        # with it. `unsupported` is this job's word for "no preview for this file here" and is
        # terminal. Maker::Previews::Gerber makes the identical call for a layer that plots
        # nothing, and Maker::Previews::GerberZip for a zip that is not a board.
        #
        # ON THE BYTES, NOT ON THE EXTENSION: a `.pdf` that is not a PDF gets the same terminal
        # state instead of pdfium's exit code rendered as an error. That is a behaviour change for
        # `.pdf` and it is the right one — nothing about those bytes will ever render.
        unless pdf_bytes.to_s.b.start_with?(MAGIC)
          raise ::Maker::GeneratePreviewJob::Unsupported,
                "not a PDF (no %PDF- header at byte 0) — an Illustrator file saved without " \
                "PDF compatibility, or a file whose extension is wrong"
        end

```

- [ ] **Step 4: the registry.** In `app/services/maker/previews/registry.rb`, beside the `"pdf" => Maker::Previews::Pdf,` line:

```ruby
        # An Illustrator file, when Illustrator wrote it as a PDF — the renderer decides by reading
        # the first five bytes and answers the job's terminal `unsupported` when they are not
        # `%PDF-` (stage 4, S4-2). This is the SECOND renderer whose claim a read can retract, the
        # first being GerberZip; both are registered by NAME and refuse by CONTENT.
        "ai"    => Maker::Previews::Pdf,
```

- [ ] **Step 5: run, expect PASS.** `bin/rails test test/services/maker/previews/pdf_test.rb test/services/maker/previews/registry_test.rb test/services/maker/previews/renderer_contract_test.rb`. The contract test's "every EXTENSIONS entry resolves back to its renderer" is what pins step 3 against step 4; it needs no new fixture, because `Pdf`'s fixture (`sample.pdf`) already covers the renderer.

- [ ] **Step 6: the registry's own case.** In `test/services/maker/previews/registry_test.rb`, after "a zip resolves to the GerberZip renderer":

```ruby
      # `.ai` RESOLVES TO THE PDF RENDERER, and the vocabulary agrees it is a `vector` file. Two
      # different questions with two different answers, which is the split files-preview.md names:
      # a ROLE says where a file lives, a RENDERER says what picture we can make of it.
      test "an Illustrator file resolves to the Pdf renderer while its role stays vector" do
        assert_equal Maker::Previews::Pdf, Maker::Previews::Registry.for("ai")
        assert_equal Maker::Previews::Pdf, Maker::Previews::Registry.for(".AI")
        assert_equal "vector", Maker::FileAttachment.role_for("logo.ai")
      end
```

- [ ] **Step 7: the page it now has.** In `test/controllers/files_controller_preview_kind_test.rb`, beside "an unknown extension is still :other":

```ruby
  # STORY 2.3: `.ai` said "No inline preview for this file type." because nothing claimed it. It
  # takes the `:thumbnail` branch now — the last branch before `:other`, reached because
  # Registry.for("ai") finally answers. NOT `:pdf`: that branch embeds the bytes for the browser's
  # own viewer, which a browser handed a file named `.ai` downloads instead of rendering.
  test "an Illustrator file previews as a thumbnail rather than as nothing" do
    assert_equal :thumbnail, preview_kind("logo.ai")
    assert_equal :other, preview_kind("logo.eps"), "and nothing else moved with it"
  end
```

(Use whatever private accessor the file already uses to reach `preview_kind` — read the top of that test class and match it.)

- [ ] **Step 8: run, expect PASS.** `bin/rails test test/controllers/files_controller_preview_kind_test.rb test/services/maker/previews/`.

- [ ] **Step 9: mutation checks.**
  1. Delete the `unless pdf_bytes … MAGIC` guard; run `bin/rails test test/services/maker/previews/pdf_test.rb` → FAILS twice: `Maker::GeneratePreviewJob::Unsupported expected but nothing was raised` (no pdfium) or `Maker::Previews::Pdf::RenderError` (with pdfium). Restore.
  2. Remove `"ai" => Maker::Previews::Pdf` from `FORMAT_RENDERERS`; run `bin/rails test test/services/maker/previews/renderer_contract_test.rb` → FAILS: `Maker::Previews::Pdf claims .ai but Registry.for(ai) disagrees`. Restore; re-run → PASS. Report all four outputs.

- [ ] **Step 10: commit.**

```bash
git add app/services/maker/previews/pdf.rb app/services/maker/previews/registry.rb test/services/maker/previews/pdf_test.rb test/services/maker/previews/registry_test.rb test/controllers/files_controller_preview_kind_test.rb
git commit -m "An Illustrator file saved as a PDF gets a thumbnail, and one that is not says so once"
```

- [ ] **Step 11: hand Task G its sentence.** `docs/invariants/files-preview.md` has no paragraph about `.ai` and needs one under "ONE file-type vocabulary"; its GerberZip paragraph is the model for "a renderer registered by name that refuses by content".

---

### Task C: the filing map's own key, the two extra seeds, and both migrations

**Files:**
- Modify: `app/models/maker/filing_rule.rb`, `app/services/maker/filing_rules.rb`, `db/schema.rb`
- Create: `db/migrate/20260907120000_add_sweep_fields_to_maker_projects.rb`, `db/migrate/20260907120100_seed_bench_filing_rules_and_rederive_roles.rb`
- Test: `test/models/maker/filing_rule_test.rb`, `test/services/maker/filing_rules_test.rb`, new `test/models/maker/seed_bench_filing_rules_migration_test.rb`

- [ ] **Step 1: the failing key test.** In `test/models/maker/filing_rule_test.rb`, REPLACE the test named `"ext must satisfy FilesController::EXT_RE"` (its subject moved) with:

```ruby
    # THE FILING MAP'S KEY RULE IS WIDER THAN THE VOCABULARY'S, ON PURPOSE (stage 4, S4-2).
    # `kicad_sch`/`kicad_pcb` are nine characters with an underscore, so they fail
    # FilesController::EXT_RE and can never earn a ROLE_BY_EXT entry — an entry there renders a
    # filter chip that links and silently does nothing (docs/invariants/files-preview.md). A
    # filing rule renders no chip and grants no role: it answers one question, "which subfolder",
    # so it can carry a key the vocabulary cannot.
    test "ext satisfies KEY_RE, which admits the KiCad extensions EXT_RE cannot" do
      %w[stl kicad_sch kicad_pcb markdown gbrjob mage].each do |ext|
        rule = @user.maker_filing_rules.new(ext:, folder: "pcb")
        assert rule.valid?, "#{ext} should be a legal filing-rule key: #{rule.errors.full_messages}"
      end
      refute_match Maker::FilingRule::KEY_RE, "kicad_sch".upcase
      assert_no_match FilesController::EXT_RE, "kicad_sch"
    end

    test "a key that is not an extension at all is still refused" do
      [ "tar.gz", "way_too_long_ext", "with space", "UPPER", "", "a-b" ].each do |ext|
        rule = @user.maker_filing_rules.new(ext:, folder: "pcb")
        refute rule.valid?, "#{ext.inspect} must not be a legal key"
        assert_includes rule.errors.attribute_names, :ext
      end
    end
```

Note `"UPPER"` is normalized to `"upper"` before validation and IS valid — **drop it from that list**; keep `"tar.gz"` (a dot can never come out of `ext_of`), `"way_too_long_ext"` (16 > 12), `"with space"`, `""` and `"a-b"`.

- [ ] **Step 2: run, expect NameError.** `bin/rails test test/models/maker/filing_rule_test.rb` → FAIL, `uninitialized constant Maker::FilingRule::KEY_RE`.

- [ ] **Step 3: `KEY_RE`.** In `app/models/maker/filing_rule.rb`, replace the `# THE SAME BOUND EVERY ROLE_BY_EXT ENTRY ALREADY MEETS …` comment and the `format:` validation with:

```ruby
    # THE FILING MAP'S OWN KEY RULE, WIDER THAN `FilesController::EXT_RE` ON PURPOSE (stage 4,
    # S4-2). A key here is an EXTENSION as `Maker::ProjectFolders.ext_of` reads it — everything
    # after the last dot, downcased — and two formats a maker actually has, `.kicad_sch` and
    # `.kicad_pcb`, are nine characters with an underscore. `EXT_RE` (/\A[a-z0-9]{1,8}\z/) is the
    # FILES PAGE's bound and is right there: an extension it rejects renders a filter chip that
    # links and silently does nothing, which is why `Maker::FileAttachment::ROLE_BY_EXT` must meet
    # it (docs/invariants/files-preview.md, and file_attachment_test.rb's own guard).
    #
    # A FILING RULE RENDERS NO CHIP AND GRANTS NO ROLE. It answers exactly one question — which
    # subfolder — so it can carry a key the vocabulary cannot. That is the split, and it is NOT a
    # second copy of EXT_RE drifting: EXT_RE is untouched, still referenced by ROLE_BY_EXT's own
    # guard, and nothing here loosens it. A `.kicad_sch` file's ROLE stays `other` and its FOLDER
    # is `pcb` — two questions, two answers, which is the same shape `.scad` already carries
    # (`cad_source` for filing, text for viewing).
    #
    # 12, NOT UNBOUNDED, AND THE UNDERSCORE IS THE ONLY CHARACTER ADDED. `kicad_sch`/`kicad_pcb`
    # are 9; 12 leaves headroom without letting a pasted filename become a key. No dot (a dot
    # would admit `tar.gz`, which `ext_of` can never produce), no dash, no space.
    KEY_RE = /\A[a-z0-9_]{1,12}\z/

    validates :ext, presence: true, format: { with: KEY_RE }
```

- [ ] **Step 4: run, expect PASS.** `bin/rails test test/models/maker/filing_rule_test.rb`.

- [ ] **Step 5: the failing seed test.** In `test/services/maker/filing_rules_test.rb`, change `"the first read seeds exactly ROLE_BY_EXT.size rows"` to read `Maker::FileAttachment::ROLE_BY_EXT.size + Maker::FilingRules::BEYOND_ROLE_BY_EXT.size` and add:

```ruby
    # THE KEYS THE VOCABULARY CANNOT CARRY ARE SEEDED BESIDE IT, NOT INSTEAD OF IT (stage 4, S4-2).
    # A user seeded today gets a `pcb` destination for their KiCad files; a user seeded before this
    # gets one from the migration. `Maker::FilingRules.seed!`'s `exists?` guard is untouched — the
    # top-up is a migration, which runs once, because /settings/filing promises a REMOVED rule
    # files into `other` and a per-read fill-in would resurrect it.
    test "a KiCad schematic and board have a destination the vocabulary could never give them" do
      map = Maker::FilingRules.for(@user)
      assert_equal "pcb", map["kicad_sch"]
      assert_equal "pcb", map["kicad_pcb"]
      assert_equal "pcb", Maker::ProjectFolders.folder_for(@user, "board.kicad_pcb")
      assert_equal "other", Maker::FileAttachment.role_for("board.kicad_pcb"),
                   "the ROLE is untouched — EXT_RE still refuses these two"
    end

    # EVERY EXTRA KEY IS A LEGAL ROW. The seed writes with insert_all, which runs no validation,
    # so a key the settings form would itself refuse could be seeded and then be uneditable.
    test "every extra seed key passes the model's own validation" do
      Maker::FilingRules::BEYOND_ROLE_BY_EXT.each do |ext, folder|
        rule = @user.maker_filing_rules.new(ext:, folder:)
        assert rule.valid?, "#{ext} => #{folder}: #{rule.errors.full_messages}"
      end
    end
```

- [ ] **Step 6: run, expect NameError**, then implement. In `app/services/maker/filing_rules.rb`, above `self.seed!`:

```ruby
    # KEYS THE VOCABULARY CANNOT CARRY, SEEDED BESIDE IT (stage 4, S4-2; story 2.8).
    # `kicad_sch`/`kicad_pcb` fail `FilesController::EXT_RE`, so they can never be
    # `Maker::FileAttachment::ROLE_BY_EXT` entries and this map — built from ROLE_BY_EXT — could
    # never reach them. `Maker::FilingRule::KEY_RE` admits them, so a destination is expressible;
    # this is where a NEW user gets one, and db/migrate/20260907120100 is where an existing one does.
    #
    # `pcb`, NOT `cad`: a schematic and a board layout are the project the fabrication outputs came
    # from, and the folder holds the whole board — the same argument `.gbrjob` carries for being
    # `pcb` rather than `document`. Spelled as a literal folder name rather than through
    # ROLE_FOLDERS because there is no ROLE here to look one up by; the totality test in
    # project_folders_test.rb has nothing to say about these two, so filing_rules_test.rb asserts
    # they pass Maker::FilingRule's own validation instead.
    #
    # KEEP THIS SMALL. Every entry is a claim that a real format exists whose extension the Files
    # page cannot filter by. Two today.
    BEYOND_ROLE_BY_EXT = { "kicad_sch" => "pcb", "kicad_pcb" => "pcb" }.freeze
```

and inside `seed!`, after the `rows = …map do … end` block:

```ruby
      rows += BEYOND_ROLE_BY_EXT.map do |ext, folder|
        { user_id: user.id, ext:, folder:, created_at: now, updated_at: now }
      end
```

- [ ] **Step 7: run, expect PASS.** `bin/rails test test/services/maker/filing_rules_test.rb test/models/maker/filing_rule_test.rb`.

- [ ] **Step 8: migration one — the three project columns.** Create `db/migrate/20260907120000_add_sweep_fields_to_maker_projects.rb`:

```ruby
# THE SWEEP'S OWN THREE COLUMNS (stage 4, S4-2; stories 1.5, 4.1, 4.3).
#
# EVERY DEFAULT REPRODUCES TODAY'S BEHAVIOUR, which is the stage's rule: `autofile` true is what
# every project does now, and a never-swept project has no timestamp and no count. A deployment
# that runs this migration and nothing else sees no change at all.
#
# NO INDEX ON ANY OF THEM, DELIBERATELY. Nothing queries by them: the sweep already holds the
# project row (`Maker::ProjectIntake` is constructed per project) and the page reads them off the
# record it loaded. An index led by `user_id` here would also be a strict prefix of an existing one
# and trip `architecture_invariants_test.rb`'s prefix guard for no read it serves.
#
# `last_sweep_moves` IS AN INTEGER WITH NO DEFAULT, NOT `default: 0`, and the difference is a test's
# ability to fail. NULL means "no sweep has ever finished here" and 0 means "one finished and moved
# nothing" — two different facts, and §15's own warning about timestamps compared at `.to_i` is the
# reason to keep a column that is nil until something writes it.
class AddSweepFieldsToMakerProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :maker_projects, :autofile, :boolean, default: true, null: false
    add_column :maker_projects, :last_swept_at, :datetime
    add_column :maker_projects, :last_sweep_moves, :integer
  end
end
```

- [ ] **Step 9: migration two — seed the five new keys and re-derive three roles.** Create `db/migrate/20260907120100_seed_bench_filing_rules_and_rederive_roles.rb`, copying `RederiveModelRolesAndSeedFilingRules`'s shape exactly (read it first):

```ruby
# THE BENCH'S OWN FORMATS REACH EXISTING USERS ONCE, HERE (stage 4, S4-2) — the same two doors
# every earlier widening used, in one migration because they are one fact: `.mage`, `.lbrn` and
# `.ai` have roles and folders now, and `.kicad_sch`/`.kicad_pcb` have folders (they can never have
# roles — they fail FilesController::EXT_RE).
#
# 1. FILING RULES. `Maker::FilingRules.seed!` is guarded by `exists?` on purpose (/settings/filing
#    promises a removed rule "will file into other until you add a new one", and a top-up on every
#    read would resurrect it), so a user seeded before these keys existed has no row for them. A
#    migration runs exactly once, which is what makes a top-up safe: a rule removed AFTER it stays
#    removed. Users with NO rows are skipped and get everything on their first read.
#    `insert_all(..., unique_by:)` is ON CONFLICT DO NOTHING, never an upsert — an edited row wins.
#
# 2. ATTACHMENT ROLES. `maker_file_attachments.role` is derived at attach time, so a `.mage`
#    attached last month carries `other`. `RederiveCodeRoles` and its siblings are the shape: only
#    rows holding the PRIOR role are touched (a role set deliberately is never rewritten), a row
#    whose node is gone is skipped, and `down` returns exactly these extensions to the prior role.
#
# SELF-CONTAINED, like every re-derive migration here: it names its own lists and tables rather
# than reading the app's constants, because it runs against whatever the code looks like months
# from now. Its test pins the copy against today's vocabulary.
#
# `down` TAKES ONLY WHAT `up` COULD HAVE WRITTEN — the folder column is free-form, so a maker who
# mapped `.stp` into `pcb` by hand must survive a rollback (SeedPcbFilingRules' recorded lesson).
class SeedBenchFilingRulesAndRederiveRoles < ActiveRecord::Migration[8.1]
  # ext => [folder, prior role, new role]. A nil new role means "no role exists for this key" —
  # the KiCad pair, which gets a folder and nothing else.
  RULES = {
    "mage"      => [ "cnc",    "other", "cnc_design" ],
    "lbrn"      => [ "laser",  "other", "laser" ],
    "ai"        => [ "design", "other", "vector" ],
    "kicad_sch" => [ "pcb",    nil,     nil ],
    "kicad_pcb" => [ "pcb",    nil,     nil ]
  }.freeze

  class MigrationFilingRule < ActiveRecord::Base
    self.table_name = "maker_filing_rules"
  end

  class MigrationAttachment < ActiveRecord::Base
    self.table_name = "maker_file_attachments"
  end

  class MigrationNode < ActiveRecord::Base
    self.table_name = "nodes"
  end

  def up
    now = Time.current
    seeded = 0
    MigrationFilingRule.distinct.pluck(:user_id).each do |user_id|
      rows = RULES.map { |ext, (folder, _prior, _new)| { user_id:, ext:, folder:, created_at: now, updated_at: now } }
      seeded += MigrationFilingRule.insert_all(rows, unique_by: %i[user_id ext]).rows.size
    end
    say "seeded #{seeded} bench filing rule#{"s" unless seeded == 1}"

    moved = 0
    MigrationAttachment.where(role: "other").find_each do |att|
      node = MigrationNode.find_by(user_id: att.user_id, node_id: att.node_id)
      next if node.nil?

      _folder, prior, new_role = RULES[File.extname(node.name.to_s).downcase.delete(".")]
      next if new_role.nil? || att.role != prior

      att.update_columns(role: new_role)
      moved += 1
    end
    say "re-derived #{moved} attachment role#{"s" unless moved == 1}"
  end

  def down
    removed = 0
    RULES.each { |ext, (folder, _prior, _new)| removed += MigrationFilingRule.where(ext:, folder:).delete_all }
    say "removed #{removed} bench filing rule#{"s" unless removed == 1}"

    reverted = 0
    MigrationAttachment.find_each do |att|
      node = MigrationNode.find_by(user_id: att.user_id, node_id: att.node_id)
      next if node.nil?

      _folder, prior, new_role = RULES[File.extname(node.name.to_s).downcase.delete(".")]
      next if new_role.nil? || att.role != new_role

      att.update_columns(role: prior)
      reverted += 1
    end
    say "returned #{reverted} attachment role#{"s" unless reverted == 1} to other"
  end
end
```

- [ ] **Step 10: run both migrations in BOTH environments and commit the schema.**

```bash
bin/rails db:migrate
RAILS_ENV=test bin/rails db:migrate
git diff --stat db/schema.rb
```
Expected: `db/schema.rb` version becomes `2026_09_07_120100` and `maker_projects` gains `autofile`, `last_swept_at`, `last_sweep_moves`. Confirm the three columns are in the alphabetised block and that no index appeared.

- [ ] **Step 11: the migration test.** Create `test/models/maker/seed_bench_filing_rules_migration_test.rb`, copying `test/models/maker/seed_pcb_filing_rules_migration_test.rb` verbatim in structure (read it), with these cases:

```ruby
require "test_helper"
require Rails.root.join("db/migrate/20260907120100_seed_bench_filing_rules_and_rederive_roles")
```

  - `"an already-seeded user gains every bench rule and keeps their own edits"` — build the pre-S4-2 world by REMOVING the five keys from what `seed!` would write today (never a hard-coded list), edit `.stl` to `prints`, run `.new.up`, assert `+5` rows, `find_by!(ext: "mage").folder == "cnc"`, `find_by!(ext: "kicad_sch").folder == "pcb"`, and that `prints` survived.
  - `"a user who has never been seeded gets nothing from the migration and everything from seed!"` — `count`, never `reload`/`assert_empty` on the association (the pcb test's recorded trap: `insert_all` does not touch a loaded association's cache).
  - `"a user who already added .mage by hand keeps their folder"` — `create!(ext: "mage", folder: "cnc-projects")`, run `up`, assert the folder survived and the count grew by 4.
  - `"down removes the bench rules and leaves a hand-made one that files into the same folder"` — create `ext: "xnc", folder: "pcb"` and `find_by!(ext: "stp").update!(folder: "pcb")` first; after `down`, `kicad_sch` is gone and both survivors keep `pcb`.
  - `"attachment roles are re-derived only from other, and only for these extensions"` — three nodes (`catan.mage`, `tray.lbrn`, `logo.ai`) with `role: "other"` attachments, one `board.gbrjob` with `role: "pcb"` (must not move), one `deliberate.mage` with `role: "image"` (a role set deliberately is never rewritten); after `up`, assert `cnc_design`/`laser`/`vector`, and that the other two are untouched.
  - `"a ghost attachment whose node is gone is skipped rather than raising"`.
  - `"the migration's copy still equals the model's vocabulary"`:

```ruby
    test "the migration's copy still equals the model's vocabulary" do
      SeedBenchFilingRulesAndRederiveRoles::RULES.each do |ext, (folder, _prior, new_role)|
        if new_role
          assert_equal new_role, Maker::FileAttachment::ROLE_BY_EXT.fetch(ext),
                       "#{ext}'s role drifted from the migration's copy"
          assert_equal folder, Maker::ProjectFolders::ROLE_FOLDERS.fetch(new_role),
                       "#{ext}'s folder drifted from ROLE_FOLDERS"
        else
          assert_equal folder, Maker::FilingRules::BEYOND_ROLE_BY_EXT.fetch(ext)
          assert_nil Maker::FileAttachment::ROLE_BY_EXT[ext],
                     "#{ext} gained a role — EXT_RE should have refused it"
        end
      end
    end
```

  - `"the top-up reaches every seeded user separately"`.

- [ ] **Step 12: run, expect PASS.** `bin/rails test test/models/maker/seed_bench_filing_rules_migration_test.rb test/services/maker/filing_rules_test.rb test/models/maker/filing_rule_test.rb`.

- [ ] **Step 13: mutation checks.**
  1. In the migration, change `next if new_role.nil? || att.role != prior` to `next if new_role.nil?`; run the migration test → FAILS on "a role set deliberately is never rewritten" (`deliberate.mage` becomes `cnc_design`). Restore.
  2. Change `KEY_RE` back to `/\A[a-z0-9]{1,8}\z/`; run `bin/rails test test/models/maker/filing_rule_test.rb test/services/maker/filing_rules_test.rb` → FAILS: `kicad_sch should be a legal filing-rule key: Ext is invalid`. Restore; re-run → PASS.
  3. Drop `rows += BEYOND_ROLE_BY_EXT.map …` from `seed!`; run `bin/rails test test/services/maker/filing_rules_test.rb` → FAILS on the seeded count and on `map["kicad_sch"]`. Restore. Report all six outputs.

- [ ] **Step 14: commit.**

```bash
git add app/models/maker/filing_rule.rb app/services/maker/filing_rules.rb db/migrate/20260907120000_add_sweep_fields_to_maker_projects.rb db/migrate/20260907120100_seed_bench_filing_rules_and_rederive_roles.rb db/schema.rb test/models/maker/filing_rule_test.rb test/services/maker/filing_rules_test.rb test/models/maker/seed_bench_filing_rules_migration_test.rb
git commit -m "A filing rule can be keyed by something the type filter cannot: KiCad files get a folder"
```

- [ ] **Step 15: hand Task G its sentences.** `docs/invariants/files-preview.md`'s `:kicanvas` section says "Living outside ROLE_BY_EXT also means Registry.for/text? have never …" and, two paragraphs up, that neither extension can earn an entry "because both fail `EXT_RE`" — still true of ROLE_BY_EXT, now incomplete about FILING. G must add the KEY_RE split there.

---

### Task D: build output is a display rule, and only a display rule

**Files:**
- Create: `app/services/library/build_output.rb`
- Modify: `app/models/node.rb`, `app/services/maker/project_folder_listing.rb`, `app/controllers/search_controller.rb` (comment only), `app/controllers/library_browse_controller.rb` (comment only)
- Test: `test/models/node_test.rb`, `test/services/maker/project_folder_listing_test.rb`, `test/integration/web/files_search_test.rb`, `test/integration/web/search_test.rb`

- [ ] **Step 1: the failing scope test.** Append to `test/models/node_test.rb`:

```ruby
  # STAGE 4, S4-2, STORY 4.8. `.pio` was hidden because it is dot-prefixed; `build/`,
  # `node_modules/` and `__pycache__/` are the same clutter without the dot, and a firmware repo
  # puts ~440 `.o/.d/.a` files under one of them on the measured share library.
  #
  # A DISPLAY RULE, GATED ON `show_hidden` EXACTLY LIKE A DOT-DIR — not unconditional like `.git`
  # or `*.ptr`. There IS a reason to look inside a build directory (a linker map, a generated
  # header), and the "Show hidden" control is already the way back.
  test "a build directory is hidden by default and revealed with hidden files" do
    build = @user.nodes.create!(node_id: "n-build", name: "build", kind: "dir", mtime: 1, size: 0)
    @user.nodes.create!(node_id: "n-nm", name: "node_modules", kind: "dir", mtime: 1, size: 0)
    @user.nodes.create!(node_id: "n-pyc", name: "__pycache__", kind: "dir", mtime: 1, size: 0)

    hidden = @user.nodes.present.visible_entries(false).pluck(:node_id)
    assert_not_includes hidden, build.node_id
    assert_not_includes hidden, "n-nm"
    assert_not_includes hidden, "n-pyc"

    shown = @user.nodes.present.visible_entries(true).pluck(:node_id)
    assert_includes shown, build.node_id
  end

  # A FILE NAMED `build` IS SOMEBODY'S COMPILED BINARY, NOT A DIRECTORY OF CLUTTER — the Go and
  # Make convention. The rule asks about DIRECTORIES, unlike the dot-prefix rule, which asks about
  # names of any kind. `nodes.kind` is NOT NULL (db/schema.rb), so the SQL has no third answer.
  test "a FILE named build is still visible" do
    file = @user.nodes.create!(node_id: "n-buildfile", name: "build", kind: "file", mtime: 1, size: 4)
    assert_includes @user.nodes.present.visible_entries(false).pluck(:node_id), file.node_id
  end

  # THE HONEST LIMIT, PINNED SO IT IS NOT MISTAKEN FOR A BUG LATER: this hides the ENTRY, not its
  # descendants. A `main.o` under `build/` is still a row and still appears in the flat
  # by-extension view — the identical, recorded limitation `.git` carries on chunk_remote. Closing
  # it needs a recursive CTE on a page in the hot path, which node.rb's own comment refuses.
  test "a file INSIDE a build directory is not hidden, and that is the recorded limit" do
    build = @user.nodes.create!(node_id: "n-build2", name: "build", kind: "dir", mtime: 1, size: 0)
    obj = @user.nodes.create!(node_id: "n-obj", name: "main.o", kind: "file",
                              parent_node_id: build.node_id, mtime: 1, size: 1)
    assert_includes @user.nodes.present.visible_entries(false).pluck(:node_id), obj.node_id
  end
```

(Match the file's existing `setup` for `@user`.)

- [ ] **Step 2: run, expect failures.** `bin/rails test test/models/node_test.rb` → FAIL: `Expected ["n-build", …] to not include "n-build"`.

- [ ] **Step 3: the one list.** Create `app/services/library/build_output.rb`:

```ruby
module Library
  # DIRECTORIES WHOSE CONTENTS ARE BUILD OUTPUT — hidden from every listing, and NOTHING ELSE.
  #
  # A DISPLAY RULE, NEVER A SCAN SKIP, AND THE DISTINCTION IS THE ONE §14b IS BUILT AROUND. DO NOT
  # WIRE THIS INTO `Library::Scanner`, `Library::S3Observer`, `FileLayer::Share#observable!` or
  # `FileLayer::S3#observable!`. That is `Library::OsClutter`'s job, and its list is a different
  # list for a different reason: OsClutter names things NO maker put in their library on purpose,
  # so it is safe to make them unobservable AND to refuse them as write destinations, together.
  # These three are the maker's own files. The instant a name becomes unobservable, a live node
  # still pointing there is a ghost the Reconciler can never pair, whose tombstone trips the
  # mass-deletion guard and refuses that scan AND EVERY SCAN AFTER IT, permanently — four wedges
  # so far, each found after the previous explanation said it could not happen.
  #
  # HIDING THE ENTRY, NOT ITS SUBTREE. `Node.visible_entries` filters ROWS BY NAME, so a `main.o`
  # under `build/` is still listed by the flat by-extension view. That is the identical limitation
  # `.git` already carries on chunk_remote and node.rb records: closing it needs a recursive CTE on
  # a page in the hot path, which that comment refuses on cost. What this DOES close is every
  # listing that walks parents — the folder view, the project's Files panel, search — which is
  # where the clutter is actually in the way.
  #
  # GATED ON `show_hidden`, LIKE A DOT-DIR AND UNLIKE `.git`. There is a real reason to open a
  # build directory (a linker map, a generated header), and "Show hidden" is already the way in.
  #
  # THREE NAMES, EXACT AND LOWERCASE — the same exact match `Library::RepoMetadata.marker?` makes.
  # `build` is the C/CMake/PlatformIO convention, `node_modules` npm's, `__pycache__` CPython's.
  # A maker who genuinely names a folder `Build` keeps it, because the match is exact; one who
  # names it `build` gets it hidden and one click from visible. Adding a name here is a change to
  # what every listing shows, so it is a decision, not a net to widen on a hunch — the same
  # sentence OsClutter's SCOPE note makes about Windows clutter.
  module BuildOutput
    NAMES = %w[node_modules __pycache__].freeze

    # Is THIS DIRECTORY's name build output? Callers that already know they hold a directory ask
    # this; `Node.visible_entries` asks the same question in SQL, off the same constant.
    def self.dir?(name) = NAMES.include?(name.to_s)
  end
end
```

- [ ] **Step 4: `Node.visible_entries`.** Replace the scope body:

```ruby
  scope :visible_entries, ->(show_hidden = false) {
    scope = outside_repo_metadata.where.not("name LIKE ?", "%.ptr")
    return scope if show_hidden

    # BUILD OUTPUT JOINS THE DOT-DIRS (stage 4, S4-2; story 4.8) — `Library::BuildOutput` holds the
    # names and the argument, including why it is a display rule and must never reach an observer.
    # WRITTEN AS A POSITIVE `where("NOT (...)")` rather than `where.not(name: …, kind: "dir")`:
    # multi-attribute `where.not` builds a NAND, which is correct here and is exactly the kind of
    # correctness a later reader has to look up. `kind` is NOT NULL (db/schema.rb), so the
    # predicate has no third answer to leak rows through.
    scope.where.not("name LIKE ?", ".%")
         .where("NOT (kind = 'dir' AND name IN (?))", Library::BuildOutput::NAMES)
  }
```

Extend the scope's header comment with one sentence naming the new rule and pointing at `Library::BuildOutput`.

- [ ] **Step 5: run, expect PASS.** `bin/rails test test/models/node_test.rb`.

- [ ] **Step 6: the listing's walk.** In `app/services/maker/project_folder_listing.rb`, add a private predicate beside `working_tree?`:

```ruby
    # THE TWO QUESTIONS EVERY DIR-SKIPPING SITE IN THIS WALK ASKS, ASKED ONCE (stage 4, S4-2).
    # `collect_dirs` and `build_dirs` both had `d.name.start_with?(".")` inline and now both need
    # the build-output rule too — two copies of a two-part rule is three chances to drift.
    # The NAMES themselves live in Library::BuildOutput and nowhere else; this composes, it does
    # not re-list, which is the shape `Library::ReservedNames` already uses for its own union.
    def hidden_dir?(name)
      name.to_s.start_with?(".") || Library::BuildOutput.dir?(name)
    end
```

Replace `next if child.name.start_with?(".")` in `collect_dirs` with `next if hidden_dir?(child.name)`, and `.reject { |d| d.name.start_with?(".") }` in `build_dirs` with `.reject { |d| hidden_dir?(d.name) }`.

Update the class header's sentence "Two rules shape the walk: a dot-prefixed dir is skipped, the same display rule Node.visible_entries applies to entries" to name build output too.

**Note for the reviewer:** the `build_dirs` reject is belt-and-braces — `collect_dirs` already keeps the dir out of `@dir_ids_set`, which `build_dirs` also filters on. Both are kept for the reason the dot rule already keeps both: the two methods are read separately and neither should imply the other.

- [ ] **Step 7: the listing test.** In `test/services/maker/project_folder_listing_test.rb`:

```ruby
    # STORY 4.8: a firmware project's `build/` is not a section, and its objects are not files in
    # the panel's count. Both halves matter — `files_in` reads `visible_entries(false)`, so a dir
    # the walk never enters contributes no files either.
    test "a build directory is neither a section nor counted, while a hidden-looking sibling is" do
      folder = project_folder_rows!(@user, @project)
      build = dir!("d-build", "build", parent: folder.node_id)
      file!("f-obj", "main.o", parent: build.node_id)
      src = dir!("d-src", "src", parent: folder.node_id)
      file!("f-main", "main.cpp", parent: src.node_id)

      listing = Maker::ProjectFolderListing.new(@user, @project)

      assert_equal %w[src], listing.tree.map(&:name)
      assert_equal 1, listing.total
      assert_equal %w[main.cpp], listing.all_rows.map { |r| r.node.name }
    end
```

(Match the file's own `dir!`/`file!` helpers; if it has none, use `@user.nodes.create!(node_id:, name:, kind:, parent_node_id:, size:, mtime:)` directly.)

- [ ] **Step 8: search.** Search reads `visible_entries(false)` already, so it follows for free — **prove it rather than assume it.** In `test/integration/web/search_test.rb`:

```ruby
    # SEARCH EXCLUDES BUILD OUTPUT THE SAME WAY IT EXCLUDES DOT-FILES, because it asks the SAME
    # scope. Driven, not reasoned: the scope is shared, and a future search that stopped calling
    # visible_entries would go red here rather than quietly listing 440 object files.
    test "a build directory is not a search result" do
      @user.nodes.create!(node_id: "s-build", name: "build", kind: "dir", mtime: 1, size: 0)
      get search_path(q: "build")
      assert_response :success
      assert_select ".result-group--file a", text: "build", count: 0
    end
```

and in `test/integration/web/files_search_test.rb`, one case asserting the flat `?q=` view does not list the directory. Both files: match the existing setup idiom.

- [ ] **Step 9: sweep the two comments this falsifies, in this task.**
  - `app/controllers/search_controller.rb`: "`visible_entries(false)` excludes dot-files and the `.git` marker, exactly like a folder view with hidden files off" → add "…and, since stage 4, S4-2, build-output directories (`Library::BuildOutput`)".
  - `app/controllers/library_browse_controller.rb`'s `visible_entries` comment → the same addition.

- [ ] **Step 10: run, expect PASS.** `bin/rails test test/models/node_test.rb test/services/maker/project_folder_listing_test.rb test/integration/web/search_test.rb test/integration/web/files_search_test.rb test/integration/web/library_browse_test.rb test/integration/web/files_test.rb`.

- [ ] **Step 11: mutation checks.**
  1. Drop `.where("NOT (kind = 'dir' AND name IN (?))", …)` from `visible_entries`; run `bin/rails test test/models/node_test.rb test/integration/web/search_test.rb` → FAILS: `Expected [… "n-build" …] to not include "n-build"` and the search case. Restore.
  2. Change `hidden_dir?` back to `name.to_s.start_with?(".")`; run `bin/rails test test/services/maker/project_folder_listing_test.rb` → FAILS: `Expected: ["src"] Actual: ["build", "src"]`. Restore; re-run → PASS.
  3. Change the SQL to `where.not(name: Library::BuildOutput::NAMES)` (dropping the `kind` clause); run `bin/rails test test/models/node_test.rb` → FAILS on "a FILE named build is still visible". Restore. Report all six outputs.

- [ ] **Step 12: commit.**

```bash
git add app/services/library/build_output.rb app/models/node.rb app/services/maker/project_folder_listing.rb app/controllers/search_controller.rb app/controllers/library_browse_controller.rb test/models/node_test.rb test/services/maker/project_folder_listing_test.rb test/integration/web/search_test.rb test/integration/web/files_search_test.rb
git commit -m "Build output is hidden the way dot-directories are, and never skipped by the scan"
```

- [ ] **Step 13: hand Task G its sentence.** `docs/invariants/files-preview.md`'s "Dot-files are a DISPLAY filter, never a scan skip" section describes the complete set of display rules and now omits this one.

---

### Task E: the sweep — board zips, an opt-out, and what it did

**Files:**
- Modify: `app/services/maker/project_intake.rb`, `app/controllers/concerns/project_folder_intake.rb`, `app/controllers/projects/scans_controller.rb`, `app/controllers/projects_controller.rb`, `app/models/maker/project.rb`, `app/views/projects/_form.html.erb`, `app/views/projects/_attachments.html.erb`, `app/assets/stylesheets/pages/projects.css`
- Test: `test/services/maker/project_intake_test.rb`, `test/integration/web/project_folder_intake_test.rb`, `test/integration/web/project_scan_button_test.rb`, `test/integration/web/project_attachments_test.rb`, `test/integration/web/projects_test.rb`, `test/integration/web/template_hygiene_test.rb`

**Depends on Task C** (the three columns). **`_attachments.html.erb` is contended with S4-1's Task B** — take its committed state as the base.

- [ ] **Step 1: the failing board-zip test.** In `test/services/maker/project_intake_test.rb`, add a bytes-writing helper beside `file` and three tests:

```ruby
    # A FIXTURE WITH REAL BYTES AND A REAL SIZE. `file` writes "x"; Maker::GerberArchive refuses a
    # nil size before any read and reads through the port, so a board fixture has to be a real zip
    # on disk with `nodes.size` and `content_hash` matching it (the cache key is the content token).
    def file_with_bytes(name, bytes, parent: @folder.node_id)
      node = file(name, parent:)
      @root.join(node.storage_path).binwrite(bytes)
      node.update!(size: bytes.bytesize, content_hash: Digest::SHA256.hexdigest(bytes))
      node
    end

    def board_zip_bytes = File.binread(Rails.root.join("test/fixtures/files/gerber-export.zip"))

    # STORY 2.8. A `.zip` is `source_archive` BY NAME and that is right for a Printables download.
    # A CAM export is the artefact a fab house is handed, and `archives/` is where it stops being
    # findable next to the board it IS.
    test "a zip the Gerber reader recognises as a board files into pcb, not archives" do
      zip = file_with_bytes("Gerber_lamp.zip", board_zip_bytes)

      assert_equal 1, intake.moved
      assert_equal "pcb", parent_name(zip)
    end

    # THE OTHER HALF, AND WITHOUT IT THE FIRST TEST PASSES FOR A RULE THAT FILES EVERY ZIP INTO
    # pcb/. The read is what tells them apart, and a zip of firmware is cached as not-a-board.
    test "an ordinary zip still files into archives" do
      zip = file_with_bytes("printables_lamp.zip", "PK\x03\x04not-a-board".b)

      intake
      assert_equal "archives", parent_name(zip)
    end

    # THE FOLDER IS THE USER'S OWN, ASKED FOR A LAYER — a board zip files where this maker files
    # `.gbr`, because the zip IS a layer set in a wrapper. Editing the layer rule moves the zip.
    test "the board folder follows the user's own rule for a Gerber layer" do
      Maker::FilingRules.seed!(@user)
      @user.maker_filing_rules.find_by!(ext: "gbr").update!(folder: "boards")
      zip = file_with_bytes("Gerber_lamp.zip", board_zip_bytes)

      intake
      assert_equal "boards", parent_name(zip)
    end
```

- [ ] **Step 2: run, expect failures.** `bin/rails test test/services/maker/project_intake_test.rb -n /board|zip/` → FAIL: `Expected: "pcb" Actual: "archives"`.

- [ ] **Step 3: implement the board rule in `Maker::ProjectIntake` — and NOWHERE ELSE.** Add beside `#folder_for`:

```ruby
    # A BOARD IN A WRAPPER FILES WITH THE BOARD (stage 4, S4-2; story 2.8). `Maker::GerberArchive
    # .for` is the SAME reader the zip's own file page and its thumbnail renderer use, so the
    # sweep and the page cannot disagree about what a board is.
    #
    # NAME FIRST, CONTENT ONLY WHERE THE NAME LEAVES IT OPEN — the ONE place in this class where a
    # filing decision reads bytes, and it is bounded three ways before it does: `archive?` is a
    # name test, so nothing but a `.zip` is ever opened; `.for` refuses a nil size and anything over
    # `GerberArchive::READ_LIMIT` (16 MB) off the catalog's own column BEFORE reading; and the
    # answer is cached by `(node_id, content token)` with NIL CACHED TOO, so a zip of firmware is
    # opened once and stays known-not-a-board until its bytes change. What that costs on the eager
    # path is one bounded read per loose zip, inside caps that already bound it (EAGER_MAX_MOVES 25,
    # or 5 on S3, where a read is a billed GET).
    #
    # AN UNREACHABLE LIBRARY ANSWERS "not a board", because `.for` rescues NotFound/FetchError to
    # nil. That costs nothing: the move that follows raises the same FetchError one line later and
    # #file_all aborts the sweep, so the zip is never filed to the wrong place — it is not filed.
    #
    # A DRY RUN STILL READS. `rake projects:organize DRY_RUN=1` writes nothing, and a bounded,
    # cached read is not a write; the alternative is a dry run that predicts the wrong folder.
    #
    # THE FOLDER IS THE USER'S OWN, ASKED FOR A LAYER. The zip IS a layer set in a wrapper, so
    # "where does this maker file `.gbr`" is the same question, not a new one — and it is why this
    # is not a new kind of rule needing a new kind of row. A maker who has REMOVED that rule gets
    # ROLE_FOLDERS' own `pcb` rather than #folder_for's "other": "other" is the honest answer for
    # an extension nobody has an opinion about, and a board is not that.
    BOARD_LAYER_EXT = "gbr".freeze

    def board_folder_for(node)
      return nil unless Maker::GerberArchive.archive?(node.name)
      return nil unless Maker::GerberArchive.for(user: @user, node:)

      filing_rules.fetch(BOARD_LAYER_EXT, Maker::ProjectFolders::ROLE_FOLDERS.fetch("pcb"))
    end
```

In `#place`, replace `dest = folder_for(node.name)` with:

```ruby
      dest = board_folder_for(node) || folder_for(node.name)
```

- [ ] **Step 4: state the prediction gap where it lives.** `.destination_for` is called BEFORE the bytes exist in the library, so it cannot ask this question and **must not grow a `node:` kwarg no caller can fill**. Add to its comment:

```ruby
    # IT CANNOT ANSWER THE BOARD-ZIP QUESTION, AND THAT IS A PROPERTY OF WHEN IT RUNS. #place asks
    # `Maker::GerberArchive.for` about a node that EXISTS; this method is asked about a file a save
    # is ABOUT to write, so there are no bytes in the library to read and no node to read them
    # from. The one caller (Tools::AddonsController#resolve_placements) writes addon output — SVG
    # and 3MF — so no bundle in this repo or in chaim354/tinkerex-addons can reach the divergence.
    # WHAT KEEPS THE USER-FACING SENTENCE TRUE ANYWAY is Result#conflicts: the flash reports the
    # folder #place ACTUALLY tried, recorded as it tried it, never re-derived from a name here.
```

- [ ] **Step 5: `Result#conflicts` and the sweep stamp.** In `project_intake.rb`:

```ruby
    Result = Data.define(:attached, :moved, :skipped, :skips, :plan, :status, :conflicts) do
      # `conflicts` MAPS A SKIPPED FILE'S NAME TO THE FOLDER #place TRIED, and it exists so a flash
      # can name that folder without re-deriving it (stage 4, S4-2). ProjectFolderIntake used to
      # recompute it from the user's rules, which was right for every file whose destination comes
      # from its NAME and wrong for the one whose destination comes from its CONTENT — a board zip
      # collides in `pcb/` and the sentence said `archives/`.
      #
      # A DEFAULT, so the three construction sites in this file and the three in
      # project_scan_button_test.rb did not have to change — and so a future Result built without
      # it reads as "no conflicts recorded" rather than raising.
      def initialize(conflicts: {}, **) = super
    end
```

`#place`'s Collision rescue becomes:

```ruby
    rescue Maker::MoveNode::Collision => e
      conflicts[node.name] = dest
      skip(node, :conflict, e)
```

with a private reader `def conflicts = @conflicts ||= {}` (`dest` is in scope: it is assigned before `MoveNode.call`, which is the only thing that raises Collision).

`#call` becomes:

```ruby
    def call
      folder = live_folder
      return Result.new(attached: 0, moved: 0, skipped: 0, skips: [], plan: [], status: :no_folder) unless folder

      files = subtree_files(folder)
      attached = attach(files)
      # THE PER-PROJECT OPT-OUT (stage 4, S4-2; story 4.3). ATTACH STILL RUNS, and the asymmetry is
      # the whole design: the attach writes a row and moves no bytes, so "don't file my folder" is
      # a statement about the maker's DIRECTORIES, not about whether the app may know what is in
      # them — the same durable/best-effort split @move already encodes for the cap. Read HERE, in
      # the one method every entry point funnels through (.for_user loops .for_project, .for_node
      # calls .for_project, the rake task and the scan door call .for_project), so no caller has to
      # remember it and a future one gets it for free.
      unless @move && @project.autofile?
        record_sweep!(0)
        return Result.new(attached:, moved: 0, skipped: 0, skips: [], plan: [], status: :ok)
      end

      inbox = full_records(files.select { |n| n.parent_node_id == folder.node_id })
      moved, skipped, skips, plan = LibraryBroadcast.batch(@user) { file_all(inbox) }
      record_sweep!(moved)

      Result.new(attached:, moved:, skipped:, skips:, plan:, conflicts:, status: :ok)
    end
```

and the writer, private:

```ruby
    # WHAT THE LAST SWEEP DID, WRITTEN IN ONE PLACE (stage 4, S4-2; stories 1.5, 4.1). Every path
    # into this class ends in #call, so ONE writer covers the eager nudge, the recurring job, the
    # Scan button and the rake task by construction rather than by four callers remembering — which
    # is the same argument §14f makes for the sweep itself being one reader of `nodes` rather than
    # a hook on each of seven doors.
    #
    # `update_columns`: no validation, no callback, no `updated_at` bump. This runs every 15
    # minutes forever, and touching `updated_at` would make every project look edited on Home,
    # which orders by it.
    #
    # NEVER ON A DRY RUN, and STAMPED EVEN WHEN NOTHING MOVED — including the attach-only paths
    # above. "Swept at T, moved 0" is a fact; a page that shows a line only when the count is
    # positive is the page's decision, not this method's.
    def record_sweep!(moved)
      return if @dry_run

      @project.update_columns(last_swept_at: Time.current, last_sweep_moves: moved)
    end
```

- [ ] **Step 6: the sweep-record and opt-out tests.** In `project_intake_test.rb`:

```ruby
    # ONE WRITER, REACHED FROM EVERY DOOR. Asserted on the COUNT rather than only the timestamp:
    # §15's recorded near-miss is a guard comparing timestamps that were written in the same
    # second, and `last_sweep_moves` is nil until something writes it.
    test "every sweep records what it did, and a dry run records nothing" do
      file("panel.svg")
      assert_nil @project.reload.last_sweep_moves

      Maker::ProjectIntake.for_user(user: @user, dry_run: true)
      assert_nil @project.reload.last_sweep_moves, "a dry run writes nothing, including this"

      Maker::ProjectIntake.for_user(user: @user)
      assert_equal 1, @project.reload.last_sweep_moves
      assert_not_nil @project.last_swept_at
    end

    test "the eager entry point records too" do
      node = file("pocket.nc")
      Maker::ProjectIntake.for_node(user: @user, node:)
      assert_equal 1, @project.reload.last_sweep_moves
    end

    # THE OPT-OUT IS ABOUT FOLDERS, NOT ABOUT KNOWING. Attach is durable and moves no bytes.
    test "autofile off attaches and files nothing" do
      @project.update!(autofile: false)
      node = file("panel.svg")

      result = intake

      assert_equal 1, result.attached
      assert_equal 0, result.moved
      assert_equal @folder.node_id, node.reload.parent_node_id
      assert @project.file_attachments.exists?(node_id: node.node_id)
      assert_equal 0, @project.reload.last_sweep_moves
    end

    # THE CONFLICT'S FOLDER IS RECORDED AS IT HAPPENS, so the flash cannot re-derive it wrongly for
    # the one file whose destination comes from its content.
    test "a conflict records the folder the sweep actually tried" do
      sub = Maker::LibraryFolder.ensure_path!(@user, [ "Projects", @project.slug, "pcb" ])
      file_with_bytes("Gerber_lamp.zip", board_zip_bytes, parent: sub.node_id)
      file_with_bytes("Gerber_lamp.zip", board_zip_bytes)

      result = intake

      assert_equal [ [ "Gerber_lamp.zip", :conflict ] ], result.skips
      assert_equal({ "Gerber_lamp.zip" => "pcb" }, result.conflicts)
    end
```

- [ ] **Step 7: the model, the params and the form.** In `app/models/maker/project.rb`, beside `STATUSES`:

```ruby
    # `autofile` (stage 4, S4-2; story 4.3): may Maker::ProjectIntake MOVE files inside this
    # project's folder? Default true — every project did this before the column existed. Off, the
    # sweep still ATTACHES what it finds; see ProjectIntake#call for why those two halves split.
```

`ProjectsController#project_params`: add `:autofile` to the permit list. In `app/views/projects/_form.html.erb`, after the Cover image block and before `.form-actions`:

```erb
  <%#
    THE SWEEP'S OWN SWITCH (stage 4, S4-2; story 4.3). A checkbox, so `f.check_box` emits the
    hidden "0" field that makes unchecking reach the controller at all — without it an unchecked
    box sends nothing and the attribute never changes.
    NOT A "don't touch my files" MASTER SWITCH: uploads, the addon save door and Move all still
    write where you tell them. This is only the automatic sort of the folder's own root.
  %>
  <label class="field-inline">
    <%= f.check_box :autofile %>
    File loose files into subfolders automatically
    <span class="field-hint muted">Off, the app still lists and links this folder's files — it
      just leaves them where you put them.</span>
  </label>
```

- [ ] **Step 8: the flash says what moved.** In `app/controllers/concerns/project_folder_intake.rb`, replace `project_intake_sentence` and add one helper:

```ruby
  def project_intake_sentence(lead, intake_result, filename)
    if left_unfiled_by_conflict?(intake_result, filename)
      return "#{lead}, but a file of that name is already in " \
             "#{conflict_folder(intake_result, filename)}/, so this one stayed at the project root."
    end

    filed = filed_sentence(intake_result, filename)
    filed ? "#{lead}. #{filed}" : "#{lead}."
  end

  # THE FOLDER THE SWEEP ACTUALLY TRIED. Read off Result#conflicts, which Maker::ProjectIntake
  # #place records as it collides — never re-derived here. The fallback keeps a Result built
  # without the map (a test double, an older caller) reading exactly as it did before.
  #
  # THE RE-DERIVATION WAS RIGHT FOR EVERY FILE WHOSE DESTINATION COMES FROM ITS NAME AND WRONG FOR
  # THE ONE WHOSE DESTINATION COMES FROM ITS CONTENT: a board zip collides in `pcb/` while
  # `folder_for` answers `archives/` (stage 4, S4-2).
  def conflict_folder(intake_result, filename)
    intake_result.conflicts[filename].presence ||
      Maker::ProjectFolders.folder_for(current_user, filename)
  end

  # WHAT THE SWEEP JUST DID, IN THE FLASH (stage 4, S4-2; stories 1.5, 4.1). The sweep moved the
  # maker's file and said nothing, so an upload landed on a page that visibly did not sort and the
  # only record was a log line. READ OFF Result#plan — the [name, folder] pairs #place BUILT AS IT
  # MOVED — so what this names and what the sweep did cannot disagree.
  #
  # THE UPLOADED FILE BY NAME WHEN IT IS THE ONLY ONE, a count otherwise: a save writes a SET, and
  # "Filed 3 files into design/, docs/." is what the maker needs to know to go look. `to_sentence`
  # is ActiveSupport's; the pluralisation is spelled out because `pluralize` is a VIEW helper and
  # this is a controller concern.
  def filed_sentence(intake_result, filename)
    return nil unless intake_result.is_a?(Maker::ProjectIntake::Result)

    plan = intake_result.plan
    return nil if plan.empty?

    mine = plan.find { |name, _folder| name == filename }
    return "Filed #{mine.first} into #{mine.last}/." if mine && plan.size == 1

    folders = plan.map(&:last).uniq.sort.map { |f| "#{f}/" }
    "Filed #{plan.size} file#{"s" unless plan.size == 1} into #{folders.to_sentence}."
  end
```

Extend the concern's header with two sentences: the return value is now read for what it FILED as well as for what it could not, and the conflict folder comes off the Result.

- [ ] **Step 9: the scan door stops saying it twice.** In `app/controllers/projects/scans_controller.rb#scan_notice`, change the populated lead to `"Scanned your library — attached #{result.attached}"` and add:

```ruby
      # THE LEAD NO LONGER COUNTS WHAT WAS FILED — ProjectFolderIntake#project_intake_sentence says
      # it now, with the FOLDERS, which is strictly more than a number. Two doors saying the same
      # fact in two shapes is the drift this method's own comment already refuses.
```

- [ ] **Step 10: the page line.** In `app/views/projects/_attachments.html.erb`, immediately after the `panel-head` `</div>` and before the `<%# A share/s3 scan is a BACKGROUND job … %>` block:

```erb
  <%# WHAT THE SWEEP DID, ON THE PAGE (stage 4, S4-2; story 1.5). Both branches are facts the maker
      needs and neither is an error: a project that files itself says when it last did, and one
      that has been told not to says so where the files are, not only on the edit form. %>
  <% if @project.autofile? %>
    <% if @project.last_sweep_moves.to_i.positive? && @project.last_swept_at.present? %>
      <p class="muted sweep-note">
        Sweep filed <%= pluralize(@project.last_sweep_moves, "file") %>
        · <%= time_ago_in_words(@project.last_swept_at) %> ago
      </p>
    <% end %>
  <% else %>
    <p class="muted sweep-note">
      Automatic filing is off for this project.
      <%= link_to "Turn it on", edit_project_path(@project) %>
    </p>
  <% end %>
```

**No `%>` inside an ERB comment** (§14d's recorded leak). In `app/assets/stylesheets/pages/projects.css`, inside `@layer pages`, append:

```css
  /* --- The sweep's own line (stage 4, S4-2): under the Files head, above the groups. --- */
  .sweep-note { margin: 0 0 10px; font-size: 11px; }
```

- [ ] **Step 11: the request tests.** `test/integration/web/project_attachments_test.rb`:

```ruby
    # STORY 1.5 — the sweep reports on the page, not only to the log.
    test "the Files panel says what the last sweep filed" do
      project_folder_rows!(@user, @project)
      @project.update_columns(last_swept_at: 2.hours.ago, last_sweep_moves: 3)

      get project_path(@project)

      assert_select "p.sweep-note", /Sweep filed 3 files/
      assert_select "p.sweep-note", /2 hours ago/
    end

    test "a sweep that moved nothing says nothing" do
      project_folder_rows!(@user, @project)
      @project.update_columns(last_swept_at: 2.hours.ago, last_sweep_moves: 0)

      get project_path(@project)

      assert_select "p.sweep-note", count: 0
    end

    test "a project with automatic filing off says so where the files are" do
      project_folder_rows!(@user, @project)
      @project.update!(autofile: false)

      get project_path(@project)

      assert_select "p.sweep-note", /Automatic filing is off/
      assert_select "p.sweep-note a[href=?]", edit_project_path(@project)
    end
```

`test/integration/web/projects_test.rb` — **assert the rendered field name** (§14d's twice-shipped `scope:` bug):

```ruby
    test "the form offers the sweep switch and the controller reads it" do
      get edit_project_path(@project)
      assert_select "form.project-form input[name=?][type=checkbox]", "project[autofile]"
      assert_select "form.project-form input[name=?][type=hidden][value=?]", "project[autofile]", "0"

      patch project_path(@project), params: { project: { name: @project.name, autofile: "0" } }
      refute @project.reload.autofile?
    end
```

`test/integration/web/project_folder_intake_test.rb` — the new sentence:

```ruby
    # STORY 4.1: the sweep filed it and the flash says where. The folder comes off Result#plan, so
    # this asserts the SENTENCE and project_intake_test.rb asserts the MOVE; neither stands in for
    # the other.
    test "the flash names the file and the folder the sweep filed it into" do
      # ... upload panel.svg into the project root through the door this file already drives ...
      assert_match(/Filed panel\.svg into design\//, flash[:notice].to_s)
    end
```

`test/integration/web/project_scan_button_test.rb` — the stub at "on chunk_remote the pull runs first" must now carry a plan for its own claim: change `plan: []` to `plan: [ [ "panel.svg", "design" ] ]` and keep `assert_match(/filed 1/i, …)`, which still matches "Filed 1 file into design/." **Report that it matched rather than assuming it** — if it does not, assert `/Filed panel\.svg into design\//` instead.

- [ ] **Step 12: the template sweep renders the new branches.** In `test/integration/web/template_hygiene_test.rb`'s project fixture, stamp the project so the populated branch renders:

```ruby
      @project.update_columns(last_swept_at: 1.hour.ago, last_sweep_moves: 2)
```

Run `bin/rails test test/integration/web/template_hygiene_test.rb` → PASS. (The `autofile: false` branch is the alternative arm of the same `if`; the sweep's coverage assertion is per TEMPLATE, not per branch, so one arm suffices there — the two request tests in step 11 are what cover both.)

- [ ] **Step 13: run everything this touches.**

```bash
bin/rails test test/services/maker/project_intake_test.rb test/integration/web/project_folder_intake_test.rb test/integration/web/project_scan_button_test.rb test/integration/web/project_attachments_test.rb test/integration/web/projects_test.rb test/integration/web/project_upload_attach_test.rb test/integration/web/template_hygiene_test.rb test/integration/web/page_query_budget_test.rb test/jobs/maker/project_intake_job_test.rb
```

- [ ] **Step 14: mutation checks — five.**
  1. `board_folder_for` → `return nil` at the top; run `project_intake_test.rb` → FAILS: `Expected: "pcb" Actual: "archives"`. Restore.
  2. `board_folder_for`'s `.for` check → `return "pcb" if Maker::GerberArchive.archive?(node.name)`; run → FAILS on "an ordinary zip still files into archives". Restore.
  3. Drop `&& @project.autofile?` from `#call`; run → FAILS on "autofile off attaches and files nothing" (`Expected: "Projects/desk-lamp" Actual: "Projects/desk-lamp/design"`). Restore.
  4. `record_sweep!` → `return`; run → FAILS on "every sweep records what it did" (`Expected 1, got nil`) and on the page test. Restore.
  5. `conflict_folder` → drop the `intake_result.conflicts[filename]` arm; run `project_intake_test.rb` and `project_folder_intake_test.rb` → the unit test stays green (it asserts the Result, not the sentence), so **add one request-level case first**: an upload of a board zip that collides in `pcb/`, asserting `/already in pcb\//`, then re-run the mutation and report it going RED. Restore; re-run → PASS. Report all ten outputs.

- [ ] **Step 15: commit.**

```bash
git add app/services/maker/project_intake.rb app/controllers/concerns/project_folder_intake.rb app/controllers/projects/scans_controller.rb app/controllers/projects_controller.rb app/models/maker/project.rb app/views/projects/_form.html.erb app/views/projects/_attachments.html.erb app/assets/stylesheets/pages/projects.css test/services/maker/project_intake_test.rb test/integration/web/project_folder_intake_test.rb test/integration/web/project_scan_button_test.rb test/integration/web/project_attachments_test.rb test/integration/web/projects_test.rb test/integration/web/template_hygiene_test.rb
git commit -m "The sweep files a board where the board is, can be switched off, and says what it did"
```

- [ ] **Step 16: hand Task G its sentences.** `docs/invariants/project-intake.md` needs: the board-zip content rule beside "the sweep decides by name"; the `autofile` opt-out; the one-writer sweep record; and the `destination_for` prediction limit stated as scoped rather than left as a contradiction of "prediction and behaviour cannot disagree". `docs/invariants/files-preview.md`'s "**Filing is untouched**: `zip` stays role `source_archive`, so a Gerber zip loose at a project's ROOT is still filed into the source folder by the intake sweep (the sweep runs before any read and decides by name)" is now **FALSE** and must be rewritten.

---

### Task F: `/settings/filing`, one card per folder

**Files:**
- Modify: `app/controllers/settings/filing_rules_controller.rb`, `app/views/settings/filing_rules/index.html.erb`, `app/assets/stylesheets/pages/settings.css`
- Create: `app/views/settings/filing_rules/_folder_card.html.erb`
- Test: `test/integration/web/settings_filing_test.rb`, `test/integration/web/page_query_budget_test.rb`

**Depends on Task C.**

- [ ] **Step 1: the failing page tests.** In `test/integration/web/settings_filing_test.rb`, REPLACE the two index tests with:

```ruby
    # STORY 4.3: "laser files go to laser/", not 130 extension rows. ONE CARD PER FOLDER, and the
    # folder list is DERIVED from ProjectFolders::ROLE_FOLDERS — a second literal list here is the
    # drift §14d exists to stop, and it would go stale the first time a role is added (S4-2 added
    # one).
    test "the page renders one card per folder, in the seed's own order" do
      get settings_filing_rules_path

      assert_response :success
      assert_select "h1", "Filing"
      folders = css_select(".filing-card .filing-folder").map { |el| el.text.strip.chomp("/") }
      assert_equal Maker::ProjectFolders::ROLE_FOLDERS.values.uniq, folders
    end

    test "each card holds its own extensions as chips" do
      get settings_filing_rules_path

      models = css_select(".filing-card").find { |c| c.at_css(".filing-folder").text.include?("models") }
      exts = models.css(".filing-chip .mono").map { |el| el.text.strip }
      assert_includes exts, ".stl"
      assert_includes exts, ".3mf"
      assert_not_includes exts, ".svg"
    end

    # A FOLDER THE SEED NEVER NAMED STILL GETS A CARD — otherwise a maker who typed `prints` could
    # not see, move or remove the rule they just made.
    test "a custom folder a user's rules name gets a card of its own" do
      Maker::FilingRules.seed!(@user)
      @user.maker_filing_rules.find_by!(ext: "stl").update!(folder: "prints")

      get settings_filing_rules_path

      folders = css_select(".filing-card .filing-folder").map { |el| el.text.strip.chomp("/") }
      assert_includes folders, "prints"
    end

    # ASSERT THE RENDERED FIELD NAMES (§14d). The add form is per CARD and carries its folder as a
    # hidden field, so adding `.lbrn` to `laser/` is one text box; the move control is a SELECT of
    # the folders that exist, which is what removes "typo a folder name" from the move path
    # entirely (the add form still takes free text, which is how a new folder is created at all).
    test "the per-card add form and each chip's move form post what the controller reads" do
      get settings_filing_rules_path

      assert_select "form.filing-add input[name=?]", "filing_rule[ext]"
      assert_select "form.filing-add input[name=?][type=hidden]", "filing_rule[folder]"

      rule = @user.maker_filing_rules.find_by!(ext: "stl")
      assert_select "form[action=?] select[name=?]", settings_filing_rule_path(rule), "filing_rule[folder]"
      assert_select "form[action=?][method=post] input[name=?][value=patch]",
                    settings_filing_rule_path(rule), "_method"
    end
```

Also FIX the now-wrong create test: `"a bad extension is refused"` posts `ext: "kicad_pcb"`, which **is legal since Task C**. Change its param to `ext: "tar.gz"` and keep the `/ext is invalid/` expectation; add a sibling asserting `kicad_pcb` is now ACCEPTED:

```ruby
    test "a KiCad extension is a legal rule now, and files where the form says" do
      post settings_filing_rules_path, params: { filing_rule: { ext: "kicad_sch", folder: "pcb" } }
      assert_redirected_to settings_filing_rules_path
      assert_equal "pcb", @user.maker_filing_rules.find_by!(ext: "kicad_sch").folder
    end
```

(The seeded map already holds `kicad_sch` after Task C, so use `find_or_initialize`-safe wording: seed first, then assert the pre-existing row's folder, or post an ext the seed does not carry. Read the seeded set before writing this one and pick a key that is genuinely absent — `kicad_wks` is a real KiCad extension the seed does not hold.)

- [ ] **Step 2: run, expect failures.** `bin/rails test test/integration/web/settings_filing_test.rb` → FAIL: `Expected exactly 0 elements matching ".filing-card .filing-folder"`.

- [ ] **Step 3: the controller.** Replace `#index` and extend the class comment:

```ruby
    # ONE CARD PER FOLDER SINCE STAGE 4, S4-2 (story 4.3). The flat 130-row table was a correct
    # reference and an unusable page: a maker asks "where does laser work go", and the answer was
    # spread over four screens. Same rows, same routes, same actions — the GROUPING is the change.
    def index
      Maker::FilingRules.seed!(current_user)
      # ONE QUERY, GROUPED IN MEMORY. A card per folder over `where(folder:)` would be eleven-plus
      # queries for a page whose whole content is one small table — page_query_budget_test.rb pins
      # this against N.
      @rules = current_user.maker_filing_rules.order(:ext).to_a
      @by_folder = @rules.group_by(&:folder)
      # DERIVED, NEVER A LITERAL LIST. `ROLE_FOLDERS.values.uniq` is the eleven folders the seed can
      # produce, in the vocabulary's own order (`docs` and `cnc` each answer for two roles and
      # appear once); a folder a maker typed at this very form is appended after them, so a rule
      # they made is always visible somewhere. S4-2 added a role and this line needed no edit.
      @folders = (Maker::ProjectFolders::ROLE_FOLDERS.values + @by_folder.keys).uniq
    end
```

- [ ] **Step 4: the view.** Replace `app/views/settings/filing_rules/index.html.erb`'s list and add form with:

```erb
<div class="filing-cards">
  <%= render partial: "folder_card", collection: @folders, as: :folder,
             locals: { by_folder: @by_folder, folders: @folders } %>
</div>
```

and create `app/views/settings/filing_rules/_folder_card.html.erb`:

```erb
<%#
  ONE FOLDER OF THE PROJECT LAYOUT (stage 4, S4-2; story 4.3): its name, the extensions that file
  into it as chips, a move control per chip and one add form for the card.

  THE MOVE CONTROL IS A SELECT, AND THAT IS WHY IT REPLACED THE FREE-TEXT FIELD. Moving `.dxf` from
  design to laser is a choice among folders that exist; typing the folder name made "dsign" a real,
  silent outcome. Creating a NEW folder is still free text — the add form below — so nothing was
  taken away.

  Locals: folder (the folder name), by_folder (folder to its rules), folders (every folder offered).
%>
<section class="filing-card">
  <h2 class="filing-folder mono"><%= folder %>/</h2>
  <% rules = by_folder[folder] || [] %>
  <ul class="filing-exts">
    <% rules.each do |rule| %>
      <li class="chip filing-chip">
        <span class="mono">.<%= rule.ext %></span>
        <%# scope: :filing_rule and an explicit url: for the reason the flat page already carried:
            Maker::FilingRule's own param_key is "maker_filing_rule", which #update does not read,
            and the path helper for this namespaced resource is settings_filing_rule_path. %>
        <%= form_with model: rule, scope: :filing_rule, url: settings_filing_rule_path(rule),
                      method: :patch, class: "filing-move" do |f| %>
          <%= f.select :folder, options_for_select(folders, rule.folder), {},
                       "aria-label": "Move .#{rule.ext} to another folder" %>
          <%= f.submit "Move", class: "btn ghost small" %>
        <% end %>
        <%= button_to "Remove", settings_filing_rule_path(rule), method: :delete,
                      class: "linkbtn danger small",
                      form: { data: { turbo_confirm: "Remove the filing rule for .#{rule.ext}? " \
                                                      "It will file into other until you add a new one." } } %>
      </li>
    <% end %>
    <% if rules.empty? %>
      <li class="empty muted">Nothing files here yet.</li>
    <% end %>
  </ul>
  <%# scope: :filing_rule names the params at all (no model object); the folder rides as a hidden
      field so adding an extension to this card is one text box. %>
  <%= form_with url: settings_filing_rules_path, scope: :filing_rule, class: "settings-add filing-add" do |f| %>
    <%= f.hidden_field :folder, value: folder %>
    <label>
      <span>Add extension</span>
      <%= f.text_field :ext, required: true, placeholder: "lbrn" %>
    </label>
    <%= f.submit "Add", class: "btn ghost small" %>
  <% end %>
</section>
```

Update the page's intro paragraph to say the folders ARE the subfolders the sweep creates under a project.

- [ ] **Step 5: the CSS.** In `app/assets/stylesheets/pages/settings.css`, inside `@layer pages`:

```css
  /* --- Filing (stage 4, S4-2): one card per FOLDER, replacing the 130-row reference list.
     `.chip` and `.empty` are COMPONENTS and are only QUALIFIED here, never redeclared
     (docs/invariants/design-system.md rule 3; test/css_hygiene_test.rb). --- */
  .filing-cards { display: grid; gap: 14px; grid-template-columns: repeat(auto-fill, minmax(300px, 1fr)); }
  .filing-card { border: 1px solid var(--line); border-radius: var(--radius-panel); padding: 12px; }
  .filing-card .filing-folder { font-size: 13px; margin: 0 0 8px; }
  .filing-exts { list-style: none; padding: 0; margin: 0 0 10px; display: flex; flex-wrap: wrap; gap: 6px; }
  .filing-card .chip { display: inline-flex; align-items: center; gap: 4px; }
  .filing-card .chip form { display: inline; margin: 0; }
  .filing-card select { font-size: 11px; max-width: 110px; }
  .filing-card .settings-add { max-width: none; }
```

- [ ] **Step 6: run, expect PASS.** `bin/rails test test/integration/web/settings_filing_test.rb test/css_hygiene_test.rb test/integration/web/template_hygiene_test.rb`. `/settings/filing` is already in the template sweep's page list, so the new partial's populated branch renders with no fixture edit.

- [ ] **Step 7: the query budget.** In `test/integration/web/page_query_budget_test.rb`, add a case in the file's own idiom:

```ruby
    # ELEVEN CARDS OVER ONE QUERY. The obvious card partial asks `where(folder:)` per card, which is
    # a page whose cost grows with the number of folders a maker invents.
    test "settings/filing does not grow with the number of rules or folders" do
      count = -> { count_queries { get settings_filing_rules_path } }
      Maker::FilingRules.seed!(@user)
      before = count.call
      10.times { |i| @user.maker_filing_rules.create!(ext: "zz#{i}", folder: "folder#{i}") }
      assert_equal before, count.call
    end
```

Match the file's own helper names (`count_queries` or whatever it uses) rather than inventing one.

- [ ] **Step 8: mutation checks.**
  1. In `#index`, replace `@folders = (Maker::ProjectFolders::ROLE_FOLDERS.values + @by_folder.keys).uniq` with a literal `%w[cnc laser design models cad code docs images archives pcb other]`; run `bin/rails test test/integration/web/settings_filing_test.rb` → the order test STAYS GREEN (the literal is today's answer) and the CUSTOM-folder test goes RED: `Expected ["cnc", …] to include "prints"`. Report both — the literal being green on one assertion is exactly why the second exists.
  2. In `_folder_card.html.erb`, replace `by_folder[folder]` with `by_folder.values.flatten`; run → FAILS on "each card holds its own extensions as chips" (`.svg` appears under models). Restore.
  3. In `#index`, change `@rules = …order(:ext).to_a` to a per-card `current_user.maker_filing_rules.where(folder:)` inside the partial; run `page_query_budget_test.rb` → FAILS (grows with folders). Restore; re-run → PASS. Report all six outputs.

- [ ] **Step 9: commit.**

```bash
git add app/controllers/settings/filing_rules_controller.rb app/views/settings/filing_rules/index.html.erb app/views/settings/filing_rules/_folder_card.html.erb app/assets/stylesheets/pages/settings.css test/integration/web/settings_filing_test.rb test/integration/web/page_query_budget_test.rb
git commit -m "Filing settings say where laser work goes, not what 130 extensions do"
```

---

### Task G: the documents this slice falsifies

**Files:** `docs/invariants/files-preview.md`, `docs/invariants/project-intake.md`, `docs/invariants/model-intake.md`

Each edit below is a sentence some earlier task made untrue, or a rule this slice introduced that binds inside one subsystem. Nothing here is new prose for its own sake.

- [ ] **Step 1: `docs/invariants/files-preview.md` — the vocabulary section.** Add a paragraph after the "STAGE 3, S3-1" block:

> **STAGE 4, S4-2: THE BENCH'S OWN THREE, AND A ROLE THAT IS NOT A FOLDER.** `mage`, `lbrn` and `ai` joined `ROLE_BY_EXT`; all three had a page and no role, so all three filed into `other/`. `mage` carries a NEW role, `cnc_design`, that shares the `cnc/` folder with `gcode` — two roles, one directory, the shape `instructions`/`document` already had for `docs/`. A role is also what `Maker::ModelIntake::EXCLUDED_ROLES` denies a model, which is why a new role must be added there in the same change: the list is a DENYLIST, so a new role joins models by default and the omission is silent.

- [ ] **Step 2: `files-preview.md` — the `.ai` renderer.** Add after the `pdf` mention:

> **`.ai` IS REGISTERED BY NAME AND REFUSED BY CONTENT, THE SECOND RENDERER TO WORK THAT WAY** (the first is `GerberZip`). `Maker::Previews::Pdf::EXTENSIONS` is `%w[pdf ai]`, and `render` raises `GeneratePreviewJob::Unsupported` unless the bytes begin `%PDF-`. Illustrator's "Create PDF Compatible File" has been the default for two decades, so an `.ai` off a maker's disk is a PDF with Illustrator's own stream appended; one saved without it is PostScript and pdfium cannot open it. `unsupported`, never `failed`: `failed` is what `Enqueue` treats as "retry me", so the wrong choice re-renders forever behind an error badge. The check is on the BYTES, so a `.pdf` that is not a PDF gets the same terminal state. `preview_kind` answers `:thumbnail` for `.ai`, not `:pdf` — the `:pdf` branch hands the bytes to the browser's own viewer, which downloads a file named `.ai` instead of rendering it.

- [ ] **Step 3: `files-preview.md` — the `:kicanvas` section.** After "Adding one anyway would render a filter chip that links and does nothing", add:

> **THEY CAN CARRY A FILING RULE, THOUGH, AND SINCE STAGE 4, S4-2 THEY DO.** `Maker::FilingRule::KEY_RE` (`/\A[a-z0-9_]{1,12}\z/`) is the filing map's own key rule and is WIDER than `EXT_RE` on purpose: a rule renders no chip and grants no role, it answers one question — which subfolder — so it can be keyed by something the vocabulary cannot hold. `kicad_sch`/`kicad_pcb` are seeded to `pcb` (`Maker::FilingRules::BEYOND_ROLE_BY_EXT` for a new user, `db/migrate/20260907120100` for an existing one). Their ROLE stays `other`, and that is not a gap: role and destination are two questions, the same split `.scad` carries (`cad_source` for filing, text for viewing). `EXT_RE` is untouched and still bounds `ROLE_BY_EXT`.

- [ ] **Step 4: `files-preview.md` — the Gerber-zip filing sentence is FALSE.** Replace "**Filing is untouched**: `zip` stays role `source_archive`, so a Gerber zip loose at a project's ROOT is still filed into the source folder by the intake sweep (the sweep runs before any read and decides by name), while one already in a subfolder is never moved — a content-aware refiling is a separate decision." with:

> **FILING IS CONTENT-AWARE FOR THIS ONE CASE SINCE STAGE 4, S4-2, AND FOR NOTHING ELSE.** `zip` keeps the role `source_archive` — the vocabulary is still name-only — but `Maker::ProjectIntake#place` asks `Maker::GerberArchive.for` about a `.zip` at a project root and files a board into the maker's `pcb` folder (their own rule for `.gbr`, since the zip IS a layer set in a wrapper) instead of `archives/`. Bounded exactly as the page's own read is: name test first, `READ_LIMIT` judged on the catalog's `size` column before any read, the answer cached by `(node_id, content token)` with nil cached. A zip already in a subfolder is still never moved — root = inbox is unchanged. `Maker::ProjectIntake.destination_for` CANNOT answer this: it is asked about a file a save is about to write, so there are no bytes to read; its one caller writes addon output (SVG, 3MF), and what keeps the user-facing sentence true regardless is `Result#conflicts`, which records the folder `#place` actually tried.

- [ ] **Step 5: `files-preview.md` — the display-filter section.** After the `.git` paragraph, add:

> **BUILD OUTPUT IS THE THIRD DISPLAY RULE (stage 4, S4-2; story 4.8).** `Library::BuildOutput::NAMES` — `build`, `node_modules`, `__pycache__` — hides those DIRECTORY entries, gated on `show_hidden` exactly like a dot-dir and unlike `.git`/`*.ptr`. Never an observer skip and never a write guard: that is `Library::OsClutter`'s list, for names no maker put in their library on purpose, and making one of these unobservable is the §14b wedge a fifth time. It hides the ENTRY, not the subtree — a `main.o` under `build/` is still a row in the flat by-extension view, the identical limitation `.git` carries on chunk_remote. One list, read by `Node.visible_entries` in SQL and by `Maker::ProjectFolderListing#hidden_dir?` in memory.

- [ ] **Step 6: `docs/invariants/project-intake.md` — four additions to the Filing section.**
  - Beside the "ROOT = INBOX" bullet: the board-zip content rule, its three bounds, why the folder comes from the user's `.gbr` rule, and that an unreachable library answers "not a board" harmlessly because the move raises one line later.
  - A new bullet for `autofile`: read in `#call` — the one method every entry point funnels through — and ATTACH STILL RUNS, because the attach writes a row and moves no bytes; the opt-out is a statement about the maker's directories.
  - A new bullet for `last_swept_at`/`last_sweep_moves`: ONE writer at the end of `#call`, `update_columns` (no `updated_at` bump — Home orders by it), never on a dry run, stamped even at zero moves because "swept, moved nothing" is a fact the page then chooses not to show.
  - Extend the "A CALLER MUST READ `intake_project_folder`'S RETURN VALUE" bullet: the three doors now read `plan` for what was FILED as well as `skips` for what was not, and the conflict folder comes off `Result#conflicts` rather than a re-derivation — the re-derivation was right for every file whose destination comes from its name and wrong for the one whose destination comes from its content.

- [ ] **Step 7: `docs/invariants/model-intake.md`.** Its `EXCLUDED_ROLES` bullet lists the excluded roles by name; add `cnc_design` with its one-line reason ("a MillMage project is a 2D cut job that merely shares a folder with a mesh — `laser`'s own argument") and the note that a new role joins models BY DEFAULT, so the addition belongs in the change that adds the role.

- [ ] **Step 8: the hygiene gate.** `bin/rails test test/docs_hygiene_test.rb` → PASS (each `docs/invariants/*` file still has its §14 stub, and CLAUDE.md is untouched by this slice — **nothing here belongs in CLAUDE.md**: all of it binds inside one subsystem, which is what the area files are for).

- [ ] **Step 9: commit.**

```bash
git add docs/invariants/files-preview.md docs/invariants/project-intake.md docs/invariants/model-intake.md
git commit -m "The invariants say what filing, previews and the display rules now do"
```

---

### Task H: close-out

- [ ] **Step 1: re-tag the stories** in `docs/user-stories.md` (S4-1's close-out is editing this file too — read it fresh, and change only these rows):
  - **2.3 `.ai`** → `rough`. New evidence: role `vector` → files into `design/`; a thumbnail through pdfium when the bytes are a PDF (S4-2). Remaining friction: an `.ai` saved without PDF compatibility has no preview at all, and there is no in-browser vector view.
  - **2.4 `.mage`** → `works`. New evidence: role `cnc_design` → `cnc/` (S4-2), beside the Measure view and the CNC operations panel it already had.
  - **2.8 KiCad + Gerbers** → `rough`. New evidence: `kicad_sch`/`kicad_pcb` carry a filing rule (`KEY_RE`) and file into `pcb/`; a Gerber zip the archive reader recognises files into `pcb/` too (S4-2). Remaining: their ROLE is still `other`, so the type filter cannot offer a KiCad chip and never will (`EXT_RE`).
  - **4.1 files land where I chose, and I am told** → `works`. New evidence: the eager flash names the file and the folder off `Result#plan`, and the project page's Files panel says what the last sweep filed (S4-2).
  - **4.3 Settings → Filing** → `rough`. New evidence: one card per folder, chips per extension, a move select and a per-card add (S4-2). Remaining: rules are still per USER, never per project (spec §9 defers that until this page shows whether one map is still too many).
  - **4.8 build output** → `rough`. New evidence: `build/`, `node_modules/` and `__pycache__/` are hidden beside the dot-dirs, excluded from the folder view, the project panel and search (S4-2). Remaining, and stated so it is not read as done: the files INSIDE them are still indexed and still appear in the flat by-extension view — the same recorded limitation `.git` carries — and nothing is un-indexed, by design (§14b).
  - **1.5 the app says what it did** → stays `missing`. The filing half landed (S4-2: the flash names moves, the page shows the last sweep); discovery's feedback, the "new" marker and the current-project switch confirmation are S4-6.
  - **4.2** stays `missing` — re-filing already-placed files on a rule change is a move the sweep must not make unasked (spec §9). Say so in the row rather than leaving it unexplained now that the rules page invites edits.
  - Update the Coverage table's counts to match.

- [ ] **Step 2: the overview.** In `docs/superpowers/plans/2026-09-07-stage-4-00-overview.md`, mark the S4-2 row landed with the PR number, and correct the Territory section's S4-2 file list where this plan diverged from it: the board rule lives in `Maker::ProjectIntake`, not in `Maker::ProjectFolders`; the display rule is a new `Library::BuildOutput` plus `Node.visible_entries` and `Maker::ProjectFolderListing`, and `search_controller.rb` needed only a comment because it already reads the shared scope.

- [ ] **Step 3: the gates.**

```bash
TINKEREX_SYNC_DIR=/Users/charlesschwartz/Desktop/repos/tinkerex-sync bin/ci
```
Green on all gates `bin/ci --list-ci` names. **Report the three legs' run counts side by side** — `test` (share), `test-s3`, `test-chunk-remote` — and confirm they are identical. A ±2 assertion / ±1 skip flap is the known nondeterminism (`tinkerex#131`); a structural difference means a test depends on the ambient `LIBRARY_BACKEND` and is a real bug in this slice. The two places that could produce one here: `project_intake_test.rb` pins its own share library (so it is leg-independent by construction — confirm the new board-zip tests inherit that setup and do not reach `FileLayer.current` themselves), and any upload-control assertion must branch on `port_writable?` (memory: `upload-form-assertions-must-branch-on-port-writable`) — the `autofile` form test does not touch the upload control, so it should not need one; verify rather than assume.

- [ ] **Step 4: commit, push, PR, record.**

```bash
git commit -m "S4-2 close-out: the stories re-tagged, the overview updated"
```
then `/finish-branch`, then `bin/log arc --from-pr <n>`. The PR body states what was verified (the three legs, every mutation check with its output) and what was not (see the open questions below).

---

## Self-review against the spec (§5's S4-2 row and §7)

| spec item | task |
|---|---|
| roles for `.mage` (`cnc_design` → `cnc/`), `.lbrn` (`laser`), `.ai` (`vector`) | A steps 3–6 |
| `EXCLUDED_ROLES` gains the new role, with a case that can fail | A steps 7, 11(2) |
| `EXT_FAMILIES` / filter chips follow automatically; the tests that pin the chip set | A steps 8, 10 (`files_helper_test.rb` is derived; `file_attachment_test.rb`'s `EXT_RE` loop covers the three new extensions) |
| a data migration seeds the new keys for already-seeded users, never overwriting an edit | C steps 9, 11 (`insert_all(unique_by:)`; users with no rows skipped) |
| `.ai` previewed through pdfium; non-PDF bytes are `unsupported`, not `failed` | B steps 3–4 (the refusal is in `render`; `available?` has no bytes — stated) |
| `Maker::FilingRule::KEY_RE` replaces the `EXT_RE` check so KiCad can be keyed, seeded to `pcb` | C steps 3, 6 |
| the sweep derives the same key (`ext_of` → `kicad_sch`, probed) | Before-you-start; C step 5's assertion through `Maker::ProjectFolders.folder_for` |
| a board zip files into `pcb/`, bounded, one read per loose zip per sweep, caps intact | E step 3 |
| the flash's prediction agrees with the move | E steps 4, 5, 8 (`Result#conflicts` for a collision, `Result#plan` for a move — recorded, never re-derived) |
| `/settings/filing` one card per folder, chips, per-card add, move select, every route kept | F steps 3–5 |
| existing `settings_filing_test.rb` assertions kept where they still describe behaviour | F step 1 (create/update/destroy and the two cross-tenant guards untouched; the two index tests and the `kicad_pcb`-is-invalid test rewritten) |
| `maker_projects.autofile`, default true; the sweep skips a project with it off; attach still runs | C step 8, E steps 5, 7 |
| `last_swept_at` + `last_sweep_moves` written by every sweep path from ONE writer | E step 5 (`record_sweep!` at the end of `#call`, the one method every entry point funnels through) |
| the project page shows "Sweep filed N files · <time ago>" when the count is positive | E step 10 |
| the eager flash names the moves, extending the concern's sentence builder | E step 8 |
| build output hidden as a DISPLAY rule, one predicate, never a scan skip; counts and search follow | D steps 3–8 |
| every template comment and invariants sentence the changes falsify is fixed in this PR | A 5, D 9, and G |
| migrations run in dev AND test, `db/schema.rb` committed | C step 10 |
| `page_query_budget_test.rb` constant in N for every page touched | F step 7 (`/settings/filing`); `projects#show` gains no query — E adds only reads off the loaded record |
| the template sweep renders every new branch | E step 12, F step 6 |
| a new column's guard obligations checked | C step 8 (no index, so the prefix guard is untouched; the four new-TABLE guards are N/A — no table is added) |
| close-out re-tags the stories and marks the overview row | H |

## Open questions the implementer must not decide alone

1. **`build/` is a plausible folder a maker named themselves.** The three names come from the spec, the match is exact and lowercase, and "Show hidden" reveals them — but a maker who keeps assembly photos in `Projects/lamp/build/` loses sight of that folder on their own project page, where there is no "Show hidden" control at all (`ProjectFolderListing` always passes `false`). If that is judged unacceptable, the fix is a `show_hidden` pass-through on the project panel, not a shorter list — raise it rather than quietly dropping `build`.
2. **Whether `/settings/filing`'s move control should be a select per chip at all.** It renders one small form per rule (about 135 on a seeded user), which is the same form count the flat page already had, with a `<select>` where a text field was. If the page feels heavy in a browser, the alternatives are a `<details>` per card or a Stimulus-driven single form — both need a decision, and a new Stimulus controller must exist before any template names it (§14d; a `data-controller` that resolves to nothing is a silent no-op).

**Stated limits, decided rather than open** — do not reopen them mid-implementation, but do report them in the PR body: `Maker::ProjectIntake.destination_for` stays name-only and cannot predict a board zip (no bytes exist when it is asked; its one caller writes SVG and 3MF); the build-output rule hides the entry and not its descendants, the same limitation `.git` carries; and a board zip's destination follows the maker's own `.gbr` rule, falling back to `ROLE_FOLDERS`'s `pcb` rather than to `"other"` when that rule has been removed.
