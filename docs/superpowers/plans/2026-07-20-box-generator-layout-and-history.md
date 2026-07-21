# Box Generator — layout fix + per-generator history — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the Box Generator addon a real two-column editor, a grouped + searchable generator picker, and a per-generator "made with this" rail that reloads a prior box's parameters.

**Architecture:** Pure addon-UI change. Three seams: (1) the picker view groups `client.generators` by their `group` field and a client-side Stimulus filter narrows them; (2) CSS + markup turn the unstyled editor into a two-column form/preview grid; (3) the `new` action loads this generator's saved boxes and renders a rail whose thumbnails reuse the existing `/files/thumbnails` endpoint + `thumbs` controller, and whose "Load" links reuse the existing `new?generator=…&params=…` prefill path. No new endpoints, no sync/file-layer/sidecar changes.

**Tech Stack:** Rails 8 ERB views, Stimulus (importmap, eager-loaded controllers), plain CSS in `app/assets/stylesheets/application.css`, Minitest integration tests with the `FakeBoxes` stub.

---

## Background the engineer needs

- **The addon controller** is `app/controllers/tools/boxes_controller.rb`. `index` assigns `@generators = client.generators` (an `Array<BoxesClient::Generator>`, each a `Data` with `.key`, `.title`, `.group`, `.params`) and `@saved`. `new` looks up `@generator` by `params[:generator]` and assigns `@values` (optional param prefill). `client` is `BoxesClient.current`; in tests it's the `FakeBoxes` stub.
- **Saved boxes** are `Maker::AddonState` rows (`current_user.maker_addon_states`, scope `for_addon("boxes")`). Each has `.name`, `.data` (a JSON Hash: `{"generator" => key, "params" => {…}}`), `.updated_at`, and `has_many :files` → `Maker::AddonFile` (each has `.node_id`, `.role`; roles written by the save flow are `"output"` (the SVG) and `"parameters"` (the JSON)).
- **Thumbnails already work** via `GET /files/thumbnails` (route helper `thumbnails_files_path`) plus the `thumbs` Stimulus controller (`app/javascript/controllers/thumbs_controller.js`). The controller drives every element with `data-thumbs-target="cell"` inside a `data-controller="thumbs" data-thumbs-url-value="…"` container: for each cell it reads `data-node-id`, POSTs the batch, and swaps the cell's `.thumb > .thumb-spinner` for an `<img>` (or a `.thumb-icon` badge using `data-ext` on `unsupported`/`failed`). The shared `_thumb` partial is `app/views/files/_thumb.html.erb` (locals: `thumb` — a `Maker::Preview` or nil; `ext_label` — String). Rendering it with `thumb: nil` emits the spinner, which the poller then resolves.
- **Stimulus registration is automatic:** `app/javascript/controllers/index.js` calls `eagerLoadControllersFrom("controllers", application)`, and `config/importmap.rb` pins the whole `controllers` dir. A new `*_controller.js` file needs **no** manual registration and **no** importmap edit.
- **CSS variables** (top of `application.css`): `--fg`, `--muted`, `--line`, `--bg`, `--accent`, `--danger`, `--soft`. Reuse these. Existing helpers: `.thumb`/`.thumb-icon`/`.thumb-spinner` (container-sized), `.addon-card` (`display:flex` column), `.tools-grid`, `.preview`/`.preview-image`, `.btn`/`.btn.ghost`, `.page-head`, `.page-actions`, `.muted`.
- **Run one test:** `bin/rails test test/controllers/tools/boxes_controller_test.rb -n "/pattern/"`. **Run the file:** `bin/rails test test/controllers/tools/boxes_controller_test.rb`. Assets are Propshaft (no build); Stimulus/importmap changes need no compile step. CSS/Stimulus behavior is verified by eye + by class/attribute presence in tests — there is no JS/system-test harness here.

## File structure

