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

# SECRETS: no `export` before a deploy. `bin/secret VAR op://tinkerex/Item/field` resolves
# every credential (exported shell value wins, else 1Password) and backs each .kamal/secrets*
# file. ALWAYS preflight first — kamal expands `$(…)` through Ruby BACKTICKS, which discard
# exit status, so an unreadable secret becomes an EMPTY one that deploys silently (§14g):
bin/secrets-preflight --all      # or: (omit) | s3 | share | ovh

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
- **`write(..., replace: true)` IS AN OPT-IN BESIDE THE CLOBBER REFUSAL, NOT A RELAXATION OF IT.**
  The refusal is still the default on both writable adapters and every existing caller omits the
  kwarg; `replace:` exists for a door that has just asked a user "this would replace `design/x.svg`
  — overwrite?" and been told yes. **It MUST reuse the existing node.** A replace written as
  delete-then-create passes any bytes-oriented test while orphaning every attachment, BOM link and
  tag — the landmine two bullets down, whose signature is that nothing errors and nothing logs.
  Pinned in `adapter_write_contract.rb` beside the clobber test, asserting **`node_id` survives**,
  not merely the content. Cheap on both backends because each already had the hard part: Share's
  temp-then-rename is atomic over an existing destination and `put_object` overwrites by definition,
  so a replace **skips** work rather than adding it. **The two adapters resolve "the file being
  replaced" DIFFERENTLY and must keep doing so** — the port asks by `storage_path` (what it derived
  the destination from), chunk's `LibraryOutput#existing_at` asks by `(parent, name)` because chunk
  nodes have no `storage_path` at all. A test fixture built with `nodes.create!` has a NULL
  `storage_path`, which cannot exist on share/s3: the lookup misses, a second node is created, and
  the leg splits chunk-green / share-red.
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
- **Addons are manifest-driven, not listed in this repo.** `Maker::Addons::Registry` builds
  `Addon`s from manifests fetched by `Maker::Addons::Source` and caches the index (`CACHE_KEY`,
  5-minute `TTL`) — republishing a bundle *is* the deploy. Three refusals matter: a manifest
  missing a `REQUIRED` key or declaring an `api_version` other than `Registry::API_VERSION` is
  **skipped, not raised on** — one bad addon must never take `/tools` down (the `api_version` arm
  is mutation-checked); and a source outage returns `[]` for **that request only**, because the
  `rescue` sits **outside** `Rails.cache.fetch` — inside, a two-second blip greys every addon out
  for the whole TTL (also mutation-checked, and only against a real `MemoryStore`: the suite's
  default `:null_store` can't observe caching at all — same shape as §14e's rate-limiting note).
- **ONE generic surface serves every addon** — `Tools::AddonsController` (shell / same-origin
  asset proxy / save), which is why a new addon needs no Rails redeploy. **Route order is
  load-bearing**: `tools/:key` matches any two-segment `/tools/*` path and collides with the
  sibling addon routes above it, mutation-checked by moving it above `resources :boxes` and
  watching `boxes_controller_test.rb` go from green to 12 failures + 2 errors. It does **not**
  collide with `tools/addon_states/:id/params` (four segments; Rails requires a segment-count
  match) — an earlier draft of the routes comment claimed it did and was verified false via
  `Rails.application.routes.recognize_path`.
