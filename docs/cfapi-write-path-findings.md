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

## OPEN — intermittent rename conflict (server-side semantics)

In ~1/3 of runs, the **rename** (`notes.md → smoke-renamed`) is pushed (op=upsert) but the server
treats it as a **conflict** (`Sync::Commit#finalize`: `base_version_id != prior_current`), so it
keeps the node at the old name and records a conflict instead of applying the rename. The fresh-
device oracle then still sees `notes.md` (and no `smoke-renamed`), failing the B3 assertion.

What's confirmed:
- The rename is captured correctly (right `node_id`, right new name) and **pushed** (commit reaches
  the server).
- It's the SAME node_id as the seeded `notes.md` (a true in-place rename), not a duplicate.
- The delete + new-file + edit on the same run apply fine; only the rename conflicts, intermittently.
- `commit_finalize` returns only `{version_id, seq}` — the client can't tell its own commit was
  recorded as a conflict, so it can't self-resolve.

Working hypothesis: between the snapshot pull (which seeds the local `version_id`) and the rename's
push, the local node's effective base version diverges from the server's `current_version` — likely
a race between the daemon's self-echo pull (`apply_change` updating `version_id`) and the push
reading the base — so the rename commits on a stale base and the server flags a (spurious, same-
device) conflict. A `push_node: commit … base_version=…` log was added to pin the exact base sent
on a failing run.

Likely real fix (not yet landed): either (a) have `commit_finalize` report whether it recorded a
conflict so the daemon can re-push the rename on the now-current base (a same-device conflict is not
a real cross-device divergence), or (b) re-read the node's current `version_id` under the push gate
immediately before `commit_begin` so a concurrent pull can't stale the base. This sits in the
conflict-detection / daemon-echo protocol, somewhat orthogonal to the CfAPI adapter itself.

This does NOT affect the core CfAPI write-path (capture → push); it's a version/conflict-semantics
edge case in the sync engine that the rename exercises.
