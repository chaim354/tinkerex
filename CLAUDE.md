# CLAUDE.md

Project context and architecture for an AI coding agent (Claude Code) and human
developers. Working name: **Maker Server** (rename freely).

> **Architecture note (2026-06):** the file layer is a **local-first sync engine**
> (Dropbox/Google-Drive-shaped), *not* a remote-mounted drive. An earlier
> rclone/JuiceFS **mount** approach was prototyped and abandoned — a synchronous
> remote filesystem is too slow over the WAN (~1 s/file; see Phase 0 in
> `docs/STATUS.md`). The detailed, current design lives in `docs/`:
> `architecture-sync-engine.md`, `sync-protocol.md`, `SYNC_SERVER.md`, `STATUS.md`.

---

## 1. What we're building

A self-hostable server + client for managing a maker's working life:

- **Files** — 3D files (STL, 3MF, OBJ), CAD (STEP/IGES, native Fusion/FreeCAD/
  SolidWorks), LightBurn (`.lbrn2`), with versioning and in-browser preview.
- **Inventory** — materials/components on hand, quantities, locations, suppliers.
- **Projects** — hardware + firmware + software, with tasks, a build log, attached
  files, and a BOM that links to inventory.

Two deployment modes:
1. **Self-hosted** — runs on the user's own box (e.g. Unraid).
2. **Managed (SaaS)** — we host it; we monetize hosting.

Commercial product. **Licensing: prefer permissive (MIT/Apache/BSD) for full
commercial rights** — avoid copyleft (GPL/AGPL) in anything we depend on or ship
(see §9). Everything built so far is permissive.

---

## 2. Core architecture — local-first sync engine

The pattern every production system uses (Dropbox, Google Drive, OneDrive):

> **Local metadata + asynchronous sync + on-demand byte hydration.**

- Each device backs its filesystem with a **local SQLite tree** → `stat`/`readdir`/
  `open` are instant; **the WAN is never in the metadata path.**
- The **Rails server** is the source of truth: tree + immutable versions + a per-user
  **changelog**. Devices stay consistent by pulling entries where `seq > cursor`.
- Files are split into **content-defined chunks (FastCDC)**, content-addressed and
  deduped. **Chunk bytes move client ⇄ object storage directly via presigned URLs —
  never through Rails.**
- The filesystem surface is a **native mount**: FUSE today (Linux + macOS via
  FUSE-T), Windows CfAPI / macOS File Provider as later polish.

This is a **sync engine, not a mount**. Versioning + dedup are native (a version = a
content-addressed manifest sharing chunks).

---

## 3. Components (what's built)

