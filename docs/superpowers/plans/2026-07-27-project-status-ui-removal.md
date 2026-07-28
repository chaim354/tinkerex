# Project Status UI Removal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Hide the five-state project status pipeline from the web UI, leaving a flat project list plus an archived view, while the `status` column and the v1 API stay exactly as they are.

**Architecture:** Views and `ProjectsController` only. `Maker::Project` gains one method (`unarchive!`) and loses nothing. There is **no migration** — see spec decision #1: `client/sync-client/src/maker.rs` declares `pub status: String` with no `serde(default)`, so dropping the field from the v1 JSON is a hard deserialize error for a shipped client, and `client/maker-app/src/projects.js` drives a status filter, badge and select off it. The web's own "is this archived" test stays what it already is today: `status == "archived"`.

**Tech Stack:** Rails 8.1, ERB views, Minitest integration tests (`ActionDispatch::IntegrationTest` under `module Web`).

**Spec:** `docs/superpowers/specs/2026-07-27-project-page-overhaul-design.md` §3.

---

## File Structure

| File | Change | Responsibility after this plan |
|---|---|---|
| `app/models/maker/project.rb` | Modify | Gains `unarchive!`. `STATUSES`, the validation, `by_status`, `active` all **stay** — the v1 API uses them. |
| `config/routes.rb` | Modify | Adds `patch :unarchive, on: :member` inside `resources :projects`. |
| `app/controllers/projects_controller.rb` | Modify | `index` partitions live/archived and serves one flat list; new `unarchive` action. `LISTED_STATUSES` removed. |
| `app/views/projects/index.html.erb` | Modify | One flat grid + an archived-view toggle. No per-status sections. |
| `app/views/projects/_card.html.erb` | Modify | Status badge removed (line 17). |
| `app/views/projects/show.html.erb` | Modify | Status badge replaced by an Archived-only badge. |
| `app/views/projects/_form.html.erb` | Modify | Status select removed. |
| `app/assets/stylesheets/projects.css` | Modify | Four unused `.badge.status-*` rules and `.project-group`/`.group-head` removed. |
| `test/models/maker/project_test.rb` | Modify | Covers `unarchive!`. |
| `test/integration/web/projects_flow_test.rb` | Modify | Covers the flat list, the archived view, and the unarchive round-trip. |

---

## Task 1: `unarchive!` on the model

**Files:**
- Modify: `app/models/maker/project.rb:41-43`
- Test: `test/models/maker/project_test.rb`

- [ ] **Step 1: Write the failing test**

Append inside `module Maker` / `class ProjectTest` in `test/models/maker/project_test.rb`:

```ruby
    test "archive! then unarchive! round-trips the lifecycle state" do
      project = @user.maker_projects.create!(name: "Old Rig")

      project.archive!
      assert_equal "archived", project.status
      assert_not_nil project.archived_at

      project.unarchive!
      assert_equal "active", project.status
      assert_nil project.archived_at
    end
```

If `@user` is not already defined in that file's `setup`, use `User.create!(email: "proj@example.com")` inline and build the project from it — check the existing `setup` block first and match it.

- [ ] **Step 2: Run the test to verify it fails**

```bash
bin/rails test test/models/maker/project_test.rb -n "/unarchive/"
```

Expected: FAIL with `NoMethodError: undefined method 'unarchive!'`.

- [ ] **Step 3: Add the method**

In `app/models/maker/project.rb`, directly below `archive!`:

```ruby
    def archive!
      update!(status: "archived", archived_at: Time.current)
    end

    # The inverse of archive!. "active" rather than the "planning" column default: a project you
    # deliberately pull back out of the archive is one you are working on again. The web UI shows
    # neither value — it reads status as archived-or-not (spec decision #1) — but the v1 API and
    # the desktop app still see the full vocabulary, so this has to name a real member of STATUSES.
    def unarchive!
      update!(status: "active", archived_at: nil)
    end
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bin/rails test test/models/maker/project_test.rb -n "/unarchive/"
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/models/maker/project.rb test/models/maker/project_test.rb
git commit -m "feat(projects): add unarchive! as the inverse of archive!"
```

---

## Task 2: The index goes flat

**Files:**
- Modify: `app/controllers/projects_controller.rb:22,26-31`
- Modify: `app/views/projects/index.html.erb`
- Modify: `app/views/projects/_card.html.erb:17`
- Test: `test/integration/web/projects_flow_test.rb:31-40`

