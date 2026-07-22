# Auto project library folders (all three backends)

**Date:** 2026-07-22
**Status:** approved (design)
**Scope:** a `Projects/<name>/` library folder auto-created per project, into which files uploaded
**from the project view** are placed. Adds a **`mkdir` verb to the `FileLayer` port** (Share + S3;
refused on Chunk), a **`Maker::LibraryFolder` service** that also covers the chunk sync-mutation
path, a `folder_node_id` column on `maker_projects`, and wires the project upload flow to pass the
folder as the upload parent. Works on **chunk, share, and s3**. Notes are a SEPARATE follow-up spec.

## Problem

Files uploaded from a project's Files panel currently land at the **library root** (the Task 12
upload flow passes `parent_node_id: nil`). Users want each project's uploads organized under
`Projects/<project>/`, with the `Projects` root and the per-project folder **auto-created**.

This was explicitly deferred in the Projects-web-UI spec ("a per-project `Projects/<slug>/` upload
folder is deferred — it needs a session-auth `mkdir` the web layer does not have yet"), because
**folder creation has no cross-backend path**:
- **chunk** (`syncable`): the sync engine owns the tree — a folder is `Sync::Mutation.apply(op: "mkdir")`.
- **share/s3** (`port_writable`): the tree is a *reflection of the store* — inserting a bare dir
  node is undone by the next scan; a folder must exist **in the store** (a real NAS directory / a
  bucket prefix) so the scan reconciles it.

The `FileLayer` port has **no `mkdir`** (`stat`/`stat_all`/`read`/`download`/`write`/`delete`/
`move`/`undelete`/`trashed` only). This spec adds it, honestly, for the two backends that own their
bytes, and routes chunk through the sync engine as everything else does.

## Decisions (from brainstorming)

- **All three backends** (chunk, share, s3). Not chunk-only.
- **Notes render as markdown** — that is a *separate* feature/spec; this spec is folders only.
- **Folder named from the project `slug`, tracked by `node_id`.** The slug is **unique per user**
  (the model enforces it), so each project gets its OWN folder with no collision/disambiguation
  logic, and it is already filesystem-safe (`desk-lamp`: lowercase, hyphenated, ASCII). Renaming a
  project does **not** move/rename its folder (the `folder_node_id` link survives; far simpler, and
  avoids a cross-backend dir-rename). Recorded so it isn't "fixed" as a bug.
- **Only uploads land in the folder.** Attaching an *existing* library file does not relocate it
  (that would be a `move`, out of scope). The folder is where *new* uploads from the project go.
- **Folder creation is best-effort at project-create and re-ensured at upload.** A momentarily
  unreachable backend must never fail project creation.

## Approach

### 1. New port verb: `mkdir(user, parent_node_id:, name:) -> FileInfo`

Creates ONE directory `name` under `parent_node_id` (nil = library root) and returns its `FileInfo`
(so the caller gets the new dir's `node_id`). Idempotent-friendly: if a live dir of that name
already exists under the parent, return it rather than raising.

- **`FileLayer::Share#mkdir`**: `rel = join(parent_rel, name)`; `FileUtils.mkdir_p(root/rel)`;
  `create!` a dir node (`kind: "dir", storage_path: rel, parent_node_id:`). The real directory +
  the dir node reconcile by path on the next scan (dir nodes pair on `storage_path`), so it
  survives. Reuses `parent_dir_rel!` / `observable!` / `resolve_inside!` (the same escape-guarded
  path resolution `write` uses).
- **`FileLayer::S3#mkdir`**: `key = "#{prefix}/#{rel}/"` (trailing slash — a **dir-marker** object,
  the shape the S3 console mints and the `S3Observer` already recognizes as a dir, not a phantom
  file — CLAUDE.md §3); `put_object` a zero-byte marker; `create!` a dir node (`storage_path: rel`).
  The marker is what makes an **empty** project folder survive a scan (no marker → no prefix → the
  reconciler would tombstone the dir node). A later file upload into the folder adds real objects
  under the prefix; the marker is harmless alongside them.
- **`FileLayer::Chunk#mkdir`**: **refused** — `raise UnsupportedOperation` (or the same
  door-naming refusal `write`/`delete`/`move` use), because chunk tree mutations belong to the sync
  engine, not the port. The service (below) never calls it; the refusal is the backstop.

The read contract (`adapter_contract.rb`) and write contract (`adapter_write_contract.rb`) get
`mkdir` coverage: Share + S3 create a navigable dir node; a duplicate name returns the existing dir
(no clobber); the created dir has a `storage_path` and shows up in `stat`.

### 2. `Maker::LibraryFolder` — the cross-backend "ensure this path" service

```
Maker::LibraryFolder.ensure_path!(user, ["Projects", name]) -> Node (the leaf dir)
```

Walks the segments from the root, find-or-creating each dir. **Branches once**, on the capability
the rest of the app already branches on:

- `FileLayer.current.capabilities.port_writable?` → create each missing segment via
  `FileLayer.current.mkdir(user, parent_node_id:, name:)` (share/s3).
- else (chunk, `syncable`) → create each missing segment via
  `Sync::Mutation.apply(user:, node: <new dir node>, op: "mkdir")` + `LibraryChannel.broadcast_change`
  — the identical door `V1::NodesController#mkdir` and the web upload path already use.

"Find" = `user.nodes.present.find_by(parent_node_id:, name:, kind: "dir")`. The backend-branching is
**sealed inside this one service** — controllers never see it. This is the §10-honest seam: folder
creation is a *file-layer* concern (extending the port + the existing chunk sync door), invoked by
the maker layer through one service, not the project controllers reaching into `Sync::` themselves.

### 3. `maker_projects.folder_node_id` + ensure-on-create

- Migration: add `folder_node_id` (string, nullable) to `maker_projects`.
- `ProjectsController#create`, after `@project.save`: best-effort
  `folder = Maker::LibraryFolder.ensure_path!(current_user, ["Projects", @project.name])` then
  `@project.update_column(:folder_node_id, folder.node_id)`. **Rescued** (`FileLayer::FetchError`,
  and — for the chunk path — any transient) so a backend blip logs + leaves `folder_node_id` nil;
  the project still saves. The folder is re-ensured lazily on the next upload.
- `Project#ensure_library_folder!(user)` helper: returns the folder node, (re)creating it if
  `folder_node_id` is nil or points at a tombstoned/missing node (user deleted it in the browser).
  This is the method the upload flow calls.

### 4. Upload flow passes the project folder as parent

- **Share/s3** (`Projects::UploadsController#create`): replace `parent_node_id: nil` with
  `parent_node_id: project.ensure_library_folder!(current_user).node_id` (folder resolved
  server-side). Build-log **entry-photo** uploads keep going to the library root in v1 (Out of scope).
- **Chunk** (the browser two-phase flow through `/files/begin_upload`): the project's
  `_upload_control` chunk branch adds `data-uploader-parent-value="<folder_node_id>"`, and
  `uploader_controller.js` includes it as `parent_node_id` in the `begin_upload` POST (which already
  accepts one). The folder is ensured when the project page renders (so `folder_node_id` is fresh).

Since the folder is resolved/re-ensured at upload time, a deleted or never-created folder is
recreated transparently.

### 5. Naming + the root

- The `Projects` root dir is the first segment — shared by all projects, created once.
- The per-project segment is the **project `slug`** (`desk-lamp`) — unique per user by the model's
  own uniqueness validation, so `ensure_path!`'s find-or-create by `(parent, name, kind: "dir")`
  gives each project exactly one folder with **no disambiguation logic**, and it is already
  filesystem-safe (lowercase, hyphenated, ASCII). A human browsing the NAS sees
  `Projects/desk-lamp/` — readable enough; a prettier display name is a backlog nicety not worth
  per-backend collision handling.

## §10 note

This **extends the file layer** (a new `mkdir` port verb + the existing chunk sync-mkdir door),
which is legitimate file-layer work — not the maker layer improperly reaching into sync. The
coupling is sealed in `Maker::LibraryFolder`; `ProjectsController`/`UploadsController` call the
service and never touch `Sync::`/the port's mkdir directly. If implementing this starts requiring
changes to the changelog, conflicts, locks, or the mounts, stop — that's the boundary talking.

## Error handling

- Backend unreachable at project-create → folder not made, `folder_node_id` nil, project saves;
  re-ensured on next upload. No user-facing failure for the folder itself.
- `mkdir` clobber (a *file* already exists at that path) → `UnsupportedOperation`, surfaced as a
  flash on the upload path (the upload controller already maps it post-review-fix).
- User deletes the project folder in the Files browser → `ensure_library_folder!` recreates it on
  next upload (old uploaded files that were inside it are gone with it — expected).

## Testing (all three backends)

- **chunk** (`pin_file_layer_backend("chunk")`): creating a project makes `Projects/<name>` dir
  nodes (via Sync::Mutation, changelog entries present); a project-view upload lands under the
  folder (`parent_node_id` == folder); re-ensure after deleting the folder.
- **share** (`FileLayer.current = Share.new(root: tmp)`): project create makes the real directory
  on disk + dir nodes; upload writes into `root/Projects/<name>/`; a `Library::Scanner` pass leaves
  the (even empty) folder intact (path-reconcile) — the empty-folder-survives-scan test.
- **s3** (`FileLayer.current = S3.new(client: FakeS3…)`): project create puts a `Projects/<name>/`
  dir-marker + dir nodes; upload puts an object under the prefix; an `S3Observer`/`Reconciler` pass
  keeps the empty folder (marker → dir, not a phantom file).
- `LibraryFolder.ensure_path!` unit tests: find-or-create idempotency; nested path; the
  capability branch (a fake `port_writable` layer vs. a chunk stub) — mirroring the `ThumbnailMap`
  fake-adapter pattern (this repo has no `minitest/mock`).
- Contract additions: `mkdir` on Share + S3 in the write contract; Chunk refuses.
- Runs on `bin/rails test`, `LIBRARY_BACKEND=share`, `LIBRARY_BACKEND=s3` (the three CI legs).

## Out of scope (→ backlog)

- Renaming/moving a project's folder when the project is renamed (folder is create-once, node_id-tracked).
- Relocating *attached-existing* files into the folder (that's a `move`).
- Build-log *photo* uploads landing in the project folder (they can stay at root, or a
  `Projects/<name>/photos/` subfolder — a small follow-up; v1 keeps entry-photo uploads as-is).
- A UI to change a project's folder or re-link it.
