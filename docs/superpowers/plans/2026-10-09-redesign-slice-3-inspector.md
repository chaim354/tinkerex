# Redesign slice 3 — the inspector and the workspace — Implementation Plan

> **For agentic workers:** in this repo, execute with **`.claude/commands/execute-plan.md`** (CLAUDE.md
> §15: batched by file, parallel where independent, one capped quality review per task). It
> overrides the generic superpowers subagent loop. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On the Files page, a click on a file selects it and opens a right-hand inspector, with the
selection in the URL. The file page becomes a full-width workspace with its facts in a side column.
Photo tiles fill their stage instead of sitting in white bars.

**Architecture:**
- The inspector is a new endpoint, `GET /files/:id/inspector`. It returns a Turbo Frame body for
  one node, built from two partials extracted out of `files/show.html.erb` (`files/_meta`,
  `files/_attach`), so the panel and the page share one markup.
- A new Stimulus controller, `selection`, intercepts a plain click on a file tile. Every tile stays
  `<a href=file_path>`, so modifier clicks, Enter, double-click, the right-click menu's Open and
  no-JavaScript all keep opening the page.
- `?selected=` is read by the server, so reload, Back and shared links restore the selection.
- The file page keeps its controller logic and reflows into `.workspace-main` and `.workspace-side`.

**Tech Stack:** Rails 8, Turbo (Drive and Frames; `turbo_frame_tag` from turbo-rails), Stimulus,
Minitest request and system tests.

