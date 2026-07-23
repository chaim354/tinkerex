# Maker.js Generator Harness + Material Test Grid — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the first client-only `/tools` addon — a browser-side generator harness (Maker.js) whose Rails side is generator-agnostic — shipping with the Material Test Grid as its first generator.

**Architecture:** A thin, generator-agnostic `Tools::GeneratorsController` (`index`/`create`/`show`) persists a `Maker::AddonState` and writes a `[svg, params.json]` bundle through the existing `Maker::Addons::LibraryOutput`. All generator specifics (schema + geometry) live in JavaScript: a Stimulus harness builds the form from a module's param schema, previews the module's SVG live (Maker.js in the browser), and saves via a normal Rails form. Adding a future generator = one JS module + one JS registry line, **no Ruby change**.

**Tech Stack:** Rails 8 (server-rendered + Devise session auth), importmap-rails + Propshaft (no bundler), Stimulus, Maker.js (Apache-2.0, vendored + pinned like JSZip), the shipped `Maker::Addons` framework (`AddonState`/`AddonFile`/`LibraryOutput`) and `Maker::Previews` SVG thumbnailer.

**Spec:** `docs/superpowers/specs/2026-07-22-makerjs-generator-harness-design.md`

---

## File Structure

**Create:**
- `app/controllers/tools/library_folders.rb` — `Tools::LibraryFolders` concern: `folder_options` + `chosen_parent_node_id`, extracted from `BoxesController` so both addons share one copy.
- `app/controllers/tools/generators_controller.rb` — the generator-agnostic addon controller (`index`/`create`/`show`).
- `app/views/tools/generators/index.html.erb` — saved grids + the harness mount (picker + form + preview).
- `app/views/tools/generators/show.html.erb` — reopen a saved grid (renders its bundle + serializes `data` for rehydration).
- `app/javascript/controllers/generator_controller.js` — the harness (form-builder + live preview + save-field wiring).
- `app/javascript/generators/index.js` — the JS generator registry (`key → module`).
- `app/javascript/generators/material_test_grid.js` — the first generator module.
- `vendor/javascript/makerjs.js` — vendored Maker.js (added via importmap in Task 6).
- `test/controllers/tools/generators_controller_test.rb` — the controller test suite (the gate).
- `test/controllers/tools/library_folders_test.rb` — a focused test for the extracted concern.

**Modify:**
- `config/routes.rb` — add `resources :generators, only: %i[index create show]` inside `namespace :tools`.
- `app/services/maker/addons/registry.rb` — add the `"generators"` registry entry (always available).
- `app/controllers/tools/boxes_controller.rb` — remove the two folder methods; `include Tools::LibraryFolders`.
- `config/importmap.rb` — pin `makerjs` and the generators JS.

**Note on JS testing:** this importmap app has no JS test runner (confirmed — no `package.json`/jest; the existing `boxpreview_controller.js` has no JS tests). JS tasks (6–8) are therefore **implement + browser-smoke**, not TDD. The Ruby controller tests (Tasks 1, 3, 4, 5 + the concern test in Task 2) are the automated gate and must stay green on all three `LIBRARY_BACKEND` legs.

---

## Task 1: Registry entry + route + gallery tile

**Files:**
- Modify: `app/services/maker/addons/registry.rb`
- Modify: `config/routes.rb:88` (inside `namespace :tools`)
- Test: `test/controllers/tools/generators_controller_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/controllers/tools/generators_controller_test.rb`:

```ruby
require "test_helper"

module Tools
  class GeneratorsControllerTest < ActionDispatch::IntegrationTest
    include ActiveJob::TestHelper
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "gen@example.com", password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      Storage::ChunkStore.reset!
      if ENV["LIBRARY_BACKEND"] == "s3"
        require_relative "../../support/fake_s3"
        @fake = FakeS3.new
        FileLayer.current = FileLayer::S3.new(bucket: "b", region: "us-east-1", access_key_id: "ak",
                                              secret_access_key: "sk", prefix: "library",
                                              client: @fake.client)
      end
    end
    teardown { FileLayer.reset! }

    test "the tools gallery lists Generators as an always-available addon" do
      get tools_path
      assert_response :success
      assert_select "a.addon-card[href=?]", tools_generators_path do
        assert_select ".addon-title", text: "Generators"
      end
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/controllers/tools/generators_controller_test.rb -v`
Expected: FAIL — `tools_generators_path` is undefined (no route yet) / no `Generators` tile.

- [ ] **Step 3: Add the route**

In `config/routes.rb`, inside `namespace :tools do` (after the `resources :boxes ... end` block, before the `namespace :tools` closes):

```ruby
    resources :generators, only: %i[index create show]
```

- [ ] **Step 4: Add the registry entry**

In `app/services/maker/addons/registry.rb`, add to `REGISTRY` after the `"boxes"` entry:

```ruby
        "generators" => Addon.new(
          key: "generators", title: "Generators", icon: "✏️",
          description: "Parametric 2D drawings → SVG (laser & CNC)",
          available: -> { true } # client-only (Maker.js in the browser); always available
        )
```

- [ ] **Step 5: Add a placeholder controller + view so the route resolves**

The gallery only needs `tools_generators_path` to exist for its `link_to`; but `assert_select` on the tile does not hit the controller. Still, create a minimal controller now so later tasks build on it. Create `app/controllers/tools/generators_controller.rb`:

```ruby
module Tools
  # The Generators addon — a client-only Maker.js harness. This controller is generator-AGNOSTIC:
  # it persists a Maker::AddonState and writes a [svg, params.json] bundle via LibraryOutput. All
  # generator schema + geometry live in JS (app/javascript/generators/*). No sidecar, no per-
  # generator branching here. Mirrors Tools::BoxesController minus the sidecar.
  class GeneratorsController < BaseController
    def index
    end
  end
end
```

Create `app/views/tools/generators/index.html.erb`:

```erb
<% content_for :title, "Generators — Tinkerex" %>
<div class="page-head"><h1>Generators</h1></div>
```

- [ ] **Step 6: Run test to verify it passes**

