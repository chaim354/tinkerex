# Web Shell PR 4: Tools, Trash, Repo Pages, and a Dark Code Theme — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. **In this repo `.claude/commands/execute-plan.md` overrides the generic loop:** batch by file (each task below is one coherent unit), dispatch disjoint tasks in parallel, no spec-compliance stage, one capped quality review per task with its mutations run and their output reported.

**Goal:** Deliver step 4 of the spec's delivery order (`docs/superpowers/specs/2026-09-03-web-shell-and-design-system-design.md` §8 "Tools gallery and addon host page", "Trash, sheet page, repo commit and history", and §3/§13's third-party skins): the trash and both repository pages get the page-head/panel/table vocabulary, the Tools gallery cards get their final form, and the CodeMirror editors (the source viewer, the repo editor, diffs, history blobs) follow the theme by adding `oneDark` to the vendored bundle — without renaming a class, label, field, id or data attribute the tests pin.

**Architecture:** Template tidying plus page rules in `pages/preview.css` and `pages/tools.css`; one vendored-bundle change (`@codemirror/theme-one-dark` exported from `vendor/javascript/codemirror-entry.js`, rebuilt by `bin/build-codemirror`, still ONE pin — CLAUDE.md §14d) consumed by the four editor controllers through a tiny shared module that reads `html[data-theme]`.

**Tech Stack:** Rails 8, Propshaft, Stimulus, CodeMirror 6 (vendored ESM bundle built with esbuild), Minitest request tests under `test/integration/web/`, Capybara/Selenium system tests under `test/system/`.

---

## Before you start

