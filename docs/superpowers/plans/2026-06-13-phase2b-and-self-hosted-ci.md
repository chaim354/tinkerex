# Phase 2b CfAPI + Self-Hosted CI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finish the Windows CfAPI write path (new files / deletes / renames / live remote-file appearance), make CfAPI the default Windows backend behind a flag, then migrate CI to self-hosted runners that can live-verify it, add a consolidated test suite, and sketch the macOS FSKit migration.

**Architecture:** Track B adds cross-platform `Provider` primitives (hermetically testable on macOS) and the Windows CfAPI NOTIFY callbacks that use them (typecheck-only on macOS, live-verified on Windows). Track A keeps GitHub Actions as orchestrator and only moves `runs-on` to self-hosted runners, adding a macOS cross-check job and a live Windows smoke job. The test suite and FSKit sketch follow.

**Tech Stack:** Rust (`fs-provider`, `fs-cfapi`, `sync-engine`), the `windows` crate (CfAPI FFI), Rails (server, for integration tests), GitHub Actions self-hosted runners, `gh` CLI.

**Verification legend per task:** 🟢 = fully verifiable on this macOS box · 🟡 = cross-target typecheck only here (`cargo check --target x86_64-pc-windows-gnu`), live-verified on Windows · 🔵 = run by the user on their box.

**Working agreement:** Branch `auth-caching-security`. One focused commit per task, **pushed after each task** (rollback points). Before every push of CfAPI FFI code, run `cargo check --target x86_64-pc-windows-gnu` in `client/fs-cfapi`. **NOTE:** `client/sync-engine` CANNOT be gnu-cross-checked from macOS — its `fs-winfsp` dep pulls `winfsp-sys`, whose build script panics on the gnu triple (`unsupported triple x86_64-pc-windows-gnu`, only msvc is supported). So the engine-wiring gate is the **msvc `cfapi-windows` CI job** (and the self-hosted Windows runner), NOT a local gnu check. Keep CfAPI changes to `fs-cfapi`'s existing public API where possible so the engine wiring is unaffected.

---

## File Structure

**Track B (Provider primitives — new code):**
- Modify: `client/fs-provider/src/lib.rs` — add `delete_by_node_id`, `resolve_path`, `rename_by_node_id` to `SqliteProvider`.
- Test: `client/fs-provider/tests/posix_semantics.rs` (or a new `tests/node_id_ops.rs`) — hermetic tests for the primitives.

**Track B (CfAPI callbacks — Windows FFI):**
- Modify: `client/fs-cfapi/src/lib.rs` — extend pure-logic helpers + the `PlaceholderAction` enum.
- Modify: `client/fs-cfapi/src/win.rs` — register + implement the NOTIFY callbacks.
- Modify: `client/sync-engine/src/daemon.rs` — extend the `Invalidate` seam to `{invalidate, create, delete}`; wire the engine create-placeholder-on-pull hook.

**Track B (default flip):**
- Modify: `client/maker-app/src-tauri/src/lib.rs` — `Mount` alias behind a cargo feature.
- Modify: `client/maker-app/SETUP.md`.

**Track A (CI):**
- Create: `ci/runners/setup-linux.sh`, `ci/runners/setup-macos.sh`, `ci/runners/setup-windows.ps1`, `ci/runners/README.md`.
- Create: `client/test-conformance/cfapi-smoke.ps1` (the scripted Windows smoke).
- Modify: `.github/workflows/rust-client.yml`, `.github/workflows/ci.yml`.

**Test suite + FSKit:**
- Modify: `client/sync-engine/tests/integration.rs`.
- Create: `docs/plan-macos-fskit-migration.md`.

---

## Track B — Phase 2b CfAPI

### Task B0a: `delete_by_node_id` on `SqliteProvider` 🟢

**Files:**
- Modify: `client/fs-provider/src/lib.rs` (next to `apply_remote_delete` ~line 573 and `enqueue` ~line 636)
- Test: `client/fs-provider/tests/node_id_ops.rs` (new)

- [ ] **Step 1: Write the failing test**

