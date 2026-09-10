# Files-page affordances — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: this repo's `.claude/commands/execute-plan.md` is the
> DEFAULT and overrides any generic subagent loop (CLAUDE.md §15). Batch by FILE, run independent
> tasks in PARALLEL, no spec-compliance stage, cap each quality review to named claims. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the Files page the four affordances a maker asked for — a Back control that is not
inert, Delete on the right-click menu, a text file you can create and edit outside a git repository,
and a folder you can delete on every backend.

**Architecture:** Two halves that ship independently. **Slices 1–2** are the web surface: a shared JS
module, a helper, a Stimulus controller, one new controller and two `FilesController` predicates.
**Slices 3–4** are the `FileLayer` port: `Share#delete` and `S3#delete` learn directories, the
subtree tombstone becomes part of the delete, and `dir_deletable` is removed once no backend refuses.

**Tech Stack:** Rails 8, Hotwire/Stimulus, vanilla ES modules under `app/javascript/`, Minitest
(request + system tiers), `bin/ci` (7 gates, three `LIBRARY_BACKEND` legs).

**Spec:** `docs/superpowers/specs/2026-09-10-files-page-affordances-design.md`

---

## Before you start

```bash
# Branch off main, and note the sibling the chunk_remote leg needs.
git fetch origin main && git checkout -B claude/files-affordances origin/main
gh repo clone chaim354/tinkerex-sync ../tinkerex-sync   # if absent
```

Bare `bin/ci` needs `TINKEREX_SYNC_DIR` when you are in a worktree:

```bash
TINKEREX_SYNC_DIR=/Users/charlesschwartz/Desktop/repos/tinkerex-sync bin/ci
```

A bare `bin/rails test` needs `LIBRARY_PATH` or it reports ~187 errors that are not yours:

```bash
d=$(mktemp -d) && LIBRARY_BACKEND=share LIBRARY_PATH="$d" bin/rails test
```

**Every guard here is mutation-checked (§15).** After a test that forbids something goes green,
break the thing it guards, confirm RED, restore. Name the mutation and its **actual output** in the
PR. Clear `tmp/cache/bootsnap*` after restoring an equal-length mutation.

---

## File structure

| file | responsibility | slice |
|---|---|---|
| `app/javascript/lib/file_chooser.js` | the Miller-columns browser, both faces | 1 |
| `app/helpers/files_helper.rb` | `file_menu_data` — the menu's server-written payload | 1 |
| `app/javascript/controllers/filemenu_controller.js` | builds the right-click menu | 1 |
| `app/views/files/_list.html.erb`, `_grid.html.erb` | where folders get the menu | 1 |
| `app/controllers/files/text_files_controller.rb` | **new** — create an empty text file | 2 |
| `app/views/files/text_files/new.html.erb` | **new** — the name form | 2 |
| `app/controllers/files_controller.rb` | `@editable`, `#update`'s refusal | 2 |
| `app/views/files/_editor.html.erb` (or its current home) | the no-history note | 2 |
| `app/services/file_layer/share.rb` | `deletable_file!`, `delete`, `undelete` | 3 |
| `app/services/file_layer/subtree.rb` | **new** — the descendant walk both adapters share | 3 |
| `app/services/file_layer/s3.rb` | `delete` over a prefix, the cap | 4 |
| `app/services/file_layer/capabilities.rb` | `dir_deletable` removed | 4 |

---

# HALF ONE — the web surface (slices 1–2)

## Task 1: The Back control disappears at the top level

**Files:**
- Modify: `app/javascript/lib/file_chooser.js:192-207` (`render()`)
- Test: `test/system/repo_browser_test.rb`

- [ ] **Step 1: Write the failing test**

Append inside `RepoBrowserTest` (it already has a repository fixture; reuse its `setup`):

```ruby
  # THE CONTROL WAS RENDERED LIVE AND INERT AT THE ROOT. `back()` opens with
  # `if (this.trail.length === 0) return`, so at a repository's top level the button was focusable,
  # styled as available, and did nothing — the "looks available, is absent" shape §14d records for
  # an unresolvable Stimulus identifier, with the added cost that here the user can see it.
  #
  # A SYSTEM TEST BECAUSE ONLY A BROWSER KNOWS WHETHER A CONTROL IS VISIBLE. `assert_select` asks
  # about elements in a document; this is about a rendered box.
  test "the browser offers no Back at the repository root, and does below it" do
    visit project_path(@project)
    open_repo_browser   # the existing helper in this file; see its own setup

    assert_selector ".filechooser-crumbs", text: @repo_dir.name,
                    wait: 5 # the columns arrive from LibraryBrowseController#children
    assert_no_selector ".filechooser-back", visible: true

    find(".filechooser-col .filechooser-row", text: "src").click
    assert_selector ".filechooser-crumbs", text: "src"
    assert_selector ".filechooser-back", visible: true

    find(".filechooser-back").click
    assert_selector ".filechooser-crumbs", text: @repo_dir.name
    assert_no_selector ".filechooser-back", visible: true
    assert_no_console_errors
  end
```

If `open_repo_browser` does not exist in that file, add it there rather than inline:

```ruby
  def open_repo_browser
    find("summary", text: "Files").click unless page.has_selector?(".repo-browser [data-filebrowser-target='mount'] .filechooser")
    assert_selector ".repo-browser .filechooser"
  end
```

- [ ] **Step 2: Run it and watch it fail**

