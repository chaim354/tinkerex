# Design: split the maker layer from the file layer (share / S3-backed web version)

**Date:** 2026-07-14 · **Status:** DESIGN (approved, no code yet)

> **One-liner:** let a deployment back the maker layer (projects / inventory / BOM /
> previews) with a **plain network-share folder** or the **user's own S3-compatible
> bucket** instead of the FastCDC chunk/manifest sync engine — for the **web version**,
> with no daemon, no mount, no sync.

---

## 1. Why

The product today is one stack: the maker layer sits on top of the local-first sync engine
(`CLAUDE.md` §2), so every file must live in the content-addressed chunk store. That's the
right engine for the synced-drive product, but it forces a self-hoster who already has
**2TB of STLs on a NAS** to copy everything into our chunk store before they can use the
maker layer at all.

This design targets the opposite on-ramp — the Immich / Photoprism "external library"
shape:

> *"Point tinkerex at `/mnt/nas/models`. Index what's already there. Give me previews,
> tags, projects, and a BOM on top. Don't move my files."*

The maker layer's coupling to the file layer is already narrow: `Maker::FileAttachment`,
`Maker::Preview`, and `Maker::BomLine` reference files only by an opaque `node_id` +
`version_id`. The actual leak is a **single service** — `Maker::FileBytes` — which reaches
through `version.manifest_chunks` into `Storage::ChunkStore`. So this is widening one seam,
not a rewrite.

## 2. Decisions (settled — do not relitigate without new information)

| # | Decision | Rationale |
|---|---|---|
| 1 | **Backend chosen per deployment**, `LIBRARY_BACKEND=chunk\|share\|s3` | No `Source` model, no per-source capability logic. An instance is the sync product or the web-over-your-folder product. Mirrors the existing `STORAGE_BACKEND` factory. |
| 2 | **Index existing *and* write new** | The point is an existing library; but the web UI must still upload. Costs a scanner + external-change reconciliation. |
| 3 | **Current-state only on share/s3 — no version history, no restore** | A plain share has no history: when a user overwrites `bracket.stl` in Finder the old bytes are gone. `CLAUDE.md` §5 ("keep versions so restore always works") **cannot** hold on storage we don't own. Being honest beats faking it. Restore stays a chunk-backed feature and a real upgrade reason. |
| 4 | **Identity = `node_id` in our DB**, reconciled on scan: path → `(content_hash, size)` | Users reorganize a NAS constantly. Path-as-identity would break every attachment on rename. Sidecar id files pollute the folder we promised was "just your files". |
| 5 | **Periodic incremental scan + manual "Rescan now"** | `inotify`/FSEvents do not reliably fire for changes made by *other* machines over SMB/NFS, and S3 can't be watched at all. One code path for all three backends; changes appear within the interval. |
| 6 | **Bytes:** share → Rails streams (X-Accel/X-Sendfile when available); S3 → presigned | A mounted directory cannot be presigned. §15 ("keep bytes out of Rails") was aimed at managed/WAN scale + egress cost; a self-hosted box serving its own NAS over a LAN is a different problem. §15 survives intact where it was aimed (S3, and the whole chunk mode). |
| 7 | **Delete → trash → 30-day purge** | Unlinking a file from the user's own NAS with no version history is genuinely destructive. Trash gives a bounded undo and matches the existing chunk-mode trash/undelete UI. |

## 3. Architecture

### 3.1 `version_id` becomes a content-state token

`maker_previews` is unique on `(user_id, node_id, version_id, kind)` and `version_id` is
already nullable — but **NULLs are distinct in a unique index** on both SQLite and
Postgres, so leaving it NULL in share mode would silently disable that constraint and
accumulate duplicate previews per file.

So `version_id` is reinterpreted as an opaque **content-state token**:

- **chunk mode:** an immutable version UUID — bytes are restorable (unchanged from today).
- **share/s3 mode:** the file's **content hash** — identifies the bytes, does not imply they
  are recoverable.

Three things fall out: previews auto-invalidate when content changes (new hash → new token
→ new row), a `FileAttachment` can still pin "this exact content", and **no maker model
changes at all**.

**Naming:** the port calls this value `content_token` (`FileInfo#content_token`); the
database column that stores it is the existing `version_id` on `maker_previews` /
`maker_file_attachments`. They are the same value — the port name is backend-neutral, the
column name is retained to avoid a pointless migration of existing rows.

### 3.2 The `FileLayer` port

Selected at boot, mirroring `Storage::ChunkStore.current`. Adapters: `Chunk` (wraps today's
version→manifest→chunk path), `Share` (a mounted directory), `S3` (their bucket).

