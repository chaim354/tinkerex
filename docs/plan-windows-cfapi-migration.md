# Plan: migrate the Windows mount from WinFsp to CfAPI (Cloud Filter API)

**Status:** sketch / design intent (not started). Companion to the per-OS mount story in
`CLAUDE.md` §4 + §12 step 4 (WinFsp, done) and the forward-compat notes in
`docs/plan-real-mtime-and-invalidation.md` (the `Invalidate` seam was built to land here).

## Why

WinFsp works and is shipped (`fs-winfsp`, a drive letter), but it has two costs CfAPI removes:

1. **Licensing (§9, the real driver).** WinFsp's kernel driver is **GPL**; we keep it out of
   our binaries by making it user-installed, but that's a worse install story (user fetches
   WinFsp, `winfsp-x64.dll` must be on PATH) and a permanent footnote. **CfAPI is part of
   Windows** (`cldapi.dll`, the API OneDrive itself uses) — **no driver, no copyleft, nothing
   to bundle or ask the user to install.** This is the §9 win and the stated Windows
   preference ("on Windows prefer native CfAPI (no driver)").
2. **Native UX.** CfAPI files live in a normal folder under the user's profile (not a drive
   letter), with first-class Explorer integration: per-file **availability** (online-only vs
   always-on-device), sync-state overlays, "Free up space" / "Always keep on this device",
   and progress UI — the OneDrive/Dropbox experience, for free.

This is **another adapter over the same `Provider`** — the architecture's whole point — but
CfAPI **inverts the data-plane model**, which is the substance of the work (see Design §0).

## Design

### 0. The model inversion (read this first)

| | FUSE / WinFsp (today) | CfAPI |
|---|---|---|
| Files on disk | virtual — **we serve every** `read`/`write`/`getattr` | **real NTFS files**; the OS serves hydrated reads/writes directly |
| We are asked for | every op, synchronously | only: **fetch data** (hydrate), **enumerate** (populate), and **notifications** of change |
| Local writes reach us via | `write`/`flush` callbacks | we **detect** them (dirty placeholder state / change notifications) and pull bytes off disk |
| Remote change applied by | repoint manifest + `invalidate(ino)` | `CfUpdatePlaceholder` (+ dehydrate) — *the same idea, different call* |

So `fs-cfapi` is **not** a drop-in like `fs-winfsp` was. The `Provider` stays the metadata +
content-addressed chunk authority, but the read/write halves of the seam change shape: the OS
owns the on-disk bytes; we own the *truth* (tree, versions, chunks) and *bridge* the two.
What maps cleanly is the part we already built; what's new is **local-change capture**.

### 1. Sync-root registration + connection lifecycle
- Register the library folder as a **sync root**: `StorageProviderSyncRootManager.Register`
  (WinRT, `windows::Storage::Provider`) — display name, version, `HydrationPolicy` (e.g.
  `Full` or `Progressive`), `PopulationPolicy` (`Full` vs `AlwaysFull`/on-demand),
  `InSyncPolicy`, icon, and a **provider id** (per user/library). This is also what lights up
  the Explorer integration.
- Connect callbacks: `CfConnectSyncRoot` (`windows::Win32::Storage::CloudFilters`) with a
  `CF_CALLBACK_REGISTRATION` table → a connection key held for the session (the `Daemon`'s
  Windows equivalent owns it, like the FUSE `BackgroundSession`). `CfDisconnectSyncRoot` +
  `CfUnregisterSyncRoot` on stop.

### 2. Populate the tree as placeholders (from the local SQLite Provider)
- Walk `Provider::export_tree`/`readdir`; `CfCreatePlaceholders` for each node carrying:
  - **`FileIdentity`** = our stable `node_id` (opaque blob CfAPI hands back on every callback
    — this is the node_id↔path bridge, replacing `fs-winfsp`'s path↔inode map).
  - **`FsMetadata`** = `FILE_BASIC_INFO` with **size** + **`LastWriteTime` from our real
    nanos mtime** — reuse the `unix_to_filetime` helper already in `fs-winfsp` (Option B
    widened mtime to nanos *and* fixed that helper to nanos→100ns-ticks for exactly this).
  - file mode → there is no POSIX mode on NTFS; the executable bit is a non-goal here (Windows
    keys off extension), consistent with the "perms gaps deliberate" stance.
- On-demand population: handle `CF_CALLBACK_TYPE_FETCH_PLACEHOLDERS` to create child
  placeholders lazily when Explorer opens a dir (cheaper first-run than full populate).

### 3. Hydrate on FETCH_DATA (reuse the existing hydration path)
- `CF_CALLBACK_TYPE_FETCH_DATA` fires on a read of a dehydrated file. Resolve `FileIdentity`
  → `node_id`, run the **existing** `SyncEngine::hydrate` (node_manifest_hashes → presigned
  GET → chunk cache), assemble the requested byte range, and feed it back with
  `CfExecuteOperation(CF_OPERATION_TYPE_TRANSFER_DATA)` in chunks, reporting progress via the
  range params. This is the direct analogue of today's `Hydrate` hook (`fs-fuse`/`fs-webdav`
  closures) — the transport underneath is identical.
- Handle `CANCEL_FETCH_DATA` (user cancelled / app shutting down) by aborting the transfer.

