# Reusable file chooser + Box Generator save UI

**Date:** 2026-07-22
**Status:** approved (design)
**Scope:** a new **reusable, session-authed folder/file chooser** for the web UI (one Stimulus
controller + one trigger partial + CSS + one small browse controller with two JSON endpoints +
one thin `Maker::LibraryFolder` helper), and rewiring the **Box Generator** save UI to use it.
No sync/file-layer changes beyond going through the existing `Maker::LibraryFolder` seam and
`Node#children` (§10 tripwire respected). No sidecar changes. No change to the box *save* flow
itself — the server already reads `params[:parent_node_id]`.

## Problem

The Box Generator's "save to" control (`app/views/tools/boxes/new.html.erb`) is:

1. **A flat `<select>`** populated by `BoxesController#folder_options`, which pre-flattens every
   one of the user's folders into one long list of `["/A/B/C", node_id]` pairs. No navigation, no
   sense of the tree, no way to create a folder.
2. **Placed at the top of the form**, far from the "Save to library" button at the bottom — you
   pick the destination, fill a long param form, then commit from somewhere else entirely.

The user wants the destination control **moved next to the Save button** and upgraded to a
**full file chooser that feels like a native OS one** — and that chooser should be a **separate,
reusable component the rest of the app can use** (e.g. the project "Attach a file" flow, a future
"move to" action).

## Decisions (settled during brainstorming)

- **Dual-mode.** One component that works as a "Save" panel (**folder-pick**) and an "Open" panel
  (**file-pick**). Box Generator uses folder-pick. File-pick is built into the component but not
  wired to any consumer yet (the project attach flow is the obvious future consumer).
- **Miller columns** (macOS Finder style): selecting a folder opens its children in the next
  column to the right. **Mobile fallback:** below a width breakpoint, show only the deepest column
  with a ← back control (single-column drill-down).
- **Modal presentation.** Native file dialogs are modal windows, and Miller columns want the
  horizontal room. The modal is built on demand by the Stimulus controller and appended to
  `<body>`, so a consuming page needs no per-page modal markup.
- **Trigger = a single button** showing the current destination path (📁 + caret), placed next to
  Save. Clicking it opens the modal. Styled distinctly from the primary Save button so it doesn't
  read as "save now".
- **New Folder** button in the modal footer (native Save panels have one; the backend already
  supports cross-backend `mkdir`).
- **Build:** Stimulus controller renders the modal client-side from a small session-authed JSON
  endpoint — navigation must not reload the page, or the half-filled box form is lost.

## Architecture

Four new units, each with one job, plus one box-view rewire.

### 1. `LibraryBrowseController` — the generic data source

`app/controllers/library_browse_controller.rb`, session-authed (`authenticate_user!`),
user-scoped. Not box-specific; lives at a neutral route so any consumer can use it.

- **`GET /library/children?parent=<node_id>&files=0|1`** → JSON:
  ```json
  {
    "parent":  "<node_id or null for root>",
    "crumbs":  [{"node_id": "...", "name": "Projects"}, {"node_id": "...", "name": "Enclosure v2"}],
    "entries": [{"node_id": "...", "name": "exports", "kind": "dir"},
                {"node_id": "...", "name": "notes.txt", "kind": "file"}]
  }
  ```
  - Entries come from `current_user.nodes.present` under the given parent (the same shared catalog
    `FilesController#index` browses, via `Node#children`), sorted dirs-first then name.
  - Folders are always included; **files only when `files=1`** (folder-pick mode omits them).
  - **`parent` is validated to belong to the user**, exactly like today's `chosen_parent_node_id`
    (a foreign/forged/stale id resolves to root or an empty list — never another user's tree).
  - `crumbs` are built by climbing `parent_node_id` in Ruby over the user's own dirs (mirrors the
    breadcrumb logic already in `FilesController`), so nothing trusts the raw param twice.

- **`POST /library/folders`** (`parent_node_id`, `name`) → creates **one** child directory and
  returns its node JSON (`{node_id, name, kind}`). Powers "New Folder" live (the UI inserts the
  returned node into the current column and selects it). Validates the parent is the user's own
  dir; blank/duplicate name handling returns a 422 with a message the modal can show.

Routes:
```ruby
get  "library/children", to: "library_browse#children"
post "library/folders",  to: "library_browse#create_folder"
```

### 2. `Maker::LibraryFolder.create_child!` — the one mkdir seam

