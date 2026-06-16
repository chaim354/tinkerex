# Build status — sync engine

**Updated:** 2026-06-16 (managed-Postgres hardening G2 + storage-orphan reaper G4 + file-layer polish G5/G8/G10 + R2 validated live)

## Latest (2026-06-16): managed-deploy hardening (G2/G4) + file-layer polish (G5/G8/G10) + R2 live (HEAD `94b7f02`)

Three PRs landed on `main` on top of the cross-OS E2E state, plus R2 was validated end-to-end
against a real bucket.

- **G2 — managed-Postgres hardening** (PR #11): a **boot-time statement-pooler safety guard**
  (`lib/postgres_pooler_check.rb` + `config/initializers/postgres_pooler_check.rb`) that refuses
  to boot behind a statement-mode pooler (it would silently break the transaction-spanning
  `User#next_seq!` `FOR UPDATE` row lock and corrupt the changelog with duplicate seqs);
  `sslmode` defaulting in `config/database.yml` (`require` off-localhost, `prefer` local);
  Solid Queue/Cache/Cable roles documented for managed Postgres. **Real concurrency deadlock
  fix:** `next_seq!` is now the *first* statement in `Sync::Commit#finalize`/`Mutation#apply`/
  `Restore`/`Conflicts`, so two concurrent commits can't deadlock on a `FOR KEY SHARE`→`FOR
  UPDATE` lock upgrade (`test/services/sync/concurrent_seq_test.rb`). `docs/SYNC_SERVER.md` +
  `docs/parity-roadmap.md` updated by that PR (authoritative).
- **G4 — storage-orphan chunk reaper** (PR #10): `Sync::ChunkReaper` + `ChunkReaperJob` (weekly
  via `config/recurring.yml`) + `Storage::ChunkStore#list` + `lib/tasks/chunks.rake`. Sweeps
  chunk **bytes** left in object storage by commits that uploaded but never finalized — objects
  with **no DB row**, which the refcount-based `version_retention` sweep cannot see. Closes the
  abandoned-upload storage leak (matters for managed R2 cost; weekly cadence because
  `list_objects_v2` is billed per request, with a 24 h grace window protecting in-flight
  uploads). `docs/torn-writes-and-batching.md` §5 marked resolved by that PR (authoritative).
- **G5/G8/G10 — file-layer polish** (PR #12, in `fs-provider`/`fs-fuse`/`sync-engine`): an
  **opt-in (default-OFF) outbox debounce** for big CAD autosaves; a **special-file `EPERM`
  guardrail** (FIFO/socket/device nodes rejected cleanly); and a **delta-on-wire audit**.
- **R2 validated LIVE** (2026-06-15, docs in PR #9): the `Storage::S3ChunkStore` presign path
  was exercised end-to-end against a real R2 bucket (`maker-chunks-prod`, ENAM) — compatibility
  confirmed (`presigned_roundtrip` OK, chunk byte-for-byte in the bucket) and per-chunk hydrate
  latency measured (**~85–205 ms**, invisible in the local-first UX — metadata is local, hydrate
  is background/on-demand). See `docs/r2-migration.md` §5. A **parallel/pipelined chunk-hydration**
  optimization (concurrent `io.get` across a bounded pool, the one lever for large *cold* files)
  is **in flight on a separate branch — not yet merged**.
- **Next:** the maker app layer (Projects→Inventory→BOM→preview); then the parity roadmap
  (OAuth/OIDC → sharing → encryption-last). See `docs/HANDOFF.md`.

## Previous (2026-06-15): automated cross-OS real-mount E2E + web UI MVP + real auth (HEAD `bab90bb`)

A large batch landed on `main`, and a deep cross-OS debugging arc got **automated real-mount A↔B
end-to-end green on all three OSes** (Linux FUSE, Windows CfAPI, macOS WebDAV) in `nightly.yml`.

- **Cross-OS real-mount E2E green (all 3):** the saga surfaced + fixed real on-hardware bugs:
  Windows CfAPI **3 receive-side bugs** (empty-dir enum `0x8007017C`; create-materialization
  parent-placeholders; delete/rename removal + echo-guard); Linux FUSE **`fuser` 0.14→0.17 upgrade**
  + the actual bug (`run_until_unmounted` used `umount_and_join()` which unmounts immediately in 0.17,
  vs `join()` wait-only). Long chain of eliminated red herrings (AppArmor, /dev/fuse, fusermount3,
  module, privilege) — `bindfs` held while ours didn't → proved it was our code. Regression smokes kept.
- **Real auth (Rails 8 built-in):** signup/confirm/login/reset + `Session` + OmniAuth seam; replaced
  the web UI placeholder; device-token/pairing untouched. Security review: 1 HIGH (OAuth email-link
  takeover) fixed; rest sound; brakeman 0.
- **Web UI MVP:** server-rendered file browser (upload via presigned PUT + `Sync::Commit`, download,
  inline view, soft-delete) + **trash/undelete**. Bytes stay off Rails.
- **Sync features:** **selective sync** (subtree subscriptions + hydration gate), **progressive/range
  hydration** (`hydrate_range`), **client bandwidth controls** (`ThrottledChunkIO`).
- **Hardening + research:** stress/concurrency (≤50 devices) + 15-filetype conformance (no corruption);
  **torn-write safety confirmed** (finalize is one transaction); `STORAGE_BACKEND=local` test backend;
  `image_processing`→2.0; `SecureRandom` pairing codes. New docs: `parity-roadmap.md`,
  `torn-writes-and-batching.md`, `r2-migration.md` (config-only R2 plan + latency harness).
- **Server 144/0.** Cross-machine `cross-os-e2e.yml` wired (gated on mac→shared-server reachability).
- **Next:** the maker app layer (Projects→Inventory→BOM→preview); then parity roadmap
  (OAuth/OIDC → sharing → encryption-last). See `docs/HANDOFF.md`.

## Earlier (2026-06-14): `auth-caching-security` merged to main + file layer hardened to "rock-solid"

The big `auth-caching-security` arc landed on **`main`** (squash PR #8), and a hardening batch
on top closed the remaining file-layer gaps. The headline: an adversarial fault-injection
harness was built and **found two real changelog ordering bugs**, both now fixed and verified.

- **Postgres validated** (CLAUDE.md §12 step 8): the adapter-agnostic server runs green on
  Postgres (Docker), 56/0; switch is config-only via `DATABASE_URL` (a `postgres` profile in
  `database.yml`). `next_seq!` row-lock exercised on PG. Caveats for a real managed deploy (TLS
  `sslmode`, **session/transaction** pooling not statement pooling for `FOR UPDATE`, concurrent-
  commit load test, Solid Queue/Cache/Cable still on SQLite) noted.
- **GC/retention wired** (closes an unbounded-storage bug): `Sync::RetentionPolicy`
  (`keep_all` self-host / `tiered` managed, current + `pinned` versions never pruned),
  `RetentionJob` (nightly via `config/recurring.yml`), and the actual S3 `delete_object` in
  `sweep_orphans!` (row destroyed first, then best-effort idempotent storage delete).
- **CfAPI B6 polish**: pin/unpin ↔ hydrate/dehydrate, `CfUnregisterSyncRoot` remove-library
  lifecycle, streamed page-aligned `FETCH_DATA` (+cancel), O(1) ino→path index. Windows CI green.
  (pin/unpin + remove-library are code-complete; need interactive-Explorer verification.)
- **Two-device end-to-end suite** (`client/sync-engine/tests/two_device_e2e.rs`, 9 tests): the
  A→write→B→pull→edit→A→pull byte-for-byte roundtrip + nested-dir/delete/rename/dedup/restore/
  conflict/lock/offline — driving the same engine loop the Tauri app uses. Per-OS CI jobs
  (`e2e-linux`/`e2e-macos`/`e2e-windows`) green.
- **Adversarial fault-injection harness** (`client/sync-engine/tests/fault_injection.rs`,
  "Trinity"): injected PUT/GET faults, mid-pull/push crashes, randomized interleaving, concurrent
  edits; asserts no-data-loss + convergence + idempotency, seeded + soak-validated 1000×200.
- **Two real bugs found + fixed** (merged `ce72f25`): (1) **outbox drained child-before-parent**
  on a move into a newer dir → pull abort → `outbox_list_topo()` topological drain.
  (2) **a pull could hard-delete a locally-renamed-but-unpushed node** (collision/recursive-delete
  sweep) → silent convergence loss → defer-and-retry parentless upserts + a sticky `needs_resync`
  that triggers the `pull_snapshot` reconcile floor. Soak: **0 silent losses** (373/1000 self-heal
  via the floor). All suites green (fs-provider, integration 19/0, two_device_e2e 9/0, harness 10/0).
- **UI polish** (`client/maker-app`): accessible loading/empty/error states, closable conflict
  modal, restore confirmation, pairing copy-to-clipboard, per-OS backend label (CfAPI default).
- **Loose ends cleared**: pairing codes now from **SecureRandom** (not `Array#sample`);
  `image_processing` 1.x→**2.0.2** (Dependabot #5); GC retention tests made **deterministic**
  (frozen clock; `sweep_orphans!` uses `updated_at <= cutoff` so grace:0 = sweep-now). Server
  suite **75/0**.
- **New strategy docs**: `docs/research-sync-competitors.md` (vs Dropbox/Drive/Nextcloud/oCIS/
  OpenCloud/Seafile/Syncthing + ranked gaps) and `docs/feature-set-and-workflows.md` (supported
  today / gap workflows, FILE-LAYER vs MAKER-APP).

**Open file-layer items (non-correctness, shape the product):** selective sync (research #2) and
at-rest chunk encryption (#3). Both fit the existing chunk/manifest/changelog model. Next big
arc: the **maker app layer** (projects/inventory/BOM/preview — §12 step 9).

## Earlier (2026-06-12): Windows CfAPI mount — read+write loop live, offline-capable

Building on the verified-live populate+hydrate (below), the CfAPI mount now runs the full
read **and** write loop on real Windows 11, and behaves correctly offline. Detailed handoff
+ remaining plan: **`docs/plan-windows-cfapi-migration.md`**.
- **Remote-change invalidation** live: a file edited on another device refreshes on next open
  (`CfUpdatePlaceholder` + `CfDehydratePlaceholder` via the engine `Invalidate` seam; updates
  the new size+mtime, then dehydrates so the next read re-fetches).
- **Phase 2 (edits)** live: a local edit to an existing file is captured via
  `NOTIFY_FILE_CLOSE_COMPLETION` + a content-compare self-write filter →
  `Provider::ingest_bytes` → the sync loop pushes it. (New files / deletes / renames = Phase 2b.)
- **Offline availability** (cross-platform): hydrated files persist on unmount (CfAPI Drop now
  only disconnects — no unregister/delete), and because the content-addressed chunk cache
  persists and the engine only fetches *missing* chunks, a hydrated file reads with **no
  network** on macOS/Windows/Linux. Test `hydrated_file_stays_readable_offline` (dead server +
  erroring transport → still reads from cache).
- **Stale-DB guard:** `Provider::bind_library(hash(server, token))` wipes a *different*
  library's stale tree/cursor on mount (keeps the chunk cache) — wired into **all four** mounts
  (FUSE/WebDAV/WinFsp/CfAPI). Fixes the reused-DB "cursor ahead of head_seq → remote edits never
  apply" + duplicate-placeholder bug. Tested (`bind_library_wipes_a_different_librarys_stale_state`).
- Three live-bring-up bugs fixed (each caught by the doctor/log workflow): on-demand population
  (empty-tree-at-mount + missing FETCH_PLACEHOLDERS → hang), always-answer FETCH_DATA, and a
  null-`FileIdentity` `from_raw_parts` panic on root enumeration. See the plan's "gotchas".

## Earlier (2026-06-12): Windows CfAPI mount — **verified live** (populate + hydrate)

The driverless CfAPI mount **runs on real Windows 11 hardware**: a sync root registers, Explorer
enumerates it, and files hydrate on open (no GPL driver — the §9 win, on actual hardware). Three
runtime bugs from the first live run, each caught by the doctor/log diagnostics and fixed:
- `populate()` ran at mount against the *empty* local tree + there was no FETCH_PLACEHOLDERS
  handler → enumeration hung. Switched to **on-demand population** (PARTIAL policy +
  FETCH_PLACEHOLDERS reading the provider's live tree) + a **pre-mount snapshot pull**.
- `FETCH_DATA` could return without answering → reading app hung. Now **always answers**
  (error completion on failure).
- `slice::from_raw_parts` on the root's **null FileIdentity** → UB panic on the callback thread.
  Added `callback_node_id` (null → root).
Diagnostics added: `eprintln` in both callbacks + a layered **`doctor` example** (control plane +
storage reachability, no CfAPI) that isolated the failure to the CfAPI layer. Still to exercise
live: remote-change invalidation + clean teardown. **Phase 2** = local-edit capture.

## Earlier (2026-06-12): Windows CfAPI migration — Phase 1 (driverless mount)

`client/fs-cfapi` — the **driverless** Windows mount (Cloud Filter API; no GPL WinFsp driver,
the OneDrive model: a registered sync-root folder with on-demand hydration + native Explorer
integration). **Phase 1** = the download/read half: register the root, **populate** every node
as a dehydrated placeholder from the local `Provider` tree, **hydrate** on the FETCH_DATA
callback (presigned GET → chunk cache → `CfExecuteOperation(TRANSFER_DATA)`), and **invalidate**
on a remote content change (`CfUpdatePlaceholder` + dehydrate). Wired as
`sync_engine::CfApiMount` + the `maker-cfsyncd` bin. **Now the DEFAULT Windows backend**
(flipped 2026-06-14): Phase 2b complete (new-file/delete/rename capture), **live smoke +
byte-for-byte conformance green** against the deployed server; WinFsp behind the
`winfsp-backend` feature.
- Reuses the Option-B seams directly: the engine's `Invalidate` trait → `CfUpdatePlaceholder`
  (an `EngineCfInvalidate` newtype bridges them), and real nanos mtime → `FILETIME`.
- New `Provider::ingest_bytes` (the Phase-2 local-edit primitive: re-ingest an edited on-disk
  file as a node's new version) — tested.
- Pure logic (`FileIdentity` node_id↔blob, nanos↔FILETIME, placeholder-action decision) is
  **unit-tested cross-platform** (6 tests, green on macOS/CI). The Windows FFI is authored on
  macOS (like `fs-winfsp` was), compiled by the new `cfapi-windows` CI job, **runtime-UNVERIFIED**
  — smoke steps in `client/fs-cfapi/BUILD.md`.
- **Phase 2** (next): capture local edits/creates/deletes (CfAPI doesn't route writes through
  us) via a USN-journal / `ReadDirectoryChangesW` watcher → `ingest_bytes` → push →
  `CfSetInSyncState`. Plan: `docs/plan-windows-cfapi-migration.md`.

## Earlier (2026-06-12): real-mtime preservation + active cache invalidation (Option B)

Replaces the `mtime = now`-on-pull freshness hack (which destroyed the true modification
time — breaking `make`/`ninja`/`cargo` incremental builds) by splitting mtime's two jobs:
**preserve the real mtime** end-to-end, and **invalidate the OS cache explicitly** on a
content-changing pull instead of relying on an mtime bump. Plan:
`docs/plan-real-mtime-and-invalidation.md`.

- `fs-provider`: `mtime` is now real, **unix nanoseconds** (build-tool resolution; maps to
  FILETIME/NSDate for the CfAPI/File-Provider future). `flush` stamps the real local mod
  time; `apply_remote` writes the **source device's** mtime verbatim (no more `now`), and
  returns an `ApplyOutcome { ino, content_changed }` so the adapter knows when to drop its
  cache. New `set_mtime` (the kernel's `utimensat`/`cp -p`). `SyncNode.mtime` round-trips
  through export/sync_node/apply.
- `fs-fuse`: `setattr(mtime)` → `set_mtime`; `file_attr` reports nanos.
- `sync-engine`: an `Invalidate` seam (cross-platform) the pull path calls when a pull
  repoints an existing inode at new content. `EngineInvalidate` (FUSE-only) holds the
  session `Notifier` and calls `notify_inval_inode` (abi-7-12); shared by the sync loop +
  freshness adapter (whichever applies the change first invalidates), wired into the
  `Daemon` via deferred notifier injection (the construction-cycle break). WebDAV/WinFsp
  pass `None` (lean on short metadata timeouts until CfAPI/File-Provider land — the same
  two primitives slot in here). `push_node`/converters carry mtime.
- Server: `nodes.mtime` + `pending_commits.mtime` as **bigint** (nanos in 2026 overflow a
  32-bit int); `Commit`/mkdir store it; tree + changes serialize it; controllers permit it.
- Tests: fs-provider (`pulled_node_keeps_the_source_mtime_not_now`,
  `apply_remote_reports_content_change_for_cache_invalidation`, updated
  `remote_update_serves_fresh_content_and_carries_real_mtime`), server (commit stores +
  tree/changes expose the bigint mtime), integration `real_mtime_propagates_across_devices`
  (A's 2001 mtime visible verbatim on B). External: rclone⇄WebDAV re-run clean.
  **Invalidation itself can't be unit-tested** (needs a live FUSE kernel) — verified by the
  Linux CI `mount-conformance` path / manual smoke (edit on A, `cat` on B before/after).

## Earlier (2026-06-12): file mode / executable-bit preservation

The one POSIX-fidelity gap that actually bites makers (scripts/binaries losing `+x` after
sync — see the conformance dig): file mode is now preserved end-to-end.
- `fs-provider`: `mode` column (+ ALTER) defaulted 0644/0755; `Attr.mode`; `set_mode`
  (chmod, enqueues sync); `getattr` reports it; `SyncNode.mode` round-trips through
  `apply_remote`/export/sync_node. Persists across reopen.
- `fs-fuse`: `file_attr.perm` from mode; `setattr(mode)` → chmod; `create` captures the
  create-time mode.
- Server: `nodes.mode` (+ `pending_commits.mode`); `Commit`/mkdir store it;
  tree + changes serialize it; commit/mkdir params permit it.
- Client: `CommitBegin.mode`, `mkdir(mode)`, `NodeView`/`TreeNode.mode`; `push_node` sends
  it, the converters read it.
- Tests: fs-provider (mode set/sync/reopen), server (commit stores + tree exposes),
  integration `executable_bit_propagates_across_devices` (chmod +x on A → 0755 on B).

This is mode *preservation*, not enforcement (ownership/uid-gid deliberately not synced —
meaningless across devices). Remaining POSIX gaps (symlinks/hardlinks/special files,
ctime/atime) are intentional non-goals for a personal sync drive.

## Earlier (2026-06-12): best-effort cross-device lock

Layered on the local locks + conflict detection: a **best-effort advisory edit lock**
across devices. On open-for-write the client (when connected) acquires a server lock so
other *connected* clients see the file is being edited; if it can't reach the server the
open just proceeds on the local cached copy, and conflict detection reconciles on
reconnect. Advisory + TTL-based (a disconnected holder's lock auto-frees), never blocking.

- Server: `FileLock` (TTL) + `Sync::Locks` (acquire/refresh/release/status/active — never
  steals a live lock; expired locks reclaimable). `POST /v1/nodes/:id/lock` + `/unlock`,
  `GET /v1/locks`. 6 tests (`locks_test.rb`): grant, no-steal, holder-refresh, expiry
  reclaim, release-only-by-holder, active/status reflect expiry.
- Client: `ServerClient::lock`/`unlock`/`locks` (2s timeout so offline never hangs the
  open). `fs-fuse` gains a `RemoteLock` hook; `sync-engine::EngineRemoteLock` acquires on
  open-for-write / releases on close **in a background thread** (non-blocking). Wired into
  the Daemon. Integration test `best_effort_lock_coordinates_connected_devices` (live).
- App: the file browser shows a 🔒 + holder name for files locked on another device.

## Earlier (2026-06-12): file locking + conflict detection & resolution

Local-first concurrency = local advisory locks + cross-device conflict detection (NOT
distributed locks — can't hold a WAN lock offline; the synchronous model we rejected).

- **Local advisory locking** — `fs-provider::LockManager` (POSIX byte-range advisory
  locks, owner-tracked, conflict = different owners + overlapping range + ≥1 exclusive,
  released per owner on close; 7 unit tests). Provider trait gains
  `set_lock`/`test_lock`/`unlock`/`release_locks`; `fs-fuse` wires `setlk`/`getlk`/release.
  Non-blocking (F_SETLKW retry-wait is a TODO).
- **Conflict detection** — each commit now sends `base_version_id` (the client tracks the
  server version each node reflects: a new `version_id` column in `fs-provider`, populated
  on pull, advanced after a push, sent on the next commit). When the base is no longer
  current (a divergent offline edit), `Sync::Commit` records a **conflict** (keeps both
  versions, emits a `conflict` changelog op) instead of last-writer-wins dropping an edit.
- **Resolution** — `Sync::Conflicts`: keep one side current, or **split** (the incoming
  side becomes a new sibling "foo (conflict from <device> <when>).ext", reusing its
  manifest → zero new blocks). `GET /v1/conflicts` returns both sides with device + time +
  size; the app shows a resolution **popup** (keep this / keep that / keep both).
- Tests: server 41→47 (`conflicts_test.rb`), sync-engine integration +2
  (`offline_divergent_edit_raises_a_conflict`, `sequential_edits_fast_forward_without_a_conflict`),
  fs-provider +7 lock tests. The old LWW integration test is replaced (concurrent edits now
  conflict by design).

## Earlier (2026-06-12): auth, security, caching, freshness-on-access, file browser

Branch `auth-caching-security`. Areas:

### Freshness-on-access (the on-open catch-up pull)
A file open now does a quick, **throttled** changelog catch-up pull before serving, so an
open never returns a copy another device already changed — closing the window between
background sync ticks. `fs-fuse` gained a `Freshness` hook in `open`; `sync-engine`
`EngineFreshness` implements it as `pull_changes` throttled to ≥750 ms (the loop + nudge
keep us mostly current, so this only matters in the sub-tick gap), wired into the `Daemon`.
Red-green integration test `freshness_check_on_access_serves_latest_after_remote_change`:
RED = stale read before catch-up, GREEN = latest after. Versioning/restore design sketched
in `docs/versioning.md` (near-delta-per-version via CDC + dedup; restore reuses a manifest
for zero new blocks; retention/GC policy to bound growth).



### Auth + cross-user security (server 30→41 tests)
Audited the client↔sync-engine and ↔bucket-storage auth. **Cross-user isolation was
structurally sound** — presigned URLs are SigV4-signed for a per-user key
(`chunks/<user_id>/<hash>`, untamperable), chunk storage/metadata + dedup are per-user,
and every node mutation scopes through `current_user.nodes`. **The one real hole was the
bootstrap:** `register` did `find_or_create_by!(email)` and handed out a device token for
*any* email → account takeover. Fixes:
- `register` creates a **new account only** (409 on an existing email).
- Additional devices join via a **single-use, 10-min pairing code** issued by an
  authenticated device (`DevicePairing`; `POST /v1/devices/pairing` → `POST /v1/auth/pair`).
  SHA256-digested, atomic single-use claim, generic error (no account enumeration). The
  Syncthing/Plex model — secure multi-device without external OAuth (the later
  email-verification upgrade, §12.5).
- Defense in depth: `/v1/chunks/download` only mints URLs for chunks the requester owns.
- Client: `create_pairing()`/`pair()` on `ServerClient`; **maker-app persists the device
  token** (register/pair once, reuse) instead of re-registering each start.
- Tests: `auth_test.rb`, expanded `tenant_isolation_test.rb`, live pairing integration.

### Client caching / freshness (fs-provider 50→53)
- **`mtime` was permanently 0** — never written on commit or pull, so a same-size edit on
  another device was invisible (open a minute later → stale cached copy). `flush` and
  `apply_remote` now stamp `mtime = now` → readers re-read + re-hydrate the new manifest.
- **Random writes could miss** (write seeds from committed content; only `read` had a
  hydrate-retry). `fs-fuse`/`fs-winfsp` `open` now hydrate the whole file on write-intent.
  WebDAV (whole-file PUT/GET) is unaffected. Tests in `tests/caching.rs`.

### App: file browser + versioning
`sync-client::versions()`; maker-app `browse`/`file_versions`/`restore_version` commands;
frontend rebuilt — status pill, "this is my device" vs "pair with a code" tabs, an
"add a device" pairing-code panel, and a file tree that expands per-file version history
with one-click restore.

## Earlier (2026-06-11): external conformance suites

Added independent, battle-tested external tools pointed at our real mount surfaces — the
same suites JuiceFS/CephFS gate on — so robustness isn't only self-authored tests.
`client/test-conformance/` + a `mount-conformance` CI job (`rust-client.yml`):

- **`webdav-rclone.sh`** (gating, cross-platform) — drives `fs-webdav` with **rclone**:
  `copy` a tree in, `check --download` every file byte-for-byte, then modify/append/delete
  + `sync` + re-check. **Verified locally on macOS** (0 differences, initial 8 files +
  post-delta 7 files). Exercises read+write through chunking + the content store with an
  independent client.
- **`fsx-fuse.sh`** (gating, Linux) — **fsx** (xfstests) against `fs-fuse`: a long
  randomized write/read/**truncate** stream verified against an in-memory model — the
  strongest adversarial check of the data plane. CI-verified on first run (no FUSE on the
  macOS build host, same as fs-winfsp).
- **`pjdfstest-fuse.sh`** (informational, Linux) — **pjdfstest** POSIX semantics for the
  ops we implement (rename/unlink/mkdir/rmdir/truncate/open); perms/owner/link tests are
  out of scope, so it's a conformance *map*, not a gate (`continue-on-error`).

These cover the **mount**; distributed-sync convergence stays the job of the
`fs-provider/tests/convergence.rs` FakeFolder harness (no external suite exists for that).

## Earlier (2026-06-11): offline/reconnect hardening (§12.6)

## Latest (2026-06-11): offline/reconnect hardening (§12.6)

Hardened the path real usage hits but the demos never did — a device going offline and
reconnecting far behind. Found and fixed a concrete data-loss bug.

- **Changelog pagination data-loss bug — FIXED.** `pull_changes` made a *single*
  `changes(cursor)` call then advanced the cursor to the global `head_seq` — so a device
  more than one server page (500) behind applied only the first page yet jumped its cursor
  past everything, **silently dropping every entry beyond page 1**. The exact
  offline-reconnect failure. `pull_changes` now **loops**, advancing the cursor to the
  *last applied entry's seq* each round until caught up. Regression-tested
  (`pull_changes_pages_through_a_backlog_without_dropping_entries`, forces multi-page via a
  small page size).
- **Full-resync backstop.** The changes endpoint now reports `oldest_seq` (the lowest
  retained changelog seq); `Sync::Gc.prune_changelog!(user, keep_after:)` is the retention
  op that moves it. If a client's cursor falls below the retained floor (`oldest_seq >
  cursor + 1`), the entries it needs were pruned, so `pull_changes` falls back to a full
  `pull_snapshot` instead of skipping the hole. Server contract tested in
  `test/services/sync/changes_test.rb` (pagination order/limit, oldest_seq floor, the
  pruned-gap signal, snapshot stays complete after a full prune).
- **Offline reconcile + hydrate-after-conflict verified.** New integration tests: a device
  that queues writes offline while another pushes converges on reconnect (push-then-pull),
  and `hydrate` correctly follows a manifest swapped in by a conflict pull (reads the
  winning version's bytes — the path the LWW test had sidestepped).

Tests: server 26→**30**, sync-engine integration 6→**9**. (~90 → ~94 total.)

## Earlier (2026-06-11): comprehensive sync-foundation test suite

## Latest (2026-06-11): comprehensive foundation test suite

Paused feature work to harden the file-sync foundation with a real test suite, modeled on
how production sync/chunking systems test: **rclone `fstests`** (one contract suite over a
backend), **restic/borg chunker** (round-trip + boundary-stability properties),
**ownCloud/Nextcloud `FakeFolder`** (model-based multi-replica convergence), **JuiceFS
pjdfstest** (POSIX semantics), and **Dropbox**-style randomized state-machine checks.
Added `proptest` (dev-only) for property tests with shrinking.

**~90 tests, up from ~40.** Tiers:
- **fs-provider (hermetic, no server) — 50 tests** in `client/fs-provider/tests/`:
  `chunking` (round-trip for every size, dedup, **block-delta boundary stability** — a
  front-insert keeps ≥half the chunks, an append keeps all but the last, a 1-byte edit
  perturbs few; size bounds; zeros/repetitive/random), `posix_semantics` (rename-over
  replace, dup/missing errors, unicode/long names, deep nesting, re-create-after-delete),
  `convergence` (3-replica random-op FakeFolder harness asserting byte-identical trees
  every step; durability across reopen; idempotent re-apply; placeholder truncate),
  `concurrency` (shared-`Arc` threads + the chunk-store same-hash race).
- **sync-engine (server-backed) — 6 integration tests** in `tests/integration.rs`:
  roundtrip (real bytes), delete/move delta, **last-writer-wins**, hydrate-only-missing +
  idempotent, push dedup/idempotency, cursor monotonicity. Skips cleanly with no server;
  CI boots `STORAGE_BACKEND=memory` Rails and runs it (new `engine-integration` job).
- **Rails — 26 tests, up from 10:** added GC (`prune_version!` refcounts, `sweep_orphans!`
  grace/keep-live), restore (reuse manifest, bump refcounts, undelete, chain), tree
  pagination (cover-once, exclude-tombstoned, carry manifest), and tenant isolation
  (one user's token can't see/mutate another's tree/changes/nodes).

**Two foundation bugs the suite caught and fixed (both in `fs-provider`):**
1. **`rename` over an existing name** hit the unique `(parent, name)` index and errored
   instead of POSIX-replacing — so **atomic saves (write `f.tmp` → rename over `f`), how
   nearly every app saves, were broken on the mount.** Now replaces atomically and
   tombstones the displaced node (so the deletion propagates; no cross-device duplicate).
2. **`truncate(ino, 0)` read the base content first**, so an `O_TRUNC` overwrite of a
   pulled-but-unhydrated placeholder failed with `ChunkMissing` — a routine mount op.
   Truncate-to-empty now short-circuits without touching the (absent) bytes.

## Earlier (2026-06-11): §12.4 truncate gap closed

## Latest (2026-06-11): §12.4 truncate gap closed

The `Provider` trait had **no truncate**, so overwriting a file with fewer bytes than
before left the old manifest's trailing chunks past the new EOF — reads returned a stale
tail / wrong size (CLAUDE.md §12.4, a gap shared by all three mount adapters).

- **`Provider::truncate(ino, size)`** (impl on `SqliteProvider`): if the file is open for
  write, it resizes the in-memory staging buffer in place (the eventual `flush` commits
  the new length); otherwise it seeds from committed content, resizes, and commits
  immediately so a bare `truncate(2)` (and its outbox entry) is durable with no following
  write. Shrink drops the tail; grow zero-fills. Mirrored on `impl Provider for Arc<P>`.
- **Wired through every OS's truncate signal:** FUSE **`setattr(size)`** (`fs-fuse`),
  WinFsp **`set_file_size`** *and* the **`overwrite` disposition** (CREATE_ALWAYS /
  FILE_OVERWRITE — the common Windows "save a smaller file" path; both call
  `Provider::truncate`, `fs-winfsp`), and a **truncating WebDAV PUT open** (`fs-webdav`
  now honors `options.truncate`). The kernel issues `setattr(size=0)` on an `O_TRUNC`
  open before the shorter `write`, so the save-a-smaller-file path is now correct on
  macOS, Linux, and Windows. Caveat: `fs-winfsp` is `#![cfg(windows)]`, so the Windows
  legs compile only under the `windows-mount` CI job — unverified on the macOS build host.
- **Tests:** `overwrite_with_shorter_leaves_no_stale_tail` (reproduces the §12.4 bug —
  2000 bytes → truncate → 100 bytes → reads exactly 100) plus a grow/shrink test. The
  `convergence_under_random_ops` harness now overwrites via **truncate-then-write** (small
  length ceiling → shrink is the common case) and asserts the source committed exactly the
  new bytes (no stale tail); replica content convergence stays proven by the
  content-addressed `manifest_id` in the snapshot. fs-provider is now **15 tests** green.
- **Re-verified:** `(cd client/sync-engine && cargo run --example roundtrip)` against
  `STORAGE_BACKEND=memory` on `localhost:3001` — real bytes A→cloud→B, byte-for-byte.

## Earlier (2026-06-11): daemon loop wired + live SeaweedFS round-trip

## Live deployment (2026-06-11): full stack on an Unraid VM via Kamal

The Rails sync server is **deployed and verified** on an Ubuntu 26.04 Unraid VM
(`192.168.1.95`) via Kamal 2.11, all-on-one-box: Docker + a local htpasswd registry on
`127.0.0.1:5000`, image built in the host dockerd (`builder.driver: docker`), app behind
kamal-proxy on `:80`, Solid Cache/Queue/Cable on SQLite on a persistent volume. Chunk
storage is **SeaweedFS** (`STORAGE_BACKEND=s3`). Runbook: `docs/DEPLOY.md`.

**All three cross-stack demos pass against the deployed server** (`SERVER_URL=http://192.168.1.95`):
`e2e` (control plane), `nudge` (ActionCable `{head_seq}` via deployed Solid Cable through
kamal-proxy, ~130 ms), and `presigned_roundtrip` (real 40 KB file pushed to SeaweedFS via
presigned PUT, hydrated on a fresh device byte-for-byte). Two fixes were needed and are
committed: `config.solid_queue.connects_to` (Solid Queue was hitting the primary DB and
crash-looping Puma) and the single-host Kamal registry/builder config (127.0.0.1 + auth +
`driver: docker` to avoid the localhost reverse-tunnel + isolated-buildkit traps).

## Latest (2026-06-11, evening): §12 step 3 — delete/move propagation

Closed the correctness hole where the **delta pull dropped deletes** (`pull_changes`
had a literal `NOTE: 'delete' tombstones are not yet applied locally`): a file deleted on
device A was never removed on device B, and a move duplicated the file at both the old and
new path.

- **`fs_provider::apply_remote_delete(node_id)`** — removes the node and its whole subtree
  via a recursive CTE (a dir delete can't orphan children even if per-child deletes arrive
  out of order or not at all), idempotent (no-op on an already-gone or never-seen id), and
  does **not** touch the outbox (inbound change must never echo back to the server).
- **`SyncEngine::pull_changes`** now routes a change to `apply_remote_delete` when
  `op == "delete"` **or** the (soft-deleted) node carries `deleted: true`; everything else
  flows through `apply_remote`. **Moves needed no new code** — the server models a move as
  op `move`/`put` on the **same** stable `node_id` with a new parent/name, and
  `commit_begin` already carries parent/name, so `apply_remote` updates the row in place.
- **Verified end-to-end vs the live server**: `client/sync-engine/examples/delete_move.rs`
  — A deletes `trash.txt` and moves `note.txt` Inbox→Archive, B converges via a changelog
  **delta pull** (seq 4→6): deleted file gone, moved file at the new path only, trees
  identical. Passed against `STORAGE_BACKEND=memory` on `localhost:3001`.
- **Convergence harness** (`fs-provider` test `convergence_under_random_ops`): drives a
  deterministic pseudo-random stream of create/overwrite/delete/move ops on a source
  provider, replicates each step's outbox to a replica exactly as the daemon's pull does,
  and asserts the two trees stay byte-identical after **every** op. This is the mechanical
  backstop CLAUDE.md called for — it would have caught the dropped-delete/duplicated-move
  bugs. fs-provider is now **13 tests** green (15 after the truncate fix above).

## Latest (2026-06-11, afternoon): §12 steps 1 & 2 landed

- **Continuous sync loop wired.** `fs-provider` gained an `outbox` + `sync_state`
  (cursor) table; FUSE mutations (`flush`/`mkdir`/`unlink`/`rmdir`/`rename`) enqueue the
  dirty `node_id` atomically with the tree change. `sync-engine` gained
  `push_outbox` (incremental, drains the outbox without holding the SQLite lock across
  WAN I/O), `sync_tick` (the loop body = push_outbox + pull_changes), and
  `EngineHydrator`. `fs-fuse` gained a `Hydrate` hook: a `read` on a chunk-cache miss
  hydrates + retries. Proven end-to-end vs the live server in
  `client/sync-engine/examples/daemon_loop.rs`.
- **`maker-syncd` binary** (`client/sync-engine/src/bin/`) mounts FUSE and runs the loop
  in a background thread sharing one `Arc<SqliteProvider>` (`impl Provider for Arc<P>`).
  Compiles + supervises the thread cleanly; the live kernel mount needs an interactive
  session (FUSE-T won't hold a mount from a detached process — same limitation as the
  existing `maker-mount`; verify in Finder).
- **Live SeaweedFS round-trip DONE.** Real bytes through presigned PUT/GET to
  `192.168.1.7:8333` (bucket `my-bucket`), byte-for-byte on a fresh device —
  `client/sync-engine/examples/presigned_roundtrip.rs` against the `STORAGE_BACKEND=s3`
  server. Presigning worked first try.
- **Bonus fix:** `LocalChunkStore::put` used a fixed temp filename → concurrent writers
  of the same chunk hash raced on the rename (loser hit ENOENT). Now uses a unique temp
  name + treats a lost race as the dedup win. Load-bearing once the daemon writes the
  store from multiple threads.
- **ActionCable nudge wired.** `ServerClient::watch_library` (blocking tungstenite WS)
  subscribes to `LibraryChannel`; the daemon runs it on its own thread and feeds an mpsc
  channel the sync loop waits on via `recv_timeout(poll)` — so a `{head_seq}` broadcast
  wakes the loop in ~39 ms while the 2 s poll stays as the correctness fallback. Verified
  in `client/sync-client/examples/nudge.rs`. Required `disable_request_forgery_protection`
  for ActionCable (a browser-CSRF defense; our cable auth is a query-string device token,
  not cookies, so it doesn't apply and would 404 the native client).
- **Supervised daemon + Tauri app.** `sync_engine::Daemon` (`src/daemon.rs`) mounts via
  `spawn_mount2` (non-blocking) and supervises the sync + nudge threads on one shared
  `Arc<SqliteProvider>`; `start`/`stop`/`is_running`/`run_until_unmounted`. `maker-syncd`
  is now a thin wrapper. `client/maker-app` (Tauri) drives it via `sync_start`/`sync_stop`/
  `sync_status` with a mount form — see `client/maker-app/SETUP.md`. The native-mount dep
  is `cfg(not(windows))`-gated (FUSE is Unix-only): the app builds + launches on Windows
  with the mount disabled until the winfsp-rs adapter (step 4).
- **Step 1 is functionally complete** (watch→push, nudge/poll→pull, read→hydrate,
  supervised, GUI-driven). The only unverified leg is the live kernel mount, which needs
  an interactive desktop session (FUSE-T won't hold a mount headless).
- **Windows mount adapter started (§12 step 4).** New `client/fs-winfsp` implements
  WinFsp's `FileSystemContext` over the same `Provider` (+ a `maker-mount-win` binary),
  written against winfsp 0.13. It is **unverified** — the build box is macOS, where
  `winfsp` can't compile; the non-Windows path is an inert empty crate (confirmed). A
  `winfsp-windows` CI job (`.github/workflows/rust-client.yml`) compiles it on Windows —
  that's the verification gate. See `client/fs-winfsp/BUILD.md`. Once it builds + mounts
  via `maker-mount-win`, wiring it into the `Daemon`/Tauri app is a small follow-up.

---

**Original overnight build:**

The local-first sync architecture (`docs/architecture-sync-engine.md` +
`docs/sync-protocol.md`) is now real, working code across all three tiers, with the
**multi-device convergence path verified end-to-end** (Rust client ⇄ live Rails
server). Below: what exists, what's proven, how to run it, what's next.

## What's built & verified

| Component | Path | State |
|---|---|---|
| **Local FS core** | `client/fs-provider` | ✅ SQLite tree + content-addressed FastCDC chunk store. 5 tests. |
| **FUSE mount** | `client/fs-fuse` | ✅ Mounts via FUSE-T; **verified in Finder**; persists across remount. |
| **Sync server** | Rails app (`app/`, `db/`) | ✅ Full protocol. 10 tests green on SQLite. |
| **Sync client** | `client/sync-client` | ✅ Typed API + chunk transfer + pull-apply. 5 tests. |
| **Sync daemon** | `client/sync-engine` | ✅ push / pull / hydrate / sync_once; pluggable `ChunkIO` (shared-dir + presigned). |
| **End-to-end** | `examples/e2e`, `multi_device`, `roundtrip` | ✅ **Run live against the Rails server, incl. real chunk bytes.** |
| **S3/SeaweedFS storage** | server `STORAGE_BACKEND=s3` | ✅ Wired (`aws-sdk-s3`); presign verified against the SeaweedFS creds. Not round-tripped live (SeaweedFS unreachable from build env). |

### Proven end-to-end (Rust client → live Rails server)
- **Single device** (`e2e`): register → mkdir → commit(begin/finalize) → changes →
  tree → restore.
- **Multi-device** (`multi_device`): device A builds a tree; device B (second device,
  same user) initial-syncs via the snapshot, then **converges on A's delete via a
  delta pull**.
- **Full daemon roundtrip with real bytes** (`roundtrip`): device A creates a 40 KB
  file → `SyncEngine::push` chunks it + uploads to a cloud store → device B
  `pull_snapshot` + `hydrate` + read → **byte-for-byte identical**. Data plane (chunks)
  *and* control plane (changelog) both proven. The cloud store is a shared local dir
  standing in for SeaweedFS/R2 (unreachable from the build env); the presigned
  transport (`PresignedIO`) is built and the server presigns correct SeaweedFS URLs.

## How to run it yourself

**The server + cross-stack demo:**
```sh
# from repo root
STORAGE_BACKEND=memory bin/rails server -p 3001        # terminal 1
# terminal 2:
cd client/sync-client
SERVER_URL=http://localhost:3001 cargo run --example e2e
SERVER_URL=http://localhost:3001 cargo run --example multi_device
```

**The FUSE mount (macOS/FUSE-T):** see `client/fs-fuse/BUILD.md`.

**Tests:**
```sh
bin/rails test                              # server: 10
(cd client/fs-provider   && cargo test)     # 5
(cd client/sync-client   && cargo test)     # 5
(cd client/maker-app-core && cargo test)    # 3 (Windows mount controller)
```

## Architecture in one line

Each device backs its filesystem with a **local SQLite tree** (instant ops) + a
**content-addressed chunk cache**; the **Rails server** is the source of truth (tree +
versions + per-user changelog); **chunks** live in R2/S3 and move **client ⇄ storage
directly via presigned URLs** (never through Rails). Devices stay consistent by
pulling the changelog (`seq > cursor`); changes propagate via ActionCable.

## What's NOT done yet (next session)

1. **The running daemon loop.** `SyncEngine` (`push`/`pull_snapshot`/`pull_changes`/
   `hydrate`/`sync_once`) is **built and verified end-to-end with real bytes**
   (`roundtrip`). What's left is wiring it into a *continuous* loop on the client:
   (a) **watch the FUSE mount** (a write/flush → enqueue → push), (b) react to the
   **ActionCable** nudge (pull → apply), (c) hydrate on FUSE read (mount's `read`
   callback → `SyncEngine::hydrate`). Today push/pull are invoked explicitly; the
   loop + the mount↔engine wiring is the remaining integration.
2. **Real chunk bytes through S3/SeaweedFS.** The presigned transport (`PresignedIO`)
   is built, `aws-sdk-s3` is wired, and the server presigns correct SeaweedFS URLs
   (verified). Bytes were round-tripped end-to-end via a shared-dir stand-in, not live
   SeaweedFS (the box at `192.168.1.7:8333` was unreachable from the build env). To go
   live: start SeaweedFS, run the server with `STORAGE_BACKEND=s3
   CHUNK_ENDPOINT=http://192.168.1.7:8333 CHUNK_BUCKET=my-bucket
   CHUNK_ACCESS_KEY_ID=admin CHUNK_SECRET_ACCESS_KEY=secret`, and use `PresignedIO`
   in the daemon instead of `SharedDirIO`.
3. **Windows `winfsp-rs`** FUSE adapter (Linux + macOS work via `fuser`).
4. **Postgres deploy** — code is adapter-agnostic and tested on SQLite; switching is
   config only (see `docs/SYNC_SERVER.md`). No Postgres available in the build env.
5. **Writeback hardening** (atomic saves; FUSE-T defers `release`), real OAuth
   (placeholder device-token bootstrap today), N+1 preloading in `Sync::Changes`,
   chunk encryption, retention/GC policy job.

## Decisions locked tonight (from your answers)

Tenant = user; full tree on every device; file-sync only; one protocol for managed
(Postgres + R2) and self-host (SQLite + their S3); last-writer-wins (conflict-copies
deferred). Server DB = Postgres for managed, SQLite for self-host — same code, adapter
per deployment (validated against the 37signals multi-tenancy writeup).