```ruby
FileLayer.current                                  # LIBRARY_BACKEND=chunk|share|s3
  # read
  .stat(user, node_id:)                            -> FileInfo(node_id, name, path, size, mtime, content_token, kind)
  .list(user, parent_node_id:)                     -> [FileInfo]
  .read(user, node_id:, content_token: nil)        -> bytes        # server-side: preview jobs
  .download(user, node_id:)                        -> Delivery     # browser-bound bytes
  # write
  .write(user, parent_node_id:, name:, io:)        -> FileInfo
  .delete(user, node_id:)                          # -> trash
  .move(user, node_id:, new_parent_node_id:, new_name:)
  # introspection
  .capabilities                                    -> versioned? syncable? presignable?
```

`Delivery` is the polymorphic byte path — one controller serves all three backends:

| Variant | Backend | Behavior |
|---|---|---|
| `Redirect(url)` | S3 | presigned GET; bytes never touch Rails (§15 preserved) |
| `SendFile(abs_path)` | share | X-Accel-Redirect / X-Sendfile when configured, else `Rack::Files` |
| `Stream(enum)` | chunk | today's stitched-chunk enumerator, unchanged |

### 3.3 One catalog

`nodes` remains the universal catalog for every backend, so `node_id` stays the single file
identity and **browse / search / tags / the file picker keep working unmodified**. Directory
nodes are synthesized from paths, so `parent_node_id` still forms the tree.

The sync surface — v1 API, changelog, ActionCable, devices/pairing, conflicts, locks — is
mounted **only in chunk mode**. In share/s3 the maker layer and web UI are the whole product.

`Maker::FileBytes` stops being a chunk-store client and becomes a thin caller of the port.

### 3.4 Model changes (one additive migration)

`nodes` gains:

- `size` (bigint) — today size lives on `versions`, which share mode has none of
- `content_hash` (string)
- `storage_path` (string) — relative to the configured root
- index `(user_id, content_hash)` — move detection during scan
- unique index `(user_id, storage_path)`

Chunk mode leaves all three null and behaves exactly as today.

### 3.5 Configuration + boot guard

`LIBRARY_BACKEND=chunk|share|s3`; share adds `LIBRARY_PATH`; s3 adds `LIBRARY_S3_*`.
Additional knobs: `LIBRARY_SCAN_INTERVAL` (default 15m), `LIBRARY_TRASH_DAYS` (default 30,
`0` = never purge), `LIBRARY_SCAN_MAX_DELETE_PCT` (default 20).

`lib/library_backend_check.rb` + initializer, following the `postgres_pooler_check.rb`
precedent: refuse to boot in share mode when the root is missing, unreadable, or unwritable,
rather than surfacing it as a 500 on first upload.

## 4. Components

