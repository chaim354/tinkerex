# Maker Library — Tauri Client UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the **Library/Catalog UI** in the existing Tauri desktop client (`client/maker-app`) on top of the just-landed server `/v1/maker/*` API and the `sync-client` `ServerClient` maker methods. A maker can browse/search a findable catalog of items (3D models / CAD / LightBurn, made or downloaded), open an item to see its instructions + attached files by role, tag and collect items, and track tasks — all referencing synced files by their stable `node_id`.

**Architecture:** The library is **"a findable catalog over the synced file system."** It is a *separate concern* from file sync: catalog records are **server-authoritative** (normal Rails CRUD), reached over the existing device-token-authed HTTP API. The desktop UI calls them through **`sync-client`'s `ServerClient` maker methods** (already implemented — see "Prerequisite" below), wrapped in thin Tauri `#[tauri::command]`s, exactly like the existing `browse`/`file_versions`/`conflicts` commands. Files are linked into items by **`node_id`** — the UI reuses the **existing file browser** (`browse` command → the synced tree) as the file picker. Previews/thumbnails are out of scope (a separate "Previews" pillar) — the UI leaves a clean `preview_url`/thumbnail-placeholder seam so they slot in later without rework.

**Tech Stack (matches what's already in `client/maker-app` — do NOT add a framework):**
- **Frontend:** vanilla ES modules, no build framework. `src/index.html` (static markup + dialogs), `src/main.js` (logic; `const { invoke } = window.__TAURI__.core`), `src/styles.css` (hand-written CSS with the existing design tokens). All backend calls go through the Tauri `invoke` bridge; **camelCase** arg names on the JS side map to the Rust command's snake_case params (Tauri converts automatically). See `src/main.js` lines 1–10 for the existing convention contract.
- **Backend (Tauri):** `client/maker-app/src-tauri/src/lib.rs` — `#[tauri::command]` fns returning `Result<T, String>` (errors stringified for the UI), each building a `ServerClient::with_token(server, token)` from the persisted credentials (`load_token(server, email)`), then registered in `generate_handler!`. Serialize outputs with `#[derive(serde::Serialize)]` structs (the existing file-browser pattern).
- **Licensing (CLAUDE.md §9):** permissive only. This plan adds **no new dependencies** — vanilla JS + the existing `serde`/`serde_json` already in `src-tauri/Cargo.toml`. (If a markdown renderer is wanted for instructions, use a tiny permissive lib like `marked` (MIT) loaded as a local vendored file — but the plan ships a minimal built-in renderer to avoid even that; see Task 6.)

**Prerequisite (DONE — this branch):** `client/sync-client/src/maker.rs` adds the typed `ServerClient` methods this UI calls: `list_items(type, tag, q)`, `create_item`, `get_item`, `update_item`, `delete_item`, `attach_file`, `detach_file`, `tag_item`, `untag`, `list_tags`, `list_collections`, `create_collection`, `add_to_collection`, `remove_from_collection`, `collection_items`, `list_tasks`, `create_task`, `update_task`, `delete_task` — plus the request/response structs (`Item`, `ItemDetail`, `ItemInput`, `FileAttachment`, `FileAttachmentInput`, `Tag`, `Collection`, `CollectionItem`, `Task`, `TaskInput`). `cargo test -p sync-client` is green (12 (de)serialization round-trip tests). **This plan consumes them; it does not reimplement them.**

**Conventions to follow (from the existing client):**
- **Tauri command shape:** every maker command takes `server_url: String, email: String` first (to rebuild the authed client from saved creds), like `browse`/`file_versions`. Resolve the token with `load_token(&server_url, &email).ok_or("this device isn't signed in yet")?`. Return `Result<_, String>`; map errors with `.map_err(|e| format!("… failed: {e}"))`.
- **Frontend command contract:** the JS `invoke("name", { serverUrl, email, … })` arg names are **camelCase** and MUST match the Rust params. Document the command names + arg casing in the `main.js` header comment (the file already does this — extend it).
- **UI primitives already available** (`src/main.js`): `$(id)`, `val(id)`, `toast(el, text, kind)`, `withBusy(btn, label, fn)`, `fmtSize`, `fmtWhen`, `relWhen`, `setFieldError`. Reuse them — don't reinvent.
- **Design tokens** (`src/styles.css`): cards (`.card`), pills (`.pill`/`.dot`), `.muted`, `.row`, `.toast`, `.overlay`/`.modal`, `.spinner`. New components extend these.

**Where the new UI lives:** a new top-level **"Library"** view added to `index.html` as additional `<section class="card">` blocks (and one full-screen `.overlay` modal for item detail/edit), shown/hidden by a small in-app nav. The existing Connection/Devices/Files cards stay; Library appears once a device is connected (a token exists for `(server,email)`).

---

## File Structure

**Frontend (`client/maker-app/src/`):**
- Modify `index.html` — add a top nav (Sync | Library), the Library view (catalog toolbar + grid, collections rail, tasks board) and a full-screen **item detail/edit** modal + a **file-picker** modal (reuses the tree).
- Modify `main.js` — add a `library.js`-style section (kept in `main.js` to match the single-module setup, OR split into `src/library.js` imported by `main.js`; this plan splits it for clarity — a plain ES module, no bundler needed since `index.html` can load both with `<script type="module">`). Wires every Library control to the Tauri maker commands.
- Modify `styles.css` — add `.lib-*` component styles (grid card, type badge, tag chip, board column, picker rows) on top of the existing tokens.

**Backend (`client/maker-app/src-tauri/src/`):**
- Modify `lib.rs` — add the maker `#[tauri::command]` wrappers (one per `ServerClient` maker method) + their `#[derive(Serialize)]` output structs, and register them in `generate_handler!`.

Responsibilities: the Tauri layer is a **thin, stateless pass-through** to `ServerClient` (auth from saved creds, stringify errors). All view state (current filter, open item, board) lives in the frontend. The file-layer seam is the `browse` command (already present) reused as the node picker.

---

## Task 1: Tauri command layer — items CRUD + list/filter

**Files:**
- Modify: `client/maker-app/src-tauri/src/lib.rs`

- [ ] **Step 1: Add a shared `maker_client` helper + item output structs**

In `client/maker-app/src-tauri/src/lib.rs`, after the conflicts commands (around line 358), add a new section. First, a helper that rebuilds the authed client (mirrors the inline pattern in `browse`):
```rust
// ---- maker library (the catalog over the synced tree) ------------------------------

/// Build an authed `ServerClient` from the saved creds for this (server, email), or a
/// human error if this device isn't signed in. Mirrors the inline pattern in `browse`.
fn maker_client(server_url: &str, email: &str) -> Result<sync_client::ServerClient, String> {
    let token = load_token(server_url, email).ok_or("this device isn't signed in yet")?;
    Ok(sync_client::ServerClient::with_token(server_url, token))
}
```

- [ ] **Step 2: Add the item commands**

Append (still in `lib.rs`):
```rust
#[tauri::command]
fn maker_list_items(
    server_url: String,
    email: String,
    item_type: Option<String>,
    tag: Option<String>,
    q: Option<String>,
) -> Result<Vec<sync_client::Item>, String> {
    let c = maker_client(&server_url, &email)?;
    c.list_items(item_type.as_deref(), tag.as_deref(), q.as_deref())
        .map_err(|e| format!("list items failed: {e}"))
}

#[tauri::command]
fn maker_get_item(server_url: String, email: String, id: i64) -> Result<sync_client::ItemDetail, String> {
    let c = maker_client(&server_url, &email)?;
    c.get_item(id).map_err(|e| format!("open item failed: {e}"))
}

#[tauri::command]
fn maker_create_item(server_url: String, email: String, input: sync_client::ItemInput) -> Result<sync_client::ItemDetail, String> {
    let c = maker_client(&server_url, &email)?;
    c.create_item(&input).map_err(|e| format!("create item failed: {e}"))
}

#[tauri::command]
fn maker_update_item(server_url: String, email: String, id: i64, input: sync_client::ItemInput) -> Result<sync_client::ItemDetail, String> {
    let c = maker_client(&server_url, &email)?;
    c.update_item(id, &input).map_err(|e| format!("update item failed: {e}"))
}

#[tauri::command]
fn maker_delete_item(server_url: String, email: String, id: i64) -> Result<(), String> {
    let c = maker_client(&server_url, &email)?;
    c.delete_item(id).map_err(|e| format!("delete item failed: {e}"))
}
```
Note: `sync_client::ItemInput` derives `Serialize` only; for it to arrive **from** the frontend as a Tauri command arg it must also `Deserialize`. **Sub-step:** in `client/sync-client/src/maker.rs`, add `Deserialize` to `ItemInput`'s derive (it's harmless — the struct is `skip_serializing_if` on send, and tolerant on receive) — i.e. `#[derive(Debug, Clone, Default, Serialize, Deserialize)]`. Do the same for `FileAttachmentInput` and `TaskInput` (Tasks 2 & 4 pass them as command args). Re-run `cargo test -p sync-client` to confirm still green.

