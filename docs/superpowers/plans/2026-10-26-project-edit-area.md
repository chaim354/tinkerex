# The Project Edit Area Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. In this repo `.claude/commands/execute-plan.md` overrides the generic loop (CLAUDE.md §15).

**Goal:** The project page has one Edit button; everything that customises a project lives in a three-tab edit area (Details, Publishing, Page layout).

**Architecture:** One shared partial (`projects/_edit_head`) draws the edit area's head and tab bar on three pages: the existing `edit` form, a new `publishing` member action rendering the old Publish panel's body, and the existing in-place layout editor (`projects#show` with `editing`). `publish` leaves the page-layout vocabulary; `Maker::LayoutDocument` skips it as a retired key with a note.

**Tech Stack:** Rails 8, server-rendered ERB + Hotwire, Minitest integration + system tests.

Spec: `docs/superpowers/specs/2026-10-26-project-edit-area-design.md`.

---

## File map

| file | change |
|---|---|
| `config/routes.rb` | `get :publishing, on: :member` inside `resources :projects` |
| `app/controllers/projects_controller.rb` | `publishing` action; `set_project` covers it; `update`'s `return_to` is `"publishing"` |
| `app/controllers/projects/unlisted_tokens_controller.rb` | redirects to `publishing_project_path` |
| `app/controllers/settings/handles_controller.rb` | `return_path` → `publishing_project_path` |
| `app/views/projects/_edit_head.html.erb` | **new**: "Edit <name>", tab bar, Done |
| `app/views/projects/edit.html.erb` | edit head + form + Danger zone |
| `app/views/projects/publishing.html.erb` | **new**: edit head + `projects/_publish` |
| `app/views/projects/_publish.html.erb` | a `section.publish-panel` without `#publish`, `@panel_layout` and `return_to=project` |
| `app/views/projects/show.html.erb` | head: Edit + "+ Add panel" only; edit mode renders `_edit_head`; no `publish` locals |
| `app/views/projects/_panel_groups.html.erb` | no `yield "publish"` |
| `app/views/projects/_panel_slot.html.erb`, `_panel_strip.html.erb` | no Publish branches |
| `app/javascript/controllers/layout_editor_controller.js` | no pinned-slot handling |
| `app/models/maker/project.rb` | `publish` out of `PANELS` and `PANEL_LABELS` |
| `app/services/maker/project_kind.rb` | `publish` out of `ALWAYS`, `groups`, `layout_for` |
| `app/services/maker/layout_document.rb` | `RETIRED_PANELS`; skip with a note on both parse paths; no move-to-end |
| `app/assets/stylesheets/pages/projects.css` | edit-area rules (page sheet; no component selector) |
| tests | see each task |

---

### Task 1: `publish` leaves the layout vocabulary

**Files:** `app/models/maker/project.rb`, `app/services/maker/project_kind.rb`, `app/services/maker/layout_document.rb`, `test/services/maker/project_kind_test.rb`, `test/services/maker/layout_document_test.rb`

- [ ] **Step 1: Failing tests.** In `project_kind_test.rb`, replace the "publish is normalised last" test (≈ line 490) with:

```ruby
# PUBLISH LEFT THE PAGE (2026-10-26, the edit area): its settings are the Publishing tab, so a
# stored order the editor wrote before then still names it and must read without it.
test "a stored order naming the retired publish panel reads without it" do
  layout = Maker::ProjectKind.layout_for(kind: "other", folders: [],
                                         overrides: { "order" => [ "publish", "tasks", "attachments" ] })
  refute_includes layout.order, "publish"
  refute_includes Maker::Project::PANELS, "publish"
  refute_includes Maker::ProjectKind::ALWAYS, "publish"
end
```

In `layout_document_test.rb`, replace the assertion at ≈ line 153 (Publish moved last) with a test that a YAML `panel: publish` entry applies with a note and no error, and one that a draft entry `{ "key" => "publish" }` does the same:

```ruby
test "a YAML layout from before the edit area still applies, skipping publish with a note" do
  result = parse_yaml(<<~YAML)
    layout: 1
    panels:
      - panel: tasks
      - panel: publish
  YAML
  assert_empty result.errors
  refute_includes result.draft["panels"].map { |e| e["key"] }, "publish"
  assert_includes result.notes.join(" "), "Publishing has its own tab now"
end
```