- **Modify** `test/support/fake_boxes.rb` — add a second generator in a second group so grouping + filtering are testable.
- **Modify** `app/views/tools/boxes/index.html.erb` — group generators, add the search box, restyle the saved list.
- **Create** `app/javascript/controllers/boxfilter_controller.js` — live client-side generator filter.
- **Modify** `app/views/tools/boxes/new.html.erb` — two-column editor; history rail in the right column.
- **Modify** `app/controllers/tools/boxes_controller.rb` — `new` loads `@prior`.
- **Modify** `app/assets/stylesheets/application.css` — one appended "Box Generator addon" block (picker + editor + rail).
- **Modify** `test/controllers/tools/boxes_controller_test.rb` — grouping, editor structure, history-rail, and import-link tests.

---

## Task 1: Grouped, searchable generator picker

**Files:**
- Modify: `test/support/fake_boxes.rb`
- Modify: `test/controllers/tools/boxes_controller_test.rb`
- Create: `app/javascript/controllers/boxfilter_controller.js`
- Modify: `app/views/tools/boxes/index.html.erb`
- Modify: `app/assets/stylesheets/application.css`

- [ ] **Step 1: Give the FakeBoxes stub a second generator in a second group**

The stub currently returns a single generator, so grouping can't be exercised. Add a second one in a different group. This file is used **only** by `test/controllers/tools/boxes_controller_test.rb`, and no existing assertion depends on the generator count — safe to extend.

Replace the `generators` method in `test/support/fake_boxes.rb`:

```ruby
  def generators
    [ BoxesClient::Generator.new(
        key: "ABox", title: "Simple box", group: "Boxes",
        params: [ { "name" => "x", "type" => "float", "default" => 100, "help" => "width (mm)" },
                  { "name" => "y", "type" => "float", "default" => 50, "help" => "depth (mm)" } ]),
      BoxesClient::Generator.new(
        key: "TypeTray", title: "Divider tray", group: "Trays",
        params: [ { "name" => "x", "type" => "float", "default" => 100, "help" => "width (mm)" } ]) ]
  end
```

- [ ] **Step 2: Write the failing grouping test**

Add to `test/controllers/tools/boxes_controller_test.rb` (inside the class):

```ruby
    test "index groups generators under their group headings" do
      get tools_boxes_path
      assert_response :success
      assert_select ".box-group-title", text: "Boxes"
      assert_select ".box-group-title", text: "Trays"
      assert_select ".addon-card[data-boxfilter-target='card']", minimum: 2
      assert_select "input.box-search"
    end
```

- [ ] **Step 3: Run it to verify it fails**

Run: `bin/rails test test/controllers/tools/boxes_controller_test.rb -n "/groups generators/"`
Expected: FAIL (no `.box-group-title`, no `.box-search`, no `data-boxfilter-target` yet).

- [ ] **Step 4: Rewrite the index view with groups + a search box**

Replace the whole of `app/views/tools/boxes/index.html.erb`:

```erb
<% content_for :title, "Box Generator — Tinkerex" %>

<div class="page-head"><h1>📦 Box Generator</h1></div>

<section class="box-generators" data-controller="boxfilter">
  <h2>New box</h2>
  <input type="search" class="box-search" placeholder="Filter generators…"
         aria-label="Filter generators"
         data-boxfilter-target="query" data-action="input->boxfilter#filter">

  <% @generators.group_by(&:group).sort_by { |group, _| group.to_s }.each do |group, gens| %>
    <div class="box-group" data-boxfilter-target="group">
      <h3 class="box-group-title"><%= group.presence || "Other" %></h3>
      <div class="tools-grid">
        <% gens.each do |g| %>
          <%= link_to new_tools_box_path(generator: g.key), class: "addon-card",
                      data: { boxfilter_target: "card",
                              terms: "#{g.title} #{g.key} #{g.group}".downcase } do %>
            <span class="addon-title"><%= g.title %></span>
            <span class="addon-desc muted"><%= g.key %></span>
          <% end %>
        <% end %>
      </div>
    </div>
  <% end %>
</section>

<h2>Saved boxes</h2>
<% if @saved.empty? %>
  <p class="muted">No saved boxes yet.</p>
<% else %>
  <ul class="saved-boxes">
    <% @saved.each do |s| %>
      <li>
        <%= link_to s.name, tools_box_path(s) %>
        <div class="muted"><%= s.data["generator"] %> · <%= s.updated_at.strftime("%Y-%m-%d") %></div>
      </li>
    <% end %>
  </ul>
<% end %>
```

