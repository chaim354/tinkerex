# Current Project Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A session-scoped "current project", shown in the top bar, that becomes the default destination for tool output and Files-page uploads (files land in the project's `Projects/<slug>` folder **and** attach to the project).

**Architecture:** A `CurrentProject` controller concern (in `ApplicationController`) reads `session[:current_project_id]` and exposes helpers. A tiny `CurrentProjectController` sets/clears it. The top bar and each project page switch it. Tools default their folder picker to the project folder and attach output; the Files page reuses the *existing* project upload/attach control. No models, migrations, or JS changes — it reads metadata and creates `FileAttachment` references only, so the file-layer split's §10 boundary (sync/changelog/conflicts/locks/mounts) is never touched.

**Tech Stack:** Rails 8, server-rendered Hotwire, Minitest (`ActionDispatch::IntegrationTest`), session auth (Devise). Backend-neutral across chunk / share / s3 (the CI runs the suite once per backend).

**Spec:** `docs/superpowers/specs/2026-07-23-current-project-design.md`

---

## File Structure

| File | Responsibility | New/Modify |
|---|---|---|
| `app/controllers/concerns/current_project.rb` | `current_project`, `current_project_choices`, `current_project_folder_node_id`, `attach_addon_files_to_current_project` | **new** |
| `app/controllers/current_project_controller.rb` | `update` (set/clear) + `destroy` (clear) | **new** |
| `config/routes.rb` | `resource :current_project, only: %i[update destroy]` | modify |
| `app/controllers/application_controller.rb` | `include CurrentProject` | modify |
| `app/views/layouts/application.html.erb` | top-bar project dropdown | modify |
| `app/views/projects/show.html.erb` | "Set as current" / "Clear" control | modify |
| `app/controllers/tools/boxes_controller.rb` | picker default + attach | modify |
| `app/views/tools/boxes/new.html.erb` | pre-select the picker | modify |
| `app/controllers/tools/generators_controller.rb` | picker default + attach | modify |
| `app/views/tools/generators/index.html.erb` | pre-select the picker | modify |
| `app/views/files/index.html.erb` | project-aimed upload control + override link | modify |
| `test/controllers/current_project_controller_test.rb` | Task 1 tests | **new** |
| `test/integration/web/current_project_topbar_test.rb` | Task 2 tests | **new** |
| `test/integration/web/current_project_set_from_project_test.rb` | Task 3 tests | **new** |
| `test/integration/web/current_project_files_upload_test.rb` | Task 6 tests | **new** |
| `test/controllers/tools/boxes_controller_test.rb` | Task 4 tests | modify |
| `test/controllers/tools/generators_controller_test.rb` | Task 5 tests | modify |

---

## Phase 1 — State + surface it

### Task 1: The `CurrentProject` concern + route + controller

**Files:**
- Create: `app/controllers/concerns/current_project.rb`
- Create: `app/controllers/current_project_controller.rb`
- Modify: `config/routes.rb`
- Modify: `app/controllers/application_controller.rb:1`
- Test: `test/controllers/current_project_controller_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/controllers/current_project_controller_test.rb`:

