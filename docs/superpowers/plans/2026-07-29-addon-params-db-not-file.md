# Addon params in the DB, not in a library file — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop writing a `.params.json` file into the library on every addon save, and replace the one job that file did (readable + portable params) with a params list on each show page and one shared JSON download.

**Architecture:** The params are **already** in the DB — `Maker::AddonState#data` is a `json` column, and every reader in the app already goes there. The file is write-only. So this is a removal from three `LibraryOutput.write` calls, plus one shared controller + one shared partial (because `Maker::AddonState` is addon-agnostic, so the replacement is too), plus a `def up`-only migration that drops the join rows for files already written. Files already on disk are left alone.

**Tech Stack:** Rails 8.1, Minitest integration tests, SQLite (dev/test) + Postgres (managed), ERB + plain CSS. No new dependencies.

**Spec:** [`docs/superpowers/specs/2026-07-29-addon-params-db-not-file-design.md`](../specs/2026-07-29-addon-params-db-not-file-design.md)

---

## File Structure

**Create:**
| Path | Responsibility |
|---|---|
| `app/controllers/tools/addon_params_controller.rb` | One action: serve any addon state's `data` as a JSON download. Addon-agnostic, `current_user`-scoped. |
| `app/views/tools/shared/_params.html.erb` | The params list + download link. One local (`state`). Rendered by all three addons' show pages. |
| `test/controllers/tools/addon_params_controller_test.rb` | Covers the new endpoint: content, disposition, filename, cross-user 404, auth. |
| `db/migrate/20260730010000_delete_addon_parameters_file_rows.rb` | `DELETE FROM maker_addon_files WHERE role = 'parameters'`. Data-only. |

**Modify:**
| Path | Change |
|---|---|
| `config/routes.rb` | One route for the new controller, at top level (near the hand-written `tools/openscad` routes). |
| `app/controllers/tools/boxes_controller.rb:70-79` | Drop the second `files:` entry. Drop the now-unused `require "json"`. |
| `app/controllers/tools/generators_controller.rb:30-38` | Same. |
| `app/controllers/tools/openscad_controller.rb:65-73` | Same. |
| `app/views/tools/boxes/show.html.erb` | Render the shared partial. |
| `app/views/tools/generators/show.html.erb` | Render the shared partial. |
| `app/views/tools/openscad/show.html.erb` | Render the shared partial. |
| `app/assets/stylesheets/application.css` | One rule: `.addon-params dd { white-space: pre-wrap; }`. |
| `app/models/maker/addon_file.rb:2-3` | The `role` comment still says `"output" \| "parameters"`. |
| `test/controllers/tools/boxes_controller_test.rb` | 2 tests inverted, 1 added. |
| `test/controllers/tools/generators_controller_test.rb` | 4 tests inverted, 2 added. |
| `test/controllers/tools/openscad_controller_test.rb` | 2 tests inverted, 1 added. |
| `CLAUDE.md:71` (Addons row) | Note the removal + the one shared replacement surface. |
| `docs/STATUS.md` | New "## Latest" entry at the top. |

**Deliberately NOT touched:**
- `app/services/maker/addons/library_output.rb` — role-agnostic by design; it has no idea what "parameters" meant.
- `db/migrate/20260720235428_create_maker_addon_files.rb` — its `"output" | "parameters" | ...` comment stays. A migration records what was true when it ran.
- `test/services/maker/addons/library_output_test.rb:25`, `test/models/maker/addon_state_test.rb:11` — they use `role: "parameters"` as generic fixture data to prove the helper and the model take *any* role. Still true, still worth proving.

---

## Task 1: The shared params download endpoint

**Files:**
- Create: `app/controllers/tools/addon_params_controller.rb`
- Create: `test/controllers/tools/addon_params_controller_test.rb`
- Modify: `config/routes.rb` (after the `tools/openscad` routes, before the `unless Rails.env.production?` dev-blobs block)

- [ ] **Step 1: Write the failing test**

Create `test/controllers/tools/addon_params_controller_test.rb`:

```ruby
require "test_helper"

module Tools
  # The params behind any addon state, as a download. This replaces the `.params.json` file that
  # every addon used to write into the library beside its output (removed 2026-07-29: nothing ever
  # read it back, and `Maker::AddonState#data` is the record).
  class AddonParamsControllerTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "addonparams@example.com", password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      @state = @user.maker_addon_states.create!(
        addon_key: "boxes", name: "My Box",
        data: { "generator" => "ABox", "params" => { "x" => "120", "y" => "60" } }
      )
    end

    test "serves the whole data hash as pretty JSON, dispositioned as a download" do
      get tools_addon_params_path(@state)
      assert_response :success
      assert_equal "application/json", response.media_type
      assert_equal JSON.pretty_generate(@state.data), response.body
      assert_match(/\A\{\n/, response.body, "must be pretty-printed, not compact")
      assert_match "attachment", response.headers["Content-Disposition"]
      assert_match "my-box-#{@state.id}.params.json", response.headers["Content-Disposition"]
    end

    test "the download carries the generator, not only the params" do
      # `generator` is what made the removed file self-describing — with it you can tell what
      # produced the output sitting next to it. Params alone are an anonymous bag of numbers.
      get tools_addon_params_path(@state)
      body = JSON.parse(response.body)
      assert_equal "ABox", body["generator"]
      assert_equal({ "x" => "120", "y" => "60" }, body["params"])
    end

    test "another user's state is a 404, not a 403 and not a leak" do
      other = User.create!(email: "addonparams-other@example.com", password: PASSWORD, confirmed_at: Time.current)
      theirs = other.maker_addon_states.create!(addon_key: "boxes", name: "Theirs",
                                                data: { "generator" => "ABox", "params" => {} })
      get tools_addon_params_path(theirs)
      assert_response :not_found
    end

    test "requires login" do
      reset!
      get tools_addon_params_path(@state)
      assert_redirected_to new_user_session_path
    end

    test "a name that parameterizes to nothing falls back to the addon key" do
      # `"🎁".parameterize` is "" — the naive filename would be "-12.params.json".
      state = @user.maker_addon_states.create!(addon_key: "boxes", name: "🎁", data: {})
      get tools_addon_params_path(state)
      assert_response :success
      assert_match "boxes-#{state.id}.params.json", response.headers["Content-Disposition"]
    end

    test "serves any addon's state, not just boxes" do
      state = @user.maker_addon_states.create!(
        addon_key: "openscad", name: "Hex Plate",
        data: { "generator" => "hex_plate", "node_id" => "n-1", "params" => { "cols" => 6 } }
      )
      get tools_addon_params_path(state)
      assert_response :success
      assert_equal 6, JSON.parse(response.body)["params"]["cols"], "the coerced Integer must survive"
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bin/rails test test/controllers/tools/addon_params_controller_test.rb
```

Expected: every test errors with `NameError: undefined local variable or method 'tools_addon_params_path'` (the route does not exist yet).

- [ ] **Step 3: Add the route**

In `config/routes.rb`, immediately after the last `tools/openscad` route (`get "tools/openscad/:id", to: "tools/openscad#show", as: :tools_openscad_design`) and before the `# DEV/TEST ONLY chunk-bytes endpoint` comment, insert:

```ruby
# The params behind ANY addon state, as a download. ONE route for every addon: `Maker::AddonState`
# is addon-agnostic (`data` IS each addon's own shape), so there is nothing per-addon to branch on.
# Declared at top level rather than inside `namespace :tools` for the same reason the openscad
# routes above are — `as:` here is the whole helper name, so this reads like its siblings.
get "tools/addon_states/:id/params", to: "tools/addon_params#show", as: :tools_addon_params
```

- [ ] **Step 4: Write the controller**

Create `app/controllers/tools/addon_params_controller.rb`:

```ruby
require "json"

module Tools
  # The params behind any addon state, as the download the `.params.json` library file used to be.
  # That file was removed 2026-07-29: nothing ever read it back, and `Maker::AddonState#data` is the
  # record. Addon-agnostic on purpose — `data` IS each addon's own shape, so there is nothing here to
  # branch on, and one endpoint serves boxes, generators and openscad alike.
  #
  # Serves the WHOLE `data` hash, which is byte-identical to the file that was removed (all three
  # addons wrote `JSON.pretty_generate` of the whole hash). `generator` is what made it
  # self-describing; the show pages' list shows only `params` because they already print the
  # generator above it.
  class AddonParamsController < BaseController
    def show
      state = current_user.maker_addon_states.find(params[:id])
      send_data JSON.pretty_generate(state.data),
                type: "application/json", disposition: "attachment", filename: filename_for(state)
    end

    private

    # `current_user.maker_addon_states.find` (above) is the tenant scope: another user's id raises
    # RecordNotFound -> 404, by construction rather than by a check someone can forget.

    # Matches what the removed file was called. `name.parameterize` can come back BLANK (a name of
    # only emoji or punctuation), which would emit "-12.params.json" — hence the addon-key fallback.
    # The per-addon fallbacks in the create actions (box/drawing/model) are not reproduced: this is a
    # download hint, not a library name.
    def filename_for(state)
      "#{state.name.parameterize.presence || state.addon_key}-#{state.id}.params.json"
    end
  end
end
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
bin/rails test test/controllers/tools/addon_params_controller_test.rb
```

Expected: `6 runs, ... 0 failures, 0 errors, 0 skips`.

- [ ] **Step 6: Commit**

```bash
git add app/controllers/tools/addon_params_controller.rb test/controllers/tools/addon_params_controller_test.rb config/routes.rb
git commit -m "feat(addons): one shared params download for every addon state"
```

---

## Task 2: The shared params partial, on all three show pages

**Files:**
- Create: `app/views/tools/shared/_params.html.erb`
- Modify: `app/views/tools/boxes/show.html.erb`, `app/views/tools/generators/show.html.erb`, `app/views/tools/openscad/show.html.erb`
- Modify: `app/assets/stylesheets/application.css`
- Test: `test/controllers/tools/boxes_controller_test.rb`, `test/controllers/tools/generators_controller_test.rb`, `test/controllers/tools/openscad_controller_test.rb`

**Note on what the tests can and cannot prove:** `white-space: pre-wrap` is CSS — the newline sits in the HTML either way, so no integration test can verify the *rendering*. The test below asserts the other half: that the view never squishes or truncates a multiline value out of the markup. Do not write a test that pretends to check the CSS.

- [ ] **Step 1: Write the failing tests**

In `test/controllers/tools/boxes_controller_test.rb`, add after the existing `test "show reopens a saved box with its params" do ... end` block (around line 207):

```ruby
    test "show lists the params and offers the JSON download (they are not a file any more)" do
      state = @user.maker_addon_states.create!(
        addon_key: "boxes", name: "Multi Tray",
        # A MULTILINE value: boxes' TrayLayout/FrontPanel/NightLightBox section params are
        # newline-separated, and they are why the value cell must not collapse whitespace.
        data: { "generator" => "ABox", "params" => { "x" => "120", "sx" => "50 60\n70 80" } }
      )
      get tools_box_path(state)
      assert_response :success
      assert_select "section.addon-params dl.meta dt", text: "x"
      assert_select "section.addon-params dl.meta dd", text: "120"
      assert_select "section.addon-params a[href=?]", tools_addon_params_path(state)
      # The newline must survive into the markup. The `white-space: pre-wrap` that makes it RENDER as
      # two lines is CSS and cannot be asserted here; this guards the half that can be — that the
      # view never squishes or truncates the value.
      assert_includes response.body, "50 60\n70 80"
    end
```

In `test/controllers/tools/generators_controller_test.rb`, add after `test "show does not expose another user's grid (scoped find → 404)" do ... end` (around line 181):

```ruby
    test "show lists the params and offers the JSON download" do
      state = @user.maker_addon_states.create!(
        addon_key: "generators", name: "Grid P",
        data: { "generator" => "material-test-grid", "params" => { "cols" => "4" } }
      )
      get tools_generator_path(state)
      assert_response :success
      assert_select "section.addon-params dl.meta dt", text: "cols"
      assert_select "section.addon-params dl.meta dd", text: "4"
      assert_select "section.addon-params a[href=?]", tools_addon_params_path(state)
    end

    test "show says so when a state has no params at all" do
      state = @user.maker_addon_states.create!(addon_key: "generators", name: "Bare",
                                               data: { "generator" => "material-test-grid" })
      get tools_generator_path(state)
      assert_response :success
      assert_select "section.addon-params", text: /No parameters/
      # The download stays offered either way — `data` still carries the generator.
      assert_select "section.addon-params a[href=?]", tools_addon_params_path(state)
    end
```

In `test/controllers/tools/openscad_controller_test.rb`, add after `test "show reopens a saved design and its duplicate link actually prefills the editor" do ... end` (find its `end` and insert after it):

```ruby
    test "show lists the params and offers the JSON download" do
      # POSTed rather than hand-built: `show` resolves the source through `openscad_source_key`, and
      # a real save is the honest way to get a state that helper can read.
      post tools_openscad_path, params: { name: "OS Params", generator: "hex_plate",
                                          params: { cols: "6", wall: "2.5" } }
      state = @user.maker_addon_states.for_addon("openscad").order(:id).last
      get tools_openscad_design_path(state)
      assert_response :success
      assert_select "section.addon-params dl.meta dt", text: "cols"
      assert_select "section.addon-params dl.meta dd", text: "6"
      assert_select "section.addon-params a[href=?]", tools_addon_params_path(state)
    end
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bin/rails test test/controllers/tools/boxes_controller_test.rb -n "/lists the params/" test/controllers/tools/generators_controller_test.rb test/controllers/tools/openscad_controller_test.rb -n "/lists the params|no params at all/"
```

Simpler, run each file and read the new failures:

```bash
bin/rails test test/controllers/tools/boxes_controller_test.rb -n "/lists the params/"
```

Expected: FAIL — `Expected exactly 0 elements matching "section.addon-params dl.meta dt", found 0..` i.e. the assertion on `dt` fails because the section does not exist.

- [ ] **Step 3: Create the shared partial**

Create `app/views/tools/shared/_params.html.erb`:

```erb
<%# The params behind this state, straight from the DB. They used to ALSO be written into the
    library as a `.params.json` file; that file was write-only (nothing read it back) and is gone —
    `Maker::AddonState#data` is the record. `state` is the only local, because `Maker::AddonState` is
    addon-agnostic and so is this: boxes, generators and openscad all render it unchanged.

    VALUES CAN BE MULTILINE — boxes' TrayLayout/FrontPanel/NightLightBox section params are
    newline-separated — so `.addon-params dd` carries `white-space: pre-wrap`. A collapsing cell
    renders those as one mangled line. %>
<section class="addon-params">
  <h2>Parameters</h2>

  <% values = state.data["params"] || {} %>
  <% if values.empty? %>
    <p class="muted">No parameters.</p>
  <% else %>
    <dl class="meta">
      <% values.each do |key, value| %>
        <dt><%= key %></dt>
        <dd class="mono"><%= value.to_s.presence || "—" %></dd>
      <% end %>
    </dl>
  <% end %>

  <%# The download serves the WHOLE `data` hash — byte-identical to the removed file. The list above
      shows only `params`, because every show page already prints the generator above it. %>
  <%= link_to "Download params.json", tools_addon_params_path(state), class: "btn ghost" %>
</section>
```

- [ ] **Step 4: Render it from the three show pages**

`app/views/tools/boxes/show.html.erb` — insert between the bundle `</ul>` and the "Duplicate & tweak" link:

```erb
<%= render "tools/shared/params", state: @state %>

<%= link_to "Duplicate & tweak",
```

`app/views/tools/openscad/show.html.erb` — same position, between the bundle `</ul>` and the "Duplicate & tweak" link:

```erb
<%= render "tools/shared/params", state: @state %>

<%= link_to "Duplicate & tweak",
```

`app/views/tools/generators/show.html.erb` — append at the end of the file, after the closing `</section>` of `.generator-bundle`:

```erb
<%= render "tools/shared/params", state: @state %>
```

- [ ] **Step 5: Add the CSS rule**

In `app/assets/stylesheets/application.css`, after the line:

```css
.addon-card[hidden], .box-group[hidden] { display: none; }
```

add:

```css
/* A param value can be MULTILINE (boxes' TrayLayout/FrontPanel section params are newline-separated),
   so the value cell must not collapse it into one line. */
.addon-params dd { white-space: pre-wrap; }
```

- [ ] **Step 6: Run the tests to verify they pass**

```bash
bin/rails test test/controllers/tools/boxes_controller_test.rb test/controllers/tools/generators_controller_test.rb test/controllers/tools/openscad_controller_test.rb
```

Expected: 0 failures, 0 errors. (The `create` tests still assert the two-file bundle at this point — that is correct; the file is still being written until Task 3.)

- [ ] **Step 7: Commit**

```bash
git add app/views/tools/shared/_params.html.erb app/views/tools/boxes/show.html.erb app/views/tools/generators/show.html.erb app/views/tools/openscad/show.html.erb app/assets/stylesheets/application.css test/controllers/tools/boxes_controller_test.rb test/controllers/tools/generators_controller_test.rb test/controllers/tools/openscad_controller_test.rb
git commit -m "feat(addons): show the params on every addon's show page, from the DB"
```

---

## Task 3: Boxes stops writing the params file

**Files:**
- Modify: `test/controllers/tools/boxes_controller_test.rb:145-153` and `:274-288`
- Modify: `app/controllers/tools/boxes_controller.rb:1` and `:70-79`

- [ ] **Step 1: Invert the two tests**

In `test/controllers/tools/boxes_controller_test.rb`, replace the whole test that currently reads:

```ruby
    test "create saves the state + a tied bundle (svg output + params file)" do
      assert_difference("Maker::AddonState.count", 1) do
        post tools_boxes_path, params: { name: "My Box", generator: "ABox", params: { x: 120, y: 60 } }
      end
      state = @user.maker_addon_states.for_addon("boxes").order(:id).last
      assert_equal %w[output parameters], state.files.map(&:role)
      state.files.each { |af| assert @user.nodes.exists?(node_id: af.node_id) }
      assert_redirected_to tools_box_path(state)
    end
```

with:

```ruby
    test "create saves the state + a tied bundle of ONE file — the params live in the DB" do
      assert_difference("Maker::AddonState.count", 1) do
        post tools_boxes_path, params: { name: "My Box", generator: "ABox", params: { x: 120, y: 60 } }
      end
      state = @user.maker_addon_states.for_addon("boxes").order(:id).last
      assert_equal %w[output], state.files.map(&:role)
      state.files.each { |af| assert @user.nodes.exists?(node_id: af.node_id) }

      # Asserted at the LIBRARY level, not just on the join rows: the FILE is what was removed, and a
      # `.params.json` written as an untied node would still pass the roles check above.
      assert_empty @user.nodes.present.where("name LIKE ?", "%.params.json"),
                   "no .params.json may be written into the library"

      # …and the params really are recorded, in the DB.
      assert_equal({ "generator" => "ABox", "params" => { "x" => "120", "y" => "60" } }, state.data)
      assert_redirected_to tools_box_path(state)
    end
```

Then replace the whole test that currently reads `test "create attaches both output files to the current project" do` … `end` with:

```ruby
    test "create attaches the output file to the current project" do
      project = @user.maker_projects.create!(name: "Desk Lamp")
      folder = project.ensure_library_folder!(@user)
      patch current_project_path, params: { project_id: project.id }
      assert_difference "project.file_attachments.count", 1 do
        post tools_boxes_path, params: { name: "Cur Box", generator: "ABox", params: { x: 1, y: 2 },
                                         parent_node_id: folder.node_id }
      end
      # the attached node lives under the project folder
      project.file_attachments.each do |att|
        assert_equal folder.node_id, @user.nodes.find_by(node_id: att.node_id).parent_node_id
      end
      state = @user.maker_addon_states.for_addon("boxes").order(:id).last
      assert_equal state.files.map(&:node_id).sort, project.file_attachments.pluck(:node_id).sort,
                   "the one output file (svg) must be the attached node"
    end
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bin/rails test test/controllers/tools/boxes_controller_test.rb -n "/tied bundle of ONE file|attaches the output file/"
```

Expected: 2 failures — `Expected: ["output"] Actual: ["output", "parameters"]`, and `"project.file_attachments.count" didn't change by 1, but by 2`.

- [ ] **Step 3: Drop the file from the controller**

In `app/controllers/tools/boxes_controller.rb`, replace:

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
```

with:

```ruby
      # ONE file. The params are NOT written beside it: `state.data` above is the record, every
      # reader in the app already goes there, and the file was write-only. `Tools::AddonParamsController`
      # serves them as a download for anyone who wants them outside the app.
      addon_files = Maker::Addons::LibraryOutput.write(
        user: current_user, state:, parent_node_id: chosen_parent_node_id,
        files: [
          { name: "#{base}-#{state.id}.svg", bytes: svg,
            content_type: "image/svg+xml", role: "output" }
        ]
      )
```

Then delete line 1 (`require "json"`) — that was its only use in this file. Verify with:

```bash
grep -n 'JSON\.' app/controllers/tools/boxes_controller.rb
```

Expected: no output.

- [ ] **Step 4: Run the boxes suite to verify it passes**

```bash
bin/rails test test/controllers/tools/boxes_controller_test.rb
```

Expected: 0 failures, 0 errors.

- [ ] **Step 5: Commit**

```bash
git add app/controllers/tools/boxes_controller.rb test/controllers/tools/boxes_controller_test.rb
git commit -m "refactor(boxes): the params are in the DB, so stop writing them as a file"
```

---

## Task 4: Generators stops writing the params file

**Files:**
- Modify: `test/controllers/tools/generators_controller_test.rb:82`, `:88-96`, `:98-105`, `:192-208`
- Modify: `app/controllers/tools/generators_controller.rb:1` and `:30-38`

- [ ] **Step 1: Invert the four tests**

In `test/controllers/tools/generators_controller_test.rb`:

**(a)** change the single line

```ruby
      assert_equal %w[output parameters], state.files.map(&:role)
```

to

```ruby
      assert_equal %w[output], state.files.map(&:role) # params live in `data`, not in a second file
```

**(b)** replace the whole test that currently reads:

```ruby
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
```

with:

```ruby
    test "create writes ONLY the svg output node into the library — no params file" do
      post tools_generators_path, params: {
        name: "Bundle", generator: "material-test-grid", params: { cols: 2 }, svg: SVG_FIXTURE
      }
      state = @user.maker_addon_states.for_addon("generators").order(:id).last
      assert_equal [ "image/svg+xml" ], state.files.map(&:content_type)

      # Asserted at the LIBRARY level, not just on the join rows: an untied `.params.json` would
      # still pass a join-row check.
      assert_empty @user.nodes.present.where("name LIKE ?", "%.params.json"),
                   "no .params.json may be written into the library"
      assert_equal({ "cols" => "2" }, state.data["params"], "the params are recorded in the DB")
    end
```

**(c)** replace the whole test that currently reads:

```ruby
    test "create enqueues a preview for each written node" do
      assert_enqueued_jobs 2, only: Maker::GeneratePreviewJob do
```

…with the same test renamed and the count dropped to 1 (keep the rest of the block byte-for-byte):

```ruby
    test "create enqueues a preview for the one written node" do
      assert_enqueued_jobs 1, only: Maker::GeneratePreviewJob do
        post tools_generators_path, params: {
          name: "Preview Me", generator: "material-test-grid", params: { cols: 2 }, svg: SVG_FIXTURE
        }
      end
    end
```

**(d)** replace the whole test that currently reads `test "create attaches both output files to the current project" do` … `end` with:

```ruby
    test "create attaches the output file to the current project" do
      project = @user.maker_projects.create!(name: "Desk Lamp")
      folder = project.ensure_library_folder!(@user)
      patch current_project_path, params: { project_id: project.id }
      assert_difference "project.file_attachments.count", 1 do
        post tools_generators_path, params: {
          name: "Cur Grid", generator: "material-test-grid", params: { cols: 2 },
          svg: SVG_FIXTURE, parent_node_id: folder.node_id
        }
      end
      project.file_attachments.each do |att|
        assert_equal folder.node_id, @user.nodes.find_by(node_id: att.node_id).parent_node_id
      end
      state = @user.maker_addon_states.for_addon("generators").order(:id).last
      assert_equal state.files.map(&:node_id).sort, project.file_attachments.pluck(:node_id).sort,
                   "the one output file (svg) must be the attached node"
    end
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bin/rails test test/controllers/tools/generators_controller_test.rb
```

Expected: 4 failures (wrong roles, a `.params.json` node present, 2 preview jobs instead of 1, attachments changed by 2 instead of 1).

- [ ] **Step 3: Drop the file from the controller**

In `app/controllers/tools/generators_controller.rb`, replace:

```ruby
      addon_files = Maker::Addons::LibraryOutput.write(
        user: current_user, state:, parent_node_id: chosen_parent_node_id,
        files: [
          { name: "#{base}-#{state.id}.svg", bytes:, content_type: "image/svg+xml", role: "output" },
          { name: "#{base}-#{state.id}.params.json",
            bytes: JSON.pretty_generate(state.data), content_type: "application/json", role: "parameters" }
        ]
      )
```

with:

```ruby
      # ONE file. The params are NOT written beside it: `state.data` above is the record, and
      # `Tools::AddonParamsController` serves it as a download.
      addon_files = Maker::Addons::LibraryOutput.write(
        user: current_user, state:, parent_node_id: chosen_parent_node_id,
        files: [
          { name: "#{base}-#{state.id}.svg", bytes:, content_type: "image/svg+xml", role: "output" }
        ]
      )
```

Also update the class comment on line 5-6, which says the controller "writes a `[svg, params.json]` bundle":

```ruby
  # The Generators addon — a client-only Maker.js harness. Generator-AGNOSTIC: it persists a
  # Maker::AddonState and writes an [svg] bundle via LibraryOutput. All generator schema
```

Then delete line 1 (`require "json"`). Verify:

```bash
grep -n 'JSON\.' app/controllers/tools/generators_controller.rb
```

Expected: no output.

- [ ] **Step 4: Run the generators suite to verify it passes**

```bash
bin/rails test test/controllers/tools/generators_controller_test.rb
```

Expected: 0 failures, 0 errors.

- [ ] **Step 5: Commit**

```bash
git add app/controllers/tools/generators_controller.rb test/controllers/tools/generators_controller_test.rb
git commit -m "refactor(generators): the params are in the DB, so stop writing them as a file"
```

---

## Task 5: OpenSCAD stops writing the params file

**Files:**
- Modify: `test/controllers/tools/openscad_controller_test.rb:272-312` and `:352-363`
- Modify: `app/controllers/tools/openscad_controller.rb:1`, `:56-62` (comment), `:65-73`

**Careful — this one test carries coverage nothing else has.** Its params-file read is the only assertion that `OpenscadParams` coercion round-trips (a form String becoming Integer `6` / Float `2.5`). That assertion **moves to `state.data`**; it is not deleted.

- [ ] **Step 1: Invert the two tests**

In `test/controllers/tools/openscad_controller_test.rb`, replace the comment block + test that currently begins:

```ruby
    # THE TEST SPEC §11 SINGLES OUT, and the one CLAUDE.md's Phase 4 lesson says is easiest to fake:
    # it asserts two AddonFiles with the right roles, REAL nodes in the library, and the BYTES read
```

…through the end of that test (`assert_redirected_to tools_openscad_design_path(state)` + `end`), with:

```ruby
    # THE TEST SPEC §11 SINGLES OUT, and the one CLAUDE.md's Phase 4 lesson says is easiest to fake:
    # it asserts the ONE AddonFile with its role, a REAL node in the library, and the BYTES read
    # back through FileLayer and confirmed to be a zip/OPC container — not merely that the
    # controller redirected. Reading through FileLayer is also what makes it meaningful on share and
    # s3 rather than only on chunk.
    test "create writes a real 3mf into the library, and the params stay in the DB" do
      assert_difference("Maker::AddonState.count", 1) do
        post tools_openscad_path, params: { name: "OS Bundle", generator: "hex_plate",
                                            params: { cols: "6", wall: "2.5" } }
      end
      state = @user.maker_addon_states.for_addon("openscad").order(:id).last

      assert_equal %w[output], state.files.map(&:role)
      assert_equal [ "model/3mf" ], state.files.map(&:content_type)

      # A real library node, not just a join row.
      state.files.each { |af| assert @user.nodes.exists?(node_id: af.node_id), "no node for #{af.role}" }

      out = state.files.find { |f| f.role == "output" }
      assert @user.nodes.find_by(node_id: out.node_id).name.end_with?(".3mf")

      bytes = FileLayer.current.read(@user, node_id: out.node_id)
      assert_equal "PK", bytes[0, 2], "output is not a zip/OPC container"
      assert_equal FakeOpenscad.minimal_3mf.bytesize, bytes.bytesize,
                   "the bytes that landed are not the ones the sidecar rendered"
      entries = nil
      Zip::File.open_buffer(bytes.b) { |z| entries = z.map(&:name) }
      assert_includes entries, "3D/3dmodel.model", "not a 3MF: no OPC model part inside the zip"

      # NO params file. Asserted at the library level, not just on the join rows.
      assert_empty @user.nodes.present.where("name LIKE ?", "%.params.json"),
                   "no .params.json may be written into the library"

      # The DB records what was rendered — COERCED, so the design reproduces exactly. This assertion
      # used to read the params FILE; it MOVED to `data` rather than being deleted, because the
      # coercion it pins (a form String becoming an Integer/Float) is the reason OpenscadParams
      # exists, and `data` is now the only place it is recorded.
      assert_equal "hex_plate", state.data["generator"]
      assert_equal 6, state.data["params"]["cols"], "cols should be the coerced Integer, not the string"
      assert_equal 2.5, state.data["params"]["wall"]

      assert_redirected_to tools_openscad_design_path(state)
    end
```

Then replace the whole test that currently reads `test "create attaches BOTH bundle files to the current project" do` … `end` with:

```ruby
    test "create attaches the output file to the current project" do
      project = @user.maker_projects.create!(name: "OpenSCAD Lamp")
      folder = project.ensure_library_folder!(@user)
      patch current_project_path, params: { project_id: project.id }
      assert_difference "project.file_attachments.count", 1 do
        post tools_openscad_path, params: { name: "OS Attached", generator: "hex_plate",
                                            params: { cols: "4" }, parent_node_id: folder.node_id }
      end
      state = @user.maker_addon_states.for_addon("openscad").order(:id).last
      assert_equal state.files.map(&:node_id).sort, project.file_attachments.pluck(:node_id).sort,
                   "the one bundle file (3mf) must be the attached node"
    end
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bin/rails test test/controllers/tools/openscad_controller_test.rb -n "/real 3mf into the library|attaches the output file/"
```

Expected: 2 failures — `Expected: ["output"] Actual: ["output", "parameters"]`, and attachments changed by 2 instead of 1.

- [ ] **Step 3: Drop the file from the controller**

In `app/controllers/tools/openscad_controller.rb`, replace:

```ruby
      addon_files = Maker::Addons::LibraryOutput.write(
        user: current_user, state:, parent_node_id: chosen_parent_node_id,
        files: [
          { name: "#{base}-#{state.id}.3mf", bytes:, content_type: "model/3mf", role: "output" },
          { name: "#{base}-#{state.id}.params.json",
            bytes: JSON.pretty_generate(state.data), content_type: "application/json",
            role: "parameters" }
        ]
      )
```

with:

```ruby
      # ONE file. The params are NOT written beside it: `state.data` above is the record, and
      # `Tools::AddonParamsController` serves it as a download.
      addon_files = Maker::Addons::LibraryOutput.write(
        user: current_user, state:, parent_node_id: chosen_parent_node_id,
        files: [
          { name: "#{base}-#{state.id}.3mf", bytes:, content_type: "model/3mf", role: "output" }
        ]
      )
```

Then fix the `data:` comment just above it, which currently ends by crediting the removed file:

```ruby
        # Record WHICH source produced this so `show` and "duplicate & tweak" can reopen it. We do
        # NOT store the .scad itself (spec §6.1): for a bring-your-own file that would copy a
        # possibly restrictively-licensed design around the user's library and into any future
        # share/export path. `data` records what was rendered; the source stays where the user
        # put it.
```

Then delete line 1 (`require "json"`). Verify:

```bash
grep -n 'JSON\.' app/controllers/tools/openscad_controller.rb
```

Expected: no output.

- [ ] **Step 4: Run the openscad suite to verify it passes**

```bash
bin/rails test test/controllers/tools/openscad_controller_test.rb
```

Expected: 0 failures, 0 errors.

- [ ] **Step 5: Commit**

```bash
git add app/controllers/tools/openscad_controller.rb test/controllers/tools/openscad_controller_test.rb
git commit -m "refactor(openscad): the params are in the DB, so stop writing them as a file"
```

---

## Task 6: Drop the join rows for files already written

**Files:**
- Create: `db/migrate/20260730010000_delete_addon_parameters_file_rows.rb`
- Modify: `db/schema.rb` (version line only, regenerated by `db:migrate`)

The timestamp **must** be greater than the current max (`20260730001500`, per `db/schema.rb`'s `version:`), or `db:migrate` will not bump the schema version.

- [ ] **Step 1: Write the migration**

Create `db/migrate/20260730010000_delete_addon_parameters_file_rows.rb`:

```ruby
# The `.params.json` file is no longer part of an addon bundle: `Maker::AddonState#data` is the
# record, nothing ever read the file back, and `Tools::AddonParamsController` serves it as a download
# for anyone who wants it outside the app. This drops the JOIN ROWS for the files already written, so
# the show pages stop listing a file the addon no longer produces.
#
# THE FILES THEMSELVES ARE LEFT ALONE, deliberately. They are ordinary library files the user may
# have renamed, organized, or attached to a project, and a migration must not delete user bytes.
# What survives, all of it intended:
#   - a params file attached to a project keeps its `Maker::FileAttachment` (a separate record), so it
#     stays visible in the project panel — it just stops being part of the addon BUNDLE;
#   - its `Maker::Preview` rows stay valid, because the node still exists (the preview reaper only
#     reaps previews whose node is gone);
#   - the file name embeds the state id, so it is still traceable by hand.
#
# Raw SQL, not `Maker::AddonFile.where(...).delete_all`: a migration is history and must not depend on
# a model that may later change or disappear. Valid on both SQLite and Postgres (§15: adapter-agnostic).
class DeleteAddonParametersFileRows < ActiveRecord::Migration[8.1]
  def up
    execute "DELETE FROM maker_addon_files WHERE role = 'parameters'"
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
```

- [ ] **Step 2: Confirm the migration is pending and seed a row to prove it works**

```bash
bin/rails db:prepare && bin/rails db:migrate:status | tail -3
```

Expected: the last line is `  down    20260730010000  Delete addon parameters file rows`.

Seed one `parameters` row and one `output` row in the development DB, so the next step proves the DELETE is targeted rather than indiscriminate:

```bash
bin/rails runner 'u = User.create!(email: "mig-check-#{SecureRandom.hex(4)}@example.com"); s = u.maker_addon_states.create!(addon_key: "boxes", name: "Mig Check", data: {}); s.files.create!(node_id: "mig-out", role: "output", content_type: "image/svg+xml", position: 0); s.files.create!(node_id: "mig-par", role: "parameters", content_type: "application/json", position: 1); puts "state=#{s.id} params=#{Maker::AddonFile.where(role: %q(parameters)).count} output=#{Maker::AddonFile.where(role: %q(output)).count}"'
```

Expected: `state=<id> params=1 output=1` (counts may be higher if the dev DB already had addon saves — note the numbers).

- [ ] **Step 3: Run the migration and verify it deleted exactly the parameters rows**

```bash
bin/rails db:migrate && bin/rails runner 'puts "params=#{Maker::AddonFile.where(role: %q(parameters)).count} output=#{Maker::AddonFile.where(role: %q(output)).count}"'
```

Expected: `params=0 output=1` (or the same `output` count you noted in Step 2 — unchanged).

- [ ] **Step 4: Verify `down` refuses, and that schema.rb moved only its version line**

```bash
bin/rails db:rollback 2>&1 | tail -3; git diff db/schema.rb
```

Expected: an `ActiveRecord::IrreversibleMigration` error, and the only `db/schema.rb` change is `version: 2026_07_30_001500` → `version: 2026_07_30_010000`.

Clean up the seeded dev row:

```bash
bin/rails runner 'Maker::AddonState.where(name: "Mig Check").destroy_all; User.where("email LIKE ?", "mig-check-%").destroy_all; puts "cleaned"'
```

- [ ] **Step 5: Commit**

```bash
git add db/migrate/20260730010000_delete_addon_parameters_file_rows.rb db/schema.rb
git commit -m "chore(addons): drop the join rows for params files already written"
```

---

## Task 7: The comments and docs that still claim a params file

**Files:**
- Modify: `app/models/maker/addon_file.rb:2-3`
- Modify: `CLAUDE.md:71` (the Addons row)
- Modify: `docs/STATUS.md` (top: the `**Updated:**` line + a new `## Latest` section)

- [ ] **Step 1: Fix the `AddonFile` role comment**

In `app/models/maker/addon_file.rb`, replace:

```ruby
  # The tie between an AddonState and one library node it produced, carrying the file's `role`
  # (e.g. "output" | "parameters") so the addon and UI know what each file in the bundle is.
```

with:

```ruby
  # The tie between an AddonState and one library node it produced, carrying the file's `role`
  # (currently only "output") so the addon and UI know what each file in the bundle is. `role` earns
  # its place the moment an addon emits a second FORMAT; it is not for metadata — the "parameters"
  # role was removed 2026-07-29 because `AddonState#data` already records the params and nothing ever
  # read the file back.
```

- [ ] **Step 2: Update the CLAUDE.md Addons row**

In `CLAUDE.md`, in the `| **Addons (Tools)** |` row, immediately after the sentence ending `…a single-chunk `Sync::Commit` on chunk.`, insert:

```
**Each save writes ONE file — its output.** The `.params.json` that used to sit beside it is gone (2026-07-29): `Maker::AddonState#data` already recorded the params, every reader in the app already went there, and the file was **write-only**. Its one real job — params readable and portable outside the app — is now `Tools::AddonParamsController` (**one** route for all three addons, because `AddonState` is addon-agnostic) plus `tools/shared/_params`. **The download serves the whole `data` hash, not `data["params"]`**, which is byte-identical to the removed file: `generator` is what made it self-describing. Files already written were **left in place** (ordinary library files a user may have renamed or attached to a project — a migration must not delete user bytes); only their `AddonFile` join rows were dropped.
```

- [ ] **Step 3: Add the STATUS.md entry**

In `docs/STATUS.md`, change line 3 to:

```markdown
**Updated:** 2026-07-29 (**Addon params live in the DB, not in a library file — branch `claude/boxes-sidecar-params-db-1c508f`**)
```

…and insert a new section immediately before the existing `## Latest (2026-07-29): saving a file removed its preview…` heading (change that heading's `## Latest` to `## Earlier`, matching the file's existing convention):

```markdown
## Latest (2026-07-29): addon params live in the DB, not in a library file (branch `claude/boxes-sidecar-params-db-1c508f`)

**Suite 1633 → 1642 runs / 0 failures / 0 errors — identical on chunk, share and s3.**

**The request was "store the boxes params in the DB instead of a separate file", and the params were
already in the DB.** `Maker::AddonState#data` is a `json` column holding `{ generator:, params: }`,
and every reader in the app already went there: the show pages' Generator/Source line, "Duplicate &
tweak", and the prior rail on boxes' `new`. **Nothing read the file.** It was write-only. So the work
was a removal plus a replacement for the one job the file did.

**All three addons, not just boxes** — the three `LibraryOutput.write` calls were identical, and
fixing one would have left three addons with different bundle shapes for no stated reason.

**The replacement is ONE surface, because `AddonState` is addon-agnostic and so is the replacement:**
`Tools::AddonParamsController#show` (one route, top-level to sidestep the two documented openscad
inflector traps) serves `JSON.pretty_generate(state.data)` as a download, and
`app/views/tools/shared/_params.html.erb` lists the params on all three show pages.

**The download serves the WHOLE `data` hash, while the list shows only `data["params"]`.** Deliberate
asymmetry: the download is byte-identical to the removed file, and `generator` is what made that file
self-describing — without it the download is an anonymous bag of numbers. In the *display* it is
redundant, since every show page prints it above the list.

**Param values can be MULTILINE** (boxes' TrayLayout/FrontPanel/NightLightBox section params are
newline-separated), so `.addon-params dd` carries `white-space: pre-wrap`. Worth knowing what the
tests can prove: the newline sits in the HTML either way, so **no integration test can verify that
CSS** — the test asserts the half that can be, that the view never squishes or truncates the value.

**Files already written were LEFT IN PLACE; only their `AddonFile` join rows were dropped**
(`20260730010000`, `def up` only, raw SQL so a migration does not depend on a model). They are
ordinary library files a user may have renamed, organized, or attached to a project. Three things
survive on purpose: a project attachment (a separate `Maker::FileAttachment` record) keeps the file
visible in the project panel; its `Maker::Preview` rows stay valid because the node still exists; and
the file name embeds the state id, so it is traceable by hand.

**One test's coverage MOVED rather than being deleted.** `openscad_controller_test`'s bundle test read
the params *file* back to assert `OpenscadParams` coercion round-trips (a form String becoming Integer
`6` / Float `2.5`). That is the reason `OpenscadParams` exists, and `data` is now the only place it is
recorded — so the assertion moved to `state.data`. Deleting it with the file it happened to live in
would have dropped the only proof of coercion in the suite.
```

- [ ] **Step 4: Verify the docs claims still hold**

```bash
grep -rn '"parameters"' app lib | grep -v ':[0-9]*: *#'
```

Expected: no output — no code references the role any more (the surviving mentions are comments and the two generic test fixtures).

```bash
grep -rn 'params\.json' app/controllers app/views | grep -v ':[0-9]*: *#'
```

Expected: only `app/controllers/tools/addon_params_controller.rb` (the download filename) and `app/views/tools/shared/_params.html.erb` (the link label).

- [ ] **Step 5: Commit**

```bash
git add app/models/maker/addon_file.rb CLAUDE.md docs/STATUS.md
git commit -m "docs(addons): the params are the DB's job; the file is gone"
```

---

## Task 8: Verify on all three backends

CI cannot run (no linux runner is registered — `CLAUDE.md` §15), so all three legs are verified locally. `LibraryOutput` takes a different door per backend, and the `create` tests exercise it, so a green chunk leg proves nothing about share or s3.

- [ ] **Step 1: The default (chunk) leg**

```bash
bin/rails test
```

Expected: `0 failures, 0 errors`. Record the run/assertion counts.

- [ ] **Step 2: The share leg**

```bash
LIBRARY_BACKEND=share bin/rails test
```

Expected: the same run count, `0 failures, 0 errors`.

- [ ] **Step 3: The s3 leg**

```bash
LIBRARY_BACKEND=s3 bin/rails test
```

Expected: the same run count, `0 failures, 0 errors`.

- [ ] **Step 4: Lint the touched files**

```bash
bundle exec rubocop app/controllers/tools app/models/maker/addon_file.rb db/migrate/20260730010000_delete_addon_parameters_file_rows.rb test/controllers/tools
```

Expected: `no offenses detected`.

- [ ] **Step 5: Correct the STATUS.md counts if they differ**

Task 7 wrote `1633 → 1642` as the expected suite growth (+6 endpoint tests, +4 show-page tests, −1 test folded into another). If the real numbers differ, fix the line — a count nobody re-checked is exactly the kind of stale claim `docs/STATUS.md` warns about.

```bash
git add docs/STATUS.md && git commit -m "docs(status): the real suite counts"
```

(Skip the commit if the numbers were already right.)

---

## Self-Review

**Spec coverage:**
| Spec section | Task |
|---|---|
| §3 The removal (3 controllers) | Tasks 3, 4, 5 |
| §4.1 `Tools::AddonParamsController` + route | Task 1 |
| §4.2 shared partial + multiline CSS | Task 2 |
| §4.3 the display/download asymmetry | Task 1 (test), Task 2 (partial comment), Task 7 (STATUS) |
| §5 existing rows migration | Task 6 |
| §6 tests (new endpoint, inverted create tests, show pages, all three legs) | Tasks 1, 2, 3, 4, 5, 8 |
| §7 docs (`AddonFile` comment, CLAUDE.md, STATUS.md; migration comment left alone) | Task 7 |
| §8 out of scope | Nothing does it |

**Placeholder scan:** none — every code step carries the actual code, every command its expected output.

**Type/name consistency:** `tools_addon_params_path` (route helper), `Tools::AddonParamsController#show`, `filename_for`, partial `"tools/shared/params"` with local `state:`, CSS `.addon-params dd`, migration class `DeleteAddonParametersFileRows` / file `20260730010000_delete_addon_parameters_file_rows.rb` — consistent everywhere they appear.

**One gap found and closed while reviewing:** the spec's test section did not mention
`generators_controller_test`'s `assert_enqueued_jobs 2` (preview-per-file) or `openscad_controller_test`'s
coercion assertion living inside the params-file read. Both are now explicit — Task 4 step 1(c) and
Task 5's "Careful" note.
