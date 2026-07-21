# Projects Web UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a server-rendered web UI for `Maker::Project` — a list, a create/edit form, and a detail "hub" page with attached design files (thumbnail tiles), a build log, and tasks — plus cover thumbnails and an "Attach to project" action in the file browser.

**Architecture:** New session-authenticated web controllers (like `FilesController`/`TrashController`) query `Maker::*` models directly, scoped to `current_user`. Hotwire (Turbo + Stimulus) for interactivity; plain ERB + partials + `application.css`. Design-file thumbnails reuse the existing preview pipeline (`Maker::Preview`, `_thumb` partial, the `thumbs` Stimulus controller, and the `/files/thumbnails` poll endpoint). The file library being unreachable degrades thumbnails only — never the page. Stays on the maker side of the FileLayer port's **read** surface (`stat_all`) — no sync/changelog/conflict/lock/mount code (CLAUDE.md §10).

**Tech Stack:** Rails 8, Devise (web session auth), Hotwire (turbo-rails, stimulus-rails), importmap, Propshaft, plain CSS, Minitest integration tests.

**Branch:** `projects-web-ui` (already checked out; the design spec commit is its first commit).

**Spec:** `docs/superpowers/specs/2026-07-21-projects-web-ui-design.md`

**Conventions for every commit in this plan:**
- Conventional-commit subjects (`feat(projects): …`, `test(projects): …`).
- End every commit message with the trailer:
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
- Run tests with `bin/rails test <path>`; run the whole web suite with `bin/rails test test/integration/web`.

**v1 scope note (read before starting):** Attaching a file means **attach an existing library file** (a file already uploaded via the Files UI), plus the "Attach to project" action from the file browser. **Inline upload-and-attach** (uploading a brand-new file from inside the project page) is deliberately **out of this plan** — it would re-implement the capability-branched uploader (chunk two-phase vs. share/s3 multipart). Build-log photos likewise attach *existing* image files. This keeps the plan free of the sync/upload machinery and is called out in the execution handoff so it can be added as a fast-follow if wanted.

---

## File map

**Create:**
- `app/controllers/projects_controller.rb` — list, new, create, show, edit, update, destroy(→archive)
- `app/controllers/projects/attachments_controller.rb` — attach existing / detach (nested)
- `app/controllers/projects/build_log_entries_controller.rb` — add / delete log entries + entry photos
- `app/controllers/projects/tasks_controller.rb` — add / update / reorder / delete tasks
- `app/services/maker/previews/thumbnail_map.rb` — degrade-safe current-thumbnail resolver
- `app/helpers/projects_helper.rb` — small view helpers (status label, cover tag)
- `app/views/projects/index.html.erb`, `_card.html.erb`, `new.html.erb`, `edit.html.erb`, `_form.html.erb`, `show.html.erb`
- `app/views/projects/_attachments.html.erb`, `_attachment_picker.html.erb`, `_build_log.html.erb`, `_log_entry.html.erb`, `_tasks.html.erb`, `_task.html.erb`
- `test/integration/web/projects_flow_test.rb`
- `test/integration/web/project_attachments_test.rb`
- `test/integration/web/project_build_log_test.rb`
- `test/integration/web/project_tasks_test.rb`
- `test/integration/web/attach_from_files_test.rb`
- `test/services/maker/previews/thumbnail_map_test.rb`

**Modify:**
- `config/routes.rb` — add web `resources :projects` with nested attachments/build_log_entries/tasks
- `app/models/maker/project.rb` — `to_param`, `cover_node_id`
- `app/models/maker/file_attachment.rb` — `role_for(name)` class method
- `app/views/layouts/application.html.erb` — "Projects" nav link
- `app/controllers/files_controller.rb` — load `@projects` for the attach-to-project control in `#show`
- `app/views/files/show.html.erb` — the "Attach to project" control
- `app/assets/stylesheets/application.css` — styles for the new classes

---

## Task 1: Scaffold — routes, controller, index, nav

**Files:**
- Modify: `config/routes.rb`
- Create: `app/controllers/projects_controller.rb`
- Create: `app/views/projects/index.html.erb`
- Create: `app/views/projects/_card.html.erb`
- Modify: `app/views/layouts/application.html.erb:32`
- Create: `test/integration/web/projects_flow_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/integration/web/projects_flow_test.rb`:

```ruby
require "test_helper"

module Web
  class ProjectsFlowTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    def sign_in(email = "maker@example.com")
      user = User.find_by(email:) ||
             User.create!(email:, password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email:, password: PASSWORD } }
      user
    end

    test "requires login" do
      get projects_path
      assert_redirected_to new_user_session_path
    end

    test "index lists the user's projects grouped by status, empty state otherwise" do
      user = sign_in
      get projects_path
      assert_response :success
      assert_select "h1", "Projects"
      assert_select ".projects-empty"

      user.maker_projects.create!(name: "Desk Lamp", status: "active")
      user.maker_projects.create!(name: "Old Rig", status: "archived")
      get projects_path
      assert_select ".project-card .project-name", text: "Desk Lamp"
      # Archived projects are not in the default (non-archived) listing.
      assert_select ".project-card .project-name", text: "Old Rig", count: 0
    end

    test "index shows only the current user's projects" do
      sign_in("a@example.com").maker_projects.create!(name: "Mine")
      other = User.create!(email: "b@example.com", password: PASSWORD, confirmed_at: Time.current)
      other.maker_projects.create!(name: "Theirs")
      get projects_path
      assert_select ".project-name", text: "Mine"
      assert_select ".project-name", text: "Theirs", count: 0
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/integration/web/projects_flow_test.rb`
Expected: FAIL — `projects_path` undefined (no route).

- [ ] **Step 3: Add the routes**

In `config/routes.rb`, immediately after the `resources :files … end` block (around line 43), add:

```ruby
  # --- Maker: Projects (server-rendered web UI, session auth) ---
  # The maker product hub. Uses Maker::* models directly (NOT the device-token /v1/maker API).
  resources :projects do
    resources :attachments, only: %i[new create destroy], module: :projects, shallow: true
    resources :build_log_entries, only: %i[create destroy], module: :projects, shallow: true
    resources :tasks, only: %i[create update destroy], module: :projects, shallow: true
  end
```

- [ ] **Step 4: Add `to_param` to the Project model**

In `app/models/maker/project.rb`, after the `scope :active …` line (line 23), add:

```ruby
    # Friendly, user-scoped URLs (/projects/desk-lamp). Slugs are unique per user, so a
    # current_user-scoped find_by(slug:) is unambiguous. Does NOT change JSON `id` (the v1 API
    # serializes explicit fields / #id), only URL generation.
    def to_param = slug
```

- [ ] **Step 5: Create the controller**

Create `app/controllers/projects_controller.rb`:

```ruby
# Server-rendered web UI for the maker Projects hub: list, create, edit, and a detail page
# tying together a build log, attached design files, and tasks.
#
# Maker data is backend-neutral: it does not live in the file library, so the file backend being
# unreachable degrades design-file THUMBNAILS (see Maker::Previews::ThumbnailMap) but never the
# page. This controller stays on the maker side of the FileLayer port — it only READS file
# metadata (never writes/moves/deletes bytes), so none of the §10 tripwire surfaces are touched.
class ProjectsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_project, only: %i[show edit update destroy]

  # STATUS order for the grouped list; `archived` is intentionally excluded from the default view.
  LISTED_STATUSES = %w[planning active paused done].freeze

  def index
    projects = current_user.maker_projects.order(updated_at: :desc).to_a
    @by_status = projects.reject { |p| p.status == "archived" }.group_by(&:status)
    @archived_count = projects.count { |p| p.status == "archived" }
    @covers = Maker::Previews::ThumbnailMap.for(current_user, projects.filter_map(&:cover_node_id))
  end

  def show
    @attachments = @project.file_attachments.order(:position).to_a
    att_ids = @attachments.map(&:node_id)
    @att_nodes = current_user.nodes.present.where(node_id: att_ids).index_by(&:node_id)
    @thumbs = Maker::Previews::ThumbnailMap.for(current_user, att_ids)
    # `reorder`, NOT `order`: the association default-scopes `order(:logged_at)` (asc), and a bare
    # `.order(logged_at: :desc)` would append -> `ORDER BY logged_at, logged_at DESC`, where the
    # asc column wins. reorder replaces it, giving a genuine newest-first timeline.
    @entries = @project.build_log_entries.reorder(logged_at: :desc).to_a
    @tasks = @project.tasks.order(:position, :created_at).to_a
  end

  def new
    @project = current_user.maker_projects.new(status: "planning")
  end

  def create
    @project = current_user.maker_projects.new(project_params)
    if @project.save
      redirect_to project_path(@project), notice: "Project created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit; end

  def update
    if @project.update(project_params)
      redirect_to project_path(@project), notice: "Project updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  # Soft archive — the model's lifecycle op (keeps the record + its history). Hard delete is a
  # deliberately deferred secondary affordance.
  def destroy
    @project.archive!
    redirect_to projects_path, notice: "Archived #{@project.name}."
  end

  private

  def set_project
    @project = current_user.maker_projects.find_by!(slug: params[:id])
  end

  def project_params
    params.require(:project).permit(:name, :description, :status)
  end
end
```

