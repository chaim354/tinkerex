# Windows CfAPI mount — status + handoff plan

> **HISTORICAL — not re-verified.** Written before the repository split of 2026-08-20, when the
> sync engine and the Rust client still lived here (they are `chaim354/tinkerex-sync` and
> `chaim354/tinkerex-client` now). Kept for its reasoning and its measurements; it does not
> describe what this repository contains today. The current map is `docs/README.md`.


The driverless Windows mount (Cloud Filter API / `cldapi.dll` — the OneDrive model: a
registered sync-root folder with on-demand placeholders and hydrate-on-read), replacing the
GPL-WinFsp path (CLAUDE.md §9). **Verified live on Windows 11.** This doc is the source of
truth for the next agent: what's done, where it lives, how to debug it, the gotchas we hit
bringing it up, and the detailed plan for what's left.

---

## Status (2026-06-12)

**Working + verified live on Windows 11:**
- Register sync root + connect callbacks; **on-demand population** (`FETCH_PLACEHOLDERS`) so
  Explorer enumerates the library; **hydrate on open** (`FETCH_DATA` → presigned GET from
  SeaweedFS → `CfExecute(TRANSFER_DATA)`).
- **Remote-change invalidation** (`CfUpdatePlaceholder` + dehydrate, via the engine's
  `Invalidate` seam) — a file edited on another device refreshes on next open.
- **Phase 2 (edits):** local edits to existing files captured via
  `NOTIFY_FILE_CLOSE_COMPLETION` + content-compare → `Provider::ingest_bytes` → push.
- **Offline availability:** hydrated files persist on unmount (Drop disconnects but does **not**
  unregister or delete the folder); the persistent content-addressed chunk cache means a
  hydrated file reads with no network (cross-platform — test
  `hydrated_file_stays_readable_offline`).
- **Stale-DB protection:** `Provider::bind_library(id)` wipes a *different* library's stale tree
  on mount (keeps the chunk cache). Wired into all four mounts (Daemon/WebdavMount/WinfspMount/
  CfApiMount), keyed by `hash(server, token)`.

**Verification posture:** the FFI **typechecks for the Windows target** on macOS (`cargo check
--target x86_64-pc-windows-gnu`) and **compiles+links on `windows-latest`** (CI job
`cfapi-windows`); pure logic is unit-tested everywhere; the *runtime* callbacks were brought up
live with the doctor/log workflow below. WinFsp (`fs-winfsp`) is still the **default** Windows
backend until CfAPI is flipped on (next step #3).

---

## Where the code lives

| Piece | Location |
|---|---|
| Pure logic (cross-platform, unit-tested) | `client/fs-cfapi/src/lib.rs` — `FileIdentity` (node_id↔blob), `unix_nanos_to_filetime`/`filetime_to_unix_nanos`, `PlaceholderAction`/`decide_action` |
| Windows FFI | `client/fs-cfapi/src/win.rs` (`#[cfg(windows)]`) — `mount()`, register/connect, the 3 callbacks, `CfApiInvalidate` |
| Engine wiring | `client/sync-engine/src/daemon.rs` — `CfApiMount` (+ `EngineCfInvalidate`, `library_id_for`, the pre-mount snapshot + cursor reset) |
| Write-path primitive | `fs_provider::SqliteProvider::ingest_bytes(ino, &[u8])` |
| Stale-DB guard | `fs_provider::SqliteProvider::bind_library(id) -> wiped: bool` |
| Runner | `client/sync-engine/src/bin/maker-cfsyncd.rs` |
| Test helpers | `client/sync-engine/examples/{mac_host,doctor,push_update}.rs` |
| Build/smoke doc | `client/fs-cfapi/BUILD.md` |

The callbacks reach shared state via the connection's callback context (a `Box::into_raw`'d
`CfState { provider, hydrate, connection_key }`, reclaimed on Drop). `node_id` is carried as
the placeholder's opaque `FileIdentity`; the sync root itself has a **null** identity (handled
by `callback_node_id` → `None` → treated as `ROOT_INO`).

---

## How to debug it (the workflow that worked)

Live CfAPI behavior can't be tested on macOS, so bring-up is iterative against a real Windows
box. What made it fast:

1. **Compile-verify on macOS without Windows** — `cargo check --target x86_64-pc-windows-gnu`
   typechecks the whole `cfg(windows)` path (needs `rustup target add x86_64-pc-windows-gnu` +
   `brew install mingw-w64` for the sqlite build script). **Do this before every push.**
2. **Resolve windows-rs API specifics from the generated source**, not by guessing:
   `~/.cargo/registry/src/index.crates.io-*/windows-0.61.3/src/Windows/Win32/Storage/CloudFilters/mod.rs`
   — grep for the exact fn signature, struct fields, required `#[cfg(feature = …)]`, and const
   names. This is how every "cannot find X" / wrong-arity error was fixed.
3. **The `doctor` example** isolates the failing layer (no CfAPI, runs anywhere):
   `cargo run --example doctor -- <server> <token>` checks control-plane (pull tree) then
   storage (hydrate first file). Tells you "server/token wrong" vs "chunk store unreachable from
   this box" vs "purely a CfAPI issue."
4. **Per-callback `eprintln!` + capture to a file** on Windows:
   `… maker-cfsyncd … 2>&1 | Tee-Object cfapi.log` with `$env:RUST_BACKTRACE="1"`. The logs
   pinpointed every runtime bug (null-pointer panic line, the cursor mismatch, etc.).
5. **Test fixtures:** `mac_host` seeds a library + mints a token; `push_update <server> <token>
   <file> <content>` pushes a *new version* of a file (for invalidation tests).

---

## Hard-won gotchas (don't relitigate — these bit us live)

- **windows-rs feature gating.** CfAPI items are split across features. We need
  `Win32_Storage_CloudFilters` + `Win32_Storage_FileSystem` + `Win32_Foundation` +
  **`Win32_System_CorrelationVector`** (gates `CF_CALLBACK_*`/`CF_OPERATION_INFO` +
  `CfConnectSyncRoot`) + **`Win32_System_IO`** (OVERLAPPED → `CfUpdatePlaceholder`) +
  **`Win32_Security`** (SECURITY_ATTRIBUTES → `CreateFileW`).
- **Names that aren't what you'd guess:** the execute fn is **`CfExecute`** (not
  `CfExecuteOperation`); `CfConnectSyncRoot` **returns** `CF_CONNECTION_KEY` (4 args, no
  out-param); `CfCreatePlaceholders` takes a **`&mut [CF_PLACEHOLDER_CREATE_INFO]`** slice;
  TRANSFER_DATA is the `CF_OPERATION_PARAMETERS_0_0` union member (it *does* carry `Buffer`);
  hydration/population policy fields take the typed consts directly (no `i16` wrapping).
- **Null `FileIdentity` on the root** → `slice::from_raw_parts(null, 0)` is UB and panics the
  callback thread → Explorer hangs to a timeout. Always guard (`callback_node_id`).
- **Empty-tree-at-mount.** `populate()` at mount ran against the not-yet-pulled local tree (0
  placeholders) and there was no `FETCH_PLACEHOLDERS` handler → enumeration hung. Fix:
  **on-demand population** (PARTIAL policy + `FETCH_PLACEHOLDERS` reading the provider's *live*
  tree) + a **pre-mount snapshot pull**.
- **Every FETCH_* callback must answer** (success *or* error completion via `CfExecute`). An
  unanswered callback hangs the requesting app.
- **Reused local DB across libraries** → mixed trees + a cursor ahead of `head_seq` (so the
  delta pull returns nothing and remote edits never apply). Fixed by `bind_library` + resetting
  the cursor to the snapshot head **before** the sync thread reads it.
- **Invalidate must update metadata AND dehydrate.** `CfUpdatePlaceholder` with `None` metadata
  left the old size; the dedicated `CfDehydratePlaceholder` is the reliable "force re-fetch."
- **Hydrated files must persist** (offline goal): on unmount, **disconnect only** — do NOT
  `CfUnregisterSyncRoot` or delete the folder.
- General: **NTFS only**; **no drive letter** (a profile folder); don't sync POSIX mode/uid/gid;
  app-must-be-running for *online-only* files (hydrated ones open offline).

---

## Plan for the remaining work (priority order)

### 1. Phase 2b — finish local-change capture
Edits to existing files work; the rest of the write side is missing. All via CfAPI NOTIFY
callbacks (register in the table in `mount()`), each small + testable with the doctor/log loop:

- **New files** dropped into the folder. On `NOTIFY_FILE_CLOSE_COMPLETION` with **no** known
  `FileIdentity`: derive the path from `VolumeDosName + NormalizedPath`, strip the sync-root
  prefix to get the library-relative path, resolve/create parent dirs in the `Provider`
  (`mkdir` chain), `Provider::create(parent_ino, name)` + `ingest_bytes`, then
  `CfConvertToPlaceholder` (give the new on-disk file our `node_id` identity) + `CfSetInSyncState`.
  The push happens via the outbox/sync loop.
- **Deletes:** `NOTIFY_DELETE` (pre-op; must **ACK** via `CfExecute(ACK_DELETE)` to allow it) →
  resolve `node_id` → a `Provider` "delete by node_id" (add one; today `unlink` needs parent+name)
  → enqueue a `delete` outbox entry → push. Use the COMPLETION variant if a post-op signal is
  enough, but deletes usually want the pre-op ACK so you can veto/observe.
- **Renames/moves:** `NOTIFY_RENAME` (pre-op ACK) → `Provider::rename` → outbox. CfAPI gives
  source + target paths in the params.
- **Provider additions likely needed:** `delete_by_node_id`, maybe `rename_by_node_id`, and a
  helper to resolve a library-relative path → parent ino (mirror `CfApiInvalidate::path_for` but
  for the inbound direction). Keep them cross-platform + unit-tested.
- **Self-write filter** stays the content-compare already used for edits (our hydration writes
  leave bytes equal → skipped). For new files there's nothing to compare against, so gate on
  "is this path inside the sync root and not one we just created."

**Test:** drop a file in `MakerCF`, delete one, rename one; assert each via `doctor`/the Mac
app on another device. Add hermetic `Provider` tests for the new `delete_by_node_id`/path
resolution.

### 2. New remote files appearing while mounted
Today a directory is marked **fully populated** after the first `FETCH_PLACEHOLDERS`
(`DISABLE_ON_DEMAND_POPULATION`), so a file added on another device *while* you're browsing
won't show until you re-navigate. Fix: when the sync loop's pull creates a **new** node (an
`apply_remote` insert, not just a content change), have the engine create a placeholder for it
in its parent directory via `CfCreatePlaceholders` (a new adapter hook alongside `Invalidate`,
or extend `Invalidate` to an enum of {invalidate, create, delete}). Plumb the parent path the
same way the invalidator resolves paths. Low risk once the path-resolution helper from #1 exists.

### 3. Make CfAPI the default Windows backend
Flip the Tauri app's per-OS `Mount` alias from `sync_engine::WinfspMount` to
`sync_engine::CfApiMount` (`client/maker-app/src-tauri/src/lib.rs`, the `#[cfg(target_os =
"windows")] type Mount = …`). Keep WinFsp reachable behind a setting/cargo-feature for one
release. Update `maker-app/SETUP.md` (no WinFsp/`winfsp-x64.dll` needed; the mount point is a
folder, not a drive letter). This is the dogfooding milestone — once it's the default, the GUI
drives CfAPI like Mac/Linux.

### 4. Harden + polish — **CODE-COMPLETE (needs live-Windows verification)**
All four items below are implemented on branch `cfapi-b6-polish`: pure logic is unit-tested on
macOS (39 fs-cfapi tests green) and the FFI typechecks for the Windows target
(`cargo check --target x86_64-pc-windows-gnu`, clean). The *runtime* behavior is unverified — it
needs the live self-hosted Windows runner (`gh workflow run rust-client.yml -f target=cfapi` /
`-f target=cfapi-conf`) + a manual pin/unpin + remove-library smoke in Explorer.

- ~~**Pin/unpin**~~ **DONE (code).** Explorer's "Always keep on this device" / "Free up space"
  toggles the file's pinned attribute — there's no dedicated CfAPI pin callback, so the
  `ReadDirectoryChangesW` watcher now also watches `FILE_NOTIFY_CHANGE_ATTRIBUTES`; on a MODIFIED
  event `win::reconcile_pin_state` reads `CF_PLACEHOLDER_STANDARD_INFO.PinState`, maps it through the
  unit-tested `pin_hydration_action` (lib.rs), and calls `CfHydratePlaceholder` (pinned → fetches via
  FETCH_DATA) or `CfDehydratePlaceholder` (unpinned). No-op on dirs/non-placeholders; skipped during
  teardown. **Live-verify:** right-click → both menu items in Explorer; confirm a pinned file reads
  offline and an unpinned one frees its bytes.