Run: `bin/rails test test/controllers/tools/generators_controller_test.rb -v`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add config/routes.rb app/services/maker/addons/registry.rb \
        app/controllers/tools/generators_controller.rb app/views/tools/generators/index.html.erb \
        test/controllers/tools/generators_controller_test.rb
git commit -m "feat(addons): register the Generators addon (route + registry + gallery tile)"
```

---

## Task 2: Extract the shared folder picker into `Tools::LibraryFolders`

Both `BoxesController` and the new `GeneratorsController` need "which folders can I save into?" (`folder_options`) and "resolve the chosen parent, scoped to the user's own live dirs" (`chosen_parent_node_id`). Extract the copy that lives in `BoxesController` into a concern, include it in both, and prove Boxes still behaves.

**Files:**
- Create: `app/controllers/tools/library_folders.rb`
- Modify: `app/controllers/tools/boxes_controller.rb:104-131` (remove the two methods; include the concern)
- Test: `test/controllers/tools/library_folders_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/controllers/tools/library_folders_test.rb`:

```ruby
require "test_helper"

module Tools
  # Exercises the extracted concern through a tiny host that includes it, so the behavior is pinned
  # independently of any one addon. Uses the same "scope to the user's own live dirs" contract the
  # boxes folder tests already rely on.
  class LibraryFoldersTest < ActiveSupport::TestCase
    class Host
      include Tools::LibraryFolders
      attr_reader :current_user, :params
      def initialize(user, params) = (@current_user, @params = user, ActionController::Parameters.new(params))
    end

    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "lf@example.com", password: PASSWORD, confirmed_at: Time.current)
    end

    test "folder_options lists the library root first, then the user's folders by path" do
      @user.nodes.create!(node_id: SecureRandom.uuid, name: "Projects", kind: "dir")
      opts = Host.new(@user, {}).send(:folder_options)
      assert_equal ["/ (library root)", ""], opts.first
      assert opts.any? { |label, _| label == "/Projects" }
    end

    test "chosen_parent_node_id returns nil for a blank param (root)" do
      assert_nil Host.new(@user, {}).send(:chosen_parent_node_id)
    end

    test "chosen_parent_node_id returns the node_id of the user's own live folder" do
      dir = @user.nodes.create!(node_id: SecureRandom.uuid, name: "CNC", kind: "dir")
      host = Host.new(@user, { parent_node_id: dir.node_id })
      assert_equal dir.node_id, host.send(:chosen_parent_node_id)
    end

    test "chosen_parent_node_id ignores a folder that is not the user's own (falls back to root)" do
      other = User.create!(email: "lf-other@example.com", password: PASSWORD, confirmed_at: Time.current)
      foreign = other.nodes.create!(node_id: SecureRandom.uuid, name: "theirs", kind: "dir")
      host = Host.new(@user, { parent_node_id: foreign.node_id })
      assert_nil host.send(:chosen_parent_node_id)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/controllers/tools/library_folders_test.rb -v`
Expected: FAIL — `uninitialized constant Tools::LibraryFolders`.

- [ ] **Step 3: Create the concern (move the code verbatim from BoxesController)**

Create `app/controllers/tools/library_folders.rb`:

```ruby
module Tools
  # Shared "save into which library folder?" helpers for addon controllers. Extracted from
  # BoxesController so Boxes and Generators share ONE copy (DRY). Both methods are private helpers
  # for the including controller.
  module LibraryFolders
    private

    # The folder the user picked to save into, or nil (= library root). SCOPED to the user's own
    # live dirs, so a forged/foreign node_id can't write into someone else's tree and a stale or
    # blank one simply falls back to root.
    def chosen_parent_node_id
      id = params[:parent_node_id].presence
      return nil unless id

      current_user.nodes.present.find_by(node_id: id, kind: "dir")&.node_id
    end

    # Existing folders to offer in the "save to" picker, as [label, node_id] pairs with the library
    # root first. Restricted to folders that ALREADY exist: creating folders on save needs a
    # cross-backend mkdir story we haven't built. Paths are built in Ruby (one pluck of the user's
    # own dirs — a bounded set) rather than a recursive SQL CTE, to stay SQLite/Postgres-agnostic.
    def folder_options
      rows = current_user.nodes.present.where(kind: "dir").pluck(:node_id, :parent_node_id, :name)
      by_id = rows.index_by(&:first)
      labels = {}
      label = lambda do |nid|
        return labels[nid] if labels.key?(nid)

        _id, parent, name = by_id[nid]
        prefix = parent && by_id[parent] ? label.call(parent) : ""
        labels[nid] = "#{prefix}/#{name}"
      end
      folders = rows.map { |nid, _p, _n| [ label.call(nid), nid ] }.sort_by(&:first)
      [ [ "/ (library root)", "" ] ] + folders
    end
  end
end
```

- [ ] **Step 4: Run the concern test to verify it passes**

Run: `bin/rails test test/controllers/tools/library_folders_test.rb -v`
Expected: PASS (4 tests).

- [ ] **Step 5: Switch BoxesController to the concern**

In `app/controllers/tools/boxes_controller.rb`: add `include Tools::LibraryFolders` right after `class BoxesController < BaseController`, and **delete** the two private methods `chosen_parent_node_id` (lines ~106-111) and `folder_options` (lines ~118-131) — they now live in the concern. Leave `box_params` and everything else intact.

The top of the class becomes:

```ruby
  class BoxesController < BaseController
    include Tools::LibraryFolders
    before_action :require_boxes!
```

And the private section keeps only `client`, `require_boxes!`, and `box_params` (the two folder methods are gone).

- [ ] **Step 6: Run the boxes tests to prove no regression**

Run: `bin/rails test test/controllers/tools/boxes_controller_test.rb -v`
Expected: PASS (all boxes tests, including the folder-picker + chosen-folder + foreign-folder tests, still green — proof the extraction preserved behavior).

- [ ] **Step 7: Commit**

```bash
git add app/controllers/tools/library_folders.rb app/controllers/tools/boxes_controller.rb \
        test/controllers/tools/library_folders_test.rb
git commit -m "refactor(addons): extract Tools::LibraryFolders concern (shared by boxes + generators)"
```

---

## Task 3: `GeneratorsController#index` — saved grids + the harness mount