- **Asset paths are REJECTED, never normalized** (§14a's `key_for` rule) — one guard,
  `Source.validate_asset_path!`, shared by the HTTP and local (`Source::Local`, dev/test)
  backends. The controller-level traversal test passed under mutation until the fake was seeded
  with a file the traversal would actually *reach*: asserting only a 404 proved nothing, because
  "refused" and "not found" both produce one. `Source::Local`'s own test had the same false-green
  shape one layer down — `Pathname#join` doesn't sanitize `..` the way a URL does, so a made-up
  escape target just happened not to exist on disk; the fix plants a real file outside the source
  root and proves it unreachable, not coincidentally missing.
- **`skip_forgery_protection only: :asset`** — needed because `verify_same_origin_request`
  (an `append_after_action`, not skipped by this) fires unconditionally on any non-XHR JS
  response, which is exactly what a `<script type="module" src>` load looks like; skipping the
  `verify_authenticity_token` before_action is what stops the request from ever being marked for
  that check, since marking only happens there. On a GET-only action the CSRF-token check itself
  was already a no-op (GET is exempt), so the skip's sole practical effect is disabling that
  cross-origin-JS guard. Residual, stated plainly: the endpoint stays behind `authenticate_user!`,
  so a cross-origin `<script src>` remains a login-state / addon-inventory oracle (200 vs 404 via
  `onload`/`onerror`, no response bytes leak). Whether to close that residual is a product
  decision, not one this comment makes.
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
- **Addon bundles are served by the `addons` Kamal accessory** (`chaim354/tinkerex-addons`), not
  shipped inside the Rails image — **publishing the bundle image IS the addon deploy; Rails is
  never rebuilt.** `deploy.yml` sets `ADDON_SOURCE_URL: http://tinkerex-addons`. Read the
  precedence carefully, because the obvious story is backwards: `Source.current` gives
  **`ADDON_SOURCE_PATH` precedence over `ADDON_SOURCE_URL`** when both are set (the safer
  failure mode — a stray URL left in a dev/test env can never make a local run hit the network
  by surprise). What actually turns production onto the accessory is that **the PATH default
  itself is conditional**: both `production.rb` and `development.rb` only default
  `ADDON_SOURCE_PATH` `if ADDON_SOURCE_URL.blank?`, so PATH is never set alongside a real URL.
  An *unconditional* PATH default would leave PATH always set in production too — and since PATH
  wins whenever both are present, the accessory would run and answer requests while Rails
  silently never called it. That conditional default, not a URL-beats-PATH rule, is the whole
  cutover.
- **`ADDON_SOURCE_URL` MUST be blanked in `deploy.ovh.yml`** — same rule, same reason, as the two
  sidecar URLs above: Kamal deep-merges `env.clear`, so OVH would otherwise inherit the
  Unraid-only `tinkerex-addons` hostname, `Source.configured?` would read true, and every fetch
  would fail instead of the gallery merely greying out. It does **not** match the `_SIDECAR_URL`
  suffix the guard originally grepped for, and was silently unguarded until
  `test/deploy_hygiene_test.rb`'s pattern was widened to `/_SIDECAR_URL\z|\AADDON_SOURCE_URL\z/`
  — **any future accessory URL needs the same manual addition**, because the guard covers a
  naming convention, not a category. Consequence for OVH today: an **empty tools gallery**,
  degrading through `Registry`'s rescue rather than 500ing, until OVH gets its own addons
  accessory.
- **The addon system test is hermetic by fixture, deliberately.**
  `test/system/addon_bundle_test.rb` reads `test/fixtures/addons/`, never the real bundle —
  pointing it at the `tinkerex-addons` repo's working copy (the dev-default assumption: checked
  out as a sibling) would make CI depend on a repo a fresh clone never has. The fixture's entry
  module imports from a **pinned bare specifier** (`fixture-dep`, declared in its own manifest's
  `pins`) and renders that module's exported value into the DOM, so a pass proves the
  **merged importmap** actually resolved a bare specifier through the proxy — not merely that
  the entry module itself loaded. Mutation-checked: blanking `pins` in the fixture manifest
  turns it red.
