# CLAUDE.md

Project context and architecture for an AI coding agent (Claude Code) and human
developers. Working name: **Maker Server** (rename freely).

> **How this file is scoped.** It holds what is *permanently* true: architecture, the
> data model, and the **invariants a future editor must not undo** (§14). It does **not**
> narrate finished work — every arc (dates, branches, suite counts, per-phase detail)
> lives in **`docs/STATUS.md`**, which is the canonical record. Keep it that way: this
> file is loaded into an agent's context on *every* session, so length here is a tax on
> every future task, and a rule buried in 600 lines of history is a rule nobody reads.
>
> **Do not renumber the sections.** Code comments cite them by number
> (`§15` ~141 times, `§9` ~175, `§10` ~107, `§5` ~95 — `grep -rn "§[0-9]" app/ lib/`).

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
- The filesystem surface is a **native mount**, per-OS over the same `Provider`: **Linux**
  FUSE, **Windows** CfAPI (driverless Cloud Filter, the default), **macOS** WebDAV (native
  `mount_webdav`). All three live. (macOS FSKit / Windows File-Provider are future polish.)

This is a **sync engine, not a mount**. Versioning + dedup are native (a version = a
content-addressed manifest sharing chunks).

---

## 3. Components (what's built)

Roles only. The **invariants** for the file layer, the scan, the addons, and project
intake are in **§14** — that is where a "don't undo this" belongs, not in a table cell.

