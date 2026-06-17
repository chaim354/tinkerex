# Plan: Maker Lite — the personal model library / backup vault

> **Status:** PLAN (no code). 2026-06-16. Branch `night/maker-lite-plan`.
>
> **One-liner:** A basic, storage-first slice of the maker layer that lets someone
> **upload → organize → preview → download** their 3D-printable and maker files as a
> personal **backup vault** — *without* the sync engine, daemon, or any mount
> (no FUSE / CfAPI / WebDAV). Web-first, lowest-friction signup.

---

## 0. Why this exists (positioning)

The full product is a local-first **sync engine + native mount** (CLAUDE.md §2): your
maker drive shows up as a folder on every device and syncs in the background. That's
powerful but heavy — it needs a desktop app, a driver install, a daemon, and a mental
model ("it's a drive").

**Maker Lite is the on-ramp.** It targets a much simpler, very common want:

> *"I download a lot of STLs/3MFs from Thingiverse / Printables / MakerWorld / Thangs.
> Models get pulled or sites disappear. I want one place to back up my own copies and
> actually find them again when I want to re-print."*

So the pitch is **"your personal model library / backup vault"** — a Google-Photos-shaped
home for maker files:

- Drag files in from a browser. They're safe, versioned, deduped.
- See a thumbnail/3D preview so you recognize what's what.
- Tag, collect, filter, search.
- Download the original bytes back any time, byte-for-byte.
- Remember *where you got it* (source URL/site) so you can credit / re-find the maker.

No drive, no daemon, no install. **It runs entirely on the primitives we already shipped**
— the same content-addressed chunk storage, immutable versions, the maker Library pillar,
and the preview pipeline. Maker Lite is mostly **a web client + a thin glue layer**, not
new infrastructure. And it's the natural **upsell funnel** into the full synced product
(§9).

---

## 1. Scope — explicitly in vs out

### In scope (v1)

- **Web app, signup/login** (reuse the existing Devise web auth — §3).
- **Upload**: drag-and-drop single files, multi-file bulk upload, and **folder import**
  (directory drop preserving relative structure). Browser-side chunking + presigned PUT,
  **bytes never through Rails** (the existing `FilesController#begin_upload` /
  `finalize_upload` path — §4).
- **Library catalog**: each uploaded file (or grouped set) becomes a **Maker::Item**
  (title, type, origin, source URL/name, favorite) with **file attachments** pointing at
  the synced node/version (§4, §5).
- **Organize**: **tags**, **collections**, **type filters**, favorites — all already
  modeled (`Maker::Tag` / `Maker::Tagging` / `Maker::Collection` — §5).
- **Preview**: thumbnails + in-browser 3D/2D preview for **STL / 3MF / OBJ / STEP / DXF /
  SVG / LightBurn `.lbrn2`** via the existing renderer registry + preview job (§6).
- **Download**: original bytes back via presigned GET (the existing `blob` path), single
  file or **collection-as-zip** (§4).
- **Version history**: re-upload a file → new immutable version; view + restore prior
  versions (the existing `nodes#versions` / `nodes#restore`).
- **Trash / undelete**: soft-delete + restore (existing tombstone model).

### Out of scope (explicitly NOT in Maker Lite)

- ❌ **No sync engine** — no continuous daemon loop, no outbox/cursor, no changelog
  *consumption* on a client. (The server still appends changelog entries on commit; Lite
  just never *pulls* them into a local tree.)
- ❌ **No mount** — no FUSE (Linux), no CfAPI/WinFsp (Windows), no WebDAV (macOS). Nothing
  appears as a drive or folder on the OS.