- [ ] **Step 1: Rewrite the failing test**

In `test/integration/web/projects_flow_test.rb`, **replace** the existing test named
`"index lists the user's projects grouped by status, empty state otherwise"` with:

```ruby
    test "index lists live projects in one flat list, empty state otherwise" do
      user = sign_in
      get projects_path
      assert_response :success
      assert_select "h1", "Projects"
      assert_select ".projects-empty"

      user.maker_projects.create!(name: "Desk Lamp", status: "active")
      user.maker_projects.create!(name: "Bench Jig", status: "paused")
      user.maker_projects.create!(name: "Old Rig", status: "archived")
      get projects_path

      # One grid, no per-status sections.
      assert_select ".projects-grid", count: 1
      assert_select ".project-group", count: 0
      # A non-archived status is no longer a heading and no longer a badge.
      assert_select ".project-card .badge", count: 0
      assert_select ".project-card .project-name", text: "Desk Lamp"
      assert_select ".project-card .project-name", text: "Bench Jig"
      # Archived projects stay out of the default listing.
      assert_select ".project-card .project-name", text: "Old Rig", count: 0
    end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rails test test/integration/web/projects_flow_test.rb -n "/flat list/"
```

Expected: FAIL — `.project-group` is still rendered and each card still carries a `.badge`.

- [ ] **Step 3: Rewrite the controller's `index`**

In `app/controllers/projects_controller.rb`, delete the `LISTED_STATUSES` constant and its comment
(around line 22) and replace the `index` action with:

```ruby
  # One flat list of live projects, newest activity first. `?archived=1` swaps in the archived
  # ones. The web reads `status` as archived-or-not and never shows or sets the other four values
  # (spec decision #1) — the column, its validation and the v1 API are deliberately untouched.
  def index
    @archived_view = params[:archived].present?
    all = current_user.maker_projects.includes(:file_attachments).order(updated_at: :desc).to_a
    archived, live = all.partition { |p| p.status == "archived" }
    @projects = @archived_view ? archived : live
    @archived_count = archived.size
    @covers = Maker::Previews::ThumbnailMap.for(current_user, @projects.filter_map(&:cover_node_id))
  end
```

- [ ] **Step 4: Rewrite the index view**

Replace the whole of `app/views/projects/index.html.erb` with:

```erb
<% content_for :title, "Projects — Tinkerex" %>

<div class="page-head">
  <h1><%= @archived_view ? "Archived projects" : "Projects" %></h1>
  <%= link_to "New project", new_project_path, class: "btn primary" unless @archived_view %>
</div>

<% if @projects.empty? %>
  <p class="projects-empty muted">
    <%= @archived_view ? "No archived projects." : "No projects yet. Create your first build." %>
  </p>
<% else %>
  <div class="projects-grid" data-controller="thumbs" data-thumbs-url-value="<%= thumbnails_files_path %>">
    <% @projects.each do |project| %>
      <%= render "card", project:, thumb: @covers.thumb(project.cover_node_id) %>
    <% end %>
  </div>
<% end %>

<p class="archived-note muted">
  <% if @archived_view %>
    <%= link_to "← Back to projects", projects_path %>
  <% elsif @archived_count.positive? %>
    <%= link_to "#{@archived_count} archived project#{"s" unless @archived_count == 1}",
                projects_path(archived: 1) %>
  <% end %>
</p>
```

- [ ] **Step 5: Drop the badge from the card**

In `app/views/projects/_card.html.erb`, delete line 17:

```erb
  <span class="badge status-<%= project.status %>"><%= project.status %></span>
```

The `<%= link_to … do %>` block now ends after the `.project-name` span.

- [ ] **Step 6: Run the test to verify it passes**

```bash
bin/rails test test/integration/web/projects_flow_test.rb
```

Expected: PASS, whole file.

- [ ] **Step 7: Commit**

```bash
git add app/controllers/projects_controller.rb app/views/projects/index.html.erb \
        app/views/projects/_card.html.erb test/integration/web/projects_flow_test.rb
git commit -m "feat(projects): flat project index, no per-status sections"
```

---

## Task 3: The archived view and the Unarchive button