**Files:**
- Modify: `app/controllers/tools/generators_controller.rb`
- Modify: `app/views/tools/generators/index.html.erb`
- Test: `test/controllers/tools/generators_controller_test.rb`

- [ ] **Step 1: Write the failing tests**

Append to `test/controllers/tools/generators_controller_test.rb` (inside the class):

```ruby
    test "index mounts the harness and offers a save form with a folder picker" do
      @user.nodes.create!(node_id: SecureRandom.uuid, name: "Projects", kind: "dir")
      get tools_generators_path
      assert_response :success
      # the harness mount (Stimulus builds picker/form/preview inside it)
      assert_select "[data-controller='generator']"
      assert_select "[data-generator-target='picker']"
      assert_select "[data-generator-target='preview']"
      # the save form posts to create, with name + folder picker (root default + existing folder)
      assert_select "form[action=?][method='post']", tools_generators_path
      assert_select "form input[name='name']"
      assert_select "form select[name='parent_node_id'] option[value='']"
      assert_select "form select[name='parent_node_id'] option", text: %r{/Projects}
      # hidden fields the harness fills before submit
      assert_select "form input[type='hidden'][name='generator']"
      assert_select "form input[type='hidden'][name='svg']"
    end

    test "index lists this user's saved grids, newest first" do
      older = @user.maker_addon_states.create!(addon_key: "generators", name: "Older Grid",
                                               data: { "generator" => "material-test-grid", "params" => {} })
      newer = @user.maker_addon_states.create!(addon_key: "generators", name: "Newer Grid",
                                               data: { "generator" => "material-test-grid", "params" => {} })
      get tools_generators_path
      assert_response :success
      assert_select ".generator-saved", text: /Newer Grid/
      assert_select ".generator-saved", text: /Older Grid/
      assert response.body.index("Newer Grid") < response.body.index("Older Grid"),
             "newer grid should render before older"
    end

    test "index does not list another user's saved grids" do
      other = User.create!(email: "gen-other@example.com", password: PASSWORD, confirmed_at: Time.current)
      other.maker_addon_states.create!(addon_key: "generators", name: "Secret Grid",
                                       data: { "generator" => "material-test-grid", "params" => {} })
      get tools_generators_path
      assert_response :success
      assert_select "*", text: /Secret Grid/, count: 0
    end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/controllers/tools/generators_controller_test.rb -v`
Expected: FAIL — the index view has no harness mount / save form / saved list yet.

- [ ] **Step 3: Implement the index action**

Replace `app/controllers/tools/generators_controller.rb` with:

```ruby
module Tools
  # The Generators addon — a client-only Maker.js harness. Generator-AGNOSTIC: it persists a
  # Maker::AddonState and writes a [svg, params.json] bundle via LibraryOutput. All generator schema
  # + geometry live in JS (app/javascript/generators/*). No sidecar, no per-generator branching.
  class GeneratorsController < BaseController
    include Tools::LibraryFolders

    ADDON_KEY = "generators".freeze
    MAX_SVG_BYTES = 2_000_000 # generation is client-side + bounded; this is a backstop.

    def index
      @saved = current_user.maker_addon_states.for_addon(ADDON_KEY)
                           .includes(:files).order(updated_at: :desc, id: :desc)
      @folders = folder_options
    end

    private

    def addon_params = params[:params]&.to_unsafe_h || {}
  end
end
```

- [ ] **Step 4: Implement the index view**

Replace `app/views/tools/generators/index.html.erb` with:

```erb
<% content_for :title, "Generators — Tinkerex" %>

<div class="page-head"><h1>Generators</h1>
  <p class="page-subtitle muted">Parametric 2D drawings → SVG, generated in your browser.</p>
</div>

<div class="generator-editor" data-controller="generator">
  <aside class="generator-side">
    <label class="generator-picker-label">Generator
      <select data-generator-target="picker" data-action="change->generator#selectGenerator"></select>
    </label>

    <%= form_with url: tools_generators_path, method: :post, data: { generator_target: "form" } do |f| %>
      <input type="hidden" name="generator" data-generator-target="generatorField">
      <input type="hidden" name="svg" data-generator-target="svgField">

      <div class="generator-params" data-generator-target="fields"
           data-action="input->generator#render"></div>

      <label class="generator-name-label">Name
        <%= text_field_tag "name", "", required: true, placeholder: "e.g. 3mm birch test" %>
      </label>
      <label class="generator-folder-label">Save into
        <%= select_tag "parent_node_id", options_for_select(@folders) %>
      </label>
      <%= submit_tag "Save to library", class: "generator-save", data: { generator_target: "save" } %>
    <% end %>
  </aside>

  <div class="generator-preview">
    <img data-generator-target="preview" alt="live preview">
  </div>
</div>

<section class="generator-saved-list">
  <h2>Saved grids</h2>
  <% if @saved.any? %>
    <ul>
      <% @saved.each do |state| %>
        <li class="generator-saved">
          <%= link_to state.name, tools_generator_path(state) %>
          <span class="muted"><%= state.data["generator"] %></span>
        </li>
      <% end %>
    </ul>
  <% else %>
    <p class="muted generator-saved-hint">No saved grids yet — build one above and Save.</p>
  <% end %>
</section>
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bin/rails test test/controllers/tools/generators_controller_test.rb -v`
Expected: PASS (index tests green; the Task 1 gallery test still green).

- [ ] **Step 6: Commit**

```bash
git add app/controllers/tools/generators_controller.rb app/views/tools/generators/index.html.erb \
        test/controllers/tools/generators_controller_test.rb
git commit -m "feat(addons): Generators#index — saved grids + harness mount + save form"
```

---

## Task 4: `GeneratorsController#create` — persist state + write the tied bundle

**Files:**
- Modify: `app/controllers/tools/generators_controller.rb`
- Test: `test/controllers/tools/generators_controller_test.rb`

- [ ] **Step 1: Write the failing tests**

Append to the test class:

```ruby
    SVG_FIXTURE = %(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><rect width="10" height="10"/></svg>).freeze

    test "create saves the state + a tied bundle (svg output + params file) and redirects to show" do
      assert_difference("Maker::AddonState.count", 1) do
        post tools_generators_path, params: {
          name: "My Grid", generator: "material-test-grid",
          params: { cols: 3, rows: 3, cell: 10 }, svg: SVG_FIXTURE
        }
      end
      state = @user.maker_addon_states.for_addon("generators").order(:id).last
      assert_equal "material-test-grid", state.data["generator"]
      assert_equal({ "cols" => "3", "rows" => "3", "cell" => "10" }, state.data["params"])
      assert_equal %w[output parameters], state.files.map(&:role)
      state.files.each { |af| assert @user.nodes.exists?(node_id: af.node_id) }
      assert_redirected_to tools_generator_path(state)
    end

    test "create writes an svg output node and a json parameters node into the library" do
      post tools_generators_path, params: {
        name: "Bundle", generator: "material-test-grid", params: { cols: 2 }, svg: SVG_FIXTURE
      }
      state = @user.maker_addon_states.for_addon("generators").order(:id).last
      out = state.files.find { |f| f.role == "output" }
      par = state.files.find { |f| f.role == "parameters" }
      assert_equal "image/svg+xml", out.content_type
      assert_equal "application/json", par.content_type
    end

    test "create enqueues a preview for each written node" do
      assert_enqueued_jobs 2, only: Maker::Previews::RenderJob do
        post tools_generators_path, params: {
          name: "Preview Me", generator: "material-test-grid", params: { cols: 2 }, svg: SVG_FIXTURE
        }
      end
    end

    test "create saves into the chosen folder (asserts the controller's parent wiring, backend-agnostic)" do
      folder = @user.nodes.create!(node_id: SecureRandom.uuid, name: "CNC", kind: "dir")
      captured = :unset
      original = Maker::Addons::LibraryOutput.method(:write)
      Maker::Addons::LibraryOutput.define_singleton_method(:write) do |user:, state:, parent_node_id:, files:|
        captured = parent_node_id
        []
      end
      begin
        post tools_generators_path, params: {
          name: "Foldered", generator: "material-test-grid", params: { cols: 2 },
          svg: SVG_FIXTURE, parent_node_id: folder.node_id
        }
      ensure
        Maker::Addons::LibraryOutput.define_singleton_method(:write, original)
      end
      assert_equal folder.node_id, captured
    end

    test "create ignores a foreign parent_node_id (falls back to root)" do
      other = User.create!(email: "gen-foreign@example.com", password: PASSWORD, confirmed_at: Time.current)
      foreign = other.nodes.create!(node_id: SecureRandom.uuid, name: "theirs", kind: "dir")
      captured = :unset
      original = Maker::Addons::LibraryOutput.method(:write)
      Maker::Addons::LibraryOutput.define_singleton_method(:write) do |user:, state:, parent_node_id:, files:|
        captured = parent_node_id
        []
      end
      begin
        post tools_generators_path, params: {
          name: "Foreign", generator: "material-test-grid", params: { cols: 2 },
          svg: SVG_FIXTURE, parent_node_id: foreign.node_id
        }
      ensure
        Maker::Addons::LibraryOutput.define_singleton_method(:write, original)
      end
      assert_nil captured
    end

    test "create rejects a missing svg with 422" do
      post tools_generators_path, params: { name: "No SVG", generator: "material-test-grid", params: { cols: 2 } }
      assert_response :unprocessable_entity
    end

    test "create rejects an over-cap svg with 422" do
      post tools_generators_path, params: {
        name: "Huge", generator: "material-test-grid", params: { cols: 2 }, svg: "x" * 2_000_001
      }
      assert_response :unprocessable_entity
    end
```

Note: the params values arrive as strings (`"3"`) because they are form fields — the assertion reflects the real wire shape, exactly as the boxes flow stores them.

- [ ] **Step 2: Verify the Previews job class name**

Run: `grep -rn "class RenderJob\|Previews::Enqueue" app/jobs app/services/maker/previews | head`
Expected: confirms `Maker::Previews::RenderJob` (used by `assert_enqueued_jobs ... only:`). If the job class differs, update the test's `only:` to the real class name before proceeding.

- [ ] **Step 3: Run tests to verify they fail**

Run: `bin/rails test test/controllers/tools/generators_controller_test.rb -v`
Expected: FAIL — no `create` action.

- [ ] **Step 4: Implement `create`**

In `app/controllers/tools/generators_controller.rb`, add the `create` action after `index` and a `svg_bytes` helper in the private section:

```ruby
    def create
      bytes = svg_bytes
      return head(:unprocessable_entity) if bytes.blank? || bytes.bytesize > MAX_SVG_BYTES

      generator = params.require(:generator)
      state = current_user.maker_addon_states.create!(
        addon_key: ADDON_KEY, name: params.require(:name),
        data: { generator:, params: addon_params }
      )
      base = state.name.parameterize.presence || "grid"
      Maker::Addons::LibraryOutput.write(
        user: current_user, state:, parent_node_id: chosen_parent_node_id,
        files: [
          { name: "#{base}-#{state.id}.svg", bytes:, content_type: "image/svg+xml", role: "output" },
          { name: "#{base}-#{state.id}.params.json",
            bytes: JSON.pretty_generate(state.data), content_type: "application/json", role: "parameters" }
        ]
      )
      redirect_to tools_generator_path(state), notice: "Saved “#{state.name}”."
    end
```

And in the private section (below `addon_params`):

```ruby
    # SVG arrives as a plain form field (SVG is text). Accept a string or an uploaded part.
    def svg_bytes
      raw = params[:svg]
      (raw.respond_to?(:read) ? raw.read : raw).to_s
    end
```

Add `require "json"` at the top of the file (mirrors `boxes_controller.rb`).

- [ ] **Step 5: Run tests to verify they pass**

Run: `bin/rails test test/controllers/tools/generators_controller_test.rb -v`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add app/controllers/tools/generators_controller.rb test/controllers/tools/generators_controller_test.rb
git commit -m "feat(addons): Generators#create — persist state + write [svg, params.json] bundle"
```

---

## Task 5: `GeneratorsController#show` — reopen a saved grid