- ❌ **No desktop/Tauri app**, no driver install, no `maker-syncd` / `maker-cfsyncd`.
- ❌ **No local-first metadata mirror** on the client — the web client reads the server
  over plain HTTPS/JSON every time (it's a thin client, not a replica).
- ❌ **No selective sync / range hydration / bandwidth controls** (those are sync-engine
  concepts; irrelevant without a sync client).
- ❌ **No conflict detection / file locking** — Lite uploads are explicit, user-initiated
  re-uploads (a new version off the current base), not concurrent offline edits. The
  conflict machinery stays dormant.
- ❌ **No inventory / projects / BOM / tasks** — those maker pillars exist server-side but
  are *not surfaced* in Lite. Lite is **files-only** (library + preview). (They become the
  "Pro/maker" expansion, not the backup-vault MVP.)
- ❌ **No at-rest encryption / sharing** — tracked elsewhere (`docs/plan-encryption.md`,
  `docs/plan-sharing.md`); not gating the vault MVP.

> **Design rule:** Maker Lite adds **zero new storage/sync infrastructure**. If something
> requires the sync engine or a mount, it's out of scope by definition. Everything Lite
> does is HTTPS control plane + presigned bytes + the maker catalog tables.

---

## 2. How it maps onto what's already built

Maker Lite is a recombination, not a rebuild. The pieces already on `main`:

| Need | Already exists | Where |
|---|---|---|
| Content-addressed, deduped, versioned byte store | chunks + manifests + immutable versions | `Sync::Commit`, `chunks`, `manifest_chunks`, `versions` |
| Browser upload without bytes through Rails | begin/finalize + presigned PUT (browser SHA-256 + SubtleCrypto) | `FilesController#begin_upload` / `#finalize_upload` |
| Browser download without bytes through Rails | presigned GET / 302-to-storage | `FilesController#blob` |
| Catalog: items, tags, collections, attachments | the **maker Library pillar** | `app/models/maker/*`, `V1::Maker::*` controllers |
| Preview thumbnails + 3D/2D renders | the **preview pipeline** + registry | `Maker::GeneratePreviewJob`, `Maker::Previews::{Svg,Lbrn2,Dxf,ThreeMf,Mesh}` |
| Version history + restore | versions chain + restore | `nodes#versions`, `nodes#restore` |
| Trash / undelete | tombstones, versions kept | `trash#index`, `trash#restore`, `TrashController` |
| Human signup/login | Devise web auth + OmniAuth seam | `config/routes.rb` `devise_for :users` |
| Search by name/path | `v1/search` + item search (`q`, `type`, `tag`) | `SearchController`, `V1::Maker::ItemsController#index` |

**The existing web UI** (`FilesController` + `app/views/files/`) is a *flat file browser*
— upload/download/view/delete/trash. Maker Lite is the **catalog-shaped layer on top of
it**: items with previews, tags, collections, and a gallery UX instead of a flat list.

---

## 3. Reuse of existing server APIs (and the gaps)

### Endpoints Maker Lite consumes as-is

**Byte plane (web session-authed, server-rendered controllers):**

- `POST /files/begin_upload` → records a pending commit, presigns **only missing** chunks
  (dedup for free), returns `{ commit_id, node_id, put_urls, missing }`.
- `POST /files/finalize_upload` → verifies bytes landed, creates the immutable version +
  changelog entry, broadcasts.
- `GET /files/:id/blob` → presigned GET assembly / 302-to-storage for download + inline
  view.
- `DELETE /files/:id` → soft-delete (tombstone).
- `GET /trash` + `POST /trash/:id/restore` → undelete.

**Catalog plane (currently `namespace :v1, :maker` — device-token / Bearer authed):**

- `GET/POST/PATCH/DELETE /v1/maker/items` (+ `q`, `type`, `tag` filters).
- `POST/DELETE /v1/maker/items/:id/file_attachments` — link a node/version to an item.
- `POST/DELETE /v1/maker/items/:id/taggings`, `GET/POST/DELETE /v1/maker/tags`.
- `GET/POST/PATCH/DELETE /v1/maker/collections` (+ `items`, `add_item`, `remove_item`).
- `GET/POST /v1/maker/previews` — enqueue + poll preview status (returns the asset blob
  URL when `ready`).
- Version history via `GET /v1/nodes/:node_id/versions`, restore via
  `POST /v1/nodes/:node_id/restore`.

### The one real architectural gap: **auth surface mismatch**

The byte plane (`FilesController`) is **web-session-authed** (Devise `authenticate_user!`).
The catalog plane (`V1::Maker::*`) is **device-token / Bearer-authed** (`V1::BaseController`,
built for the sync client). A pure web client has a **session cookie**, not a device token.

Three ways to bridge (recommendation: **Option A**):

- **Option A (recommended): a web-session-authed `maker/*` controller namespace** that
  reuses the same `Maker::*` models + the same JSON shapes, but under `authenticate_user!`
  with CSRF. Concretely: a `Maker::ItemsController`, `Maker::CollectionsController`,
  `Maker::TagsController`, `Maker::PreviewsController` (web), each a *thin* delegate /
  shared concern over the logic already in `V1::Maker::*`. This keeps the device-token v1
  API untouched for the desktop product and gives the browser a clean, cookie-authed,
  CSRF-protected surface. **Lowest risk; matches how `FilesController` already lives
  outside the `v1` Bearer namespace.**
- **Option B:** issue the web session a scoped, short-lived "web device" token (the
  `FilesController` already lazily creates a `web_device` per user) and have the browser
  call `/v1/maker/*` with it. Reuses the v1 controllers verbatim but leaks a Bearer token
  into the browser and bypasses Devise CSRF — more surface, less clean.
- **Option C:** make `V1::BaseController` *also* accept a valid web session. Muddies the
  device-token contract; not recommended.

Everything else is **already there**. The only genuinely *new* server code Maker Lite
needs is:

1. **The web-authed `maker/*` controllers** (Option A) — thin wrappers / shared concern.
2. **Collection-as-zip download** (nice-to-have): a streaming endpoint that presigned-GETs
   each member file's chunks and streams a zip. Can be **client-side** in v1 (browser
   fetches each blob URL and zips with JSZip) to avoid any new server byte path — preferred
   for the MVP (keeps bytes off Rails).