- **The service proxy ALLOWLISTS content types, and `image/svg+xml` is deliberately NOT on it**
  — the entry most likely to be "restored", because SVG is the box generator's main output.
  `#service` used to echo the sidecar's `Content-Type` verbatim `inline`, a same-origin
  script-execution channel: the route is `via: %i[get post]` while boxes' `/generate` is
  POST-only, so a plain GET returns **Werkzeug's 405 page as `text/html`** under our origin.
  SVG is script-capable and `nosniff` does not help it. Excluding it costs the generator
  **nothing** — `preview.js` reads the render with `fetch()` + `res.text()` and re-encodes it as
  a `data:` URL, and neither header affects a `fetch()` body. Two entries are load-bearing the
  other way and must stay INLINE: **`image/jpeg`** (`gallery.js` points an `<img src>` straight
  at this proxy for sample photos) and **`application/json`** (`preview.js` branches on a JSON
  content-type to read a sidecar's error message). Unlisted types degrade to
  `octet-stream` + `attachment` rather than 415, so a sidecar upgrade can't become an outage. If
  a future bundle needs an SVG in an `<img src>`, add it back **with a
  `Content-Security-Policy: sandbox` response header**, not by relaxing the list.
- **An addon save validates its filenames AT THE DOOR, backend-neutrally** —
  `Maker::MoveNode.valid_leaf_name?` in `parse_files`, not inside any adapter. Share and S3 each
  refuse a traversing name in their own `leaf!`; **chunk has no name check anywhere** (
  `Sync::Commit.begin` validates the manifest exhaustively and the name not at all, and `Node`
  validates `name` for **presence only**), so `"../../escape.txt"` created a live node on the
  main deployment, bound for the changelog and every device mount. A guard that exists on two
  backends and silently does not on the third is this repo's recorded failure shape — the fix is
  the door, never a third copy in the chunk adapter. The save also pre-checks destination names
  (a CHECK, not a lock) so chunk stops creating two same-named siblings in one directory, and
  `Tools::AddonsController` maps `UnsupportedOperation`/`FetchError`/`NotFound` **once** via
  `rescue_from` — as JSON with a real status, NOT a redirect-with-flash, because the only caller
  is a `fetch()` that branches on `res.ok` and **fetch follows a 302**, so answering an error the
  way success is answered reports "Saved." over a save that never happened.

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
- **EVERY REFCOUNT WRITE GOES THROUGH `Sync::Gc.touch_refcounts!`, never a bare `update_all`** —
  because `update_all` does not maintain timestamps, and `Gc.sweep_orphans!`'s grace window
  filters on `updated_at`. With the column only ever written at `insert_all` time the filter
  tested the chunk's **CREATION age, not its ZEROING age**, so for any chunk older than the
  window — i.e. **every real chunk** — the protection the sweep's own contract promises did not
  exist. Four sites (`gc`, `commit`, `restore`, `conflicts`). Two ordering rules go with it, and
  neither is decoration: `sweep_orphans!` **deletes compare-and-swap**
  (`where(id:, refcount: ..0).delete_all == 1` before the byte delete), because it takes NO user
  lock and its batch is a snapshot a concurrent `Commit#finalize` can re-reference **0 → 1 while
  uploading nothing** (it deduped against the row) — leaving a live version pointing at a chunk
  with no row and no bytes; and `prune_version!` is **claim-then-decrement** (delete the version
  row, decrement only if it removed 1), so two overlapping retention passes cannot decrement
  twice for one removal. The `WHERE refcount > 0` guard prevents a NEGATIVE refcount, which was
  never the bug. Failure mode throughout: **silent permanent data loss**, managed/tiered only
  (`keep_all` never decrements). Beware the test shape that hid it — every sweep test hand-set
  `updated_at` via `update_column`, and the "within grace" one used a chunk created moments
  earlier, so it passed either way.
- **`config.active_storage.variant_processor = :disabled`, and it must stay that way.**
  `load_defaults 8.1` sets it to `:vips`, which loads `ImageProcessing::Vips` → `ruby-vips` at
  boot. This app deliberately ships **no `ruby-vips`**: every thumbnail shells out to the
  `vipsthumbnail` BINARY, precisely so there is no in-process libvips thread pool to deadlock the
  fork-based parallel test runner. That was silently inert until activestorage **8.1.3.1** (the
  CVE-2026-66066 fix) added an eager `require "image_processing/vips"`, whose LoadError message
  ("ImageProcessing::Vips requires the ruby-vips gem") matches **neither** arm of the engine's own
  `rescue` (`/libvips/`, `/image_processing/` — note the underscore), so it re-raised and **took
  the whole boot down**. `:disabled` is the engine's supported answer and removes that CVE's code
  path STRUCTURALLY rather than leaving it merely unreachable by argument. **Do not "fix" this by
  adding `ruby-vips`** — that reintroduces the deadlock the subprocess design exists to avoid.
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
  `frame-ancestors` consistent with `X-Frame-Options` (`SAMEORIGIN` → `'self'`).
- **Query cost is a property nothing asserts unless you assert it.** `projects#show` went from
  flat to +1 query per build-log entry when rich text arrived and the eager load was not extended
  — invisible to a green suite, while `models#show` carried the correct pattern the whole time.
  Guards live in `test/integration/web/page_query_budget_test.rb` and assert **constancy in N**,
  never a literal: the counts differ per `LIBRARY_BACKEND`, so a literal pins one leg and fails
  the other two.
- **AN APP MUST NOT POINT A SYNCHRONOUS HTTP CLIENT AT ITSELF.** Serving addon bundles from this
  app's own `public/` over `ADDON_SOURCE_URL` made every asset fetch a **nested** request into the
  same Puma pool already servicing the outer one — reentrancy, not just extra load. Measured, not
  theorized: the `generators` bundle's own module graph (2 sequential fetches, then 4 of makerjs's
  bare-specifier deps fetched at once by the browser) against a stock 3-4-thread dev/Capybara Puma
  pool stalled most requests **14-24 seconds**, and several outright **404'd** — `Net::HTTP`'s own
  read timeout firing before a thread ever freed up. Fixed by `ADDON_SOURCE_PATH`
  (`Maker::Addons::Source::Local`), which reads `public/addons` straight off disk in dev/test;
  `ADDON_SOURCE_URL` (HTTP) stays for Phase B's genuinely separate static container, which has its
  own pool and is structurally immune to this. A second, smaller effect in the same area: even
  `Source::Local` needs more than Puma's stock `threads 3, 3` in a real `bin/rails server`, because
  `config.enable_reloading = true`'s per-request interlock adds overhead a page firing several
  near-simultaneous asset requests can expose — `RAILS_MAX_THREADS=16` fixed it; production
  (eager-loaded) and the test env (`enable_reloading = false`) don't carry that overhead.

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
- **`:attached_elsewhere` IS THE ONE RULE THAT DOES NOT TRANSFER TO THE INTAKE, and it is
  scoped AT `#refusal_for` (`within_own_folder:`), never by `#place` filtering the answer.**
  Its stated reason is positional — "yanked out of the folder that project put it in" — and
  `#place`'s move is `Projects/<slug>/x` → `Projects/<slug>/<cat>/x`, so there is no other
  project's folder to yank it out of; `node_id` never changes, so the other project's
  attachment survives. Unscoped it was **silent and permanent**: a file any second project
  also claimed sat at the root through every 15-minute sweep forever, recorded only in a
  `skips` entry nothing but `rake projects:organize` prints. Reachable without doing
  anything unusual — `CurrentProject#attach_addon_files_to_current_project` attaches an
  addon's output to whatever project is **current**, regardless of which folder the save
  dialog wrote it into. `:not_a_file` and `:model_bundle` stay unconditional: the bundle
  rule is deliberately about the ATTACHMENT rather than the folder, so it makes no claim
  about where the file currently sits and has no equivalent argument for relaxing.