**Files:**
- Modify: `app/controllers/tools/generators_controller.rb`
- Create: `app/views/tools/generators/show.html.erb`
- Test: `test/controllers/tools/generators_controller_test.rb`

- [ ] **Step 1: Write the failing tests**

Append to the test class:

```ruby
    test "show reopens a saved grid: its name and a rehydration payload for the harness" do
      post tools_generators_path, params: {
        name: "Reopen Me", generator: "material-test-grid",
        params: { cols: 4, rows: 2 }, svg: SVG_FIXTURE
      }
      state = @user.maker_addon_states.for_addon("generators").order(:id).last
      get tools_generator_path(state)
      assert_response :success
      assert_select "*", text: /Reopen Me/
      # the harness reads data-generator-reopen-value to prefill generator + params
      assert_select "[data-controller='generator'][data-generator-reopen-value*='material-test-grid']"
      assert_select "[data-generator-reopen-value*='cols']"
    end

    test "show does not expose another user's grid" do
      other = User.create!(email: "gen-show-other@example.com", password: PASSWORD, confirmed_at: Time.current)
      theirs = other.maker_addon_states.create!(addon_key: "generators", name: "Theirs",
                                                data: { "generator" => "material-test-grid", "params" => {} })
      assert_raises(ActiveRecord::RecordNotFound) { get tools_generator_path(theirs) }
    end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/controllers/tools/generators_controller_test.rb -v`
Expected: FAIL — no `show` action / view.

- [ ] **Step 3: Implement `show`**

Add to `app/controllers/tools/generators_controller.rb` after `create`:

```ruby
    def show
      @state = current_user.maker_addon_states.for_addon(ADDON_KEY).includes(:files).find(params[:id])
    end
```

`find` on a user-scoped relation raises `RecordNotFound` for a foreign id → the second test passes.

- [ ] **Step 4: Implement the show view**

Create `app/views/tools/generators/show.html.erb`:

```erb
<% content_for :title, "#{@state.name} — Generators" %>

<div class="page-head"><h1><%= @state.name %></h1>
  <p class="page-subtitle muted"><%= @state.data["generator"] %></p>
</div>

<%# Reopen in the harness: same editor as index, prefilled from this state's data (duplicate & tweak
    → Save creates a NEW state, matching the shipped boxes flow). %>
<div class="generator-editor" data-controller="generator"
     data-generator-reopen-value="<%= @state.data.to_json %>">
  <aside class="generator-side">
    <label class="generator-picker-label">Generator
      <select data-generator-target="picker" data-action="change->generator#selectGenerator"></select>
    </label>
    <%= form_with url: tools_generators_path, method: :post, data: { generator_target: "form" } do %>
      <input type="hidden" name="generator" data-generator-target="generatorField">
      <input type="hidden" name="svg" data-generator-target="svgField">
      <div class="generator-params" data-generator-target="fields" data-action="input->generator#render"></div>
      <label class="generator-name-label">Name
        <%= text_field_tag "name", @state.name, required: true %>
      </label>
      <%= submit_tag "Save a copy", class: "generator-save", data: { generator_target: "save" } %>
    <% end %>
  </aside>
  <div class="generator-preview"><img data-generator-target="preview" alt="live preview"></div>
</div>

<section class="generator-bundle">
  <h2>Saved files</h2>
  <ul>
    <% @state.files.each do |af| %>
      <li><span class="muted"><%= af.role %></span> — <code><%= af.node_id %></code></li>
    <% end %>
  </ul>
</section>
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bin/rails test test/controllers/tools/generators_controller_test.rb -v`
Expected: PASS (whole file green).

- [ ] **Step 6: Run the full controller suite on all three backends**

```bash
bin/rails test test/controllers/tools/generators_controller_test.rb test/controllers/tools/boxes_controller_test.rb test/controllers/tools/library_folders_test.rb
LIBRARY_BACKEND=share bin/rails test test/controllers/tools/generators_controller_test.rb
LIBRARY_BACKEND=s3 bin/rails test test/controllers/tools/generators_controller_test.rb
```
Expected: all green on all three legs.

- [ ] **Step 7: Commit**

```bash
git add app/controllers/tools/generators_controller.rb app/views/tools/generators/show.html.erb \
        test/controllers/tools/generators_controller_test.rb
git commit -m "feat(addons): Generators#show — reopen a saved grid (prefill → save a copy)"
```

---

## Task 6: Vendor Maker.js and make it importable

Maker.js (`makerjs`, Apache-2.0) has runtime deps, so pinning it raw drags transitive modules (the JSZip failure mode). Primary path: fetch the **standalone browser build** (deps inlined) and pin it to a bare specifier, adding a one-line ESM default-export shim. Verify `import makerjs from "makerjs"` resolves and `makerjs.exporter.toSVG` exists in the browser.

**Files:**
- Create: `vendor/javascript/makerjs.js`
- Modify: `config/importmap.rb`

- [ ] **Step 1: Fetch the standalone browser build**

```bash
cd /Users/charlesschwartz/Desktop/tinkerex/.claude/worktrees/addons-brainstorm-plan-04adb7
curl -fsSL https://cdn.jsdelivr.net/npm/makerjs@0.18.1/dist/browser.maker.js -o vendor/javascript/makerjs.js
ls -l vendor/javascript/makerjs.js
head -c 400 vendor/javascript/makerjs.js
```
Expected: a ~non-trivial file (hundreds of KB). If 0.18.1 404s, list versions with `curl -fsSL https://data.jsdelivr.com/v1/packages/npm/makerjs` and pick the latest `dist/browser.maker.js`.

- [ ] **Step 2: Confirm how the build exposes itself, then add an ESM shim**

Inspect the UMD preamble to see the global it attaches to:

```bash
grep -nE "typeof (module|define|exports|self|window)|root\.|globalThis|MakerJs|makerjs" vendor/javascript/makerjs.js | head
```

Append an ESM default export so `import makerjs from "makerjs"` works under importmap. Add to the **end** of `vendor/javascript/makerjs.js`:

```js

// --- ESM shim (added for importmap) -------------------------------------------------------------
// The vendored bytes above are the untouched UMD browser build; it attaches the library to a global.
// Re-export it as an ES module default so `import makerjs from "makerjs"` resolves under importmap.
export default (globalThis.makerjs || globalThis.MakerJs);
```

If Step 2's grep shows the UMD guards on `typeof self`/`window` only (not `globalThis`) and the module fails to attach under ESM strict mode (`this === undefined`), fall back: prepend `var self = globalThis;` before the UMD, or use the jspm route in Step 5's fallback.

- [ ] **Step 3: Pin it in importmap**

In `config/importmap.rb`, add near the other vendored-lib pins (after the jszip block):

```ruby
# Maker.js 0.18.1 — Apache-2.0 — https://github.com/microsoft/maker.js — vendored browser standalone
# build (deps inlined) + a one-line ESM default-export shim, pinned to a bare specifier so
# `import makerjs from "makerjs"` resolves. Same vendoring pattern as jszip (raw pin drags deps).
pin "makerjs", to: "makerjs.js" # @0.18.1
```

- [ ] **Step 4: Browser-smoke the import**

Start the app and open the tools page, then check Maker.js loads with no importmap 404s.

```bash
grep -rn "def index" app/controllers/tools/home_controller.rb   # confirm @addons is set (gallery)
```

Use the Browser pane: `preview_start` the Rails dev server (add a `.claude/launch.json` entry `bin/rails server -p 3020` if needed), sign in, navigate to `/tools/generators`. Then in the browser console (via the harness once Task 7 exists) — for now, verify no red importmap errors for `makerjs` in `read_console_messages`. A deeper functional check happens in Task 8.

- [ ] **Step 5: Fallback if the standalone build won't import**

If `import makerjs from "makerjs"` fails in the browser (UMD/ESM `this` problem), remove `vendor/javascript/makerjs.js` and use the jspm ESM build instead (the exact JSZip precedent):

```bash
bin/importmap pin makerjs   # downloads the jspm ESM build (+ any small deps) into vendor/javascript
git status vendor/javascript config/importmap.rb   # review what it added; commit those files + pins
```
Then re-run the Step 4 smoke. Keep whichever path imports cleanly.

- [ ] **Step 6: Commit**

```bash
git add vendor/javascript config/importmap.rb
git commit -m "chore(addons): vendor Maker.js (Apache-2.0) + importmap pin for the client harness"
```

---

## Task 7: The harness Stimulus controller + JS generator registry

The harness owns: (1) a client-side generator **registry**, (2) building the param form from a module's schema, (3) live preview via a data-URL `<img>` (safe — SVG in `<img>` is not scriptable), (4) keeping the hidden `generator`/`svg` fields current for the form POST, and (5) reopen-prefill. It knows the module **contract** (`{ key, title, description, params, generate(values) → svgString }`), not any specific generator.

**Files:**
- Create: `app/javascript/generators/index.js`
- Create: `app/javascript/controllers/generator_controller.js`
- Modify: `config/importmap.rb`

- [ ] **Step 1: Create the JS registry**

Create `app/javascript/generators/index.js`:

```js
// The client-side generator registry. Adding a generator = author a module (schema + geometry) and
// list it here. NO Ruby change — the Rails controller is generator-agnostic. Each module is:
//   { key, title, description, params: [{name,label,type,default,min,max,step}], generate(values) }
// where generate returns an SVG string.
import materialTestGrid from "generators/material_test_grid"

const REGISTRY = [materialTestGrid]

export const all = () => REGISTRY
export const find = (key) => REGISTRY.find((g) => g.key === key)
export default REGISTRY
```

- [ ] **Step 2: Create the harness controller**

Create `app/javascript/controllers/generator_controller.js`:

```js
import { Controller } from "@hotwired/stimulus"
import * as registry from "generators/index"

// The generator harness. Builds the picker + param form from the JS registry, previews the active
// module's SVG live (data-URL <img> — SVG in <img> can't run scripts, so user text in labels is
// safe), and keeps the hidden `generator`/`svg` fields current for the Rails form POST. Reopen:
// data-generator-reopen-value = {generator, params} prefills generator + fields.
export default class extends Controller {
  static targets = ["picker", "fields", "preview", "generatorField", "svgField"]
  static values = { reopen: Object }

  connect() {
    this.populatePicker()
    const reopenKey = this.reopenValue && this.reopenValue.generator
    if (reopenKey && registry.find(reopenKey)) this.pickerTarget.value = reopenKey
    this.selectGenerator()
    if (reopenKey) this.prefill(this.reopenValue.params || {})
  }

  populatePicker() {
    this.pickerTarget.innerHTML = ""
    for (const gen of registry.all()) {
      const opt = document.createElement("option")
      opt.value = gen.key
      opt.textContent = gen.title
      this.pickerTarget.appendChild(opt)
    }
  }

  selectGenerator() {
    const gen = this.currentGenerator()
    this.generatorFieldTarget.value = gen.key
    this.buildFields(gen)
    this.render()
  }

  buildFields(gen) {
    this.fieldsTarget.innerHTML = ""
    for (const p of gen.params) {
      const wrap = document.createElement("label")
      wrap.className = "generator-field"
      wrap.textContent = p.label || p.name
      const input = document.createElement("input")
      input.name = `params[${p.name}]`
      input.dataset.param = p.name
      if (p.type === "bool") { input.type = "checkbox"; input.checked = !!p.default }
      else if (p.type === "text") { input.type = "text"; input.value = p.default ?? "" }
      else {
        input.type = "number"
        if (p.min != null) input.min = p.min
        if (p.max != null) input.max = p.max
        input.step = p.step ?? (p.type === "int" ? 1 : "any")
        input.value = p.default ?? 0
      }
      wrap.appendChild(input)
      this.fieldsTarget.appendChild(wrap)
    }
  }

  values() {
    const out = {}
    for (const el of this.fieldsTarget.querySelectorAll("[data-param]")) {
      out[el.dataset.param] = el.type === "checkbox" ? el.checked : el.value
    }
    return out
  }

  prefill(params) {
    for (const el of this.fieldsTarget.querySelectorAll("[data-param]")) {
      const v = params[el.dataset.param]
      if (v == null) continue
      if (el.type === "checkbox") el.checked = !!v
      else el.value = v
    }
    this.render()
  }

  render() {
    const gen = this.currentGenerator()
    let svg
    try {
      svg = gen.generate(this.values())
    } catch (e) {
      svg = `<svg xmlns="http://www.w3.org/2000/svg" width="200" height="40"><text x="4" y="24" fill="#c00">${String(e.message).replace(/[<&]/g, "")}</text></svg>`
    }
    this.svgFieldTarget.value = svg
    this.previewTarget.src = `data:image/svg+xml;utf8,${encodeURIComponent(svg)}`
  }

  currentGenerator() {
    return registry.find(this.pickerTarget.value) || registry.all()[0]
  }
}
```