```rust
// client/fs-provider/tests/node_id_ops.rs
mod common;
use common::mem_provider; // existing helper: builds an in-memory SqliteProvider
use fs_provider::Provider;

#[test]
fn delete_by_node_id_removes_subtree_and_enqueues_delete() {
    let p = mem_provider();
    let dir = p.mkdir(1, "d").unwrap();           // root ino = 1
    let f = p.create(dir.ino, "f.txt").unwrap();
    let dir_id = p.node_id_for(dir.ino).unwrap().unwrap();
    let f_id = p.node_id_for(f.ino).unwrap().unwrap();
    // drain the outbox from setup so we assert only the delete
    p.outbox_clear_for_test();

    p.delete_by_node_id(&dir_id).unwrap();

    // subtree gone
    assert!(p.ino_for_node_id(&dir_id).unwrap().is_none());
    assert!(p.ino_for_node_id(&f_id).unwrap().is_none());
    // delete op enqueued for the deleted node
    let ob = p.outbox_list().unwrap();
    assert!(ob.iter().any(|(id, op)| id == &dir_id && op == "delete"));
    // idempotent
    p.delete_by_node_id(&dir_id).unwrap();
}
```

If `common::mem_provider` / `outbox_clear_for_test` don't exist, check `client/fs-provider/tests/common/` for the actual helper names and adapt; add a tiny `#[cfg(test)]`-free `outbox_clear` only if a test-helper is truly missing (prefer an existing one).

- [ ] **Step 2: Run test, verify it fails**

Run: `cargo test --manifest-path client/fs-provider/Cargo.toml --test node_id_ops`
Expected: FAIL — `no method named delete_by_node_id`.

- [ ] **Step 3: Implement `delete_by_node_id`**

Add to the `impl SqliteProvider` block, modeled on `apply_remote_delete` but enqueueing the outbox `"delete"` op (so it pushes), unlike the inbound `apply_remote_delete`:

```rust
/// Delete the node `node_id` and its whole subtree from the LOCAL tree as a
/// local-origin change: recursive like `apply_remote_delete`, but it ALSO enqueues a
/// `"delete"` outbox entry so the sync loop pushes the removal. Idempotent: a no-op
/// (and no outbox entry) if the node is already gone. Used by the inbound CfAPI
/// `NOTIFY_DELETE` callback, which only has the node identity (not parent+name).
pub fn delete_by_node_id(&self, node_id: &str) -> Result<()> {
    let conn = self.conn.lock().unwrap();
    let exists: bool = conn
        .query_row("SELECT 1 FROM nodes WHERE node_id = ?1", params![node_id], |_| Ok(()))
        .optional()?
        .is_some();
    if !exists {
        return Ok(());
    }
    conn.execute(
        "DELETE FROM nodes WHERE ino IN (
             WITH RECURSIVE sub(ino) AS (
                 SELECT ino FROM nodes WHERE node_id = ?1
                 UNION ALL
                 SELECT n.ino FROM nodes n JOIN sub ON n.parent_ino = sub.ino
             )
             SELECT ino FROM sub
         )",
        params![node_id],
    )?;
    Self::enqueue(&conn, node_id, "delete")?;
    Ok(())
}
```

- [ ] **Step 4: Run test, verify it passes**

Run: `cargo test --manifest-path client/fs-provider/Cargo.toml --test node_id_ops`
Expected: PASS.

- [ ] **Step 5: Commit + push**

```bash
git add client/fs-provider/src/lib.rs client/fs-provider/tests/node_id_ops.rs
git commit -m "fs-provider: delete_by_node_id (local-origin recursive delete + outbox)"
git push
```

### Task B0b: `resolve_path` (library-relative path → parent ino + leaf) 🟢

**Files:**
- Modify: `client/fs-provider/src/lib.rs`
- Test: `client/fs-provider/tests/node_id_ops.rs`

- [ ] **Step 1: Write the failing test**