- [ ] **Step 5: Create the `boxfilter` Stimulus controller**

Create `app/javascript/controllers/boxfilter_controller.js`:

```javascript
import { Controller } from "@hotwired/stimulus"

// Live client-side filter over the grouped generator gallery. Typing in the search box hides
// cards whose terms don't match, then hides any group whose cards are all hidden. No server round
// trip; with JS off the full grouped list still renders.
export default class extends Controller {
  static targets = ["query", "card", "group"]

  filter() {
    const q = this.queryTarget.value.trim().toLowerCase()
    for (const card of this.cardTargets) {
      card.hidden = q !== "" && !card.dataset.terms.includes(q)
    }
    for (const group of this.groupTargets) {
      const cards = group.querySelectorAll("[data-boxfilter-target='card']")
      group.hidden = Array.from(cards).every((c) => c.hidden)
    }
  }
}
```

- [ ] **Step 6: Add the picker CSS**

Append to the END of `app/assets/stylesheets/application.css` (this is the first half of the "Box Generator addon" block; Tasks 2 and 3 append the rest):

```css

/* --- Box Generator addon --- */
.box-search {
  width: 100%; padding: 9px 12px; margin: 4px 0 18px;
  border: 1px solid var(--line); border-radius: 8px;
  font-size: 15px; background: var(--bg); color: var(--fg);
}
.box-group { margin-bottom: 22px; }
.box-group-title {
  font-size: 12px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.04em;
  color: var(--muted); margin: 0 0 10px;
}
.addon-card[hidden], .box-group[hidden] { display: none; }

.saved-boxes {
  list-style: none; padding: 0; margin: 0;
  display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap: 12px;
}
.saved-boxes li { border: 1px solid var(--line); border-radius: 10px; padding: 12px 14px; }
.saved-boxes li > div { font-size: 13px; margin-top: 2px; }
```

Note: `.addon-card[hidden]` (specificity 0,2,0) intentionally overrides `.addon-card { display:flex }` (0,1,0) so the `hidden` attribute the controller sets actually hides the flex card.

- [ ] **Step 7: Run the grouping test to verify it passes**

Run: `bin/rails test test/controllers/tools/boxes_controller_test.rb -n "/groups generators/"`
Expected: PASS.

- [ ] **Step 8: Run the whole boxes test file (nothing regressed)**

Run: `bin/rails test test/controllers/tools/boxes_controller_test.rb`
Expected: PASS (all tests, including the pre-existing "index lists generators and saved boxes").

- [ ] **Step 9: Commit**

```bash
git add test/support/fake_boxes.rb test/controllers/tools/boxes_controller_test.rb \
        app/views/tools/boxes/index.html.erb app/javascript/controllers/boxfilter_controller.js \
        app/assets/stylesheets/application.css
git commit -m "feat(boxes): group + live-filter the generator picker

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Two-column editor layout

**Files:**
- Modify: `test/controllers/tools/boxes_controller_test.rb`
- Modify: `app/views/tools/boxes/new.html.erb`
- Modify: `app/assets/stylesheets/application.css`

- [ ] **Step 1: Write the failing editor-structure test**

Add to `test/controllers/tools/boxes_controller_test.rb`:

```ruby
    test "new renders the two-column editor with a params grid and a preview column" do
      get new_tools_box_path(generator: "ABox")
      assert_response :success
      assert_select ".box-editor form .box-params"
      assert_select ".box-editor .box-side .box-preview img[data-boxpreview-target='image']"
      assert_select "input[name=?]", "params[x]"
    end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/controllers/tools/boxes_controller_test.rb -n "/two-column editor/"`
Expected: FAIL (no `.box-side`; the preview isn't inside a `.box-side` yet).

- [ ] **Step 3: Rewrite the editor view with the two-column structure**

Replace the whole of `app/views/tools/boxes/new.html.erb`. The `boxpreview` controller and its `form`/`image` targets are preserved (the image just moves into the right column — still a descendant of the controller element, so the target still resolves):

```erb
<% content_for :title, "#{@generator.title} — Box Generator" %>