```bash
d=$(mktemp -d) && LIBRARY_BACKEND=share LIBRARY_PATH="$d" PARALLEL_WORKERS=1 bin/rails test test/system/repo_browser_test.rb -i "/offers no Back/"
```

Expected: FAIL at the first `assert_no_selector ".filechooser-back", visible: true` — the control is
rendered at the root today.

- [ ] **Step 3: Hide it in `render()`, not in the two templates**

In `app/javascript/lib/file_chooser.js`, inside `render()`, immediately after the crumbs line
(currently `:207`):

```js
    this.crumbsEl.textContent = [ this.rootLabel, ...this.trail.map((f) => f.name) ].join("  ›  ")
    // BACK IS OFFERED ONLY WHEN IT CAN ACT. `back()` returns early at `trail.length === 0`, so at
    // the root the control was rendered live and did nothing when clicked. Hidden HERE rather than
    // in the two markup templates because both faces — the modal and the inline browse mount —
    // are drawn by this one method; a fix in a template is a fix for one caller.
    //
    // `el.hidden`, not `style.display`: the house idiom (readme_controller.js, layout_editor_controller.js).
    const backBtn = this.host.querySelector(".filechooser-back")
    if (backBtn) backBtn.hidden = this.trail.length === 0
```

- [ ] **Step 4: Run it and watch it pass**

```bash
d=$(mktemp -d) && LIBRARY_BACKEND=share LIBRARY_PATH="$d" PARALLEL_WORKERS=1 bin/rails test test/system/repo_browser_test.rb
```

Expected: PASS, and every existing test in that file still passes.

- [ ] **Step 5: Mutation-check**

Delete the two lines you just added, re-run, confirm the root assertion reddens with
`expected not to find visible css ".filechooser-back"`. Restore. Record the output for the PR.

- [ ] **Step 6: Commit**

```bash
git add app/javascript/lib/file_chooser.js test/system/repo_browser_test.rb
git commit -m "The browser offers Back only where Back can go"
```

---

## Task 2: `file_menu_data` carries a delete URL, and a folder gets a menu

**Files:**
- Modify: `app/helpers/files_helper.rb:40-46`
- Modify: `app/views/files/_list.html.erb`, `app/views/files/_grid.html.erb`
- Test: `test/integration/web/file_menu_wiring_test.rb`

- [ ] **Step 1: Write the failing test**

