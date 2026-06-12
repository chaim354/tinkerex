# Build status — sync engine

**Updated:** 2026-06-11 (comprehensive sync-foundation test suite — ~90 tests across 4 tiers)

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