3. **An "ingest a file as an item" convenience** — *optional*. Today upload (creates a
   node/version) and cataloging (create item + attach node) are two steps. A small
   server-side helper (or just client orchestration) that, on `finalize_upload`, also
   creates a `Maker::Item` + `Maker::FileAttachment` is the smoothest UX. **Prefer client
   orchestration** (call finalize, then create item, then attach) so no new server endpoint
   — the catalog endpoints already support it.

> **Net:** the only required new server work is the Option-A web-authed catalog
> controllers (a thin re-expose of existing logic). No new storage, sync, or preview
> infrastructure.

---

## 4. The upload → organize → preview → download flow (end to end)

```
 Browser                         Rails (control plane)            Object storage
 ───────                         ─────────────────────            ──────────────
 1. user drops file(s)
 2. read file, FastCDC-shaped*   ─ begin_upload (manifest) ─►  record pending commit,
    chunk + SHA-256 each chunk   ◄── put_urls (MISSING only) ─  presign PUT (dedup!)
 3. PUT chunk bytes ─────────────────────────────────────────────────────►  store
 4.                              ─ finalize_upload (commit) ─►  verify bytes, create
                                 ◄──── {version_id, seq} ─────   immutable version
 5. create Maker::Item + attach  ─ POST maker/items, ─────────►  catalog rows
    node/version                 ─ POST .../file_attachments
 6. enqueue preview              ─ POST maker/previews ───────►  GeneratePreviewJob
 7. poll preview status          ─ GET  maker/previews ───────►  {status, blob url}
 ...
 download:                       ─ GET  files/:id/blob ───────►  presigned GET / 302
                                 ◄──── bytes (off Rails) ─────   store
```

\* The browser must produce the **same content-defined chunk boundaries** the server's
refcount/dedup assumes. The existing web UI already chunks + SHA-256s in JS; Maker Lite
reuses that exact path (whole-file-as-one-chunk is acceptable for the MVP since dedup is a
bonus, not a correctness requirement — but matching FastCDC boundaries maximizes dedup
across versions/duplicates; see `docs/torn-writes-and-batching.md`). Reuse whatever the
shipped web uploader does.

**Versioning for free:** re-uploading the same logical file (same item / same node)
supplies the current `base_version_id` and creates a **new immutable version** sharing
unchanged chunks. History + restore come from `nodes#versions` / `nodes#restore` with no
new code. (Because Lite has no concurrent editors, the base is always current → clean
fast-forward; the conflict path never triggers.)

---

## 5. Client — web-first

**Web-first, server-rendered + Hotwire/Stimulus** (matching the existing `FilesController`
+ importmap stack — no SPA build needed). Rationale: lowest-friction signup (just a URL +
email/password or OAuth), zero install, works on any OS, and it's the exact funnel we want
for the "I just want a backup" user. A desktop app is the *upsell* (§9), not the entry
point.

### Auth / onboarding