- ~~**Registration lifecycle**~~ **DONE (code).** `CfApiMountHandle::remove_library(delete_folder)`
  (+ `CfApiMount::remove_library` on the engine wrapper) disconnects, `CfUnregisterSyncRoot`s, and
  optionally `remove_dir_all`s the folder — the explicit "remove this library" action, distinct from
  the offline-keeping Drop. A `torn_down` flag makes Drop a no-op afterward (no double-disconnect /
  double-free). **Live-verify:** call it, then confirm the folder is no longer a sync root
  (`Get-SyncRoot` / re-register at the same path succeeds clean). **App wiring (TODO):** surface a
  Tauri command/button — the engine method exists; the GUI button is not wired yet.
- ~~**Large-file `FETCH_DATA`**~~ **DONE (code).** `fetch_data_callback` now streams via the
  unit-tested `plan_transfer_chunks` (lib.rs): the required range is split into ≤16 MiB page-aligned
  slices (only the EOF-reaching slice may be short — CfAPI's one legal unaligned length), each read
  from the provider + transferred with its own `CfExecute(TRANSFER_DATA)`, with per-slice
  `CfReportProviderProgress`. `CANCEL_FETCH_DATA` is registered + honored (cancelled transfer keys
  stop the loop between slices). **Live-verify:** hydrate a multi-GB file; watch the Explorer
  progress bar; cancel mid-download.
- ~~**ino→path index**~~ **DONE (code).** New cross-platform `PathIndex` (lib.rs, unit-tested):
  `FETCH_PLACEHOLDERS` records each child's `ino → dir_path/name` as it enumerates (free — it already
  holds both), so `CfApiInvalidate::path_for` is O(1) on a hit. A miss falls back to the old DFS and
  back-fills the index (always correct). Delete/rename callbacks drop the stale entry. The engine
  shares one `Arc<PathIndex>` between the mount (`win::mount_full`) and `CfApiInvalidate::with_index`.
- **`FETCH_DATA` size** — each *slice* read is now ≤16 MiB, so the old 4 GB `read(.., len as u32)`
  cap is no longer reachable in practice (a >4 GB file streams in ≤16 MiB slices). The provider
  `read` signature still takes a `u32` length; the streaming planner keeps every call well under it.

### 5. CI / runtime regression net
The pure logic is unit-tested and the FFI compiles in CI, but live behavior is manual. If you
want it gated: a **self-hosted Windows runner** smoke that registers a root, enumerates,
hydrates, edits, and asserts the round-trip (the Windows analogue of the `mount-conformance`
job). Until then, the `doctor` + `BUILD.md` smoke is the manual gate.

---

## Test command reference

```sh
# Mac: seed a library + mint a Windows token
SERVER_URL=http://192.168.1.95 cargo run --example mac_host        # in client/sync-engine
# Mac: isolate a failure layer (no CfAPI)
cargo run --example doctor -- http://192.168.1.95 <token>
# Mac: push a new version of a file (invalidation fixture)
cargo run --example push_update -- http://192.168.1.95 <token> hello.txt "new content"
```
```powershell
# Windows: build + run the mount with logging
cargo run --manifest-path client\sync-engine\Cargo.toml --bin maker-cfsyncd -- `
  "$env:USERPROFILE\MakerCF" "$env:TEMP\maker-cf.db" "$env:TEMP\maker-cf-chunks" `
  http://192.168.1.95 <token> 2>&1 | Tee-Object "$env:USERPROFILE\cfapi.log"
```
```sh
# macOS: typecheck the whole Windows FFI before pushing
cargo check --target x86_64-pc-windows-gnu   # in client/fs-cfapi
```

Server is deployed via Kamal on `192.168.1.95` (port 80, SeaweedFS at `192.168.1.7:8333`).
Redeploy: `rsync` the tree to `kamal1@192.168.1.95:~/tinkerex/` then `~/kamalw deploy` on the VM
(`docs/DEPLOY.md`).