**Files:**
- Modify: `config/routes.rb:51`
- Modify: `app/controllers/projects_controller.rb` (new action + `set_project` + Step 0 fix)
- Modify: `app/views/projects/index.html.erb` (Step 0 fixes)
- Modify: `app/views/projects/_card.html.erb`
- Test: `test/integration/web/projects_flow_test.rb`

- [ ] **Step 0: Three carried fixes to Task 2's code**

Task 2's code-quality review raised three findings against code this plan supplied. All three live
in files Task 3 touches anyway, so they are folded in here rather than left as debt.

**(a) `?archived=0` currently renders the ARCHIVED view.** In
`app/controllers/projects_controller.rb`, `@archived_view = params[:archived].present?` is true for
*any* value including `"0"`. Nothing constructs that URL today, but this task adds UI around the
parameter, and a checkbox would submit `"0"` for "off" by Rails convention — landing the user on
the exact opposite page. Change it to an equality test:

```ruby
    # `== "1"`, not `.present?`: a checkbox submits "0" for off, and `.present?` would read that as
    # "show me the archive" — the opposite page.
    @archived_view = params[:archived] == "1"
```

**(b) The `.archived-note` paragraph renders empty when there is nothing to say.** In
`app/views/projects/index.html.erb`, wrap the whole `<p>` so a fresh install with no archived
projects doesn't get a stray empty paragraph and its default margin:

```erb
<% if @archived_view || @archived_count.positive? %>
  <p class="archived-note muted">
    <% if @archived_view %>
      <%= link_to "← Back to projects", projects_path %>
    <% else %>
      <%= link_to pluralize(@archived_count, "archived project"), projects_path(archived: 1) %>
    <% end %>
  </p>
<% end %>
```

**(c)** That block also replaces the nested string interpolation
(`"#{@archived_count} archived project#{"s" unless @archived_count == 1}"`) with Rails'
`pluralize` helper, which is what it is for.

Run the existing test after these three, before writing anything new — they must stay green:

```bash
bin/rails test test/integration/web/projects_flow_test.rb
```

- [ ] **Step 1: Write the failing test**

Append to `test/integration/web/projects_flow_test.rb`:

```ruby
    test "the archived view lists archived projects and links back" do
      user = sign_in
      user.maker_projects.create!(name: "Desk Lamp", status: "active")
      user.maker_projects.create!(name: "Old Rig", status: "archived")

      get projects_path(archived: 1)
      assert_response :success
      assert_select "h1", "Archived projects"
      assert_select ".project-card .project-name", text: "Old Rig"
      assert_select ".project-card .project-name", text: "Desk Lamp", count: 0
    end

    test "the default index links to the archived view when there are archived projects" do
      user = sign_in
      user.maker_projects.create!(name: "Old Rig", status: "archived")
      get projects_path
      assert_select ".archived-note a", text: "1 archived project"

      user.maker_projects.create!(name: "Older Rig", status: "archived")
      get projects_path
      assert_select ".archived-note a", text: "2 archived projects"
    end

    # Step 0(b): with nothing archived there is nothing to say, so the note must not render at all.
    test "the archived note is absent when nothing is archived" do
      user = sign_in
      user.maker_projects.create!(name: "Desk Lamp", status: "active")
      get projects_path
      assert_select ".archived-note", count: 0
    end

    # Step 0(a): `.present?` would have made "0" truthy and served the ARCHIVED view here.
    test "archived=0 shows the live list, not the archive" do
      user = sign_in
      user.maker_projects.create!(name: "Desk Lamp", status: "active")
      user.maker_projects.create!(name: "Old Rig", status: "archived")

      get projects_path(archived: 0)
      assert_select "h1", "Projects"
      assert_select ".project-card .project-name", text: "Desk Lamp"
      assert_select ".project-card .project-name", text: "Old Rig", count: 0
    end

    test "unarchive returns a project to the live list" do
      user = sign_in
      project = user.maker_projects.create!(name: "Old Rig", status: "archived",
                                            archived_at: Time.current)

      patch unarchive_project_path(project)
      assert_redirected_to projects_path

      project.reload
      assert_equal "active", project.status
      assert_nil project.archived_at

      get projects_path
      assert_select ".project-card .project-name", text: "Old Rig"
    end

    # `config.action_dispatch.show_exceptions = :rescuable` in the test env, so a RecordNotFound
    # from the current_user scoping arrives as a 404 RESPONSE rather than a raised exception —
    # which is why every cross-user test in this suite asserts the status, not an exception.
    test "unarchive cannot reach another user's project" do
      sign_in("a@example.com")
      other = User.create!(email: "b@example.com", password: PASSWORD, confirmed_at: Time.current)
      theirs = other.maker_projects.create!(name: "Theirs", status: "archived")

      patch unarchive_project_path(theirs)
      assert_response :not_found
      assert_equal "archived", theirs.reload.status
    end
```