- **TWO COLLISION CHECKS, AGAINST TWO DIFFERENT FOLDERS, AND THE GAP BETWEEN THEM WAS A REAL BUG.**
  A door's own check (`refuse_taken_names!`) asks about the folder the user **picked** and is
  terminal ("pick another name" → **422** `unsupported_operation`). `Maker::ProjectIntake
  .destination_for` asks about the **category folder** the sweep will file into, and is answerable
  ("overwrite?" → **409** `would_replace`). A re-save goes straight through the gap: the first copy
  has already been filed, so the picked folder is vacant, the door accepts, and the sweep then
  cannot place the second copy — which sits at the project root **forever**, with two copies of one
  drawing in the library. That is CLAUDE.md §12 item 11 in the wild (`harbor-number-v4.svg`, saved
  twice, while v3 and v5 sorted fine). **Keep 409 and 422 distinct**: a bundle must be able to tell
  "never succeeds on retry" from "say yes and it will", or it offers an Overwrite button for a save
  that can never take one. `destination_for` **creates nothing** — looking up a category folder must
  not mkdir it (`#relocate`'s recorded bug) — and takes its folder name from
  `Maker::ProjectFolders.folder_for`, the same pure function `#place` uses, so prediction and
  behaviour cannot disagree.
- **`Tools::OpenscadController#create` CANNOT REACH THAT BUG, and the guard is on the property that
  makes it so** — its output name embeds `state.id`, a fresh autoincrement per save, so two saves of
  one design under one name still produce two filenames. A confirm dialog there would be UI for an
  unreachable branch. Drop `state.id` from the name and `openscad_controller_test.rb` goes red,
  which is exactly when that door needs what the other one has.
- **EVERY ADDON SAVE DOOR FIRES THE EAGER NUDGE — there are TWO of them**
  (`Tools::AddonsController#create`, `Tools::OpenscadController#create`), and the concern is
  included on `Tools::BaseController` so a third inherits it. This was the last
  browser-facing door without one: the save dialog DEFAULTS to the current project's folder,
  so the user watched the redirect land on a file that visibly did not sort — 15 minutes on
  chunk, and on share/s3 there is no `project_folder_intake` schedule at all
  (`ProjectIntakeJob.sweep_all!` declines on a scannable backend), so it waits on
  `Library::ScanJob`'s poll. **ONE sweep per save, not one per file** (every file in a save
  shares `parent_node_id` and `.for_node` sweeps the owning PROJECT), **after** the attach
  per `ProjectFolderIntake`'s call-site rule. The conflict clause has one home,
  `#project_intake_sentence` — the doors differ on the LEAD-IN ("Uploaded grid.svg" vs
  "Saved “X”") and must not differ on what follows — and `#unfiled_by_conflict` is its plural
  form, because a save writes a SET and the colliding output need not be the first.
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
  `:conflict` entry out of `Result#skips` for exactly this — but only in the **four** doors
  whose response a user actually sees (`FilesController#create`'s HTML branch,
  `Projects::UploadsController#create`, and both addon save doors); the JSON-only branches
  still run the intake and still file what they can, they just don't surface the fact,
  because nothing downstream reads that response key today.