(Use the file's own helpers for building a document; read its setup first.)

- [ ] **Step 2:** `LIBRARY_PATH=$(mktemp -d) bin/rails test test/services/maker/project_kind_test.rb test/services/maker/layout_document_test.rb` — expect the new tests to FAIL.
- [ ] **Step 3: Implement.** Remove `publish` from `PANELS` and `PANEL_LABELS`; `ALWAYS = %w[attachments photos]`; drop `next if k == "publish"` in `groups`; `ordered = order & vocabulary` in `layout_for`; rewrite the comments that explain publish pinning. In `LayoutDocument` add `RETIRED_PANELS = { "publish" => "Publishing has its own tab now; that entry was skipped." }`, consult it in `key_from_yaml`'s `panel` branch and in `key_from_draft` before the unknown-panel error (push the note, return nil), and delete the move-Publish-to-the-end block.
- [ ] **Step 4:** re-run, expect PASS; then fix the other tests in both files that assert `"publish"` last (they now assert the order without it).
- [ ] **Step 5: Commit.**

### Task 2: the read page and the layout editor lose Publish

**Files:** `app/views/projects/show.html.erb`, `_panel_groups.html.erb`, `_panel_slot.html.erb`, `_panel_strip.html.erb`, `app/javascript/controllers/layout_editor_controller.js`, `test/integration/web/project_tabs_test.rb`, `test/system/page_editor_test.rb`, `test/system/page_tabs_test.rb`, `test/integration/web/project_layout_editor_test.rb`, `test/integration/web/project_page_test.rb`, `test/integration/web/public_project_test.rb`

- [ ] Remove the two `yield "publish"` in `_panel_groups` (and the foot keyed on it: the foot is now the tail alone), the `panel-slot--pinned` class in `_panel_slot`, the two `unless key == "publish"` in `_panel_strip` (the handle and Up/Down render for every non-tab key), and `"publish" => {...}` from `panel_locals`.
- [ ] In `layout_editor_controller.js` remove the Sortable `filter`/`onMove` pinned rules and the two pinned lookups (`movable` becomes `this.slotTargets`; a new tab is appended after the last slot).
- [ ] Update the tests that assert `section#publish` in the foot / `publish` last: they now assert no `section#publish` on the page and no Publish slot in the editor. Run the touched files.
- [ ] Commit.

### Task 3: the Publishing tab

**Files:** `config/routes.rb`, `app/controllers/projects_controller.rb`, `app/controllers/projects/unlisted_tokens_controller.rb`, `app/controllers/settings/handles_controller.rb`, `app/views/projects/_edit_head.html.erb` (new), `app/views/projects/publishing.html.erb` (new), `app/views/projects/_publish.html.erb`, `test/integration/web/publishing_test.rb`

- [ ] **Step 1: Failing tests** in `publishing_test.rb`: `get publishing_project_path(@project)` renders `section.publish-panel` with the three `project[visibility]` radios, `project[license]`, `input[name=return_to][value=publishing]`, Preview; the head's `.tab-bar a.tab-link.is-active[aria-current=page]` is "Publishing"; a PATCH with `return_to: "publishing"` redirects to `publishing_project_path` on success and on refusal; the handle claim and New link redirect there.
- [ ] **Step 2:** run, expect FAIL (no route).
- [ ] **Step 3: Implement.**

`config/routes.rb`, inside `resources :projects`:

```ruby
    # THE PUBLISHING TAB (2026-10-26, the edit area; spec 2026-10-26-project-edit-area §3): what the
    # Publish panel held, on a page of its own beside Details and Page layout. A member GET on this
    # controller for the reason `preview` is one: the rail lights Projects with no SECTIONS entry.
    get :publishing, on: :member
```

`ProjectsController`: add `publishing` to `set_project`; the action builds the folder path from one `Maker::LibraryTree`:

```ruby
  def publishing
    tree = Maker::LibraryTree.new(current_user)
    id = @project.folder_node_id.presence
    @folder_path = id && tree.dir?(id) ? tree.path_for(id) : nil
  end
```

`update`: `params[:return_to] == "publishing"` → success `redirect_to publishing_project_path(@project), notice: publish_notice`, refusal `redirect_to publishing_project_path(@project), alert: …`.

`_edit_head.html.erb` (locals: `project`, `current` ∈ `:details | :publishing | :layout`): a `.page-head.edit-head` with `.page-title` (eyebrow "Edit", `h1` the name) and `.head-actions` (Done → `project_path`), then `nav.tab-bar.edit-tabs` with three `a.tab-link`, the current one `is-active` + `aria-current="page"`.

`publishing.html.erb`: title, crumbs (Projects / name / Publishing), `render "projects/edit_head", current: :publishing`, `render "projects/publish", project: @project, folder_path: @folder_path`.

`_publish.html.erb`: drop `id="publish"`, the `panel_title`/`panel_intro` calls (heading reads "Publishing"), and `return_to` becomes `"publishing"`.

Handles: `project ? publishing_project_path(project) : edit_user_registration_path`. Unlisted tokens: both redirects to `publishing_project_path(project)`.

- [ ] **Step 4:** run, expect PASS.
- [ ] Commit.

### Task 4: Details tab and its Danger zone; the project head

**Files:** `app/views/projects/edit.html.erb`, `app/views/projects/show.html.erb`, `app/assets/stylesheets/pages/projects.css`, `test/integration/web/projects_flow_test.rb`, `test/integration/web/project_page_test.rb`, `test/integration/web/project_layout_editor_test.rb`

- [ ] **Step 1: Failing tests.** `projects_flow_test.rb`'s archive / unarchive / Not a project tests read `get edit_project_path(...)` and `.danger-zone form[action=?] button`; a new project-page test asserts the head's one editing control:

```ruby
# ONE WAY INTO EDITING (2026-10-26, the edit area). The page is a view: Edit is its one door, and
# Customise page, the Publish link, the ⋯ menu and the Publish panel all live behind it now.
test "the project page has one way into editing" do
  get project_path(@project)
  assert_select ".head-actions a[href=?]", edit_project_path(@project), { count: 1, text: "Edit" }
  assert_select "a[href=?]", edit_layout_project_path(@project), 0
  assert_select "a[href=?]", publishing_project_path(@project), 0
  assert_select "details.project-menu, section.publish-panel, a[href='#publish']", 0
end
```

and the edit page renders the edit head with Details current and links to the other two tabs, plus `input[name=?]` `project[name]` (§14d).
- [ ] **Step 2:** run, expect FAIL.
- [ ] **Step 3: Implement.** `show.html.erb`'s `.head-actions` keeps Edit and "+ Add panel" and loses Customise page, the Publish link and the ⋯ menu (the archive confirm local moves to `edit.html.erb`). When `@editing`, the page head is `render "projects/edit_head", project: @project, current: :layout` instead of `.project-head`, and the stats line, description and tag chips are not rendered (the page-intro card carries the description in edit mode). `edit.html.erb` renders the edit head (`current: :details`), the form, then `section.panel.danger-zone` with the three `button_to`s moved verbatim (classes `btn small` / `btn small danger`).
- [ ] **Step 4:** run, expect PASS. Mutation-check the one-way test by restoring the Customise page link: RED; restore.
- [ ] Commit.

### Task 5: accents, shell, sweep

**Files:** `test/system/accent_spend_test.rb`, `test/system/shell_test.rb`, CSS

- [ ] `accent_spend_test.rb`: `/projects/desk-lamp` → `["Upload"]`; add `/projects/desk-lamp/edit` → `["Save changes"]`, `/projects/desk-lamp/publishing` → `["Save publishing"]`, `/projects/desk-lamp/layout` → `["Save"]`. Update the header comment's numbers.
- [ ] `shell_test.rb` 697/732: the phone head no longer has `.project-menu`; the publish panel check moves to the publishing page.
- [ ] Remove now-dead CSS (`.project-menu` page rules if any, `.panel-slot--pinned`), add `.edit-head`/`.edit-tabs`/`.danger-zone` rules to `pages/projects.css`.
- [ ] Grep `app/` and `test/` for `#publish`, `customise-link`, `publish-link`, `project-menu`, `"publish"`; each remaining hit is either history prose or fixed.
- [ ] Commit.

### Task 6: verify and ship

- [ ] Screenshots of the three tabs and the project page (dev server, demo).
- [ ] `TINKEREX_SYNC_DIR=/Users/charlesschwartz/Desktop/repos/tinkerex-sync SYNC_PORT=3192 bin/ci` — green, three legs equal RUN counts.
- [ ] `/finish-branch`: commit, push, PR; `bin/log arc --from-pr <n>`.