| Component | Path | Role |
|---|---|---|
| **fs-provider** | `client/fs-provider` | Local SQLite tree + content-addressed FastCDC chunk store. `export_tree`/`apply_remote` for sync. |
| **fs-fuse** | `client/fs-fuse` | FUSE adapter (**Linux** mount path) over `Provider`. Verified live. (macOS uses `fs-webdav` — FUSE-T can't mount on macOS 26.) |
| **fs-winfsp** | `client/fs-winfsp` | WinFsp adapter (**Windows** mount path) over the **same** `Provider`. **Verified: mounts a drive letter + syncs** via the app. Needs `winfsp-x64.dll` on PATH at runtime (or bundled). |
| **fs-cfapi** | `client/fs-cfapi` | **CfAPI** adapter — the **driverless** Windows path (Cloud Filter API, no GPL driver; the OneDrive model: sync-root folder + on-demand hydration). **Verified live on Windows 11**: register + on-demand enumerate (FETCH_PLACEHOLDERS) + hydrate-on-open (FETCH_DATA). Successor to `fs-winfsp` (kept as fallback). Phase 2 = local-edit capture. |
| **fs-webdav** | `client/fs-webdav` | WebDAV adapter (`dav-server`) over the **same** `Provider` — the **macOS** mount path (native `mount_webdav`, no FUSE/kext/FSKit). Cross-platform; verified live on macOS 26. |
| **sync-client** | `client/sync-client` | Typed server API client + chunk transfer (presigned PUT/GET) + pull-apply (`LocalTree`). |
| **sync-engine** | `client/sync-engine` | The daemon: `push`/`pull`/`hydrate`/`sync_once`. Pluggable `ChunkIO` (shared-dir for tests, presigned for R2/SeaweedFS). |
| **server** | repo root (Rails 8) | Source of truth: models, `Sync::*` services, v1 API, ActionCable. |
| maker-app-core, juicefs-backend | `client/…` | Earlier Tauri mount-controller + JuiceFS WebDAV backend (from the abandoned path; kept for reference). |

**Verified end-to-end:** device A creates a file → daemon pushes (chunks to a cloud
store) → device B pulls + hydrates + reads, **byte-for-byte identical**; metadata via
the live server changelog. Multi-device convergence demonstrated. ~90 tests green
(hermetic provider/chunking/convergence/concurrency suites + server-backed engine
integration + Rails service/isolation tests).

---

## 4. Tech stack (decided)

| Layer | Choice |
|---|---|
| Backend | **Rails 8** (Solid Queue/Cache/Cable) |
| Server DB | **Postgres** (managed) / **SQLite** (self-host) — same adapter-agnostic models |
| Object storage | **S3-compatible** — R2 (managed), SeaweedFS/MinIO/their S3 (self-host) |
| Chunking | **FastCDC** (`fastcdc-rs`, MIT) — content-defined, deduped |
| Client | **Tauri** (Rust core), `fs-provider` + per-OS mount (`fs-fuse`/`fs-winfsp`/`fs-webdav`) + `sync-engine` |
| Mount | Per-OS, all live: **Linux** FUSE (`fuser`), **Windows** WinFsp, **macOS** WebDAV (native `mount_webdav`, no kext). CfAPI / macOS File Provider are later native polish. Drivers user-installed (keeps copyleft drivers out of our binaries). |
| Change notification | **ActionCable** → `{head_seq}` on commit |
| Preview (later) | Three.js (browser) + FreeCAD/CadQuery (server jobs) |

---

## 5. Data model

**Server (authoritative, Postgres/SQLite):** `users(head_seq)`, `devices`,
`nodes(node_id, parent, name, kind, current_version, deleted)`, `versions(parent
chain)`, `manifest_chunks`, `chunks(refcount)`, `changelog_entries(seq)`,
`pending_commits`. Stable cross-device ids are string UUIDs.

**Client (local SQLite mirror):** the tree (`fs-provider`'s `nodes`/`manifest_chunks`,
each node carrying its server `node_id`), a local content-addressed chunk cache, and
sync state (cursor + outbox — outbox/cursor wiring is the remaining daemon piece).

Versioning is native: every commit is an immutable version → manifest; chunks are
refcounted and shared. **Keep versions** (don't prune) so restore always works; GC
only sweeps refcount-0 chunks.

---

## 6. Sync protocol (see `docs/sync-protocol.md`)

Three channels: **HTTPS API** (control), **ActionCable** (the "pull" nudge), **direct
to storage** (chunk bytes via presigned URLs).

- **Push:** `export_tree` → for each file `commit`(begin → upload missing chunks →
  finalize); dirs via `mkdir`. Server appends one changelog entry, bumps `head_seq`,
  broadcasts.
- **Pull:** changelog delta since cursor → `apply_remote` into local SQLite →
  dehydrate changed placeholders.
- **Hydrate:** on read, fetch missing chunks via presigned GET → local cache.
- **Conflict detection** (replaced v1 last-writer-wins, 2026-06-12): each commit sends its
  `base_version_id`; if it's no longer current (a concurrent/offline edit slipped in), the
  server records a **conflict** (both versions kept) instead of silently dropping an edit,
  and the client prompts the user to keep one or split into two files (`Sync::Conflicts`,
  `GET /v1/conflicts`, `POST /v1/nodes/:id/resolve_conflict`). A base that IS current is a
  clean fast-forward. Tenant = user, full tree on every device.

---

## 7. Deployment (one protocol, two hosts)

| | Managed | Self-host |
|---|---|---|
| Rails | cloud | user's box |
| DB | Postgres (Neon/RDS) | SQLite |
| Storage | R2 | their S3 (SeaweedFS/MinIO) |
| Tenancy | `user_id` scoping | single user |

Same models, same API, same client — only the hosts/creds differ. Switching DB is
config-only (the code is adapter-agnostic; tested on SQLite). To use S3 storage set
`STORAGE_BACKEND=s3` + `CHUNK_*` env (see `docs/SYNC_SERVER.md`).

---

## 8. Multi-tenancy & security

- **Tenant = user** (one library, the user's own devices). Isolation = ordinary
  Rails `user_id` scoping — *not* the JuiceFS no-ACL problem (that's why the sync
  model is simpler than the mount model).
- **Client holds only a device token** (256-bit, SHA256-digested at rest). No storage
  credentials — it gets short-lived, per-object **presigned URLs**, SigV4-signed for a
  per-user key `chunks/<user>/<hash>` (untamperable → cross-user chunk access impossible;
  storage + dedup are per-user). `/v1/chunks/download` additionally only mints URLs for
  chunks the requester owns.
- **Bytes never flow through Rails.** Rails is the control plane + presigned-URL
  minter only.
- **Registration creates a new account only** (no `find_or_create_by` takeover); a new
  device joins an existing library via a **single-use, expiring pairing code** issued by
  an authenticated device (`DevicePairing`, `POST /v1/devices/pairing` → `/v1/auth/pair`;
  Syncthing/Plex model). Real OAuth/OIDC (email verification) is the later upgrade; the
  device-token + pairing mechanism downstream stays. (If multi-user/db-per-tenant is
  wanted later, the 37signals
  `active_record_tenanted` pattern slots over the same models.)

---

## 9. Licensing (don't relitigate)

- **Prefer permissive: MIT / Apache-2.0 / BSD.** Everything we use/ship is permissive
  (Rails MIT, FastCDC MIT, SQLite PD, our crates Apache).
- **Avoid GPL/AGPL** in dependencies and shipped artifacts. FUSE drivers (WinFsp GPL,
  macFUSE) are **user-installed**, never bundled — so no copyleft in our binaries; on
  Windows prefer native **CfAPI** (no driver). SeaweedFS (Apache) is the self-host S3
  backend (not MinIO, which is AGPL).

---

## 10. Repo layout

```
/                Rails 8 sync server (app/, config/, db/) + docs/ (incl. DEPLOY.md)
/client          Rust crates: fs-provider, fs-fuse (Linux), fs-winfsp (Windows),
                 fs-webdav (macOS), sync-client, sync-engine, maker-app (Tauri)
                 (+ maker-app-core, juicefs-backend from the prior path)
/docs            architecture-sync-engine.md, sync-protocol.md, SYNC_SERVER.md,
                 STATUS.md, DEPLOY.md, adr/
```

---

## 11. Status (see `docs/STATUS.md` for detail)

> **Headline (2026-06-11):** the full stack runs **on real hardware**. The Rails server
> is **deployed via Kamal** on an Unraid VM (`192.168.1.95`, SeaweedFS chunk storage —
> `docs/DEPLOY.md`), and the client **mounts + syncs against it on all three OSes**, each
> via its native filesystem layer over the *same* `Provider` + sync loop + nudge:
> **macOS = WebDAV** (`fs-webdav`, native `mount_webdav`), **Linux = FUSE** (`fs-fuse`),
> **Windows = WinFsp** (`fs-winfsp`, drive letter) — all verified live (a file written
> through the mount → pushed to the deployed server → content-addressed chunk in
> SeaweedFS, hash-matched on read-back). The Tauri app (`client/maker-app`) picks the
> backend per-OS via a `Mount` type alias; commands are identical everywhere.

> **Branch `auth-caching-security` (2026-06-12, all CI green):** a large hardening arc on
> top of the deployed stack — device **pairing** auth + cross-user security audit;
> client **caching/freshness** (mtime + full-hydrate-on-write + freshness-on-open);
> **file browser + version/restore UI**; local + **best-effort cross-device file locking**;
> **conflict detection + keep/split resolution** (replacing silent LWW); **file-mode
> (executable-bit) preservation**; and **real-mtime preservation + active cache invalidation**
> (Option B — real mtime synced in unix-nanos end-to-end; explicit FUSE `notify_inval_inode`
> replacing the `mtime = now`-on-pull bump). External conformance (rclone/fsx/pjdfstest) re-run:
> data plane byte-perfect, POSIX-perms gaps deliberate (rclone⇄WebDAV caught + fixed a
> nanos-overflow in the WebDAV/WinFsp adapters). Next up: real **OAuth/OIDC** email
> verification (§12 step 5) + Postgres deploy validation (step 8).

**Built + verified (~125 tests green + live cross-stack + cross-OS demos):**
- Server (Rails): full v1 API, `Sync::*` services, ActionCable. **53 tests** (commit/
  refcounts/dedup + GC prune/sweep + changelog prune, restore chains, tree + changelog
  pagination / `oldest_seq` backstop, tenant isolation, **auth: register hardening +
  device pairing**, **conflict detect/keep/split**, **best-effort edit locks**, **file-mode
  sync**).
- `fs-provider`: local SQLite tree + FastCDC chunks + `export_tree`/`apply_remote`/`apply_remote_delete`/`truncate`. **53 tests** across hermetic suites (`tests/`): **caching** (mtime-freshness + random-write-on-hydrated), **chunking**
  (round-trip / dedup / block-delta boundary stability / pathological inputs, proptest),
  **posix_semantics** (rename-over replace, dup/missing, unicode/deep nesting),
  **convergence** (3-replica FakeFolder-style random op stream + durability + idempotency),
  **concurrency** (shared `Arc` threads + chunk-store race). Modeled on rclone-fstests /
  restic-chunker / ownCloud-FakeFolder / JuiceFS-pjdfstest.
- `fs-fuse`: FUSE mount (Linux/macOS-FUSE-T), verified live in Finder. Now also persists +
  syncs file **mode** (chmod/executable bit), local advisory **locks** (`setlk`/`getlk`),
  **freshness**-on-open, and best-effort **remote-lock** acquire/release.
- `sync-client`: typed API + chunk transfer + pull-apply, plus pairing/conflict/lock/
  versions methods. 5 tests.
- `sync-engine`: `push`/`pull_snapshot`/`pull_changes`/`hydrate`/`sync_once` **plus the
  daemon loop primitives** `push_outbox`/`sync_tick` + `EngineHydrator`/`EngineFreshness`/
  `EngineRemoteLock`. **Server-backed integration suite** (`tests/integration.rs`,
  **14 tests**: roundtrip, delete/move delta, hydrate (only-missing/after-conflict), push
  dedup, cursor monotonicity, changelog paging, offline reconcile, **freshness-on-access**,
  **pairing**, **offline-edit conflict + split**, **best-effort lock coordination**,
  **executable-bit propagation**) — skips with no server; CI boots `STORAGE_BACKEND=memory`
  Rails (`rust-client.yml`).
- **External conformance** (`client/test-conformance/`): rclone⇄WebDAV (gating, 0 diffs),
  fsx⇄FUSE (gating, 100k ops no mismatch), pjdfstest⇄FUSE (informational POSIX map). New CI
  `mount-conformance` job.
- **Two foundation bugs the suite caught + fixed:** (1) `rename` over an existing name hit
  the unique index instead of POSIX-replacing → **atomic saves (write-temp-then-rename)
  were broken**; now replaces + tombstones the displaced node. (2) `truncate(ino, 0)` read
  the base content first → **`O_TRUNC` overwrite of a pulled-but-unhydrated placeholder
  failed**; now short-circuits to empty (no hydration needed).
- **End-to-end daemon roundtrip with real bytes**: A creates a file → push → B pull +
  hydrate + read, byte-for-byte identical (`client/sync-engine/examples/roundtrip.rs`).
- **The continuous sync loop is wired** (§12 step 1): a local write enqueues an
  `outbox` in `fs-provider`'s SQLite (incremental, not whole-tree); `sync_tick` drains it
  (push) then pulls the changelog delta; a FUSE read on a chunk-cache miss hydrates +
  retries (`fs-fuse::Hydrate` → `EngineHydrator`). Driven end-to-end vs the live server
  in `client/sync-engine/examples/daemon_loop.rs`. The `maker-syncd` binary mounts FUSE +
  runs the loop in a background thread sharing one `Arc<SqliteProvider>`.
- **The ActionCable nudge is wired** (§12 step 1): `ServerClient::watch_library`
  subscribes to `LibraryChannel`; each `{head_seq}` broadcast wakes the sync loop
  instantly (~39 ms vs the 2 s poll fallback). Verified in
  `client/sync-client/examples/nudge.rs`.
- **Live SeaweedFS round-trip DONE** (§12 step 2): real bytes through presigned PUT/GET
  to `192.168.1.7:8333`, verified byte-for-byte on a fresh device
  (`client/sync-engine/examples/presigned_roundtrip.rs`). No longer "URLs only".

---

## 12. Next steps — the plan (do roughly in order)

1. ~~**Wire the continuous daemon loop into the client.**~~ **DONE** (2026-06-11). The
   loop primitives are built and proven end-to-end vs the live server
   (`examples/daemon_loop.rs`):
   - **Watch → push:** ✅ FUSE `flush`/`mkdir`/`unlink`/`rmdir`/`rename` enqueue the
     node into `fs-provider`'s `outbox` table (atomic with the tree change);
     `SyncEngine::push_outbox` drains it incrementally (commit → upload missing →
     finalize), never holding the SQLite lock across WAN I/O. `sync_cursor` lives in a
     `sync_state` table.
   - **Read → hydrate:** ✅ `fs-fuse::Hydrate` hook — a `read` on a `ChunkMissing` calls
     `EngineHydrator::hydrate` (presigned GET) then retries. Doubles as
     placeholder-dehydration after a pull (new manifest → cache miss → hydrate).
   - **Nudge → pull:** ✅ `ServerClient::watch_library` subscribes to the ActionCable
     `LibraryChannel` (`ws://…/cable?token=<device>`); each `{head_seq}` broadcast wakes
     the sync loop instantly (verified **~39 ms** vs the 2 s poll —
     `client/sync-client/examples/nudge.rs`). The loop waits on a `recv_timeout(poll)`,
     so the nudge is the fast path and the cursor-delta poll is the correctness fallback
     (the backbone every prod client relies on — Dropbox long-poll / OneDrive
     delta-token / Nextcloud `notify_push`). Required disabling ActionCable
     request-forgery protection (browser-CSRF defense; irrelevant to our token-authed,
     cookieless cable connection).
   - **Supervised daemon:** ✅ `sync_engine::Daemon` (`src/daemon.rs`) wraps it all —
     `start()` mounts via `spawn_mount2` (non-blocking; FUSE session on its own thread)
     + spawns the sync & nudge threads sharing one `Arc<SqliteProvider>` (new
     `impl Provider for Arc<P>`); `stop()`/`Drop` unmount + join; `is_running()` for
     status. `maker-syncd` is a thin CLI wrapper (`run_until_unmounted`).
   - **Tauri app:** ✅ `client/maker-app` drives the `Daemon` via `sync_start`/
     `sync_stop`/`sync_status` commands (register device → mount → sync) with a mount
     form. The native-mount dep is `cfg(not(windows))`-gated: the app builds + launches
     on Windows but the mount returns a "needs winfsp-rs (§12 step 4)" message. **Run it:
     `client/maker-app/SETUP.md`.**
   - **Step 1 is functionally complete.** Caveat: the live kernel-mount leg needs an
     **interactive** session (FUSE-T won't hold a mount from a detached/headless process
     — same as `maker-mount`; verify in Finder via the app).
2. ~~**Live SeaweedFS/R2 round-trip.**~~ **DONE** (2026-06-11). Real bytes through
   presigned PUT/GET to SeaweedFS (`192.168.1.7:8333`, bucket `my-bucket`), byte-for-byte
   on a fresh device — `examples/presigned_roundtrip.rs` with the `STORAGE_BACKEND=s3`
   server (§13). Presign worked first try (no path-style/SigV4 surprises).
3. ~~**`delete`/`move` apply on pull**~~ **DONE** (2026-06-11). `pull_changes` now
   applies deletes via `fs_provider::apply_remote_delete` (recursive subtree sweep, so a
   dir delete can't orphan children; idempotent; never re-enqueues to the outbox). Moves
   were already correct — the server models a move as op `move`/`put` on the **same**
   stable `node_id` with a new parent/name, so `apply_remote` updates the row in place
   (no delete, no duplicate). Verified end-to-end vs the live server in
   `client/sync-engine/examples/delete_move.rs` (B converges on A's delete + move via a
   delta pull). Backed by a `fs-provider` **convergence harness**
   (`convergence_under_random_ops`) that drives a pseudo-random create/overwrite/delete/
   move stream and asserts the source and replica trees stay identical after every op —
   the mechanical backstop that catches dropped-delete / duplicated-move regressions.
4. ~~**Windows `winfsp-rs` mount adapter.**~~ **DONE.** `client/fs-winfsp` implements
   WinFsp's `FileSystemContext` over the same `Provider` (path↔inode + hydrate hook),
   wired into `sync_engine::WinfspMount` and the Tauri app (per-OS `Mount` alias). Built
   + verified live on a real Windows box: a drive letter mounts and **syncs to the
   deployed server**. Remaining polish: **runtime needs `winfsp-x64.dll` on PATH** (the
   `winfsp` `system` feature would load it from the registry InstallDir but requires the
   WinFsp SDK headers to build — a runtime-only WinFsp install lacks them; for a
   distributable `.exe`, bundle the DLL next to it). Build/run: `client/fs-winfsp/BUILD.md`,
   `client/maker-app/SETUP.md`. ~~Shared gap (all adapters): `Provider` has no truncate
   (overwrite-with-shorter leaves a stale tail).~~ **CLOSED** (2026-06-11): `Provider`
   now has `truncate(ino, size)` — shrink drops chunks past the new EOF, grow zero-fills.
   The kernel's `O_TRUNC` reaches it via **FUSE `setattr(size)`**, **WinFsp
   `set_file_size`**, and a **truncating WebDAV PUT open** (`options.truncate`), so an
   overwrite-with-shorter leaves no stale tail on any of the three OSes. Covered by
   `overwrite_with_shorter_leaves_no_stale_tail` + a grow/shrink test, and the
   `convergence_under_random_ops` harness now overwrites via truncate-then-write and
   asserts the source has no stale tail (replica content convergence is proven by the
   content-addressed `manifest_id`).
   **CfAPI migration UNDERWAY** (2026-06-12): `client/fs-cfapi` — the **driverless** Windows
   path (Cloud Filter API; no GPL driver — §9). **Phase 1** (populate placeholders + hydrate
   on FETCH_DATA + invalidate via `CfUpdatePlaceholder`) authored over the same `Provider`,
   wired as `sync_engine::CfApiMount` + `maker-cfsyncd` (WinFsp kept as the default fallback).
   Reuses the Option-B seams: the `Invalidate` trait → `CfUpdatePlaceholder`+dehydrate, real
   nanos mtime → `FILETIME`. Pure logic unit-tested cross-platform; FFI compiled by the
   `cfapi-windows` CI job; runtime-UNVERIFIED (smoke: `client/fs-cfapi/BUILD.md`). **Phase 2**
   (local-edit→upload capture via a USN watcher → `Provider::ingest_bytes` → push) is next.
   Plan: `docs/plan-windows-cfapi-migration.md`.
5. ~~**Real OAuth/OIDC** replacing the placeholder device-token bootstrap~~ **PARTLY DONE**
   (2026-06-12): the account-takeover hole is closed — `register` is new-account-only and
   additional devices join via a **single-use pairing code** (`DevicePairing`); the app
   persists its token instead of re-registering. Cross-user isolation audited + tested
   (presigned URLs are per-user SigV4 keys; chunk-download is ownership-gated). Remaining:
   real **OAuth/OIDC email verification** so the bootstrap proves email ownership (the
   device-token + pairing mechanism stays underneath).
6. **Writeback + robustness hardening:** ~~atomic saves (write-temp-then-rename)~~ **DONE**
   (`Provider::rename` POSIX-replaces + tombstones the displaced node; `truncate(0)` no
   longer needs hydration). ~~reconnect/offline reconcile + the changelog-pruned →
   full-resync backstop~~ **DONE** (2026-06-11): `pull_changes` now **pages** the delta
   (was a single call that dropped every entry past page 1 on a far-behind device — a
   silent data-loss bug) and **full-resyncs** when its cursor is below the server's
   reported `oldest_seq` (pruned-gap detection; `Sync::Gc.prune_changelog!` is the
   retention op). Still open: FUSE-T's *deferred `release`* (flush-on-close isn't
   synchronous), `Sync::Changes` N+1 preloading. **Concurrency: conflict detection** (each
   commit sends `base_version_id`; stale base → recorded conflict + keep/split resolution,
   replacing silent LWW — §6) and **best-effort cross-device + local file locking** are
   **DONE** (2026-06-12).
7. **Caching/freshness DONE** (2026-06-12): full-hydrate on write-open (random writes can't
   miss), freshness-on-open catch-up pull, and **file-mode (executable-bit) preservation**
   synced end-to-end. ~~real-mtime preservation + active cache invalidation~~ **DONE**
   (2026-06-12, Option B): replaced the `mtime = now`-on-pull hack (which destroyed build-tool
   mtimes) with **real mtime synced end-to-end in unix nanoseconds** (`flush` stamps the real
   local time; `apply_remote` writes the *source* device's mtime verbatim; new `set_mtime` for
   `utimensat`/`cp -p`; server columns are **bigint**) **plus an explicit `invalidate(ino)`
   seam** — `apply_remote` returns `content_changed`, and on FUSE `sync_engine::EngineInvalidate`
   calls the kernel `notify_inval_inode` (abi-7-12) via the session `Notifier` (shared by the
   sync loop + freshness, wired into the `Daemon` by deferred notifier injection). WebDAV/WinFsp
   pass `None` (lean on metadata timeouts until CfAPI/File-Provider — the same two primitives
   slot in there). Caught + fixed a nanos-overflow regression in the WebDAV + WinFsp adapters
   (interpreted `Attr.mtime` as seconds) via the rclone⇄WebDAV conformance re-run. Plan:
   **`docs/plan-real-mtime-and-invalidation.md`**. (Invalidation itself is FUSE-kernel-only →
   CI `mount-conformance` / manual smoke, per the plan.)
8. **Postgres deploy validation** (code is adapter-agnostic, tested on SQLite; switch
   is config — see `docs/SYNC_SERVER.md`).
9. **The maker app layer** on top (projects/inventory/BOM/preview) — a *separate* Rails
   concern from file sync; references files by `node_id`. Groundwork landed: the Tauri app
   has a **file browser + version-history/restore UI + conflict-resolution popup + lock
   indicators** (`client/maker-app`).

---

## 13. Build & run cheatsheet (for a fresh context)

```sh
# Server tests (SQLite; proves adapter-agnosticism)
bin/rails test

# Boot the server for the live demos (memory chunk store = control-plane only)
STORAGE_BACKEND=memory bin/rails server -p 3001

# Live cross-stack demos (server must be running):
(cd client/sync-client && SERVER_URL=http://localhost:3001 cargo run --example e2e)
(cd client/sync-client && SERVER_URL=http://localhost:3001 cargo run --example multi_device)
(cd client/sync-engine && SERVER_URL=http://localhost:3001 cargo run --example roundtrip)      # real bytes
(cd client/sync-engine && SERVER_URL=http://localhost:3001 cargo run --example daemon_loop)     # the loop: outbox→push→pull→hydrate
(cd client/sync-client && SERVER_URL=http://localhost:3001 cargo run --example nudge)           # ActionCable {head_seq} push (~39ms)

# Server with real S3/SeaweedFS storage (presigned PUT/GET):
STORAGE_BACKEND=s3 CHUNK_ENDPOINT=http://192.168.1.7:8333 CHUNK_BUCKET=my-bucket \
CHUNK_REGION=us-east-1 CHUNK_ACCESS_KEY_ID=admin CHUNK_SECRET_ACCESS_KEY=secret \
  bin/rails server -p 3001
# …then push/hydrate real bytes through SeaweedFS via presigned URLs:
(cd client/sync-engine && SERVER_URL=http://localhost:3001 cargo run --example presigned_roundtrip)

# The daemon (mount + continuous loop). Needs a device token (register via the API) and
# the FUSE-T pkg-config alias + rpath (sync-engine has its own .cargo/config.toml now):
# PKG_CONFIG_PATH=/tmp/fuse-pc:/usr/local/lib/pkgconfig cargo build --bin maker-syncd
# ./target/debug/maker-syncd <mnt> <db> <chunks> http://localhost:3001 <device_token>

# Rust crate tests
(cd client/fs-provider && cargo test)   # 50: chunking/posix/convergence/concurrency (hermetic)
(cd client/sync-client && cargo test)   # 5
# sync-engine integration needs a running server (skips cleanly without one):
STORAGE_BACKEND=memory bin/rails server -p 3001 &   # then:
(cd client/sync-engine && SYNC_IT_SERVER_URL=http://localhost:3001 cargo test --test integration)

# External conformance (battle-tested tools vs our real mounts — client/test-conformance/):
client/test-conformance/webdav-rclone.sh      # rclone ⇄ WebDAV round-trip (macOS+Linux)
client/test-conformance/fsx-fuse.sh           # fsx data-integrity exerciser ⇄ FUSE (Linux)
client/test-conformance/pjdfstest-fuse.sh     # pjdfstest POSIX map ⇄ FUSE (Linux, informational)

# fs-fuse on macOS needs FUSE-T + a pkg-config alias + rpath — see client/fs-fuse/BUILD.md.
# Mount it:  ./target/debug/maker-mount ~/MakerDrive /tmp/maker.db /tmp/maker-chunks
```

**Env gotchas in this build box (may differ on yours):** no local Postgres/libpq (dev
& test run on SQLite); FUSE-T is installed but `fuser` needs an `osxfuse`→`fuse-t`
pkg-config alias (`client/fs-fuse/BUILD.md`); macOS keeps creating `" 2"`-suffixed
duplicate files in the repo (some sync client?) — they broke a build once; `find . -name
'* 2.*' -delete` to sweep.

**Mount: per-OS backend, gated cleanly in `sync-engine` (`Mount` alias in the Tauri
app).** Each platform uses its native layer over the same `Provider`; the deps are
strictly target-gated so each OS compiles only its own:
- **macOS → WebDAV** (`fs-webdav`, native `mount_webdav`). FUSE-T's **FSKit** build can't
  mount on macOS 26 (silent fail; the System-Settings extension toggle is greyed), so
  macOS uses WebDAV instead. `fuser` is **`cfg(target_os = "linux")`**, so macOS builds
  with **zero FUSE** — no FUSE-T, no pkg-config alias, nothing fuse-linked.
- **Linux → FUSE** (`fs-fuse`/`fuser`). `auto_unmount` needs `user_allow_other` in
  `/etc/fuse.conf` + `/dev/fuse` access (`SETUP.md`).
- **Windows → WinFsp** (`fs-winfsp`, drive letter like `Z:`). Build needs LLVM/libclang
  (winfsp-sys bindgen) + WinFsp; **runtime needs `winfsp-x64.dll` on PATH** (set PATH to
  `<WinFsp>\bin`, or bundle the DLL). Mount point is a **drive letter**, not a path.

Verified live on all three: a file written through the mount → sync push → deployed
Rails on the Unraid VM → content-addressed chunk in SeaweedFS, hash-matched on read-back
(`examples/webdav_live.rs` for macOS; the Tauri app on Linux + Windows).

---

## 14. Hard-won learnings (don't relitigate)

- **A remote-mounted filesystem does NOT work over the WAN.** rclone/JuiceFS mount =
  synchronous metadata round-trips → ~1 s/file (Phase 0, measured). Every production
  system (Dropbox/Google/OneDrive) uses **local metadata + async sync + on-demand
  hydration**. That pivot is the whole reason this architecture exists. Do not go back
  to a remote mount.
- **JuiceFS was abandoned** for this use case: chatty metadata over the WAN (slow), no
  internal ACL (multi-tenancy needs a gateway/volume-per-tenant), and FUSE-driver
  licensing. The `client/juicefs-backend` + `maker-app-core` crates are leftovers from
  that path — reference only.
- **Edge-SQLite (Cloudflare D1, Turso) can't back JuiceFS** — no driver + chatty-metadata
  latency. They *would* fit the coarse-manifest model (this one), but we use Rails +
  Postgres/SQLite to stay self-hostable (D1/DO are Cloudflare-locked → break self-host).
- **The sync model makes multi-tenancy SIMPLE** (coarse API + `user_id` scoping) —
  the opposite of the mount model's gateway/credential gymnastics. Tenant = user for v1.
- **Permissive licensing is a hard constraint** (§9). The hard capability (block-delta +
  versioning) is available as permissive libraries: **fastcdc-rs (MIT)**, **desync
  (BSD-3)**, **restic/chunker (BSD-2)** — we build on FastCDC. SeaweedFS (Apache) is the
  self-host S3 backend, not MinIO (AGPL).
- **DB: Postgres managed, SQLite self-host, one adapter-agnostic codebase** — validated
  by 37signals' multi-tenancy writeup (db-per-tenant pattern, engine per deployment).
  No PG-only SQL in the hot path; `next_seq!`'s row lock is correct on both.
- **Server presigning is local** (HMAC) — you can verify chunk URLs are correct without
  the storage being reachable.

---

## 15. Working agreements for the coding agent

- Permissive licenses only (§9); check new deps.
- **Keep bytes out of Rails** — presigned URLs, control plane only.
- **Local-first**: metadata reads hit local SQLite, never the WAN.
- Content-addressed chunks + immutable versions everywhere; **keep versions** for restore.
- Adapter-agnostic server code (SQLite + Postgres) without perf compromise.
- Write tests; verify end-to-end against the live server when wiring sync.
- Update this file **and** `docs/STATUS.md` when the architecture moves.