- [ ] **Step 3: Register the commands**

In `generate_handler!` (currently ends `…resolve_conflict_split`), add the five item commands:
```rust
            resolve_conflict_split,
            maker_list_items,
            maker_get_item,
            maker_create_item,
            maker_update_item,
            maker_delete_item,
```

- [ ] **Step 4: Verify it compiles**

Run (from `client/maker-app/src-tauri`, with the platform's mount toolchain available — on macOS this is the default):
`cargo check`
Expected: compiles. (If the live FUSE/WebDAV deps aren't set up on the build box, `cargo check -p sync-client` at least proves the `Deserialize` additions; the Tauri crate check needs the per-OS mount toolchain per `client/maker-app/SETUP.md`.)

- [ ] **Step 5: Commit**
```bash
git add client/maker-app/src-tauri/src/lib.rs client/sync-client/src/maker.rs
git commit -m "feat(maker-app): Tauri item CRUD/list commands over the maker API"
```

---

## Task 2: Tauri command layer — attachments, tags, collections, tasks

**Files:**
- Modify: `client/maker-app/src-tauri/src/lib.rs`

- [ ] **Step 1: Add attachment + tag commands**

After the item commands in `lib.rs`:
```rust
#[tauri::command]
fn maker_attach_file(server_url: String, email: String, item_id: i64, input: sync_client::FileAttachmentInput) -> Result<sync_client::FileAttachment, String> {
    let c = maker_client(&server_url, &email)?;
    c.attach_file(item_id, &input).map_err(|e| format!("attach failed: {e}"))
}

#[tauri::command]
fn maker_detach_file(server_url: String, email: String, attachment_id: i64) -> Result<(), String> {
    let c = maker_client(&server_url, &email)?;
    c.detach_file(attachment_id).map_err(|e| format!("detach failed: {e}"))
}

#[tauri::command]
fn maker_tag_item(server_url: String, email: String, item_id: i64, name: String) -> Result<String, String> {
    let c = maker_client(&server_url, &email)?;
    c.tag_item(item_id, &name).map_err(|e| format!("tag failed: {e}"))
}

#[tauri::command]
fn maker_untag(server_url: String, email: String, tagging_id: i64) -> Result<(), String> {
    let c = maker_client(&server_url, &email)?;
    c.untag(tagging_id).map_err(|e| format!("untag failed: {e}"))
}

#[tauri::command]
fn maker_list_tags(server_url: String, email: String) -> Result<Vec<sync_client::Tag>, String> {
    let c = maker_client(&server_url, &email)?;
    c.list_tags().map_err(|e| format!("list tags failed: {e}"))
}
```
Note: the **detach** and **untag** routes are keyed by the *attachment id* / *tagging id*, not the node/tag id — the UI must carry those ids (the item detail view exposes `file_attachments[].id`; for taggings the detail view returns only tag **names**, so removing a tag in the UI re-fetches via `list_tags` to resolve name→id only if a per-item tagging-id is needed. Simpler: the item detail's `tags` are names; "remove tag" deletes by finding the tagging — but the server only exposes tagging id via the create response. **Decision:** the UI removes a tag by calling `maker_tag_item` is additive; for removal expose the tagging id by adding it to the item detail's tag serialization in a *server* follow-up, OR delete-and-recreate is not possible. For v1, the UI shows tags read-only-removable via the **server tagging id** which we surface by changing the item `tags` JSON to objects — **out of scope here**; v1 UI supports *adding* tags and *filtering* by tag, and removing a tag is deferred with a visible "managed on the web for now" note. (This keeps the client honest about the current API: `taggings#destroy` needs a tagging id the item view doesn't return.)

- [ ] **Step 2: Add collection commands**
```rust
#[tauri::command]
fn maker_list_collections(server_url: String, email: String) -> Result<Vec<sync_client::Collection>, String> {
    let c = maker_client(&server_url, &email)?;
    c.list_collections().map_err(|e| format!("list collections failed: {e}"))
}

#[tauri::command]
fn maker_create_collection(server_url: String, email: String, name: String, description: Option<String>) -> Result<sync_client::Collection, String> {
    let c = maker_client(&server_url, &email)?;
    c.create_collection(&name, description.as_deref()).map_err(|e| format!("create collection failed: {e}"))
}

#[tauri::command]
fn maker_collection_items(server_url: String, email: String, collection_id: i64) -> Result<Vec<sync_client::CollectionItem>, String> {
    let c = maker_client(&server_url, &email)?;
    c.collection_items(collection_id).map_err(|e| format!("collection items failed: {e}"))
}

#[tauri::command]
fn maker_add_to_collection(server_url: String, email: String, collection_id: i64, item_id: i64) -> Result<(), String> {
    let c = maker_client(&server_url, &email)?;
    c.add_to_collection(collection_id, item_id).map_err(|e| format!("add to collection failed: {e}"))
}

#[tauri::command]
fn maker_remove_from_collection(server_url: String, email: String, collection_id: i64, item_id: i64) -> Result<(), String> {
    let c = maker_client(&server_url, &email)?;
    c.remove_from_collection(collection_id, item_id).map_err(|e| format!("remove from collection failed: {e}"))
}
```

- [ ] **Step 3: Add task commands**
```rust
#[tauri::command]
fn maker_list_tasks(server_url: String, email: String, open_only: bool) -> Result<Vec<sync_client::Task>, String> {
    let c = maker_client(&server_url, &email)?;
    c.list_tasks(open_only).map_err(|e| format!("list tasks failed: {e}"))
}

#[tauri::command]
fn maker_create_task(server_url: String, email: String, input: sync_client::TaskInput) -> Result<sync_client::Task, String> {
    let c = maker_client(&server_url, &email)?;
    c.create_task(&input).map_err(|e| format!("create task failed: {e}"))
}

#[tauri::command]
fn maker_update_task(server_url: String, email: String, id: i64, input: sync_client::TaskInput) -> Result<sync_client::Task, String> {
    let c = maker_client(&server_url, &email)?;
    c.update_task(id, &input).map_err(|e| format!("update task failed: {e}"))
}

#[tauri::command]
fn maker_delete_task(server_url: String, email: String, id: i64) -> Result<(), String> {
    let c = maker_client(&server_url, &email)?;
    c.delete_task(id).map_err(|e| format!("delete task failed: {e}"))
}
```

- [ ] **Step 4: Register all of them in `generate_handler!`**
```rust
            maker_attach_file,
            maker_detach_file,
            maker_tag_item,
            maker_untag,
            maker_list_tags,
            maker_list_collections,
            maker_create_collection,
            maker_collection_items,
            maker_add_to_collection,
            maker_remove_from_collection,
            maker_list_tasks,
            maker_create_task,
            maker_update_task,
            maker_delete_task,
```

- [ ] **Step 5: Verify + commit**

Run `cargo check` (in `src-tauri`). Expected: compiles.
```bash
git add client/maker-app/src-tauri/src/lib.rs
git commit -m "feat(maker-app): Tauri commands for attachments, tags, collections, tasks"
```

---

## Task 3: App nav + Library view shell (HTML/CSS)

**Files:**
- Modify: `client/maker-app/src/index.html`
- Modify: `client/maker-app/src/styles.css`

- [ ] **Step 1: Add the top nav**

In `index.html`, just under `<header>` (after the `statusPill` span block, before the first `<section>`), add a view switcher:
```html
      <nav class="viewnav" role="tablist" aria-label="Sections">
        <button id="navSync" role="tab" aria-selected="true" class="active">Sync</button>
        <button id="navLibrary" role="tab" aria-selected="false">Library</button>
      </nav>
```
Wrap the three existing `<section class="card">` blocks (Connection, Devices, Files) in `<div id="viewSync">…</div>`.

- [ ] **Step 2: Add the Library view markup**

After `</div><!-- viewSync -->`, add the Library view (hidden by default):
```html
      <div id="viewLibrary" class="hidden">
        <!-- Catalog toolbar -->
        <section class="card">
          <div class="lib-toolbar">
            <input id="libSearch" class="lib-search" placeholder="Search the library…" autocomplete="off" />
            <select id="libType" aria-label="Filter by type">
              <option value="">All types</option>
              <option value="model_3d">3D model</option>
              <option value="cad">CAD</option>
              <option value="lightburn">LightBurn</option>
              <option value="electronics">Electronics</option>
              <option value="other">Other</option>
            </select>
            <button id="libNewItem" class="primary">New item</button>
          </div>
          <div id="libTags" class="lib-tagbar" aria-label="Filter by tag"></div>
          <div id="libGrid" class="lib-grid" aria-live="polite"></div>
          <div id="libEmpty" class="muted hidden">No items yet. Click “New item” to add one.</div>
        </section>

        <!-- Collections -->
        <section class="card">
          <h2>Collections</h2>
          <div class="row" style="margin-top:0">
            <input id="collName" placeholder="New collection name" autocomplete="off" />
            <button id="collCreate">Create</button>
          </div>
          <div id="collList" class="lib-coll-list"></div>
        </section>

        <!-- Tasks -->
        <section class="card">
          <h2>Tasks</h2>
          <div class="row" style="margin-top:0">
            <input id="taskTitle" placeholder="Add a task…" autocomplete="off" />
            <button id="taskCreate">Add</button>
          </div>
          <div id="taskBoard" class="lib-board"></div>
        </section>
      </div>
```

- [ ] **Step 3: Add the item-detail / edit modal + file-picker modal**

After the existing conflict `<div id="overlay">…</div>`, add two more overlays:
```html
    <!-- Item detail / edit -->
    <div id="itemOverlay" class="overlay" role="dialog" aria-modal="true" aria-labelledby="itemTitle">
      <div class="modal modal-wide">
        <div class="modal-head">
          <h3 id="itemTitle">Item</h3>
          <button id="itemClose" class="modal-close" aria-label="Close">&times;</button>
        </div>
        <div id="itemBody"></div>
        <div id="itemErr" class="modal-err"></div>
      </div>
    </div>

    <!-- File picker (reuses the synced tree from `browse`) -->
    <div id="pickerOverlay" class="overlay" role="dialog" aria-modal="true" aria-labelledby="pickerTitle">
      <div class="modal">
        <div class="modal-head">
          <h3 id="pickerTitle">Attach a file</h3>
          <button id="pickerClose" class="modal-close" aria-label="Close">&times;</button>
        </div>
        <input id="pickerFilter" placeholder="Filter files…" autocomplete="off" />
        <div id="pickerList" class="picker-list" role="listbox"></div>
        <div id="pickerErr" class="modal-err"></div>
      </div>
    </div>
```

- [ ] **Step 4: Add the styles**

In `styles.css`, append a Library block (extends the existing tokens):
```css
/* ---- view nav ---- */
.viewnav { display:flex; gap:.5rem; margin:.4rem 0 1rem; }
.viewnav button { flex:0 0 auto; }
.viewnav button.active { background: var(--accent, #4f7cff); color:#fff; }

/* ---- catalog ---- */
.lib-toolbar { display:flex; gap:.5rem; align-items:center; }
.lib-search { flex:1; }
.lib-tagbar { display:flex; flex-wrap:wrap; gap:.35rem; margin:.6rem 0; }
.chip { border:1px solid var(--border,#3a3a3a); border-radius:999px; padding:.15rem .6rem; cursor:pointer; font-size:.82rem; background:transparent; }
.chip.on { background: var(--accent,#4f7cff); color:#fff; border-color:transparent; }
.lib-grid { display:grid; grid-template-columns:repeat(auto-fill,minmax(160px,1fr)); gap:.7rem; margin-top:.6rem; }
.lib-card { border:1px solid var(--border,#3a3a3a); border-radius:10px; padding:.6rem; cursor:pointer; position:relative; }
.lib-card:hover { border-color: var(--accent,#4f7cff); }
.lib-thumb { aspect-ratio:1/1; border-radius:8px; background:#2a2a2a center/cover no-repeat; display:flex; align-items:center; justify-content:center; color:#777; font-size:1.6rem; margin-bottom:.45rem; }
.lib-title { font-weight:600; font-size:.9rem; line-height:1.2; }
.badge { display:inline-block; font-size:.7rem; padding:.05rem .4rem; border-radius:6px; background:#333; color:#bbb; margin-top:.3rem; }
.fav { position:absolute; top:.4rem; right:.5rem; cursor:pointer; font-size:1rem; }
.fav.on { color:#ffce3a; }

/* ---- collections + board ---- */
.lib-coll-list { display:flex; flex-wrap:wrap; gap:.5rem; margin-top:.7rem; }
.lib-coll { border:1px solid var(--border,#3a3a3a); border-radius:8px; padding:.4rem .7rem; cursor:pointer; }
.lib-board { display:grid; grid-template-columns:repeat(3,1fr); gap:.6rem; margin-top:.7rem; }
.lib-col { background:#222; border-radius:8px; padding:.5rem; min-height:80px; }
.lib-col h4 { margin:.1rem 0 .5rem; font-size:.78rem; text-transform:uppercase; color:#999; }
.task { background:#2c2c2c; border-radius:6px; padding:.4rem .5rem; margin-bottom:.4rem; font-size:.85rem; display:flex; justify-content:space-between; gap:.4rem; }
.task button { padding:.1rem .35rem; font-size:.75rem; }

/* ---- modals + picker ---- */
.modal-wide { max-width:640px; width:92vw; }
.picker-list { max-height:50vh; overflow:auto; margin-top:.5rem; }
.picker-row { display:flex; justify-content:space-between; padding:.35rem .5rem; border-radius:6px; cursor:pointer; }
.picker-row:hover { background:#2c2c2c; }
.picker-row.dir { color:#9bb6ff; }
.attach-row { display:flex; justify-content:space-between; align-items:center; padding:.3rem 0; border-bottom:1px solid #2c2c2c; }
```
(Reuse `--accent`/`--border` if defined; the fallbacks keep it working if not.)

- [ ] **Step 5: Commit**
```bash
git add client/maker-app/src/index.html client/maker-app/src/styles.css
git commit -m "feat(maker-app): Library view shell — nav, catalog/collections/tasks markup + styles"
```

---

## Task 4: Frontend — catalog browse/search/filter + favorite

**Files:**
- Create: `client/maker-app/src/library.js`
- Modify: `client/maker-app/src/index.html` (load the module)
- Modify: `client/maker-app/src/main.js` (nav wiring + export `args()`/helpers)

- [ ] **Step 1: Expose the shared helpers to `library.js`**

In `main.js`, the helpers (`invoke`, `$`, `toast`, `withBusy`, `args`, `fmtWhen`, etc.) are module-local. Export the ones Library needs by attaching them to a small shared object at the end of `main.js`:
```js
// Shared with library.js (kept on window to avoid a bundler/import graph).
window.MakerUI = { invoke, $, val, toast, withBusy, fmtSize, fmtWhen, relWhen, args };
```
(`args()` returns `{ serverUrl, email }` from the connection form — Library passes it into every command.)

- [ ] **Step 2: Wire the nav**

In `main.js`, after the existing tab wiring, add:
```js
const showView = (which) => {
  const lib = which === "library";
  $("viewSync").classList.toggle("hidden", lib);
  $("viewLibrary").classList.toggle("hidden", !lib);
  $("navSync").classList.toggle("active", !lib);
  $("navLibrary").classList.toggle("active", lib);
  $("navSync").setAttribute("aria-selected", String(!lib));
  $("navLibrary").setAttribute("aria-selected", String(lib));
  if (lib) window.dispatchEvent(new CustomEvent("library:show"));
};
$("navSync").onclick = () => showView("sync");
$("navLibrary").onclick = () => showView("library");
```

- [ ] **Step 3: Load `library.js`**

In `index.html`, after the existing `<script type="module" src="/main.js"></script>`, add:
```html
    <script type="module" src="/library.js"></script>
```
(`library.js` reads `window.MakerUI` — `main.js` sets it on load; both are modules executed after parse, and `main.js` is listed first, so `MakerUI` exists by the time `library.js`'s event handlers fire. Guard with a top-of-file `const UI = window.MakerUI;`.)

- [ ] **Step 4: Implement catalog load + render in `library.js`**

Create `client/maker-app/src/library.js`:
```js
// Maker Library view. Reads shared helpers from window.MakerUI (set by main.js).
// Tauri commands (snake_case fn ↔ camelCase args):
//   maker_list_items {serverUrl,email,itemType?,tag?,q?}  maker_get_item {…,id}
//   maker_create_item/maker_update_item {…,input}         maker_delete_item {…,id}
//   maker_attach_file {…,itemId,input}  maker_detach_file {…,attachmentId}
//   maker_tag_item {…,itemId,name}      maker_list_tags {…}
//   maker_list_collections/maker_create_collection/maker_collection_items/
//   maker_add_to_collection/maker_remove_from_collection
//   maker_list_tasks {…,openOnly}  maker_create_task/maker_update_task/maker_delete_task
//   browse {serverUrl,email}  (reused as the file picker source)

const UI = window.MakerUI;
const { invoke, $, toast } = UI;

const TYPE_LABEL = { model_3d: "3D model", cad: "CAD", lightburn: "LightBurn", electronics: "Electronics", other: "Other" };
const TYPE_ICON  = { model_3d: "🧊", cad: "📐", lightburn: "🔥", electronics: "🔌", other: "📄" };

let activeTag = null; // tag-name filter, or null

const libArgs = () => UI.args(); // { serverUrl, email }

async function loadCatalog() {
  const a = libArgs();
  const itemType = $("libType").value || null;
  const q = $("libSearch").value.trim() || null;
  try {
    const items = await invoke("maker_list_items", { ...a, itemType, tag: activeTag, q });
    renderGrid(items);
  } catch (e) {
    toast($("connToast"), String(e), "err");
  }
}

function renderGrid(items) {
  const grid = $("libGrid");
  grid.innerHTML = "";
  $("libEmpty").classList.toggle("hidden", items.length > 0);
  for (const it of items) {
    const card = document.createElement("div");
    card.className = "lib-card";
    card.onclick = () => openItem(it.id);
    // preview seam: when the Previews pillar lands, set background-image to it.preview_url.
    card.innerHTML = `
      <div class="lib-thumb">${TYPE_ICON[it.item_type] || "📄"}</div>
      <div class="lib-title"></div>
      <span class="badge"></span>
      <span class="fav ${it.favorited ? "on" : ""}" title="Favorite">★</span>`;
    card.querySelector(".lib-title").textContent = it.title;
    card.querySelector(".badge").textContent = TYPE_LABEL[it.item_type] || it.item_type;
    const fav = card.querySelector(".fav");
    fav.onclick = async (ev) => {
      ev.stopPropagation();
      await invoke("maker_update_item", { ...libArgs(), id: it.id, input: { favorited: !it.favorited } });
      loadCatalog();
    };
    grid.appendChild(card);
  }
}

async function loadTagBar() {
  const bar = $("libTags");
  bar.innerHTML = "";
  let tags = [];
  try { tags = await invoke("maker_list_tags", libArgs()); } catch { /* empty bar */ }
  for (const t of tags) {
    const chip = document.createElement("button");
    chip.className = "chip" + (activeTag === t.name ? " on" : "");
    chip.textContent = t.name;
    chip.onclick = () => { activeTag = activeTag === t.name ? null : t.name; loadTagBar(); loadCatalog(); };
    bar.appendChild(chip);
  }
}

// Debounced search.
let searchTimer;
$("libSearch").addEventListener("input", () => { clearTimeout(searchTimer); searchTimer = setTimeout(loadCatalog, 200); });
$("libType").addEventListener("change", loadCatalog);

window.addEventListener("library:show", () => { loadTagBar(); loadCatalog(); /* collections+tasks: Tasks 5–7 */ });

export { loadCatalog, loadTagBar, libArgs, TYPE_LABEL };
```
(Item open/create/edit and the picker are stubbed by `openItem` — implemented in Task 5; declare a placeholder `async function openItem(id){ /* Task 5 */ }` until then so the file loads. Build incrementally per the TDD-ish task order.)

- [ ] **Step 5: Manual smoke (interactive — needs a running server + a connected device)**

Boot a server (`STORAGE_BACKEND=memory bin/rails server -p 3001`), connect the app, create an item via the API or Task 5's form, switch to **Library**: the grid shows the item with its type badge; typing in search filters; the type dropdown filters; clicking ★ toggles favorite and the card updates.

- [ ] **Step 6: Commit**
```bash
git add client/maker-app/src/library.js client/maker-app/src/index.html client/maker-app/src/main.js
git commit -m "feat(maker-app): Library catalog browse/search/type+tag filter/favorite"
```

---

## Task 5: Frontend — item detail, create/edit form, attachments + file picker

**Files:**
- Modify: `client/maker-app/src/library.js`

- [ ] **Step 1: Item detail render**

In `library.js`, replace the `openItem` placeholder with a real detail view that calls `maker_get_item` and renders title/summary/instructions (markdown-lite), the type/origin/source, the attachments grouped by role, and the tags, plus Edit / Attach file / Delete actions:
```js
// Minimal, safe markdown: escape, then **bold**, *italic*, `code`, and line breaks.
// (Avoids a dependency; instructions are short. A real renderer is a later polish.)
function mdLite(src) {
  const esc = (s) => s.replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]));
  return esc(src || "")
    .replace(/`([^`]+)`/g, "<code>$1</code>")
    .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
    .replace(/\*([^*]+)\*/g, "<em>$1</em>")
    .replace(/^### (.*)$/gm, "<h4>$1</h4>")
    .replace(/\n/g, "<br>");
}

async function openItem(id) {
  const a = libArgs();
  let it;
  try { it = await invoke("maker_get_item", { ...a, id }); }
  catch (e) { return toast($("connToast"), String(e), "err"); }
  $("itemTitle").textContent = it.title;
  const atts = (it.file_attachments || []).map((f) => `
    <div class="attach-row">
      <span>${f.role} · ${f.label || f.node_id}</span>
      <button data-att="${f.id}" class="detach">Detach</button>
    </div>`).join("");
  $("itemBody").innerHTML = `
    <p class="muted">${TYPE_LABEL[it.item_type] || it.item_type} · ${it.origin}${it.source_url ? ` · <a href="${it.source_url}" target="_blank" rel="noreferrer">source</a>` : ""}</p>
    ${it.summary ? `<p>${it.summary}</p>` : ""}
    <div class="instructions">${mdLite(it.instructions)}</div>
    <div class="lib-thumb" style="max-width:200px">${(TYPE_ICON[it.item_type] || "📄")}</div>
    <h4>Files</h4>${atts || '<p class="muted">No files attached.</p>'}
    <div class="row" style="margin-top:.4rem">
      <button id="itemAttach">Attach a file</button>
      <button id="itemEdit">Edit</button>
      <button id="itemDelete" class="danger">Delete</button>
    </div>
    <h4>Tags</h4>
    <div class="row"><input id="itemTagInput" placeholder="add a tag…"/><button id="itemTagAdd">Add</button></div>
    <div class="lib-tagbar">${(it.tags || []).map((t) => `<span class="chip on">${t}</span>`).join("") || '<span class="muted">none</span>'}</div>`;
  // wire actions
  $("itemBody").querySelectorAll(".detach").forEach((b) => b.onclick = async () => {
    await invoke("maker_detach_file", { ...libArgs(), attachmentId: Number(b.dataset.att) }); openItem(id);
  });
  $("itemAttach").onclick = () => openPicker(id);
  $("itemEdit").onclick = () => openItemForm(it);
  $("itemDelete").onclick = async () => {
    await invoke("maker_delete_item", { ...libArgs(), id }); closeOverlay("itemOverlay"); loadCatalog();
  };
  $("itemTagAdd").onclick = async () => {
    const name = $("itemTagInput").value.trim(); if (!name) return;
    await invoke("maker_tag_item", { ...libArgs(), itemId: id, name }); openItem(id); loadTagBar();
  };
  showOverlay("itemOverlay");
}

const showOverlay = (id) => $(id).classList.add("open");
const closeOverlay = (id) => $(id).classList.remove("open");
$("itemClose").onclick = () => closeOverlay("itemOverlay");
```
(Note `.overlay.open { display:flex }` already governs visibility in `styles.css` — confirm the conflict modal uses the same `open` class; if it toggles differently, match that mechanism.)

- [ ] **Step 2: Create/edit form**

Add a form renderer reused for both new and edit (title required; type/origin selects; summary/instructions/source fields):
```js
function openItemForm(existing) {
  const a = libArgs();
  const it = existing || { item_type: "other", origin: "downloaded" };
  $("itemTitle").textContent = existing ? "Edit item" : "New item";
  const opt = (v, cur, label) => `<option value="${v}" ${v === cur ? "selected" : ""}>${label}</option>`;
  $("itemBody").innerHTML = `
    <label>Title</label><input id="fTitle" value="${(it.title || "").replace(/"/g, "&quot;")}"/>
    <label>Type</label><select id="fType">
      ${opt("model_3d", it.item_type, "3D model")}${opt("cad", it.item_type, "CAD")}
      ${opt("lightburn", it.item_type, "LightBurn")}${opt("electronics", it.item_type, "Electronics")}
      ${opt("other", it.item_type, "Other")}</select>
    <label>Origin</label><select id="fOrigin">
      ${opt("self_made", it.origin, "Self-made")}${opt("downloaded", it.origin, "Downloaded")}
      ${opt("modified", it.origin, "Modified")}</select>
    <label>Summary</label><input id="fSummary" value="${(it.summary || "").replace(/"/g, "&quot;")}"/>
    <label>Source URL</label><input id="fSource" value="${(it.source_url || "").replace(/"/g, "&quot;")}"/>
    <label>Instructions (markdown)</label><textarea id="fInstr" rows="6">${it.instructions || ""}</textarea>
    <div class="row" style="margin-top:.5rem"><button id="fSave" class="primary">Save</button></div>`;
  $("fSave").onclick = async () => {
    const input = {
      title: $("fTitle").value.trim(), item_type: $("fType").value, origin: $("fOrigin").value,
      summary: $("fSummary").value.trim() || null, source_url: $("fSource").value.trim() || null,
      instructions: $("fInstr").value || null,
    };
    if (!input.title) return toast($("itemErr") || $("connToast"), "Title is required", "err");
    try {
      const saved = existing
        ? await invoke("maker_update_item", { ...a, id: existing.id, input })
        : await invoke("maker_create_item", { ...a, input });
      loadCatalog(); openItem(saved.id);
    } catch (e) { toast($("connToast"), String(e), "err"); }
  };
  showOverlay("itemOverlay");
}
$("libNewItem").onclick = () => openItemForm(null);
```
(`input` sends `null` for cleared fields; the Rust `ItemInput`'s `skip_serializing_if = Option::is_none` means a JS `null` arrives as JSON `null` → Rust `Option<String> = None` → omitted on the wire → server leaves it untouched. For *clearing* a field to empty, send `""` not `null`.)

- [ ] **Step 3: The file picker (reuses `browse`)**

```js
async function openPicker(itemId) {
  showOverlay("pickerOverlay");
  const list = $("pickerList"); list.innerHTML = "Loading…";
  let entries = [];
  try { entries = await invoke("browse", libArgs()); }
  catch (e) { list.innerHTML = ""; return toast($("pickerErr"), String(e), "err"); }
  const files = entries.filter((e) => e.kind === "file");
  const render = (filter) => {
    list.innerHTML = "";
    for (const f of files.filter((f) => !filter || f.name.toLowerCase().includes(filter))) {
      const row = document.createElement("div");
      row.className = "picker-row";
      row.innerHTML = `<span>${f.name}</span><span class="muted">${UI.fmtSize(f.size)}</span>`;
      row.onclick = async () => {
        const role = guessRole(f.name);
        await invoke("maker_attach_file", { ...libArgs(), itemId, input: { node_id: f.node_id, role, label: f.name } });
        closeOverlay("pickerOverlay"); openItem(itemId);
      };
      list.appendChild(row);
    }
  };
  $("pickerFilter").oninput = () => render($("pickerFilter").value.trim().toLowerCase());
  render("");
}
function guessRole(name) {
  const n = name.toLowerCase();
  if (/\.(stl|3mf|obj|step|stp|iges|igs|f3d|fcstd|sldprt)$/.test(n)) return "model";
  if (/\.(png|jpg|jpeg|webp|gif)$/.test(n)) return "image";
  if (/\.(md|txt|pdf)$/.test(n)) return "instructions";
  if (/\.(gcode|gco|nc)$/.test(n)) return "gcode";
  if (/\.(zip|7z|rar)$/.test(n)) return "source_archive";
  return "other";
}
$("pickerClose").onclick = () => closeOverlay("pickerOverlay");
```
(Roles must match the server's `Maker::FileAttachment::ROLES = %w[model instructions image source_archive gcode other]`. `guessRole` only ever returns those.)

- [ ] **Step 4: Manual smoke**

Open an item → Attach a file → pick a synced file → it appears under Files with a role → Detach removes it. Edit changes fields and re-renders. New item creates and opens.

- [ ] **Step 5: Commit**
```bash
git add client/maker-app/src/library.js
git commit -m "feat(maker-app): item detail, create/edit form, attach/detach via the file picker"
```

---

## Task 6: Frontend — collections

**Files:**
- Modify: `client/maker-app/src/library.js`

- [ ] **Step 1: Render + create collections**

In `library.js`, add collections logic loaded on `library:show`:
```js
async function loadCollections() {
  const wrap = $("collList"); wrap.innerHTML = "";
  let cols = [];
  try { cols = await invoke("maker_list_collections", libArgs()); } catch { return; }
  for (const c of cols) {
    const el = document.createElement("div");
    el.className = "lib-coll";
    el.textContent = `${c.name} (${c.item_count})`;
    el.onclick = () => openCollection(c);
    wrap.appendChild(el);
  }
}
$("collCreate").onclick = async () => {
  const name = $("collName").value.trim(); if (!name) return;
  await invoke("maker_create_collection", { ...libArgs(), name, description: null });
  $("collName").value = ""; loadCollections();
};
```

- [ ] **Step 2: View a collection's items + add/remove**

Reuse the item overlay to list members; "Add current filter results" or per-item add is the simplest. v1: open a collection → list its items (each opens the item detail), and an "Add item…" picker that lists all catalog items to add:
```js
async function openCollection(c) {
  $("itemTitle").textContent = c.name;
  let members = [];
  try { members = await invoke("maker_collection_items", { ...libArgs(), collectionId: c.id }); } catch {}
  const rows = members.map((m) => `
    <div class="attach-row"><span>${m.title} <span class="badge">${TYPE_LABEL[m.item_type] || m.item_type}</span></span>
    <button data-rm="${m.id}" class="rmcoll">Remove</button></div>`).join("");
  $("itemBody").innerHTML = `${rows || '<p class="muted">Empty collection.</p>'}
    <div class="row" style="margin-top:.5rem"><button id="collAddItem">Add an item…</button></div>`;
  $("itemBody").querySelectorAll(".rmcoll").forEach((b) => b.onclick = async () => {
    await invoke("maker_remove_from_collection", { ...libArgs(), collectionId: c.id, itemId: Number(b.dataset.rm) });
    openCollection(c); loadCollections();
  });
  $("collAddItem").onclick = async () => {
    const all = await invoke("maker_list_items", { ...libArgs(), itemType: null, tag: null, q: null });
    $("itemBody").innerHTML = all.map((it) => `<div class="picker-row" data-add="${it.id}">${it.title}</div>`).join("");
    $("itemBody").querySelectorAll("[data-add]").forEach((r) => r.onclick = async () => {
      await invoke("maker_add_to_collection", { ...libArgs(), collectionId: c.id, itemId: Number(r.dataset.add) });
      openCollection(c); loadCollections();
    });
  };
  showOverlay("itemOverlay");
}
```

- [ ] **Step 3: Hook into `library:show`**

Extend the `library:show` listener to also call `loadCollections()`.

- [ ] **Step 4: Manual smoke + commit**

Create a collection, open it, add/remove items; the `(count)` updates.
```bash
git add client/maker-app/src/library.js
git commit -m "feat(maker-app): collections — create, view members, add/remove items"
```

---

## Task 7: Frontend — tasks board (todo/doing/done)

**Files:**
- Modify: `client/maker-app/src/library.js`

- [ ] **Step 1: Render the board**

```js
const COLS = [["todo", "To do"], ["doing", "Doing"], ["done", "Done"]];
async function loadTasks() {
  const board = $("taskBoard"); board.innerHTML = "";
  let tasks = [];
  try { tasks = await invoke("maker_list_tasks", { ...libArgs(), openOnly: false }); } catch { return; }
  for (const [status, label] of COLS) {
    const col = document.createElement("div");
    col.className = "lib-col";
    col.innerHTML = `<h4>${label}</h4>`;
    for (const t of tasks.filter((x) => x.status === status)) {
      const el = document.createElement("div");
      el.className = "task";
      const next = status === "todo" ? "doing" : status === "doing" ? "done" : "todo";
      el.innerHTML = `<span></span><span class="task-acts">
        <button data-mv>${status === "done" ? "↺" : "→"}</button>
        <button data-del>✕</button></span>`;
      el.querySelector("span").textContent = t.title;
      el.querySelector("[data-mv]").onclick = async () => {
        await invoke("maker_update_task", { ...libArgs(), id: t.id, input: { status: next } }); loadTasks();
      };
      el.querySelector("[data-del]").onclick = async () => {
        await invoke("maker_delete_task", { ...libArgs(), id: t.id }); loadTasks();
      };
      col.appendChild(el);
    }
    board.appendChild(col);
  }
}
$("taskCreate").onclick = async () => {
  const title = $("taskTitle").value.trim(); if (!title) return;
  await invoke("maker_create_task", { ...libArgs(), input: { title } });
  $("taskTitle").value = ""; loadTasks();
};
```
(The `→` button advances todo→doing→done; on done it shows `↺` to reopen. Moving to `done` stamps `completed_at` server-side; reopening clears it — handled in `TasksController#update`. A task created from an item detail can pass `{ title, taskable_type: "Maker::Item", taskable_id: it.id }` — a later enhancement; standalone is v1.)

- [ ] **Step 2: Hook into `library:show`** — also call `loadTasks()`.

- [ ] **Step 3: Manual smoke + commit**

Add a task → appears in To do → advance through Doing → Done (✓ greyed/reopen) → delete.
```bash
git add client/maker-app/src/library.js
git commit -m "feat(maker-app): standalone tasks board (todo/doing/done)"
```

---

## Task 8: End-to-end smoke + previews seam doc

**Files:**
- Modify: `client/maker-app/SETUP.md` (a short "Library" section)

- [ ] **Step 1: Full manual E2E (interactive, against a live server)**

1. `STORAGE_BACKEND=memory bin/rails server -p 3001`
2. Launch the app (`client/maker-app/SETUP.md`), connect (register a device).
3. Library → New item (title "Benchy", type 3D model) → Save.
4. In Sync, write a file into the mount; Refresh files.
5. Open Benchy → Attach a file → pick the synced file → it appears under Files as `model`.
6. Add tag "printed"; the tag chip appears in the toolbar and filters the grid.
7. Create a collection "Boats", add Benchy; the count shows 1.
8. Tasks: add "Sand the deck", advance to Done.
9. Reload the app: everything persists (server-authoritative).

- [ ] **Step 2: Document the previews seam**

In `SETUP.md`, add:
```md
## Library (catalog over the synced files)

The **Library** tab is a findable catalog: items (with type, tags, instructions),
collections, and tasks, all stored server-side and reached over `/v1/maker/*`. Files are
linked by the synced tree's `node_id` (the file picker reuses the file browser).

**Previews seam:** item cards render a type-icon placeholder today. When the *Previews*
pillar lands (server-rendered thumbnails per `(node_id, version_id)`), the grid card and
the detail header set `background-image` from a `preview_url` on the item/attachment JSON —
no other UI change. The placeholder div (`.lib-thumb`) is the single insertion point.
```

- [ ] **Step 3: Commit**
```bash
git add client/maker-app/SETUP.md
git commit -m "docs(maker-app): Library usage + previews seam"
```

---

## Self-Review (completed during authoring)

- **Spec coverage:** catalog browse/search (Task 4: `maker_list_items` + debounced search + type/tag filter + favorite ★), item detail (Task 5: instructions markdown-lite, attachments by role, tags, edit/attach/delete), create/edit form (Task 5), collections list/create/view/add/remove (Task 6), tasks board todo/doing/done + create/complete/delete + standalone-or-item-owned seam (Task 7), file linking by `node_id` via the reused file browser (Task 5 picker), previews `preview_url`/`.lib-thumb` seam (Tasks 4/8). ✓
- **Wiring consistency:** every screen calls a `sync-client` `ServerClient` maker method (implemented + tested on this branch) through a thin Tauri command (Tasks 1–2), with the exact camelCase↔snake_case arg contract documented in `library.js`'s header. Roles emitted by `guessRole` are exactly the server's `ROLES`; item-type/origin selects match `ITEM_TYPES`/`ORIGINS`. ✓
- **Stack fidelity:** no new framework — vanilla ES modules + the existing CSS tokens + `serde`/`serde_json` already present. The one honest gap (tag *removal* needs a tagging id the item JSON doesn't return today) is called out in Task 2 with a v1 deferral, not hidden. ✓
- **Placeholder scan:** every task ships exact paths, runnable commands, and complete code snippets; incremental order keeps each file loading at every step. ✓

---

## Out of scope (follow-on plans)

- **Web UI parity** — the same library surface in the browser web app (off-Rails bytes already exist for files; the catalog is plain JSON, so the web client reuses the same `/v1/maker/*` endpoints).
- **Previews pillar** — server-rendered thumbnails per `(node_id, version_id)`; this UI already leaves the `.lib-thumb` / `preview_url` seam.
- **Tag removal in-app** — needs the server to expose a per-item tagging id (return `tags` as `[{id,name}]` from the item view); a tiny server follow-up unblocks the UI's untag button (the `untag(tagging_id)` client method already exists).
- **Drag-and-drop** task reordering / kanban (the `position` field + `update_task` already support it; v1 uses an advance button).
- **Projects / Inventory / BOM** pillars (separate server + UI plans).
```