- [ ] **Step 3: Pin the generators path in importmap**

In `config/importmap.rb`, add:

```ruby
pin_all_from "app/javascript/generators", under: "generators"
```

- [ ] **Step 4: Commit (module lands in Task 8; import will resolve then)**

```bash
git add app/javascript/generators/index.js app/javascript/controllers/generator_controller.js config/importmap.rb
git commit -m "feat(addons): Maker.js harness (Stimulus form-builder + preview + generator registry)"
```

Note: `generators/index.js` imports `generators/material_test_grid`, created in Task 8. Do the browser smoke only after Task 8 (otherwise the import 404s). This commit is code-complete for the harness itself.

---

## Task 8: The Material Test Grid generator module

A `rows × cols` grid of squares (X = speed sweep, Y = power sweep), each labeled `S… P…`, with axis labels and a material title. Built with Maker.js (`makerjs.models.Rectangle` + `addCaption`, exported via `makerjs.exporter.toSVG`) so DXF export is a near-free future add. Returns an **SVG string**. `generate` is pure (values → SVG), so it previews identically and would unit-test unchanged if a JS runner is ever added.

**Files:**
- Create: `app/javascript/generators/material_test_grid.js`

- [ ] **Step 1: Create the module**

Create `app/javascript/generators/material_test_grid.js`:

```js
import makerjs from "makerjs"

// Material Test Grid — power × speed sweep for dialing in laser settings. Pure: values -> SVG string.
// Geometry via Maker.js (Rectangle per cell + captions for labels), exported with toSVG. v1 is a
// simple labeled grid (no color-coded laser layers — a future param); the maker assigns per-row/
// column settings in their laser software.
const clampInt = (v, lo, hi) => Math.max(lo, Math.min(hi, Math.round(Number(v) || 0)))
const num = (v, d) => (Number.isFinite(Number(v)) ? Number(v) : d)
const lerp = (a, b, t, n) => (n <= 1 ? a : a + (b - a) * (t / (n - 1)))
const round = (x) => Math.round(x * 100) / 100

export default {
  key: "material-test-grid",
  title: "Material Test Grid",
  description: "Power × speed sweep to dial in laser settings.",
  params: [
    { name: "cols", label: "Speed steps (X)", type: "int", default: 5, min: 1, max: 20 },
    { name: "rows", label: "Power steps (Y)", type: "int", default: 5, min: 1, max: 20 },
    { name: "speedMin", label: "Speed min", type: "float", default: 100 },
    { name: "speedMax", label: "Speed max", type: "float", default: 500 },
    { name: "powerMin", label: "Power min (%)", type: "float", default: 10 },
    { name: "powerMax", label: "Power max (%)", type: "float", default: 100 },
    { name: "cell", label: "Cell size (mm)", type: "float", default: 10, min: 1, max: 100 },
    { name: "gap", label: "Gap (mm)", type: "float", default: 4, min: 0, max: 50 },
    { name: "material", label: "Material label", type: "text", default: "" },
    { name: "labels", label: "Show cell labels", type: "bool", default: true },
  ],

  generate(v) {
    const cols = clampInt(v.cols, 1, 20)
    const rows = clampInt(v.rows, 1, 20)
    const cell = num(v.cell, 10)
    const gap = num(v.gap, 4)
    const pitch = cell + gap
    const labels = v.labels === true || v.labels === "true" || v.labels === "on"

    const model = { models: {}, captions: [] }

    for (let r = 0; r < rows; r++) {
      const power = round(lerp(num(v.powerMin, 10), num(v.powerMax, 100), r, rows))
      for (let c = 0; c < cols; c++) {
        const speed = round(lerp(num(v.speedMin, 100), num(v.speedMax, 500), c, cols))
        const sq = new makerjs.models.Rectangle(cell, cell)
        // Maker.js Y is up; put row 0 at the top by flipping the row index.
        sq.origin = [c * pitch, (rows - 1 - r) * pitch]
        const name = `c_${r}_${c}`
        model.models[name] = sq
        if (labels) {
          const cx = c * pitch + cell / 2
          const cy = (rows - 1 - r) * pitch + cell / 2
          makerjs.model.addCaption(sq, `S${speed} P${power}`, [cx - cell / 2, cy], [cx + cell / 2, cy])
        }
      }
    }

    // Axis + material captions along the edges.
    const width = cols * pitch - gap
    const height = rows * pitch - gap
    makerjs.model.addCaption(model, "Speed →", [0, -gap - cell / 2], [width, -gap - cell / 2])
    makerjs.model.addCaption(model, "Power ↓", [-gap - cell / 2, 0], [-gap - cell / 2, height])
    const title = (v.material && String(v.material).trim()) || "Material Test Grid"
    makerjs.model.addCaption(model, title, [0, height + gap + cell / 2], [width, height + gap + cell / 2])

    return makerjs.exporter.toSVG(model, {
      units: makerjs.unitType.Millimeter,
      useSvgPathOnly: false,
      fontSize: `${Math.max(2, cell / 5)}px`,
    })
  },
}
```

- [ ] **Step 2: Browser smoke — the harness renders, previews, and generates valid SVG**

Start the dev server (Browser pane `preview_start`, or `bin/rails server`), sign in, open `/tools/generators`.