- [ ] **Step 6: Create a placeholder ThumbnailMap so index renders**

Task 5 builds this out with tests. For now create the minimal degrade-safe version so `index`/`show` load. Create `app/services/maker/previews/thumbnail_map.rb`:

```ruby
module Maker
  module Previews
    # Resolve the CURRENT-version thumbnail for a set of file-library node_ids, degrade-safe.
    #
    # A thumbnail is keyed by (node_id, content_token); the token comes from the FileLayer port.
    # If the backend is unreachable (FetchError), we return an empty map so callers show a spinner
    # /icon rather than 503-ing a page of maker data that does not depend on the file backend.
    class ThumbnailMap
      def self.for(user, node_ids)
        ids = node_ids.compact.uniq
        info =
          if ids.empty?
            {}
          else
            begin
              FileLayer.current.stat_all(user, node_ids: ids)
            rescue FileLayer::FetchError
              {}
            end
          end
        tokens = info.transform_values(&:content_token)
        previews =
          if tokens.values.compact.empty?
            {}
          else
            user.maker_previews
                .where(kind: "thumbnail", node_id: ids, version_id: tokens.values.compact)
                .index_by { |p| [ p.node_id, p.version_id ] }
          end
        new(tokens:, previews:)
      end

      def initialize(tokens:, previews:)
        @tokens = tokens
        @previews = previews
      end

      # The Maker::Preview for a node's current content, or nil (nil => spinner in _thumb).
      def thumb(node_id)
        token = @tokens[node_id]
        token && @previews[[ node_id, token ]]
      end
    end
  end
end
```

- [ ] **Step 7: Add a `cover_node_id` stub to Project**

Task 8 implements the real derivation. For now (so `index` runs) add to `app/models/maker/project.rb`, after `to_param`:

```ruby
    # The node_id whose thumbnail represents this project on the list. Implemented in Task 8.
    def cover_node_id = nil
```

- [ ] **Step 8: Create the index view**

Create `app/views/projects/index.html.erb`:

```erb
<% content_for :title, "Projects — Tinkerex" %>

<div class="page-head">
  <h1>Projects</h1>
  <%= link_to "New project", new_project_path, class: "btn primary" %>
</div>

<% if @by_status.values.flatten.empty? && @archived_count.zero? %>
  <p class="projects-empty muted">No projects yet. Create your first build.</p>
<% else %>
  <% ProjectsController::LISTED_STATUSES.each do |status| %>
    <% projects = @by_status[status] %>
    <% next if projects.blank? %>
    <section class="project-group">
      <h2 class="group-head"><%= status.capitalize %> <span class="muted">(<%= projects.size %>)</span></h2>
      <div class="projects-grid">
        <% projects.each do |project| %>
          <%= render "card", project:, thumb: @covers.thumb(project.cover_node_id) %>
        <% end %>
      </div>
    </section>
  <% end %>

  <% if @archived_count.positive? %>
    <p class="muted archived-note"><%= @archived_count %> archived project<%= "s" unless @archived_count == 1 %>.</p>
  <% end %>
<% end %>
```

- [ ] **Step 9: Create the card partial**

Create `app/views/projects/_card.html.erb`:

```erb
<%#
  One project on the list. `thumb` is a Maker::Preview or nil (cover). The `.file-cell` +
  data-node-id wiring lets the shared `thumbs` controller poll a pending cover to ready — but only
  when a cover node exists. No cover -> a neutral placeholder, never a forever-spinner.
%>
<%= link_to project_path(project), class: "project-card" do %>
  <% if project.cover_node_id %>
    <span class="thumb file-cell" data-thumbs-target="cell"
          data-node-id="<%= project.cover_node_id %>" data-ext="">
      <%= render "files/thumb", thumb:, ext_label: "" %>
    </span>
  <% else %>
    <span class="thumb project-thumb-empty" aria-hidden="true">📦</span>
  <% end %>
  <span class="project-name"><%= project.name %></span>
  <span class="badge status-<%= project.status %>"><%= project.status %></span>
<% end %>
```

Wrap the grid so the `thumbs` poll drives the cover cells. Change the `projects-grid` div in `index.html.erb` (Step 8) to include the controller — replace `<div class="projects-grid">` with:

```erb
      <div class="projects-grid" data-controller="thumbs" data-thumbs-url-value="<%= thumbnails_files_path %>">
```

- [ ] **Step 10: Add the nav link**

In `app/views/layouts/application.html.erb`, after the Files link (line 31), add:

```erb
          <%= link_to "Projects", projects_path, class: "linkbtn" %>
```

- [ ] **Step 11: Run the test to verify it passes**

Run: `bin/rails test test/integration/web/projects_flow_test.rb`
Expected: PASS (3 tests).

- [ ] **Step 12: Commit**

```bash
git add config/routes.rb app/controllers/projects_controller.rb app/models/maker/project.rb \
  app/services/maker/previews/thumbnail_map.rb app/views/projects app/views/layouts/application.html.erb \
  test/integration/web/projects_flow_test.rb
git commit -m "feat(projects): projects list + nav (grouped by status)"
```

---

## Task 2: Create a project

**Files:**
- Create: `app/views/projects/new.html.erb`, `app/views/projects/_form.html.erb`
- Test: `test/integration/web/projects_flow_test.rb` (add cases)

- [ ] **Step 1: Write the failing tests**

Add to `test/integration/web/projects_flow_test.rb` (inside the class):

```ruby
    test "create a project with valid params" do
      sign_in
      get new_project_path
      assert_response :success
      assert_select "form"

      assert_difference "Maker::Project.count", 1 do
        post projects_path, params: { project: { name: "Smart Lamp", status: "active", description: "RGB" } }
      end
      project = Maker::Project.order(:created_at).last
      assert_redirected_to project_path(project)
      assert_equal "smart-lamp", project.slug
      follow_redirect!
      assert_select "h1", text: /Smart Lamp/
    end

    test "create with a blank name re-renders the form with an error" do
      sign_in
      assert_no_difference "Maker::Project.count" do
        post projects_path, params: { project: { name: "" } }
      end
      assert_response :unprocessable_entity
      assert_select "form"
    end
```

- [ ] **Step 2: Run to verify failure**

Run: `bin/rails test test/integration/web/projects_flow_test.rb -n /create/`
Expected: FAIL — missing `new`/`_form` templates.

- [ ] **Step 3: Create the form partial**

Create `app/views/projects/_form.html.erb`:

```erb
<%= form_with model: project, url: (project.persisted? ? project_path(project) : projects_path),
              method: (project.persisted? ? :patch : :post), class: "project-form" do |f| %>
  <% if project.errors.any? %>
    <div class="form-errors flash-alert">
      <%= project.errors.full_messages.to_sentence %>
    </div>
  <% end %>

  <label class="field">
    <span>Name</span>
    <%= f.text_field :name, required: true, autofocus: true %>
  </label>

  <label class="field">
    <span>Status</span>
    <%= f.select :status, Maker::Project::STATUSES.map { |s| [ s.capitalize, s ] } %>
  </label>

  <label class="field">
    <span>Description</span>
    <%= f.text_area :description, rows: 5, placeholder: "What are you building?" %>
  </label>

  <div class="form-actions">
    <%= f.submit(project.persisted? ? "Save changes" : "Create project", class: "btn primary") %>
    <%= link_to "Cancel", (project.persisted? ? project_path(project) : projects_path), class: "linkbtn" %>
  </div>
<% end %>
```

- [ ] **Step 4: Create the new view**