### 4. Apply remote changes → placeholder update + invalidation (the seam we pre-built)
- The pull path already returns `ApplyOutcome { ino, content_changed }` and calls
  `Invalidate::invalidate` (see `plan-real-mtime-and-invalidation.md`). The **Windows impl of
  that trait** becomes: `CfUpdatePlaceholder` with the new `FsMetadata` (new size + real
  mtime) and, when content changed, **`CF_UPDATE_FLAG_DEHYDRATE`** (or mark not-in-sync) so the
  next read re-raises FETCH_DATA and pulls the new manifest. New nodes →
  `CfCreatePlaceholders`; deletes → delete the placeholder; moves → rename on disk. This is the
  `notify_inval_inode` equivalent the Option B seam was designed to host — **no new plumbing in
  the engine, just a new `Invalidate` implementor + a placeholder mutator.**

### 5. Capture LOCAL changes → outbox (the genuinely new engineering)
The OS no longer routes writes through us, so we must observe them:
- **New/modified files:** a placeholder the user edits (or a brand-new file dropped in) is a
  real, dirty file. Detect via **CfAPI in-sync state** + directory change notifications
  (`ReadDirectoryChangesW`) or the **NTFS USN journal** (robust, survives app-down gaps).
- On a detected local change: read the on-disk bytes, run them through `Provider` (chunk +
  manifest, the existing write/flush/`truncate` logic but sourced from the file, not a FUSE
  buffer), enqueue the `outbox` entry, let `push_outbox` upload, then **`CfSetInSyncState` +
  `CfConvertToPlaceholder`** to mark it synced and reclaimable.
- Deletes/renames: `CF_CALLBACK_TYPE_NOTIFY_DELETE`/`NOTIFY_RENAME` (or USN) → `unlink`/
  `rename` on the Provider → outbox.
- **This is where a `Provider` extension is likely needed:** a "ingest an on-disk file as this
  node_id's new content" entry point (vs today's staging-buffer `write`/`flush`).

### 6. Wire into the per-OS mount selector
- New crate `client/fs-cfapi` over the same `Provider`; `sync-engine` gains a Windows
  `CfApiMount` with the same `start`/`stop`/`is_running`/`mountpoint` shape as
  `Daemon`/`WebdavMount`/`WinfspMount`, so the Tauri app's `Mount` alias just points at it.
- Keep `fs-winfsp` as a **fallback** (config flag) during rollout — both compile under
  `cfg(windows)`; default flips to CfAPI once proven.

## Edit checklist (rough, layer by layer)
- [ ] `fs-cfapi`: sync-root register/connect lifecycle; `node_id`↔path via `FileIdentity`;
      placeholder create/update/dehydrate; FETCH_DATA + FETCH_PLACEHOLDERS callbacks.
- [ ] hydration: route FETCH_DATA through `SyncEngine::hydrate` + `CfExecuteOperation`.
- [ ] invalidation: implement `sync_engine::Invalidate` for CfAPI (`CfUpdatePlaceholder`
      [+ dehydrate]); reuse `unix_to_filetime` for the mtime field.
- [ ] local-change capture: USN-journal/`ReadDirectoryChangesW` watcher → Provider ingest →
      outbox → push → `CfSetInSyncState`. Add a `Provider` "ingest on-disk file" method.
- [ ] `sync-engine`: `CfApiMount` (+ feature flag vs `WinfspMount`); deferred-notifier-style
      wiring if a connection key must reach the invalidator (mirror the FUSE `OnceLock` break).
- [ ] deps: `windows` crate features `Win32_Storage_CloudFilters` + `Storage_Provider`
      (first-party Microsoft bindings — **permissive, no GPL driver**; deletes the
      `winfsp-x64.dll`-on-PATH runtime requirement).
- [ ] packaging: register the provider on install (sync-root + Explorer integration); MSIX or
      a registration step on first run.

## Testing
- Unit-testable: `node_id`↔`FileIdentity` round-trip, FsMetadata/mtime conversion (FILETIME),
  the placeholder-mutation decisions (create vs update vs dehydrate vs delete) as pure logic
  over `ApplyOutcome`.
- **Not** unit-testable (like FUSE invalidation): the live kernel callbacks. Needs a Windows
  host + the registered sync root — a manual smoke + a CI `windows` job that registers a root,
  drops a file, reads it back, edits on another device, and asserts the placeholder
  re-hydrates. Extend the existing `winfsp-windows` CI job.
- Reuse the cross-platform conformance idea: drive the populated folder with robocopy / a
  byte-diff harness, the Windows analogue of `rclone⇄WebDAV` / `fsx⇄FUSE`.

## Gotchas / risks
- **Local-change capture is the hard part** — it's a model inversion, not a port. Budget most
  of the work here; the hydrate/invalidate halves are largely already built.
- **App-must-be-running** for online-only files (same as OneDrive). "Always keep on device"
  (pinned/hydrated) files are readable offline; online-only ones error when the provider's
  disconnected. Set a sane default hydration policy.
- **NTFS only** (CfAPI requirement). Network/removable targets aren't sync roots.
- **No drive letter** — the mount is a profile folder. The Tauri UI's "mountpoint" wording +
  the `DaemonConfig` shape should accommodate a path, not a `Z:` (already a `PathBuf`).
- **Don't sync POSIX mode/uid/gid** (no meaning on NTFS) — consistent with the existing
  deliberate non-goals.
- Keep WinFsp shippable until CfAPI is proven on real hardware (the project's bar: "verified
  live, file written through the mount → server → chunk in storage, hash-matched on read-back").