- [ ] **Step 2: Run them to verify they fail**

```bash
bin/rails test test/integration/web/projects_flow_test.rb -n "/archived view|archived projects|unarchive/"
```

Expected: FAIL with `NameError: undefined local variable or method 'unarchive_project_path'`.

- [ ] **Step 3: Add the route**

In `config/routes.rb`, change the `resources :projects do` line's block to open with the member
route (insert as the first line inside the block, before `resources :attachments`):

```ruby
  resources :projects do
    # Return an archived project to the live list. A member PATCH rather than an update to a
    # `status` field: the web form no longer exposes status at all (spec decision #1).
    patch :unarchive, on: :member
```

- [ ] **Step 4: Add the controller action**

In `app/controllers/projects_controller.rb`, add `:unarchive` to the `set_project` before_action
list so it reads:

```ruby
  before_action :set_project, only: %i[show edit update destroy unarchive]
```

Then add the action immediately after `destroy`:

```ruby
  # The inverse of #destroy (which archives). Redirects to the live list, where the project has
  # just reappeared — landing back on the archived view it left would read as a no-op.
  def unarchive
    @project.unarchive!
    redirect_to projects_path, notice: "Restored #{@project.name}."
  end
```

- [ ] **Step 5: Add the Unarchive button to the card**

In `app/views/projects/_card.html.erb`, after the closing `<% end %>` of the `link_to` block, add:

```erb
<% if project.status == "archived" %>
  <%= button_to "Unarchive", unarchive_project_path(project), method: :patch, class: "linkbtn" %>
<% end %>
```

Note the button sits **outside** the `link_to` block — a `<form>` nested inside an `<a>` is invalid
HTML and the click would be swallowed by the link.

- [ ] **Step 6: Run the tests to verify they pass**

```bash
bin/rails test test/integration/web/projects_flow_test.rb
```

Expected: PASS, whole file.

- [ ] **Step 7: Commit**

```bash
git add config/routes.rb app/controllers/projects_controller.rb \
        app/views/projects/_card.html.erb test/integration/web/projects_flow_test.rb
git commit -m "feat(projects): archived view with an unarchive action"
```

---

## Task 4: Detail page, form, and CSS cleanup

**Files:**
- Modify: `app/views/projects/show.html.erb:12`
- Modify: `app/views/projects/_form.html.erb:18-21`
- Modify: `app/assets/stylesheets/projects.css:14-18,21-22`
- Test: `test/integration/web/projects_flow_test.rb`

- [ ] **Step 1: Write the failing test**

Append to `test/integration/web/projects_flow_test.rb`:

```ruby
    test "the detail page shows no status badge for a live project" do
      user = sign_in
      project = user.maker_projects.create!(name: "Desk Lamp", status: "paused")
      get project_path(project)
      assert_response :success
      assert_select "h1", "Desk Lamp"
      assert_select ".project-status", count: 0
    end

    test "the detail page badges an archived project" do
      user = sign_in
      project = user.maker_projects.create!(name: "Old Rig", status: "archived")
      get project_path(project)
      assert_select ".badge.status-archived", text: "Archived"
    end

    test "the project form offers no status select" do
      sign_in
      get new_project_path
      assert_response :success
      assert_select "select[name=?]", "project[status]", count: 0
    end
```

- [ ] **Step 2: Run them to verify they fail**

```bash
bin/rails test test/integration/web/projects_flow_test.rb -n "/status badge|badges an archived|status select/"
```

Expected: FAIL — the live project still renders `.project-status`, and the form still renders the select.

- [ ] **Step 3: Fix the show page**

In `app/views/projects/show.html.erb`, replace line 12:

```erb
    <span class="project-status badge status-<%= @project.status %>"><%= @project.status %></span>
```

with:

```erb
    <% if @project.status == "archived" %>
      <span class="badge status-archived">Archived</span>
    <% end %>
```