**Spec:** `docs/superpowers/specs/2026-10-08-structural-redesign-design.md` §5.1–5.3 (and slice 1's
deferred photo matte). Slices 1 (#381) and 2 (#382) are merged.

**Required reading for every task** (they bind these paths): `docs/invariants/files-preview.md`,
`docs/invariants/git-editing.md`, `docs/invariants/design-system.md`, and CLAUDE.md §14d. The rules
most likely to bite here:
- **The eight viewer partials take strict locals** and build no URL; maker-only facts stay outside
  them.
- **`current_thumbnail` asks for an existing row before it enqueues**, so a door opened repeatedly
  never resets a `failed` render.
- **A reload-mode `thumbs` controller reloads the whole document**, so the inspector polls in swap
  mode.
- **`back_target_path` is referer-based and must not become a URL parameter.**
- **Query budgets assert constancy in N.**
- **No `%>` inside an ERB comment.**
- **A `data-controller` name must resolve.**
- **Class names are a contract.**
- **No sideways scroll at 375px.**

---

## Decisions this plan applies

From the spec: one click selects a file and opens the inspector, double-click or Enter opens the
page, arrow keys move the selection and Escape clears it. The selection lives in `?selected=`, and
a stale, foreign, folder or off-listing id is ignored, never an error. The inspector loads one node,
so it is constant in N. The file page goes full width with the viewer in the main column.

Sequencing and scope choices (recorded in the spec by Task 4):
1. **The inspector's actions are Open, Download and Delete.** Rename, Move and Pin are not in slice
   3. They need doors that don't exist on the web (Rename and Move) or belong to the folder (Pin).
2. **The inspector shows the note count and a link to the page's notes** (`#notes`), not the
   composer. The composer is a Lexxy editor and belongs on the page.
3. **Attaching from the inspector returns to the Library with the file still selected**
   (`return_to: "library"`). If the attach raises a move conflict, it falls back to the file page,
   because only that page renders the conflict prompt.
4. **"Back to folder" is the breadcrumb, not a new button.** The file page's top-bar breadcrumb
   gains the folder chain, and its parent-folder link carries `selected` for this file. The
   existing Back keeps its referer contract, and since `selection` writes `?selected=` with
   `replaceState`, the referer already carries the selection.
5. **The workspace's side column is not collapsible in slice 3.** The 3D, Gerber and Measure
   viewers size themselves to their container when they are built (files-preview.md, "`--ready`
   means the viewer is open"), so a collapse would need a resize contract with each one. The
   columns stack below 1280px.
6. **Which tiles are photos is decided by extension.** `Maker::FileAttachment::PHOTO_EXTS` is
   `jpg jpeg heic heif`, a display-only subset of the `image` role: the formats a camera writes.
   PNG, GIF, WebP, BMP and TIFF keep `contain`, because they are more often screenshots, renders or
   scans. The role is unchanged.

## Files

| file | change | task |
|---|---|---|
| `app/views/files/_meta.html.erb`, `app/views/files/_attach.html.erb` | new partials, extracted verbatim from `files/show.html.erb` | 1 |
| `app/views/files/show.html.erb` | render the two partials; `id="notes"` on the notes panel | 1 |
| `app/controllers/files_controller.rb` | `attach_choices_for`, `library_path_for` (extracted from `#show`); new `#inspector` | 1 |
| `app/views/files/inspector.html.erb`, `app/views/files/inspector_gone.html.erb` | new | 1 |
| `config/routes.rb` | `get "inspector"` on the files member | 1 |
| `app/controllers/projects/attachments_controller.rb` | `return_to: "library"` | 1 |
| `test/integration/web/inspector_test.rb`, `test/integration/web/page_query_budget_test.rb` | new tests | 1 |
| `app/views/files/show.html.erb` | the workspace layout and the breadcrumb | 2 |
| `app/controllers/files_controller.rb` (`#show` only) | `@crumbs` for the breadcrumb | 2 |
| `app/assets/stylesheets/pages/preview.css` | `.workspace` rules | 2 |
| `test/integration/web/workspace_test.rb` | new | 2 |
| `app/javascript/controllers/selection_controller.js` | new | 3 |
| `app/helpers/files_helper.rb` | `with_selection` | 3 |
| `app/views/files/index.html.erb`, `_grid.html.erb`, `_list.html.erb`, `_thumb.html.erb` | the library wrapper, the inspector aside, item data, `.is-selected`, `photo:` | 3 |
| `app/controllers/files_controller.rb` (`#index` and `files_query_base` only) | `@selected` | 3 |
| `app/models/maker/file_attachment.rb` | `PHOTO_EXTS`, `photo?` | 3 |
| `app/assets/stylesheets/pages/files.css` | library and inspector layout, selected tile, inspector body | 3 |
| `test/integration/web/files_selection_test.rb`, `test/system/files_selection_test.rb`, `test/models/maker/file_attachment_test.rb` | new and extended tests | 3 |
| `docs/invariants/files-preview.md`, the spec | the inspector's rules, the amendments | 4 |

**Dependencies:** Task 1 first, because Tasks 2 and 3 use its partials and route. **Tasks 2 and 3 then
run in parallel.** Their files are disjoint, except `files_controller.rb`: Task 2 edits only `#show`
and Task 3 only `#index` and `files_query_base`. Run each in its own worktree; the hunks are far
apart, so the cherry-picks merge cleanly. Task 4 last.

**Branch:** `claude/redesign-slice-3` from `origin/main`.

**Test fixtures:** use `use_fresh_share_library!` plus rows from `@user.nodes.create!`, as
`test/integration/web/addon_origin_surfaces_test.rb` does. It pins the backend to share for the
file, so the file page and the inspector render on all three legs. For system tests that need real
tiles, scan files in the way `test/system/code_theme_test.rb` does. Run tests with
`LIBRARY_PATH=$(mktemp -d) bin/rails test <files>`, and use bare `bin/ci` for the close-out.

---

### Task 1: The shared partials and the inspector endpoint

**Files:** listed under task 1 in the table above.

- [ ] **Step 1: Extract `files/_meta` and `files/_attach`, with no behaviour change**

Create `app/views/files/_meta.html.erb` from the `<dl class="meta">…</dl>` block of
`files/show.html.erb`, **verbatim, comments included**. Add a strict-locals header, and replace
`@info` with `info` and `@library_path` with `library_path`:

```erb
<%# locals: (info:, addon_origin:, library_path:) %>
```

Create `app/views/files/_attach.html.erb` from the `<% if @projects.present? || @attached_projects.present? %>`
block, verbatim. Header:

```erb
<%# locals: (node:, attached_projects:, projects:, return_to:) %>
```

Replace `@node` with `node`, `@projects` with `projects`, `@attached_projects` with
`attached_projects`, and the hidden field's `value: "file"` with `value: return_to`. Extend its
comment: "`return_to` is `"file"` on the file page and `"library"` in the inspector;
AttachmentsController#attach_redirect_path allowlists both."

In `files/show.html.erb`, replace the two blocks with:

```erb
<%= render "files/meta", info: @info, addon_origin:, library_path: @library_path %>
<%= render "files/attach", node: @node, attached_projects: @attached_projects, projects: @projects,
                           return_to: "file" %>
```

The hash shorthand `addon_origin:` is safe here, because the next line is not another tag's
expression. **Spell it out (`addon_origin: addon_origin`) if a `%>` follows on the same line.** The
house memory "ERB hash shorthand swallows the next line" is about exactly that case.

Also add `id="notes"` to `<section class="notes-panel">`.

Run: `LIBRARY_PATH=$(mktemp -d) bin/rails test test/integration/web/file_page_test.rb test/integration/web/attach_from_files_test.rb test/integration/web/addon_origin_surfaces_test.rb test/integration/web/back_link_test.rb test/integration/web/template_hygiene_test.rb`
Expected: PASS, unchanged. The extraction is behaviour-neutral.

- [ ] **Step 2: Extract the two controller helpers from `#show`**

In `app/controllers/files_controller.rb`, move the attach-choices block (the one starting
`attachments = current_user.maker_file_attachments` and ending with
`@projects = scope.to_a.sort_by { |p| name_key(p) }`) into a private method, with its comments
moved along with it:

```ruby
  # THE ATTACH CONTROL'S TWO HALVES — what the file is already in, and the rest — shared by #show
  # and #inspector. [the existing comments from #show, moved here verbatim]
  def attach_choices_for(node)
    attachments = current_user.maker_file_attachments
                              .where(node_id: node.node_id, attachable_type: "Maker::Project")
                              .includes(:attachable).to_a
    attached = attachments.filter_map { |a|
      [ a.attachable, a ] if a.attachable && a.attachable.status != "archived"
    }.sort_by { |project, _| name_key(project) }
    scope = current_user.maker_projects.where.not(status: "archived")
    attached_ids = attachments.map(&:attachable_id)
    scope = scope.where.not(id: attached_ids) if attached_ids.any?
    [ attached, scope.to_a.sort_by { |p| name_key(p) } ]
  end
```

Move the library-path block (`folder_path = …` and `@library_path = …`) into:

```ruby
  # WHERE THIS FILE IS, IN THE LIBRARY'S OWN TERMS. [the existing comments, moved verbatim]
  def library_path_for(node)
    folder_path = Maker::LibraryTree.new(current_user).path_for(node.parent_node_id)
    folder_path && [ folder_path.presence, node.name ].compact.join("/")
  end
```

In `#show`, write `@attached_projects, @projects = attach_choices_for(@node)` and
`@library_path = library_path_for(@node)` where the blocks were.

Run the Step 1 tests plus `test/integration/web/page_query_budget_test.rb`. Expected: PASS.

- [ ] **Step 3: Write the failing inspector test**

Create `test/integration/web/inspector_test.rb`:

```ruby
require "test_helper"

module Web
  class InspectorTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @root = use_fresh_share_library!
      @user = User.create!(email: "insp-#{SecureRandom.hex(4)}@example.com", password: PASSWORD,
                           confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      @dir = @user.nodes.create!(node_id: "dir-legs", name: "legs", kind: "dir", mtime: 1, size: 0)
      @file = @user.nodes.create!(node_id: "n-leg", name: "leg.lbrn2", kind: "file", mtime: 1, size: 5,
                                  parent_node_id: @dir.node_id)
    end

    teardown do
      FileLayer.reset!
      FileUtils.remove_entry(@root) if @root&.exist?
    end

    test "the inspector is one file's panel: name, Open, Download, facts, projects, notes" do
      project = @user.maker_projects.create!(name: "Shop Stool")
      @user.maker_notes.create!(node_id: @file.node_id, body: "Cut at 80%.")

      get inspector_file_path(@file.node_id)
      assert_response :success
      assert_select "turbo-frame#inspector[target='_top']" do
        assert_select ".inspector-name", text: "leg.lbrn2"
        assert_select "a[href=?]", file_path(@file.node_id), text: "Open"
        assert_select "a[href=?]", blob_file_path(@file.node_id, download: 1), text: "Download"
        assert_select "dl.meta dt", text: "Size"
        assert_select "form.attach-form input[name='return_to'][value='library']"
        assert_select "form.attach-form select option", text: project.name
        assert_select "a[href=?]", file_path(@file.node_id, anchor: "notes"), text: "1 note"
      end
      assert_select "aside.rail", count: 0, "a frame body renders without the layout"
    end

    test "a folder, a tombstone or another user's file answers a gone frame, not a page" do
      other = User.create!(email: "o-#{SecureRandom.hex(4)}@example.com")
      theirs = other.nodes.create!(node_id: "n-theirs", name: "x.stl", kind: "file", mtime: 1, size: 1)
      gone = @user.nodes.create!(node_id: "n-gone", name: "old.stl", kind: "file", mtime: 1, size: 1,
                                 deleted: true)
      [ @dir.node_id, gone.node_id, theirs.node_id ].each do |id|
        get inspector_file_path(id)
        assert_response :not_found
        assert_select "turbo-frame#inspector", text: /isn't here any more/
      end
    end

    test "opening the panel twice asks for the existing preview, never a second render" do
      @file.update_columns(size: 5)
      2.times { get inspector_file_path(@file.node_id) }
      assert_operator Maker::Preview.where(user: @user, node_id: @file.node_id).count, :<=, 1
    end

    test "attaching from the inspector lands back in the Library with the file selected" do
      project = @user.maker_projects.create!(name: "Shop Stool")
      post attachments_path, params: { node_id: @file.node_id, project_id: project.slug,
                                       return_to: "library" }
      assert_redirected_to files_path(folder: @dir.node_id, selected: @file.node_id)
    end
  end
end
```

Run it and expect ERROR: `undefined method 'inspector_file_path'`.

- [ ] **Step 4: Route, action, views, redirect**

In `config/routes.rb`, inside `resources :files … member do`, add:

```ruby
      get "inspector"
```

In `FilesController`, add a public action after `#show`:

```ruby
  # GET /files/:id/inspector — the Library's right-hand panel for ONE selected file (structural
  # redesign spec §5.2, slice 3), a Turbo Frame body rendered without the layout. Everything here is
  # about one node, so its cost is constant in the size of the folder (page_query_budget_test.rb).
  #
  # `current_thumbnail` ASKS FOR THE EXISTING ROW FIRST, so a panel opened again and again never
  # re-enqueues — files-preview.md's Enqueue asymmetry (`call` resets `failed`).
  #
  # A MISSING NODE ANSWERS A FRAME, NOT THE CONTROLLER'S REDIRECT: rescue_from sends HTML to
  # files_path, which inside a frame would put the whole Library into the panel.
  def inspector
    @node = current_user.nodes.present.find_by(node_id: params[:id], kind: "file")
    return render("inspector_gone", layout: false, status: :not_found) unless @node

    @info = FileLayer.current.stat(current_user, node_id: @node.node_id)
    token = @info&.content_token
    @thumbnail = token && current_thumbnail(@node, token)
    @attached_projects, @projects = attach_choices_for(@node)
    @note_count = current_user.maker_notes.where(node_id: @node.node_id).count
    @addon_origins = addon_origins_for([ @node.node_id ])
    @library_path = library_path_for(@node)
    render layout: false
  end
```

`app/views/files/inspector_gone.html.erb`:

```erb
<%# The inspector's answer for a node that is not a live file of this user's (FilesController#inspector). %>
<turbo-frame id="inspector">
  <p class="empty inline">That file isn't here any more.</p>
</turbo-frame>
```

`app/views/files/inspector.html.erb`:

```erb
<%# THE INSPECTOR (structural redesign spec §5.2, slice 3): the Library's right-hand panel for one
    selected file, loaded into the `inspector` frame on files/index.html.erb. `target="_top"` so
    Open, a project link and every form's redirect replace the Library, never just this panel.

    THE PREVIEW POLLS IN SWAP MODE (no reload value): a reload-mode thumbs controller here would
    reload the whole Files page when the render lands. files/show.html.erb's preview row owns
    reload mode. %>
<% addon_origin = @addon_origins[@node.node_id] %>
<% ext = File.extname(@node.name).delete(".").upcase %>
<turbo-frame id="inspector" target="_top">
  <div class="inspector-head">
    <span class="eyebrow"><%= ext.present? ? "#{ext} file" : "File" %></span>
    <h2 class="inspector-name"><%= @node.name %></h2>
  </div>

  <div class="inspector-stage" data-controller="thumbs" data-thumbs-url-value="<%= thumbnails_files_path %>">
    <% if Maker::FileAttachment.inline_image?(@node.name) %>
      <span class="thumb"><img src="<%= blob_file_path(@node.node_id) %>" alt=""></span>
    <% elsif Maker::Previews::Registry.for_filename(@node.name).present? %>
      <%= tag.span class: "file-cell", data: thumb_cell_data(@node.node_id, ext.first(4)) do %>
        <%= render "files/thumb", thumb: @thumbnail, ext_label: ext.first(4), url: preview_src(@thumbnail) %>
      <% end %>
    <% else %>
      <span class="thumb generic-thumb" aria-hidden="true"><%= ext.first(4).presence || "FILE" %></span>
    <% end %>
  </div>

  <div class="inspector-actions">
    <%= link_to "Open", file_path(@node.node_id), class: "btn small" %>
    <%= link_to "Download", blob_file_path(@node.node_id, download: 1), class: "btn small", data: { turbo: false } %>
    <%= button_to "Delete", file_path(@node.node_id), method: :delete, class: "btn small danger",
          form: { data: { turbo_confirm: "Delete #{@node.name}?" } } %>
  </div>

  <%= render "files/meta", info: @info, addon_origin: addon_origin, library_path: @library_path %>

  <% if addon_origin %>
    <p class="inspector-origin">
      <span class="group-head">Made with</span>
      <%= link_to addon_origin[:label], addon_origin[:url] %>
    </p>
  <% end %>

  <%= render "files/attach", node: @node, attached_projects: @attached_projects, projects: @projects,
                             return_to: "library" %>

  <p class="inspector-notes">
    <%= link_to pluralize(@note_count, "note"), file_path(@node.node_id, anchor: "notes") %>
    · <%= link_to "Add a note", file_path(@node.node_id, anchor: "notes") %>
  </p>
</turbo-frame>
```

In `app/controllers/projects/attachments_controller.rb`, replace `attach_redirect_path`:

```ruby
    # `return_to` IS AN ALLOWLISTED FLAG, NOT A URL, so it cannot become an open redirect. "file" is
    # the file page; "library" is the inspector, which returns to the file's folder with the file
    # still selected — UNLESS the attach raised a move conflict, whose prompt only the file page
    # renders (projects/_move_conflict), so a conflict falls back to the file page.
    def attach_redirect_path(node, conflict_id)
      case params[:return_to]
      when "library"
        return file_path(node.node_id, move_conflict: conflict_id) if conflict_id
        files_path(folder: node.parent_node_id, selected: node.node_id)
      when "file"
        file_path(node.node_id, move_conflict: conflict_id)
      else
        project_path(@project, move_conflict: conflict_id)
      end
    end
```

Add the frame to `template_hygiene_test.rb`'s `pages` map, so a comment leak in it would show:

```ruby
        "file inspector" => inspector_file_path(<an existing fixture file's node_id in that test>),
```

Use whichever file node that test's setup already creates.

Run: `LIBRARY_PATH=$(mktemp -d) bin/rails test test/integration/web/inspector_test.rb test/integration/web/template_hygiene_test.rb test/integration/web/attach_from_files_test.rb`
Expected: PASS.

- [ ] **Step 5: The inspector's query budget**

In `test/integration/web/page_query_budget_test.rb`:

```ruby
    # THE INSPECTOR IS ONE NODE'S PANEL, so it must not grow with the file's notes or its projects —
    # it is fetched on every selection.
    test "the inspector does not grow with notes or attached projects" do
      file = node!("panel.stl")
      assert_constant_queries(
        seed: ->(n) {
          n.times do |i|
            @user.maker_notes.create!(node_id: file.node_id, body: "note #{i}")
            p = @user.maker_projects.create!(name: "P#{SecureRandom.hex(3)}")
            p.file_attachments.create!(user: @user, node_id: file.node_id, role: "model")
          end
        },
        render: -> { get inspector_file_path(file.node_id) }
      )
    end
```

Match `assert_constant_queries`'s real signature and the `node!` helper in that file. Read them first
and adapt the call shape, keeping the intent: seed SMALL, measure, seed to LARGE, measure, and
assert the counts are equal.

- [ ] **Step 6: Mutation-check (§15)** — report actual output.

1. In `#inspector`, replace `current_thumbnail(@node, token)` with a direct
   `Maker::Previews::Enqueue.call(...)`, using the same arguments as `current_thumbnail`'s second
   branch. Expected: with a fixture whose preview is already ready, the second open re-enqueues.
   **If the test as written cannot see it, strengthen it until it can** (seed a `ready` row first),
   and report.
2. Delete the `return file_path(...) if conflict_id` line. Expected: no test reddens. Then **add**
   a test that forces a conflict, if `attach_from_files_test.rb` has a conflict fixture to copy. If
   it has none, report that the fallback is unguarded.
3. Make `attach_choices_for` add one query per attachment (e.g. `attachments.each(&:reload)`).
   Expected: the budget test is red.

- [ ] **Step 7: Commit**

Subject: `A file has an inspector: one node's panel, built from the file page's own partials`.

---

### Task 2: The workspace (the file page)

**Files:** `app/views/files/show.html.erb`, `app/controllers/files_controller.rb` (`#show` only),
`app/assets/stylesheets/pages/preview.css`, `test/integration/web/workspace_test.rb`.

- [ ] **Step 1: Failing test**

Create `test/integration/web/workspace_test.rb`, with the same setup as `inspector_test.rb` (a dir
`legs` and a file `leg.lbrn2` inside it, on a fresh share library):

```ruby
    test "the file page is a workspace: the viewer in the main column, the facts beside it" do
      get file_path(@file.node_id)
      assert_response :success
      assert_select "main.container.container-wide"
      assert_select ".workspace .workspace-main .preview-row"
      assert_select ".workspace .workspace-side dl.meta"
      assert_select ".workspace .workspace-side section.connections-panel"
      assert_select ".workspace .workspace-side section.notes-panel#notes"
    end

    test "the breadcrumb walks to the file's folder and that link reselects the file" do
      get file_path(@file.node_id)
      assert_select "header.topbar nav.breadcrumb" do
        assert_select "a[href=?]", files_path, text: "Files"
        assert_select "a[href=?]", files_path(folder: @dir.node_id, selected: @file.node_id), text: "legs"
        assert_select "[aria-current='page']", text: "leg.lbrn2"
      end
    end
```

Run it and expect FAIL.

- [ ] **Step 2: `@crumbs` in `#show`**

At the end of `#show`:

```ruby
    # THE BREADCRUMB'S FOLDER CHAIN (structural redesign §5.3): the same `folder_crumbs` walk #index
    # makes — one find_by per ancestor, so it grows with DEPTH, never with the folder's size. Also
    # what lets ShellHelper#sidebar_current light a pinned ancestor on a file page.
    parent = @node.parent_node_id && current_user.nodes.present.find_by(node_id: @node.parent_node_id, kind: "dir")
    @crumbs = folder_crumbs(parent)
```

Check that `folder_crumbs(nil)` returns `[]`. It walks from the folder it is given, so nil produces
an empty chain. Read it to confirm.

- [ ] **Step 3: The workspace layout**

In `files/show.html.erb`:

1. After the `content_for :title` line, add:

```erb
<% content_for :container_class, "container-wide" %>
<% content_for :crumbs do %>
  <nav class="breadcrumb" aria-label="File path">
    <%= link_to "Files", files_path %>
    <% @crumbs.each_with_index do |crumb, i| %>
      <span class="sep" aria-hidden="true">/</span>
      <%# The LAST crumb is this file's folder; it reselects the file there, which is what "back to
          folder" means in a Library with an inspector. %>
      <%= link_to crumb.name, files_path(folder: crumb.node_id,
                                         selected: (i == @crumbs.length - 1 ? @node.node_id : nil)) %>
    <% end %>
    <span class="sep" aria-hidden="true">/</span>
    <span aria-current="page"><%= @node.name %></span>
  </nav>
<% end %>
```

   A file at the library root has `@crumbs == []`, so the `Files` link is its folder. Give that link
   `selected:` too when `@crumbs` is empty:
   `link_to "Files", files_path(selected: (@crumbs.empty? ? @node.node_id : nil))`.

2. Wrap everything after `<%= render "projects/move_conflict" %>` as follows.
   - `.workspace-main` holds the preview row and the history panel.
   - `.workspace-side` holds the meta partial, the attach partial, connections and the notes panel,
     in that order.
   - Keep `.page-head` and `projects/move_conflict` above the wrapper, unchanged. The move-conflict
     prompt stays at the top.

```erb
<div class="workspace">
  <div class="workspace-main">
    [the .preview-row block, unchanged]
    [the history-panel block, unchanged]
  </div>
  <aside class="workspace-side" aria-label="About this file">
    <%= render "files/meta", info: @info, addon_origin: addon_origin, library_path: @library_path %>
    <%= render "files/attach", node: @node, attached_projects: @attached_projects, projects: @projects,
                               return_to: "file" %>
    <%= render "files/connections" %>
    [the notes-panel section, unchanged, with id="notes"]
  </aside>
</div>
```

   Move blocks **only**. Do not edit their markup.

3. In `app/assets/stylesheets/pages/preview.css`, inside its `@layer pages`:

```css
  /* THE WORKSPACE (structural redesign §5.3): the viewer takes the main column and the file's facts
     sit beside it from 1280px; below that they stack under the viewer. NOT COLLAPSIBLE: the 3D,
     Gerber and Measure viewers measure their container when they are built (files-preview.md,
     "`--ready` means the viewer is open"), so a column that changes width after load would need a
     resize contract with each of them. */
  .workspace { display: grid; gap: var(--space-5); grid-template-columns: minmax(0, 1fr); }
  .workspace-side { display: grid; gap: var(--space-4); align-content: start; min-width: 0; }
  .workspace-side dl.meta { grid-template-columns: max-content minmax(0, 1fr); margin: 0; }
  .workspace-side .notes-panel, .workspace-side .connections-panel { margin-top: 0; }
  @media (min-width: 1280px) {
    .workspace { grid-template-columns: minmax(0, 1fr) 340px; }
    .workspace-side { position: sticky; top: calc(var(--topbar-height) + var(--space-4)); }
  }
```

- [ ] **Step 4: Run**

Run: `LIBRARY_PATH=$(mktemp -d) bin/rails test test/integration/web/workspace_test.rb test/integration/web/file_page_test.rb test/integration/web/back_link_test.rb test/integration/web/attach_from_files_test.rb test/integration/web/notes_test.rb test/integration/web/files_flow_test.rb test/integration/web/template_hygiene_test.rb test/integration/web/page_query_budget_test.rb test/integration/web/shell_layout_test.rb`
Expected: PASS.

System, since the viewers measure their container: `test/system/shell_test.rb` (the 375px sweep
covers three file pages), `test/system/files_pages_test.rb`, and one each of the o3dv, measure,
gerber and repo_history suites (grep `test/system` for their filenames).

- [ ] **Step 5: Mutation-check** — report actual output.

1. Drop `selected:` from the last crumb. Expected: the breadcrumb test is red.
2. Move `dl.meta` back above the wrapper. Expected: the workspace test is red.

- [ ] **Step 6: Commit**

Subject: `The file page is a workspace: the viewer wide, its facts beside it, a breadcrumb home`.

---

### Task 3: Selection, the docked inspector, and photo tiles

**Files:** listed under task 3 in the table above.

- [ ] **Step 1: The photo rule — failing model test, then the constant**

Append to `test/models/maker/file_attachment_test.rb`, creating the file if it does not exist with
`require "test_helper"` and `module Maker; class FileAttachmentTest < ActiveSupport::TestCase … end; end`:

```ruby
    test "a photo is a camera format, and every photo extension is an image" do
      assert Maker::FileAttachment.photo?("stool.JPG")
      assert Maker::FileAttachment.photo?("IMG_0042.heic")
      refute Maker::FileAttachment.photo?("screenshot.png"), "a PNG keeps contain: it is often a screenshot"
      refute Maker::FileAttachment.photo?("bracket.stl")
      assert_empty Maker::FileAttachment::PHOTO_EXTS - Maker::FileAttachment::IMAGE_EXTS,
                   "PHOTO_EXTS is a display subset of the image role, never a second vocabulary"
    end
```

In `app/models/maker/file_attachment.rb`, after `INLINE_IMAGE_EXTS` and its `inline_image?`:

```ruby
    # PHOTO_EXTS — the image formats a CAMERA writes. A tile of one is cropped to fill its stage
    # (`.thumb.photo`); PNG, GIF, WebP, BMP and TIFF keep `contain`, being more often screenshots,
    # renders or scans, where a crop cuts off the point. A DISPLAY choice only: the role stays
    # "image" for all ten (ROLE_BY_EXT), and this list must stay a subset of IMAGE_EXTS
    # (file_attachment_test.rb). Structural redesign slice 3; slice 1 styled `.thumb.photo`.
    PHOTO_EXTS = (IMAGE_EXTS & %w[jpg jpeg heic heif]).freeze

    def self.photo?(name) = PHOTO_EXTS.include?(File.extname(name.to_s).delete(".").downcase)
```

Run the model test. Expected: PASS.

- [ ] **Step 2: Failing request tests for selection**

Create `test/integration/web/files_selection_test.rb`. Use the same setup as `inspector_test.rb`, plus
a renderable `bracket.stl` and a non-renderable `notes.rtf` in `legs`, a `side.jpg`, and a `shot.png`:

```ruby
    test "every file tile is a selectable item that still links to its page; folders are not" do
      %w[grid list].each do |view|
        get files_path(folder: @dir.node_id, view:)
        items = css_select("[data-selection-target='item']")
        assert_operator items.size, :>=, 3, "#{view}: the files are not all items"
        items.each do |el|
          assert_equal file_path(el["data-selection-id"]), el["href"], "#{view}: an item stopped linking to its page"
          assert_includes el["data-action"], "selection#click"
          assert_includes el["data-action"], "selection#open"
        end
        assert_select "[data-selection-target='item'][data-action*='filemenu#open']", minimum: 1
      end
      get files_path
      assert_select "a.dir[data-selection-target], a.grid-folder[data-selection-target]", count: 0
    end

    test "a selected file in the listing opens the inspector frame and marks its tile" do
      get files_path(folder: @dir.node_id, selected: @stl.node_id, view: "grid")
      assert_select ".library.has-inspector"
      assert_select "aside.inspector turbo-frame#inspector[src=?][target='_top']", inspector_file_path(@stl.node_id)
      assert_select ".grid-card.is-selected[data-selection-id=?]", @stl.node_id
    end

    test "a stale, foreign, folder or off-listing selection is ignored, not an error" do
      [ "no-such-node", @dir.node_id, @root_png.node_id ].each do |id|
        get files_path(folder: @dir.node_id, selected: id)
        assert_response :success
        assert_select ".library.has-inspector", count: 0
        assert_select "turbo-frame#inspector[src]", count: 0
      end
    end

    test "the selection rides along on the listing's own links" do
      get files_path(folder: @dir.node_id, selected: @stl.node_id, view: "list")
      assert_select "th a[href*='selected=#{@stl.node_id}']", minimum: 1
    end

    test "a photo tile crops and a screenshot keeps contain" do
      get files_path(view: "grid")
      assert_select ".grid-card[data-selection-id=?] .thumb.photo", @jpg.node_id
      assert_select ".grid-card[data-selection-id=?] .thumb.photo", @root_png.node_id, count: 0
    end
```

`@root_png` is `shot.png` at the root (off the `legs` listing), and `@jpg` is `side.jpg` at the root.
Run them and expect FAIL.

- [ ] **Step 3: `@selected` and the query base**

In `FilesController#index`, after the line that finishes ordering `@nodes` (before `@folder_paths`):

```ruby
    # THE SELECTION (structural redesign §5.1): a FILE in THIS listing, or nothing. A stale, foreign,
    # folder or off-page id is ignored rather than an error — a shared link outlives its file.
    requested = params[:selected].presence
    @selected = requested if requested && @nodes.any? { |n| n.node_id == requested && n.file? }
```

`Node#file?` exists if the views use it (`_grid` calls `node.file?`); confirm. In
`files_query_base`, add `selected: @selected` to the hash before `.compact`.

- [ ] **Step 4: Item data, selected tile, photo class**

In `app/helpers/files_helper.rb`:

```ruby
  # A FILE TILE IS A SELECTABLE ITEM (structural redesign §5.1): click selects, double-click opens,
  # and the link's own behaviour stays for everything else (selection_controller.js). Merged into
  # whatever data the tile already carries — its `action` is APPENDED to, never replaced, because
  # the file menu's `contextmenu->filemenu#open` lives in the same attribute.
  def with_selection(data, node_id)
    data.merge(selection_target: "item", selection_id: node_id,
               action: [ data[:action], "click->selection#click", "dblclick->selection#open" ].compact.join(" "))
  end
```

In `_grid.html.erb`, for both FILE branches (renderable and non-renderable), wrap the existing `data:`
hash in `with_selection(…, node.node_id)`, and add `is-selected` to the class when
`node.node_id == @selected`. For example, for the renderable branch:

```erb
      <%= link_to file_path(node.node_id), class: [ "grid-card file-cell", ("is-selected" if node.node_id == @selected) ],
                  data: with_selection(thumb_cell_data(node.node_id, ext_label)
                          .merge(file_menu_data(node.node_id, node.name, @addon_origins[node.node_id])), node.node_id) do %>
        <%= render "thumb", thumb:, ext_label:, url: preview_src(thumb), photo: Maker::FileAttachment.photo?(node.name) %>
```

Do the same for `_list.html.erb`'s two file links. Folders are untouched.

In `_thumb.html.erb`, extend the strict locals and the span:

```erb
<%# locals: (thumb:, ext_label:, url:, photo: false) %>
```

```erb
<span class="thumb<%= " photo" if photo %>" data-thumbs-target="thumb">
```

`thumbs_controller` replaces only the span's innerHTML, so the class survives the poll.

- [ ] **Step 5: The library wrapper and the inspector aside**

In `files/index.html.erb`, wrap the block that renders the listing (`render "grid"` / `render "list"`,
the empty states and the pager) in:

```erb
<div class="library<%= " has-inspector" if @selected %>" data-controller="selection"
     data-selection-inspector-url-value="<%= inspector_file_path("__ID__") %>">
  <div class="library-main">
    [the listing block, unchanged]
  </div>
  <aside class="inspector" aria-label="Selected file">
    <button type="button" class="btn small icon inspector-close" data-action="selection#close"
            aria-label="Close the inspector">×</button>
    <%= turbo_frame_tag "inspector", src: (@selected && inspector_file_path(@selected)),
                        target: "_top", data: { selection_target: "frame" } %>
  </aside>
</div>
```

`app/javascript/controllers/selection_controller.js`:

```js
import { Controller } from "@hotwired/stimulus"

// CLICK TO SELECT, DOUBLE-CLICK OR ENTER TO OPEN (structural redesign spec §5.1, slice 3).
// A plain click on a FILE tile selects it: `.is-selected` on the tile, `?selected=<id>` in the URL
// (replaceState, so Back leaves the Library instead of stepping through selections, and the next
// page's referer carries the selection), and the inspector frame loads that file's panel.
// EVERYTHING ELSE KEEPS THE LINK'S OWN BEHAVIOUR, which is why the tiles stay `<a href=file_path>`:
// a modifier or middle click opens a tab, Enter (a click whose `detail` is 0) opens the page, a
// double-click opens it, the file menu's Open reads the href, and with JavaScript off every tile is
// just a link. Folders are not items and navigate as links.
export default class extends Controller {
  static targets = ["item", "frame"]
  static values = { inspectorUrl: String }

  connect() {
    this.onKeydown = (event) => this.keydown(event)
    this.element.addEventListener("keydown", this.onKeydown)
  }

  disconnect() {
    this.element.removeEventListener("keydown", this.onKeydown)
  }

  click(event) {
    if (event.detail === 0 || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return
    event.preventDefault()
    this.select(event.currentTarget)
  }

  open(event) {
    event.preventDefault()
    const href = event.currentTarget.getAttribute("href")
    if (window.Turbo) window.Turbo.visit(href)
    else window.location.assign(href)
  }

  select(item) {
    this.itemTargets.forEach((el) => el.classList.toggle("is-selected", el === item))
    const id = item.dataset.selectionId
    const url = new URL(window.location.href)
    url.searchParams.set("selected", id)
    history.replaceState(history.state, "", url)
    this.frameTarget.src = this.inspectorUrlValue.replace("__ID__", encodeURIComponent(id))
    this.element.classList.add("has-inspector")
    item.focus({ preventScroll: true })
  }

  close() {
    this.itemTargets.forEach((el) => el.classList.remove("is-selected"))
    const url = new URL(window.location.href)
    url.searchParams.delete("selected")
    history.replaceState(history.state, "", url)
    this.frameTarget.removeAttribute("src")
    this.frameTarget.replaceChildren()
    this.element.classList.remove("has-inspector")
  }

  // Arrows move the selection in document order; Escape closes. Only while focus is inside the
  // library (the listener is on this element), so arrows still scroll the page elsewhere.
  keydown(event) {
    if (event.key === "Escape" && this.element.classList.contains("has-inspector")) {
      this.close()
      return
    }
    const step = { ArrowRight: 1, ArrowDown: 1, ArrowLeft: -1, ArrowUp: -1 }[event.key]
    if (!step || this.itemTargets.length === 0) return
    const items = this.itemTargets
    const current = items.findIndex((el) => el.classList.contains("is-selected"))
    const next = items[Math.min(items.length - 1, Math.max(0, current === -1 ? 0 : current + step))]
    event.preventDefault()
    this.select(next)
  }
}
```

`pin_all_from` picks the file up, and `test/stimulus_hygiene_test.rb` derives the name.

- [ ] **Step 6: The CSS**

In `app/assets/stylesheets/pages/files.css`, inside its `@layer pages`:

```css
  /* THE LIBRARY AND ITS INSPECTOR (structural redesign §5.1–5.2). Hidden until a file is selected
     (`.has-inspector`, written by the server for `?selected=` and by selection_controller). Docked
     at 1100px and up; sliding over the grid from 720px; a full-screen sheet on a phone. */
  .library { display: grid; grid-template-columns: minmax(0, 1fr); gap: var(--space-5); }
  .inspector { display: none; padding: var(--space-4); background: var(--surface);
               border: 1px solid var(--line); border-radius: var(--radius-panel); }
  .library.has-inspector .inspector { display: block; }
  .inspector-close { float: right; }
  .inspector-head { margin-bottom: var(--space-3); }
  .inspector-head .eyebrow { display: block; font: 600 11px/16px var(--font-ui); letter-spacing: .08em; text-transform: uppercase; color: var(--fg-muted); }
  .inspector-name { font-size: 16px; line-height: 22px; overflow-wrap: anywhere; }
  .inspector-stage .thumb { width: 100%; height: auto; aspect-ratio: 1 / 1; }
  .inspector-actions { display: flex; flex-wrap: wrap; gap: var(--space-2); margin: var(--space-3) 0; }
  .inspector dl.meta { grid-template-columns: max-content minmax(0, 1fr); }
  .inspector-origin, .inspector-notes { margin: var(--space-3) 0 0; font-size: 13px; }
  .grid-card.is-selected .thumb { border-color: var(--fg); box-shadow: 0 0 0 1px var(--fg); }
  table.files tr:has(.is-selected) { background: var(--raised); }
  @media (min-width: 1100px) {
    .library.has-inspector { grid-template-columns: minmax(0, 1fr) 300px; }
    .inspector { position: sticky; top: calc(var(--topbar-height) + var(--space-4)); align-self: start;
                 max-height: calc(100vh - var(--topbar-height) - var(--space-6)); overflow-y: auto; }
  }
  @media (max-width: 1099px) {
    .inspector { position: fixed; z-index: 40; top: var(--topbar-height); right: 0; bottom: 0;
                 width: min(340px, 100vw); overflow-y: auto; border-radius: 0; box-shadow: var(--shadow-float); }
  }
  @media (max-width: 719px) {
    .inspector { top: 0; left: 0; width: 100vw; bottom: var(--tabbar-height); z-index: 50; }
  }
```

- [ ] **Step 7: The system test**

Create `test/system/files_selection_test.rb`. Seed by scanning: write `bracket.stl` (any bytes),
`plate.stl` and `side.jpg` into `@root/legs/`, then run `Library::Scanner.call(@user, root: @root.to_s, max_delete_pct: 100)`
as `test/system/code_theme_test.rb` does.

```ruby
  test "click selects and opens the inspector, Escape closes, reload restores" do
    visit files_path(folder: legs.node_id, view: "grid")
    find(".grid-card", text: "bracket.stl").click
    assert_selector ".library.has-inspector .inspector .inspector-name", text: "bracket.stl"
    assert_includes page.current_url, "selected=#{bracket.node_id}"
    assert_selector ".grid-card.is-selected", text: "bracket.stl"

    visit page.current_url
    assert_selector ".inspector .inspector-name", text: "bracket.stl"

    find(".grid-card", text: "bracket.stl").send_keys(:escape)
    assert_no_selector ".library.has-inspector"
    refute_includes page.current_url, "selected="
  end

  test "double-click opens the page, and Enter on a focused tile opens it too" do
    visit files_path(folder: legs.node_id, view: "grid")
    find(".grid-card", text: "plate.stl").double_click
    assert_current_path file_path(plate.node_id)

    visit files_path(folder: legs.node_id, view: "grid")
    find(".grid-card", text: "plate.stl").send_keys(:enter)
    assert_current_path file_path(plate.node_id)
  end

  test "arrow keys move the selection" do
    visit files_path(folder: legs.node_id, view: "grid")
    find(".grid-card", text: "bracket.stl").click
    find(".grid-card.is-selected").send_keys(:arrow_right)
    assert_selector ".grid-card.is-selected", count: 1
    refute_selector ".grid-card.is-selected", text: "bracket.stl"
  end

  test "at phone width the inspector is a sheet that closes, and nothing scrolls sideways" do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 375, height: 812,
                                    deviceScaleFactor: 1, mobile: false)
    visit files_path(folder: legs.node_id, view: "grid")
    find(".grid-card", text: "bracket.stl").click
    assert_selector ".inspector .inspector-name", text: "bracket.stl"
    assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")
    find(".inspector-close").click
    assert_no_selector ".library.has-inspector"
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end
```

`legs`, `bracket` and `plate` are the scanned nodes, found with
`@user.nodes.find_by!(storage_path: …)` as `code_theme_test` does. Add `assert_no_console_errors` to
each test.

- [ ] **Step 8: Run**

Run: `LIBRARY_PATH=$(mktemp -d) bin/rails test test/models/maker/file_attachment_test.rb test/integration/web/files_selection_test.rb test/system/files_selection_test.rb test/integration/web/file_cell_payload_test.rb test/integration/web/file_menu_wiring_test.rb test/integration/web/addon_origin_surfaces_test.rb test/integration/web/files_sort_test.rb test/integration/web/files_type_filter_test.rb test/integration/web/files_search_test.rb test/integration/web/files_pagination_test.rb test/integration/web/folder_nav_test.rb test/integration/web/files_toolbar_test.rb test/integration/web/template_hygiene_test.rb test/stimulus_hygiene_test.rb test/integration/web/page_query_budget_test.rb test/system/file_menu_test.rb test/system/files_pages_test.rb test/system/shell_test.rb test/system/accent_spend_test.rb`
Expected: PASS.

- [ ] **Step 9: Mutation-check** — report actual output.

1. In `selection_controller.js#click`, drop the `event.detail === 0` guard. Expected: "Enter on a
   focused tile opens it" is red.
2. Drop `history.replaceState` from `select`. Expected: the reload test is red.
3. In `with_selection`, replace the action instead of appending. Expected: `file_menu_wiring_test`
   or the items test is red, because the file menu's action is lost.
4. Remove `&& n.file?` from `@selected`. Expected: the folder case of "a stale … selection" is red.
5. Drop `photo:` from the grid's `_thumb` render. Expected: the photo test is red.

- [ ] **Step 10: Commit**

Subject: `Click selects a file and its inspector opens beside the Library; photos fill their tiles`.

---

### Task 4: Record the slice

- [ ] **Step 1:** In `docs/invariants/files-preview.md`, add a section **"The inspector"** with these
  rules, one paragraph each:
  - it is one node's frame body, rendered without the layout, constant in N;
  - it asks `current_thumbnail` (an existing row first), never `Enqueue.call` directly;
  - its preview polls in swap mode, never reload mode;
  - it targets `_top`;
  - a missing node answers a frame (`inspector_gone`), never the controller's redirect;
  - `PHOTO_EXTS` is a display subset of the image role.
- [ ] **Step 2:** In the spec, under §11's table, add an amendment paragraph recording decisions 1
  (inspector actions), 2 (notes as a link), 4 (back to folder is the breadcrumb) and 5 (the side
  column is not collapsible, with the viewer reason).
- [ ] **Step 3:** Run `test/docs_hygiene_test.rb`, then commit:
  `The preview invariants record the inspector, and the spec what slice 3 deferred`.

### Task 5: Close out

- [ ] Run bare `bin/ci`. All gates must be green, and the three backend legs must report identical
  run counts.
- [ ] `/finish-branch`, then `bin/log arc --from-pr <n>`, and `bin/log close <n>` at merge.
