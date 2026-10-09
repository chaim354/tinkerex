# Redesign slice 7 — cleanup — Implementation Plan

> **For agentic workers:** in this repo, execute with **`.claude/commands/execute-plan.md`** (CLAUDE.md
> §15: batched by file, parallel where independent, one capped quality review per task). It
> overrides the generic superpowers subagent loop. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** finish the redesign.
- Drop the two current-project columns slice 4 retired.
- Give phones the single "+" the spec promised.
- Take the last emoji out of the interface, with a guard so none comes back.
- Fix three visual nits noted along the way.
- Clear the stale comments the earlier slices left.

**Architecture:** five independent cleanups, plus the record.
- The column drop is a reversible `remove_column` migration in the house style. The architecture
  guard keeps forbidding the names, minus the exemption that only existed for `ignored_columns`.
- The phone "+" is a phone-only "Upload…" item in the New menu. It forwards a click to the real
  top-bar upload label, so the chooser on a page with no folder still runs. No upload logic moves.

**Tech Stack:** Rails 8, Hotwire (one new Stimulus controller), Minitest request and system tests.

**Spec:** `docs/superpowers/specs/2026-10-08-structural-redesign-design.md`:
- §4.3: the phone row is "breadcrumb and one '+' (New and Upload)".
- §9.1: "the columns stay for one release … then dropped by a later migration".
- §11: slice 7.
- Slice 4's amendment 7 deferred the "+" here.