Add to `file_menu_wiring_test.rb` (it already sweeps the menu payload's presence):

```ruby
  test "every file row carries a delete url" do
    get files_path
    assert_response :success
    rows = css_select("[data-action*='filemenu#open']")
    refute_empty rows, "no menu-bearing rows rendered — the fixture is not reaching the list"
    rows.each do |row|
      assert row["data-delete-url"].present?,
             "a menu-bearing row has no data-delete-url: #{row["data-node-id"]}"
    end
  end

  test "a folder row carries a menu, holding a delete url and nothing else" do
    # A FOLDER GOT NEITHER MENU NOR THUMB CELL until now. It gains the MENU and still no cell,
    # which makes files_helper's "not co-extensive" comment more true rather than less: a folder
    # has no note popover, no blob to download and no addon origin, so Delete is its whole menu.
    get files_path
    folder = css_select("[data-node-id='#{@folder.node_id}'][data-action*='filemenu#open']").first
    refute_nil folder, "the folder row has no right-click menu"
    assert folder["data-delete-url"].present?, "the folder's menu has no delete url"
    assert_nil folder["data-note-url"], "a folder has no notes"
    assert_nil folder["data-download-url"], "a folder has no blob"
  end
```

- [ ] **Step 2: Run and watch both fail**

```bash
d=$(mktemp -d) && LIBRARY_BACKEND=share LIBRARY_PATH="$d" bin/rails test test/integration/web/file_menu_wiring_test.rb
```

Expected: FAIL — no `data-delete-url` anywhere, and the folder row has no menu at all.

- [ ] **Step 3: Add `delete_url`, and a folder builder beside it**

In `app/helpers/files_helper.rb`, replace `file_menu_data` and add its folder sibling:

```ruby
  def file_menu_data(node_id, origin)
    { action: "contextmenu->filemenu#open",
      note_url: file_notes_path(node_id),
      download_url: blob_file_path(node_id, download: 1),
      delete_url: file_path(node_id),
      addon_open_url: origin&.dig(:url),
      addon_open_label: origin&.dig(:label) }
  end

  # A FOLDER'S MENU IS DELETE ALONE, and it is a separate builder rather than a branch inside the
  # one above because the two payloads share exactly one key. A folder has no note popover, no blob
  # endpoint and no addon origin; handing it `file_menu_data` with four nils would put the decision
  # about what a folder has into the CONTROLLER, which cannot see the node.
  def folder_menu_data(node_id)
    { action: "contextmenu->filemenu#open", delete_url: file_path(node_id) }
  end
```

- [ ] **Step 4: Give folder rows the menu**

In `app/views/files/_list.html.erb` and `app/views/files/_grid.html.erb`, the folder branch (the one
rendering a dir row/tile) gains `data: folder_menu_data(node.node_id)`. Merge it into the existing
`tag.tr(...)` / link `data:` hash exactly as the file branch merges `file_menu_data`.

- [ ] **Step 5: Run and watch both pass**

```bash
d=$(mktemp -d) && LIBRARY_BACKEND=share LIBRARY_PATH="$d" bin/rails test test/integration/web/file_menu_wiring_test.rb
```

- [ ] **Step 6: Commit**

```bash
git add app/helpers/files_helper.rb app/views/files/_list.html.erb app/views/files/_grid.html.erb test/integration/web/file_menu_wiring_test.rb
git commit -m "A row's menu payload carries where to delete it, and a folder has one"
```

---

## Task 3: Delete on the menu, and the gate that would have swallowed it

**Files:**
- Modify: `app/javascript/controllers/filemenu_controller.js:28-84`
- Test: `test/system/file_menu_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
  test "the menu deletes a file, and deletes a folder" do
    visit files_path
    page.driver.browser.action.context_click(find("[data-node-id='#{@node.node_id}']").native).perform
    accept_confirm { find(".file-menu button", text: "Delete").click }
    assert_no_selector "[data-node-id='#{@node.node_id}']"
    assert_no_console_errors
  end
```

- [ ] **Step 2: Run and watch it fail**

```bash
d=$(mktemp -d) && LIBRARY_BACKEND=share LIBRARY_PATH="$d" PARALLEL_WORKERS=1 bin/rails test test/system/file_menu_test.rb -i "/menu deletes/"
```

Expected: FAIL — `Unable to find css ".file-menu button" with text "Delete"`.

- [ ] **Step 3: Widen the gate, then add the item**

`filemenu_controller.js:30` currently reads `if (!noteUrl) return`, which gates **the whole menu** on
the note URL — so a folder carrying only `delete_url` would open nothing. Replace the head of
`open()`:

```js
    const cell = event.currentTarget
    const noteUrl = cell.dataset.noteUrl
    const deleteUrl = cell.dataset.deleteUrl
    // THE GATE ASKS WHETHER THERE IS A MENU TO SHOW, NOT WHETHER THERE ARE NOTES. It read
    // `if (!noteUrl) return` until 2026-09-10, which was correct while every menu-bearing cell was
    // a FILE and every file had notes. A folder has a delete url and nothing else, so the old gate
    // would have opened no menu for it at all — silently, since a contextmenu handler that returns
    // early is indistinguishable from one that never ran.
    if (!noteUrl && !deleteUrl) return
```

Then guard the "Add note" item on `noteUrl` (it is no longer implied):

```js
    if (noteUrl) {
      const add = document.createElement("button")
      add.type = "button"
      add.textContent = "Add note"
      add.addEventListener("click", (e) => { e.stopPropagation(); this.closeMenu(); this.openPopover(noteUrl, event.pageX, event.pageY) })
      this.menu.appendChild(add)
    }
```

And append Delete **last**, after the addon item:

```js
    // DELETE IS LAST AND IS THE ONLY DESTRUCTIVE ITEM. A real DELETE with the CSRF token, not a
    // link: the menu is built in JS, so it assembles the request itself. `confirm` first, with the
    // wording the list row's button_to and the file page's button already use, so the three delete
    // doors agree — a fourth phrasing for one action is the divergence this menu exists to close.
    if (deleteUrl) {
      const name = cell.dataset.nodeName || "this item"
      const del = document.createElement("button")
      del.type = "button"
      del.className = "danger"
      del.textContent = "Delete"
      del.addEventListener("click", (e) => {
        e.stopPropagation()
        this.closeMenu()
        if (!window.confirm(`Delete ${name}?`)) return
        const form = document.createElement("form")
        form.method = "post"
        form.action = deleteUrl
        form.innerHTML =
          `<input type="hidden" name="_method" value="delete">` +
          `<input type="hidden" name="authenticity_token" value="${document.querySelector('meta[name="csrf-token"]')?.content || ""}">`
        document.body.appendChild(form)
        form.submit()
      })
      this.menu.appendChild(del)
    }
```

- [ ] **Step 4: Add `node_name` to both payloads**

The confirm needs a name. In `files_helper.rb`, add `node_name:` to `file_menu_data` and
`folder_menu_data` — both take it as an argument rather than deriving it, matching the
`ext_label` rule already recorded in that file's comments. Update both call sites in
`_list.html.erb` / `_grid.html.erb` to pass `node.name`.

- [ ] **Step 5: Run and watch it pass**

```bash
d=$(mktemp -d) && LIBRARY_BACKEND=share LIBRARY_PATH="$d" PARALLEL_WORKERS=1 bin/rails test test/system/file_menu_test.rb
```

- [ ] **Step 6: Mutation-check, twice**

1. Revert the gate to `if (!noteUrl) return` → the folder-delete assertion reddens (no menu opens).
2. Drop `delete_url` from `file_menu_data` → Task 2's request test reddens naming the row.

Restore both; record actual output.

- [ ] **Step 7: Commit**

```bash
git add app/javascript/controllers/filemenu_controller.js app/helpers/files_helper.rb app/views/files/_list.html.erb app/views/files/_grid.html.erb test/system/file_menu_test.rb
git commit -m "Right-click offers Delete, and a menu opens for a row that only has one"
```

---

## Task 4: Create a text file

**Files:**
- Create: `app/controllers/files/text_files_controller.rb`
- Create: `app/views/files/text_files/new.html.erb`
- Modify: `config/routes.rb`
- Modify: `app/views/files/index.html.erb` (the toolbar action)
- Test: `test/integration/web/text_file_creation_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
require "test_helper"

module Web
  class TextFileCreationTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @root = use_fresh_share_library!
      @user = User.create!(email: "txt@example.com", password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
    end

    teardown { FileLayer.reset!; FileUtils.remove_entry(@root) if @root&.exist? }

    test "it creates an empty file and lands on its page" do
      post files_text_files_path, params: { name: "bench-notes.txt" }
      node = @user.nodes.present.find_by(name: "bench-notes.txt")
      refute_nil node, "no node was created"
      assert_redirected_to file_path(node.node_id)
    end

    test "a reserved name is refused, and nothing is written" do
      # BOTH GUARDS, because a name-minting door asks two questions (§14b): `valid_leaf_name?` for
      # syntax and `ReservedNames.reserved?` for the library's own namespace. The upload door
      # shipped with NEITHER and was the weakest door in the app.
      before = @user.nodes.count
      post files_text_files_path, params: { name: ".trash" }
      assert_response :unprocessable_entity
      assert_equal before, @user.nodes.count, "a refused name still wrote a row"
    end

    test "a traversing name is refused" do
      before = @user.nodes.count
      post files_text_files_path, params: { name: "../escape.txt" }
      assert_response :unprocessable_entity
      assert_equal before, @user.nodes.count
    end
  end
end
```

- [ ] **Step 2: Run and watch all three fail**

```bash
d=$(mktemp -d) && LIBRARY_BACKEND=share LIBRARY_PATH="$d" bin/rails test test/integration/web/text_file_creation_test.rb
```

Expected: FAIL — `files_text_files_path` is undefined.

- [ ] **Step 3: Route it**

In `config/routes.rb`, beside the existing `resources :files`:

```ruby
  # A DOOR OF ITS OWN, not a parameter on FilesController#create. That action's job is bytes off a
  # multipart form and it already carries a batch branch; a create-that-takes-no-bytes riding it
  # would need a third arm with its own refusals. Namespaced under files/ so the two stay visibly
  # related without sharing an action.
  namespace :files do
    resources :text_files, only: %i[new create]
  end
```

- [ ] **Step 4: Write the controller**

```ruby
module Files
  # CREATE AN EMPTY TEXT FILE IN THE FOLDER THE USER IS LOOKING AT, then hand them the editor.
  # The bytes go through the port like every other write (§15) — this writes "" rather than
  # touching the store directly, so share's temp-and-rename and s3's put_object both apply.
  class TextFilesController < ApplicationController
    def new
      @parent_node_id = params[:parent_node_id].presence
    end

    def create
      name = params[:name].to_s.strip
      # TWO QUESTIONS IN THE SAME BREATH (§14b). `valid_leaf_name?` answers syntax; `reserved?`
      # answers the library's own namespace (.trash, .maker-tmp-*, .git, OS clutter). The upload
      # door shipped asking NEITHER and minted a live node named "../../escape.txt".
      unless Maker::MoveNode.valid_leaf_name?(name) && !Library::ReservedNames.reserved?(name)
        return render(:new, status: :unprocessable_entity,
                            alert: "#{name.presence || "That"} is not a name this library can use.")
      end

      result = Maker::TextSave.call(user: current_user, node: nil,
                                    parent_node_id: params[:parent_node_id].presence,
                                    name:, body: "", base_token: nil, repo_root_node_id: nil)
      return render(:new, status: result.status, alert: result.error) unless result.ok

      redirect_to file_path(result.node_id), notice: "Created #{name}."
    end
  end
end
```

- [ ] **Step 5: Write the form**

`app/views/files/text_files/new.html.erb`:

```erb
<% content_for :title, "New text file — Tinkerex" %>

<div class="page-head">
  <h1>New text file</h1>
</div>

<%= form_with url: files_text_files_path, method: :post, class: "settings-form" do |f| %>
  <%= hidden_field_tag :parent_node_id, @parent_node_id %>
  <label class="field">
    <span>Name</span>
    <%= text_field_tag :name, params[:name], placeholder: "notes.txt", autofocus: true %>
  </label>
  <div class="form-actions">
    <%= f.submit "Create", class: "btn primary" %>
    <%= link_to "Cancel", files_path(folder: @parent_node_id), class: "btn ghost" %>
  </div>
<% end %>
```

- [ ] **Step 6: Run and watch all three pass**

```bash
d=$(mktemp -d) && LIBRARY_BACKEND=share LIBRARY_PATH="$d" bin/rails test test/integration/web/text_file_creation_test.rb
```

- [ ] **Step 7: Add the toolbar action**

In `app/views/files/index.html.erb`'s `.page-actions`, beside the uploader — **without `primary`**,
because the Files page already spends its accent on Upload (UI-cohesion decision 3, guarded by
`test/system/accent_spend_test.rb`, which will redden if you make it accent):

```erb
    <%= link_to "New text file", new_files_text_file_path(parent_node_id: @folder&.node_id), class: "btn" %>
```

- [ ] **Step 8: Run the accent guard to confirm you did not spend a second one**

```bash
d=$(mktemp -d) && LIBRARY_BACKEND=share LIBRARY_PATH="$d" PARALLEL_WORKERS=1 bin/rails test test/system/accent_spend_test.rb
```

Expected: PASS. If it fails naming `/files`, you added `primary`.

- [ ] **Step 9: Mutation-check**

Drop `&& !Library::ReservedNames.reserved?(name)` → the reserved-name test reddens. Restore.

- [ ] **Step 10: Commit**

```bash
git add app/controllers/files/text_files_controller.rb app/views/files/text_files config/routes.rb app/views/files/index.html.erb test/integration/web/text_file_creation_test.rb
git commit -m "A text file can be made where you are standing"
```

---

## Task 5: The editor opens outside a repository

**Files:**
- Modify: `app/controllers/files_controller.rb:507` (`@editable`), `:643-646` (`#update`)
- Modify: the editor partial that renders the no-history note
- Test: `test/integration/web/text_file_creation_test.rb`, `test/system/readme_editor_test.rb`

- [ ] **Step 1: Write the failing tests**

Append to `text_file_creation_test.rb`:

```ruby
    test "the editor renders for a text file outside a repository" do
      post files_text_files_path, params: { name: "notes.txt" }
      node = @user.nodes.present.find_by!(name: "notes.txt")
      get file_path(node.node_id)
      assert_response :success
      assert_select "[data-controller~=editor]", 1, "no editor rendered outside a repo"
    end

    test "a save round-trips and the node id survives it" do
      # `replace: true` REUSES THE NODE. A save written as delete-then-create passes any
      # bytes-oriented assertion while orphaning every attachment, BOM link and tag — §14a's
      # landmine, which errors nowhere and logs nothing. The node id is what they are keyed on.
      post files_text_files_path, params: { name: "notes.txt" }
      node = @user.nodes.present.find_by!(name: "notes.txt")
      token = FileLayer.current.stat(@user, node_id: node.node_id).content_token

      patch file_path(node.node_id), params: { content: "bench notes\n", base_token: token }
      assert_response :success

      assert_equal node.node_id, @user.nodes.present.find_by!(name: "notes.txt").node_id
      assert_equal "bench notes\n", FileLayer.current.read(@user, node_id: node.node_id)
    end
```

- [ ] **Step 2: Run and watch both fail**

```bash
d=$(mktemp -d) && LIBRARY_BACKEND=share LIBRARY_PATH="$d" bin/rails test test/integration/web/text_file_creation_test.rb
```

Expected: FAIL — no editor renders, and the PATCH answers 422 *"Only files inside a git repository
can be edited."*

- [ ] **Step 3: Drop the two repo requirements**

`files_controller.rb:507`:

```ruby
    # `@repo_root.present?` WAS A TERM HERE AND IS GONE (2026-09-10). The editor refused anything
    # outside a working tree because git was the undo; the trade is now NAMED on the editor instead
    # — see the no-history note below — which is the same choice the project README door already
    # made. `@repo_root` still decides whether a save records a pending git edit, and still does so
    # by being nil, so nothing branches.
    @editable = @kind == :text && editable?(@node)
```

`files_controller.rb:646` — delete the line:

```ruby
    return render_save_error(:unprocessable_entity, "Only files inside a git repository can be edited.") if root.nil?
```

`root` stays, and is still passed as `repo_root_node_id:` — nil outside a repository, unchanged
inside one.

- [ ] **Step 4: Add the no-history note**

In the editor partial, above the editor:

```erb
<%# THE TRADE, NAMED WHERE IT IS TAKEN. Outside a repository there is no undo: this save replaces
    the file. Keyed on `versioned?`, so chunk_remote — where the sync server keeps versions — shows
    nothing, and share and s3 show it. A note that renders everywhere is the same defect as one
    that renders nowhere. This sentence is load-bearing; do not drop it in a restyle. %>
<% unless capabilities.versioned? %>
  <p class="muted editor-note">This library keeps no history for this file; saving replaces it.</p>
<% end %>
```

- [ ] **Step 5: Guard the note's absence on chunk_remote**

```ruby
    test "the no-history note names the trade on share and says nothing on chunk_remote" do
      post files_text_files_path, params: { name: "notes.txt" }
      node = @user.nodes.present.find_by!(name: "notes.txt")
      get file_path(node.node_id)
      if FileLayer.current.capabilities.versioned?
        assert_select ".editor-note", 0, "a versioned library must not claim it keeps no history"
      else
        assert_select ".editor-note", 1
      end
    end
```

- [ ] **Step 6: Run all three legs — this task is the one that can diverge**

```bash
d=$(mktemp -d) && LIBRARY_BACKEND=share LIBRARY_PATH="$d" bin/rails test test/integration/web/text_file_creation_test.rb
TINKEREX_SYNC_DIR=/Users/charlesschwartz/Desktop/repos/tinkerex-sync bin/ci test-chunk-remote
```

- [ ] **Step 7: Mutation-check**

Restore `@repo_root.present?` in `@editable` → the editor-renders test reddens. Restore.

- [ ] **Step 8: Commit**

```bash
git add app/controllers/files_controller.rb app/views/files test/integration/web/text_file_creation_test.rb
git commit -m "A text file is editable where the library keeps no history, and says so"
```

---

## Task 6: Ship half one

- [ ] **Step 1: Full gates**

```bash
TINKEREX_SYNC_DIR=/Users/charlesschwartz/Desktop/repos/tinkerex-sync bin/ci
```

All seven green; `test`, `test-s3`, `test-chunk-remote` must print **identical run counts**.

- [ ] **Step 2: PR and arc**

```bash
git push -u origin claude/files-affordances
gh pr create --base main --title "The Files page gets Delete, a text file, and a Back that can go somewhere"
bin/log arc --from-pr <n>
```

---

# HALF TWO — the FileLayer port (slices 3–4)

> Ships separately. Do not start until half one is merged: Task 3's folder menu is what makes a
> folder delete reachable, and shipping the port change first would put a working delete behind a
> menu nobody can open.

## Task 7: The descendant walk, shared by both adapters

**Files:**
- Create: `app/services/file_layer/subtree.rb`
- Test: `test/services/file_layer/subtree_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
require "test_helper"

class FileLayer::SubtreeTest < ActiveSupport::TestCase
  setup do
    @root = use_fresh_share_library!
    @user = User.create!(email: "sub@example.com", password: "correct horse battery staple",
                         confirmed_at: Time.current)
  end
  teardown { FileLayer.reset!; FileUtils.remove_entry(@root) if @root&.exist? }

  test "it walks by parent_node_id, not by storage_path" do
    # BY PARENT, NOT BY PATH. `move` rewrites only the moved node's own row, so a moved directory's
    # descendants keep a STALE storage_path until the next scan pairs them — a prefix walk would
    # miss exactly the children most likely to be mid-reorganisation. The parent edge is always
    # accurate in the catalog.
    dir  = create_node!(@user, node_id: "d1", name: "parts", kind: "dir", parent_node_id: nil)
    sub  = create_node!(@user, node_id: "d2", name: "stl", kind: "dir", parent_node_id: "d1")
    leaf = create_node!(@user, node_id: "f1", name: "a.stl", kind: "file", parent_node_id: "d2")
    leaf.update!(storage_path: "somewhere/else/entirely/a.stl")

    ids = FileLayer::Subtree.node_ids(@user, "d1")
    assert_equal %w[d1 d2 f1].sort, ids.sort
  end

  test "a tombstoned descendant is included, so a re-delete cannot strand it" do
    create_node!(@user, node_id: "d1", name: "parts", kind: "dir", parent_node_id: nil)
    gone = create_node!(@user, node_id: "f1", name: "old.stl", kind: "file", parent_node_id: "d1")
    gone.update!(deleted: true, storage_path: nil)
    assert_includes FileLayer::Subtree.node_ids(@user, "d1"), "f1"
  end
end
```

- [ ] **Step 2: Run and watch it fail**

```bash
d=$(mktemp -d) && LIBRARY_BACKEND=share LIBRARY_PATH="$d" bin/rails test test/services/file_layer/subtree_test.rb
```

Expected: FAIL — `uninitialized constant FileLayer::Subtree`.

- [ ] **Step 3: Write it**

```ruby
module FileLayer
  # EVERY NODE AT OR BENEATH A DIRECTORY, walked by the parent edge.
  #
  # WHY THIS EXISTS AS ONE THING: share and s3 move bytes completely differently — one rename
  # against one copy-and-delete per object — but they must tombstone exactly the same set, and a
  # second copy of this walk is a second chance to tombstone a subset. A live node left pointing at
  # a path now inside `.trash` is §14b's skip-list wedge: the scan refuses to look there, nothing
  # can ever pair it, and the resulting tombstone trips the mass-deletion guard — refusing that scan
  # and every scan after it, permanently.
  #
  # ADAPTER-AGNOSTIC SQL: iterative, not a recursive CTE, because this codebase runs on SQLite and
  # Postgres and keeps no PG-only SQL in a hot path (§14e). Levels, not rows: a 3-deep folder is 3
  # queries whatever its width.
  module Subtree
    # A cap on DEPTH, not on size — a cycle in `parent_node_id` would otherwise loop forever, and
    # the catalog has no constraint forbidding one (the same reason LibraryTree#path_for carries a
    # cycle guard, docs/invariants/model-intake.md).
    MAX_DEPTH = 64

    def self.node_ids(user, root_node_id)
      ids = [ root_node_id.to_s ]
      frontier = ids.dup
      MAX_DEPTH.times do
        break if frontier.empty?
        frontier = user.nodes.where(parent_node_id: frontier).pluck(:node_id)
        ids.concat(frontier)
      end
      ids.uniq
    end
  end
end
```

- [ ] **Step 4: Run and watch both pass, then commit**

```bash
d=$(mktemp -d) && LIBRARY_BACKEND=share LIBRARY_PATH="$d" bin/rails test test/services/file_layer/subtree_test.rb
git add app/services/file_layer/subtree.rb test/services/file_layer/subtree_test.rb
git commit -m "One walk of a directory's nodes, by the edge that is always accurate"
```

---

## Task 8: Share deletes a directory

**Files:**
- Modify: `app/services/file_layer/share.rb:363-411` (`delete`), `:633-642` (`deletable_file!`), `undelete`
- Test: `test/services/file_layer/share_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
  test "deleting a directory moves it whole and tombstones every node under it" do
    # `make_dir` / `make_file` are this file's OWN hooks (share_test.rb:20-24) and each returns a
    # NODE ID, not a node. They go through the port's own write/mkdir, which is the point — a
    # fixture built with `nodes.create!` has a NULL storage_path, which cannot exist on share.
    dir_id  = make_dir(name: "parts")
    leaf_id = adapter.write(@user, parent_node_id: dir_id, name: "a.stl",
                            io: StringIO.new("solid a\n")).node_id

    adapter.delete(@user, node_id: dir_id)

    # THE WEDGE ASSERTION, and it is the point of this test. A live node whose storage_path points
    # inside `.trash` can never be paired by a scan — the scan refuses to look there — so the next
    # reconcile tombstones it as vanished and the mass-deletion guard refuses that scan AND EVERY
    # SCAN AFTER IT. Asserting the directory alone is tombstoned would pass over exactly that.
    assert @user.nodes.find_by!(node_id: dir_id).deleted?
    assert @user.nodes.find_by!(node_id: leaf_id).deleted?, "a child survived as a live node"
    assert_nil @user.nodes.find_by!(node_id: leaf_id).storage_path

    refute Dir.exist?(@root.join("parts")), "the directory is still at its old path"
    assert Dir.exist?(@root.join(".trash", dir_id, "parts")), "the bytes are not in .trash"
  end

  test "restoring a directory returns the subtree with the same node ids" do
    dir_id  = make_dir(name: "parts")
    leaf_id = adapter.write(@user, parent_node_id: dir_id, name: "a.stl",
                            io: StringIO.new("solid a\n")).node_id
    adapter.delete(@user, node_id: dir_id)
    adapter.undelete(@user, node_id: dir_id)

    assert @user.nodes.present.exists?(node_id: dir_id)
    assert @user.nodes.present.exists?(node_id: leaf_id),
           "the child came back as a new node — every attachment on it is now orphaned"
    assert_equal "solid a\n", adapter.read(@user, node_id: leaf_id)
  end
```

- [ ] **Step 2: Run and watch both fail**

Expected: FAIL with `UnsupportedOperation` — *"share-mode delete is files only"*.

- [ ] **Step 3: Retire the refusal**

Delete `deletable_file!` and its call in `delete`. Leave a note where it stood:

```ruby
    # `deletable_file!` STOOD HERE AND IS GONE (2026-09-10). It refused a directory because moving
    # one into `.trash` stranded its children at paths that no longer exist — the wedge §14b
    # describes. What made it safe to remove is the SUBTREE TOMBSTONE below, not the rename: the
    # rename was always atomic and always correct; it was the catalog that was left inconsistent.
```

- [ ] **Step 4: Tombstone the subtree instead of the node**

Replace `node.update!(deleted: true, storage_path: nil)` with:

```ruby
      # EVERY NODE AT OR BENEATH IT, IN ONE TRANSACTION. `storage_path: nil` on all of them for the
      # reason the single-node version already gives: Reconciler#create_or_revive! revives a
      # tombstone BY storage_path, so a trash tombstone that kept its path would hand a new,
      # unrelated file the trashed node's node_id along with every attachment on it.
      ids = FileLayer::Subtree.node_ids(user, node.node_id)
      user.nodes.where(node_id: ids).update_all(deleted: true, storage_path: nil, updated_at: Time.current)
      nil
```

- [ ] **Step 5: Make `undelete` revive the subtree**

After its rename-back, revive by the same walk, restoring each node's `storage_path` from its
position under the restored root. The root's own path is known; a descendant's is its parent's path
plus its name, walked top-down in the same level order `Subtree` produces.

- [ ] **Step 6: Run, then run all three legs**

```bash
d=$(mktemp -d) && LIBRARY_BACKEND=share LIBRARY_PATH="$d" bin/rails test test/services/file_layer/share_test.rb
TINKEREX_SYNC_DIR=/Users/charlesschwartz/Desktop/repos/tinkerex-sync bin/ci
```

- [ ] **Step 7: Mutation-check, twice**

1. Tombstone only `node` (drop the `Subtree` call) → the wedge assertion reddens on the child.
2. Tombstone **before** the rename → the resurrect assertion reddens (the next scan revives it).

- [ ] **Step 8: Commit**

```bash
git add app/services/file_layer/share.rb test/services/file_layer/share_test.rb
git commit -m "A share folder goes to the trash whole, catalog and all"
```

---

## Task 9: S3 deletes a prefix, up to a cap

**Files:**
- Modify: `app/services/file_layer/s3.rb`
- Test: `test/services/file_layer/s3_test.rb`

- [ ] **Step 1: Write the failing tests**

```ruby
  # `@fake.objects` IS THE STORE, keyed by the FULL key including PREFIX (s3_test.rb:37-43, and
  # `seed!` at :92 shows the shape). Asserting on it rather than on a helper means these read the
  # WIRE FORMAT — §14e's FakeS3 lesson is that a fake sharing the adapter's misunderstanding
  # confirms it, so a key assertion must be spelled the way the bucket would see it.
  def stored?(key) = @fake.objects.key?("#{PREFIX}/#{key}")

  test "deleting a directory copies every object to .trash, then deletes, then tombstones" do
    dir_id  = make_dir(name: "parts")
    leaf_id = adapter.write(@user, parent_node_id: dir_id, name: "a.stl",
                            io: StringIO.new("solid a\n")).node_id
    adapter.delete(@user, node_id: dir_id)

    assert @user.nodes.find_by!(node_id: leaf_id).deleted?
    assert_nil @user.nodes.find_by!(node_id: leaf_id).storage_path
    refute stored?("parts/a.stl"), "the source object survived"
    assert stored?(".trash/#{dir_id}/parts/a.stl"), "no copy reached .trash"
  end

  test "a name with a space survives the round trip" do
    # THE 79-of-80 CASE, ASSERTED DIRECTLY. FakeS3 once decoded copy_source with CGI.unescape while
    # the adapter encoded with CGI.escape — exact inverses, so the suite was green over silent
    # permanent data loss on any filename containing a space (§14e). A folder delete is a copy per
    # object, so it walks straight into it.
    dir_id = make_dir(name: "parts")
    adapter.write(@user, parent_node_id: dir_id, name: "Bracket v2.stl", io: StringIO.new("x"))
    adapter.delete(@user, node_id: dir_id)

    refute stored?("parts/Bracket v2.stl"), "the source object survived"
    assert stored?(".trash/#{dir_id}/parts/Bracket v2.stl"), "the copy did not land under its real name"
  end

  test "over the cap it refuses and writes nothing" do
    dir_id = make_dir(name: "parts")
    (FileLayer::S3::DIR_DELETE_MAX_OBJECTS + 1).times do |i|
      adapter.write(@user, parent_node_id: dir_id, name: "f#{i}.stl", io: StringIO.new("x"))
    end

    assert_raises(FileLayer::UnsupportedOperation) { adapter.delete(@user, node_id: dir_id) }
    refute @user.nodes.find_by!(node_id: dir_id).deleted?, "a refused delete tombstoned anyway"
    assert stored?("parts/f0.stl"), "a refused delete moved bytes"
  end
```

- [ ] **Step 2: Run and watch both fail**

- [ ] **Step 3: Implement the sequence**

```ruby
    # A CAP, NOT A JOB. Each object costs a COPY plus a DELETE — two billed requests — so a folder
    # of 5,000 is 10,000 and will exhaust the request before it exhausts the folder. Refusing above
    # the cap keeps the ordering guarantee below intact; a background job would have to decide what
    # the catalog says while it runs, which is the landmine spread across time. Lifting this is
    # named follow-on work.
    DIR_DELETE_MAX_OBJECTS = 500
```

and, in `delete`'s directory branch:

```ruby
      # ORDER IS THE WHOLE DESIGN: copy ALL, then delete ALL, then tombstone. §14a's landmine is a
      # delete failing AFTER a tombstone — the next scan finds an unclaimed key with no tombstone to
      # revive by path, mints a NEW node_id, and orphans every attachment, by a scan that did
      # nothing wrong, with no error anywhere. A failure at any stage leaves the catalog untouched.
      #
      # PER-SEGMENT `ERB::Util.url_encode`, never CGI.escape: §14e records FakeS3 sharing the
      # adapter's inverse-encoding misunderstanding and hiding silent permanent data loss on any
      # filename with a SPACE behind 79 of 80 green tests. Assert the WIRE format.
```

- [ ] **Step 4: Run, mutation-check**

1. Move the tombstone before the deletes → assert the orphan case reddens.
2. Raise the cap past the fixture → the refusal test reddens.

- [ ] **Step 5: Commit**

```bash
git add app/services/file_layer/s3.rb test/services/file_layer/s3_test.rb
git commit -m "An s3 folder goes to the trash object by object, or not at all"
```

---

## Task 10: `dir_deletable` goes

**Files:**
- Modify: `app/services/file_layer/capabilities.rb`, `share.rb`, `s3.rb`, `chunk_remote.rb`
- Modify: `app/controllers/files_controller.rb` (the comment at `:965`)
- Modify: `test/services/file_layer/adapter_mutation_contract.rb:31,43,173`
- Modify: `test/integration/chunk_remote_journey_test.rb:166,204`
- Modify: `CLAUDE.md` §14a

- [ ] **Step 1: Remove the member and every gate**

Delete `dir_deletable` from the `Capabilities` struct, its `dir_deletable?` reader, and the keyword
from all three adapters. In `adapter_mutation_contract.rb`, the three gated blocks become
unconditional — **which is the point**: a directory delete is now part of the shared contract every
backend answers.

- [ ] **Step 2: Rename the two tests that explain a deleted concept**

`chunk_remote_journey_test.rb:166` is titled *"a directory delete cascades, because dir_deletable is
true on chunk_remote"*. Retitle to *"a directory delete cascades on the sync server"* and rewrite
`:204`'s assertion message. A test whose name explains a concept that no longer exists is the
stale-ledger problem §15 records, in a place no gate reads.

- [ ] **Step 3: Rewrite §14a's bullet**

Replace the `dir_deletable` bullet with a note recording that directories were refused on share/s3
until 2026-09-10, why (the wedge), and what each backend does now — plus the rule that survives:
**`delete` on a directory must reach a CASCADE, never a per-node tombstone.**

- [ ] **Step 4: Full gates, then ship**

```bash
TINKEREX_SYNC_DIR=/Users/charlesschwartz/Desktop/repos/tinkerex-sync bin/ci
git commit -am "A capability nothing varies is a lie about the shape of the port"
git push && gh pr create --base main --title "A folder can be deleted on every backend"
bin/log arc --from-pr <n>
```

---

## Self-review notes

**Spec coverage.** A → Task 1. B → Tasks 2–3. C → Tasks 4–5. D-share → Tasks 7–8. D-s3 → Task 9.
Capability removal → Task 10. The cap constant, the encoding rule and the ordering rule each have a
task step that names them.

**One thing the spec did not anticipate**, found while reading for this plan and folded into Task 3:
`filemenu_controller.js` opens with `if (!noteUrl) return`, which gates **the whole menu** on the
note URL. A folder carrying only `delete_url` would have opened nothing, silently — a contextmenu
handler that returns early is indistinguishable from one that never ran. The spec's Task-B section
assumed adding an item was enough; it is not.

**Naming consistency.** `FileLayer::Subtree.node_ids(user, root_node_id)` is the one signature, used
identically in Tasks 8 and 9. `DIR_DELETE_MAX_OBJECTS` is the one constant name.