<div class="page-head">
  <h1><%= @generator.title %></h1>
  <%= link_to "Back", tools_boxes_path, class: "btn ghost" %>
</div>

<div class="box-editor" data-controller="boxpreview" data-boxpreview-url-value="<%= preview_tools_boxes_path %>">
  <%= form_with url: tools_boxes_path, method: :post, data: { boxpreview_target: "form" } do %>
    <input type="hidden" name="generator" value="<%= @generator.key %>">
    <label class="box-field">
      <span class="box-field-label">Name</span>
      <input type="text" name="name" required>
    </label>

    <%= render "form", generator: @generator, values: @values %>

    <div class="page-actions">
      <button type="button" data-action="boxpreview#preview" class="btn ghost">Preview</button>
      <button type="submit" class="btn">Save to library</button>
    </div>
  <% end %>

  <aside class="box-side">
    <div class="preview box-preview">
      <img data-boxpreview-target="image" alt="Box preview" class="preview-image">
    </div>
  </aside>
</div>
```

- [ ] **Step 4: Add the editor CSS**

Append to the END of `app/assets/stylesheets/application.css` (continues the "Box Generator addon" block):

```css

.box-editor { display: grid; grid-template-columns: minmax(0, 1fr) 320px; gap: 24px; align-items: start; }
.box-editor > form { min-width: 0; }
.box-params {
  display: grid; grid-template-columns: repeat(auto-fill, minmax(190px, 1fr));
  gap: 12px 16px; margin: 16px 0;
}
.box-field { display: flex; flex-direction: column; gap: 4px; font-size: 14px; }
.box-field-label { color: var(--muted); }
.box-field input[type="number"], .box-field input[type="text"], .box-field select {
  width: 100%; padding: 7px 9px; border: 1px solid var(--line); border-radius: 7px;
  font-size: 14px; background: var(--bg); color: var(--fg);
}
.box-field input[type="checkbox"] { width: auto; align-self: flex-start; }
.box-side { position: sticky; top: 16px; display: flex; flex-direction: column; gap: 16px; }
.box-preview { padding: 12px; }
.box-preview .preview-image { width: 100%; background: #fff; border-radius: 6px; }

@media (max-width: 720px) {
  .box-editor { grid-template-columns: 1fr; }
  .box-side { position: static; }
}
```

- [ ] **Step 5: Run the editor test to verify it passes**

Run: `bin/rails test test/controllers/tools/boxes_controller_test.rb -n "/two-column editor/"`
Expected: PASS.

- [ ] **Step 6: Run the whole boxes test file**

Run: `bin/rails test test/controllers/tools/boxes_controller_test.rb`
Expected: PASS (the pre-existing "new renders a dynamic form" test still passes — the param inputs are unchanged).

- [ ] **Step 7: Commit**

```bash
git add test/controllers/tools/boxes_controller_test.rb \
        app/views/tools/boxes/new.html.erb app/assets/stylesheets/application.css
git commit -m "feat(boxes): two-column editor layout (params grid + sticky preview)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Per-generator history rail + param import

**Files:**
- Modify: `test/controllers/tools/boxes_controller_test.rb`
- Modify: `app/controllers/tools/boxes_controller.rb`
- Modify: `app/views/tools/boxes/new.html.erb`
- Modify: `app/assets/stylesheets/application.css`

- [ ] **Step 1: Write the failing history + import tests**

Add to `test/controllers/tools/boxes_controller_test.rb`. (POST-ing `create` writes to the library, which the setup already configures for the s3 leg; the existing "create saves…" test proves `create` works on all three backend legs.)

```ruby
    test "new lists prior boxes for this generator only, newest first" do
      post tools_boxes_path, params: { name: "Older ABox", generator: "ABox", params: { x: 1, y: 2 } }
      post tools_boxes_path, params: { name: "Newer ABox", generator: "ABox", params: { x: 3, y: 4 } }
      post tools_boxes_path, params: { name: "A Tray",     generator: "TypeTray", params: { x: 5 } }

      get new_tools_box_path(generator: "ABox")
      assert_response :success
      assert_select ".box-prior", text: /Newer ABox/
      assert_select ".box-prior", text: /Older ABox/
      assert_select ".box-prior", text: /A Tray/, count: 0
      assert response.body.index("Newer ABox") < response.body.index("Older ABox"),
             "newer box should render before older"
    end

    test "new omits the history rail when this generator has no saved boxes" do
      get new_tools_box_path(generator: "ABox")
      assert_response :success
      assert_select ".box-prior", count: 0
      assert_select ".box-prior-hint", text: /No saved boxes/
    end

    test "a prior box's Load link imports its saved params into the generator" do
      post tools_boxes_path, params: { name: "Loadable", generator: "ABox", params: { x: 42, y: 7 } }
      state = @user.maker_addon_states.for_addon("boxes").order(:id).last

      get new_tools_box_path(generator: "ABox")
      assert_response :success
      assert_select ".box-prior a[href=?]",
                    new_tools_box_path(generator: "ABox", params: state.data["params"]), text: "Load"
    end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/controllers/tools/boxes_controller_test.rb -n "/prior box|history rail|Load link/"`
Expected: FAIL (no `.box-prior` / `.box-prior-hint` markup, `@prior` not assigned).

- [ ] **Step 3: Load `@prior` in the `new` action**

In `app/controllers/tools/boxes_controller.rb`, replace the `new` method:

```ruby
    def new
      @generator = client.generators.find { |g| g.key == params[:generator] }
      redirect_to(tools_boxes_path, alert: "Unknown generator.") and return unless @generator

      @values = params[:params]&.to_unsafe_h || {} # optional prefill (e.g. "duplicate & tweak")

      # Saved boxes made with THIS generator, newest first. Filtered in Ruby (not SQL): `data` is a
      # JSON column and a `data->>'generator'` query is Postgres-only, which would break the
      # SQLite/Postgres adapter-agnostic rule. The set is one user's saved boxes — small. `id: :desc`
      # is a deterministic tie-break on `updated_at`. `includes(:files)` preloads the rail's output
      # nodes (no N+1).
      @prior = current_user.maker_addon_states.for_addon("boxes")
                           .includes(:files).order(updated_at: :desc, id: :desc)
                           .select { |s| s.data["generator"] == @generator.key }
    end
```

- [ ] **Step 4: Render the history rail in the editor's right column**

In `app/views/tools/boxes/new.html.erb`, replace the `<aside class="box-side">…</aside>` block from Task 2 with this (adds the rail after the preview):

```erb
  <aside class="box-side">
    <div class="preview box-preview">
      <img data-boxpreview-target="image" alt="Box preview" class="preview-image">
    </div>

    <% if @prior.any? %>
      <div class="box-prior" data-controller="thumbs" data-thumbs-url-value="<%= thumbnails_files_path %>">
        <h3>Made with <%= @generator.title %></h3>
        <div class="box-prior-hint muted"><%= pluralize(@prior.size, "saved box") %></div>
        <ul class="box-prior-list">
          <% @prior.each do |s| %>
            <% out = s.files.find { |f| f.role == "output" } %>
            <%= tag.li class: "box-prior-item",
                       data: (out ? { thumbs_target: "cell", node_id: out.node_id, ext: "SVG" } : {}) do %>
              <% if out %>
                <%= render "files/thumb", thumb: nil, ext_label: "SVG" %>
              <% else %>
                <span class="thumb"><span class="thumb-icon" aria-hidden="true">SVG</span></span>
              <% end %>
              <div class="box-prior-meta">
                <div class="box-prior-name"><%= s.name %></div>
                <div class="box-prior-date"><%= s.updated_at.strftime("%b %-d") %></div>
              </div>
              <%= link_to "Load", new_tools_box_path(generator: @generator.key, params: s.data["params"]) %>
            <% end %>
          <% end %>
        </ul>
      </div>
    <% else %>
      <p class="box-prior-hint muted">No saved boxes with this generator yet.</p>
    <% end %>
  </aside>
```

Why this shape: each `<li>` is the `thumbs` cell (`data-thumbs-target="cell"` + `data-node-id` + `data-ext`); the `thumbs` controller does `cell.querySelector(".thumb")`, so the `.thumb` from the `_thumb` partial must be a **descendant** of the `<li>` — it is. Rendering `_thumb` with `thumb: nil` emits the spinner; the poller resolves it to the output SVG's PNG (already generated at save time) or, on the rare unsupported/failed, a badge. The `Load` link is the existing prefill path — no new endpoint.

- [ ] **Step 5: Add the rail CSS**

Append to the END of `app/assets/stylesheets/application.css` (final part of the "Box Generator addon" block):

```css

.box-prior { border: 1px solid var(--line); border-radius: 10px; padding: 12px 14px; }
.box-prior h3 { margin: 0; font-size: 14px; }
.box-prior-hint { font-size: 13px; margin-top: 2px; }
.box-prior-list { list-style: none; padding: 0; margin: 10px 0 0; display: flex; flex-direction: column; gap: 10px; }
.box-prior-item { display: flex; align-items: center; gap: 10px; }
.box-prior-item .thumb { width: 40px; height: 40px; flex: 0 0 40px; background: var(--soft); }
.box-prior-meta { flex: 1; min-width: 0; }
.box-prior-name { font-size: 13px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.box-prior-date { font-size: 12px; color: var(--muted); }
```

- [ ] **Step 6: Run the new tests to verify they pass**

Run: `bin/rails test test/controllers/tools/boxes_controller_test.rb -n "/prior box|history rail|Load link/"`
Expected: PASS (all three).

- [ ] **Step 7: Run the whole boxes test file**

Run: `bin/rails test test/controllers/tools/boxes_controller_test.rb`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add test/controllers/tools/boxes_controller_test.rb app/controllers/tools/boxes_controller.rb \
        app/views/tools/boxes/new.html.erb app/assets/stylesheets/application.css
git commit -m "feat(boxes): per-generator history rail with one-click param import

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Full-suite verification across all three backends

The addon writes through the FileLayer port, so the suite runs on chunk (default), share, and s3. This task proves nothing regressed on any leg.

**Files:** none (verification only).

- [ ] **Step 1: Default (chunk) leg**

Run: `bin/rails test`
Expected: PASS, 0 failures / 0 errors.

- [ ] **Step 2: Share leg**

Run: `LIBRARY_BACKEND=share bin/rails test test/controllers/tools/boxes_controller_test.rb test/integration/tools/boxes_live_test.rb`
Expected: PASS (the addon tests; `boxes_live_test` skips without a sidecar).

- [ ] **Step 3: S3 leg**

Run: `LIBRARY_BACKEND=s3 bin/rails test test/controllers/tools/boxes_controller_test.rb`
Expected: PASS (setup wires `FakeS3`).

- [ ] **Step 4: Manual smoke (optional, if a sidecar is reachable)**

If `BOXES_SIDECAR_URL` is set, boot the server (`bin/rails server -p 3001`), open `/tools/boxes`, confirm: generators are grouped and the filter box narrows them live; clicking a generator shows the two-column editor; after saving a box, revisiting that generator shows it in the rail with a thumbnail; clicking "Load" reopens the editor with the params filled and the name blank.

- [ ] **Step 5: Final confirmation**

No commit (verification only). If any leg failed, fix under the failing task's TDD loop before proceeding.

---

## Notes for the implementer

- **Do not** touch `BoxesClient`, `LibraryOutput`, the save/`create` flow, or anything under `sidecar/`. This plan is view/CSS/one-controller-read only (spec §"Out of scope").
- **Do not** add a `data->>'generator'` SQL query "for performance" — it breaks SQLite (spec §Approach 3). Ruby filtering is deliberate.
- The `Load` link deliberately leaves the **name** field blank (you're creating a new box), matching the existing "Duplicate & tweak" behavior.
- Keep the appended CSS as one contiguous "Box Generator addon" block at the end of `application.css` (Tasks 1→2→3 append in order).