### 14g. Deploy secrets

- **KAMAL CANNOT NOTICE AN UNREADABLE SECRET, SO `bin/secrets-preflight` IS NOT OPTIONAL.** It
  expands `$(…)` in `.kamal/secrets*` through Ruby **backticks, which discard exit status** — a
  locked vault makes `bin/secret` exit 1, the substitution yields `""`, and `Kamal::Secrets#[]`
  returns that empty string **without raising**. A *missing* key raises; an *empty* one does not,
  so the failure surfaces later and elsewhere (an empty `KAMAL_REGISTRY_PASSWORD` becomes a
  confusing `docker login` error — once reported as exit 0 here). Verified against kamal 2.11.
- **SECRETS ARE PER-DESTINATION, AND `.kamal/secrets` IS THE *BASE* FILE, NOT A SHARED ONE.** Kamal
  reads `[secrets-common, secrets.<dest>]`, so anything added to `.kamal/secrets` is invisible
  under `-d`. Required, not tidiness: `CHUNK_SECRET_ACCESS_KEY` is **SeaweedFS on Unraid and
  Cloudflare R2 on OVH** — one name, two credentials, which `secrets-common` cannot tell apart.
- **ONLY UNIVERSALLY-REQUIRED KEYS MAY LIVE IN `secrets-common`.** `InlineCommandSubstitution` runs
  every `$(…)` in a parsed file **eagerly**, not lazily per key, so a credential parked there makes
  `-d share` shell out for something a share container never holds. Guarded, mutation-checked, in
  `test/deploy_hygiene_test.rb` — which is **static** (no vault needed, passes on a bare runner).