Create `app/views/projects/new.html.erb`:

```erb
<% content_for :title, "New project — Tinkerex" %>
<div class="page-head"><h1>New project</h1></div>
<%= render "form", project: @project %>
```

- [ ] **Step 5: Run to verify pass**

Run: `bin/rails test test/integration/web/projects_flow_test.rb -n /create/`
Expected: PASS. (The `show` template does not exist yet — the redirect-follow asserts the `h1`; if `show` is missing this fails, so build Task 3 first if running the full follow-through. To keep this task green in isolation, the create test's `follow_redirect!` needs `show`. **Reorder note:** implement Task 3's `show.html.erb` before running this step's `follow_redirect!` assertion, or split: assert `assert_redirected_to` only here and move the `follow_redirect!` assertion to Task 3.)

**Do this:** in Step 1's first test, delete the `follow_redirect!` + `assert_select "h1"` lines for now; they are re-added in Task 3. The `assert_redirected_to project_path(project)` line stays.

- [ ] **Step 6: Commit**

```bash
git add app/views/projects/new.html.erb app/views/projects/_form.html.erb \
  test/integration/web/projects_flow_test.rb
git commit -m "feat(projects): create-project form"
```

---

## Task 3: Detail page skeleton + lifecycle (edit/update/archive)

**Files:**
- Create: `app/views/projects/show.html.erb`, `app/views/projects/edit.html.erb`
- Test: `test/integration/web/projects_flow_test.rb` (add cases)

- [ ] **Step 1: Write the failing tests**

Add to `test/integration/web/projects_flow_test.rb`:

```ruby
    test "show renders the project header, status, and description" do
      user = sign_in
      project = user.maker_projects.create!(name: "Desk Lamp", status: "active",
                                            description: "A nice lamp")
      get project_path(project)
      assert_response :success
      assert_select "h1", text: /Desk Lamp/
      assert_select ".project-status", text: /active/i
      assert_select ".project-description", text: /A nice lamp/
    end

    test "show 404s for another user's project" do
      sign_in("a@example.com")
      other = User.create!(email: "b@example.com", password: PASSWORD, confirmed_at: Time.current)
      p = other.maker_projects.create!(name: "Theirs")
      get project_path(p)   # slug-based path; a's scope has no such slug
      assert_response :not_found
    end

    test "edit + update changes fields" do
      user = sign_in
      project = user.maker_projects.create!(name: "Old", status: "planning")
      get edit_project_path(project)
      assert_response :success
      patch project_path(project), params: { project: { name: "New", status: "paused" } }
      project.reload
      assert_equal "New", project.name
      assert_equal "paused", project.status
      assert_redirected_to project_path(project)
    end

    test "destroy archives (soft) rather than deleting" do
      user = sign_in
      project = user.maker_projects.create!(name: "Done Build", status: "active")
      assert_no_difference "Maker::Project.count" do
        delete project_path(project)
      end
      assert_equal "archived", project.reload.status
      assert_redirected_to projects_path
    end
```

Also re-add the follow-through removed in Task 2 Step 5 — in the "create a project with valid params" test, append after `assert_redirected_to`:

```ruby
      follow_redirect!
      assert_select "h1", text: /Smart Lamp/
```

- [ ] **Step 2: Run to verify failure**

Run: `bin/rails test test/integration/web/projects_flow_test.rb -n /show|edit|update|archive|valid/`
Expected: FAIL — `show`/`edit` templates missing.

- [ ] **Step 3: Create the show view (skeleton; panels are added by later tasks)**

Create `app/views/projects/show.html.erb`:

```erb
<% content_for :title, "#{@project.name} — Tinkerex" %>

<nav class="breadcrumb" aria-label="Project path">
  <%= link_to "Projects", projects_path %>
  <span class="sep" aria-hidden="true">/</span>
  <span aria-current="page"><%= @project.name %></span>
</nav>

<div class="page-head project-head">
  <div>
    <h1><%= @project.name %></h1>
    <span class="project-status badge status-<%= @project.status %>"><%= @project.status %></span>
  </div>
  <div class="head-actions">
    <%= link_to "Edit", edit_project_path(@project), class: "linkbtn" %>
    <%= button_to "Archive", project_path(@project), method: :delete, class: "linkbtn danger",
                  form: { data: { turbo_confirm: "Archive #{@project.name}?" } } %>
  </div>
</div>

<% if @project.description.present? %>
  <p class="project-description"><%= @project.description %></p>
<% end %>

<div class="project-panels">
  <%= render "attachments" %>
  <%= render "build_log" %>
  <%= render "tasks" %>
</div>
```

- [ ] **Step 4: Create empty panel partials (filled in by later tasks)**

Create placeholder partials so `show` renders now. Create `app/views/projects/_attachments.html.erb`:

```erb
<section class="panel attachments-panel">
  <h2>Files</h2>
  <p class="muted">No files attached yet.</p>
</section>
```

Create `app/views/projects/_build_log.html.erb`:

```erb
<section class="panel build-log-panel">
  <h2>Build log</h2>
  <p class="muted">No entries yet.</p>
</section>
```

Create `app/views/projects/_tasks.html.erb`:

```erb
<section class="panel tasks-panel">
  <h2>Tasks</h2>
  <p class="muted">No tasks yet.</p>
</section>
```

- [ ] **Step 5: Create the edit view**

Create `app/views/projects/edit.html.erb`:

```erb
<% content_for :title, "Edit #{@project.name} — Tinkerex" %>
<div class="page-head"><h1>Edit project</h1></div>
<%= render "form", project: @project %>
```

- [ ] **Step 6: Run to verify pass**

Run: `bin/rails test test/integration/web/projects_flow_test.rb`
Expected: PASS (all Task 1–3 cases).

- [ ] **Step 7: Commit**

```bash
git add app/views/projects/show.html.erb app/views/projects/edit.html.erb \
  app/views/projects/_attachments.html.erb app/views/projects/_build_log.html.erb \
  app/views/projects/_tasks.html.erb test/integration/web/projects_flow_test.rb
git commit -m "feat(projects): detail page + edit/update/archive"
```

---

## Task 4: ThumbnailMap — degrade-safe, unit-tested

**Files:**
- Modify: `app/services/maker/previews/thumbnail_map.rb` (already created in Task 1; add nothing unless a test forces it)
- Create: `test/services/maker/previews/thumbnail_map_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/services/maker/previews/thumbnail_map_test.rb`:

```ruby
require "test_helper"

module Maker
  module Previews
    class ThumbnailMapTest < ActiveSupport::TestCase
      setup do
        pin_file_layer_backend("chunk")
        Storage::ChunkStore.reset!
        @user = User.create!(email: "tm@example.com", confirmed_at: Time.current, omniauth_signup: true)
      end

      test "returns the ready thumbnail for a node's current content token" do
        node_id = "node-1"
        token = "tok-1"
        @user.nodes.create!(node_id:, name: "part.stl", kind: "file")
        # A version so the chunk backend's stat_all can answer a content_token for this node.
        FileLayer.current.stub :stat_all, { node_id => Struct.new(:content_token).new(token) } do
          p = @user.maker_previews.create!(node_id:, version_id: token, kind: "thumbnail", status: "ready")
          map = ThumbnailMap.for(@user, [ node_id ])
          assert_equal p, map.thumb(node_id)
        end
      end

      test "nil when there is no preview row for the current token" do
        node_id = "node-2"
        FileLayer.current.stub :stat_all, { node_id => Struct.new(:content_token).new("tok") } do
          assert_nil ThumbnailMap.for(@user, [ node_id ]).thumb(node_id)
        end
      end

      test "degrades to empty (no raise) when the backend is unreachable" do
        node_id = "node-3"
        FileLayer.current.stub :stat_all, ->(*) { raise FileLayer::FetchError, "nas down" } do
          map = ThumbnailMap.for(@user, [ node_id ])
          assert_nil map.thumb(node_id)   # no thumbnail, but the call did not raise
        end
      end

      test "empty input never touches the port" do
        FileLayer.current.stub :stat_all, ->(*) { raise "should not be called" } do
          assert_nil ThumbnailMap.for(@user, []).thumb("x")
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run to verify pass/fail**

Run: `bin/rails test test/services/maker/previews/thumbnail_map_test.rb`
Expected: The Task 1 implementation should PASS all four. If the "unreachable" case raises, confirm the `rescue FileLayer::FetchError` is present in `thumbnail_map.rb`.

- [ ] **Step 3: Commit**

```bash
git add test/services/maker/previews/thumbnail_map_test.rb app/services/maker/previews/thumbnail_map.rb
git commit -m "test(projects): pin ThumbnailMap degrade-safe behavior"
```

---

## Task 5: Attachments panel — render tiles

**Files:**
- Modify: `app/views/projects/_attachments.html.erb`
- Create: `test/integration/web/project_attachments_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/integration/web/project_attachments_test.rb`:

```ruby
require "test_helper"

module Web
  class ProjectAttachmentsTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      pin_file_layer_backend("chunk")
      Storage::ChunkStore.reset!
    end

    def sign_in(email = "maker@example.com")
      user = User.find_by(email:) ||
             User.create!(email:, password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email:, password: PASSWORD } }
      user
    end

    # Seed a library node + attach it to a project via the model (attach UI is Task 6).
    def attach_node(user, project, name:, node_id:, role: "model")
      user.nodes.create!(node_id:, name:, kind: "file")
      project.file_attachments.create!(user:, node_id:, role:)
    end

    test "attached files render as tiles linking to the file view" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      attach_node(user, project, name: "base.stl", node_id: "n-1", role: "model")

      get project_path(project)
      assert_response :success
      assert_select ".attachments-panel .attachment-tile", 1
      assert_select ".attachment-tile a[href=?]", file_path("n-1")
      assert_select ".attachment-tile .badge", text: /model/
    end

    test "a missing/deleted attached node degrades to an unavailable placeholder, never a 500" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      # Attachment row whose node_id has no live Node (deleted / never present).
      project.file_attachments.create!(user:, node_id: "gone", role: "model", label: "ghost.stl")

      get project_path(project)
      assert_response :success
      assert_select ".attachment-tile.unavailable"
    end
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `bin/rails test test/integration/web/project_attachments_test.rb`
Expected: FAIL — the placeholder panel has no `.attachment-tile`.