| Component | Path | Role |
|---|---|---|
| `FileLayer` port + factory | `app/services/file_layer/` | the seam; capabilities; `Delivery` |
| `FileLayer::Chunk` | `app/services/file_layer/chunk.rb` | wraps version→manifest→chunk (today's behavior) |
| `FileLayer::Share` | `app/services/file_layer/share.rb` | mounted directory |
| `FileLayer::S3` | `app/services/file_layer/s3.rb` | user's bucket |
| `Library::Scanner` | `app/services/library/scanner.rb` | incremental namespace walk |
| `Library::Reconciler` | `app/services/library/reconciler.rb` | the matching algorithm |
| `Library::ScanJob` | `app/jobs/library/scan_job.rb` | `recurring.yml` + manual trigger |
| `Library::TrashPurgeJob` | `app/jobs/library/trash_purge_job.rb` | `recurring.yml`, purge > N days |
| boot guard | `lib/library_backend_check.rb` | refuse to boot on a bad root |

Previews keep using ActiveStorage for the rendered thumbnail — that artifact is ours, not
the user's file.

## 5. Data flow

### 5.1 Scan → reconcile

1. `ScanJob` (interval) or "Rescan now" → walk the namespace (`Dir` for share,
   `list_objects_v2` for S3), yielding `(path, mtime, size)`. **`.trash/**` is excluded.**
2. Look up the node by `(user, storage_path)`:
   - **unchanged** `(mtime, size)` → skip, no hashing (keeps a 2TB archive cheap);
   - **changed** → hash → update `content_hash`/`size`/`mtime` → new content token →
     enqueue preview;
   - **absent from DB** → hash → hold as a match candidate.
3. Pair leftovers — DB nodes whose path vanished vs. disk entries with no node — by
   `(content_hash, size)`. A unique pair is a **move**: keep `node_id`, update
   `storage_path`; every attachment survives.
4. Unpaired DB nodes → **tombstone** (`deleted = true`, row kept) so a project shows
   "file missing" instead of an attachment silently vanishing.
5. Unpaired disk entries → new node + fresh `node_id` + preview job.

**Ambiguity:** several byte-identical files make the pairing non-unique. Tie-break
deterministically — (a) nearest common directory to the old path, (b) then lexical path
order — and log the ambiguity; worst case degrades to delete + create. A move *and* edit in
the same interval is indistinguishable from delete + create — accepted, documented.

**First scan of a large archive.** The scanner hashes every file on first scan (correctness
over speed: without hashes there is no move detection). It writes nodes incrementally, so the
library becomes browsable while the scan is still running, and it **checkpoints** progress
(last completed path / S3 continuation token) so a multi-hour first scan of a 2TB archive
survives a restart instead of starting over.

### 5.2 Upload

POST → validate the name against traversal; the resolved absolute path must live under the
root → `FileLayer.write` streams to the backend, hashing as it goes → share writes to a temp
file and **atomically renames** into place (a half-uploaded file is never visible in the
user's Finder) → upsert node → enqueue preview.

**v1 simplification:** uploads stream through Rails in *both* share and s3 mode. S3 could
presign the PUT (preserving §15), but then the bytes never pass us, so we'd have to trust an
ETag (not a content hash for multipart) or re-read the object. Presigned S3 upload is a
documented later optimization.

### 5.3 Download / preview

`FileLayer.download` → `Delivery` → the controller redirects (S3), `send_file`s (share), or
streams (chunk). Preview jobs call `Maker::FileBytes.read` → `FileLayer.read`. Because
previews key on the content token, an edited file re-renders automatically.

## 6. Error handling & safety

**Delete → trash → purge.** `FileLayer.delete` moves the file to
`<root>/.trash/<node_id>/<name>` — keyed by `node_id` so two deleted `bracket.stl`s can't
collide. Share: atomic rename within the same filesystem. S3: copy+delete — **tombstone only
after the copy confirms**. The node is tombstoned, not destroyed; undelete is a move back.
`TrashPurgeJob` purges entries older than `LIBRARY_TRASH_DAYS`. The scanner skips `.trash/**`
— otherwise it re-indexes trashed files as new ones and resurrects them (the same bug class
as the `pull_snapshot` ghosts fixed on 2026-07-14).

**Capability degradation.** The UI reads `FileLayer.current.capabilities` and hides
Restore/History/Conflicts/Devices in share mode. The API returns **501 Not Implemented**
(not 500) — an honest "this deployment can't do that".

**Byte failures.** Reuse the distinction `Maker::FileBytes` already draws (written for a real
production incident): `NotFound` (genuinely gone → terminal, mark preview failed) vs
`FetchError` (403/5xx/timeout → transient → retry). The share adapter maps `ENOENT` →
`NotFound`, but `EACCES` / `EIO` / stale NFS handle → `FetchError`. An unmounted NAS must
**never** read as "the user deleted 40,000 files".

**Mass-deletion guard.** If a scan finds the root empty/missing, or more than
`LIBRARY_SCAN_MAX_DELETE_PCT` of the library disappearing at once, **abort and alert** rather
than tombstoning the library. Immich, Photoprism, and Plex each learned this the hard way.

**Scan robustness.** Symlink loops (visited-set), permission errors (skip + log, never
tombstone), files vanishing mid-scan (skip).

## 7. Testing

- **Shared port-contract suite** run against all three adapters — the mechanical guard
  against chunk-specific assumptions leaking back into the port (the one real cost of this
  approach).
- **Reconciler, table-driven** — rename, move, edit, move+edit, duplicates/ambiguity, add,
  delete. The whole "attachments survive reorganization" promise rests here.
- **Scan safety** — mass-deletion guard trips on an unmounted root; permission errors skip
  rather than tombstone; symlink loops terminate; `.trash/**` excluded.
- **Trash/purge** — same-name collisions; `LIBRARY_TRASH_DAYS` honored; undelete; S3 copies
  before tombstoning.
- **Write safety** — writes outside the root rejected.
- **Delivery variants** — S3 redirects; share `send_file`s + emits X-Accel when configured;
  chunk streams.
- **The headline promise, end-to-end** — attach a file to a project, rename it on disk,
  rescan, assert the attachment + preview still resolve; then edit it and assert the preview
  re-renders.
- **CI matrix** — run the server suite a second time with `LIBRARY_BACKEND=share` against a
  tmpdir root (cheap, no external services); it's the only thing stopping the two modes from
  silently diverging. S3 gets a stubbed client.

> Testing bias: every critical bug in the 2026-07-14 full-stack audit lived at a **seam** —
> components that were each fine alone. Here the seams are scan↔maker-references and
> port↔adapters, so tests concentrate there rather than on adapter internals.

## 8. Explicitly out of scope

- Sync/mount for share-backed libraries (no chunks → nothing to sync). Web only.
- Version history / restore / conflicts / locks on share-backed libraries (decision 3).
- Presigned S3 upload (documented optimization, §5.2).
- Multiple sources per account (decision 1) — a deployment picks one backend.
- Migrating an existing chunk library to a share, or vice versa.

## 9. Suggested phasing (for the implementation plan)

Each phase is independently shippable and leaves the tree green.

1. **Port + `Chunk` adapter — pure refactor, no behavior change.** Introduce `FileLayer`,
   move `Maker::FileBytes` onto it, add the shared contract suite. Chunk mode is the only
   backend; the whole existing suite must stay green. This proves the seam before anything
   depends on it.
2. **`Share` adapter + scanner/reconciler + trash + boot guard.** The migration, the
   `LIBRARY_BACKEND=share` CI leg, and the headline end-to-end test (rename on disk →
   attachment survives).
3. **`S3` adapter.** Reuses the scanner via `list_objects_v2`; adds the `Redirect` delivery.
4. **Capability gating in the web UI + 501s** for the sync surface.

## 9a. Deferred to Phase 2 (surfaced by the Phase 1 code review, 2026-07-14)

Real issues found while building the port. Each needs a behavior change or a product decision,
so they are recorded rather than smuggled into Phase 1's pure refactor (see §10).

1. **Deleted-node read semantics — decide before `Share` lands.** `Chunk#stat` uses the
   `present` scope (tombstoned → `NotFound`), but `Chunk#read` does not, so a trashed node's
   bytes are still readable. That inconsistency is inherited and harmless with one adapter —
   but `Share`'s trash is a real filesystem move to `<root>/.trash/…` (§6), so `Share#read`
   on a tombstoned node *cannot* return bytes and will raise `NotFound`. Two adapters, same
   call, opposite answers, and the contract asserts nothing about it. Decide "tombstoned =
   gone" (likely) and pin it with a contract test.
   *Not a one-word fix:* `read`'s by-token path resolves through `user.versions` and never
   touches `nodes`, so the asymmetry survives inside `read` itself; and the existing
   `file_bytes` tests construct `Version` rows with no `Node` row, so a node-presence check
   changes real behavior and breaks them. Hence Phase 2.
2. **Pin retryability in the contract.** The contract asserts `NotFound` in four places and
   `FetchError` in zero, so an adapter could answer a transient failure with `NotFound` and
   pass. For `Share` that is exactly the "an unmounted NAS must never read as *the user
   deleted 40,000 files*" failure in §6. Needs a per-adapter "make the backend fail
   transiently" hook, which is only meaningful once a second adapter exists.
3. **`capabilities.presignable` is answered statically but is a property of the store.**
   `Chunk` hardcodes `presignable: true` (accurate today for all three chunk stores) while
   `Chunk.fetch` separately duck-types the same question via `respond_to?`. Two mechanisms,
   two places. Consider delegating to `Storage::ChunkStore.current`.
4. **`Chunk.fetch`'s `respond_to?` sniffing puts backend knowledge in the wrong class.**
   `Storage::ChunkStore` already owns backend polymorphism; the adapter reaches around it and
   duck-types, order-dependently and failing open (if `S3ChunkStore` ever gains a `read`, the
   presign path is silently bypassed with no test failing). A `ChunkStore#read_bytes` template
   method plus three overrides would delete the sniffing.
5. **`MAX_BYTES` overflow raises `NotFound` for a file that is emphatically found.** The port
   documents two categories (terminal-absent, transient); "too big" is a third — terminal but
   present. The behavior is right, the taxonomy isn't. `Share`/`S3` will each face the same
   choice. Also the check is post-append, so the cap is approximate by up to one chunk.
6. **Contract hook shape.** `adapter` and `create_file!` are methods but `@user` is an ivar
   reached into directly; a `user` reader would let an adapter that constructs its user
   differently satisfy the contract without mimicking an ivar name.

## 10. Non-goals restated (so the plan doesn't drift)

This spec does **not** change chunk mode's behavior. If any phase requires a change to sync,
the changelog, conflicts, locks, or the mount adapters, that is a signal the boundary is
wrong — stop and revisit the design rather than reaching into the sync engine.