- **`op read` NEEDS NO SECOND CODE PATH FOR UNATTENDED RUNS** — it uses `OP_SERVICE_ACCOUNT_TOKEN`
  when set and desktop/biometric auth when not. Items live in the **`tinkerex` vault, never
  `Personal`**: 1Password *refuses* to grant a service account access to a Personal/Private vault,
  so `op://Personal/…` failing is by design, not a broken vault.
- **EVERY SECRET FAILING AT ONCE MEANS THE TOKEN EXPIRED — DON'T DEBUG THE REPO.** The token
  reaches the process through the environment and so is invisible to this tree: nothing here can
  be edited to fix it, and `git log` will show nothing that broke it. Re-mint per `docs/DEPLOY.md`.
  **ONE secret failing is the opposite diagnosis** — a wrong ref or field name in that single
  `.kamal/secrets*` line. `bin/secrets-preflight --all` tells the two apart at a glance, and prints
  which auth path is in use.
- **NEVER `op read "$ref" 2>&1 >/dev/null`** — the redirection order LEAKS the value (`2>&1` points
  fd2 at the captured stdout *before* `>/dev/null` moves fd1). It printed a live ghcr PAT into a
  transcript and forced a rotation. `bin/secret` keeps the value on fd1 only.
- **`kamal deploy` WARNS ON AN UNCOMMITTED TREE, IT DOES NOT REFUSE** (`say "Building with
  uncommitted changes"`, yellow), and this repo sets no `builder: clone:` — so the image is built
  from the **working tree** and whatever is half-finished in it ships. Check `git status` first.

### 14h. LightBurn shape measurement

- **EVERY REPORTED NUMBER COMES FROM FULL-RESOLUTION POINTS; THINNING IS DRAWING-ONLY.**
  `LbrnGeometry` simplifies contours to keep the payload small (the worst real file drops
  728 KB → 200 KB gzipped) and computes `b` and `d` **before** thinning. Measure after thinning and
  every curve under-reports, silently, while every "does it draw" test stays green. `d` is the
  sharper case: a 0.2 mm hole thins to 9 points, below `MIN_CIRCLE_POINTS`, so measuring after
  would drop its diameter entirely and report a bare bounding box instead of "⌀0.2 mm".
- **THINNING IS BOUNDED BY GEOMETRIC ERROR, NEVER BY POSITION IN THE ARRAY.** `simplify` is
  Ramer-Douglas-Peucker against `SIMPLIFY_TOLERANCE` (0.01 mm). **Do not replace it with an index
  stride** — that is what shipped first, and it was wrong: `Lbrn2.polylines` appends 12 points per
  `B` (bezier) segment and exactly **ONE** per `L` (straight) segment, so a single straight edge
  shifts every later index and no vertex lands where a stride expects. For an `L` segment that one
  point IS a vertex, so dropping it cuts the corner off entirely. Measured over the corpus before
  the fix: **1148 of 5259 thinned contours displaced by more than 5% of their own size, worst case
  58.7 mm.** RDP keeps a corner by construction (a corner is the farthest point from any chord
  spanning it) and is also *smaller* — 200 KB worst case against the stride's 281 KB.
  - The stride's justification, `BEZIER_SAMPLES % DECIMATE_STRIDE == 0`, was **true but only for
    an all-bezier contour**, and `bezier-circle.lbrn2` is exactly that (`B0 1B1 2B2 3B3 0`) — so
    the guard asserting it passed while real mixed-geometry files were being mangled. If you find
    yourself proving a property on that fixture, check it on a contour with an `L` op too.