- [ ] **Step 3: Implement the attachments panel**

Replace `app/views/projects/_attachments.html.erb` with:

```erb
<%#
  Attached design files as thumbnail tiles. `@att_nodes` (node_id => Node) is the source of truth
  for name + availability — a DB fact, independent of the file backend. `@thumbs` (ThumbnailMap) is
  best-effort. A node not in @att_nodes (deleted/missing) renders as an unavailable placeholder,
  never a broken image or a 500. The `thumbs` controller polls pending cells via /files/thumbnails.
%>
<section class="panel attachments-panel">
  <div class="panel-head">
    <h2>Files</h2>
    <%= link_to "Attach a file", new_project_attachment_path(@project), class: "linkbtn" %>
  </div>

  <% if @attachments.empty? %>
    <p class="muted">No files attached yet.</p>
  <% else %>
    <div class="attachments-grid" data-controller="thumbs" data-thumbs-url-value="<%= thumbnails_files_path %>">
      <% @attachments.each do |att| %>
        <% node = @att_nodes[att.node_id] %>
        <% if node %>
          <% ext = File.extname(node.name).delete(".").upcase.first(4) %>
          <div class="attachment-tile">
            <%= link_to file_path(att.node_id), class: "grid-card file-cell",
                        data: { thumbs_target: "cell", node_id: att.node_id, ext: ext } do %>
              <%= render "files/thumb", thumb: @thumbs.thumb(att.node_id), ext_label: ext %>
              <span class="grid-name"><%= node.name %></span>
            <% end %>
            <div class="tile-meta">
              <span class="badge role-<%= att.role %>"><%= att.role %></span>
              <%= button_to "Detach", attachment_path(att), method: :delete, class: "linkbtn danger",
                            form: { data: { turbo_confirm: "Detach #{node.name}? (the file itself is kept)" } } %>
            </div>
          </div>
        <% else %>
          <div class="attachment-tile unavailable">
            <span class="thumb">⚠️</span>
            <span class="grid-name"><%= att.label.presence || "(file unavailable)" %></span>
            <div class="tile-meta">
              <%= button_to "Remove", attachment_path(att), method: :delete, class: "linkbtn danger" %>
            </div>
          </div>
        <% end %>
      <% end %>
    </div>
  <% end %>
</section>
```

- [ ] **Step 4: Run to verify pass**

Run: `bin/rails test test/integration/web/project_attachments_test.rb`
Expected: FAIL still — `new_project_attachment_path` and `attachment_path` need the controller (Task 6) for the routes to generate. The routes EXIST (Task 1), so the path helpers resolve; the tiles render. This step should PASS for rendering. If `button_to`/`link_to` to those paths raise, confirm Task 1 Step 3 routes are in place.

- [ ] **Step 5: Commit**

```bash
git add app/views/projects/_attachments.html.erb test/integration/web/project_attachments_test.rb
git commit -m "feat(projects): attachments panel — thumbnail tiles + graceful degrade"
```

---

## Task 6: Attach existing file + detach

**Files:**
- Modify: `app/models/maker/file_attachment.rb` (add `role_for`)
- Create: `app/controllers/projects/attachments_controller.rb`
- Create: `app/views/projects/_attachment_picker.html.erb`, `app/views/projects/attachments/new.html.erb`
- Test: `test/integration/web/project_attachments_test.rb` (add cases)

- [ ] **Step 1: Write the failing tests**

Add to `test/integration/web/project_attachments_test.rb`:

```ruby
    test "attach picker lists the user's recent files and searches by name" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      user.nodes.create!(node_id: "f-1", name: "bracket.stl", kind: "file")
      user.nodes.create!(node_id: "f-2", name: "manual.pdf", kind: "file")

      get new_project_attachment_path(project)
      assert_response :success
      assert_select ".picker-result", 2

      get new_project_attachment_path(project), params: { q: "bracket" }
      assert_select ".picker-result", 1
      assert_select ".picker-result", text: /bracket.stl/
    end

    test "attach creates a reference with an inferred role" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      user.nodes.create!(node_id: "f-1", name: "bracket.stl", kind: "file")

      assert_difference "project.file_attachments.count", 1 do
        post project_attachments_path(project), params: { node_id: "f-1" }
      end
      assert_equal "model", project.file_attachments.last.role   # .stl -> model
      assert_redirected_to project_path(project)
    end

    test "attach refuses a node the user does not own" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      other = User.create!(email: "z@example.com", password: PASSWORD, confirmed_at: Time.current)
      other.nodes.create!(node_id: "theirs", name: "secret.stl", kind: "file")

      assert_no_difference "Maker::FileAttachment.count" do
        post project_attachments_path(project), params: { node_id: "theirs" }
      end
      assert_redirected_to new_project_attachment_path(project)
    end

    test "detach removes the reference but never the library node" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      user.nodes.create!(node_id: "f-1", name: "bracket.stl", kind: "file")
      att = project.file_attachments.create!(user:, node_id: "f-1", role: "model")

      assert_difference "Maker::FileAttachment.count", -1 do
        delete attachment_path(att)
      end
      assert user.nodes.present.exists?(node_id: "f-1"), "the library file must survive a detach"
      assert_redirected_to project_path(project)
    end
```

- [ ] **Step 2: Run to verify failure**

Run: `bin/rails test test/integration/web/project_attachments_test.rb -n /picker|attach|detach/`
Expected: FAIL — `Projects::AttachmentsController` missing.

- [ ] **Step 3: Add `role_for` to the FileAttachment model**

In `app/models/maker/file_attachment.rb`, after the `ROLES` constant (line 8), add:

```ruby
    ROLE_BY_EXT = {
      "stl" => "model", "3mf" => "model", "obj" => "model", "step" => "model", "stp" => "model",
      "png" => "image", "jpg" => "image", "jpeg" => "image", "gif" => "image", "webp" => "image", "bmp" => "image",
      "pdf" => "instructions", "gcode" => "gcode", "gco" => "gcode", "zip" => "source_archive"
    }.freeze

    # Best-effort role from a filename's extension; unknown -> "other".
    def self.role_for(name)
      ROLE_BY_EXT.fetch(File.extname(name.to_s).downcase.delete("."), "other")
    end
```

- [ ] **Step 4: Create the attachments controller**

Create `app/controllers/projects/attachments_controller.rb`:

```ruby
module Projects
  # Attach an EXISTING library file to a project (or detach it). "Attach" creates a reference
  # (node_id + role); it never moves or uploads bytes, so no capability gating and no §10 surface.
  # Ownership is a DB fact (current_user.nodes) — deliberately NOT a FileLayer.stat check, so an
  # unmounted backend cannot block attaching a file the user demonstrably owns.
  class AttachmentsController < ApplicationController
    before_action :authenticate_user!
    before_action :set_project, only: %i[new create]

    RECENT_LIMIT = 40

    # GET /projects/:project_id/attachments/new?q= — the picker: search by name + recent files.
    def new
      scope = current_user.nodes.present.where(kind: "file")
      scope = scope.where("name LIKE ?", "%#{sanitize_sql_like(params[:q])}%") if params[:q].present?
      @results = scope.order(updated_at: :desc).limit(RECENT_LIMIT).to_a
    end

    # POST /projects/:project_id/attachments { node_id }
    def create
      node = current_user.nodes.present.find_by(node_id: params.require(:node_id))
      unless node
        return redirect_to new_project_attachment_path(@project), alert: "That file isn't in your library."
      end
      @project.file_attachments.create!(user: current_user, node_id: node.node_id,
                                        role: Maker::FileAttachment.role_for(node.name))
      redirect_to project_path(@project), notice: "Attached #{node.name}."
    end

    # DELETE /attachments/:id (shallow) — remove the reference only; the library file is untouched.
    def destroy
      att = current_user.maker_file_attachments.find(params[:id])
      project = att.attachable
      att.destroy!
      redirect_back_or_to project_path(project), notice: "Detached."
    end

    private

    def set_project
      @project = current_user.maker_projects.find_by!(slug: params[:project_id])
    end

    def sanitize_sql_like(str) = ActiveRecord::Base.sanitize_sql_like(str.to_s)
  end
end
```

Note: `att.attachable` is the Project (polymorphic). `redirect_back_or_to` handles detach initiated from either the project page or (later) elsewhere.

- [ ] **Step 5: Create the picker view**

Create `app/views/projects/attachments/new.html.erb`:

```erb
<% content_for :title, "Attach a file — Tinkerex" %>

<div class="page-head"><h1>Attach a file to <%= @project.name %></h1></div>

<%= form_with url: new_project_attachment_path(@project), method: :get, class: "picker-search" do |f| %>
  <%= f.search_field :q, value: params[:q], placeholder: "Search your library by name…", autofocus: true %>
  <%= f.submit "Search", class: "btn" %>
<% end %>

<% if @results.empty? %>
  <p class="muted">No files found<%= " for “#{params[:q]}”" if params[:q].present? %>.</p>
<% else %>
  <div class="picker-results">
    <% @results.each do |node| %>
      <div class="picker-result">
        <span class="picker-name"><%= node.name %></span>
        <%= button_to "Attach", project_attachments_path(@project), params: { node_id: node.node_id },
                      class: "btn small" %>
      </div>
    <% end %>
  </div>
<% end %>

<p><%= link_to "← Back to project", project_path(@project), class: "linkbtn" %></p>
```

- [ ] **Step 6: Run to verify pass**

Run: `bin/rails test test/integration/web/project_attachments_test.rb`
Expected: PASS (all attachment cases).

- [ ] **Step 7: Commit**

```bash
git add app/models/maker/file_attachment.rb app/controllers/projects/attachments_controller.rb \
  app/views/projects/attachments/new.html.erb test/integration/web/project_attachments_test.rb
git commit -m "feat(projects): attach existing file (picker) + detach"
```

---

## Task 7: Cover thumbnails

**Files:**
- Modify: `app/models/maker/project.rb` (real `cover_node_id`)
- Test: `test/integration/web/projects_flow_test.rb` (add case)

- [ ] **Step 1: Write the failing test**

Add to `test/integration/web/projects_flow_test.rb`:

```ruby
    test "cover_node_id prefers image, then model, then first attachment, else nil" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      assert_nil project.cover_node_id

      project.file_attachments.create!(user:, node_id: "m1", role: "model", position: 0)
      project.file_attachments.create!(user:, node_id: "i1", role: "image", position: 1)
      assert_equal "i1", project.reload.cover_node_id, "an image cover wins over a model"

      project.file_attachments.destroy_all
      project.file_attachments.create!(user:, node_id: "src", role: "source_archive", position: 0)
      project.file_attachments.create!(user:, node_id: "m2", role: "model", position: 1)
      assert_equal "m2", project.reload.cover_node_id, "a model wins over a non-image/non-model"
    end

    test "a project card shows a cover cell when it has an attachment" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp", status: "active")
      user.nodes.create!(node_id: "c1", name: "cover.png", kind: "file")
      project.file_attachments.create!(user:, node_id: "c1", role: "image")

      get projects_path
      assert_select ".project-card .file-cell[data-node-id=?]", "c1"
    end
```

- [ ] **Step 2: Run to verify failure**

Run: `bin/rails test test/integration/web/projects_flow_test.rb -n /cover/`
Expected: FAIL — `cover_node_id` is the Task 1 stub returning nil.

- [ ] **Step 3: Implement `cover_node_id`**

In `app/models/maker/project.rb`, replace the Task 1 stub:

```ruby
    def cover_node_id = nil
```

with:

```ruby
    # The node_id whose thumbnail represents this project on the list: first image, else first
    # model, else the first attachment by position, else nil. Reads the loaded/queried
    # file_attachments; callers that render many cards should include(:file_attachments).
    def cover_node_id
      atts = file_attachments.sort_by { |a| [ a.position, a.id ] }
      pick = atts.find { |a| a.role == "image" } ||
             atts.find { |a| a.role == "model" } ||
             atts.first
      pick&.node_id
    end
```

- [ ] **Step 4: Avoid an N+1 on the index**

In `app/controllers/projects_controller.rb`, change the first line of `index` to eager-load attachments:

```ruby
    projects = current_user.maker_projects.includes(:file_attachments).order(updated_at: :desc).to_a
```

- [ ] **Step 5: Run to verify pass**

Run: `bin/rails test test/integration/web/projects_flow_test.rb`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add app/models/maker/project.rb app/controllers/projects_controller.rb \
  test/integration/web/projects_flow_test.rb
git commit -m "feat(projects): cover thumbnails on project cards"
```

---

## Task 8: Build log — list + add + delete

**Files:**
- Create: `app/controllers/projects/build_log_entries_controller.rb`
- Modify: `app/views/projects/_build_log.html.erb`
- Create: `app/views/projects/_log_entry.html.erb`
- Create: `test/integration/web/project_build_log_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/integration/web/project_build_log_test.rb`:

```ruby
require "test_helper"

module Web
  class ProjectBuildLogTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    def sign_in(email = "maker@example.com")
      user = User.find_by(email:) ||
             User.create!(email:, password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email:, password: PASSWORD } }
      user
    end

    test "add a build-log entry" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      assert_difference "project.build_log_entries.count", 1 do
        post project_build_log_entries_path(project), params: { build_log_entry: { body: "Cut the panels" } }
      end
      assert_redirected_to project_path(project)
      follow_redirect!
      assert_select ".log-entry .entry-body", text: /Cut the panels/
    end

    test "a blank entry body is rejected" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      assert_no_difference "Maker::BuildLogEntry.count" do
        post project_build_log_entries_path(project), params: { build_log_entry: { body: "" } }
      end
      assert_redirected_to project_path(project)
    end

    test "delete a build-log entry" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      entry = project.build_log_entries.create!(user:, body: "oops")
      assert_difference "project.build_log_entries.count", -1 do
        delete build_log_entry_path(entry)
      end
    end

    test "entries render newest first" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      project.build_log_entries.create!(user:, body: "first", logged_at: 2.days.ago)
      project.build_log_entries.create!(user:, body: "second", logged_at: 1.day.ago)
      get project_path(project)
      bodies = css_select(".log-entry .entry-body").map(&:text).map(&:strip)
      assert_equal [ "second", "first" ], bodies
    end
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `bin/rails test test/integration/web/project_build_log_test.rb`
Expected: FAIL — controller + view missing.

- [ ] **Step 3: Create the controller**

Create `app/controllers/projects/build_log_entries_controller.rb`:

```ruby
module Projects
  # Build-log entries for a project. Create is nested under a project; destroy is shallow.
  class BuildLogEntriesController < ApplicationController
    before_action :authenticate_user!

    def create
      project = current_user.maker_projects.find_by!(slug: params[:project_id])
      entry = project.build_log_entries.new(entry_params.merge(user: current_user))
      if entry.save
        redirect_to project_path(project), notice: "Log entry added."
      else
        redirect_to project_path(project), alert: entry.errors.full_messages.to_sentence
      end
    end

    def destroy
      entry = current_user.maker_build_log_entries.find(params[:id])
      project = entry.project
      entry.destroy!
      redirect_to project_path(project), notice: "Entry deleted."
    end

    private

    def entry_params
      params.require(:build_log_entry).permit(:body, :entry_type)
    end
  end
end
```

- [ ] **Step 4: Implement the build-log panel**

Replace `app/views/projects/_build_log.html.erb` with:

```erb
<section class="panel build-log-panel">
  <h2>Build log</h2>

  <%= form_with url: project_build_log_entries_path(@project), method: :post, class: "log-form" do |f| %>
    <%= f.fields_for :build_log_entry do |e| %>
      <%= e.text_area :body, rows: 2, placeholder: "What did you do?", required: true %>
      <%= f.submit "Add entry", class: "btn small" %>
    <% end %>
  <% end %>

  <% if @entries.empty? %>
    <p class="muted">No entries yet.</p>
  <% else %>
    <ol class="log-timeline">
      <% @entries.each do |entry| %>
        <%= render "log_entry", entry: %>
      <% end %>
    </ol>
  <% end %>
</section>
```

Create `app/views/projects/_log_entry.html.erb`:

```erb
<li class="log-entry">
  <div class="entry-head">
    <time class="entry-time muted"><%= entry.logged_at.strftime("%Y-%m-%d %H:%M") %></time>
    <%= button_to "Delete", build_log_entry_path(entry), method: :delete, class: "linkbtn danger",
                  form: { data: { turbo_confirm: "Delete this entry?" } } %>
  </div>
  <p class="entry-body"><%= entry.body %></p>
</li>
```

- [ ] **Step 5: Run to verify pass**

Run: `bin/rails test test/integration/web/project_build_log_test.rb`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add app/controllers/projects/build_log_entries_controller.rb \
  app/views/projects/_build_log.html.erb app/views/projects/_log_entry.html.erb \
  test/integration/web/project_build_log_test.rb
git commit -m "feat(projects): build log — add/list/delete entries"
```

---

## Task 9: Build-log photos (attach existing image to an entry)

**Files:**
- Modify: `config/routes.rb` (nested attachment-to-entry route)
- Modify: `app/controllers/projects/attachments_controller.rb` (support entry as attachable) — OR a dedicated action
- Modify: `app/views/projects/_log_entry.html.erb` (render inline photos + attach control)
- Modify: `app/controllers/projects_controller.rb#show` (load entry photos + their thumbnails)
- Test: `test/integration/web/project_build_log_test.rb` (add cases)

- [ ] **Step 1: Write the failing test**

Add to `test/integration/web/project_build_log_test.rb`:

```ruby
    test "attach an existing image to a log entry renders it inline" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      entry = project.build_log_entries.create!(user:, body: "glued it")
      user.nodes.create!(node_id: "img-1", name: "clamp.png", kind: "file")

      assert_difference "entry.file_attachments.count", 1 do
        post entry_photos_path(entry), params: { node_id: "img-1" }
      end
      assert_equal "image", entry.file_attachments.last.role

      get project_path(project)
      assert_select ".log-entry .entry-photo[data-node-id=?]", "img-1"
    end

    test "attaching a photo refuses a node the user does not own" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      entry = project.build_log_entries.create!(user:, body: "x")
      other = User.create!(email: "z2@example.com", password: PASSWORD, confirmed_at: Time.current)
      other.nodes.create!(node_id: "theirs", name: "p.png", kind: "file")
      assert_no_difference "Maker::FileAttachment.count" do
        post entry_photos_path(entry), params: { node_id: "theirs" }
      end
    end
```

- [ ] **Step 2: Run to verify failure**

Run: `bin/rails test test/integration/web/project_build_log_test.rb -n /photo/`
Expected: FAIL — `entry_photos_path` route + action missing.

- [ ] **Step 3: Add the route**

In `config/routes.rb`, inside the `resources :projects do … end` block, add a top-level (shallow) route for entry photos. Add AFTER the `resources :tasks …` line inside the projects block, a sibling standalone route below the projects block:

```ruby
  # A build-log entry's inline photos (attach an existing image node to the entry). Explicit
  # routes so the helpers read entry_photos_path / entry_photo_path (a nested `resources :photos`
  # would generate build_log_entry_photos_path, which the controller/views/tests do NOT use).
  post   "build_log_entries/:build_log_entry_id/photos",
         to: "projects/entry_photos#create", as: :entry_photos
  delete "entry_photos/:id", to: "projects/entry_photos#destroy", as: :entry_photo
```

- [ ] **Step 4: Create the entry-photos controller**

Create `app/controllers/projects/entry_photos_controller.rb`:

```ruby
module Projects
  # Inline photos on a build-log entry: attach an EXISTING image node to the entry, or remove the
  # reference. Same rules as project attachments — a reference, DB-scoped ownership, no byte writes.
  class EntryPhotosController < ApplicationController
    before_action :authenticate_user!

    def create
      entry = current_user.maker_build_log_entries.find(params[:build_log_entry_id])
      node = current_user.nodes.present.find_by(node_id: params.require(:node_id))
      if node
        entry.file_attachments.create!(user: current_user, node_id: node.node_id, role: "image")
        redirect_to project_path(entry.project), notice: "Photo added."
      else
        redirect_to project_path(entry.project), alert: "That image isn't in your library."
      end
    end

    def destroy
      att = current_user.maker_file_attachments.find(params[:id])
      entry = att.attachable
      att.destroy!
      redirect_to project_path(entry.project), notice: "Photo removed."
    end
  end
end
```

- [ ] **Step 5: Load entry-photo thumbnails in `show`**

In `app/controllers/projects_controller.rb#show`, after the `@entries = …` line, add:

```ruby
    entry_photo_ids = @entries.flat_map { |e| e.file_attachments.map(&:node_id) }
    @entry_nodes = current_user.nodes.present.where(node_id: entry_photo_ids).index_by(&:node_id)
    @entry_thumbs = Maker::Previews::ThumbnailMap.for(current_user, entry_photo_ids)
```