- Branch: `claude/ui-rework-pr4-tools-trash-repo`, in the worktree `/Users/charlesschwartz/Desktop/repos/tinkerex/.claude/worktrees/auto-model-folder-files-bug-112353`. Never push to `main`.
- Tests need `export LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d)`. `bin/ci style` is rubocop (rails-omakase). The full gate is `bin/ci` with `export TINKEREX_SYNC_DIR=/Users/charlesschwartz/Desktop/repos/tinkerex-sync`; only ONE full-suite run at a time in this worktree.
- Read `docs/invariants/design-system.md` (§14m), `docs/invariants/git-editing.md` (§14l — you touch the repo pages' templates and the editor controllers; change no behaviour there), and `docs/invariants/addons.md`'s host-page section (§14c — the Tools gallery and host page). Never write the ERB close delimiter inside an ERB comment; every `data-controller` value is a literal.
- **`git checkout -- <file>` restores to HEAD, not to your uncommitted edit** — `git add` your work before a mutation check.
- **The contract this PR must not break** — a full sweep of the tests that drive these pages (2026-09-04) pins these; keep each exactly:
  - Tools gallery: `h1` "Tools"; `.tools-grid`; `a.addon-card[href=tools_addon_path]` with `.addon-icon`, `.addon-title`, `.addon-desc`, `.addon-permissions` ("This tool can: …"); `div.addon-card.disabled[title]`; `.addon-card` count equals the manifest count (no hard-coded cards); the card's link text is the manifest title (`click_link "SDK Fixture"`).
  - Addon host page (`tools/addons/show`): `main.container` / `main.container.container-wide`; `.page-head h1`, `p.page-subtitle`; `ul.addon-permissions li`; `[data-controller=addon]` with every `data-addon-*-value` (entry, save-url, service-url, states-url, folders, default-folder, default-folder-label, children-url, create-url, ctx) and `[data-addon-target=mount]`. The bundles render their own markup with the classes `pages/tools.css` styles (`.box-*`, `.generator-*`, `.param-group*`, `.addon-thumb*`, `.saved-boxes`, plus the shared `.page-head`, `.page-subtitle`, `dl.meta`, `.page-actions`, `.btn`, `.file-menu`, `.folder-field*`): restyle, never rename.
  - Trash: `h1` exactly "Trash"; `table.files` with `td` (name), `td.num` (size, `/10 Bytes/`), the `a`-less name for a trashed row; `p.empty.muted` `/Trash is empty/`; `button_to "Restore"` posting `restore_trash_path`; "← Back to Files".
  - Repo commit page: `form.commit-box` posting `repo_commit_path` with `input[type=hidden][name=expected_head]`, `input[name='paths[]']` (checked state per group), `textarea[name=message]`, the submit "Commit"; `section.commit-group[data-group][data-controller=commitgroup][data-commitgroup-label-value]`, `details.commit-group-body[open]` with its `summary` (title + count) and `.commit-group-note`; `ul.commit-rows > li[data-path][data-state]` with `.commit-row-head` (`code` path, `.commit-row-state`, `.plus`, `.minus`), `p.commit-nodiff` texts "deleted — nothing to diff" / "binary — no diff", `.commit-diff[data-controller=diffview]` with its three values; texts "ignored by .gitignore", "Renames are not detected…", "N further changed path(s) not listed", "Nothing to commit here — git reports no changes in this repository."; the JS-built `.commit-group-all` "Select all in {title}"; flash "Committed N file(s).".
  - Repo history page: `ol.commit-history > li.commit-history-row[data-oid]` newest first, `code.mono`, `.commit-subject`, `time[datetime]`; "Browse files", "Review and commit"; "No commits here yet." / "Stopped after N commits without listing anything." / "Showing the newest N commits from the last M commits walked. Older history is in git."
  - Editors: `.preview-code[data-controller=codeview|editor]` and their values, `pre.preview-text` fallback (absent once mounted), `.cm-editor`, `.cm-content[contenteditable=true|false]`, `.cm-lineNumbers .cm-gutterElement`, `.cm-line span`, `.editor-bar`, `.editor-status` "Saved", "Save"; `.commit-diff .cm-editor`, `.cm-deletedChunk`, no `.cm-chunkButtons`; `.history-diff .cm-editor`, `.history-blob`.

## File structure

| path | responsibility | task |
|---|---|---|
| `app/views/trash/index.html.erb` | page head with a ghost Back, column classes, Restore as a button | 1 |
| `app/views/repo_commits/show.html.erb` | page head with actions, groups as panels, Commit as the primary submit | 1 |
| `app/views/repo_histories/show.html.erb` | page head with actions, styled history rows | 1 |
| `app/assets/stylesheets/pages/preview.css` | commit groups, rows, message, history list, trash tweaks | 1 |
| `test/integration/web/repo_trash_pages_test.rb` | the three pages' new structure | 1 |
| `test/system/shell_test.rb` | the phone sweep gains the trash and commit pages | 1 |
| `app/views/tools/home/index.html.erb` | gallery cards: permissions as a footer line, disabled reason as a note | 2 |
| `app/assets/stylesheets/pages/tools.css` | gallery card and host page rules | 2 |
| `test/integration/web/tools_gallery_test.rb` | card structure, disabled card, host page head | 2 |
| `bin/build-codemirror`, `vendor/javascript/codemirror-entry.js`, `vendor/javascript/codemirror.js` | `@codemirror/theme-one-dark` in the ONE bundle | 3 |
| `app/javascript/lib/codemirror_theme.js` | `darkTheme?` from `html[data-theme]`, and the extension list to add | 3 |
| `app/javascript/controllers/codeview_controller.js`, `editor_controller.js`, `diffview_controller.js`, `history_controller.js` | pass the theme extensions | 3 |
| `app/assets/stylesheets/vendor-overrides.css` | the CodeMirror overrides become theme-aware (light keeps ours; dark defers to oneDark) | 3 |
| `test/system/code_theme_test.rb` | the editor is dark under the dark theme and light under light | 3 |

**Dependencies:** Tasks 1, 2 and 3 are disjoint and run in parallel. Task 4 is the close-out.

---

### Task 1: Trash and the two repository pages

**Files:**
- Modify: `app/views/trash/index.html.erb`, `app/views/repo_commits/show.html.erb`, `app/views/repo_histories/show.html.erb`, `app/assets/stylesheets/pages/preview.css`, `test/system/shell_test.rb`
- Create: `test/integration/web/repo_trash_pages_test.rb`

Read all three templates in full first and keep every ERB comment (the commit page's carry rules from `docs/invariants/git-editing.md`).

- [ ] **Step 1: Write the failing tests**

`test/integration/web/repo_trash_pages_test.rb`:

```ruby
require "test_helper"

module Web
  # The trash page and the two repository pages after PR 4 (spec §8): page heads with button
  # actions, the trash table carrying the same column classes as the Files list (so the phone rules
  # apply), Restore and Commit as buttons, and history rows with the mono oid in its own cell.
  # Everything the repo tests pin — the form, the hidden head, the group/path/state attributes —
  # is untouched; this file asserts the chrome around them.
  class RepoTrashPagesTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "rt-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
    end

    test "the trash page has a head with a ghost Back, column classes, and Restore as a button" do
      @root = use_fresh_share_library!
      node = create_node!(@user, node_id: SecureRandom.uuid, name: "old-bracket.stl", kind: "file")
      delete file_path(node.node_id)
      get trash_index_path
      assert_response :success
      assert_select ".page-head h1", text: "Trash"
      assert_select ".page-head a.btn.ghost[href=?]", files_path, text: "← Back to Files"
      assert_select "table.files th.col-name", text: "Name"
      assert_select "table.files td.col-name", text: "old-bracket.stl"
      assert_select "table.files td.num.col-size"
      assert_select "table.files td.col-modified"
      assert_select "table.files td.row-actions.col-actions form[action=?] button.btn.small", restore_trash_path(node.node_id), text: "Restore"
    end

    test "an empty trash keeps its sentence in the empty component" do
      get trash_index_path
      assert_select "p.empty.muted", text: "Trash is empty."
    end
  end
end
```

The repository pages need a git working tree. `test/support/git_repo_fixture.rb` is the house fixture: `include GitRepoFixture` in the class, set `@library = use_fresh_share_library!` in `setup` (the module reads `library_root` from it), and `make_repo!(name:, files:)` creates the repo with one "seed" commit, scans it, and returns the repository's ROOT dir node. Add to the same class:

```ruby
    include GitRepoFixture

    test "the commit page has a head with actions and Commit as the primary submit" do
      @library = use_fresh_share_library!
      root = make_repo!(name: "demo", files: { "notes.md" => "hello\n" })
      File.write(File.join(library_root, "demo", "notes.md"), "hello world\n")   # a change outside tinkerex: the "other" group
      get repo_commit_path(root.node_id)
      assert_response :success
      assert_select ".page-head h1", text: /Commit — demo/
      assert_select ".page-head .page-actions a.btn.ghost[href=?]", files_path(folder: root.node_id), text: "Browse files"
      assert_select ".page-head .page-actions a.btn.ghost[href=?]", repo_history_path(root.node_id), text: "History"
      assert_select "form.commit-box section.commit-group.panel[data-group='other']"
      assert_select "form.commit-box .editor-bar input[type='submit'][value='Commit'].primary"
    end

    test "the history page has a head with actions and mono oids" do
      @library = use_fresh_share_library!
      root = make_repo!(name: "demo", files: { "notes.md" => "hello\n" })
      get repo_history_path(root.node_id)
      assert_response :success
      assert_select ".page-head h1", text: /History — demo/
      assert_select ".page-head .page-actions a.btn.ghost", text: "Browse files"
      assert_select ".page-head .page-actions a.btn.ghost", text: "Review and commit"
      assert_select "ol.commit-history li.commit-history-row[data-oid] code.mono.commit-oid"
      assert_select "ol.commit-history li.commit-history-row .commit-subject", text: "seed"
    end
```

The trash test above also needs `@root = use_fresh_share_library!` (it already sets it); `make_repo!` runs the scan itself, so the repo tests need no `Library::ScanJob` call. The commit page lists a working-tree change only on a `local_worktree?` backend — share is, and the three legs all run this file; on the chunk_remote leg `make_repo!` still builds the repo on the local library path the sync server serves, so the pages render (repo_edit_flow_test.rb runs there today).

- [ ] **Step 2: Run them to see them fail**

```bash
bin/rails test test/integration/web/repo_trash_pages_test.rb
```

Expected: the page-head, column-class and button assertions fail.

- [ ] **Step 3: The trash page**

Replace `app/views/trash/index.html.erb` with:

```erb
<% content_for :title, "Trash — Tinkerex" %>

<div class="page-head">
  <h1>Trash</h1>
  <div class="page-actions">
    <%= link_to "← Back to Files", files_path, class: "btn ghost small" %>
  </div>
</div>
<p class="muted page-intro">Files you delete are moved here, and can be restored to your library.</p>

<% if @entries.empty? %>
  <p class="empty muted">Trash is empty.</p>
<% else %>
  <table class="files">
    <thead>
      <tr>
        <th class="col-name">Name</th>
        <th class="col-type">Kind</th>
        <th class="num col-size">Size</th>
        <th class="col-modified">Deleted</th>
        <th class="col-actions"></th>
      </tr>
    </thead>
    <tbody>
      <% @entries.each do |entry| %>
        <tr>
          <td class="col-name">
            <% if entry.kind == "dir" %>
              <span class="dir">📁 <%= entry.name %></span>
            <% else %>
              <%= entry.name %>
            <% end %>
          </td>
          <td class="muted col-type"><%= entry.kind %></td>
          <td class="num muted col-size"><%= entry.size ? number_to_human_size(entry.size) : "—" %></td>
          <td class="muted col-modified"><%= entry.deleted_at&.strftime("%Y-%m-%d %H:%M") || "—" %></td>
          <td class="row-actions col-actions">
            <%= button_to "Restore", restore_trash_path(entry.node_id), method: :post,
                  form: { data: { turbo_confirm: "Restore #{entry.name}?" } }, class: "btn small" %>
          </td>
        </tr>
      <% end %>
    </tbody>
  </table>
<% end %>
```

(The old file had ERB comments explaining the restore semantics — read it and carry them over above the matching lines.)

- [ ] **Step 4: The commit page**

In `app/views/repo_commits/show.html.erb` replace the bare `<h1>` with a page head, add `panel` to each group section, make the submit primary:

```erb
<% content_for :title, "Commit — #{@root.name} — Tinkerex" %>
<div class="page-head">
  <h1>Commit — <%= @root.name %></h1>
  <div class="page-actions">
    <%= link_to "Browse files", files_path(folder: @root.node_id), class: "btn ghost small" %>
    <%= link_to "History", repo_history_path(@root.node_id), class: "btn ghost small" %>
  </div>
</div>
```

`<section class="commit-group" …>` becomes `<section class="commit-group panel" …>` (every attribute unchanged), and `<%= submit_tag "Commit" %>` becomes `<%= submit_tag "Commit", class: "primary" %>`. Nothing else changes.

- [ ] **Step 5: The history page**

In `app/views/repo_histories/show.html.erb`:

```erb
<% content_for :title, "History — #{@root.name} — Tinkerex" %>
<div class="page-head">
  <h1>History — <%= @root.name %></h1>
  <div class="page-actions">
    <%= link_to "Browse files", files_path(folder: @root.node_id), class: "btn ghost small" %>
    <%= link_to "Review and commit", repo_commit_path(@root.node_id), class: "btn ghost small" %>
  </div>
</div>
```

replaces the `<h1>` and the `p.page-sub` block; the row's `<code class="mono">` becomes `<code class="mono commit-oid">`, and the meta `<span class="muted">` becomes `<span class="muted commit-meta">`. Everything else is unchanged.

- [ ] **Step 6: The rules** (append inside `@layer pages` in `pages/preview.css`; replace the existing `.commit-rows > li`, `.commit-row-head`, `.commit-message`, `.commit-group + .commit-group`, `.commit-group-body > summary` rules with these)

```css
  .page-intro { max-width: 72ch; margin: -8px 0 16px; font-size: 13px; }
  .commit-group + .commit-group { margin-top: 12px; }
  .commit-group-body > summary { cursor: pointer; padding: 2px 0; font-weight: 600; list-style: none; display: flex; align-items: center; gap: 8px; }
  .commit-group-body > summary::-webkit-details-marker { display: none; }
  .commit-group-body > summary::before {
    content: ""; width: 6px; height: 6px; border-right: 1.5px solid var(--fg-muted); border-bottom: 1.5px solid var(--fg-muted);
    transform: rotate(-45deg); transition: transform 120ms ease;
  }
  .commit-group-body[open] > summary::before { transform: rotate(45deg); }
  .commit-group-body > summary .muted { font: 400 11px/1.4 var(--font-mono); }
  .commit-rows { list-style: none; margin: 8px 0 0; padding: 0; }
  .commit-rows > li { border: 1px solid var(--line); border-radius: var(--radius-panel); margin-bottom: 8px; background: var(--bg); }
  .commit-row-head { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; padding: 6px 10px; border-bottom: 1px solid var(--line); }
  .commit-row-head code { font-family: var(--font-mono); font-size: 12px; overflow-wrap: anywhere; }
  .commit-row-state { font: 500 10px/1.4 var(--font-mono); text-transform: uppercase; letter-spacing: .08em; }
  .commit-nodiff { margin: 0; padding: 6px 10px; font-size: 12px; }
  .commit-message { width: 100%; font: 13px/1.5 var(--font-ui); padding: 8px 10px; border: 1px solid var(--line); border-radius: var(--radius-control); background: var(--surface); color: inherit; }
  .commit-rename-note, .commit-truncated { font-size: 12px; }
  .commit-history { list-style: none; margin: 0; padding: 0; border-top: 1px solid var(--line); }
  .commit-history-row { display: grid; grid-template-columns: 76px minmax(0, 1fr) auto; gap: 4px 14px; align-items: baseline; padding: 8px 0; border-bottom: 1px solid var(--line); }
  .commit-oid { font-size: 12px; color: var(--fg-muted); }
  .commit-subject { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .commit-meta { font: 11px/1.5 var(--font-mono); white-space: nowrap; }
  @media (max-width: 719px) { .commit-history-row { grid-template-columns: 76px minmax(0, 1fr); } .commit-meta { grid-column: 2; } }
```

Keep every comment that travels with the rules you replace (the `.plus`/`.minus` tabular-nums note, the `ignored` row note, the `:only-child` note).

- [ ] **Step 7: The phone sweep**

In `test/system/shell_test.rb`'s "no page scrolls sideways at phone width" test, add `trash_index_path` to the visited list (after `models_path`). The trash table now carries the same `col-*` classes as the Files list, so the drop-column rules apply.

- [ ] **Step 8: Run**

```bash
bin/rails test test/integration/web/repo_trash_pages_test.rb test/integration/web/trash_flow_test.rb test/integration/web/share_trash_test.rb \
  test/integration/web/repo_edit_flow_test.rb test/integration/web/repo_history_flow_test.rb test/integration/web/template_hygiene_test.rb test/css_hygiene_test.rb
bin/rails test test/system/repo_staging_test.rb test/system/repo_history_test.rb test/system/shell_test.rb
bin/ci style
```

Expected: green.

- [ ] **Step 9: Mutation-check** (stage first)

```bash
sed -i '' 's/class: "btn small" %>/class: "linkbtn" %>/' app/views/trash/index.html.erb
bin/rails test test/integration/web/repo_trash_pages_test.rb -n /Restore/   # expected: 1 failure
git checkout -- app/views/trash/index.html.erb
git status --porcelain
```

- [ ] **Step 10: Commit**

```bash
git add app/views/trash/index.html.erb app/views/repo_commits/show.html.erb app/views/repo_histories/show.html.erb \
        app/assets/stylesheets/pages/preview.css test/system/shell_test.rb test/integration/web/repo_trash_pages_test.rb
git commit -m "Trash and the repository pages: page heads with actions, panels for the staging groups, mono oids"
```

---

### Task 2: The Tools gallery

**Files:**
- Modify: `app/views/tools/home/index.html.erb`, `app/assets/stylesheets/pages/tools.css`
- Create: `test/integration/web/tools_gallery_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
require "test_helper"

module Web
  # The Tools gallery after PR 4 (spec §8): each card is a surface with the icon and title on one
  # row, the description under it, and the permission line as a quiet footer; an unavailable addon
  # keeps its reason. The count and the link texts are what test/controllers/tools/home_controller_test.rb
  # pins; this asserts the structure around them.
  class ToolsGalleryTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "tg-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
    end

    test "an available card has a head row, a description and a permissions footer" do
      get tools_path
      assert_response :success
      assert_select ".tools-grid a.addon-card .addon-card-head .addon-icon"
      assert_select ".tools-grid a.addon-card .addon-card-head .addon-title", text: "Generators"
      assert_select ".tools-grid a.addon-card .addon-desc"
      assert_select ".tools-grid a.addon-card .addon-permissions.addon-card-foot", text: /This tool can:/
    end

    test "an unavailable card keeps its reason and its title attribute" do
      get tools_path
      assert_select ".tools-grid div.addon-card.disabled[title] .addon-desc", minimum: 1
    end
  end
end
```

(The dev/test fixture manifests include `generators` (available) and at least one addon whose sidecar env is unset — `home_controller_test.rb` relies on both; if this box's manifest set differs, assert on whatever `tools/home_controller_test.rb` asserts on.)

- [ ] **Step 2: Run it to see it fail**

```bash
bin/rails test test/integration/web/tools_gallery_test.rb
```

- [ ] **Step 3: The template**

`app/views/tools/home/index.html.erb` — keep the loop, the `available?` branch, the `title:` on the disabled card and the closing comment about hard-coded cards; wrap icon+title in a head row and give the permissions span the footer class:

```erb
    <% if addon.available? %>
      <%= link_to tools_addon_path(addon.key), class: "addon-card" do %>
        <span class="addon-card-head">
          <span class="addon-icon"><%= addon.icon %></span>
          <span class="addon-title"><%= addon.title %></span>
        </span>
        <span class="addon-desc muted"><%= addon.description %></span>
        <% if addon.permissions.any? %>
          <span class="addon-permissions addon-card-foot muted">
            This tool can:
            <%= addon.permissions.map { |p| Maker::Addons::Permissions.label_for(p["name"]) }.to_sentence %>
          </span>
        <% end %>
      <% end %>
    <% else %>
      <div class="addon-card disabled" title="<%= addon.unavailable_reason %>">
        <span class="addon-card-head">
          <span class="addon-icon"><%= addon.icon %></span>
          <span class="addon-title"><%= addon.title %></span>
        </span>
        <span class="addon-desc muted"><%= addon.unavailable_reason %></span>
      </div>
    <% end %>
```

- [ ] **Step 4: The rules** (replace the `.tools-grid`, `.addon-card*`, `.addon-icon`, `.addon-title`, `.addon-desc`, `.addon-permissions` rules in `pages/tools.css`; keep `ul.addon-permissions*`, `.addon-thumb*` and everything the bundles use)

```css
  .tools-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(240px, 1fr)); gap: 14px; }
  .addon-card { display: flex; flex-direction: column; gap: 8px; padding: 14px 16px; border: 1px solid var(--line); border-radius: var(--radius-panel); background: var(--surface); color: var(--fg); }
  .addon-card:hover { text-decoration: none; border-color: var(--accent); }
  .addon-card.disabled { opacity: .6; }
  .addon-card-head { display: flex; align-items: center; gap: 10px; }
  .addon-icon { font-size: 22px; line-height: 1; }
  .addon-title { font-weight: 600; font-size: 14px; }
  .addon-desc { font-size: 13px; line-height: 1.45; }
  .addon-permissions { font-size: 12px; }
  .addon-card-foot { margin-top: auto; padding-top: 8px; border-top: 1px solid var(--line); font: 11px/1.5 var(--font-mono); }
```

The Box Generator's own gallery reuses `.tools-grid`/`.addon-card` for its generator picker with `.addon-thumb` images and no `.addon-card-head`; the rules above are additive for it (the head row is optional), and `.box-group > .tools-grid` keeps its margin rule.

- [ ] **Step 5: Run**

```bash
bin/rails test test/integration/web/tools_gallery_test.rb test/controllers/tools/home_controller_test.rb test/controllers/tools/addons_controller_test.rb \
  test/css_hygiene_test.rb test/integration/web/template_hygiene_test.rb
bin/rails test test/system/box_sections_test.rb test/system/addon_bundle_test.rb
bin/ci style
```

Expected: green (the two system files prove the bundles' reuse of the card classes still lays out and `settle_addon_cards` still settles).

- [ ] **Step 6: Commit**

```bash
git add app/views/tools/home/index.html.erb app/assets/stylesheets/pages/tools.css test/integration/web/tools_gallery_test.rb
git commit -m "The Tools gallery: cards with a head row, a description and a permissions footer"
```

---

### Task 3: The code editors follow the theme

**Files:**
- Modify: `bin/build-codemirror`, `vendor/javascript/codemirror-entry.js`, `vendor/javascript/codemirror.js` (rebuilt), `app/javascript/controllers/codeview_controller.js`, `editor_controller.js`, `diffview_controller.js`, `history_controller.js`, `app/assets/stylesheets/vendor-overrides.css`
- Create: `app/javascript/lib/codemirror_theme.js`, `test/system/code_theme_test.rb`

CLAUDE.md §14d: CodeMirror is ONE vendored bundle and ONE importmap pin; languages and themes are added to `vendor/javascript/codemirror-entry.js` and the bundle rebuilt with `bin/build-codemirror`, which refuses to build if any `@codemirror/*` or `@lezer/*` package resolves twice. `oneDark` lives in `@codemirror/theme-one-dark`, which depends only on `@codemirror/language`, `@codemirror/state`, `@codemirror/view` and `@lezer/highlight` — all already pinned.

- [ ] **Step 1: Write the failing system test**

`test/system/code_theme_test.rb`:

```ruby
require "application_system_test_case"

# The source viewer follows the theme (spec §3, §13): under the dark theme the editor is painted by
# oneDark (its ground is #282c34, rgb(40, 44, 52)); under the light theme it keeps this app's own
# surface. Asserting a computed colour rather than a class, because CodeMirror's theme classes are
# generated names (ͼ-prefixed) that change between builds.
class CodeThemeTest < ApplicationSystemTestCase
  setup do
    @root = use_fresh_share_library!
    @user = sign_in_as("code-theme@example.com")
    @node = create_node!(@user, node_id: SecureRandom.uuid, name: "main.c", kind: "file")
    File.write(@root.join(@node.storage_path), "int main(void) { return 0; }\n")
  end

  teardown do
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  def editor_background
    page.evaluate_script("getComputedStyle(document.querySelector('.cm-editor')).backgroundColor")
  end

  test "the editor is dark under the dark theme and light under the light theme" do
    visit file_path(@node.node_id)
    assert_selector ".cm-editor"
    assert_equal "rgb(40, 44, 52)", editor_background

    page.execute_script("document.cookie = 'theme=light; path=/; max-age=31536000; samesite=lax'")
    visit file_path(@node.node_id)
    assert_selector ".cm-editor"
    assert_equal "rgb(255, 255, 255)", editor_background
    assert_no_console_errors
  ensure
    page.execute_script("document.cookie = 'theme=dark; path=/; max-age=31536000; samesite=lax'")
  end
end
```

- [ ] **Step 2: Run it to see it fail**

```bash
bin/rails test test/system/code_theme_test.rb
```

Expected: the first `assert_equal` fails — today the dark editor's background is this app's `--surface` (`rgb(27, 31, 37)`), not oneDark's.

- [ ] **Step 3: Add the theme to the bundle**

In `bin/build-codemirror`'s `package.json` heredoc, add beside the other `@codemirror/*` pins (verified against the registry on 2026-09-04: version 6.1.3, whose only dependencies — `@codemirror/view`, `@codemirror/state`, `@codemirror/language`, `@lezer/highlight` — are already pinned there, so the duplicate-copy refusal cannot trigger):

```json
    "@codemirror/theme-one-dark": "6.1.3",
``` In `vendor/javascript/codemirror-entry.js` add:

```js
export { oneDark } from "@codemirror/theme-one-dark"
```

Rebuild:

```bash
bin/build-codemirror
```

Expected: "installing pinned CodeMirror packages…", no "REFUSING TO BUILD" (the theme pulls no second copy of any package), "wrote vendor/javascript/codemirror.js — N bytes". Run it TWICE and confirm the two outputs are byte-identical (`shasum vendor/javascript/codemirror.js` between runs) — that is the reproducibility the build script's header requires. Confirm the bundle exports the symbol: `grep -c "oneDark" vendor/javascript/codemirror.js` is at least 1 (minified names vary, so also open a Rails console-free check: `node -e 'import("./vendor/javascript/codemirror.js").then(m => console.log(typeof m.oneDark))'` should print `object`).

- [ ] **Step 4: The shared module and the four controllers**

`app/javascript/lib/codemirror_theme.js`:

```js
// Which CodeMirror theme a page wants, read from the same attribute the layout stamps
// (ShellHelper#ui_theme): "dark" and "system"-resolving-to-dark get oneDark; "light" gets
// CodeMirror's default (this app's vendor-overrides paint the chrome). One place, four editors.
export function darkThemeActive() {
  const theme = document.documentElement.dataset.theme
  if (theme === "light") return false
  if (theme === "system") return window.matchMedia("(prefers-color-scheme: dark)").matches
  return true
}

export function themeExtensions(cm) {
  return darkThemeActive() ? [cm.oneDark] : []
}
```

Pin it in `config/importmap.rb` only if `lib/` is not already covered: `pin_all_from "app/javascript/lib", under: "lib"` — check for an existing `lib/` pin first (`lib/codemirror_languages` and `lib/formula_adapter` are imported today, so the pin exists; add nothing).

In each controller, import it and add the extensions:

- `codeview_controller.js`: alongside `import("codemirror")` and `import("lib/codemirror_languages")`, also `import("lib/codemirror_theme")`; push `...theme.themeExtensions(cm)` onto `extensions` after `cm.basicSetup`.
- `editor_controller.js`: same, after `cm.basicSetup`.
- `diffview_controller.js`: same, after `cm.basicSetup` (before `unifiedMergeView`).
- `history_controller.js`: wherever it builds an `EditorView` for a diff (`history-diff`), the same.

Match each file's existing import style (they use dynamic `import()` in a `Promise.all`; add the third import there and destructure it the same way the languages module is). Keep `cm.EditorView.editable.of(false)` and every existing extension.

- [ ] **Step 5: The overrides become theme-aware**

In `app/assets/stylesheets/vendor-overrides.css`, scope the existing CodeMirror block to the light theme, so oneDark paints the dark one unopposed:

```css
/* CodeMirror 6: under the LIGHT theme these paint the editor in this app's tokens; under the
   dark theme app/javascript/lib/codemirror_theme.js adds oneDark, whose own rules carry higher
   specificity (its generated class plus the element), so nothing here needs to fight it. The
   border and radius are ours in both themes. */
.cm-editor { border: 1px solid var(--line); border-radius: var(--radius-panel); }
:root[data-theme="light"] .cm-editor, :root[data-theme="system"] .cm-editor { background: var(--surface); color: var(--fg); }
:root[data-theme="light"] .cm-editor .cm-gutters, :root[data-theme="system"] .cm-editor .cm-gutters { background: var(--raised); color: var(--fg-muted); border-right: 1px solid var(--line); }
:root[data-theme="light"] .cm-editor .cm-activeLine { background: color-mix(in srgb, var(--accent) 8%, transparent); }
:root[data-theme="light"] .cm-editor .cm-activeLineGutter { background: color-mix(in srgb, var(--accent) 12%, var(--raised)); }
.cm-editor .cm-selectionBackground, .cm-editor ::selection { background: color-mix(in srgb, var(--accent) 30%, transparent); }
:root[data-theme="light"] .cm-editor .cm-cursor { border-left-color: var(--fg); }
```

(`system` resolving to dark is painted by oneDark via the JS check; the `[data-theme="system"]` selectors above only matter when the OS is light, where they are correct.)

- [ ] **Step 6: Run**

```bash
bin/rails test test/system/code_theme_test.rb test/system/code_viewer_test.rb test/system/repo_editor_test.rb test/system/repo_history_test.rb
bin/rails test test/ci_hygiene_test.rb test/css_hygiene_test.rb test/stimulus_hygiene_test.rb
bin/ci style
```

Expected: green. `ci_hygiene_test` still sees exactly one `codemirror` pin and no `@codemirror/*` pin.

- [ ] **Step 7: Mutation-check** (stage first)

```bash
sed -i '' 's/return darkThemeActive() ? \[cm.oneDark\] : \[\]/return []/' app/javascript/lib/codemirror_theme.js
bin/rails test test/system/code_theme_test.rb    # expected: 1 failure (dark background is rgb(27, 31, 37))
git checkout -- app/javascript/lib/codemirror_theme.js
git status --porcelain
```

- [ ] **Step 8: Commit**

```bash
git add bin/build-codemirror vendor/javascript/codemirror-entry.js vendor/javascript/codemirror.js \
        app/javascript/lib/codemirror_theme.js app/javascript/controllers/codeview_controller.js app/javascript/controllers/editor_controller.js \
        app/javascript/controllers/diffview_controller.js app/javascript/controllers/history_controller.js \
        app/assets/stylesheets/vendor-overrides.css test/system/code_theme_test.rb
git commit -m "The code editors follow the theme: oneDark in the one vendored bundle, chosen from html[data-theme]"
```

---

### Task 4: Close-out

- [ ] `export TINKEREX_SYNC_DIR=/Users/charlesschwartz/Desktop/repos/tinkerex-sync; bin/ci` — every gate green; the three backend legs' run counts identical.
- [ ] Amend `docs/invariants/design-system.md` rule 2 with one sentence: the CodeMirror editors take `oneDark` from `lib/codemirror_theme.js` under the dark theme, and `vendor-overrides.css` paints only the light one.
- [ ] `/finish-branch`; `bin/log arc --from-pr <n>` the moment the PR exists.