The New Folder endpoint must **not** reach into `Sync::` or the port directly (that is exactly the
§10 tripwire). `Maker::LibraryFolder` already owns the cross-backend create branch
(`port_writable?` → `FileLayer.current.mkdir`; else `Sync::Mutation.apply(op: "mkdir")`) but only
exposes `ensure_path!(segments)` from root. Add a thin public method for single-child creation
under an arbitrary parent, wrapping the existing private `ensure_segment`:

```ruby
def self.create_child!(user, parent_node_id:, name:)
  new(user).send(:ensure_segment, parent_node_id, name)  # or promote ensure_segment to public
end
```

Find-or-create semantics are inherited (an existing folder of that name is returned, not
duplicated), which is the right behavior for a New Folder button too.

### 3. `filechooser` Stimulus controller — the reusable modal

`app/javascript/controllers/filechooser_controller.js`.

- **Values:** `mode` (`"folder"` | `"file"`, default `"folder"`), `childrenUrl`, `createUrl`,
  `rootLabel` (default `"/ (library root)"`), `value` (initial selected node_id, may be blank),
  `label` (initial button text).
- **Trigger:** the controller is attached to the trigger element (see partial). A click opens the
  modal. The controller lazily builds the modal DOM (overlay + title + columns strip + footer with
  New Folder / selected-path / Cancel / Choose) and appends it to `<body>`.
- **Navigation:** opening loads the root column via `GET childrenUrl` (with `files=1` in file
  mode). Selecting a folder in column *n* loads its children into column *n+1* and drops any
  columns to the right; the breadcrumb mirrors the path to the deepest selected column. Columns
  strip is `overflow-x:auto` and auto-scrolls right as it deepens.
- **Selection model** (one rule, both modes: a single click **highlights** an entry; a folder
  click *additionally* opens its children in the next column):
  - folder-pick: the selected destination is the currently highlighted folder. Opening the modal
    highlights **root**; clicking a folder highlights it *and* drills in, so "just navigating"
    and "selecting" are the same gesture and there is always a valid selection (root at minimum).
    "Choose" is always enabled. Files are not shown.
  - file-pick: clicking a folder navigates (highlights the *column*, not a selection); clicking a
    file highlights it. "Open" is enabled only when a file is highlighted.
- **New Folder:** reveals an inline text input **in the modal footer**; on submit `POST createUrl`,
  then inserts the returned node into the current (deepest) column and highlights it.
- **Result:** on Choose, the controller
  1. writes the chosen `node_id` into the trigger's hidden `<input>` (for form submission), and
     updates the trigger button label to the chosen path;
  2. dispatches a `filechooser:choose` `CustomEvent` on the trigger element with
     `detail: { nodeId, kind, path }` (for JS-driven, non-form consumers);
  3. closes the modal.
- **Close:** Cancel, backdrop click, or Esc closes without changing the value. Focus is trapped in
  the modal while open and restored to the trigger on close (a11y).
- **Mobile:** under a CSS width breakpoint the strip shows only the deepest column plus a ← back
  affordance; the controller tracks a "visible column" index for narrow viewports.

### 4. `shared/_folder_field` — the form trigger partial

`app/views/shared/_folder_field.html.erb`. Renders a `<button type="button">` (so it never submits
the host form) wired to the `filechooser` controller, plus a hidden `<input>`.

Locals: `name:` (hidden input name, e.g. `"parent_node_id"`), `mode:` (default `"folder"`),
`value:` (initial node_id, default `nil`), `label:` (initial button text, default the root label),
`children_url:`, `create_url:`, `root_label:` (optional).

```erb
<%= tag.div class: "folder-field",
      data: { controller: "filechooser",
              filechooser_mode_value: mode, filechooser_children_url_value: children_url,
              filechooser_create_url_value: create_url,
              filechooser_root_label_value: (root_label || "/ (library root)"),
              filechooser_value_value: value, filechooser_label_value: (label || root_label) } do %>
  <button type="button" class="folder-field-btn" data-action="filechooser#open"
          data-filechooser-target="button">📁 <%= label || root_label %> ▾</button>
  <%= hidden_field_tag name, value, data: { filechooser_target: "input" } %>
<% end %>
```

### 5. Box Generator rewire (the visible task)