And eager-load entry attachments — change the `@entries = …` line to (keep `reorder`, per Task 1's note):

```ruby
    @entries = @project.build_log_entries.includes(:file_attachments).reorder(logged_at: :desc).to_a
```

- [ ] **Step 6: Render photos + the attach control in the entry partial**

Replace `app/views/projects/_log_entry.html.erb` with:

```erb
<li class="log-entry">
  <div class="entry-head">
    <time class="entry-time muted"><%= entry.logged_at.strftime("%Y-%m-%d %H:%M") %></time>
    <%= button_to "Delete", build_log_entry_path(entry), method: :delete, class: "linkbtn danger",
                  form: { data: { turbo_confirm: "Delete this entry?" } } %>
  </div>
  <p class="entry-body"><%= entry.body %></p>

  <% photos = entry.file_attachments.select { |a| @entry_nodes.key?(a.node_id) } %>
  <% if photos.any? %>
    <div class="entry-photos" data-controller="thumbs" data-thumbs-url-value="<%= thumbnails_files_path %>">
      <% photos.each do |att| %>
        <% node = @entry_nodes[att.node_id] %>
        <span class="entry-photo file-cell" data-thumbs-target="cell"
              data-node-id="<%= att.node_id %>" data-ext="IMG">
          <%= render "files/thumb", thumb: @entry_thumbs.thumb(att.node_id), ext_label: "IMG" %>
        </span>
      <% end %>
    </div>
  <% end %>

  <p class="photo-attach">
    <%= link_to "Add photo", new_project_attachment_path(@project, entry_id: entry.id), class: "linkbtn muted" %>
  </p>
</li>
```

**Note on the "Add photo" flow:** "Add photo" reuses the project attach picker (Task 6), passing `entry_id` so the picker's Attach button targets the *entry* instead of the *project*. Wire that into the picker — in `app/views/projects/attachments/new.html.erb`, replace the single `button_to "Attach" …` line with a branch on `entry_id`:

```erb
        <% if params[:entry_id].present? %>
          <%= button_to "Attach", entry_photos_path(params[:entry_id]),
                        params: { node_id: node.node_id }, class: "btn small" %>
        <% else %>
          <%= button_to "Attach", project_attachments_path(@project),
                        params: { node_id: node.node_id }, class: "btn small" %>
        <% end %>
```

- [ ] **Step 7: Run to verify pass**

Run: `bin/rails test test/integration/web/project_build_log_test.rb`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add config/routes.rb app/controllers/projects/entry_photos_controller.rb \
  app/controllers/projects_controller.rb app/views/projects/_log_entry.html.erb \
  app/views/projects/attachments/new.html.erb test/integration/web/project_build_log_test.rb
git commit -m "feat(projects): inline build-log photos (attach existing image)"
```

---

## Task 10: Tasks — list, add, status, delete

**Files:**
- Create: `app/controllers/projects/tasks_controller.rb`
- Modify: `app/views/projects/_tasks.html.erb`
- Create: `app/views/projects/_task.html.erb`
- Create: `test/integration/web/project_tasks_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/integration/web/project_tasks_test.rb`:

```ruby
require "test_helper"

module Web
  class ProjectTasksTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    def sign_in(email = "maker@example.com")
      user = User.find_by(email:) ||
             User.create!(email:, password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email:, password: PASSWORD } }
      user
    end

    test "add a task to a project" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      assert_difference "project.tasks.count", 1 do
        post project_tasks_path(project), params: { task: { title: "Print base" } }
      end
      task = project.tasks.last
      assert_equal "todo", task.status
      assert_redirected_to project_path(project)
    end

    test "tasks render grouped by status" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      project.tasks.create!(user:, title: "A", status: "todo")
      project.tasks.create!(user:, title: "B", status: "done")
      get project_path(project)
      assert_select ".tasks-group.status-todo .task-title", text: "A"
      assert_select ".tasks-group.status-done .task-title", text: "B"
    end

    test "change a task's status" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      task = project.tasks.create!(user:, title: "A", status: "todo")
      patch task_path(task), params: { task: { status: "done" } }
      assert_equal "done", task.reload.status
      assert task.completed_at.present?, "moving to done stamps completed_at"
    end

    test "delete a task" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      task = project.tasks.create!(user:, title: "A")
      assert_difference "project.tasks.count", -1 do
        delete task_path(task)
      end
    end
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `bin/rails test test/integration/web/project_tasks_test.rb`
Expected: FAIL — controller + views missing.

- [ ] **Step 3: Create the tasks controller**

Create `app/controllers/projects/tasks_controller.rb`:

```ruby
module Projects
  # Project tasks: an ordered checklist grouped by status. Create is nested; update/destroy/reorder
  # are shallow. `taskable` is the project (polymorphic), matching Maker::Task's contract.
  class TasksController < ApplicationController
    before_action :authenticate_user!

    def create
      project = current_user.maker_projects.find_by!(slug: params[:project_id])
      next_pos = (project.tasks.maximum(:position) || -1) + 1
      task = project.tasks.new(task_params.merge(user: current_user, position: next_pos))
      if task.save
        redirect_to project_path(project), notice: "Task added."
      else
        redirect_to project_path(project), alert: task.errors.full_messages.to_sentence
      end
    end

    def update
      task = current_user.maker_tasks.find(params[:id])
      # Route "done" through the model op so completed_at is stamped consistently.
      if task_params[:status] == "done" && task.status != "done"
        task.complete!
        task.update(task_params.except(:status))
      else
        task.update(task_params)
      end
      redirect_to project_path(task.taskable)
    end

    def destroy
      task = current_user.maker_tasks.find(params[:id])
      project = task.taskable
      task.destroy!
      redirect_to project_path(project), notice: "Task deleted."
    end

    private

    def task_params
      params.require(:task).permit(:title, :status, :notes)
    end
  end
end
```

- [ ] **Step 4: Implement the tasks panel**

Replace `app/views/projects/_tasks.html.erb` with:

```erb
<section class="panel tasks-panel">
  <h2>Tasks</h2>

  <%= form_with url: project_tasks_path(@project), method: :post, class: "task-form" do |f| %>
    <%= f.fields_for :task do |t| %>
      <%= t.text_field :title, placeholder: "Add a task…", required: true %>
      <%= f.submit "Add", class: "btn small" %>
    <% end %>
  <% end %>

  <% Maker::Task::STATUSES.each do |status| %>
    <% group = @tasks.select { |t| t.status == status } %>
    <div class="tasks-group status-<%= status %>">
      <h3><%= status.capitalize %> <span class="muted">(<%= group.size %>)</span></h3>
      <% group.each do |task| %>
        <%= render "task", task: %>
      <% end %>
    </div>
  <% end %>
</section>
```

Create `app/views/projects/_task.html.erb`:

```erb
<div class="task-row">
  <span class="task-title"><%= task.title %></span>
  <div class="task-actions">
    <% (Maker::Task::STATUSES - [ task.status ]).each do |to| %>
      <%= button_to to.capitalize, task_path(task), method: :patch,
                    params: { task: { status: to } }, class: "linkbtn small" %>
    <% end %>
    <%= button_to "✕", task_path(task), method: :delete, class: "linkbtn danger small",
                  form: { data: { turbo_confirm: "Delete task?" } } %>
  </div>
</div>
```

- [ ] **Step 5: Run to verify pass**

Run: `bin/rails test test/integration/web/project_tasks_test.rb`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add app/controllers/projects/tasks_controller.rb app/views/projects/_tasks.html.erb \
  app/views/projects/_task.html.erb test/integration/web/project_tasks_test.rb
git commit -m "feat(projects): tasks panel — add/status/delete, grouped checklist"
```

---

## Task 11: Attach-from-Files

**Files:**
- Modify: `app/controllers/files_controller.rb#show` (load `@projects`)
- Modify: `app/views/files/show.html.erb` (attach-to-project control)
- Create: `test/integration/web/attach_from_files_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/integration/web/attach_from_files_test.rb`:

```ruby
require "test_helper"

module Web
  class AttachFromFilesTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      pin_file_layer_backend("chunk")
      Storage::ChunkStore.reset!
    end

    def sign_in(email = "maker@example.com")
      user = User.find_by(email:) ||
             User.create!(email:, password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email:, password: PASSWORD } }
      user
    end

    test "the file detail page offers an attach-to-project control listing the user's projects" do
      user = sign_in
      user.nodes.create!(node_id: "f-1", name: "bracket.stl", kind: "file")
      user.maker_projects.create!(name: "Lamp")

      get file_path("f-1")
      assert_response :success
      assert_select ".attach-to-project", text: /Lamp/
    end

    test "attaching from the file page creates the reference and redirects to the project" do
      user = sign_in
      user.nodes.create!(node_id: "f-1", name: "bracket.stl", kind: "file")
      project = user.maker_projects.create!(name: "Lamp")

      assert_difference "project.file_attachments.count", 1 do
        post project_attachments_path(project), params: { node_id: "f-1" }
      end
      assert_equal "model", project.file_attachments.last.role
    end

    test "no attach control when the user has no projects" do
      user = sign_in
      user.nodes.create!(node_id: "f-1", name: "bracket.stl", kind: "file")
      get file_path("f-1")
      assert_select "form.attach-to-project", count: 0
    end
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `bin/rails test test/integration/web/attach_from_files_test.rb`
Expected: FAIL — no attach control in `files/show`.

- [ ] **Step 3: Load projects in FilesController#show**

In `app/controllers/files_controller.rb#show` (after the `@thumbnail = …` assignment, before the method ends), add:

```ruby
    # For the "Attach to project" control (a design file can be sent to a project from here).
    @projects = current_user.maker_projects.where.not(status: "archived").order(:name).to_a
```

- [ ] **Step 4: Add the control to files/show**

In `app/views/files/show.html.erb`, add near the file actions (placement is cosmetic). A **JS-free per-project button list** — each button POSTs the current node to that project's attachments (reusing `Projects::AttachmentsController#create` from Task 6, which infers the role):

```erb
<% if @projects.present? %>
  <div class="attach-to-project">
    <span class="muted">Attach to project:</span>
    <% @projects.each do |project| %>
      <%= button_to project.name, project_attachments_path(project),
                    params: { node_id: @node.node_id }, class: "btn small" %>
    <% end %>
  </div>
<% end %>
```

