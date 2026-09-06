# Gerber previews with tracespace — implementation plan

> **For agentic workers:** execute per `.claude/commands/execute-plan.md`. Steps use checkbox
> (`- [ ]`) syntax. One implementer (the slice is one coherent unit), one capped review.

**Goal:** a Gerber or Excellon drill file renders in the browser on its file page, and a project
folder holding a board's layer set gets a **Fabrication** panel on the private and the public page
with the layers listed and the board rendered as a stackup (top and bottom), with no server-side
renderer and no sidecar.

**Architecture:** the KiCanvas pattern exactly (`docs/invariants/files-preview.md`, S3-2): ONE
vendored build from a pinned npm version (`bin/build-tracespace` → `vendor/javascript/tracespace.js`
+ `LICENSE-tracespace.md`), one importmap pin with `preload: false`, a Stimulus controller that
dynamic-imports it only on a page that holds a Gerber, bytes fetched through the SAME routes the
page already links (the named blob route privately, the public file route publicly — the library
keys on the URL's trailing extension like KiCanvas does). A new file role, `pcb`, files the layer
set into a `pcb/` folder; existing users get the new rules through a data migration, never a
re-seed (removing a rule must stay "files into other" — the settings page promises it).

**Tech:** tracespace (MIT). Two candidates, in order of preference — the implementer probes and
picks the first that bundles and renders the fixture: **`@tracespace/core@5.0.0-alpha.0`**
(browser-native: `read(files)` → `plot` → `renderLayers` / `renderBoard`, no Node streams), else
**`pcb-stackup@4.2.8`** (stable v4, bundles `gerber-to-svg` + `whats-that-gerber`; needs the
`buffer`/`process` shims this app already vendors for JSZip, and esbuild with
`--platform=browser`). Either way the bundle is esbuild output from the pinned version, the
CodeMirror/KiCanvas rule: no npm package at runtime, no CDN.

---

## Task A — the whole slice

**Files:**
- Create: `bin/build-tracespace`, `vendor/javascript/tracespace.js`, `vendor/javascript/LICENSE-tracespace.md`
- Modify: `config/importmap.rb` (pin + `preload: false`), `app/models/maker/file_attachment.rb`
  (`ROLE_BY_EXT` gains the Gerber set under a new role `pcb`; `ROLE_FOLDERS` gains `"pcb" => "pcb"`),
  `app/controllers/files_controller.rb` (`GERBER_EXTS` beside `KICANVAS_EXTS`, `:gerber` in
  `preview_kind` — read the KiCanvas comment there first: the KiCad extensions live OUTSIDE
  `ROLE_BY_EXT` because they fail `EXT_RE`; the Gerber ones PASS it, so they go IN `ROLE_BY_EXT`
  with their role, and `GERBER_EXTS` is derived from it, never a second list), `app/helpers/files_helper.rb`
  (`gerber?`), `app/views/files/show.html.erb` (a `:gerber` branch), `app/views/projects/show.html.erb`
  + a new `app/views/projects/_fabrication.html.erb`, `app/views/public/projects/show.html.erb` + a new
  `app/views/public/projects/_fabrication.html.erb`, `app/services/maker/public_project.rb`
  (`gerber_rows`, `gerber_sets`), `app/assets/stylesheets/pages/preview.css` (`.gerber-stage`),
  `app/assets/stylesheets/pages/projects.css` (the panel), `docs/invariants/files-preview.md`
  (a paragraph beside the `:kicanvas` one), `docs/invariants/project-intake.md` (the role)
- Create: `app/javascript/controllers/gerber_controller.js`, a data migration
  `db/migrate/<ts>_seed_pcb_filing_rules.rb`, `test/support/gerber_fixture.rb`,
  `test/system/gerber_test.rb`, `test/integration/web/gerber_preview_test.rb`,
  `test/controllers/files_controller_preview_kind_test.rb` (cases), `test/models/maker/filing_rule_seed_test.rb`
  or the existing filing-rules test (the migration's top-up)

### A.1 The build

`bin/build-tracespace`, modelled on `bin/build-kicanvas` (read it): a temp dir, `npm init -y`,
`npm install --silent <package>@<pinned version> esbuild@<pinned>`, an entry file
`entry.js` that re-exports what the controller needs, `npx esbuild entry.js --bundle --format=esm
--platform=browser --minify --outfile=$ROOT/vendor/javascript/tracespace.js`, the package's LICENSE
copied to `vendor/javascript/LICENSE-tracespace.md` with the package name and version written at
the top, and a size line printed. For v5 core the entry is:

```js
export { read, plot, renderLayers, renderBoard, stringifySvg } from "@tracespace/core"
```

(verify the export names against the installed package's `package.json`/`README`; the v5 API
renders to an SVG DOM/JSON that `stringifySvg` turns into a string — if the names differ, use
what exists and record it in the build script's comment). For v4 the entry is
`export { default as pcbStackup } from "pcb-stackup"; export { default as gerberToSvg } from "gerber-to-svg"`
with `--alias:buffer=buffer --alias:process=process` pointing at the app's shims if esbuild needs
them (probe; the vendored shims live under `vendor/javascript/`).

Pin: `pin "tracespace", to: "tracespace.js", preload: false # bundle: see bin/build-tracespace for the pinned version`
with a comment in `config/importmap.rb` beside KiCanvas's saying it is dynamic-imported by
`gerber_controller.js` only.

### A.2 The vocabulary

`ROLE_BY_EXT` gains, under the role `"pcb"`:
`gbr gtl gbl gts gbs gto gbo gtp gbp gko gm1 gm2 gm3 gp1 gp2 g1 g2 g3 g4 gd1 gg1 drl xln gbrjob`
(all ≤ 8 alphanumerics — they satisfy `EXT_RE`; say so in the comment). `ROLE_FOLDERS` gains
`"pcb" => "pcb"`. `Maker::FileAttachment` may carry a role→label table too (read the file: the
`ROLE_LABELS`/panel headings for "Images" etc. at the top) — add `"pcb" => "PCB"`. Grep every
consumer of the role list (`ROLE_FOLDERS.fetch`, the filing seed, `project_folders_test`,
`filing_rules_test`, the settings filing page's expected row count, `tenant_cleanup`? no) and
update the counts they assert: `docs/invariants/project-intake.md` says "the eleven roles" — it is
twelve now; fix the prose where it counts.

`FilesController::GERBER_EXTS = Maker::FileAttachment::ROLE_BY_EXT.select { |_, r| r == "pcb" }.keys.freeze`
and `preview_kind` returns `:gerber` for them (before `:text`, after `:kicanvas`; a `.gbrjob` is
JSON text but it is the board's manifest, so it is `:gerber` too and renders the stackup).
`FilesHelper#gerber?(name)` reads `GERBER_EXTS`.

### A.3 The data migration — existing users get the `pcb` rules once

```ruby
class SeedPcbFilingRules < ActiveRecord::Migration[8.1]
  # A NEW ROLE'S RULES REACH EXISTING USERS ONCE, HERE — never by re-seeding on read.
  # Maker::FilingRules.seed! is guarded by `exists?` on purpose: /settings/filing promises that a
  # removed rule "will file into other until you add a new one", and a top-up on every read would
  # resurrect it. A migration runs exactly once, so a rule removed AFTER it stays removed.
  # Users with NO rules yet are skipped: their first read seeds the full table, pcb included.
  def up
    exts = Maker::FileAttachment::ROLE_BY_EXT.select { |_, role| role == "pcb" }.keys
    now = Time.current
    User.where(id: Maker::FilingRule.select(:user_id)).find_each do |user|
      rows = exts.map { |ext| { user_id: user.id, ext:, folder: "pcb", created_at: now, updated_at: now } }
      Maker::FilingRule.insert_all(rows, unique_by: %i[user_id ext])
    end
  end

  def down = Maker::FilingRule.where(folder: "pcb").delete_all
end
```

Check the unique index name/columns on `maker_filing_rules` for `unique_by:`. A model test pins:
a user seeded BEFORE (rows without pcb) gains the pcb rows after `up` and keeps their edited
`stl` folder; a user with no rows gets nothing from the migration and everything from `seed!`.
Run the migration on the dev DB and the test DB (`RAILS_ENV=test bin/rails db:prepare`); no
schema change, so `docs/schema-map.html` is untouched (confirm with `bin/rails schema:map` and
`test/schema_map_test.rb`).

### A.4 The controller — `gerber_controller.js`

```js
import { Controller } from "@hotwired/stimulus"

// ONE GERBER, OR A BOARD. `layers` is a JSON list of {name, url} the SERVER rendered — the set of
// files that make up this board (every pcb-role file in the same folder, or the .gbrjob's own
// list when one is present); `single` is true on a file page, where only that file renders.
// tracespace is dynamic-imported here and nowhere else, so no page without a Gerber pays for it
// (the KiCanvas rule; config/importmap.rb pins it preload: false). Bytes come through the same
// routes the page links (files-preview.md): the library keys the layer TYPE off each file's name.
export default class extends Controller {
  static targets = ["stage", "status", "side"]
  static values = { layers: Array, single: Boolean }

  async connect() {
    try {
      const ts = await import("tracespace")
      const files = await Promise.all(this.layersValue.map(async (l) => {
        const res = await fetch(l.url)
        if (!res.ok) throw new Error(`${l.name}: ${res.status}`)
        return { name: l.name, text: await res.text() }
      }))
      this.render(ts, files)
      this.element.dataset.gerberState = "ready"
    } catch (e) {
      this.element.dataset.gerberState = "failed"
      if (this.hasStatusTarget) this.statusTarget.textContent = "The viewer could not load."
    }
  }
  // render(ts, files): v5 — read → plot → (single ? renderLayers : renderBoard) → stringifySvg
  // into stageTarget.innerHTML for the chosen side; a Top/Bottom toggle (sideTarget buttons)
  // swaps the side without refetching. v4 — pcbStackup(layers) → {top, bottom}.svg.
  // The SVG must fit the stage: set width/height 100% and preserveAspectRatio on the root.
}
```

The exact render code depends on the package chosen; write it against the installed API and
pin it with the system test below, which is the only thing that can prove it renders.

### A.5 The surfaces

File page (`files/show.html.erb`, a `:gerber` branch beside `:kicanvas`): a `div.gerber-stage`
with `data-controller="gerber"`, `data-gerber-single-value="true"`, and
`data-gerber-layers-value` = `[{ name: @node.name, url: named_blob_file_path(@node.node_id, filename: @node.name) }].to_json`
— for a `.gbrjob`, the layers are the job's listed files that exist in the same folder (parse the
JSON server-side: `FilesAttributes[].Path`, matched by name among the folder's siblings), and the
page renders the stackup. A `p.muted[data-gerber-target=status]` "Loading the viewer…" and a
Top/Bottom pair of `.btn.small` buttons (`data-action="gerber#top"` / `gerber#bottom`) shown only for
a stackup.

Project page (`projects/_fabrication.html.erb`, rendered after Schematics): `Maker::PublicProject`-
style grouping lives in a small service both pages share — `Maker::GerberSets.for(rows)` in
`app/services/maker/gerber_sets.rb`: group the pcb-role rows by parent dir; within a dir, if a
`.gbrjob` exists, its listed files are the set (others in the dir are listed but not stacked);
else every pcb file in the dir is one set. Returns `[Set(dir_path, name, rows)]`. The panel
lists each set's files (name + a layer badge from the extension: `gtl` top copper, `gbl` bottom
copper, `gts`/`gbs` solder mask, `gto`/`gbo` silkscreen, `gko`/`gm1` outline, `drl`/`xln` drill,
`gbrjob` job, else "gerber") and renders ONE stackup per set (`data-gerber-layers-value` with the
private named blob URLs). Public: the same partial shape under `app/views/public/projects/`, URLs
from `pub.file_url_for(node_id, filename:)` (carrying `k`), only for rows `pub.permits?` — the
rows come from the listing, which is permitted by construction, so no per-row check. Omitted
when the folder holds no Gerbers, like Schematics.

CSS: `.gerber-stage` like `.kicanvas-stage` (min-height 320px, `70vh` in `.preview`), the SVG at
100%; the panel's list like `.schematics-list`; the side toggle inline.

### A.6 Tests

- `test/support/gerber_fixture.rb`: a MINIMAL but real RS-274X layer (a `%FSLAX24Y24*%`,
  `%MOMM*%`, one aperture `%ADD10C,0.5*%`, a few `D02`/`D01` moves drawing a rectangle, `M02*`)
  as `MINIMAL_GERBER`, a minimal Excellon drill (`M48`, `METRIC`, `T1C0.8`, `%`, `T1`, `X10Y10`,
  `M30`) as `MINIMAL_DRILL`, and `write_gerber!(name:, parent_node_id: nil, body:)` in
  `KicadFixture`'s shape (real bytes under `@root`).
- `test/system/gerber_test.rb` (mirrors `kicanvas_test.rb`): a `.gtl` file page reaches
  `.gerber-stage[data-gerber-state='ready']` and holds an `svg` with at least one path; a folder
  with `.gtl`+`.gbl`+`.drl` on the project page renders the Fabrication panel's stackup to
  `ready`, and the Bottom toggle swaps the SVG (assert the stage's innerHTML changes); no console
  errors (`ignoring: [ KICANVAS_PLACEHOLDER_FETCH ]` only if a schematic is on the page — none
  here). The public page too, signed out, on a public project.
- `test/integration/web/gerber_preview_test.rb`: `preview_kind` cases (`gtl` → `:gerber`, `gbrjob`
  → `:gerber`, `txt` untouched); the file page renders the stage with the named blob URL and
  `single=true`; a `.gbrjob` page's layers are its listed siblings and nothing else; the project
  panel groups by folder and by job; the public panel's URLs carry `k` for an unlisted project; the
  intake files a loose `.gtl` into `pcb/` for a NEW user (seeded) and for an EXISTING user after the
  migration's top-up (drive `SeedPcbFilingRules.new.up` on a user seeded from a `ROLE_BY_EXT`
  with pcb removed — or simply insert their old rows by hand — and assert `folder_for`).
- Guards: `template_hygiene_test.rb` pages render both new partials populated (seed a Gerber set
  in its setup); `stimulus_hygiene_test.rb` (`gerber` matches the filename); `css_hygiene_test.rb`;
  `page_query_budget_test.rb` — the panel's grouping must be constant in N (rows are already in
  memory; no query per row); the phone sweep visits the project page — put a Gerber set in its
  project folder so the panel renders at 375px (the stackup SVG must scale, not overflow).
- Mutations, each with actual output: `preview_kind` → `:text` for `gtl` (the file page test);
  the job's list ignored (every pcb file in the dir stacked) → the `.gbrjob` test; `preload:
  false` dropped → `lazy_bundles_test.rb` gains `tracespace` in its `LAZY` list first; the
  migration's `unique_by:` dropped → the top-up test on a user who already has one pcb row raises;
  a wrong module name in the controller → the system test's `ready` assertion.

Commit with pathspecs. Run the new files plus `files_flow_test.rb`, `project_page_test.rb`,
`public_project_test.rb`, `project_folder_intake_test.rb`, `filing_rules` tests, the four hygiene
guards, `lazy_bundles_test.rb`, `test/system/shell_test.rb`, and rubocop.

---

## Self-review

- No server renderer, no sidecar: gerbv (GPL) is not used; thumbnails for Gerber files stay the
  extension badge (files-preview.md's `/files/thumbnails` rule needs no change: no renderer is
  registered, so the poll answers "unsupported").
- The s3 deployment's cross-origin fetch applies to these fetches as to KiCanvas's (S3-2's shared
  follow-up); say so in the controller and the PR.
- Licences: tracespace MIT (and its deps: `whats-that-gerber` MIT, `gerber-parser` MIT,
  `gerber-plotter` MIT); the LICENSE file ships beside the bundle.
