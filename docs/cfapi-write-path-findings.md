# CfAPI write-path fixes — findings & status

Working notes for the Windows CfAPI write-path hardening (branch
`worktree-agent-af328b23f11a2dc23`, off `auth-caching-security`). Live-verified against the
self-hosted Windows runner via `gh workflow run rust-client.yml -f target=cfapi`
(`client/test-conformance/cfapi-smoke.ps1`).

## Fixed (verified live)

### B1 — new-file capture (was: never fired)
CfAPI delivers **no callback** for a brand-new file created directly in the sync root — its
`NOTIFY_*` callbacks only cover files already in the placeholder namespace (verified: editing /
deleting / renaming seeded placeholders fired `NOTIFY_FILE_CLOSE`, but creating `smoke-new-*.txt`
fired nothing). This matches OneDrive, which runs its own directory watcher for local creations.

Fix: a `ReadDirectoryChangesW` watcher (`client/fs-cfapi/src/win.rs` —
`spawn_new_file_watcher` / `new_file_watch_loop`) over the sync root feeds ADDED/MODIFIED paths
into `capture_new_file`, which is now idempotent (an existing node routes to an edit; the convert
is skipped). The watcher uses overlapped I/O + a stop event for a clean, prompt shutdown.
**New files now reach the server in every run.**

### Captured writes reaching the server (was: never pushed)
- `SyncEngine::push_outbox` is now **per-node error-isolated**: one node failing to push no longer
  aborts the whole drain and blocks its siblings; a failure is logged and left queued for retry.
- `maker-cfsyncd` watches a `<db>.stop` sentinel for **graceful shutdown** (the smoke touches it
  instead of `Stop-Process -Force`), so an in-flight push can finish.

### Graceful-shutdown hang (was: 15–40 s hang → force-kill → captures lost)
Multiple causes, all fixed:
- **Re-entrant CfAPI during teardown deadlocked the closing connection.** CfAPI flushes its
  batched NOTIFY callbacks at unmount; processing them re-entered CfAPI
  (`CfConvertToPlaceholder` / `CfSetInSyncState` / the ACK `CfExecute`s) and wedged
  `CfDisconnectSyncRoot`. Likewise the sync-loop pull's `invalidate`/`created`
  (`CfUpdatePlaceholder` / `CfCreatePlaceholders`). Fix: one shared `shutting_down`
  `Arc<AtomicBool>` (mount callbacks + `CfApiInvalidate`), flipped by `begin_shutdown()` at the
  very top of `CfApiMount::stop`; every re-entrant path bails while it's set (still mirroring the
  change into the provider/outbox).
- **The sync thread's push could be mid-HTTP at unmount.** Added a 30 s request / 10 s connect
  timeout to the `reqwest::blocking::Client` (`sync-client`) so a stalled push can't block forever.
- **Teardown order:** `begin_shutdown` → set stop → disconnect (flushes callbacks → outbox) →
  **main-thread drain** of the outbox → bounded-join the sync thread. The drain is the
  authoritative final push.
- **Self-conflict guard:** a `push_gate` `Arc<Mutex<()>>` serializes the sync loop's tick against
  the drain so they never push the same node concurrently.
- **Patient drain:** CfAPI delivers stragglers lazily, so the drain keeps going until the outbox
  has been empty for a sustained window (and a bit past the last activity), bounded by 25 s.

### `apply_remote` (parent,name) collision (was: oracle UNIQUE-constraint failure)
`apply_remote` now recursively displaces any *different*-node_id row at the same `(parent, name)`
before insert/update — the remote snapshot is authoritative. Mirrors the local POSIX
rename-replace path; covered by `apply_remote_displaces_a_name_collision`
(`client/fs-provider/tests/convergence.rs`).

## Smoke status

B1 (new file), edit, and delete reach the server **reliably**. The smoke passes the large majority
of runs. The hang is gone.

## Two more causes found + fixed for the intermittent rename/delete failure

The intermittent smoke B3 (rename) / B2 (delete) failures had **two** further causes, both fixed:

1. **Runner pollution (test isolation).** The smoke's after-tree sometimes showed files from PRIOR
   runs — a `maker-cfsyncd` that outlived an earlier (hung→force-killed) run kept a **live new-file
   watcher**, capturing/pushing into a stale library on the shared self-hosted runner. Fix: the
   smoke + conformance now `Stop-Process maker-cfsyncd` before each run. This alone took the smoke
   from ~50% to ~80% green.

2. **Same-device self-conflict (server-side).** With a clean, isolated library the rename still
   occasionally conflicted: the daemon pushes the rename, pulls its own changelog entry back
   (advancing `current_version`), then a follow-up/retry push still carries the pre-echo
   `base_version_id`. `Sync::Commit#finalize` saw `base != current` and recorded a CONFLICT — but
   it's the **same device's** own sequential write racing its echo, not a cross-device divergence,
   so the rename never applied. Fix (`app/services/sync/commit.rb`): a stale base from the SAME
   device (prior current version's `device_id == pending.device_id`) **fast-forwards** (op=put); a
   genuine conflict still needs a *different* device. Covered by a new `conflicts_test` case; all 55
   server tests green.

   ⚠️ **The server fix takes effect only after redeploying the live server** (`192.168.1.95`) — the
   CfAPI smoke hits the deployed instance, which runs the prior code until `rsync` + `~/kamalw
   deploy` (see `docs/DEPLOY.md`). Until then the smoke can still hit the same-device conflict ~1/5;
   the **conformance** harness does not (its create-wave → settle → churn-wave structure lets the
   echo settle, so the rename pushes cleanly — it passes green against the deployed server).

## Status

- **B1 (new file), edit, delete, rename** all reach the server and round-trip byte-for-byte.
- **`cfapi-conformance.ps1` PASSES green** against the live deployed server: 24 files across nested
  dirs, varied sizes (incl. > chunk size → multi-chunk/dedup), create/edit/delete/rename churn, all
  byte-exact on a fresh device.
- **`cfapi-smoke.ps1`**: green ~4/5 against the *deployed* (pre-fix) server; expected fully green
  once the server is redeployed with the same-device fast-forward.