- **THE PAYLOAD'S BBOXES MUST UNION TO `Lbrn2.job_size`** — one traversal, so the Measure view and
  the Laser Settings panel cannot disagree; §14b's `LbrnMetadata` second-copy bug is the precedent.
  But **a union is the weakest possible form of that assertion** and cannot catch a
  measure-after-thinning bug: any per-shape error some other shape already bounds disappears into
  it. It stayed green on three separate fixtures. The guard with teeth is **per-shape**, on a
  fixture whose ellipse is not shadowed by a larger Rect.
- **CIRCULARITY NEEDS THE 12-POINT FLOOR, NOT JUST THE RADIUS TEST.** A square's four corners are
  all equidistant from its centre — as are any regular polygon's vertices — so radius variance
  alone calls every square round. Measured: a `Rect` emits 5 points with radial spread **0.00000**
  while a real bezier circle's 49 points spread **0.00263**, so the naive metric ranks the square
  as *more* circular. A `Rect` emits 5, a bezier circle 49, an `Ellipse` 33. Accepted consequence:
  a genuine 16-gon reports as round. `bezier-circle.lbrn2` pins both directions and **the square is
  the assertion that carries the weight**.
- **`each_geometry`'s 6th yielded value (`object_id`) counts NON-GROUP `<Shape>`s, and a Text's
  `<BackupPath>` REUSES its parent's** — the outline *is* the text, so alt-clicking one letter must
  report the whole word. A Group consumes no id. **Ids are DISTINCT PER OBJECT and nothing more —
  never assume contiguity**: a shape that yields nothing (a Rect without W/H, an Ellipse without
  Rx/Ry, a Text with no BackupPath) still spends a tick, so gaps are ordinary in a real file.
- **Bitmap base64 is EXCLUDED from the geometry payload, deliberately.** It is the single reason
  the payload is cheap: `metal test 5.lbrn2` is 1.45 MB gzipped as SVG and 0.1 KB as geometry JSON.
  A measuring view needs the rectangle, not the photo. Restoring it re-inflates every
  photo-engraving file by three orders of magnitude. `rake lbrn:geometry_report` is what notices —
  no fixture is big enough to.
- **A CORRUPT DOCUMENT RAISES; AN EMPTY ONE DOES NOT.** `LbrnGeometry` raises `ParseError` when
  `doc.root` is nil, matching `to_svg`, so the job marks it `failed`. A document that parses with no
  shapes returns the empty payload and goes `ready`. Collapse them and a corrupt file presents as a
  working Measure view reading "No measurable geometry in this file" — a lie about the file.
- **`geometry` IS THE FIRST KIND TO EXERCISE THE PREVIEW `kind` SEAM END TO END.** `model_glb` is
  declared in `Preview::KINDS` but refused by `Mesh`, so nothing produced a second artifact from one
  file until this. `RendererContractTest` still passes because its `render_with` never sends
  `kind:` — it exercises the thumbnail path, where "must be an inline-safe raster" stays true.
- **A PREVIEW IS STALE ON TWO INDEPENDENT AXES, AND `version_id` IS ONLY THE FIRST.** It asks
  whether an artifact was made from the file's current CONTENT; `renderer_revision` asks whether it
  was made by the current CODE. With only the first, a payload change invalidated **nothing** —
  a finished design's content never changes — so the .lbrn2 thinning fix deployed and four
  already-measured files kept serving mangled curves until they were destroyed by hand, on the one
  backend of three that had them. **Change a payload → bump the renderer's `PAYLOAD_REVISION`.**
  - **Revisions are PER KIND** (`Lbrn2.payload_revision(kind)`): one renderer emits both a
    thumbnail and a geometry payload, and bumping geometry must not rebuild ~1400 thumbnails as a
    side effect of an unrelated fix.
  - **`renderer_revision` is `NOT NULL DEFAULT 1`, and both halves are load-bearing.** Nullable, a
    NULL would differ from every declared revision, so adding the column would itself have
    triggered a full-library re-render; and `Enqueue` is **not** the only creator —
    `V1::Maker::PreviewsController` builds rows via `find_or_initialize_by`, which with no default
    would leave them stale forever, re-enqueueing on every request.
  - **`SCHEMA_VERSION` is NOT this**, and is the easy thing to bump by mistake. It is the wire
    contract the JS checks; `PAYLOAD_REVISION` is the server-side cache key. Revision 2 changed
    every coordinate while touching no key, so the schema was rightly left alone.
