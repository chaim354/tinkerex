# Design: Phase 2b CfAPI completion → self-hosted CI → test suite → FSKit sketch

Date: 2026-06-12
Branch: `auth-caching-security`
Status: approved design (pending spec review)

This spec covers four sequential tracks. They are independent enough to land as
separate plan-phases with their own rollback points, but the **order is fixed**:
finish the Windows write-path (Track B), then move CI to self-hosted runners that can
live-verify it (Track A), then a test suite that asserts the whole thing, then a
forward-looking sketch for the macOS FSKit migration.

**Working agreement (applies to every track):**
- Stay on `auth-caching-security`; **one focused commit per step, pushed after each
  step** → every step is a rollback point.
- Anything touching the live Windows CfAPI runtime is written + cross-target
  typechecked on macOS (`cargo check --target x86_64-pc-windows-gnu`) and unit-tested
  for pure logic here; **live verification is the Windows box / the smoke job**, not
  this Mac. This is called out per step.
- The maker-app **UI rework** already landed in an isolated worktree
  (`worktree-agent-a15b6e6328a976db5`, audit in `docs/ui-audit.md`); it is reviewed and
  merged separately from this spec's tracks.

---

## Track B — Phase 2b CfAPI: finish local-change capture (FIRST)

Source of truth: `docs/plan-windows-cfapi-migration.md` §1–5. Edits-to-existing-files
already work; this completes the rest of the write side and makes CfAPI shippable.
Code lives in `client/fs-cfapi/src/{lib.rs,win.rs}`, engine wiring in
`client/sync-engine/src/daemon.rs`, write primitive `fs_provider::ingest_bytes`.

### B0. Provider primitives (cross-platform, hermetic tests) — *fully verifiable here*
New `fs-provider` methods, each with `tests/` coverage:
- `delete_by_node_id(node_id)` — today `unlink` needs parent+name; CfAPI delete only has
  the node identity. Recursive subtree sweep, idempotent, enqueues a `delete` outbox
  entry (mirrors `apply_remote_delete` but for the local-origin direction).
- `resolve_path(library_relative_path) -> (parent_ino, leaf_name)` — resolve/create the
  parent dir chain for an inbound on-disk path (mirror of `CfApiInvalidate::path_for`,
  inbound). Used by new-file capture.
- `rename_by_node_id(node_id, new_parent_ino, new_name)` if the existing `rename` can't
  be driven from node identity + target path alone.

### B1. New files dropped into the folder — *write here, live-verify on Windows*
`NOTIFY_FILE_CLOSE_COMPLETION` with **no** known `FileIdentity`: derive path from
`VolumeDosName + NormalizedPath`, strip the sync-root prefix → library-relative path →
`resolve_path` → `Provider::create(parent_ino, name)` + `ingest_bytes` →
`CfConvertToPlaceholder` (stamp our `node_id` identity) + `CfSetInSyncState`. Push via
the outbox/sync loop. Self-write filter: gate on "inside sync root and not one we just
created/hydrated" (hydration writes already skipped by content-compare).

### B2. Deletes — *write here, live-verify on Windows*
`NOTIFY_DELETE` (pre-op; **ACK** via `CfExecute(ACK_DELETE)` to allow it) → resolve
`node_id` → `delete_by_node_id` → outbox → push.

### B3. Renames / moves — *write here, live-verify on Windows*
`NOTIFY_RENAME` (pre-op ACK) → `Provider::rename` / `rename_by_node_id` → outbox. CfAPI
supplies source + target paths in the params.

### B4. New remote files appearing while mounted — *write here, live-verify on Windows*
Today a dir is marked fully populated after the first `FETCH_PLACEHOLDERS`, so a file
added on another device mid-browse won't show until re-navigation. Add an engine hook
alongside `Invalidate` (extend it to an enum `{invalidate, create, delete}`): when the
sync pull's `apply_remote` does a **new-node insert**, create a placeholder in its
parent via `CfCreatePlaceholders`, reusing the B0 path resolver.

### B5. Make CfAPI the default Windows backend — *config flip; build-verifiable here*
Flip `client/maker-app/src-tauri/src/lib.rs` `#[cfg(target_os = "windows")] type Mount`
from `WinfspMount` to `CfApiMount`, behind a setting/cargo-feature so WinFsp stays
reachable for one release. Update `client/maker-app/SETUP.md` (no WinFsp/`winfsp-x64.dll`;
mount point is a folder, not a drive letter). **Lands only after the Windows smoke
(Track A) is green** — this is the gate the user asked for.

### B6. Harden + polish — *mixed; build-verifiable here, behavior live*
- **Pin/unpin** — tie Explorer `CF_PIN_STATE` to hydrate/dehydrate (both primitives
  exist); a pinned file is re-hydrated, never auto-dehydrated on invalidate.
- **Registration lifecycle** — a real "remove this library" action that
  `CfUnregisterSyncRoot` + cleans the folder (opposite of the offline default), surfaced
  in the app, not on every stop.
- **Large-file `FETCH_DATA`** — stream in chunks + `CfReportProviderProgress`, honor
  `CANCEL_FETCH_DATA`; revisit the 4 GB-per-call `read` cap for >4 GB files.
- **ino→path index** — replace the O(tree) `path_for` walks with an index built during
  `FETCH_PLACEHOLDERS` for O(1) invalidation.

---

## Track A — Self-hosted CI migration (AFTER Track B)

