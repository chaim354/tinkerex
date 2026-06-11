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
| **fs-fuse** | `client/fs-fuse` | FUSE adapter (one impl: Linux libfuse / macOS FUSE-T; Windows winfsp-rs later). |
| **sync-client** | `client/sync-client` | Typed server API client + chunk transfer (presigned PUT/GET) + pull-apply (`LocalTree`). |
| **sync-engine** | `client/sync-engine` | The daemon: `push`/`pull`/`hydrate`/`sync_once`. Pluggable `ChunkIO` (shared-dir for tests, presigned for R2/SeaweedFS). |
| **server** | repo root (Rails 8) | Source of truth: models, `Sync::*` services, v1 API, ActionCable. |
| maker-app-core, juicefs-backend | `client/…` | Earlier Tauri mount-controller + JuiceFS WebDAV backend (from the abandoned path; kept for reference). |

**Verified end-to-end:** device A creates a file → daemon pushes (chunks to a cloud
store) → device B pulls + hydrates + reads, **byte-for-byte identical**; metadata via
the live server changelog. Multi-device convergence demonstrated. ~40 tests green.

---

## 4. Tech stack (decided)

| Layer | Choice |
|---|---|
| Backend | **Rails 8** (Solid Queue/Cache/Cable) |
| Server DB | **Postgres** (managed) / **SQLite** (self-host) — same adapter-agnostic models |
| Object storage | **S3-compatible** — R2 (managed), SeaweedFS/MinIO/their S3 (self-host) |
| Chunking | **FastCDC** (`fastcdc-rs`, MIT) — content-defined, deduped |
| Client | **Tauri** (Rust core), `fs-provider` + `fs-fuse` + `sync-engine` |
| Mount | FUSE (Linux/macOS FUSE-T) now; CfAPI/File Provider later. Driver user-installed (keeps copyleft drivers out of our binaries). |
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
- v1: **last-writer-wins** (conflict-copies deferred). Tenant = user, full tree on
  every device.

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
- **Client holds only a device token.** No storage credentials — it gets short-lived,
  per-object **presigned URLs**. Chunks under `chunks/<user>/`.
- **Bytes never flow through Rails.** Rails is the control plane + presigned-URL
  minter only.
- Auth today is a **placeholder device-token bootstrap**; real OAuth/OIDC is a later
  workstream. (If multi-user/db-per-tenant is wanted later, the 37signals
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
/                Rails 8 sync server (app/, config/, db/) + docs/
/client          Rust crates: fs-provider, fs-fuse, sync-client, sync-engine,
                 (+ maker-app, maker-app-core, juicefs-backend from the prior path)
/docs            architecture-sync-engine.md, sync-protocol.md, SYNC_SERVER.md,
                 STATUS.md, adr/
```

---

## 11. Status (see `docs/STATUS.md` for detail)

**Built + verified (≈40 tests green + 3 live cross-stack demos):**
- Server (Rails): full v1 API, `Sync::*` services, ActionCable. 10 tests.
- `fs-provider`: local SQLite tree + FastCDC chunks + `export_tree`/`apply_remote`. 8 tests.
- `fs-fuse`: FUSE mount (Linux/macOS-FUSE-T), verified live in Finder.
- `sync-client`: API + chunk transfer + pull-apply. 5 tests.
- `sync-engine`: `push`/`pull_snapshot`/`pull_changes`/`hydrate`/`sync_once` **plus the
  daemon loop primitives** `push_outbox`/`sync_tick` + `EngineHydrator`.
- **End-to-end daemon roundtrip with real bytes**: A creates a file → push → B pull +
  hydrate + read, byte-for-byte identical (`client/sync-engine/examples/roundtrip.rs`).
- **The continuous sync loop is wired** (§12 step 1): a local write enqueues an
  `outbox` in `fs-provider`'s SQLite (incremental, not whole-tree); `sync_tick` drains it
  (push) then pulls the changelog delta; a FUSE read on a chunk-cache miss hydrates +
  retries (`fs-fuse::Hydrate` → `EngineHydrator`). Driven end-to-end vs the live server
  in `client/sync-engine/examples/daemon_loop.rs`. The `maker-syncd` binary mounts FUSE +
  runs the loop in a background thread sharing one `Arc<SqliteProvider>`.
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
   - **`maker-syncd` binary** mounts FUSE + runs `sync_tick` in a background thread,
     sharing one `Arc<SqliteProvider>` (new `impl Provider for Arc<P>`). Compiles +
     supervises the thread cleanly; the live kernel-mount leg needs an **interactive**
     session (FUSE-T doesn't hold a mount from a detached process — same as
     `maker-mount`, verify manually in Finder).
   - **Remaining for this step:** the **ActionCable `LibraryChannel` nudge** (the server
     already broadcasts `{head_seq}`) to cut pull latency — today pull is a cursor-delta
     **poll** every 2 s, which is the correctness backbone every production client relies
     on (Dropbox long-poll / OneDrive delta-token / Nextcloud `notify_push`); the nudge
     is a latency optimization on top. And the Tauri-app supervision wrapper.
2. ~~**Live SeaweedFS/R2 round-trip.**~~ **DONE** (2026-06-11). Real bytes through
   presigned PUT/GET to SeaweedFS (`192.168.1.7:8333`, bucket `my-bucket`), byte-for-byte
   on a fresh device — `examples/presigned_roundtrip.rs` with the `STORAGE_BACKEND=s3`
   server (§13). Presign worked first try (no path-style/SigV4 surprises).
3. **`delete`/`move` apply on pull** — `sync-engine::change_to_sync` currently skips
   `delete`; add a `fs-provider` tombstone/move apply so removals propagate.
4. **Windows `winfsp-rs` mount adapter** (Linux/macOS already work via `fuser`).
5. **Real OAuth/OIDC** replacing the placeholder device-token bootstrap
   (`V1::AuthController#register`). The device-token mechanism itself stays.
6. **Writeback + robustness hardening:** atomic saves (write-temp-then-rename),
   FUSE-T's *deferred `release`* (flush-on-close isn't synchronous), reconnect/offline
   reconcile + the changelog-pruned → full-resync backstop, `Sync::Changes` N+1
   preloading.
7. **Postgres deploy validation** (code is adapter-agnostic, tested on SQLite; switch
   is config — see `docs/SYNC_SERVER.md`).
8. **The maker app layer** on top (projects/inventory/BOM/preview) — a *separate* Rails
   concern from file sync; references files by `node_id`.

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
(cd client/fs-provider && cargo test)   # + sync-client, maker-app-core, juicefs-backend

# fs-fuse on macOS needs FUSE-T + a pkg-config alias + rpath — see client/fs-fuse/BUILD.md.
# Mount it:  ./target/debug/maker-mount ~/MakerDrive /tmp/maker.db /tmp/maker-chunks
```

**Env gotchas in this build box (may differ on yours):** no local Postgres/libpq (dev
& test run on SQLite); FUSE-T is installed but `fuser` needs an `osxfuse`→`fuse-t`
pkg-config alias (`client/fs-fuse/BUILD.md`); macOS keeps creating `" 2"`-suffixed
duplicate files in the repo (some sync client?) — they broke a build once; `find . -name
'* 2.*' -delete` to sweep.

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