Slices 1–6 (#381–#386) are merged.

**Required reading for every task:**
- `docs/invariants/design-system.md` (rules 3, 8, 9, 11, 12, 13), CLAUDE.md §10 (never rewrite a
  migration; add a drop), §14e and §15.
- **The deploy precondition for the drop:** the code running on all three backends must already be
  slice 4's or later, which ignores both columns. #384 was merged on 2026-10-09. Say so in the PR.

The rules most likely to bite:
- **Class names are a contract.** Keep `td.row-actions`, `.note-badge`, `.rail-btn` and `.topbar-new`.
  Never change the bare `.preview-image`, which the addon bundles share.
- **A `<label for="topbar_upload_file">` would bypass the upload chooser.** Its click lands on the input,
  and `upload_pick_controller.js` lets an input-targeted click through. The phone item must click the
  LABEL itself.
- **No inline scripts.** The CSP is report-only, so an `onclick` would "work" and still be wrong. Use
  Stimulus.
- **No `%>` inside ERB comments. Tokens only. No sideways scroll at 375px** (measure against
  `clientWidth`).
- **Mutation-check every guard.** Restore by re-applying your own snapshot. Never `git checkout --` a
  file holding uncommitted work. Then `rm -rf tmp/cache/bootsnap*`.

---

## Decisions

1. **The drop migration is reversible.** It is a `def change` with typed `remove_column`s. The two
   earlier drops (`DropRetiredSyncEngineTables`, `DropRetiredGitTrackedProjectTables`) raised
   `IrreversibleMigration`, because their DDL lived in another repo; these two columns are one line each
   here. No `if_exists:`: every database reaching it ran the add.
2. **The architecture guard stays.** Three docs cite it: `design-system.md` rule 8,
   `tools/addons_controller.rb` and `addons.md`. Only its `ignored_columns` exemption goes.
3. **The phone "+":**
   - At ≤719px the New summary reads "+" (with `aria-label="New and upload"`) and the top-bar upload
     *label* hides.
   - The New menu shows a phone-only `button.menu-item` "Upload…" whose Stimulus action clicks
     `header.topbar .topbar-upload label.upload-btn`. On a folder page that opens the file picker. On a
     page with no folder it runs `upload-pick#pick` and the chooser.
   - Only the label hides, not `.topbar-upload`, so the chunk flow's `.upload-status` progress text
     still shows.
4. **The note badge becomes an icon and the count.** Add a `note:` path to `ShellHelper::ICON_PATHS`.
   The badge's `title` keeps the words ("2 notes"), which is where status carries its word.
5. **A guard forbids pictographs (U+1F300–U+1FAFF) in templates, helpers and scripts**, beside
   `css_hygiene_test`'s stylesheet rule.
   - It reads compiled ERB (Erubi drops `<%# %>` comments), Ruby without comment tokens, and JS without
     comments.
   - An addon's manifest `icon` is data, not source, and stays allowed.
6. **The three visual nits**:
   - **Sign out** in the collapsed rail draws an icon with a hidden label. It and **Settings** get an
     accessible name.
   - **The 3D and Gerber fallback poster** is centred with `margin-inline: auto`, scoped to the fallback
     containers.
   - **The Library's list-view row divider** runs under the actions column.

## Files

| file | change | task |
|---|---|---|
| `db/migrate/20261009120000_drop_retired_current_project_columns.rb` | new | 1 |
| `db/schema.rb`, `docs/schema-map.html` | regenerated | 1 |
| `app/models/user.rb` | `ignored_columns` gone; its stale engine comments rewritten | 1 |
| `test/architecture_invariants_test.rb` | the exemption goes; the comment says the columns are dropped | 1 |
| CLAUDE.md §14e | delete the parenthetical about `user.rb`'s stale comment (no new lines) | 1 |
| `app/views/layouts/_topbar.html.erb`, new `app/javascript/controllers/upload_forward_controller.js`, `app/assets/stylesheets/shell.css` (the ≤719px block) | the phone "+" | 2 |
| `test/system/new_menu_test.rb` (or a new `test/system/phone_topbar_test.rb`), `test/integration/web/new_menu_test.rb` | tests | 2 |
| `app/helpers/shell_helper.rb` (`ICON_PATHS[:note]`, `[:sign_out]`), `app/views/files/_note_badge.html.erb`, `app/assets/stylesheets/components.css` (`.note-badge .rail-icon`, the list-view divider) | the badge and the divider | 3 |
| `app/views/layouts/_rail.html.erb` | Sign out icon; accessible names | 3 |
| `app/assets/stylesheets/pages/preview.css` | the poster | 3 |
| `app/assets/stylesheets/pages/models.css` (L74–76 deleted), `pages/settings.css` (L2) | duplicate and stale | 3 |
| stale comments: `app/services/maker/project_folder_listing.rb` L93, `projects_controller.rb` L96, `projects/_card.html.erb` L23 | Home → Recent; the hero is gone | 3 |
| new `test/no_emoji_test.rb`; `files_flow_test.rb`; a system check for the divider and poster | tests | 3 |
| spec, `docs/invariants/design-system.md` (rule 9), the published Design System artifact | the record | 4 |

**Order:**
- **Tasks 1, 2 and 3 run in parallel.**
- Tasks 2 and 3 both touch `shell.css` and `shell_helper.rb` in separate hunks, and the orchestrator
  resolves any cherry-pick conflict.
- **Task 4's spec and design-system edits** run alongside them.
- **Task 4's artifact refresh** is the orchestrator's, after merge-ready, because it needs the Artifact
  tool.
- Each implementer starts with `git reset --hard <the plan commit on claude/redesign-slice-7>`.

---

### Task 1: Drop the retired columns

- [ ] **Step 1: The guard first.** In `test/architecture_invariants_test.rb`, delete the three-line
  `ignored_columns` exemption inside "nothing reads a destination from session or user state…"
  (~L250–252). Run it, and expect it red: `app/models/user.rb:6 current_project_id` and
  `remember_current_project`. That proves the guard sees the names, and it stays red until Step 3.
- [ ] **Step 2: The migration**, `db/migrate/20261009120000_drop_retired_current_project_columns.rb`:

```ruby
# frozen_string_literal: true

# THE CURRENT PROJECT'S TWO COLUMNS GO (structural redesign spec §9.1, slice 7). Slice 4 retired the
# concept — new files land in the folder the maker is looking at (FolderDestination), and nothing reads a
# destination from session or user state (test/architecture_invariants_test.rb) — and left these two
# `ignored_columns` for one release, so a deploy's old and new code never disagreed about a column
# mid-rollout. That release has shipped (#384, 2026-10-09).
#
# A DROP, ADDED — never a rewrite of 20260910120000_add_current_project_to_users.rb, which runs forward
# everywhere as it is (CLAUDE.md §10). REVERSIBLE, unlike the two table drops before it: their DDL lived
# in another repository, while these are one typed line each, and their values have been unread since
# slice 4. No `if_exists:` — every database reaching this ran the add, and a silent skip would hide a
# database that did not.
class DropRetiredCurrentProjectColumns < ActiveRecord::Migration[8.1]
  def change
    remove_column :users, :current_project_id, :bigint
    remove_column :users, :remember_current_project, :boolean, default: true, null: false
  end
end
```

  Match the `ActiveRecord::Migration[x.y]` version the neighbouring migrations use.
- [ ] **Step 3:**
  - Run `bin/rails db:migrate`, and confirm `db/schema.rb` lost both column lines and its version is
    `2026_10_09_120000`.
  - Run `bin/rails db:rollback && bin/rails db:migrate`. Both must succeed, which proves reversibility.
  - Delete `app/models/user.rb` L2–6 (the comment and `ignored_columns`).
  - Rewrite `user.rb`'s stale engine comments (~L10–15, L54–62, L311–315, L333). They describe `Sync::`
    associations and a `lib/postgres_pooler_check.rb` that no longer exist. State what is true now:
    `head_seq`/`next_seq!` are served to a joining device, and the lock-ordering rule lives in the sync
    server's repo (CLAUDE.md §14e).
  - Then delete CLAUDE.md §14e's parenthetical that names this stale comment, without adding lines.
  - Run `bin/rails schema:map` to regenerate `docs/schema-map.html`.
- [ ] **Step 4:** reword the guard's comment (~L229–230): the columns are dropped (slice 7), so a read
  fails at the database, and the guard catches the NAMES, which is where a revival starts.
- [ ] **Step 5: Run.**
  - `LIBRARY_PATH=$(mktemp -d) bin/rails test test/architecture_invariants_test.rb test/schema_map_test.rb test/integration/web/`,
    then the full non-system suite.
  - Grep `app lib config test` for both column names. Only the guard's list and the old add migration
    may remain.
- [ ] **Step 6: Mutation.**
  - Put `self.ignored_columns += %w[current_project_id]` back in `User`. The guard must go red, because
    the exemption is gone.
  - Delete the migration file and re-run `schema_map_test`. It must go red against the checked-in map.
  - Restore both.
- [ ] **Commit:** "The current project's two columns are dropped". The body carries the deploy
  precondition.

### Task 2: One "+" on a phone

- [ ] **Step 1: The controller**, `app/javascript/controllers/upload_forward_controller.js`:

```js
import { Controller } from "@hotwired/stimulus"

// THE PHONE'S "+" CARRIES UPLOAD TOO (structural redesign spec §4.3, slice 7). At ≤719px the top bar's
// upload label hides and the New menu offers "Upload…", which forwards a click to that LABEL — never to
// the file input, and never through a `<label for>`: on a page with no folder the label's click is what
// upload_pick_controller.js intercepts to ask for a folder first, and an input-targeted click is the one
// it deliberately lets through, so either shortcut would upload to the library root unasked. Runs inside
// the tap's own click, so the user activation the file picker needs is still live.
export default class extends Controller {
  open() {
    document.querySelector("header.topbar .topbar-upload label.upload-btn")?.click()
  }
}
```

- [ ] **Step 2: The markup** (`app/views/layouts/_topbar.html.erb`):
  - The New summary becomes
    `<summary class="btn" aria-label="New and upload"><span class="topbar-new-label">New <span aria-hidden="true">▾</span></span><span class="topbar-new-plus" aria-hidden="true">+</span></summary>`.
  - Inside `.menu-list`, first:

```erb
        <%# PHONE ONLY (shell.css hides it above 719px): the top bar's Upload, from inside the one "+". %>
        <button type="button" class="menu-item topbar-new-upload" data-controller="upload-forward"
                data-action="upload-forward#open">Upload…</button>
        <div class="menu-sep topbar-new-upload" role="separator"></div>
```

- [ ] **Step 3: Styles** (`shell.css`):
  - Outside the media query: `.topbar-new-plus, .topbar-new-upload { display: none; }`.
  - Inside the ≤719px block:
    `.topbar-new-label { display: none; } .topbar-new-plus { display: inline; } .topbar-new-upload { display: block; } .topbar-upload label.upload-btn { display: none; }`.
  - Check the specificity against `.menu-item`'s own `display` in `components.css`. A `.menu-list
    .topbar-new-upload` qualifier may be needed; never redeclare `.menu-item` itself.
- [ ] **Step 4: Tests.**
  - **A phone system test** at 375 (CDP, as `new_menu_test.rb` does):
    - the summary shows "+" and the upload label is not visible;
    - opening "+" shows "Upload…";
    - **on Recent**, clicking it opens `.filechooser-overlay`, choosing a folder sets the hidden
      `parent_node_id`, and a `window.__picks` counter on `#topbar_upload_file` reads 1 after Choose
      (copy `topbar_upload_test.rb`'s idiom);
    - **on a folder page**, clicking it fires the input's click (`__picks` reads 1) with no chooser.
  - **At desktop width** "Upload…" is not visible and the label is.
  - **The existing phone menu test** (375 and 360) still keeps the menu on screen.
  - **`test/integration/web/new_menu_test.rb`:** the button exists, with `data-action="upload-forward#open"`.
- [ ] **Step 5: Mutations.**
  - The controller clicks `#topbar_upload_file` (the input) instead of the label. The Recent case must
    go red: no chooser.
  - Hiding all of `.topbar-upload` instead of the label must not hide `.upload-status`. Assert it is
    still in the layout on a chunk_remote-shaped render, or document why it can't be.
  - Restore both.
- [ ] **Commit:** "A phone's top bar has one '+' for New and Upload".

### Task 3: The last emoji, three nits, and stale comments

- [ ] **Step 1: The guard first**, `test/no_emoji_test.rb`:

```ruby
require "test_helper"

# NO EMOJI IN THE INTERFACE (structural redesign; design-system.md). css_hygiene_test.rb guards the
# stylesheets; this guards the rest of the source a page is built from: templates (compiled, so `<%# %>`
# comments are not read), helpers and controllers (Ripper, comment tokens skipped), and scripts (comments
# stripped). Pictographs only — U+1F300–U+1FAFF — because ✓, ✕ and ✎ are typographic marks a status
# carries as words. An addon's manifest `icon` is data the bundle supplies, not this repo's source.
class NoEmojiTest < ActiveSupport::TestCase
  PICTOGRAPH = /[\u{1F300}-\u{1FAFF}]/

  test "no template, helper, controller or script draws an emoji" do
    erb = Dir[Rails.root.join("app/views/**/*.erb")]
    rb = Dir[Rails.root.join("app/helpers/**/*.rb"), Rails.root.join("app/controllers/**/*.rb")]
    js = Dir[Rails.root.join("app/javascript/**/*.js")]
    [ erb, rb, js ].each { |set| refute_empty set, "a scan found no files — it would pass over nothing" }

    hits = erb.filter_map { |f| f if ActionView::Template::Handlers::ERB::Erubi.new(File.read(f)).src.match?(PICTOGRAPH) }
    hits += rb.filter_map do |f|
      f if Ripper.lex(File.read(f)).any? { |(_, type, str, _)| type != :on_comment && str.match?(PICTOGRAPH) }
    end
    hits += js.filter_map do |f|
      f if File.read(f).gsub(%r{/\*.*?\*/}m, "").gsub(%r{^\s*//.*$}, "").match?(PICTOGRAPH)
    end
    assert_empty hits.map { |f| Pathname.new(f).relative_path_from(Rails.root).to_s },
                 "an interface source draws an emoji; use a glyph (rail_icon, folder_glyph) or a word"
  end
end
```

  Run it and expect red: `app/views/files/_note_badge.html.erb`. If `vendor/`-sourced JS lives under
  `app/javascript` (the CodeMirror bundle, the 3D viewer), exclude those paths by name and say why.
- [ ] **Step 2: The badge.**
  - Add `note: "M3 2h7l3 3v9H3z M5 7h6 M5 10h6"` to `ICON_PATHS`.
  - `_note_badge.html.erb` renders `<%= rail_icon(:note) %> <%= count %>` inside the same span, keeping
    the `title`.
  - In `components.css`, beside `.note-badge`, add
    `.note-badge .rail-icon { width: 12px; height: 12px; vertical-align: -2px; }`.
  - `files_flow_test`'s `text: /2/` still holds. Add `assert_select ".note-badge svg.rail-icon"` and
    `assert_no_match "\u{1F4DD}", response.body`.
- [ ] **Step 3: Sign out.**
  - Add `sign_out: "M6 3H3v10h3 M10 5l3 3-3 3 M13 8H7"` to `ICON_PATHS`.
  - In `_rail.html.erb`, Sign out becomes the block form, with the icon plus
    `<span>Sign out</span>`, `title: "Sign out"` and `"aria-label": "Sign out"`.
  - The Settings link gets `title: "Settings"` and `"aria-label": "Settings"` if it lacks them.
  - `shell_test.rb:144`'s `find("aside.rail button", text: "Sign out")` still holds with the rail
    expanded.
  - A system test at 900px (where the rail is 56px icons) asserts the Sign out button is a single line:
    its height is no more than a sibling `.rail-btn`'s.
- [ ] **Step 4: The poster** (`pages/preview.css`): add
  `.model-viewer-fallback .preview-image, .measure-fallback .preview-image { margin-inline: auto; }`.
  A system check on a file page with a 3D fallback asserts the image's centre is within 1px of its
  container's centre.
- [ ] **Step 5: The list divider** (`components.css`, beside the `table.files` rules):
  - The `td.row-actions` is `display: flex` (`.row-actions` component), so its own bottom border fades
    with it.
  - Draw the divider on the row instead (`table.files tbody tr { border-bottom: 1px solid var(--line); }`
    with the cells' `border-bottom` removed). First confirm `table.files` collapses borders; if it
    doesn't, use the root-cause alternative the plan's map gives (`display: table-cell` on
    `td.row-actions`, with the fade moved to its children).
  - Prove it with a system assertion: the row's bottom border (or the actions cell's) computes to 1px
    and spans to the table's right edge. Also take a screenshot for the PR.
  - `trash/index.html.erb` shares the bug and the fix.
- [ ] **Step 6: Duplicates and stale comments.**
  - Delete `pages/models.css` L74–76; the `.project-card` rule covers the model card, which carries
    that class.
  - `pages/settings.css` L2: the shelf rows' rules live in `pages/models.css`.
  - `project_folder_listing.rb` L93: `load_files: false` has no production caller since Home's hero went.
    Say so, or delete the option if only its own test uses it. If you delete it, delete that test case
    too, and say which.
  - `projects_controller.rb` L96 and `projects/_card.html.erb` L23: Home → Recent.
- [ ] **Step 7: Run** the guard, `css_hygiene_test`, `template_hygiene_test`, the files and shell tests,
  the system tests you added, and `shell_test`'s 375px sweep.
- [ ] **Step 8: Mutations.**
  - 📝 back in the badge reddens `no_emoji_test`. A 📁 in a comment in a template or helper stays green.
  - The poster rule removed reddens the centring check.
  - The divider rule removed reddens its check.
  - The Sign out span or icon removed reddens the single-line check.
- [ ] **Commit:** "The last emoji, three visual nits, and the comments the redesign left stale".

### Task 4: Record the slice

- **Spec:** append "**Amended 2026-10-09 (slice 7's plan):**" after slice 6's. The redesign is complete.
  Cover the drop, the phone "+", the emoji guard, and the nits. Also mark §11's delivery table as
  shipped, with PR numbers #381–#386 and this one.
- **`design-system.md`:**
  - Rule 9: on a phone the top bar's New and Upload are one "+"; the Upload item forwards to the label
    and never to the input.
  - A sentence beside the stylesheet emoji rule naming `test/no_emoji_test.rb`.
- **Do not add lines to CLAUDE.md.**
- **The published Design System artifact (orchestrator, after Tasks 1–3 merge-ready).** It drifts from
  what shipped. Its `contracts.md` lists the retired `.current-project select` selectors, and its shell
  notes predate the sidebar, Recent, the inspector and folder destinations.
  - Re-read it with the Artifact tool's `read`.
  - Update its contracts and shell pages to the shipped structure.
  - Republish to the same URL.
  - It is the user's artifact, so say what changed in the final report.

### Task 5: Close out

- [ ] Bare `bin/ci`, with identical run counts on all three legs.
- [ ] `/finish-branch`. The PR states the deploy precondition for the column drop: run it only where
  slice 4 or later is already deployed. Then `bin/log arc --from-pr <n>`. **Merging needs the user's
  go-ahead.**