- Reuse Devise: email+password signup with confirmation, plus the **OmniAuth seam** for
  "Sign in with Google/GitHub" (lowest friction). The OAuth-link-takeover constraint stays
  (don't auto-link by email — already handled by the auth team).
- First-run empty state: a big drop zone — *"Drop your STL/3MF files here to start your
  library."*

### Screens (sketch)

1. **Library (home / gallery)** — the core screen.
   - Responsive **thumbnail grid** of items (preview image or 3D snapshot, title, type
     badge, favorite star, source-site favicon).
   - Top bar: **search box** (name/tag/source), **type filter** chips (3D model / CAD /
     LightBurn / vector / all), **tag filter**, sort (recent / name / size), favorites
     toggle.
   - Left rail: **Collections** list (+ "All", "Favorites", "Recently added", "Trash").
   - Persistent **"+ Upload"** button + always-on drag-and-drop overlay.
   - Bulk-select → tag, add-to-collection, delete, download-as-zip.

2. **Item detail** — the "do I want to re-print this?" screen.
   - Large **preview**: interactive **3D viewer** for STL/3MF/OBJ/STEP (Three.js +
     `model-viewer`, fed by the `model_glb` preview kind when available, else the rendered
     thumbnail); **2D SVG render** for DXF / SVG / `.lbrn2`.
   - Metadata: title, type, origin (self-made / downloaded / modified), **source URL +
     source name** (clickable — "re-find the original maker"), tags (inline add/remove),
     favorite, file size, dates.
   - **Files** panel: each attachment (model / instructions / images / gcode) with role,
     size, **download** button.
   - **Version history**: list of versions with date/size, **download** any version,
     **restore** to make an old version current.
   - Notes / description (free text).

3. **Upload modal / drop flow** — progress per file (chunking → uploading → finalizing →
   cataloging → previewing), with a small **preview-pending** spinner that resolves to the
   thumbnail. Bulk: a list with per-file progress + a "done / failed" summary.

4. **Collections** — create/rename, drag items in, set a cover, reorder; collection page is
   a filtered gallery + "Download all as zip".

5. **Trash** — list of soft-deleted items, **restore** / permanently-delete (the latter
   just leaves chunks for GC).

6. **Settings** — account, storage used (sum of version sizes), **"Upgrade to sync"** CTA
   (§9).

### Client tech

- Hotwire (Turbo + Stimulus) over the existing importmap setup — no separate SPA.
- **Three.js** for the in-browser 3D viewer (already named as the browser preview lib in
  CLAUDE.md §4); `<model-viewer>` is a permissive (Apache-2.0) shortcut for glb.
- **JSZip** (MIT) for client-side "download collection as zip" (keeps bytes off Rails).
- Browser SubtleCrypto for chunk hashing (already used by the web uploader).

---

## 6. Preview support for the target file types

The renderer registry (`Maker::Previews::Registry`) and `GeneratePreviewJob` already cover
**every** target type. Maker Lite just **enqueues + displays** — no renderer work needed
for the core set.

| Type | Renderer (exists) | How | Toolchain |
|---|---|---|---|
| **SVG** | `Previews::Svg` | sanitize + rasterize/serve as image | pure (no native dep) |
| **LightBurn `.lbrn2` / `.lbrn`** | `Previews::Lbrn2` | parse LightBurn XML → SVG → reuse Svg | Nokogiri (MIT) |
| **DXF** | `Previews::Dxf` | parse DXF entities → SVG → reuse Svg | pure Ruby |
| **3MF** | `Previews::ThreeMf` | extract the embedded `thumbnail.png` | rubyzip (BSD-2) |
| **STL / OBJ** | `Previews::Mesh` | F3D headless render → PNG (and/or glb for the 3D viewer) | f3d (BSD-3) subprocess |
| **STEP / IGES** | `Previews::Mesh` | F3D's OCCT plugin, process-isolated in the f3d subprocess | OCCT (LGPL) stays out of our binary |

Notes:

- **Preview kinds** already modeled: `thumbnail`, `model_glb`, `render`. Lite uses
  **`thumbnail`** for the grid and **`model_glb`** (where the mesh renderer can emit glb)
  to feed the interactive 3D viewer; falls back to the static thumbnail otherwise.
- **`unsupported`** is a first-class, non-error terminal state (e.g. a native
  `.f3d`/`.sldprt` someone drops in) — the grid shows a generic type icon, never an error.
  This matters for a backup vault: users will drop *everything*, and "I can't preview it
  but I'm safely storing it" is the correct, calm behavior.
- **Toolchain availability**: the mesh/STEP path needs `f3d` installed on the box (the job
  degrades to `unsupported` if absent — `renderer.available?`). The managed deployment
  should bundle f3d; self-host documents it as optional (vector/3MF previews still work
  without it).
- **Where preview bytes live**: the rendered asset is an ActiveStorage attachment served
  by **blob URL** (off Rails) — already implemented, consistent with §8/§15.
- **No new renderers required for v1.** Anything beyond the target set (native CAD) is
  correctly `unsupported` and out of scope.

---

## 7. Import flow

All three import modes ride the **same** begin/PUT/finalize byte path; they differ only in
how the browser enumerates files.

- **Drag-and-drop (single / multi)** — drop one or many files anywhere on the library; each
  becomes an item. Default item `title` = filename (sans extension), `item_type` inferred
  from extension (`model_3d` for stl/3mf/obj, `cad` for step/iges, `lightburn` for lbrn2,
  `other`/vector for svg/dxf), `origin` default `downloaded`.
- **Bulk upload (file picker, multi-select)** — same as multi-drop via a `<input multiple>`
  fallback for mobile / no-DnD.
- **Folder import (directory drop)** — `webkitdirectory` / DataTransfer directory
  enumeration. Two behaviors, user-selectable:
  - **Flatten to items** (default for a vault): each file → an item; subfolder names become
    **tags** or a **collection** named after the top folder (great for importing a
    downloaded "thing" folder that contains `model.stl` + `instructions.pdf` + images →
    one item with multiple **file attachments** by role).
  - **Group as one item**: when a folder clearly represents *one* model (a model file + its
    readme + images), create a single item and attach the rest by `role`
    (`model` / `instructions` / `image` / `source_archive`). Heuristic: the largest mesh
    file is the primary; the rest attach. User can adjust after.
- **Source capture**: an optional "where did you get this?" field (or a browser-extension /
  bookmarklet later) that stamps `source_url` + `source_name` — the heart of the
  *"re-find the maker if it gets pulled"* promise.
- **Dedup is automatic**: re-importing the same bytes (same chunk hashes) uploads nothing
  new (begin_upload presigns only `missing`). Importing a model you already have surfaces a
  gentle "you already have this file" hint (match by manifest hash).
- **Robustness**: per-file progress, resumable in the sense that already-PUT chunks are
  skipped on retry (idempotent finalize), and a clear failed-file summary. Large folders
  upload with a bounded concurrency pool client-side.

---

## 8. Organize & search

All backed by existing models/endpoints — Maker Lite is mostly UI here.

- **Tags** (`Maker::Tag` / `Maker::Tagging`) — free-form, normalized (lowercased,
  trimmed), per-user-unique. Inline add/remove on item detail; tag filter in the gallery;
  bulk-tag selected items.
- **Collections** (`Maker::Collection` / `Maker::CollectionItem`) — named, ordered groups
  (e.g. "Halloween 2026", "Printer mods", "Client work"). An item can be in many
  collections. Cover image = first item's preview.
- **Type filters** — `item_type` chips (`model_3d`, `cad`, `lightburn`, `electronics`,
  `other`) — already an indexed scope (`Item.of_type`).
- **Favorites** — `favorited` flag, indexed, one-click star, "Favorites" pseudo-collection.
- **Search** — the item index already supports `q` (title/summary/description, case-
  insensitive on SQLite + Postgres), `type`, and `tag`. Lite wires the search box +
  filters to it. (Filename/path search is also available via `v1/search` if needed.)
- **Source-site grouping** (nice-to-have) — facet by `source_name` ("show everything from
  Printables").

> Inventory / projects / BOM are intentionally **not** surfaced (§1 out-of-scope). The
> models exist; Lite simply doesn't show them. They're the "maker workspace" expansion.

---

## 9. The upsell path into the full synced/mounted product

Maker Lite and the full product **share the same account, same library, same byte store,
same versions**. That's the whole point: upgrading is *enabling a client*, not migrating
data.

- A Lite user's files are already real `nodes` + `versions` + `chunks` under their
  `user_id`. The day they install the desktop app, it **pairs to the same account**
  (`POST /v1/devices/login` — the Dropbox email+password → device-token model already
  shipped), runs the sync engine, mounts the drive, and **their entire vault hydrates on
  demand** as a native folder. Zero data migration.
- **In-product upsell surfaces:**
  - Settings → **"Get the desktop app — your library as a real folder, synced
    everywhere."**
  - When a user has uploaded N files / hit a storage tier → "Working with these a lot?
    Mount them locally so your slicer/LightBurn open them directly."
  - On item detail → "Edit this in your CAD tool" → nudge toward the mount (where opening +
    saving round-trips automatically instead of download → edit → re-upload).
- **Monetization shape** (consistent with CLAUDE.md §1 managed model): Lite = the free /
  low tier (web vault, capped storage); **Sync + Mount = the paid tier** (native drive,
  multi-device, larger storage). Self-host gets both.
- **Honest framing in the upsell:** Lite is *backup + browse*; the paid product is *work
  with your files in place*. The re-upload-makes-a-new-version flow in Lite is the manual
  version of what the mount does automatically — a natural "this is tedious, automate it"
  moment.

---

## 10. Phased build plan + rough effort

Effort is rough engineer-time for someone fluent in this codebase; the heavy lifting
(storage, versions, catalog, previews) is **already done**, so most phases are wiring + UI.

### Phase 0 — Web-authed catalog surface (the only real new server work) — ~2–3 days
- Add the **Option-A web-session-authed `maker/*` controllers** (items, file_attachments,
  taggings, tags, collections, previews) as thin delegates over the existing `Maker::*`
  models / `V1::Maker::*` logic (extract a shared concern). CSRF + `authenticate_user!`.
- Tests: the existing v1 maker controller tests, mirrored for the web-authed routes.
- *Deliverable:* the browser can CRUD the catalog with a session cookie.

### Phase 1 — Upload → item → catalog (vault MVP) — ~4–6 days
- Library gallery view (grid of items) + empty state.
- Drag-and-drop + bulk **upload** wired to the existing begin/PUT/finalize path; on
  finalize, client orchestrates **create item + attach node/version** (no new endpoint).
- Item detail page with metadata, download (original + per-attachment), delete/trash.
- Source URL/name capture on upload.
- *Deliverable:* a usable backup vault — drop files, see them, download them back.

### Phase 2 — Preview integration — ~3–4 days
- On finalize, **enqueue a preview** (`maker/previews` POST); poll + display in grid +
  detail.
- Interactive **3D viewer** (Three.js / model-viewer) for mesh/CAD via `model_glb` (or
  thumbnail fallback); **2D viewer** for svg/dxf/lbrn2.
- Ensure `f3d` is present in the managed image (doc it for self-host); verify
  `unsupported` degrades gracefully.
- *Deliverable:* recognize files at a glance; inspect models in-browser.

### Phase 3 — Organize & search — ~3–4 days
- Tags (inline + bulk), collections (create/add/reorder/cover), type filters, favorites,
  search box wired to `q`/`type`/`tag`.
- Left-rail navigation (collections, favorites, recent, trash).
- *Deliverable:* a real library you can actually find things in.

### Phase 4 — Folder/bulk import polish + versioning UX — ~3–5 days
- Folder import (`webkitdirectory`) with flatten-vs-group + role attachment heuristics.
- Bounded-concurrency bulk uploader with progress + failure summary + dedup hints.
- Version history UI (list / download-any / restore) on item detail; re-upload → new
  version.
- *Deliverable:* import a whole downloads folder; version safety.

### Phase 5 — Polish, upsell, ops — ~3–5 days
- Trash/undelete UI, storage-used meter, account/settings.
- "Download collection as zip" (client-side JSZip).
- Upsell surfaces (§9) + "get the desktop app" funnel.
- OAuth sign-in (OmniAuth) for lowest-friction signup.
- *Deliverable:* shippable Maker Lite + a clear path to the paid sync product.

**Rough total: ~3–4 weeks** for one engineer, dominated by front-end/UX since the storage,
versioning, catalog, and preview engines are all already built and tested.

### Risks / watch-items
- **Auth bridge** (§3) — pick Option A early; it's the only structural decision.
- **Browser chunking parity** — match whatever the shipped web uploader does so dedup +
  refcounts stay correct; whole-file-as-one-chunk is a safe MVP fallback.
- **f3d availability** — mesh/STEP previews need the toolchain; degrade to `unsupported`
  cleanly when absent (already handled by the job).
- **Large folder imports** — throttle client concurrency; keep finalize idempotent.
- **Keep bytes off Rails** — every new path (incl. zip download) must use presigned URLs /
  client-side assembly; no new bytes-through-Rails route.

---

## 11. Summary

Maker Lite is a **web-first personal model-library / backup vault** built almost entirely
from primitives already on `main`: the content-addressed versioned byte store (presigned
upload/download), the maker Library pillar (items / tags / collections / attachments), and
the preview pipeline (SVG / DXF / LightBurn / 3MF / STL / OBJ / STEP renderers). It
deliberately **omits the sync engine and all mounts** — pure upload/organize/preview/
download/version — to give the "I just want my STLs backed up and findable" user a
zero-install on-ramp. The only genuinely new server work is a thin **web-session-authed
catalog controller surface** (Option A); everything else is front-end wiring. It shares
the account + library + storage with the full product, so the upgrade to the synced,
native-mounted experience is **enable-a-client, not migrate-data** — making Lite the
natural funnel into the paid offering. Estimated ~3–4 weeks for one engineer.