```rust
#[test]
fn resolve_path_creates_parent_chain() {
    let p = mem_provider();
    // "a/b/c.txt" → creates dirs a, b; returns (ino_of_b, "c.txt")
    let (parent, leaf) = p.resolve_path("a/b/c.txt").unwrap();
    assert_eq!(leaf, "c.txt");
    // calling again is stable (no duplicate dirs)
    let (parent2, _) = p.resolve_path("a/b/c.txt").unwrap();
    assert_eq!(parent, parent2);
    // a top-level file resolves to root (ino 1)
    let (root_parent, leaf2) = p.resolve_path("top.txt").unwrap();
    assert_eq!(root_parent, 1);
    assert_eq!(leaf2, "top.txt");
}
```

- [ ] **Step 2: Run test, verify it fails**

Run: `cargo test --manifest-path client/fs-provider/Cargo.toml --test node_id_ops resolve_path`
Expected: FAIL — `no method named resolve_path`.

- [ ] **Step 3: Implement `resolve_path`**

Reuse `lookup`/`mkdir` (both already on the trait). Split on `/`, walk/create each dir component, return the final parent ino + leaf name:

```rust
/// Resolve a library-relative POSIX path (e.g. `"a/b/c.txt"`) to its
/// `(parent_ino, leaf_name)`, creating any missing intermediate directories. Used by
/// the inbound CfAPI new-file callback, which sees an on-disk path but no node identity.
/// The leaf itself is NOT created (the caller decides file vs dir).
pub fn resolve_path(&self, rel: &str) -> Result<(u64, String)> {
    let parts: Vec<&str> = rel.split('/').filter(|s| !s.is_empty()).collect();
    if parts.is_empty() {
        return Err(FsError::NotFound);
    }
    let (leaf, dirs) = parts.split_last().unwrap();
    let mut parent: u64 = ROOT_INO; // ROOT_INO == 1
    for comp in dirs {
        parent = match self.lookup(parent, comp) {
            Ok(attr) => attr.ino,
            Err(FsError::NotFound) => self.mkdir(parent, comp)?.ino,
            Err(e) => return Err(e),
        };
    }
    Ok((parent, (*leaf).to_string()))
}
```

Confirm `ROOT_INO` and `FsError::NotFound` exist (grep `ROOT_INO` / `enum FsError` in `lib.rs`); use the actual names.

- [ ] **Step 4: Run test, verify it passes**

Run: `cargo test --manifest-path client/fs-provider/Cargo.toml --test node_id_ops resolve_path`
Expected: PASS.

- [ ] **Step 5: Commit + push**

```bash
git add client/fs-provider/src/lib.rs client/fs-provider/tests/node_id_ops.rs
git commit -m "fs-provider: resolve_path (rel path -> parent ino, create dir chain)"
git push
```

### Task B0c: `rename_by_node_id` 🟢

**Files:** `client/fs-provider/src/lib.rs`, test in `node_id_ops.rs`

- [ ] **Step 1: Failing test**

```rust
#[test]
fn rename_by_node_id_moves_and_enqueues() {
    let p = mem_provider();
    let d1 = p.mkdir(1, "d1").unwrap();
    let d2 = p.mkdir(1, "d2").unwrap();
    let f = p.create(d1.ino, "f.txt").unwrap();
    let f_id = p.node_id_for(f.ino).unwrap().unwrap();
    p.outbox_clear_for_test();

    p.rename_by_node_id(&f_id, d2.ino, "g.txt").unwrap();

    let attr = p.lookup(d2.ino, "g.txt").unwrap();
    assert_eq!(p.node_id_for(attr.ino).unwrap().unwrap(), f_id);
    assert!(p.lookup(d1.ino, "f.txt").is_err());
    assert!(p.outbox_list().unwrap().iter().any(|(id, op)| id == &f_id && op == "upsert"));
}
```

- [ ] **Step 2: Run, verify fails.** `cargo test --manifest-path client/fs-provider/Cargo.toml --test node_id_ops rename_by_node_id` → FAIL.

- [ ] **Step 3: Implement** — resolve the node's current parent+name, then delegate to the existing `rename`:

```rust
/// Rename/move the node identified by `node_id` to `(new_parent_ino, new_name)`.
/// Thin wrapper over `rename` for the CfAPI `NOTIFY_RENAME` callback, which carries the
/// node identity + target path rather than the old parent+name.
pub fn rename_by_node_id(&self, node_id: &str, new_parent: u64, new_name: &str) -> Result<()> {
    let (old_parent, old_name) = {
        let conn = self.conn.lock().unwrap();
        conn.query_row(
            "SELECT parent_ino, name FROM nodes WHERE node_id = ?1",
            params![node_id],
            |r| Ok((r.get::<_, i64>(0)? as u64, r.get::<_, String>(1)?)),
        )
        .optional()?
        .ok_or(FsError::NotFound)?
    };
    self.rename(old_parent, &old_name, new_parent, new_name)
}
```

- [ ] **Step 4: Run, verify passes.** PASS.

- [ ] **Step 5: Commit + push.** `git commit -m "fs-provider: rename_by_node_id wrapper over rename"`; `git push`.

### Task B1: New-file capture callback 🟡

**Files:** `client/fs-cfapi/src/lib.rs` (pure path-stripping helper + unit test), `client/fs-cfapi/src/win.rs` (the callback).

- [ ] **Step 1 (🟢 unit-testable): pure helper + test in `lib.rs`** — strip the sync-root prefix to a library-relative path:

```rust
/// Strip the sync-root prefix from an absolute on-disk path to a library-relative,
/// forward-slash path. Returns None if `abs` is not under `root`.
pub fn library_relative(root: &str, abs: &str) -> Option<String> {
    let rel = abs.strip_prefix(root)?.trim_start_matches(['\\', '/']);
    Some(rel.replace('\\', "/"))
}

#[cfg(test)]
mod relpath {
    use super::*;
    #[test]
    fn strips_root_and_normalizes_sep() {
        assert_eq!(library_relative(r"C:\Users\me\MakerCF", r"C:\Users\me\MakerCF\a\b.txt"),
                   Some("a/b.txt".into()));
        assert_eq!(library_relative(r"C:\Users\me\MakerCF", r"C:\Other\x"), None);
    }
}
```

Run: `cargo test --manifest-path client/fs-cfapi/Cargo.toml library_relative` → write failing first, then PASS.

- [ ] **Step 2 (🟡): implement the callback in `win.rs`.** In the `NOTIFY_FILE_CLOSE_COMPLETION` handler, when `callback_node_id` returns `None` (no identity) AND the path is inside the sync root and not one we just hydrated/created: read the file bytes, `library_relative(root, abs)` → `provider.resolve_path(rel)` → `provider.create(parent, leaf)` → `provider.ingest_bytes(ino, &bytes)`, then `CfConvertToPlaceholder` (stamp the new `node_id` as the `FileIdentity`) + `CfSetInSyncState`. Resolve exact `windows` crate signatures from the generated source (`windows-0.61.3/.../CloudFilters/mod.rs`) per `docs/plan-windows-cfapi-migration.md`. The push happens via the outbox/sync loop. Track the just-created path in a short-lived set to suppress the self-write echo.

- [ ] **Step 3 (🟢): cross-target typecheck.** Run in `client/fs-cfapi`: `cargo check --target x86_64-pc-windows-gnu`. Expected: compiles. Also `cargo check --target x86_64-pc-windows-gnu` in `client/sync-engine`.

- [ ] **Step 4: Commit + push.** `git commit -m "fs-cfapi: capture new files (NOTIFY_FILE_CLOSE, no identity) -> create+ingest+placeholder"`; `git push`. Live verification deferred to the Windows smoke (Task A4).

### Task B2: Delete capture callback 🟡

**Files:** `client/fs-cfapi/src/win.rs`

- [ ] **Step 1 (🟡):** Register + handle `NOTIFY_DELETE` (pre-op). ACK via `CfExecute` with the `ACK_DELETE` operation type to allow the delete, resolve the `node_id` from the placeholder identity, call `provider.delete_by_node_id(node_id)` (Task B0a), which enqueues the push. Resolve the exact `CF_OPERATION_TYPE` / `CF_OPERATION_PARAMETERS` for ACK_DELETE from the generated source.
- [ ] **Step 2 (🟢): cross-target typecheck** — `cargo check --target x86_64-pc-windows-gnu` in `fs-cfapi` + `sync-engine`. Expected: compiles.
- [ ] **Step 3: Commit + push** — `git commit -m "fs-cfapi: capture deletes (NOTIFY_DELETE pre-op ACK -> delete_by_node_id)"`; `git push`.