```ruby
require "test_helper"

class CurrentProjectControllerTest < ActionDispatch::IntegrationTest
  PASSWORD = "correct horse battery staple".freeze

  setup do
    @user = User.create!(email: "cp-#{SecureRandom.hex(4)}@example.com",
                         password: PASSWORD, confirmed_at: Time.current)
    post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
  end

  test "update sets the session current project and redirects" do
    project = @user.maker_projects.create!(name: "Lamp")
    patch current_project_path, params: { project_id: project.id }
    assert_equal project.id, session[:current_project_id]
    assert_response :redirect
  end

  test "update with a blank project_id clears the selection" do
    project = @user.maker_projects.create!(name: "Lamp")
    patch current_project_path, params: { project_id: project.id }
    patch current_project_path, params: { project_id: "" }
    assert_nil session[:current_project_id]
  end

  test "update ignores a project that is not the user's own" do
    other = User.create!(email: "cp-other-#{SecureRandom.hex(4)}@example.com",
                         password: PASSWORD, confirmed_at: Time.current)
    foreign = other.maker_projects.create!(name: "Theirs")
    patch current_project_path, params: { project_id: foreign.id }
    assert_nil session[:current_project_id]
  end

  test "destroy clears the current project" do
    project = @user.maker_projects.create!(name: "Lamp")
    patch current_project_path, params: { project_id: project.id }
    delete current_project_path
    assert_nil session[:current_project_id]
  end

  test "requires sign-in" do
    delete destroy_user_session_path
    patch current_project_path, params: { project_id: 1 }
    assert_redirected_to new_user_session_path
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/controllers/current_project_controller_test.rb`
Expected: FAIL — `NameError: undefined ... current_project_path` (route + controller don't exist yet).

- [ ] **Step 3: Create the concern**

Create `app/controllers/concerns/current_project.rb`:

```ruby
# Session-scoped "current project": the maker's active project, shown in the top bar and used as the
# default destination for tool output and Files-page uploads (spec 2026-07-23). Session-only by
# design — it resets on sign-out and is not shared across devices. Included in ApplicationController
# so the layout's top bar can read `current_project` on every page.
#
# It reads file metadata and creates FileAttachment REFERENCES (+ the project's library folder) only
# — it never moves bytes, so none of the file-layer split's §10 surface
# (sync/changelog/conflicts/locks/mounts) is touched.
module CurrentProject
  extend ActiveSupport::Concern

  included do
    helper_method :current_project, :current_project_choices
  end

  private

  # The selected project, or nil. User-scoped (a forged/foreign id can't resolve); archived or
  # deleted projects resolve to nil — so archiving the current project silently clears it and every
  # consumer falls back to today's behavior. Memoized per request.
  def current_project
    return @current_project if defined?(@current_project)
    id = session[:current_project_id]
    @current_project =
      if id && current_user
        current_user.maker_projects.where.not(status: "archived").find_by(id: id)
      end
  end

  # The project's Projects/<slug> folder node_id, or nil. ensure_library_folder! is idempotent and
  # (re)creates the folder; a rescue → nil falls back to the library root rather than 500-ing a page.
  def current_project_folder_node_id
    current_project&.ensure_library_folder!(current_user)&.node_id
  rescue StandardError
    nil
  end

  # [name, id] pairs for the top-bar select — this user's non-archived projects, A→Z. One indexed
  # query; only when signed in.
  def current_project_choices
    return [] unless user_signed_in?
    current_user.maker_projects.where.not(status: "archived").order(:name).pluck(:name, :id)
  end

  # Attach every addon output file to the current project (if one is set), so a tool save appears on
  # the project page. No-op when no project is current. `addon_files` is what LibraryOutput.write
  # returns; roles map from the node name via FileAttachment.role_for.
  def attach_addon_files_to_current_project(addon_files)
    project = current_project
    return unless project && addon_files.present?
    names = current_user.nodes.where(node_id: addon_files.map(&:node_id)).pluck(:node_id, :name).to_h
    addon_files.each do |af|
      name = names[af.node_id]
      next unless name
      project.file_attachments.create!(user: current_user, node_id: af.node_id,
                                       role: Maker::FileAttachment.role_for(name))
    end
  end
end
```

- [ ] **Step 4: Create the controller**

Create `app/controllers/current_project_controller.rb`:

```ruby
# Sets or clears the session-scoped current project (spec §3.2). Session-authed like the rest of the
# web UI. Never stores an id that isn't the user's own project.
class CurrentProjectController < ApplicationController
  before_action :authenticate_user!

  # PATCH /current_project { project_id }. A present, owned id becomes current; a blank id clears (so
  # the top-bar "— none —" option flows through here too); a foreign/unknown id is ignored.
  def update
    id = params[:project_id].presence
    if id.nil?
      session.delete(:current_project_id)
    elsif (project = current_user.maker_projects.find_by(id: id))
      session[:current_project_id] = project.id
    end
    redirect_back fallback_location: files_path
  end

  # DELETE /current_project — the explicit clear (top-bar "×" / project-page "Clear").
  def destroy
    session.delete(:current_project_id)
    redirect_back fallback_location: files_path
  end
end
```

- [ ] **Step 5: Add the route**

In `config/routes.rb`, immediately after the `resources :projects do … end` block (around line 51-59), add:

```ruby
  # Session-scoped "current project" (the top-bar default destination). Singular resource: no id in
  # the URL — the id rides in params[:project_id] so a blank one can clear it.
  resource :current_project, only: %i[update destroy]
```

- [ ] **Step 6: Include the concern**

In `app/controllers/application_controller.rb`, add the include right after the class opens (after line 3's `allow_browser`):

```ruby
  include CurrentProject
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `bin/rails test test/controllers/current_project_controller_test.rb`
Expected: PASS (5 tests).

- [ ] **Step 8: Commit**

```bash
git add app/controllers/concerns/current_project.rb app/controllers/current_project_controller.rb \
        config/routes.rb app/controllers/application_controller.rb \
        test/controllers/current_project_controller_test.rb
git commit -m "feat(current-project): session state + set/clear controller"
```

---

### Task 2: Top-bar project dropdown

**Files:**
- Modify: `app/views/layouts/application.html.erb:33-41` (the `.topbar-right` block)
- Test: `test/integration/web/current_project_topbar_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/integration/web/current_project_topbar_test.rb`:

```ruby
require "test_helper"

module Web
  class CurrentProjectTopbarTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "tb-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
    end

    test "the top bar shows a project selector listing this user's active projects" do
      @user.maker_projects.create!(name: "Desk Lamp")
      get files_path
      assert_response :success
      assert_select "form[action=?] select[name='project_id']", current_project_path do
        assert_select "option[value='']", text: /none/i
        assert_select "option", text: "Desk Lamp"
      end
    end

    test "the selector marks the current project as selected" do
      project = @user.maker_projects.create!(name: "Desk Lamp")
      patch current_project_path, params: { project_id: project.id }
      get files_path
      assert_select "select[name='project_id'] option[selected='selected'][value=?]", project.id.to_s,
                    text: "Desk Lamp"
    end

    test "an archived current project falls back to none (auto-clear)" do
      project = @user.maker_projects.create!(name: "Desk Lamp")
      patch current_project_path, params: { project_id: project.id }
      project.archive!
      get files_path
      # archived project is not offered and is not selected
      assert_select "select[name='project_id'] option", text: "Desk Lamp", count: 0
      assert_select "select[name='project_id'] option[selected='selected']", count: 0
    end

    test "no selector when the user has no projects" do
      get files_path
      assert_select "select[name='project_id']", count: 0
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/integration/web/current_project_topbar_test.rb`
Expected: FAIL — no `select[name='project_id']` in the layout yet.

- [ ] **Step 3: Add the selector to the layout**

In `app/views/layouts/application.html.erb`, inside `<div class="topbar-right">`, insert this **before** the `<span class="muted"><%= current_user.email %></span>` line (currently line 39):

```erb
          <% if current_project_choices.any? %>
            <%= form_with url: current_project_path, method: :patch, data: { turbo: false },
                          class: "current-project-form" do %>
              <label class="current-project">
                <span class="muted">Project:</span>
                <%= select_tag :project_id,
                      options_for_select([ [ "— none —", "" ] ] + current_project_choices, current_project&.id),
                      onchange: "this.form.requestSubmit()" %>
              </label>
            <% end %>
          <% end %>
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/integration/web/current_project_topbar_test.rb`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add app/views/layouts/application.html.erb test/integration/web/current_project_topbar_test.rb
git commit -m "feat(current-project): top-bar project selector"
```

---

### Task 3: "Set as current" / "Clear" on the project page

**Files:**
- Modify: `app/views/projects/show.html.erb:14-19` (the `.head-actions` block)
- Test: `test/integration/web/current_project_set_from_project_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/integration/web/current_project_set_from_project_test.rb`:

```ruby
require "test_helper"

module Web
  class CurrentProjectSetFromProjectTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "sp-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      @project = @user.maker_projects.create!(name: "Desk Lamp")
    end

    test "the project page offers 'Set as current' when it is not current" do
      get project_path(@project)
      assert_response :success
      assert_select "form[action=?] button", current_project_path, text: /set as current/i
    end

    test "setting it from the project page makes it the session current project" do
      patch current_project_path, params: { project_id: @project.id }
      assert_equal @project.id, session[:current_project_id]
    end

    test "the project page shows a current badge + Clear once it is current" do
      patch current_project_path, params: { project_id: @project.id }
      get project_path(@project)
      assert_select ".current-project-badge"
      assert_select "form[action=?] button", current_project_path, text: /clear/i
      assert_select "button", text: /set as current/i, count: 0
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/integration/web/current_project_set_from_project_test.rb`
Expected: FAIL — no "Set as current" control on the project page.

- [ ] **Step 3: Add the control**

In `app/views/projects/show.html.erb`, replace the `.head-actions` block (currently lines 14-19):

```erb
  <div class="head-actions">
    <% if current_project == @project %>
      <span class="badge current-project-badge">★ Current project</span>
      <%= button_to "Clear", current_project_path, method: :delete, class: "linkbtn" %>
    <% else %>
      <%= button_to "Set as current", current_project_path, method: :patch,
                    params: { project_id: @project.id }, class: "linkbtn" %>
    <% end %>
    <%= link_to "Edit", edit_project_path(@project), class: "linkbtn" %>
    <%= button_to "Archive", project_path(@project), method: :delete, class: "linkbtn danger",
                  form: { data: { turbo_confirm: "Archive #{@project.name}?" } } %>
  </div>
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/integration/web/current_project_set_from_project_test.rb`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add app/views/projects/show.html.erb test/integration/web/current_project_set_from_project_test.rb
git commit -m "feat(current-project): set/clear from the project page"
```

---

## Phase 2 — Tools default to the current project

### Task 4: Box Generator — picker default + attach both files

**Files:**
- Modify: `app/controllers/tools/boxes_controller.rb:16-31` (`#new`) and `:59-81` (`#create`)
- Modify: `app/views/tools/boxes/new.html.erb:21`
- Test: `test/controllers/tools/boxes_controller_test.rb`

- [ ] **Step 1: Write the failing tests**

Append these tests inside `module Tools … class BoxesControllerTest`, before the final `end end` (after the existing tests). NOTE: keep every state `name` here globally unique across the whole test suite — under `LIBRARY_BACKEND=share` the output writes `<name>-<id>.svg` into a persistent dir while SQLite rolls `state.id` back to 1 each test, so two tests naming a state alike collide as a clobber (see the existing note in this file). `Cur Box` / `Loose Box` are unique.

```ruby
    test "new pre-selects the current project's folder in the save picker" do
      project = @user.maker_projects.create!(name: "Desk Lamp")
      folder = project.ensure_library_folder!(@user)
      patch current_project_path, params: { project_id: project.id }
      get new_tools_box_path(generator: "ABox")
      assert_response :success
      assert_select "select[name='parent_node_id'] option[selected='selected'][value=?]", folder.node_id
    end

    test "create attaches both output files to the current project" do
      project = @user.maker_projects.create!(name: "Desk Lamp")
      folder = project.ensure_library_folder!(@user)
      patch current_project_path, params: { project_id: project.id }
      assert_difference "project.file_attachments.count", 2 do
        post tools_boxes_path, params: { name: "Cur Box", generator: "ABox", params: { x: 1, y: 2 },
                                         parent_node_id: folder.node_id }
      end
      # both attached nodes live under the project folder
      project.file_attachments.each do |att|
        assert_equal folder.node_id, @user.nodes.find_by(node_id: att.node_id).parent_node_id
      end
    end

    test "create attaches nothing when no project is current" do
      @user.maker_projects.create!(name: "Desk Lamp") # exists but not current
      assert_no_difference "Maker::FileAttachment.count" do
        post tools_boxes_path, params: { name: "Loose Box", generator: "ABox", params: { x: 1, y: 2 } }
      end
    end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/controllers/tools/boxes_controller_test.rb`
Expected: FAIL — the picker has no `selected` option; no attachments created.

- [ ] **Step 3: Default the picker in `#new`**

In `app/controllers/tools/boxes_controller.rb`, in `#new`, replace the `@folders = folder_options` line with (compute the default **first** so `folder_options` includes the just-ensured folder):

```ruby
      @default_parent_node_id = current_project_folder_node_id
      @folders = folder_options # where to save the output (existing folders + root)
```

- [ ] **Step 4: Pre-select it in the view**

In `app/views/tools/boxes/new.html.erb` line 21, change:

```erb
      <%= select_tag :parent_node_id, options_for_select(@folders, @default_parent_node_id) %>
```

- [ ] **Step 5: Attach after save in `#create`**

In `app/controllers/tools/boxes_controller.rb` `#create`, capture the return of `LibraryOutput.write` and attach. Replace the `Maker::Addons::LibraryOutput.write(...)` call (lines 68-77) with:

```ruby
      addon_files = Maker::Addons::LibraryOutput.write(
        user: current_user, state:, parent_node_id: chosen_parent_node_id,
        files: [
          { name: "#{base}-#{state.id}.svg", bytes: svg,
            content_type: "image/svg+xml", role: "output" },
          { name: "#{base}-#{state.id}.params.json",
            bytes: JSON.pretty_generate({ generator:, params: p }),
            content_type: "application/json", role: "parameters" }
        ]
      )
      attach_addon_files_to_current_project(addon_files)
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bin/rails test test/controllers/tools/boxes_controller_test.rb`
Expected: PASS (all — new + existing).

- [ ] **Step 7: Commit**

```bash
git add app/controllers/tools/boxes_controller.rb app/views/tools/boxes/new.html.erb \
        test/controllers/tools/boxes_controller_test.rb
git commit -m "feat(current-project): Box Generator defaults to + attaches to the current project"
```

---

### Task 5: Generators — picker default + attach both files

**Files:**
- Modify: `app/controllers/tools/generators_controller.rb:13-17` (`#index`) and `:19-38` (`#create`)
- Modify: `app/views/tools/generators/index.html.erb:24`
- Test: `test/controllers/tools/generators_controller_test.rb`

- [ ] **Step 1: Write the failing tests**

Append inside `module Tools … class GeneratorsControllerTest`, before the final `end end`. (Same share-backend rule as Task 4: keep every state `name` globally unique — `Cur Grid` / `Loose Grid` are.)

```ruby
    test "index pre-selects the current project's folder in the save picker" do
      project = @user.maker_projects.create!(name: "Desk Lamp")
      folder = project.ensure_library_folder!(@user)
      patch current_project_path, params: { project_id: project.id }
      get tools_generators_path
      assert_response :success
      assert_select "select[name='parent_node_id'] option[selected='selected'][value=?]", folder.node_id
    end

    test "create attaches both output files to the current project" do
      project = @user.maker_projects.create!(name: "Desk Lamp")
      folder = project.ensure_library_folder!(@user)
      patch current_project_path, params: { project_id: project.id }
      assert_difference "project.file_attachments.count", 2 do
        post tools_generators_path, params: {
          name: "Cur Grid", generator: "material-test-grid", params: { cols: 2 },
          svg: SVG_FIXTURE, parent_node_id: folder.node_id
        }
      end
      project.file_attachments.each do |att|
        assert_equal folder.node_id, @user.nodes.find_by(node_id: att.node_id).parent_node_id
      end
    end

    test "create attaches nothing when no project is current" do
      @user.maker_projects.create!(name: "Desk Lamp") # exists but not current
      assert_no_difference "Maker::FileAttachment.count" do
        post tools_generators_path, params: {
          name: "Loose Grid", generator: "material-test-grid", params: { cols: 2 }, svg: SVG_FIXTURE
        }
      end
    end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/controllers/tools/generators_controller_test.rb`
Expected: FAIL — no `selected` option; no attachments.

- [ ] **Step 3: Default the picker in `#index`**

In `app/controllers/tools/generators_controller.rb` `#index`, replace the `@folders = folder_options` line with (default computed first):

```ruby
      @default_parent_node_id = current_project_folder_node_id
      @folders = folder_options
```

- [ ] **Step 4: Pre-select it in the view**

In `app/views/tools/generators/index.html.erb` line 24, change:

```erb
        <%= select_tag "parent_node_id", options_for_select(@folders, @default_parent_node_id) %>
```

- [ ] **Step 5: Attach after save in `#create`**

In `app/controllers/tools/generators_controller.rb` `#create`, replace the `Maker::Addons::LibraryOutput.write(...)` call (lines 29-36) with:

```ruby
      addon_files = Maker::Addons::LibraryOutput.write(
        user: current_user, state:, parent_node_id: chosen_parent_node_id,
        files: [
          { name: "#{base}-#{state.id}.svg", bytes:, content_type: "image/svg+xml", role: "output" },
          { name: "#{base}-#{state.id}.params.json",
            bytes: JSON.pretty_generate(state.data), content_type: "application/json", role: "parameters" }
        ]
      )
      attach_addon_files_to_current_project(addon_files)
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bin/rails test test/controllers/tools/generators_controller_test.rb`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add app/controllers/tools/generators_controller.rb app/views/tools/generators/index.html.erb \
        test/controllers/tools/generators_controller_test.rb
git commit -m "feat(current-project): Generators defaults to + attaches to the current project"
```

---

## Phase 3 — Files-page upload defaults to the current project

### Task 6: Files upload defaults into the current project (with root override)

**Files:**
- Modify: `app/views/files/index.html.erb:33-62` (the upload block)
- Test: `test/integration/web/current_project_files_upload_test.rb`

The "upload into a project folder + attach" flow already exists as `projects/_upload_control` (driven by `uploader_controller.js` for chunk; a multipart form for share/s3) plus `Projects::UploadsController` / `Projects::AttachmentsController`. This task points it at the current project when one is set. `params[:upload] == "library"` forces today's plain upload (the override) with no client-side toggling.

- [ ] **Step 1: Write the failing tests**

Create `test/integration/web/current_project_files_upload_test.rb`:

```ruby
require "test_helper"

module Web
  # The Files-page upload defaults into the current project (folder + attach) by reusing the project
  # upload/attach control. Chunk drives the two-phase uploader (data-* wiring); share drives a
  # multipart form. s3 shares share's port_writable branch, so those two cover both view branches.
  class CurrentProjectFilesUploadTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    class ChunkTest < CurrentProjectFilesUploadTest
      setup do
        pin_file_layer_backend("chunk")
        Storage::ChunkStore.reset!
        @user = User.create!(email: "fu-#{SecureRandom.hex(4)}@example.com",
                             password: PASSWORD, confirmed_at: Time.current)
        post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
        @project = @user.maker_projects.create!(name: "Desk Lamp")
        @folder = @project.ensure_library_folder!(@user)
      end

      test "with a current project the uploader is wired to upload into it and attach" do
        patch current_project_path, params: { project_id: @project.id }
        get files_path
        assert_response :success
        assert_select "[data-uploader-parent-node-id-value=?]", @folder.node_id
        assert_select "[data-uploader-attach-url-value=?]", project_attachments_path(@project)
        assert_select "a", text: /library root instead/i
      end

      test "the ?upload=library override renders the plain (root) uploader" do
        patch current_project_path, params: { project_id: @project.id }
        get files_path(upload: "library")
        # plain uploader has no attach-url wiring
        assert_select "[data-uploader-attach-url-value]", count: 0
        assert_select "[data-controller='uploader']"
      end

      test "with no current project the plain uploader renders" do
        get files_path
        assert_select "[data-uploader-attach-url-value]", count: 0
        assert_select "[data-controller='uploader']"
      end
    end

    class ShareTest < CurrentProjectFilesUploadTest
      setup do
        @root = Pathname.new(Dir.mktmpdir("files-upload"))
        @user = User.create!(email: "fus-#{SecureRandom.hex(4)}@example.com",
                             password: PASSWORD, confirmed_at: Time.current)
        FileLayer.current = FileLayer::Share.new(root: @root.to_s)
        post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
        @project = @user.maker_projects.create!(name: "Desk Lamp")
      end
      teardown do
        FileLayer.reset!
        FileUtils.remove_entry(@root) if @root&.exist?
      end

      test "with a current project the multipart form posts to the project upload path" do
        patch current_project_path, params: { project_id: @project.id }
        get files_path
        assert_select "form.uploader[action=?]", project_uploads_path(@project)
        assert_select "a", text: /library root instead/i
      end

      test "with no current project the multipart form posts to the plain files path" do
        get files_path
        assert_select "form.uploader[action=?]", files_path
      end
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/integration/web/current_project_files_upload_test.rb`
Expected: FAIL — the Files page never points its uploader at a project.

- [ ] **Step 3: Make the Files upload block project-aware**

In `app/views/files/index.html.erb`, replace the whole upload block (the comment at lines 33-39 plus the `<% if capabilities.port_writable? %> … <% end %>` at lines 40-62) with:

```erb
<%#
  UPLOAD — when a project is CURRENT, the single upload button defaults into it (its Projects/<slug>
  folder + attach), reusing the project upload/attach control (spec §3.6). A small link overrides to
  a plain library-root upload (?upload=library) without having to clear the current project. When no
  project is current — or the override is active — the plain two-flow upload renders exactly as before
  (port_writable branch = share/s3 multipart; else = chunk two-phase). See projects/_upload_control.
%>
<% if current_project && params[:upload] != "library" %>
  <div class="upload-to-project">
    <span class="muted">Uploading to project: <strong><%= current_project.name %></strong></span>
    <%= render "projects/upload_control",
               upload_url: project_uploads_path(current_project),
               attach_url: project_attachments_path(current_project),
               redirect_url: files_path(folder: current_project_folder_node_id),
               parent_node_id: current_project_folder_node_id %>
    <%= link_to "Upload to library root instead",
                files_path(folder: @folder&.node_id, upload: "library"), class: "muted upload-alt" %>
  </div>
<% else %>
  <% if capabilities.port_writable? %>
    <%# Share/S3: no chunk store to presign into, so the bytes come up in one multipart POST. %>
    <%= form_with url: files_path, method: :post, class: "uploader",
                  data: { turbo: false }, html: { multipart: true } do |f| %>
      <label class="upload-btn">
        <%= f.file_field :file, onchange: "this.form.requestSubmit()", hidden: true %>
        <span>Upload a file</span>
      </label>
    <% end %>
  <% else %>
    <%# Chunk: the browser hashes, we presign the missing chunks, the browser PUTs them (§15). %>
    <section class="uploader"
             data-controller="uploader"
             data-uploader-begin-url-value="<%= begin_upload_files_path %>"
             data-uploader-finalize-url-value="<%= finalize_upload_files_path %>">
      <label class="upload-btn">
        <input type="file" data-uploader-target="input" data-action="uploader#upload" hidden>
        <span>Upload a file</span>
      </label>
      <span class="upload-status" data-uploader-target="status"></span>
    </section>
  <% end %>
  <% if current_project %>
    <%= link_to "Upload to project “#{current_project.name}” instead",
                files_path(folder: @folder&.node_id), class: "muted upload-alt" %>
  <% end %>
<% end %>
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/integration/web/current_project_files_upload_test.rb`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add app/views/files/index.html.erb test/integration/web/current_project_files_upload_test.rb
git commit -m "feat(current-project): Files upload defaults into the current project"
```

---

## Phase 4 — Full verification + docs

### Task 7: Run the whole suite on all three backends + update STATUS

**Files:**
- Modify: `docs/STATUS.md` (add a short entry)

- [ ] **Step 1: Run the full suite on the default (chunk) backend**

Run: `bin/rails test`
Expected: PASS, 0 failures / 0 errors (skips allowed).

- [ ] **Step 2: Run the full suite on the share backend**

Run: `LIBRARY_BACKEND=share bin/rails test`
Expected: PASS, identical count.

- [ ] **Step 3: Run the full suite on the s3 backend**

Run: `LIBRARY_BACKEND=s3 bin/rails test`
Expected: PASS, identical count.

- [ ] **Step 4: Add a STATUS entry**

In `docs/STATUS.md`, add a short dated bullet under the most recent status section:

```markdown
- **Current Project (2026-07-23):** a session-scoped "current project" shown in the top-bar
  selector (set/clear there or from a project page). Tool saves (Box Generator, Generators) default
  their save-folder to the project's `Projects/<slug>` folder and attach both output files; the
  Files-page upload defaults into the project (folder + attach) reusing the existing project
  upload/attach control, with a "library root instead" override. Session-only, zero-regression when
  unset; no models/migrations/JS; reads metadata + creates FileAttachment references only (§10
  untouched). Green on all three backends.
```

- [ ] **Step 5: Commit**

```bash
git add docs/STATUS.md
git commit -m "docs(current-project): STATUS entry + full-suite verification across backends"
```

---

## Self-Review notes (for the implementer)

- **Spec coverage:** §2.1 session state → Task 1; §3.2 set/clear → Task 1; §3.3 top bar → Task 2; §3.4 project-page button → Task 3; §3.5 tools (both) → Tasks 4-5; §3.6 Files upload (one button + override) → Task 6; §2.6 attach *both* files → the two-file `attach_addon_files_to_current_project` calls in Tasks 4-5; §6 safety (user-scoping, archived→nil, best-effort folder) → concern in Task 1 + Task 2's archived test; §7 backends → Task 7.
- **Type/name consistency:** `current_project`, `current_project_choices`, `current_project_folder_node_id`, `attach_addon_files_to_current_project` are defined once (Task 1) and used verbatim in Tasks 2-6. `@default_parent_node_id` is the picker default ivar in both tool views. Route helper is `current_project_path` (singular resource) throughout.
- **Order dependency:** in Tasks 4-5, `current_project_folder_node_id` is computed **before** `folder_options` so the just-ensured `Projects/<slug>` folder is present in the picker options (otherwise the pre-selected value matches no option).
```