| Component | Path | Role |
|---|---|---|
| **fs-provider** | `client/fs-provider` | Local SQLite tree + content-addressed FastCDC chunk store. `export_tree`/`apply_remote` for sync. Node kinds: File/Dir/**Symlink** (target synced; git-on-mount works — `docs/git-on-mount.md`). |
| **fs-fuse** | `client/fs-fuse` | FUSE adapter — the **Linux** mount path. `fuser` is `cfg(target_os = "linux")`, so macOS builds link **zero FUSE**. |
| **fs-cfapi** | `client/fs-cfapi` | **CfAPI** (Cloud Filter) — the **driverless, DEFAULT Windows** backend, no GPL driver (§9). Sync-root + on-demand hydration, local-edit capture, offline-persistent hydrated files. |
| **fs-winfsp** | `client/fs-winfsp` | WinFsp adapter (drive letter), now behind the `winfsp-backend` cargo feature. Runtime needs `winfsp-x64.dll` on PATH. |
| **fs-webdav** | `client/fs-webdav` | WebDAV adapter (`dav-server`) — the **macOS** mount path via native `mount_webdav`; no FUSE/kext/FSKit. |
| **sync-client** | `client/sync-client` | Typed server API client + chunk transfer (presigned PUT/GET) + pull-apply (`LocalTree`). |
| **sync-engine** | `client/sync-engine` | The daemon: `push`/`pull`/`hydrate`/`sync_once` + the loop primitives. Pluggable `ChunkIO`. |
| **server** | repo root (Rails 8) | Source of truth: models, `Sync::*` services, v1 API, ActionCable. |
| **FileLayer port** | `app/services/file_layer/` | The seam between the **maker layer** and whatever holds the bytes, chosen per deployment by `LIBRARY_BACKEND=chunk\|share\|s3`. All three boot, index, write, deliver. Invariants: **§14a**. |
| **Library scan** | `app/services/library/` | Share/S3 indexing: `Scanner` + `S3Observer` **observe**, one shared `Reconciler` **decides**. Invariants: **§14b**. |
| **Addons (Tools)** | `app/services/maker/addons/`, `app/controllers/tools/`, `sidecar/` | The `/tools` gallery + per-addon UI; output lands via one path (`Maker::Addons::LibraryOutput`). Two GPL sidecars, HTTP-only. Invariants: **§14c**. |
| **Project intake** | `app/services/maker/project_intake.rb` | A project's library folder files itself: everything under `Projects/<slug>/` attaches to the project, whatever is loose at the root gets filed into a category subfolder. Invariants: **§14f**. |
| maker-app-core, juicefs-backend | `client/…` | Leftovers from the abandoned mount path; reference only. |

**Verified end-to-end:** device A creates a file → daemon pushes (chunks to a cloud
store) → device B pulls + hydrates + reads, **byte-for-byte identical**; metadata via
the live server changelog. Multi-device convergence demonstrated. Current per-suite test
counts: `docs/STATUS.md`.

---

## 4. Tech stack (decided)

| Layer | Choice |
|---|---|
| Backend | **Rails 8** (Solid Queue/Cache/Cable — all three wired; see §14e for what that requires) |
| Server DB | **Postgres** (managed) / **SQLite** (self-host) — same adapter-agnostic models |
| Object storage | **S3-compatible** — R2 (managed), SeaweedFS/MinIO/their S3 (self-host) |
| Chunking | **FastCDC** (`fastcdc-rs`, MIT) — content-defined, deduped |
| Client | **Tauri** (Rust core), `fs-provider` + per-OS mount + `sync-engine` |
| Mount | Per-OS, all live: **Linux** FUSE (`fuser`), **Windows** CfAPI (default; WinFsp behind a feature), **macOS** WebDAV. macOS FSKit is a **design sketch, not built** (no `client/fs-fskit` crate on `main`) and would need a paid Apple Developer membership. Drivers user-installed (keeps copyleft out of our binaries). |
| Change notification | **ActionCable** → `{head_seq}` on commit |
| Preview | Server-side thumbnails (vipsthumbnail/pdfium/resvg subprocesses) + Three.js in the browser |

---

## 5. Data model

**Server (authoritative, Postgres/SQLite):** `users(head_seq)`, `devices`,
`nodes(node_id, parent, name, kind, current_version, deleted)`, `versions(parent
chain)`, `manifest_chunks`, `chunks(refcount)`, `changelog_entries(seq)`,
`pending_commits`. Stable cross-device ids are string UUIDs.

**Client (local SQLite mirror):** the tree (`fs-provider`'s `nodes`/`manifest_chunks`,
each node carrying its server `node_id`), a local content-addressed chunk cache, and
sync state (cursor + outbox).

Versioning is native: every commit is an immutable version → manifest; chunks are
refcounted and shared. **Keep versions** (don't prune) so restore always works; GC
only sweeps refcount-0 chunks. (Departure on share/s3: §14a.)

---

## 6. Sync protocol (see `docs/sync-protocol.md`)

Three channels: **HTTPS API** (control), **ActionCable** (the "pull" nudge), **direct
to storage** (chunk bytes via presigned URLs).

- **Push:** `export_tree` → for each file `commit`(begin → upload missing chunks →
  finalize); dirs via `mkdir`. Server appends one changelog entry, bumps `head_seq`,
  broadcasts.
- **Pull:** changelog delta since cursor → `apply_remote` into local SQLite →
  dehydrate changed placeholders. The delta is **paged** and full-resyncs when the
  cursor is below the server's `oldest_seq` (pruned-gap detection).
- **Hydrate:** on read, fetch missing chunks via presigned GET → local cache.
- **Conflict detection** (replaced v1 last-writer-wins): each commit sends its
  `base_version_id`; if it's no longer current, the server records a **conflict** (both
  versions kept) instead of silently dropping an edit, and the client prompts to keep one
  or split into two files (`Sync::Conflicts`, `GET /v1/conflicts`,
  `POST /v1/nodes/:id/resolve_conflict`). A base that IS current is a clean fast-forward.
  Tenant = user, full tree on every device.

---

## 7. Deployment (one protocol, two hosts)

| | Managed | Self-host |
|---|---|---|
| Rails | cloud | user's box |
| DB | Postgres (Neon/RDS) | SQLite |
| Storage | R2 | their S3 (SeaweedFS/MinIO) |
| Tenancy | `user_id` scoping | single user |

Same models, same API, same client — only the hosts/creds differ. Switching DB is
config-only (the code is adapter-agnostic; tested on SQLite). To use S3 chunk storage set
`STORAGE_BACKEND=s3` + `CHUNK_*` (see `docs/SYNC_SERVER.md`). **A share/s3 *library*
deployment sets NO `STORAGE_BACKEND` and NO `CHUNK_*`** — see §14a.

Bare "deploy" means **the three Unraid backends only** (chunk + share + s3). Deploy OVH
only on explicit request. `docs/DEPLOY.md`.

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
  minter only. (§15; the one deliberate departure is the share backend — §14a.)
- **Registration creates a new account only** (no `find_or_create_by` takeover); a new
  device joins an existing library via a **single-use, expiring pairing code** issued by
  an authenticated device (`DevicePairing`, `POST /v1/devices/pairing` → `/v1/auth/pair`;
  Syncthing/Plex model). Web auth is Rails 8 built-in (signup/confirm/login/reset) with an
  OmniAuth seam. Real OAuth/OIDC email verification is the later upgrade; the device-token
  + pairing mechanism underneath stays. (If multi-user/db-per-tenant is wanted later, the
  37signals `active_record_tenanted` pattern slots over the same models.)

---

## 9. Licensing (don't relitigate)

- **Prefer permissive: MIT / Apache-2.0 / BSD.** Everything we use/ship is permissive
  (Rails MIT, FastCDC MIT, SQLite PD, our crates Apache).
- **Avoid GPL/AGPL** in dependencies and shipped artifacts. FUSE drivers (WinFsp GPL,
  macFUSE) are **user-installed**, never bundled — so no copyleft in our binaries; on
  Windows prefer native **CfAPI** (no driver). SeaweedFS (Apache) is the self-host S3
  backend (not MinIO, which is AGPL).
- **GPL sidecars are invoked over HTTP, never linked** — and shipping them has its own
  three rules (§14c).

---

## 10. Repo layout

```
/                Rails 8 sync server (app/, config/, db/) + docs/ (incl. DEPLOY.md)
/client          Rust crates: fs-provider, fs-fuse (Linux), fs-cfapi + fs-winfsp
                 (Windows), fs-webdav (macOS), sync-client, sync-engine, maker-app (Tauri)
                 (+ maker-app-core, juicefs-backend from the prior path)
/sidecar         GPL services invoked over HTTP only: boxes (GPL-3.0), openscad (GPL-2.0)
/docs            architecture-sync-engine.md, sync-protocol.md, SYNC_SERVER.md,
                 STATUS.md, DEPLOY.md, roads-not-taken.md, adr/
```

---

## 11. Status

**`docs/STATUS.md` is the canonical record** — current per-suite test counts, every
completed arc, and the live open-items list. Read it for anything time-bound; do not
re-narrate it here.

Where things stand: the full stack runs **on real hardware**. Rails is deployed via Kamal
on an Unraid VM with SeaweedFS chunk storage, and the client **mounts + syncs against it
on all three OSes** over the same `Provider` (macOS WebDAV / Linux FUSE / Windows CfAPI),
verified live byte-for-byte. All **three `LIBRARY_BACKEND` values are deployed live**. The
maker web layer (projects, model library, previews, `/tools` addons, current-project, 3D
viewer, file organization) is server-rendered Hotwire on `Maker::*` models.

---

## 12. What's open

Steps 1–10 of the original plan are **done** — the daemon loop, presigned round-trip,
delete/move-on-pull, the Windows adapters, writeback/robustness, caching/freshness,
Postgres validation, the maker app layer, and the maker/file-layer split (all four
phases). Per-phase detail: `docs/STATUS.md`.

Genuinely open:

1. **Real OAuth/OIDC email verification** so the bootstrap proves email ownership. The
   account-takeover hole is already closed (register is new-account-only; devices join by
   pairing code) — this is the remaining upgrade. Device-token + pairing stays underneath.
2. **At-rest chunk encryption** — deliberately last (`docs/plan-encryption.md`,
   `docs/parity-roadmap.md`).
3. **Sharing** — `docs/plan-sharing.md`.
4. **Selective sync needs an app surface** (the engine side landed).
5. **Managed-Postgres at scale** — pick a session/transaction-mode pooler endpoint and run
   a concurrent-commit load test (the boot guard + deadlock fix are in).
6. **Linux and Windows CI coverage is skipped, not passing** — only the macOS runner is
   registered. See §15 and `docs/STATUS.md` ("CI runs again").
7. **The unexplained intermittent** — `SQLite3::BusyException` in a controller test
   `setup`, captured 2026-07-27, still undiagnosed. The cross-worker explanation is
   *disproved*: each parallel worker has its own SQLite file, so the lock holder is inside
   the failing worker.
8. **`FilesController#index` render cost** — ~160 ms at 2000 nodes, identical on all three
   backends (the port's N+1 is closed; the residual is HTML). Pagination never existed.
9. **No web UI at all** for inventory, BOM, suppliers, locations, collections, tags — the
   models and v1 API exist. Obvious next slices.
10. **A chunk-mode device push through the mount gets no eager nudge for project-folder
    filing.** `Sync::Commit#finalize` never calls it — only the three web upload doors do
    — so a file arriving via the mount waits for the 15-minute sweep like everything
    else. Wiring it in would be worse, not better: `#finalize` runs once per file, so a
    500-file device sync would become 500 synchronous full-project sweeps.
11. **Whether a project-scoped upload should duplicate-check across the whole project,
    not just its immediate destination, is an open product question.** Today two files
    can both be named `dup.stl` under one project — the first filed into its category
    subfolder, the second left at the root — because the only collision checks are the
    port's own write-time clobber and `Maker::MoveNode`'s destination-folder collision,
    both scoped to one path, not a project-wide name scan.

Smaller deliberate leftovers live in `docs/STATUS.md` under "Still open".

---

## 13. Build & run cheatsheet (for a fresh context)

```sh
# ALL local gates, one command (this is what CI runs, by name):
bin/ci                 # bin/ci --list for gate names; config/ci.rb is the single definition

# Server tests (SQLite; proves adapter-agnosticism)
bin/rails test
# The other two backend legs need their env or they DON'T look like a missing var —
# LibraryBackendCheck refuses to boot, which reads as a broken backend (see ci.yml verbatim):
LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test
# s3 leg additionally needs the five LIBRARY_S3_* stub knobs — see ci.yml's test-s3-backend.

# Boot the server for the live demos (memory chunk store = control-plane only)
STORAGE_BACKEND=memory bin/rails server -p 3001

# Live cross-stack demos (server must be running):
(cd client/sync-client && SERVER_URL=http://localhost:3001 cargo run --example e2e)
(cd client/sync-client && SERVER_URL=http://localhost:3001 cargo run --example multi_device)
(cd client/sync-engine && SERVER_URL=http://localhost:3001 cargo run --example roundtrip)      # real bytes
(cd client/sync-engine && SERVER_URL=http://localhost:3001 cargo run --example daemon_loop)    # outbox→push→pull→hydrate
(cd client/sync-client && SERVER_URL=http://localhost:3001 cargo run --example nudge)          # ActionCable {head_seq} (~39ms)

# Server with real S3/SeaweedFS chunk storage (presigned PUT/GET):
STORAGE_BACKEND=s3 CHUNK_ENDPOINT=http://192.168.1.8:8333 CHUNK_BUCKET=my-bucket \
CHUNK_REGION=us-east-1 CHUNK_ACCESS_KEY_ID=admin CHUNK_SECRET_ACCESS_KEY=secret \
  bin/rails server -p 3001
(cd client/sync-engine && SERVER_URL=http://localhost:3001 cargo run --example presigned_roundtrip)

# Rust crate tests (per-suite counts in docs/STATUS.md)
(cd client/fs-provider && cargo test)   # chunking/posix/convergence/concurrency/caching (hermetic)
(cd client/sync-client && cargo test)
# sync-engine integration needs a running server (skips cleanly without one).
# SYNC_VERIFY_FINALIZE=0: finalize's verify-the-bytes-landed check defaults ON, but the engine
# suites move chunk bytes through SharedDirIO, not the server's store — so the server can't see
# them. See config/initializers/finalize_verification.rb.
STORAGE_BACKEND=memory SYNC_VERIFY_FINALIZE=0 bin/rails server -p 3001 &   # then:
(cd client/sync-engine && SYNC_IT_SERVER_URL=http://localhost:3001 cargo test --test integration)

# External conformance (battle-tested tools vs our real mounts — client/test-conformance/):
client/test-conformance/webdav-rclone.sh      # rclone ⇄ WebDAV round-trip (macOS+Linux)
client/test-conformance/fsx-fuse.sh           # fsx data-integrity exerciser ⇄ FUSE (Linux)
client/test-conformance/pjdfstest-fuse.sh     # pjdfstest POSIX map ⇄ FUSE (Linux, informational)

# Two-device REAL-MOUNT E2E (a file through ONE real kernel mount, read byte-for-byte
# through ANOTHER device's real mount). Uses STORAGE_BACKEND=local (memory:// can't move bytes):
client/test-conformance/two-device-fuse.sh           # Linux, two real FUSE mounts (CI-automatable)
client/test-conformance/two-device-webdav-macos.sh   # macOS, two real WebDAV mounts (interactive)
client/test-conformance/two-device-cfapi.ps1         # Windows, two real CfAPI sync roots (interactive)
# CI: `gh workflow run rust-client.yml -f target=two-device`

# fs-fuse on macOS needs FUSE-T + a pkg-config alias + rpath — see client/fs-fuse/BUILD.md.
# Mount it:  ./target/debug/maker-mount ~/MakerDrive /tmp/maker.db /tmp/maker-chunks
```

**Env gotchas in this build box (may differ on yours):** no local Postgres/libpq (dev
& test run on SQLite); FUSE-T is installed but `fuser` needs an `osxfuse`→`fuse-t`
pkg-config alias (`client/fs-fuse/BUILD.md`); macOS keeps creating `" 2"`-suffixed
duplicate files in the repo (some sync client?) — they broke a build once; `find . -name
'* 2.*' -delete` to sweep.

**Mount build/runtime notes.** Deps are strictly target-gated so each OS compiles only its
own. macOS → WebDAV (FUSE-T's **FSKit** build can't mount on macOS 26 — silent fail, the
System-Settings toggle is greyed). Linux → FUSE (`auto_unmount` needs `user_allow_other` in
`/etc/fuse.conf` + `/dev/fuse` access). Windows → CfAPI by default; WinFsp needs
LLVM/libclang to build and `winfsp-x64.dll` on PATH at runtime, and mounts a **drive
letter**, not a path.

---

## 14. Invariants and hard-won learnings (don't relitigate)

> The condensed **abandoned/superseded approaches** (remote mount, JuiceFS data plane,
> Cloudflare-native sync, WinFsp-as-default, last-writer-wins, the `mtime=now` hack, FSKit)
> — *what was considered → why rejected → current approach* — live in
> **`docs/roads-not-taken.md`**. Read it before reviving any of them.

Each line below cost a real bug. `docs/STATUS.md` has the full story for any of them.

### 14a. The FileLayer port

- **`LIBRARY_BACKEND=chunk|share|s3`, chosen per DEPLOYMENT, not per user.** Reads:
  `stat`/`stat_all`/`read`/`download`/`trashed` — all three adapters answer all five.
  Writes (`write`/`delete`/`move`/`undelete`) are **Share + S3 only**.
- **A share/s3 deployment sets NO `STORAGE_BACKEND` and NO `CHUNK_*`.** `STORAGE_BACKEND`
  defaults to `s3` *outside test*, so resolving a chunk store on a v1 request once made a
  share deployment's **entire v1 API answer 500** (`KeyError: CHUNK_BUCKET`) — including
  login and every gated endpoint, which returned 500 instead of 501. The suite was green
  with **and without** the fix, because the gating tests set `FileLayer.current` and never
  touched `STORAGE_BACKEND` (`memory` in test, `s3` in production).
- **`Chunk` refuses writes PER-OP, naming the real door each time** — `write` →
  `Sync::Commit`'s two-phase flow; `delete` → **`Sync::SubtreeDelete.call`** (cascades to
  the subtree; `Sync::Mutation.apply(op: "delete")` tombstones only the node it is handed
  and **orphans descendants**); `move` → `Sync::Mutation.apply(op: "move")`. **One shared
  refusal message** is how an earlier draft sent delete/move callers to `Sync::Commit`,
  which has neither path. Keep them separate.
- **`port_writable` IS NOT "accepts uploads"** — the single most-misread name here. It
  answers *which upload flow the UI drives*: true → POST bytes to the port (share, s3);
  false → drive `Sync::Commit`'s presigned flow (chunk). Chunk mode accepts uploads all
  day — that *is* `Sync::Commit` — so the "can this deployment take uploads" reading
  **hides the upload button in the product's main deployment**. It is also not `!syncable?`
  and not `scannable`; the full argument is at `app/services/file_layer/capabilities.rb`.
- **The 501 is a capability gate BEFORE the call, never a `rescue NotImplementedError`.**
  `NotImplementedError` is a **`ScriptError`, not a `StandardError`**, so `rescue => e` and
  ActiveJob's `retry_on` silently do **not** catch it — a rescue-based gate doesn't have a
  gap, it doesn't work, failing to exactly the 500 that was forbidden. A 501 from
  `Chunk#write` would also be *factually wrong* (the caller used the wrong door), and a
  controller rescue would launder an s3 **misconfiguration** into a routine response.
  Keep `NotImplementedError` un-rescued and loud. **`test/architecture_invariants_test.rb`
  enforces this** — it is no longer a grep you are trusted to remember to run.
- **Ungated on purpose:** **`devices`** (gating it makes a share deployment's whole v1 API
  unauthenticatable, since a device token is the only credential the API accepts — and the
  plan's own test stayed green because it minted a token in Ruby instead of calling the
  endpoint), and **`V1::ShareController`** (the anonymous redeem side of public file links —
  nothing to do with `FileLayer::Share`; a 501 would disclose the backend to any stranger).
  Two gates are not the capability they look like: **`chunks#download` → `syncable`, NOT
  `presignable`** (S3 is presignable with no chunk to hydrate), and **v1 `trash` →
  `syncable`** (it's the *chunk* trash). `begin_upload`/`finalize_upload` gate on
  `syncable`, not `!port_writable?`.
- **`S3` is the one backend where `presignable` is TRUE and `versioned` is FALSE** — that
  combination is its point. §15 (bytes out of Rails) **survives** there (a bucket has a URL
  signer); §5 (keep versions) does **not**. The other two agree (chunk true/true, share
  false/false), so S3 is the counterexample that forbids collapsing one into the other.
- **Two deliberate invariant departures, scoped to storage we don't own — do NOT "fix"
  these back.** §5 can't hold on a plain share (the user's overwrite in Finder destroys the
  old bytes) → share/s3 are **current-state only**, restore stays chunk-mode. §15 can't hold
  for a mounted directory, which has nothing to presign → share streams via **`send_file`**.
- **`send_file` + `x_sendfile_header` is the whole X-Accel story — there is no nginx here.**
  Deployment is kamal-proxy (Go) and `x_sendfile_header` is **nil**, so `Rack::Sendfile`
  no-ops and `Rack::Files` is the only branch that runs. The knob stays **commented** in
  `production.rb`: enabling it would **silently serve empty bodies** for every share download.
- **`Delivery`'s three variants are three MECHANISMS** — `Redirect(url)` (chunk
  single-chunk + s3) / `SendFile(path)` (share) / `Stream(enum)` (chunk multi-chunk) — and
  `FilesController` consumes them **without ever constructing a path**. `disposition:` is
  **required, not defaulted**: nil makes `ContentDisposition.format` emit a header with no
  disposition type, which browsers resolve as **inline** — a silent cross-backend
  divergence, on S3 only, where the value is signed into the URL.
- **`Chunk#download`'s `is_a?(S3ChunkStore)` is deliberately NOT `presignable?`** — memory
  and local stores presign to URLs **Rails itself serves**, so redirecting sends the browser
  back through us. The `chunks.size == 1` half is load-bearing too: a redirect names ONE
  object, so redirecting a multi-chunk file hands the browser its first chunk with a 200 and
  the right filename — **silent truncation**.
- **`stat_all(user, node_ids:) -> Hash keyed by node_id` is a port verb**, and **a missing
  node is an ABSENT KEY, not a raise** — `stat` is asked about one node so `NotFound` is its
  whole answer, but a bulk caller holds a **list**, and a row tombstoned mid-page must not
  404 the page. The shared contract pins three things, and **only the third fails for a
  loop** (`node_ids.map { stat }` is behaviorally identical): the query count must be
  **constant in N**, asserted as constant rather than a literal (chunk needs 2, share/s3 1).
- **THE TWO TOMBSTONE KINDS — the thing most likely to get "simplified" away.** A **scan**
  tombstone **keeps** `storage_path`; a **trash** tombstone **NULLs it** and is revivable
  only by `undelete`. Collapse them and `Reconciler#create_or_revive!` hands a **new,
  unrelated file the trashed node's `node_id`** — with every attachment, BOM link and tag —
  while the old bytes await an `undelete` that then collides. Silent.
- **Trash layout `.trash/<node_id>/<name>`, keyed by `node_id`** — which is *why* two
  same-named deletes can't collide, and why `undelete` has one place to look.
- **`undelete` is a FOURTH port verb.** "Undelete is just a move back" is *precluded*:
  `move` starts with `live_node!` (a tombstone isn't live) and resolves via `storage_path`,
  which is NULL — it would rename the library root.
- **Order is load-bearing both ways:** `delete` is **move-then-tombstone** (the reverse
  fails *silently* — the next scan resurrects it); `undelete` is **move-then-revive**.
  `EXDEV` → `FetchError`, **never** a copy+delete fallback.
- **`delete` refuses directories; `move` ALLOWS them.** A dir delete strands children at
  paths that no longer exist while their bytes sit in `.trash`, where the scan refuses to
  look. A moved dir leaves the bytes observable **at an observable destination**, so pairing
  rescues the children — that qualifier is load-bearing (see §14b). On **S3 both refuse
  dirs**, because there is no directory and no rename: a dir node's key doesn't exist.
- **An unmounted share must never read as "your file is permanently gone":** `undelete` and
  `read` raise **`FetchError`** (retryable → 503), not `NotFound` (terminal → 404).
  `FetchError` → 503 and `UnsupportedOperation` → 422 are mapped once at `FilesController`.
- **A clobber is `UnsupportedOperation`, and ALL THREE VERBS moved together.** Both adapters
  once raised `NotFound`, so a duplicate-name upload said "File not found." about a file in
  the list behind the alert. "The destination is taken" is ONE condition that
  `write`/`move`/`undelete` all meet — fixing only `write` leaves one condition with two
  answers inside one adapter. `FetchError` would be worse: it is the *retryable* answer and a
  clobber never succeeds on retry. If a caller must branch, the answer is a **subclass**.
  (This also broke `TrashController`, which rescued `NotFound` but not
  `UnsupportedOperation` → an uncaught 500, **while its own rescue comment already named
  that case**. The gap was in the CONTROLLER, which is why no adapter suite could find it.)
- **`LIBRARY_TRASH_DAYS`** default **30**; **`0` = keep forever, NOT purge everything**
  (`0.days.ago` is *now*, so the obvious implementation deletes the lot). Purges by
  entry-dir mtime, never touches the row, and **empties `.trash` but never removes `.trash`
  itself** (an empty root reads as unmounted → would flip `undelete`'s error class).
- **The boot guard touch-probes for writability; `File.writable?` is NOT the check** — it
  tests POSIX mode bits, not effective access, and is wrong under exactly the NFS/SMB ACLs
  this backend targets. It must run in **`after_initialize`**: app constants aren't
  autoloadable while initializers run, so the naive version raised `uninitialized constant
  Library` and **took the boot down while every test stayed green** (test env skips it).
  **The S3 boot guard does NO NETWORK** — a boot depending on a third party turns a blip
  into a crash loop. Config *presence* is what boot can honestly check.
- **THE IDENTITY LADDER** (`FileLayer::S3::ObjectIdentity`). One namespaced value answers
  two different questions: `content_token` need only be an opaque content-*state* token, but
  `content_hash` must be content-*determined* for move-pairing — and **a multipart ETag is
  not**. Ladder: **`sha256:`** (FULL_OBJECT only — a COMPOSITE sha256 is a
  checksum-of-checksums, so the *type* is required, not the checksum alone) → **`md5:`** (a
  **32-hex** single-part ETag is the md5 — 32-hex, not merely "dash-free") → **`etag:`**
  (moves degrade to delete+create — a *missed* rename, never a *wrong* pairing). **TOTAL by
  construction, never nil**: `Reconciler#plan_moves` **drops** a nil-hash observation from
  `candidates`, and candidates become the leftovers that get indexed → the object is **never
  indexed at all**, no error, no log. **Quotes come off in exactly ONE place** (S3 quotes
  every ETag in list, head *and* put). Blind spot: an **SSE-KMS** object has a 32-hex ETag
  that is *not* the content md5, so the rung-3 warning count reads **zero while no move
  pairs at all**.
- **`LIBRARY_S3_HEAD_FOR_CHECKSUM` is NOT implemented — do not document it as working.** An
  observer cannot know what is new (the Reconciler does), so a HEAD there is
  per-object-per-**scan**: 2M billed requests every 15 min on a 2M-object bucket, not 2M
  once. Consequence: the **`sha256:` rung is unreachable from any production path today**.
  Download-and-hash was rejected on §1's own terms — a full billed egress to index a library
  the user already has is the cost the on-ramp exists to avoid.
- **LANDMINE — copy → delete → TOMBSTONE.** "Tombstone only after the copy confirms" is
  necessary but **not sufficient**: if the **delete** fails after a tombstone, the next scan
  finds an unclaimed key with **no tombstone to revive by path** → a **new `node_id`** →
  **every attachment orphaned**, by a scan that did nothing wrong, with no error anywhere.
  (`undelete` is the same landmine: copy → revive → sweep the trash copy best-effort, last.)
- **`key_for` REJECTS, never normalizes** — `expand_path` would turn `a/../b` into a *valid*
  key and silently read the wrong object. We sign **path-style** URLs, so a `..` segment
  lands in the URL path and any normalizing proxy resolves it out of our bucket.
- **`S3#write` has NO temp-and-rename, and its ABSENCE is the thing to read carefully** — a
  reader who knows `Share#write` will see a missing step and "restore" it. Share renames
  because a half-written file is *visible* the whole time; **put_object is atomic**, so a
  temp key would only add a second, unobservable ghost. Clobber is refused, but it is a
  `head`-then-`put` **CHECK, NOT A LOCK** (TOCTOU; S3 has no portable conditional put).
  `put_object`'s response carries no `last_modified` → **two billed HEADs per write**.
- **`Share#write` stamps mtime from the file's own stat, not the clock** — the scan compares
  against it.

### 14b. The library scan

- **`scannable` is not `!syncable?` and not `port_writable`.** It asks *"does this backend's
  catalog come from polling the store?"* (chunk false — its tree is the changelog; share/s3
  true). It agrees with `port_writable` on all three backends we have, so the distinction
  must be **argued, not observed**: `scannable` asks where the *catalog* comes from,
  `port_writable` asks which door *bytes* go in, and a notification-driven backend splits
  both. Agreement across three samples is not identity; it is three samples. Both job gates
  (`ScanJob`, `TrashPurgeJob`) key on `scannable?` — keying on `is_a?(FileLayer::Share)`
  would answer false for S3 and **silently never index the library**.
- **The Reconciler is the reusable half; the Scanner is not.** A `Dir.children`/`lstat`/
  symlink walk is irreducibly filesystem-shaped, so S3 gets its own `S3Observer` over
  `list_objects_v2` and both feed the **same** `Reconciler` — which matters because *every
  one of phase 2a's bugs lived in the logic a second copy would have duplicated*.
- **The mass-deletion guard counts the POST-PAIRING tombstone set, never vanished paths** —
  a rename vanishes its old path, so the naive guard refuses the very reorganization the
  feature exists for. Pairing by `(content_hash, size)` is what makes **a rename keep its
  `node_id`, so project attachments survive a NAS reorganization** — the headline promise.
- **`Pathname#find` silently swallows `EACCES`** and drops the unreadable subtree — for a
  tombstoner that is a mass-deletion bug wearing a clean scan. Hence the hand-rolled walk +
  `unreadable_dirs`, which must be excluded from **both** sides of the guard's fraction *and*
  from `vanished_paths`. (`ignore_error: false` aborts the whole walk, order-dependently.)
- **THE SKIP-LIST BLIND SPOT — four instances so far, each found only after the previous
  explanation said it couldn't happen.** Wherever the app moves bytes **into** a skipped
  region (`TRASH_PREFIX` `.trash`, root-anchored; `TEMP_PREFIX` `.maker-tmp-`, skipped at
  **any depth**) while leaving a live node pointing at the old path, it creates ghosts the
  Reconciler **can never pair** — pairing needs an *observation* as the partner, and a
  skipped path produces none. The tombstone then trips the mass-deletion guard, **refusing
  that scan and every scan after it, permanently**. The four: `write`'s temp file; `delete`
  on a directory; `write`/`move` accepting `.trash` as a destination (which also turns
  `.trash` into a file, breaking **every delete in the library**); and `Share#undelete`
  reconstructing its destination from a poisoned parent. A sentence that had to be
  retracted: *"delete is uniquely exposed, because a move leaves the bytes observable at the
  new path"* — false; a move is self-healing only when its **destination** is observable.
  **Assume every path that writes is exposed until you have checked it** (`observable!`).
- **A LISTING IS NOT A SNAPSHOT.** `list_objects_v2` paginates, and a failure on page 7 of
  40 is a **well-formed lie** that reads exactly like the user deleting 82% of their library.
  It is the `EACCES` problem again minus the escape hatch: `unreadable_dirs` scopes a gap to
  a *subtree*, but a page boundary is an arbitrary key range that scopes to nothing.
  **Complete-or-abort is the only honest answer** (`Scanner::UnsafeScan`). Two more it must
  not inherit by assumption: **dir-marker objects** (`cad/`, minted by the S3 console) would
  become a phantom *file* node beside the real dir node; and **`valid_encoding?` does NOT
  transfer** — it asks about the string's *tag*, and an ASCII-8BIT string is always valid, so
  the naive port waves a `\xFF` key straight into `storage_path`. Filenames on a real NAS
  **are not guaranteed to be valid UTF-8**.
- **`Share#absolute_path` must never resolve a NULL `storage_path` to the library root.**
  `#download` handed that **directory** to `send_file`; `read`/`delete`/`move` escaped only
  by *accident* (EISDIR, EINVAL). `allow_root:` is **gone**, not switched off.
- **A `Maker::Preview` is ONE ROW PER `(user, node, kind)`, REPOINTED as content moves** (was
  one per *version*, which leaked a row + blob on every save). Two consequences that are easy
  to undo by accident: **`GeneratePreviewJob` must compare-and-set** (`#commit_if_current`) —
  with one row, a slow render of v1 finishing after v2 would attach v1's bytes to a row
  claiming v2 and mark it ready, a wrong image shown as current, which the row-per-version
  key made impossible *by construction*; and **`POST /v1/maker/previews` answers 422 for a
  superseded version** rather than repointing the live row backwards.
- **The scan must enqueue a thumbnail on BOTH the create/revive branch AND the in-place
  content change.** The second was missing: previews resolve by `[node_id, content_token]`,
  so a file re-saved in place stranded its row on content that no longer existed and went
  blank on every surface — the ordinary case on a mounted NAS (LightBurn, a slicer), which is
  why it read as a format bug. **A scan cannot repair that backlog and should not try** (those
  nodes are now `unchanged?` and correctly skipped); the sweep is
  `Maker::Previews::MissingBackfill` (`rake previews:backfill_missing`).
- **Reconciler perf, and its own comment was the lesson.** The old comment argued *"dwarfed
  by the hashing, not worth an index"* — but hashing is LINEAR and that scan was QUADRATIC,
  so the crossover was built in. A no-op scan now `pluck`s the compared columns instead of
  instantiating a live node per file, and `best_pairing` buckets candidates by `[hash, size]`.
  *Still inherent:* an all-byte-identical bucket costs O(N) per probe, because the
  deterministic tie-break must compare the old path against every identical candidate —
  removing that trades the no-lost-file guarantee for speed.

### 14c. Addons and GPL sidecars

- **Two sidecars exist, both GPL invoked ONLY over HTTP, never linked** (§9): `sidecar/boxes`
  (GPL-3.0) and `sidecar/openscad` (GPL-2.0). **Three facts are guarded by
  `test/deploy_hygiene_test.rb` rather than memory** — the first two were real shipped bugs,
  and all three live in files the Rails process never loads, so no other test can see them:
  1. **`/sidecar/` is in `.dockerignore`** — the Rails `Dockerfile` does `COPY . .`, so
     without it the copyleft trees are baked into the **permissive** app image. Never
     imported or executed, but *shipped*, which is exactly what §9 exists to prevent.
  2. **Each sidecar's URL env var must be EXPLICITLY BLANKED in `deploy.ovh.yml`** — the
     accessories run on the Unraid host and Kamal **deep-merges** `env.clear`, so the OVH
     overlay otherwise inherits an Unraid-only hostname, the addon reports itself available,
     and every call fails — strictly worse than greying out.
  3. **Each GPL sidecar image must carry its own licence text INSIDE it** — we build and push
     these to a registry, which is redistribution.
  The guard is **directory-driven, not a hard-coded pair**, so a third sidecar is covered the
  day it appears — and it asserts *two* things, because a "has a LICENSE beside it" discovery
  filter silently skipped the **worse** case: a sidecar whose author never committed a
  `LICENSE` at all was invisible to the guard written to catch exactly that. Found by
  planting a synthetic sidecar and watching the test stay green, not by reading it.
- **`Registry` is a REGISTRATION API, not a list** — an addon calls
  `Maker::Addons::Registry.register` (the host's three from
  `config/initializers/addons.rb`, inside **`to_prepare`** because app constants are not
  autoloadable while initializers run — §14a; moving those calls to initializer top level
  crashes the boot with `uninitialized constant Maker`, verified by mutation, not
  assumed). Two things there are load-bearing: `available:` stays a **lambda**, so an
  addon whose backing service is unconfigured greys out rather than 500ing; and `path:` is
  a **proc the addon declares**, not a `send("tools_#{key}_path")` naming convention. That
  convention was the sole reason the two inflector traps in `config/routes.rb` could take
  **/tools down for every user** — the guard is now generic ("every registered addon's
  path resolves with no arguments", `test/services/maker/addons/registry_test.rb`) and
  covers addons in gems this repo has never seen. `Registry.all` sorts by
  **`[title, key]`** — `sort_by` is not stable, so the key is the tiebreaker; gem load
  order must never be user-visible. `Registry.entries` is **private**: `Registry` is an
  SDK surface, so anything public on it becomes contract a gem may depend on.
- **`Maker::Addons::SDK_VERSION` + `require_sdk!` fail the BOOT**, not the first click,
  when an addon gem needs a newer host. The six SDK surfaces are enumerated in
  `docs/superpowers/specs/2026-08-02-tools-addons-separate-repo-design.md` §3. **The bump
  policy is a CONVENTION, not enforcement** — nothing ties a change in one of those six
  surfaces back to this constant, so a future editor who changes `Tools::LibraryFolders`
  gets no reminder. Say so rather than implying the contract is mechanical.
- **Each save writes ONE file — its output.** The `.params.json` beside it is gone: it was
  **write-only** (`Maker::AddonState#data` already recorded the params and every reader went
  there). Params are now served by `Tools::AddonParamsController` — **one** route for all
  addons, because `AddonState` is addon-agnostic — and the download serves the whole `data`
  hash, not `data["params"]`, which is byte-identical to the removed file. Files already
  written were **left in place** (ordinary library files a user may have renamed or attached;
  a migration must not delete user bytes).
- **`Maker::Addons::LibraryOutput` is the ONE output path**, backend-neutral on
  `port_writable?`. It is also the **one legitimate direct `Storage::ChunkStore` call in the
  maker layer** (addon output has no client to presign for). So the phase-1 decoupling proof
  is *"one hit, and it is `library_output.rb`"*, **not** "no hits":
  `grep -rn "manifest_chunks\|ChunkStore" app/services/maker/ app/models/maker/ app/jobs/maker/ | grep -v ':[0-9]*: *#'`
  The `grep -v` is load-bearing, not noise — without it the check reports comments that
  *describe* the removed coupling. **A proof that cries wolf gets ignored.**
  **`test/architecture_invariants_test.rb` now RUNS this**, asserting both the count *and* the
  file, so the claim can no longer drift the way it did before (it read "no hits" for months
  after the addon framework made the true answer one). Change the code and the test tells you;
  change the exception on purpose and update the test and this bullet together.

### 14d. The maker web layer

- **Server-rendered Hotwire on `Maker::*` models, session-authed — NEVER the device-token v1
  API.** `/v1/*` is Bearer-token; the web app is cookies. Consequence: web controllers are not
  limited to what the JSON API exposes.
- **The `port_writable?` two-door branch is written out FIVE times, not three** (both this
  file and STATUS.md said "the third appearance" until someone counted):
  `Maker::LibraryFolder#mkdir`, `FilesController#destroy`, `TrashController#restore`,
  `Maker::Addons::LibraryOutput.write`, and `Maker::MoveNode`. Only two have a name of their
  own. **So the rule is not "refuse a fourth copy" — a NEW one needs an argument for being
  inline rather than a service**, and a verb more than one caller performs doesn't have one.
  (Excluded on purpose: `require_capability!` gates and views that pick an upload FORM —
  those select a UI, which is `port_writable`'s stated job.)
- **A verb more than one controller performs gets a named service** — `Maker::MoveNode`,
  `Maker::AttachToProject`, `Maker::LibraryFolder` — rather than being re-inlined per action.
  This is **not** "controllers never touch `Sync::`": they do, in ten places, and three of those
  are the deliberate two-door branches listed above (`FilesController#destroy` →
  `Sync::SubtreeDelete`, `TrashController#restore` → `Sync::Trash.restore`, plus
  `FilesController`'s `Sync::Commit` upload flow). *(An earlier draft of this line did say
  "never reach into `Sync::`". It was wrong on its own page — the five-times list two bullets up
  names two of the exceptions — and a reader who believed it would "fix" working code.)* The
  tripwire is about **new** work: **if a maker-layer change needs to touch sync, the changelog,
  conflicts, locks, or the mounts, the boundary is wrong — stop.**
- **ONE file-type vocabulary.** `FilesHelper::EXT_FAMILIES` is **derived** from `ROLE_BY_EXT`,
  grouped by role and labelled by `ROLE_LABELS`. Add an extension in **`ROLE_BY_EXT` only**.
  Two consequences: every extension must satisfy `FilesController::EXT_RE`
  (`/\A[a-z0-9]{1,8}\z/`) or it renders a chip that links and **silently does nothing**
  (`markdown` is the current bound at exactly 8 chars); and the `role` column is
  **behavioural** — cover-image selection reads `image`/`model` and
  `Models::AttachmentsController` dispatches `ExtractPdfMetadataJob` on `instructions`, so
  `pdf` must stay `instructions`. A third copy in `importer_controller.js`'s `roleFor` has
  drifted; it is browser-only and the server re-derives authoritatively.
- **A `form_with` that is missing `scope:` emits param names the controller's `require`
  rejects — and a nested-hash test cannot see it.** Two shipped instances: `form_with model:`
  on a **namespaced** model scopes to `maker_project[...]` while the controller required
  `:project`; and `form_with url:` with **no `model:`/`scope:`** has a blank `object_name`, so
  `fields_for :task` emitted `name="[task][title]"`, which Rack parses to the **literal key
  `"[task]"`** → `ParameterMissing` → **a hard 400 on every Add since the panel shipped**.
  Note `button_to ... params:` builds hidden inputs *without* the builder, so sibling buttons
  keep working and it reads as a feature quirk. Plain `f.text_field` on a blank `object_name`
  is safe (flat `name="title"`); **`fields_for` is what interpolates brackets**. Both were
  invisible to a green suite because the tests POSTed `params: { x: {...} }` as a Ruby hash,
  which bypasses the form entirely. **Assert the rendered field name.**

### 14e. Architecture and process

- **A remote-mounted filesystem does NOT work over the WAN.** rclone/JuiceFS mount =
  synchronous metadata round-trips → ~1 s/file (Phase 0, measured). Every production system
  uses **local metadata + async sync + on-demand hydration**. That pivot is the whole reason
  this architecture exists. Do not go back to a remote mount.
- **JuiceFS was abandoned** here: chatty WAN metadata, no internal ACL (multi-tenancy needs a
  gateway/volume-per-tenant), and FUSE-driver licensing. `client/juicefs-backend` +
  `maker-app-core` are leftovers — reference only.
- **Edge-SQLite (Cloudflare D1, Turso) can't back JuiceFS** — no driver + chatty-metadata
  latency. They *would* fit the coarse-manifest model, but we use Rails + Postgres/SQLite to
  stay self-hostable (D1/DO are Cloudflare-locked → break self-host).
- **The sync model makes multi-tenancy SIMPLE** (coarse API + `user_id` scoping) — the
  opposite of the mount model's credential gymnastics. Tenant = user for v1.
- **Permissive licensing is a hard constraint** (§9). Block-delta + versioning is available
  permissively: **fastcdc-rs (MIT)**, **desync (BSD-3)**, **restic/chunker (BSD-2)**.
- **DB: Postgres managed, SQLite self-host, one adapter-agnostic codebase.** No PG-only SQL in
  the hot path. **`next_seq!` must be the FIRST statement** in `Sync::Commit#finalize` /
  `Mutation#apply` / `Restore` / `Conflicts`, or concurrent commits deadlock on a
  `FOR KEY SHARE`→`FOR UPDATE` lock upgrade. A **statement-mode pooler breaks it** — the boot
  guard refuses to start behind one.
- **Server presigning is local** (HMAC) — you can verify chunk URLs without the storage being
  reachable.
- **A FAKE THAT SHARES THE CODE'S MISUNDERSTANDING CONFIRMS IT.** `FakeS3` decoded
  `copy_source` with `CGI.unescape` while the adapter encoded with `CGI.escape` — exact
  inverses, so **79/80 tests were green** over **silent permanent data loss on any filename
  with a space** (form encoding turns `Bracket v2.stl` into `Bracket+v2.stl`; real S3 reads
  `+` as a literal plus, so the copy read a nonexistent key and the delete removed the right
  one). Fixed with per-segment `ERB::Util.url_encode`. **Assert the WIRE format, not the
  round-trip**, and mutation-check a guard by reverting the code it guards. Watch for this
  shape wherever a fake and the code under test share an assumption.
- **Checking beats reasoning.** A final whole-branch review found five real bugs of which
  **four were already recorded as unreachable, deferred, or verified** — the contribution was
  *probing*, not thinking. Corollary: **a stale open-list is worse than none**, because it
  spends the next reader's attention on finished work.
- **The suite being green is not evidence a guard works** if the guard's precondition is
  never established in test (see the `STORAGE_BACKEND` 500 in §14a, and the form `scope:` bug
  in §14d). Drive the real request.
- **`assert_select "sel[attr=?]", value, "message"` SILENTLY EATS THE MESSAGE.**
  rails-dom-testing shifts one value per `?` for substitution, then shifts **the next**
  value as the *equality comparator* — so a bare trailing string becomes a required
  TEXT-CONTENT match, and the assertion fails against correct markup (or passes for the
  wrong reason). Pass an explicit `nil`, or a real comparator hash, in the third slot. A
  repo sweep found one prior instance already working around it silently
  (`content_security_policy_test.rb`, which passes `{ count: 1 }`). Story: STATUS.md
  2026-08-02.
- **A SOLID STORE IS NOT WIRED UNTIL `config.<x>_store` SAYS SO.** Solid Cache shipped with its
  gem, `config/cache.yml`, a `cache` role in `database.yml`, `db/cache_schema.rb` and a
  persistent volume — and `config.cache_store` left at the Rails scaffold comment, so production
  resolved to a `FileStore` in the container's `tmp/`, wiped every deploy. Queue and Cable were
  wired; the third was missed while §4 claimed all three. **Resolve it by running
  `Rails.application.config.cache_store`, not by reading the file.**
- **RATE LIMITING COUNTS IN A CACHE, AND `NullStore#increment` RETURNS NIL.**
  `ActionController`'s `rate_limiting` is `count = store.increment(...)` then
  `if count && count > to`, so a throttle backed by the test env's default store fires **never**
  — a rate-limit test then fails for the wrong reason, and a "normal requests still work" test
  passes whether or not the throttle exists. `config.action_controller.cache_store` is the knob
  (real store for limits, caching still off). **Counters key on `request.remote_ip`, which is
  127.0.0.1 for every integration test**, so `test_helper.rb` clears them per test — without
  that, one worker's budget is spent across its whole suite and unrelated tests fail as
  `302 → /users/sign_in`.
- **A CSP HEADER THAT PARSES IS NOT A CSP THAT WORKS — only a browser knows.** Two defects
  shipped past every integration test and were caught by the system tests' SEVERE-console check:
  an empty `'nonce-'` (`session.id` is nil before a session exists, so anonymous pages made
  Chrome **discard the whole `script-src` directive**), and `frame-ancestors 'none'` contradicting
  the app's own same-origin PDF iframes. Ship a policy **report-only** first, and keep
  `frame-ancestors` consistent with `X-Frame-Options` (`SAMEORIGIN` → `'self'`). The same
  lesson, a second instance (STATUS.md 2026-08-02): **`pin_all_from` records only a
  DIRECTORY at draw time** and expands to named pins lazily inside `to_json`, so
  inspecting `importmap`'s `@packages` after boot shows **zero** `controllers/*` entries —
  including for the host's own long-standing pins. A config-inspection check reports a
  false negative; only a render or a browser proves importmap wiring.
- **Query cost is a property nothing asserts unless you assert it.** `projects#show` went from
  flat to +1 query per build-log entry when rich text arrived and the eager load was not extended
  — invisible to a green suite, while `models#show` carried the correct pattern the whole time.
  Guards live in `test/integration/web/page_query_budget_test.rb` and assert **constancy in N**,
  never a literal: the counts differ per `LIBRARY_BACKEND`, so a literal pins one leg and fails
  the other two.

### 14f. Project-folder intake

- **ROOT = INBOX IS THE WHOLE SORT RULE, AND IT IS STATELESS.** Only files at a project
  folder's own root are ever filed; anything already in a subfolder — including one filed
  "wrong" by hand — is never revisited, and no column records that a file was "handled."
  Position is the marker. Re-filing a subfolder would fight the user every 15 minutes, and
  on chunk each round of that fight is a changelog entry broadcast to every device.
- **A SWEEP OVER `nodes`, NOT A HOOK PER DOOR — because there are SEVEN doors and no
  funnel.** `FilesController#create` (share/s3), `#finalize_upload` (chunk),
  `Library::Reconciler` (the scan), `Sync::Commit#finalize` (a device push),
  `Maker::Addons::LibraryOutput`, `Maker::MoveNode`, and a trash restore can all land a
  file under `Projects/<slug>/`. Hooking each is seven sites that must agree, and an
  EIGHTH would silently skip the rule — this repo's recorded failure shape (the five
  `port_writable?` copies, the Scanner's skip-list blind spot). Reading `nodes` — the
  catalog all three backends populate — covers every door, present and future, without
  touching any of them.
- **ADDS NO NEW COPY OF THE `port_writable?` BRANCH — the count named in §14d stays
  five.** Moves run through `Maker::MoveNode`, mkdirs through `Maker::LibraryFolder`; both
  already branch correctly for the deployment, so `ProjectIntake` itself never asks the
  question.
- **READS `folder_node_id`, NEVER CALLS `Project#ensure_library_folder!`.** Calling the
  ensure would make a sweep CREATE `Projects/<slug>` for every project that never had one,
  as a side effect of merely looking — the same bug
  `Projects::AttachmentsController#relocate` once shipped, now at library-sweep scale. A
  project with no folder is simply not swept (`status: :no_folder`).
- **ASKS `Maker::AttachToProject#refusal_for` BEFORE EVERY MOVE — which is why that
  method is public.** Its three rules (`:not_a_file`, `:model_bundle`,
  `:attached_elsewhere`) are policy about where a file may go, not a suggestion; skipping
  them is exactly how `#relocate` once silently pulled a file out of a model's bundle
  folder while reporting success. `ProjectIntake#place` is a third door onto that one
  policy, not a second copy of it.
- **THE SCANJOB ORDERING — INTAKE STRICTLY AFTER THE RECONCILE, SAME JOB — IS A
  CORRECTNESS CONSTRAINT, NOT A CONVENIENCE.** A move made after the Scanner has captured
  its observations gets paired back by `(content_hash, size)` — `best_pairing` working
  exactly as designed — which re-points the node to its OLD path while the bytes sit at
  the new one. In that window a download does NOT get the retryable 503 (`library_present?`
  still reads true): `Share#download`'s `ENOENT` maps to `NotFound`, and `FilesController`
  renders that as a TERMINAL 404. Running the intake inline in `Library::ScanJob`, right
  after `observer.call`, makes the overlap impossible instead of merely unlikely — the
  reason `Maker::ProjectIntakeJob`'s own schedule declines on scannable backends (next
  bullet).
- **TWO CAPS, DELIBERATELY NOT ONE.** `MAX_MOVES` (500) bounds an unattended run's CHURN
  and is absolute, not a percentage — the only honest denominator is "files currently at
  project roots," of which the intended first run files 100%, so a percentage would be
  guarding against SUCCESS. `EAGER_MAX_MOVES` (25) bounds request LATENCY for `.for_node`,
  the one entry point that runs inside a browser-facing request (the eager nudge) rather
  than an unattended job. Collapsing them would let one upload's response wait on the cost
  `MAX_MOVES` is willing to accept for a background job.
- **`EAGER_MAX_MOVES = 25` WAS MEASURED ON CHUNK / LOCAL SQLITE ONLY — NOT AN EVEN BOUND
  ACROSS BACKENDS.** On S3, `FileLayer::S3#move` is three sequential, unbatched network
  calls per file (a HEAD, a COPY, a DELETE), so the default is 25 × 3 = 75 sequential S3
  calls inside one browser-facing request. It stays 25 anyway — it fails toward SLOW, not
  WRONG, on every backend, and is operator-tunable via `PROJECT_ORGANIZE_EAGER_MAX_MOVES`
  — but an S3 deployment expecting large backlog uploads is the one where an operator
  should consider tuning it DOWN, not up.
- **A CALLER MUST READ `intake_project_folder`'S RETURN VALUE, NOT JUST TRIGGER ITS SIDE
  EFFECT.** Every caller threw it away until a review caught it: a same-named upload whose
  eager nudge lost a collision at its destination folder went from a refused write with a
  flash (before the eager nudge existed) to a silent "Uploaded x." with no sign the file
  stayed at the project root (after it, before this fix).
  `ProjectFolderIntake#left_unfiled_by_conflict?` / `#project_intake_notice` read the
  `:conflict` entry out of `Result#skips` for exactly this — but only in the two doors
  whose response a user actually sees (`FilesController#create`'s HTML branch,
  `Projects::UploadsController#create`); the JSON-only branches still run the intake and
  still file what they can, they just don't surface the fact, because nothing downstream
  reads that response key today.

---

## 15. Working agreements for the coding agent

- Permissive licenses only (§9); check new deps.
- **Keep bytes out of Rails** — presigned URLs, control plane only.
  **Active Storage's `direct_uploads` route is REMOVED**, because it was the one standing hole
  in this: `ActiveStorage::DirectUploadsController` descends from
  `ActiveStorage::BaseController`, **not** `ApplicationController`, so it shipped live and
  **unauthenticated** — an anonymous POST minted a real `Blob` and returned a signed upload
  URL. `config/routes.rb` shadows it with a 404. **The shadow path derives from
  `ActiveStorage.routes_prefix` and must never be hard-coded** (the engine scopes its own
  routes to that prefix, so a literal silently stops shadowing if it is ever configured), and
  `draw_routes = false` is NOT the fix — `Maker::Preview` uses `has_one_attached :asset`
  served via `url_for`, so the blob routes are load-bearing. Verify by driving a real request:
  `recognize_path` reports the engine's route for a proc endpoint and is the wrong instrument.
  Rich text is text-only on the server too (`Maker::TextOnlyRichText`), not just in the editor.
- **Local-first**: metadata reads hit local SQLite, never the WAN.
- Content-addressed chunks + immutable versions everywhere; **keep versions** for restore.
- Adapter-agnostic server code (SQLite + Postgres) without perf compromise.
- **MUTATION-CHECK EVERY GUARD YOU WRITE.** After a test that exists to *forbid* something goes
  green, break the thing it guards and confirm it goes **RED** — then restore. A guard that has
  never failed has not been shown to work. This is the cheapest defence against this repo's
  dominant failure mode, **a green suite over something that never worked**: the `scope:` form bug
  twice, the nine capability-gating tests that *could not fail for the reason they existed*,
  `FakeS3`'s inverse encoding (79/80 green over silent data loss), and the sidecar-licence guard
  whose discovery filter skipped the worse case. Every time someone did mutation-check, it paid
  immediately. `bin/ci` is ~40 s, so there is no budget argument.
  **Assert the narrowest true thing, then mutate to prove each assertion carries weight** — in
  `ArchitectureInvariantsTest`, a mutation that keeps the count at 1 while *moving* the reference
  is caught only by the second assertion; count alone would have passed.
- Write tests; verify end-to-end against the live server when wiring sync. Prefer a **probe
  over an argument** — §14e.

### Finishing work: commit, push, and open the PR without asking

On a **`claude/*` or other non-default branch**, when the work is complete and the gates are
green, **commit, push, and open a PR — do not stop to ask.** That is standing authorization;
treat it as the default close-out for a task, and use `/finish-branch` to run it.

- **Green means bare `bin/ci`** (all gates: style, scan, test, test-share, test-s3, system).
  The three test legs must report **identical** counts.
- **Merging always needs an explicit go-ahead.** Never merge, never `--admin`-merge, never
  push to `main`.
- If the gates are red or the work is partial, **stop and report** — do not open a PR to
  "get it reviewed".
- State plainly in the PR what was verified and what was not.

### CI

- **CI runs on SELF-HOSTED runners only — never GitHub-hosted.** Every job uses
  `runs-on: [self-hosted, linux|macos|windows]`. GitHub bills *only* hosted runners
  (`ubuntu/macos/windows-latest`; macOS 10×, Windows 2×); self-hosted are **free**. So
  **never add `*-latest`** to a workflow.
- **Only ONE runner is registered: `charless-MacBook-Pro-maker-mac` (macOS).**
  `flasher-maker-linux` and `CHAIMDESK-maker-windows` are **not** — verify with
  `gh api repos/:owner/:repo/actions/runners` rather than trusting this line, and note it
  needs an **admin-scoped** token: `administration` is not a permission a workflow
  `GITHUB_TOKEN` can be granted, so **it 403s from inside Actions** and works only from a
  developer shell.
- **`ci.yml`'s jobs therefore target `macos`**, and linux/windows jobs elsewhere are
  `if:`-gated on the repo variable **`CI_RUNNERS`** via `ci/preflight.sh`, so a job whose
  runner is absent is never *scheduled*. That gate fixed a five-week outage: a job matching no
  online runner does **not** fail — it queues 24 h at 0 elapsed and is auto-cancelled, which
  is why a PR sat UNSTABLE and merging needed `--admin`. **Linux and Windows coverage is
  skipped, not passing.**
- **`ruby/setup-ruby` must NOT appear in a `macos` job** — it assumes a hosted
  `/Users/runner` layout this box lacks; the runner's PATH has mise ruby 3.4.7 matching
  `.ruby-version`, so `bundle install --quiet` suffices. `test/ci_hygiene_test.rb` fails if it
  reappears, and guards four other workflow invariants besides.
- Self-hosted machines are persistent: make dep-install steps idempotent and don't assume the
  clean toolchain of a hosted image.

### Keeping the docs honest

- **`docs/STATUS.md` is where an arc gets narrated. This file is not.** Add dates, branch
  names, suite counts and per-phase detail there.
- **What belongs HERE is an invariant** — something a future editor could undo by accident.
  Put it in §14, one line, with the consequence named. If it needs a paragraph of story to
  justify, the story goes in STATUS.md and the rule comes here.
- Update this file **and** `docs/STATUS.md` when the architecture moves.