Verify in the Browser pane:
1. `read_console_messages` shows **no** importmap 404s for `makerjs` / `generators/*`.
2. The generator picker shows "Material Test Grid"; the param form renders all 10 fields with defaults.
3. The preview `<img>` shows a grid of squares with `S… P…` labels, "Speed →" / "Power ↓" axis labels, and the material title. Changing `cols`/`rows`/`cell` updates the preview live.

If `addCaption`/caption rendering misbehaves in the vendored build (no text in the SVG), apply the fallback: replace the caption calls with post-export `<text>` splicing — after `toSVG`, read the returned SVG's `viewBox`, and insert `<text>` nodes at the computed cell centers (same `cx`/`cy`, converting Maker.js Y-up to SVG Y-down via `svgY = height - modelY`). Keep the squares from Maker.js. Re-run the smoke.

- [ ] **Step 3: Browser smoke — save produces a thumbnailed bundle**

In the browser: type a name ("3mm birch test"), leave folder = root, click **Save to library**. Expect a redirect to the show page listing an `output` and a `parameters` file. Then navigate to `/files` (the library web UI) and confirm the `…-<id>.svg` shows a **grid thumbnail** (the SVG renderer ran) and the `…-params.json` is present in the same area.

- [ ] **Step 4: Run the automated suite once more (nothing JS-side should have moved Ruby behavior)**

Run: `bin/rails test test/controllers/tools/`
Expected: green.

- [ ] **Step 5: Commit**

```bash
git add app/javascript/generators/material_test_grid.js
git commit -m "feat(addons): Material Test Grid generator module (Maker.js → labeled SVG grid)"
```

---

## Task 9: Finalize — full smoke, all-backends gate, docs

**Files:**
- Modify: `docs/STATUS.md` (add a one-line entry), `MEMORY.md` pointer if warranted
- Modify: `CLAUDE.md` only if the addon surface note needs it (likely just STATUS)

- [ ] **Step 1: Full manual smoke (the DoD walkthrough)**

Confirm end-to-end in the browser: `/tools` shows the **Generators** tile (not greyed) → open it → Material Test Grid form → live preview updates on edit → Save → bundle appears in the library with an SVG thumbnail + params.json → open a **saved grid** from the list (show) → it prefills → "Save a copy" makes a new state + bundle.

- [ ] **Step 2: Run the whole server suite on all three backends**

```bash
bin/rails test
LIBRARY_BACKEND=share bin/rails test
LIBRARY_BACKEND=s3 bin/rails test
```
Expected: identical pass counts on all three legs, 0 failures / 0 errors. Record the run counts.

- [ ] **Step 3: Confirm the "generator-agnostic controller" invariant holds**

Run: `grep -in "material-test-grid\|grid\|makerjs\|rectangle\|speed\|power" app/controllers/tools/generators_controller.rb`
Expected: **no** generator-specific references (only generic addon plumbing). This is the DoD's agnosticism check.

- [ ] **Step 4: Update `docs/STATUS.md`**

Add a dated one-liner under the latest status noting: first client-only `/tools` addon shipped — the Maker.js generator harness + Material Test Grid (generator-agnostic controller; every future generator is a JS module + a registry line), server suite green on all three `LIBRARY_BACKEND` legs.

- [ ] **Step 5: Commit**

```bash
git add docs/STATUS.md CLAUDE.md 2>/dev/null; git commit -m "docs(addons): note the Generators addon (Maker.js harness + Material Test Grid) shipped"
```

- [ ] **Step 6: Finish the branch**

Use the `superpowers:finishing-a-development-branch` skill to decide merge/PR. Summarize: what shipped, the all-backends test result, and that adding the next generator (kerf card, bolt-circle) is now a JS module + one registry line.

---

## Self-Review

**Spec coverage:**
- §1 goal (client-only harness + Material Test Grid) → Tasks 3–8. ✓
- §2 units (agnostic controller, harness, module) → Tasks 3–5 (controller), 7 (harness), 8 (module). ✓
- §3 Maker.js vendoring (standalone build + shim, JSZip pattern, jspm fallback) → Task 6. ✓
- §4 generator contract `{key,title,description,params,generate}` → Task 7 (harness reads it) + Task 8 (module implements it). Contract returns an **SVG string** (refinement over the spec's "Maker.js model" — the harness stays Maker.js-free; modules own export). Noted here so it's deliberate, not drift. ✓
- §5 test grid geometry (rows×cols, labels, axis, material, mm, bounds ≤20) → Task 8 + schema `max: 20`. ✓
- §6 controller index/create/show + agnostic + registry line + route + shared folder concern → Tasks 1, 2, 3, 4, 5 + Task 9 Step 3 invariant check. ✓
- §7 security (data-URL `<img>` preview, download-served saved SVG, size cap) → Task 4 (`MAX_SVG_BYTES`) + Task 7 (data-URL img). ✓
- §8 testing (controller gate, all three backends, always-available gallery, no Maker.js in Ruby) → Tasks 1, 4, 5 (Step 6), 9 (Step 2). ✓
- §9/§10 deferred/DoD → honored (no second generator, no DXF, no color layers, no in-place versioning; DoD walkthrough = Task 9 Step 1). ✓

**Placeholder scan:** No "TBD"/"add error handling"/"similar to Task N" — every code step shows complete code; the two adaptive spots (Maker.js import path in Task 6, caption rendering in Task 8) give a concrete primary **and** a concrete fallback, not a placeholder.

**Type/name consistency:** `ADDON_KEY = "generators"`, `data: { generator:, params: }`, roles `%w[output parameters]`, targets `picker/fields/preview/generatorField/svgField`, values `reopen` (`data-generator-reopen-value`), module contract `generate(values) → svg string`, registry `all()/find()` — all consistent across controller, views, harness, and module. `folder_options`/`chosen_parent_node_id` names preserved through the extraction so boxes tests still pass.

**Known adaptive points (honest, not placeholders):** (1) Maker.js exact build/import path — Task 6 tries the standalone+shim, falls back to the jspm pin, both concrete. (2) Maker.js caption text rendering — Task 8 uses `addCaption`, falls back to `<text>` splicing with the exact Y-flip formula. Both are verified by browser smoke, which is the correct gate for un-unit-testable client rendering in this importmap app.