- **`FilesController#geometry` READS THE EXISTING PREVIEW ROW BEFORE CALLING `Enqueue`.** `Enqueue`
  resets a `failed` row to `pending` and re-enqueues *whenever called* — right for a one-shot nudge
  at upload time, wrong for a poll. Unconditional, it makes the action's own `"failed"` branch
  **dead code** and re-enqueues a doomed render on every poll of a broken file. Accepted: a `failed`
  geometry preview is terminal until the content changes, which is honest because a transient
  byte-store failure is a `FetchError` that leaves the row `processing` and self-heals.
- **`#geometry` RESCUES `RecordNotFound` LOCALLY**, because the class-level `rescue_from` branches
  on format and answers a plain `get` — html, the default with no Accept header — with a **302 to
  `files_path`**. Right for `#show`/`#blob`, which render a page; wrong for a JSON poller, which
  would read a redirect body carrying neither a status key nor a 404.
- **The Measure view builds its SVG with `createElementNS`, never `innerHTML`.**
  `Maker::Previews::Svg` rasterizes precisely because the web layer refuses to inline SVG;
  constructing elements from parsed coordinates sidesteps that rule rather than excepting it.
- **Hit-testing is PAINT ORDER, not geometry.** Contours are appended in DESCENDING bbox-area order
  so the browser's own topmost-wins dispatch selects the hole rather than the plate around it.
  There is no point-in-polygon code; reversing that sort silently makes every small feature inside
  a larger one unclickable, while drawing an identical picture. Pinned by
  `nested-plate.lbrn2` — a plate and a hole on a SHARED CENTRE, clicked at the SVG element's own
  centre so paint order alone decides the answer. `bezier-circle.lbrn2` cannot test this and the
  gap went unclosed for a while because of it: its two shapes are equal-area AND disjoint, so
  neither ever covers the other.
- **LIGHTBURN'S LAYER PALETTE IS A HARD-CODED TABLE, AND THAT WAS RELITIGATED ON PURPOSE.** §14's
  earlier note refused one, on the grounds it would mean "30 colours guessed from thumbnails". The
  Measure view changed the calculus — it draws OUR outlines, where the file's own render is
  unavailable and the alternative is flat black — and the values are no longer guesses: most were
  RECOVERED from the embedded thumbnails by mapping contours into pixel space and reading what
  LightBurn painted. `Lbrn2::LAYER_PALETTE` marks each entry `measured` or `palette strip`. It is
  cosmetic by construction: nothing measures or decides anything from it.
- **THE PALETTE HAS ONE DEFINITION, SERVER-SIDE.** The geometry payload carries a `colors` map for
  the layers a file uses, rather than the client looking indices up in a copy — §14d's third
  extension→role table is the precedent for what a second copy does. It also means a file that DOES
  override a layer's colour is honoured without the client knowing that is possible.
- **THE LAYER COLOUR IS AN SVG PRESENTATION ATTRIBUTE, NEVER `node.style`, AND `.lbrn-contour` MUST
  NOT DECLARE A STROKE.** Presentation attributes sit BELOW every CSS rule, which is exactly what
  lets `--hover`/`--selected` recolour a contour. Set it inline instead and selection silently stops
  changing colour (only width moves); give `.lbrn-contour` a stroke and every layer flattens to one
  colour. Both directions are mutation-checked, and both need the COMPUTED style asserted — reading
  the attribute reports what we wrote even when a rule outranks it.
- **The pan/click slop is in SCREEN PIXELS, not user units.** Zoomed in, one mm is many pixels, so a
  user-space threshold calls an ordinary click a drag and silently swallows the selection.

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