- [ ] **Step 4: Fix the form**

In `app/views/projects/_form.html.erb`, delete the whole Status field (lines 18-21):

```erb
  <label class="field">
    <span>Status</span>
    <%= f.select :status, Maker::Project::STATUSES.map { |s| [ s.capitalize, s ] } %>
  </label>
```

A project created from the web now takes the column default (`"planning"`), and editing from the
web leaves `status` alone. `project_params` is left as it is — it permits `:status`, which is
harmless when no field submits it, and `Maker::Project::STATUSES` is still referenced by the model
and the v1 API.

- [ ] **Step 5: Check nothing else styles a non-archived status, then trim the CSS**

```bash
grep -rn "status-active\|status-planning\|status-paused\|status-done\|project-group\|group-head" app/ test/
```

Expected: only `app/assets/stylesheets/projects.css`. (`models.css` uses the separate `mstatus-`
prefix and is not a match.) If anything else appears, stop and reconcile before deleting.

Then in `app/assets/stylesheets/projects.css` delete these six lines:

```css
.badge.status-active { background: #ecfdf5; color: #065f46; }
.badge.status-planning { background: #eff6ff; color: #1e40af; }
.badge.status-paused { background: #fffbeb; color: #92400e; }
.badge.status-done { background: #f3f4f6; color: #374151; }
```

```css
.project-group { margin-bottom: 28px; }
.group-head { font-size: 15px; margin: 0 0 12px; }
```

Keep `.badge.status-archived` — the show page and the archived card still use it.

- [ ] **Step 6: Run the full web suite to verify**

```bash
bin/rails test test/integration/web/
```

Expected: PASS. `project_build_log_test.rb`, `project_tasks_test.rb` and
`project_attachments_test.rb` all render the show page and must stay green.

- [ ] **Step 7: Commit**

```bash
git add app/views/projects/show.html.erb app/views/projects/_form.html.erb \
        app/assets/stylesheets/projects.css test/integration/web/projects_flow_test.rb
git commit -m "feat(projects): drop the status badge and select from the web UI"
```

---

## Known deferred gap (raised in review, deliberately not fixed here)

**`Maker::Project#unarchive!` has no state guard.** It is `update!(status: "active", archived_at: nil)`
with no check that the project was archived to begin with, deliberately mirroring `archive!`, which
is equally permissive. `PATCH /projects/:slug/unarchive` is reachable whatever the current status,
so a hand-crafted request against a `paused` or `done` project silently forces it to `active`.

Why it was judged non-blocking by two independent reviews: it is scoped to the requester's **own**
projects (`set_project` scopes through `current_user.maker_projects`, pinned by a cross-user test),
it is unreachable through any shipped UI (the button renders only when `status == "archived"`), and
triggering it requires deliberately hand-crafting a request against your own data.

Why it is worth writing down anyway: the web treats `status` as binary, but the value it **writes**
is not — and the v1 API and the desktop app both read the full five-value vocabulary, so a forced
`paused` → `active` is a real state change to a consumer the web cannot see. The design doc's
"recorded consequence" note in §3 covers *display* of the other statuses, not *mutation* of them.

The cheap close, whenever this is picked up: `return unless status == "archived"` in the model, or
the equivalent check in `ProjectsController#unarchive`, with a test.

---

## Task 5: Full-suite verification on all three backend legs

**Files:** none — verification only.

- [ ] **Step 1: Default (chunk) leg**

```bash
bin/rails test
```

Expected: 0 failures, 0 errors. Record the run/assertion counts.

- [ ] **Step 2: Share leg**

```bash
LIBRARY_BACKEND=share bin/rails test
```

Expected: identical counts to step 1.

- [ ] **Step 3: S3 leg**

```bash
LIBRARY_BACKEND=s3 bin/rails test
```

Expected: identical counts to step 1.

- [ ] **Step 4: Confirm the v1 API and the Rust client were not touched**

```bash
git diff --stat main -- app/controllers/v1 client/
```

Expected: **empty output.** This plan is web-only by design; any diff here means decision #1 was
violated and a shipped desktop client is about to break.

- [ ] **Step 5: Commit any incidental fixes**

Only if steps 1-3 required changes:

```bash
git add -A && git commit -m "test: fix fallout from the project status UI removal"
```