- [ ] **Step 5: Run to verify pass**

Run: `bin/rails test test/integration/web/attach_from_files_test.rb`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add app/controllers/files_controller.rb app/views/files/show.html.erb \
  test/integration/web/attach_from_files_test.rb
git commit -m "feat(projects): attach-to-project from the file browser"
```

---

## Task 12: CSS + full-suite verification

**Files:**
- Modify: `app/assets/stylesheets/application.css`
- Run: full web suite on both backends

- [ ] **Step 1: Add styles for the new classes**

Append to `app/assets/stylesheets/application.css`:

```css
/* --- Projects ------------------------------------------------------------ */
.btn { display: inline-block; padding: 6px 12px; border: 1px solid var(--line); border-radius: 6px;
       background: var(--soft); color: var(--fg); font-size: 14px; cursor: pointer; }
.btn.primary { background: var(--accent); color: #fff; border-color: var(--accent); }
.btn.small { padding: 3px 8px; font-size: 12px; }
.btn:hover { text-decoration: none; }
.linkbtn.small { font-size: 12px; padding: 2px 4px; }

.badge { display: inline-block; padding: 2px 8px; border-radius: 999px; font-size: 11px;
         font-weight: 600; text-transform: capitalize; background: var(--soft); color: var(--muted); }
.badge.status-active { background: #ecfdf5; color: #065f46; }
.badge.status-planning { background: #eff6ff; color: #1e40af; }
.badge.status-paused { background: #fffbeb; color: #92400e; }
.badge.status-done { background: #f3f4f6; color: #374151; }
.badge.status-archived { background: #f3f4f6; color: #9ca3af; }

.projects-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(160px, 1fr)); gap: 18px; }
.project-group { margin-bottom: 28px; }
.group-head { font-size: 15px; margin: 0 0 12px; }
.project-card { display: flex; flex-direction: column; gap: 8px; align-items: center; color: var(--fg); }
.project-card:hover { text-decoration: none; }
.project-card:hover .thumb { border-color: var(--accent); }
.project-card .thumb { width: 100%; height: 130px; }
.project-thumb-empty { font-size: 40px; }
.project-name { font-size: 14px; font-weight: 600; text-align: center; word-break: break-word; }

.project-head { align-items: flex-start; }
.project-head h1 { margin: 0 0 6px; }
.head-actions { display: flex; gap: 8px; }
.project-description { white-space: pre-wrap; color: var(--fg); margin: 0 0 24px; max-width: 70ch; }

.project-panels { display: grid; grid-template-columns: 1fr; gap: 24px; }
@media (min-width: 900px) { .project-panels { grid-template-columns: 1fr 1fr; }
  .attachments-panel { grid-column: 1 / -1; } }
.panel { border: 1px solid var(--line); border-radius: 10px; padding: 16px; }
.panel h2 { margin: 0 0 12px; font-size: 16px; }
.panel-head { display: flex; align-items: center; justify-content: space-between; }

.attachments-grid, .entry-photos { display: grid;
  grid-template-columns: repeat(auto-fill, minmax(120px, 1fr)); gap: 14px; }
.attachment-tile { display: flex; flex-direction: column; gap: 6px; }
.attachment-tile .thumb { width: 100%; height: 110px; }
.attachment-tile.unavailable .thumb { font-size: 28px; color: var(--muted); }
.tile-meta { display: flex; align-items: center; justify-content: space-between; }
.entry-photo .thumb { width: 100%; height: 90px; }

.field { display: block; margin-bottom: 14px; }
.field > span { display: block; font-size: 13px; color: var(--muted); margin-bottom: 4px; }
.field input, .field textarea, .field select { width: 100%; max-width: 480px; padding: 8px;
  border: 1px solid var(--line); border-radius: 6px; font: inherit; }
.form-actions { display: flex; gap: 12px; align-items: center; }
.form-errors { border-radius: 6px; margin-bottom: 14px; }

.log-form textarea, .task-form input { width: 100%; max-width: 480px; padding: 8px;
  border: 1px solid var(--line); border-radius: 6px; font: inherit; margin-bottom: 8px; }
.log-timeline { list-style: none; padding: 0; margin: 12px 0 0; }
.log-entry { border-left: 2px solid var(--line); padding: 0 0 16px 14px; position: relative; }
.entry-head { display: flex; justify-content: space-between; align-items: center; }
.entry-body { white-space: pre-wrap; margin: 4px 0; }

.tasks-group { margin-top: 12px; }
.tasks-group h3 { font-size: 13px; color: var(--muted); margin: 0 0 6px; }
.task-row { display: flex; justify-content: space-between; align-items: center; gap: 8px;
  padding: 6px 0; border-bottom: 1px solid var(--line); }
.task-actions { display: flex; gap: 4px; align-items: center; }

.picker-results { display: flex; flex-direction: column; gap: 6px; }
.picker-result { display: flex; justify-content: space-between; align-items: center;
  padding: 8px; border: 1px solid var(--line); border-radius: 6px; }
.picker-search { display: flex; gap: 8px; margin-bottom: 16px; }
.picker-search input { flex: 1; max-width: 480px; padding: 8px; border: 1px solid var(--line); border-radius: 6px; }

.attach-to-project { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; margin-top: 16px; }
```

**Note:** confirm the CSS variables used (`--line`, `--soft`, `--accent`, `--fg`, `--muted`, `--danger`) exist at the top of `application.css`. They are used by the existing file/grid styles, so they should — if any is missing, add a sensible value in `:root`.

- [ ] **Step 2: Manually smoke-test in the browser (optional but recommended)**

Use the `run` skill or start the server (`STORAGE_BACKEND=memory bin/rails server -p 3001`), sign in, and click through: create a project → attach a file → add a log entry → add a task → archive.

- [ ] **Step 3: Run the whole web suite on the default (chunk) backend**

Run: `bin/rails test test/integration/web`
Expected: PASS (all web tests, including the pre-existing files/trash suites).

- [ ] **Step 4: Run the whole suite on the share backend**

Run: `LIBRARY_BACKEND=share bin/rails test test/integration/web`
Expected: PASS. The projects tests that touch the port pin `chunk` in setup; the ones that don't (pure maker data) are backend-neutral. If a projects test fails here because it assumed chunk, add `pin_file_layer_backend("chunk")` to its setup (only where it seeds `nodes`/thumbnails).

- [ ] **Step 5: Run the full test suite**

Run: `bin/rails test`
Expected: PASS (no regressions across the whole server suite).

- [ ] **Step 6: Commit**

```bash
git add app/assets/stylesheets/application.css
git commit -m "feat(projects): styles for the projects hub"
```

---

## Self-review checklist (run before handing off)

- **Spec coverage:** list (Task 1), create (Task 2), detail + lifecycle (Task 3), attachments render (Task 5) + attach/detach (Task 6), cover thumbnails (Task 7), build log (Task 8) + photos (Task 9), tasks (Task 10), attach-from-Files (Task 11), graceful degrade (Tasks 4/5), tenant isolation (tests in Tasks 1/3/6), dual-backend CI (Task 12). BOM, progress/markdown/milestone, and the public page are out of scope per the spec.
- **Deferred vs spec:** the spec's "upload-and-attach" and inline photo *upload* are narrowed to *attach existing* (see the v1 scope note). Surface this in the handoff.
- **Type consistency:** `Maker::Previews::ThumbnailMap.for(user, node_ids)` → `#thumb(node_id)` used identically in Tasks 1, 5, 7, 9. `Maker::FileAttachment.role_for(name)` defined in Task 6, used in Tasks 6 and 11. `Project#cover_node_id` stubbed in Task 1, implemented in Task 7. `to_param`/slug lookups (`find_by!(slug:)`) consistent across all controllers.

---

## Execution handoff notes (tell the user)

1. **v1 attach = attach-existing.** Uploading a brand-new file (or photo) from inside the project page is deferred to avoid re-implementing the capability-branched uploader; you upload via Files, then attach. Easy fast-follow if wanted.
2. **Deferred from the spec, on the backlog:** BOM editor, progress bar / markdown / milestone styling, public project page, inline upload-and-attach, `Projects/<slug>/` upload folder, and **task reordering** (tasks keep their insertion `position`; no reorder UI in v1 — drag-kanban later).
3. **Milestone entry_type** is stored (`note`) but not surfaced — the field is ready for the backlogged milestone-styling feature.