Keep GitHub Actions as the orchestrator and all existing workflow YAML; change only
*where* jobs run, and add the jobs that only a real machine can run. Repo:
`chaim354/tinkerex`. Boxes: macOS (this one), Linux, Windows — native, no VMs.

### A1. Per-box runner setup scripts (`ci/runners/`)
`setup-linux.sh`, `setup-macos.sh`, `setup-windows.ps1`. Each: download the GitHub
Actions runner, install prereqs once (rustup, ruby, plus FUSE/`libfuse-dev` on Linux,
WinFsp+LLVM on Windows, FUSE-T pkg-config alias on macOS, rclone for conformance),
`config` against `https://github.com/chaim354/tinkerex` with a **registration token**
(minted via `gh api repos/chaim354/tinkerex/actions/runners/registration-token`),
apply labels `[self-hosted, <os>]` + a `maker-<os>` custom label, install as a service.
**The user runs each script on its box** (registration is interactive; the token is
short-lived). Scripts are idempotent and print the exact next step.

### A2. Workflow edits (incremental, one commit each)
- `rust-client.yml`: `ubuntu-latest`→`[self-hosted, linux]`, `windows-latest`→
  `[self-hosted, windows]`; add a **new macOS job** (`[self-hosted, macos]`) running
  `cargo check --target x86_64-pc-windows-gnu` (the CfAPI cross-check) + a native Mac
  build (`fs-webdav`/`sync-engine`).
- `ci.yml`: Rails jobs → `[self-hosted, linux]`.
- Convert **one job first, confirm green, then the rest** — each its own push.

### A3. New `windows-smoke` job — the live regression net
On the self-hosted Windows runner (real Windows + reachable deployed server at
`192.168.1.95`): the scripted CfAPI smoke — register sync root → enumerate
(`FETCH_PLACEHOLDERS`) → hydrate (`FETCH_DATA`) → **edit / new-file / delete / rename**
→ assert the round-trip via the control plane. This is the Windows analogue of the
existing `mount-conformance` job and the verification gate for B1–B5 (and the
precondition for the B5 default-flip).

### A4. Rollback posture
Self-hosted runners lack preinstalled toolchains, so a misconfigured runner = red CI.
Mitigation: incremental per-job conversion (A2), each pushed separately; if a job goes
red, `git revert` that one commit restores the GitHub-hosted runner for it.

---

## Test suite — assert it all works (AFTER Track A)

A consolidated suite proving Tracks A+B end-to-end, runnable by the self-hosted runners:
- **`fs-provider` hermetic tests** for B0 primitives (`delete_by_node_id` recursion +
  idempotency, `resolve_path` parent-chain creation, `rename_by_node_id`), folded into
  the existing convergence/posix harnesses.
- **`fs-cfapi` pure-logic unit tests** for the new callback decision logic
  (path-stripping, self-write filtering, the `{invalidate, create, delete}` enum).
- **`sync-engine` integration tests** (server-backed) for the new outbox paths:
  new-file create, delete-by-node-id, rename propagate, and "new remote file appears →
  placeholder created" convergence — asserted against the live test server like the
  existing `tests/integration.rs`.
- **Windows live smoke** (the A3 job) as the only non-hermetic gate, scripted so its
  pass/fail is machine-checked, not eyeballed.
- The suite must run green in the migrated self-hosted CI; that is the definition of
  "it all works."

---

## FSKit migration sketch (LAST — design only, no implementation)

macOS uses WebDAV today because FUSE-T's FSKit build can't mount on macOS 26 (silent
fail; the System-Settings extension toggle is greyed). FSKit is Apple's native,
permissive (no GPL kext) filesystem-extension framework — the principled macOS target,
the peer of Windows CfAPI. Deliverable: a `docs/plan-macos-fskit-migration.md` sketch
covering:
- **Why FSKit over WebDAV** — native, no kext, no `mount_webdav` quirks; on-demand
  hydration like CfAPI; permissive (§9).
- **Module shape** — an `FSUnaryFileSystem`/`FSVolume` extension over the same
  `Provider`, reusing the Option-B mtime/invalidate seams already built for CfAPI
  (`invalidate`, real-nanos mtime); a `client/fs-fskit` crate paralleling `fs-cfapi`,
  wired as a `sync_engine::FsKitMount` behind the per-OS `Mount` alias.
- **The Swift/Rust boundary** — FSKit is Swift/ObjC; sketch the FFI bridge (Swift
  extension calling into the Rust `Provider`, mirroring how CfAPI bridges the `windows`
  crate).
- **Hydration mapping** — FSKit's fetch/materialize callbacks ↔ our `hydrate` +
  `FETCH_DATA` model; the write-capture callbacks ↔ the B1–B4 NOTIFY analogues.
- **Verification posture** — like CfAPI, live behavior is macOS-only and manual until a
  self-hosted macOS smoke job exists (which Track A's macOS runner enables).
- **Open questions / risks** — macOS-version floor, the greyed-toggle root cause,
  packaging/signing the extension, and whether FSKit is stable enough to ship vs. keep
  WebDAV as the fallback.

This is a **sketch**, not a build: it ends as a committed design doc, not code.

---

## Out of scope (YAGNI)
- Real OAuth/OIDC email verification (CLAUDE.md §12 step 5) — separate effort.
- Postgres deploy validation (step 8) — separate.
- The maker app layer (projects/inventory/BOM) — separate Rails concern.
- Actually building FSKit — this spec only sketches it.