### Task B3: Rename capture callback 🟡

**Files:** `client/fs-cfapi/src/win.rs`

- [ ] **Step 1 (🟡):** Register + handle `NOTIFY_RENAME` (pre-op ACK). CfAPI supplies source + target paths; resolve the node identity → `provider.rename_by_node_id(node_id, new_parent, new_name)` where `(new_parent, new_name)` comes from `resolve_path(library_relative(root, target))` (target's parent). ACK the rename via `CfExecute(ACK_RENAME)`.
- [ ] **Step 2 (🟢): cross-target typecheck.** Expected: compiles.
- [ ] **Step 3: Commit + push** — `git commit -m "fs-cfapi: capture renames (NOTIFY_RENAME pre-op ACK -> rename_by_node_id)"`; `git push`.

### Task B4: New remote files appear while mounted 🟡

**Files:** `client/sync-engine/src/daemon.rs`, `client/fs-cfapi/src/win.rs`

- [ ] **Step 1 (🟢 unit-testable in `lib.rs`): extend the action enum.** Change the engine seam from a bare invalidate to an enum:

```rust
// in fs-cfapi/src/lib.rs
pub enum PlaceholderEvent { Invalidate(String), Create { parent_rel: String, name: String, node_id: String }, Delete(String) }
```

Add a unit test asserting the variants carry the right data (trivial but keeps the contract pinned).

- [ ] **Step 2 (🟡): wire the pull hook.** In `daemon.rs`, where the sync pull calls `apply_remote` and gets an `ApplyOutcome`, detect a **new-node insert** (extend `ApplyOutcome` with an `inserted: bool` if not already distinguishable — check `apply_remote` ~lib.rs:505) and dispatch `PlaceholderEvent::Create`. The CfAPI adapter handles `Create` by calling `CfCreatePlaceholders` in the resolved parent dir (reuse the B0b path resolver, inverse direction). Keep WebDAV/WinFsp adapters passing `None`/no-op as today.
- [ ] **Step 3 (🟢): cross-target typecheck** both crates. Expected: compiles. Run `cargo test --manifest-path client/fs-cfapi/Cargo.toml` (pure logic). Expected: PASS.
- [ ] **Step 4: Commit + push** — `git commit -m "sync-engine+fs-cfapi: create placeholders for newly-pulled remote nodes while mounted"`; `git push`.

### Task B5: Make CfAPI the default Windows backend (FLAG; FLIP GATED ON A4 GREEN) 🟡

**Files:** `client/maker-app/src-tauri/src/lib.rs`, `client/maker-app/SETUP.md`

- [ ] **Step 1 (🟡):** Behind a cargo feature (e.g. `winfsp-backend`), set the default `#[cfg(target_os = "windows")] type Mount = sync_engine::CfApiMount;` and keep `WinfspMount` reachable when the feature is on. Update `SETUP.md`: no WinFsp/`winfsp-x64.dll` needed; mount point is a folder, not a drive letter.
- [ ] **Step 2 (🟢): cross-target typecheck** the app crate for `x86_64-pc-windows-gnu` (both with and without the `winfsp-backend` feature). Expected: compiles.
- [ ] **Step 3: Commit + push** — `git commit -m "maker-app: default Windows mount to CfApiMount (WinFsp behind feature)"`; `git push`. **Do not consider this done until the Task A4 Windows smoke is green.**

### Task B6: Harden + polish 🟡

Split into separate commits, each cross-target-checked + pushed. Per `docs/plan-windows-cfapi-migration.md` §4:
- [ ] **B6a — ino→path index:** build an index during `FETCH_PLACEHOLDERS`; replace the O(tree) `path_for` walks. Commit + push.
- [ ] **B6b — pin/unpin:** map `CF_PIN_STATE` to hydrate/dehydrate; pinned files re-hydrate (never auto-dehydrate on invalidate). Commit + push.
- [ ] **B6c — remove-library lifecycle:** an explicit action that `CfUnregisterSyncRoot` + cleans the folder (surfaced in the app, not on every stop). Commit + push.
- [ ] **B6d — large-file `FETCH_DATA`:** stream in chunks + `CfReportProviderProgress`, honor `CANCEL_FETCH_DATA`. Commit + push.

---

## Track A — Self-hosted CI (AFTER Track B lands)

### Task A1: Runner setup scripts 🔵 (user runs them)

**Files:** `ci/runners/setup-{linux.sh,macos.sh,windows.ps1}`, `ci/runners/README.md`

- [ ] **Step 1:** Write `ci/runners/README.md` explaining: labels (`[self-hosted, linux|macos|windows]` + `maker-<os>`), that the maintainer mints a token with
  `gh api -X POST repos/chaim354/tinkerex/actions/runners/registration-token --jq .token`,
  and that each script is idempotent + installs the runner as a service.
- [ ] **Step 2:** `setup-linux.sh` — install `rustup`, `libfuse-dev pkg-config rclone autoconf automake libtool build-essential`, download the latest `actions/runner` linux-x64 tarball, `./config.sh --url https://github.com/chaim354/tinkerex --token "$1" --labels self-hosted,linux,maker-linux --unattended`, `sudo ./svc.sh install && sudo ./svc.sh start`.
- [ ] **Step 3:** `setup-macos.sh` — `rustup`, the FUSE-T pkg-config alias (per `client/fs-fuse/BUILD.md`), `rustup target add x86_64-pc-windows-gnu` + `brew install mingw-w64` (for the CfAPI cross-check), download runner osx-arm64, config with labels `self-hosted,macos,maker-mac`, `./svc.sh install && ./svc.sh start`.
- [ ] **Step 4:** `setup-windows.ps1` — install rustup, LLVM + WinFsp (`choco install llvm winfsp -y`), download runner win-x64, `./config.cmd --url ... --token $args[0] --labels self-hosted,windows,maker-windows --unattended`, `./svc.cmd install; ./svc.cmd start`.
- [ ] **Step 5: Commit + push** — `git commit -m "ci: per-OS self-hosted runner setup scripts"`; `git push`. **Hand the user the three commands to run** (one per box); they report back the runners showing online (`gh api repos/chaim354/tinkerex/actions/runners --jq '.runners[].name'`).

### Task A2: Move Linux jobs to self-hosted (one job first) 🟢/🔵

**Files:** `.github/workflows/ci.yml`, `.github/workflows/rust-client.yml`

- [ ] **Step 1:** In `rust-client.yml`, change ONLY the `unix:` job `runs-on: ubuntu-latest` → `runs-on: [self-hosted, linux]`. Commit + push. Confirm the job goes green on the self-hosted Linux runner (via a PR or `workflow_dispatch`).
- [ ] **Step 2:** Once green, change the remaining Linux jobs (`engine-integration`, `mount-conformance` in `rust-client.yml`; `scan_ruby/scan_js/lint/test/system-test` in `ci.yml`). Each its own commit + push.
- [ ] **Rollback:** if a job goes red, `git revert` that single commit to restore `ubuntu-latest` for it.

### Task A3: Windows + new macOS job to self-hosted 🟢/🔵

**Files:** `.github/workflows/rust-client.yml`

- [ ] **Step 1:** `winfsp-windows` + `cfapi-windows` jobs: `windows-latest` → `[self-hosted, windows]` (drop the `choco install` steps the setup script already did, or keep them idempotent). Commit + push; confirm green.
- [ ] **Step 2:** Add a NEW `macos-cross` job `runs-on: [self-hosted, macos]` that runs `cargo check --target x86_64-pc-windows-gnu` in `client/fs-cfapi` + `client/sync-engine` (the CfAPI cross-check) and a native `cargo build` of `fs-webdav` + `sync-engine`. Commit + push; confirm green.

### Task A4: Live Windows CfAPI smoke job 🟡 (the regression net + B5 gate)

**Files:** `client/test-conformance/cfapi-smoke.ps1`, `.github/workflows/rust-client.yml`

- [ ] **Step 1:** Write `cfapi-smoke.ps1`: register a sync root → enumerate (assert library files appear) → hydrate a file (assert bytes match the control plane) → **create a new file, edit one, delete one, rename one** in the folder → assert each round-trips via the control plane (reuse the `doctor`/`push_update` examples or a small assertion binary). Use the deployed server `http://192.168.1.95` + a token minted by the `mac_host` example. Exit non-zero on any mismatch.
- [ ] **Step 2:** Add a `windows-smoke` job `runs-on: [self-hosted, windows]` that runs the script. Commit + push; confirm green on the self-hosted Windows runner.
- [ ] **Step 3:** With the smoke green, mark Task B5 (default flip) verified.

---

## Test suite — assert it all works (AFTER Track A)

### Task T1: Engine integration tests for the new write paths 🟢 (needs a local Rails server)

**Files:** `client/sync-engine/tests/integration.rs`

- [ ] **Step 1:** Add server-backed tests mirroring the existing style (`SYNC_IT_SERVER_URL`, skips without a server): (a) new-file create → appears on a second device; (b) `delete_by_node_id` → removal propagates; (c) rename propagates; (d) a node inserted on device A → device B's pull yields a `PlaceholderEvent::Create`. Boot the server per the cheatsheet: `STORAGE_BACKEND=memory bin/rails server -p 3001`.
- [ ] **Step 2:** Run: `STORAGE_BACKEND=memory bin/rails server -p 3001 &` then `cargo test --manifest-path client/sync-engine/Cargo.toml --test integration`. Expected: PASS.
- [ ] **Step 3: Commit + push** — `git commit -m "sync-engine: integration tests for new-file/delete/rename/remote-insert"`; `git push`.

### Task T2: Wire the suites into self-hosted CI 🟢

- [ ] **Step 1:** Confirm `node_id_ops.rs` (fs-provider), the `fs-cfapi` pure-logic tests, the `sync-engine` integration tests, and the `cfapi-smoke.ps1` job all run in the migrated workflows. Add any missing `cargo test` invocations to `rust-client.yml`. Commit + push; confirm the full matrix is green across linux/macos/windows self-hosted runners. This green matrix is the definition of "it all works."

---

## FSKit migration sketch — LAST (design doc only)

### Task F1: Write `docs/plan-macos-fskit-migration.md` 🟢

- [ ] **Step 1:** Write the sketch covering, per the spec: why FSKit over WebDAV (native, no kext, permissive, on-demand hydration like CfAPI); module shape (`client/fs-fskit` paralleling `fs-cfapi`, `FSUnaryFileSystem`/`FSVolume` over the same `Provider`, reusing the Option-B `invalidate` + real-nanos-mtime seams, wired as `sync_engine::FsKitMount`); the Swift/Rust FFI boundary; hydration-callback mapping (FSKit fetch/materialize ↔ our `hydrate`/`FETCH_DATA`; write callbacks ↔ the B1–B4 NOTIFY analogues); verification posture (macOS-only, manual until a self-hosted macOS smoke exists — which Track A's macOS runner enables); open questions/risks (macOS version floor, the greyed-toggle root cause, extension packaging/signing, ship-FSKit vs keep-WebDAV-fallback). **This is a sketch — it ends as a committed doc, no code.**
- [ ] **Step 2: Commit + push** — `git commit -m "docs: macOS FSKit migration sketch"`; `git push`.

---

## Self-Review notes
- **Spec coverage:** Track B §B0–B6 ↔ Tasks B0a–B6d; Track A §A1–A4 ↔ Tasks A1–A4; Test suite ↔ T1–T2; FSKit ↔ F1. All spec sections mapped.
- **Type consistency:** `delete_by_node_id`, `resolve_path`, `rename_by_node_id` used consistently in B1–B4 and T1; `PlaceholderEvent` enum introduced in B4 and referenced in T1.
- **Gaps/assumptions flagged in-task:** exact `windows`-crate signatures (B1–B4, B6) are resolved from the generated source at implementation time per the migration doc; `mem_provider`/`outbox_clear_for_test`/`ROOT_INO`/`FsError::NotFound`/`ApplyOutcome.inserted` are verified against the real source before use (noted in the tasks).