- `app/views/tools/boxes/new.html.erb`: **remove** the top `"Save to folder"` `<label>` +
  `select_tag :parent_node_id` block. In `.page-actions`, between Preview and Save, render:
  ```erb
  <%= render "shared/folder_field", name: "parent_node_id", mode: "folder",
             value: nil, label: "/ (library root)",
             children_url: library_children_path, create_url: library_folders_path %>
  ```
- `app/controllers/tools/boxes_controller.rb`: `create`/`chosen_parent_node_id` already read and
  validate `params[:parent_node_id]` — **unchanged**. Delete the now-dead `folder_options` method
  and the `@folders = folder_options` line in `new` (nothing else references them).
- CSS: `.folder-field` / `.folder-field-btn` (the trigger) and the `.filechooser*` modal styles
  (overlay, columns, breadcrumb, footer, responsive collapse) added to `application.css`.

## Data flow

```
[trigger button] --click--> filechooser controller
      controller --GET /library/children?parent=…&files=…--> LibraryBrowseController
                 <--------------- {crumbs, entries} JSON ----
      (render/append a column; repeat per folder opened)
      "New Folder" --POST /library/folders {parent, name}--> LibraryBrowseController
                                                                 -> Maker::LibraryFolder.create_child!
                 <--------------- {node_id,name,kind} --------
      "Choose" --> set hidden input + button label + dispatch filechooser:choose --> close
[box form submit] --POST /tools/boxes (parent_node_id=…)--> BoxesController#create (unchanged)
```

Bytes never flow through Rails: the endpoints read node metadata and create directory nodes only
(§15 respected). Everything reads/writes through the shared `nodes` catalog and the existing
`Maker::LibraryFolder` seam, so it works uniformly on the chunk, share, and s3 backends with **no
capability gating** (folder creation is already cross-backend).

## Modes summary

| | folder-pick (boxes, now) | file-pick (future consumers) |
|---|---|---|
| `files` param | `0` (folders only) | `1` |
| navigable | folders | folders |
| selectable | folders (incl. root) | files |
| footer verb | "Choose" | "Open" |
| New Folder | shown | shown (still useful) |

## Edge cases & correctness

- **Auth/scoping:** both endpoints `authenticate_user!` and scope every query to `current_user`;
  a foreign/forged/stale `parent` → root/empty, never another user's nodes.
- **§10 tripwire:** no direct `Sync::`/port/changelog/conflict/lock/mount access — folder creation
  goes through `Maker::LibraryFolder`; reads go through `Node#children`.
- **Host form safety:** the trigger is `type="button"`; opening/closing the modal and clicking New
  Folder never submit the box form.
- **Deep trees / long names:** columns strip scrolls horizontally; names truncate with ellipsis.
- **Empty folder:** column renders an empty-state row; in folder mode an empty folder is still a
  valid selection.
- **New Folder failures** (blank/duplicate/permission): endpoint returns 422 + message; the modal
  surfaces it inline and stays open.
- **Backend unmounted (share/s3):** a browse/create failure surfaces as a modal error, not a lost
  form; the box form remains intact to retry.

## Testing

- **`LibraryBrowseController` (Rails, primary):** children scoping to the user; dirs-first
  ordering; `files=0` omits files, `files=1` includes them; crumbs correctness; foreign-parent
  rejection; folder creation returns the node and it appears on the next children call;
  blank/duplicate-name 422.
- **Boxes:** existing `boxes_controller_test.rb` still green — `create` still saves into
  `parent_node_id`; assert the `new` view renders the trigger partial (not the old `<select>`) and
  no longer computes `@folders`.
- **Cross-backend:** the browse endpoint reads the shared catalog, so the default suite (chunk)
  plus the existing `LIBRARY_BACKEND=share` / `=s3` CI legs cover all three.
- **Manual:** drive the modal end-to-end against the running app — navigate columns, New Folder,
  Choose, submit a box into the chosen folder, and verify mobile single-column drill-down. (The
  repo has no JS system-test harness; Stimulus is verified manually, consistent with the existing
  `boxpreview`/`boxfilter` controllers.)

## Out of scope (YAGNI)

- Wiring the project **"Attach a file"** flow (or any other consumer) to file-pick mode — the
  component is built ready for it; wiring is a separate change.
- Rename / delete / move **inside** the chooser (it chooses; it does not manage).
- A filename-entry field (boxes derives filenames from its existing Name field; generic file-pick
  has no filename).
- Thumbnails, multi-select, drag-and-drop, or showing greyed non-selectable files in folder-pick
  mode (can be added later without changing the contract).
```
