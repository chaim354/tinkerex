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
- The filesystem surface is a **native mount**, per-OS over the same `Provider`: **Linux**
  FUSE, **Windows** CfAPI (driverless Cloud Filter, the default), **macOS** WebDAV (native
  `mount_webdav`). All three live. (macOS FSKit / Windows File-Provider are future polish.)

This is a **sync engine, not a mount**. Versioning + dedup are native (a version = a
content-addressed manifest sharing chunks).

---

## 3. Components (what's built)

| Component | Path | Role |
|---|---|---|
| **fs-provider** | `client/fs-provider` | Local SQLite tree + content-addressed FastCDC chunk store. `export_tree`/`apply_remote` for sync. Node kinds: File/Dir/**Symlink** (symlink target synced; git-on-mount works — `docs/git-on-mount.md`). |
| **fs-fuse** | `client/fs-fuse` | FUSE adapter (**Linux** mount path) over `Provider`. Verified live. (macOS uses `fs-webdav` — FUSE-T can't mount on macOS 26.) |
| **fs-winfsp** | `client/fs-winfsp` | WinFsp adapter (**Windows** mount path) over the **same** `Provider`. **Verified: mounts a drive letter + syncs** via the app. Needs `winfsp-x64.dll` on PATH at runtime (or bundled). |
| **fs-cfapi** | `client/fs-cfapi` | **CfAPI** adapter — the **driverless** Windows path (Cloud Filter API, no GPL driver; the OneDrive model: sync-root folder + on-demand hydration). **Verified live on Windows 11**: register + on-demand enumerate (FETCH_PLACEHOLDERS) + hydrate-on-open (FETCH_DATA) + remote-change invalidation + **local-edit capture** (NOTIFY_FILE_CLOSE → ingest → push) + offline-persistent hydrated files. **Now the DEFAULT Windows backend** (flipped 2026-06-14; Phase 2b complete): new-file capture (ReadDirectoryChangesW watcher) + delete + rename all propagate, **live smoke + byte-for-byte conformance green** against the deployed server. `fs-winfsp` stays behind the `winfsp-backend` cargo feature for one release. See `docs/plan-windows-cfapi-migration.md`, `docs/cfapi-write-path-findings.md`. |
| **fs-webdav** | `client/fs-webdav` | WebDAV adapter (`dav-server`) over the **same** `Provider` — the **macOS** mount path (native `mount_webdav`, no FUSE/kext/FSKit). Cross-platform; verified live on macOS 26. |
| **sync-client** | `client/sync-client` | Typed server API client + chunk transfer (presigned PUT/GET) + pull-apply (`LocalTree`). |
| **sync-engine** | `client/sync-engine` | The daemon: `push`/`pull`/`hydrate`/`sync_once`. Pluggable `ChunkIO` (shared-dir for tests, presigned for R2/SeaweedFS). |
| **server** | repo root (Rails 8) | Source of truth: models, `Sync::*` services, v1 API, ActionCable. |
| **FileLayer port** | `app/services/file_layer/` | The seam between the **maker layer** and whatever holds the bytes, selected per deployment by `LIBRARY_BACKEND` (mirrors `Storage::ChunkStore.current`). **All three adapters are built:** `Chunk` (version→manifest→chunk; versioned, syncable), **`Share`** (a mounted SMB/NFS dir) and **`S3`** (the user's own bucket, phase 3) — share and s3 are both **current-state only**: no versions, no history, no restore. **The reads are `stat`/**`stat_all`**/`read`/**`download`**/**`trashed`** — every adapter answers all five. **`stat_all(user, node_ids:)` -> a Hash keyed by node_id** is the BULK read a browse view needs: looping `stat` was a measured N+1 (2000 nodes = 4000 queries / 527ms on chunk), and a **missing node is an ABSENT KEY, not a raise** — `stat` is asked about one node so NotFound is its whole answer, while a bulk caller holds a list and one row tombstoned mid-page must not 404 the page. **The write path is Share + S3** (`write`/`delete`/`move`/**`undelete`**): chunk-mode writes belong to the **sync engine**, so `Chunk` refuses them **per-op, naming the real door each time** — `write` → `Sync::Commit`'s two-phase flow, `delete` → **`Sync::SubtreeDelete.call`** (cascades the tombstone to the subtree; `Sync::Mutation.apply, op: "delete"` tombstones only the node it's given and orphans descendants), `move` → `Sync::Mutation.apply, op: "move"`. **One shared refusal message is how an earlier draft told delete/move callers to use `Sync::Commit`, which has neither path** — keep them separate. **`S3` is the one backend where `presignable` is TRUE and `versioned` is FALSE**, and that combination is its point, not an oversight: §15 (bytes out of Rails) **survives** here — a bucket has a URL signer, which is exactly what a mounted directory lacks — while §5 (keep versions) does **not**. The other two have the pair agreeing (chunk true/true, share false/false), so S3 is the counterexample that forbids collapsing one into the other. **Both `delete` and `move` refuse directories on S3**, diverging from Share, which allows dir *moves* — Share's permission rests entirely on `rename()` being one atomic syscall that carries the bytes, and here there is no directory and no rename (a dir node's key simply does not exist). `Maker::FileBytes` is a 19-line shim over it — the maker layer no longer knows files are chunks. **Two contracts** stop the adapters diverging, both in the default suite: `adapter_contract.rb` (read — now runs against **all three**, and since phase 4 it **pins every capability to what the adapter actually does**, so a hand-written `Data` literal cannot lie about its own backend) and `adapter_write_contract.rb` (`FileLayerWritableContract` — `Share` **and `S3`**; inheriting it was the whole purpose of phase 3, and it had already caught that phase 3's plan was missing `write`'s clobber guard). **`download(user, node_id:, disposition:, content_type: nil)` answers a `Delivery`** — `Redirect(url)` (chunk single-chunk + s3; §15 holds) / `SendFile(path)` (share; §15 cannot) / `Stream(enum)` (chunk multi-chunk) — and `FilesController` consumes it **without ever constructing a path**. **`disposition:` is required, not defaulted**: nil makes `ContentDisposition.format` emit a header with *no disposition type*, which browsers resolve as **inline** — a silent cross-backend divergence, on S3 only, where the value is signed into the URL. `Chunk#trashed` **delegates to `Sync::Trash`** rather than minting a rival definition of "the trash". See §12 step 10. |
| **Library scan** | `app/services/library/` | Share- **and S3-mode** indexing, gated on the **`scannable`** capability (*"does this backend's catalog come from polling the store?"* — chunk **false**, its tree is the changelog; share/s3 **true**). **`scannable` is not `!syncable?`** (equal today only by coincidence of having three backends — a notification-driven backend would answer false to both, and deriving would poll it forever) and **not Phase 4's `port_writable`** — which they **agree with on every backend we have** (chunk false/false, share and s3 true/true), so the distinction has to be *argued* rather than observed: `scannable` asks where the **catalog** comes from, `port_writable` asks which door **bytes** go in, and the same notification-driven backend splits both (push-notified → `scannable` false, while its uploads still go through the port). Agreement across three samples is not identity; it is three samples. *(An earlier version of this row claimed chunk answers `port_writable` **true** and used that to call the two opposites. Both halves were wrong — chunk is `port_writable: false` — and the true-reading is the "accepts uploads" misreading Phase 4 rejects; see `capabilities.rb`.)* **The Reconciler is the reusable half, and the Scanner is not:** the spec (§9.3) said Phase 3 "reuses the scanner", but a `Dir.children`/`lstat`/symlink walk is irreducibly filesystem-shaped, so S3 gets its own **`S3Observer`** over `list_objects_v2` and both feed the *same* `Reconciler` — which matters because **every one of 2a's bugs lived in the logic a second copy would have duplicated**. `Scanner` **observes** a share root (hand-rolled walk — `Pathname#find` silently swallows `EACCES` and drops the subtree; `ignore_error: false` aborts the whole walk, order-dependently) and exposes `#unreadable_dirs`. `Reconciler` **decides**: live path-match → move-pair by `(content_hash, size)` → revive tombstone → create. The pairing is what makes **a rename keep its `node_id`, so project attachments survive a NAS reorganization** — the phase's headline promise. Its mass-deletion guard fires on the **post-pairing tombstone count** against the **observable** library, so a reorganization is never mistaken for a deletion. **It also eagerly enqueues a thumbnail — on BOTH the create/revive branch AND the in-place content change (`#enqueue_thumbnail`), and the second one was missing until 2026-07-29.** Previews are resolved by `[node_id, content_token]`, so a file re-saved in place stranded its row on content that no longer existed and went blank on every surface — the ordinary case on a mounted NAS (LightBurn, MillMage, a slicer), which is why it read as a format bug. **A `Maker::Preview` is now ONE ROW PER `(user, node, kind)`, REPOINTED as content moves** (was one per *version*, which leaked a row + blob on every save — 160 of 1334 on the deployed share library). Two consequences that are easy to undo by accident: **`GeneratePreviewJob` must compare-and-set** (`#commit_if_current`) — with one row, a slow render of v1 finishing after v2 would attach v1's bytes to a row claiming v2 and mark it ready, a wrong image shown as current, which the row-per-version key made impossible *by construction*; and **`POST /v1/maker/previews` answers 422 for a superseded version** rather than repointing the live row backwards, but only when the port can resolve the node's current token. **A scan cannot repair that backlog and should not try**: those nodes are now `unchanged?` and are correctly skipped without a re-read, so the sweep is `Maker::Previews::MissingBackfill` (`rake previews:backfill_missing`). `ScanJob` polls every 15 min (`recurring.yml`, production only). **The Scanner's skip-lists are also blind spots — 2b's structural finding, and the root cause of BOTH permanent wedges it found:** wherever the app moves bytes **into** a skipped region (`TRASH_PREFIX` = `.trash`, root-anchored; `TEMP_PREFIX` = `.maker-tmp-`, skipped **at any depth**) while leaving a live node pointing at the old path, it creates ghosts the `Reconciler` **can never pair** — pairing needs an *observation* as the partner, and a skipped path produces none; the tombstone then trips the mass-deletion guard, **refusing that scan and every scan after it, permanently**. **THREE instances so far, each found only after the previous "explanation" said it couldn't happen**: `write`'s temp file; `delete` on a directory; and `write`/`move` accepting `.trash` or `.maker-tmp-x` as a destination — an ordinary-looking upload that wedges the scan *and* turns `.trash` into a file, breaking **every delete in the library**, permanently (`Share#observable!`). A tempting sentence that 2b had to retract: *"delete is uniquely exposed, because a move leaves the bytes observable at the new path."* False — a move is self-healing only when its **destination** is observable. **Assume every path that writes is exposed until you have checked it.** `Library::TrashPurgeJob` reclaims `.trash` past `LIBRARY_TRASH_DAYS`. **`S3Observer` (phase 3) is 2a's lesson in a new spelling — a listing is NOT a snapshot:** `list_objects_v2` paginates, and a failure on page 7 of 40 is a **well-formed lie** that reads exactly like the user deleting 82% of their library. It is `Pathname#find`/`EACCES` again, with one difference that removes the escape hatch: `unreadable_dirs` scopes a gap to a *subtree*, and a page boundary is an arbitrary key range that scopes to nothing. **Complete-or-abort is the only honest answer** (`Scanner::UnsafeScan`). Two more it must not inherit by assumption: **dir-marker objects** (`cad/`, minted by the S3 console) would otherwise become a phantom *file* node beside the real dir node; and **`valid_encoding?` does NOT transfer from the Scanner** — it asks about the string's **tag**, and an ASCII-8BIT string is *always* valid, so the naive port waves a `\xFF` key straight into `storage_path` (the SDK raises on the whole page first, so the guard is a backstop that names the bucket rather than a wedge). |
| **Addons (Tools)** | `app/services/maker/addons/`, `app/controllers/tools/`, `sidecar/` | The `/tools` gallery + per-addon UI (`Registry` declares each addon and **its own `available:` lambda**, so an addon whose backing service is unconfigured greys out rather than 500ing). Output lands via **one** path, `Maker::Addons::LibraryOutput` — backend-neutral, branching on `port_writable?`: `FileLayer#write` on share/s3, a single-chunk `Sync::Commit` on chunk. Addons come in two shapes: **client-only** (`generators` — Maker.js in the browser, always available) and **server sidecar**. Two sidecars exist, and both are **GPL invoked ONLY over HTTP, never linked** (§9): `sidecar/boxes` (GPL-3.0, boxes.py → SVG) and `sidecar/openscad` (GPL-2.0, `.scad` + params → 3MF). **Three** facts about them are load-bearing enough that `test/deploy_hygiene_test.rb` guards them rather than memory — the first two were real, shipped bugs, and all three live in files the Rails process never loads, so no other test can see them: **(1) `/sidecar/` is in `.dockerignore`** — the Rails `Dockerfile` does `COPY . .`, so without that line the copyleft trees are baked into the **permissive** app image (never imported or executed, but *shipped*, which is exactly what §9 exists to prevent). **(2) Each sidecar's URL env var must be EXPLICITLY BLANKED in `deploy.ovh.yml`** — the accessories run on the Unraid host, and Kamal **deep-merges** `env.clear`, so the OVH overlay otherwise inherits an Unraid-only hostname, the addon reports itself available, and every call fails — strictly worse than greying out. **(3) Each GPL sidecar image must carry its own licence text INSIDE it** — we build these and push them to a registry, which is redistribution. Closed 2026-07-29: `sidecar/boxes` (GPL-3.0) never copied its `LICENSE` in while `sidecar/openscad` (GPL-2.0) did; both now do. The guard is **directory-driven, not a hard-coded pair**, so a third sidecar is covered the day it appears — and it asserts *two* things, because the first draft's "has a LICENSE beside it" discovery filter silently skipped the **worse** case: a sidecar whose author never committed a `LICENSE` at all was invisible to the guard written to catch exactly that. Found by planting a synthetic sidecar and watching the test stay green, not by reading it. |
| maker-app-core, juicefs-backend | `client/…` | Earlier Tauri mount-controller + JuiceFS WebDAV backend (from the abandoned path; kept for reference). |

**Verified end-to-end:** device A creates a file → daemon pushes (chunks to a cloud
store) → device B pulls + hydrates + reads, **byte-for-byte identical**; metadata via
the live server changelog. Multi-device convergence demonstrated. Hundreds of tests green
across the stack (server suite, hermetic provider/chunking/convergence/concurrency suites,
server-backed engine integration, two-device real-mount E2E, adversarial fault harness) —
see `docs/STATUS.md` for the current per-suite counts.

---

## 4. Tech stack (decided)

| Layer | Choice |
|---|---|
| Backend | **Rails 8** (Solid Queue/Cache/Cable) |
| Server DB | **Postgres** (managed) / **SQLite** (self-host) — same adapter-agnostic models |
| Object storage | **S3-compatible** — R2 (managed), SeaweedFS/MinIO/their S3 (self-host) |
| Chunking | **FastCDC** (`fastcdc-rs`, MIT) — content-defined, deduped |
| Client | **Tauri** (Rust core), `fs-provider` + per-OS mount (`fs-fuse`/`fs-winfsp`/`fs-webdav`) + `sync-engine` |
| Mount | Per-OS, all live: **Linux** FUSE (`fuser`), **Windows** CfAPI (driverless Cloud Filter — the default; WinFsp behind the `winfsp-backend` feature), **macOS** WebDAV (native `mount_webdav`, no kext). macOS FSKit is a **design sketch, not built** (no `client/fs-fskit` crate on `main`; `docs/plan-macos-fskit-migration.md`) — and would additionally need a paid Apple Developer membership. Drivers user-installed (keeps copyleft drivers out of our binaries). |
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
> nanos-overflow in the WebDAV/WinFsp adapters).

> **Merged to `main` + file layer hardened (2026-06-14):** the `auth-caching-security` arc
> landed on **`main`** (squash PR #8). A hardening batch then closed the remaining file-layer
> gaps: **Postgres validated** (config-only switch, step 8 ✅); **GC/retention wired** (tiered
> policy + nightly job + S3 delete — closes unbounded-storage growth); **CfAPI B6 polish**
> (pin/unpin↔hydrate, `CfUnregisterSyncRoot`, streamed `FETCH_DATA`, ino→path index); a
> **two-device E2E suite** (A→B→edit→A byte-for-byte) with per-OS CI; and an **adversarial
> fault-injection harness** ("Trinity") that **found two real changelog ordering bugs** — a
> child-before-parent outbox drain and a pull hard-deleting a locally-renamed-but-unpushed node
> (silent convergence loss) — **both fixed + verified** (topological drain; defer-and-retry +
> `needs_resync`→`pull_snapshot` floor; soak 1000×200 = 0 silent losses). Plus loose ends:
> pairing codes from **SecureRandom**, `image_processing`→2.0, deterministic GC tests. Server
> suite **75 tests**. New strategy docs: `docs/research-sync-competitors.md`,
> `docs/feature-set-and-workflows.md`. Next up: real **OAuth/OIDC** email verification (§12 step
> 5), then the **maker app layer** (§12 step 9); open file-layer items = selective sync + at-rest
> encryption (non-correctness).

> **Automated cross-OS real-mount E2E + web UI + real auth (2026-06-15, HEAD `bab90bb`):** a large
> batch landed on `main`. **Automated real-mount A↔B end-to-end is now green on all three OSes**
> (`nightly.yml`: `two-device-fuse-linux`, `two-device-cfapi-windows`, `two-device-webdav-macos`) —
> a deep cross-OS debugging arc surfaced + fixed real on-hardware bugs: Windows CfAPI **3 receive-side
> bugs**, and Linux FUSE (**`fuser` 0.14→0.17** + the real one: `run_until_unmounted` must `join()`,
> not `umount_and_join()` which self-unmounts in 0.17). Also: **real auth** (Rails 8 built-in:
> signup/confirm/login/reset + Session + OmniAuth seam, replacing the web placeholder; 1 HIGH OAuth
> takeover fixed); a **web UI MVP** (file browser upload/download/view/delete + trash/undelete, bytes
> off Rails); **selective sync**, **progressive/range hydration**, **client bandwidth controls**;
> stress/concurrency + 15-filetype conformance (no corruption); **torn-write safety confirmed**
> (finalize is atomic); `STORAGE_BACKEND=local` test backend. New docs: `docs/parity-roadmap.md`,
> `docs/torn-writes-and-batching.md`, `docs/r2-migration.md`. Server 144/0. **Next: the maker app
> layer (§12 step 9).** Full takeover notes: `docs/HANDOFF.md`.

> **Managed-deploy + file-layer polish batch merged (2026-06-16, HEAD `94b7f02`):** three PRs
> landed on `main` on top of the cross-OS E2E state. **G2 — managed-Postgres hardening:** a
> boot-time **statement-pooler safety guard** (`lib/postgres_pooler_check.rb` + initializer;
> refuses to boot behind a statement-mode pooler that would break `next_seq!`), `sslmode`
> defaulting in `database.yml`, the Solid Queue/Cache/Cable roles documented for managed
> Postgres, and a **real concurrency deadlock fix** — `next_seq!` is now the *first* statement
> in `Sync::Commit#finalize`/`Mutation#apply`/`Restore`/`Conflicts` so two concurrent commits
> can't deadlock on `FOR KEY SHARE`→`FOR UPDATE` lock upgrades (`test/services/sync/concurrent_seq_test.rb`).
> **G4 — storage-orphan chunk reaper:** `Sync::ChunkReaper` + `ChunkReaperJob` (weekly via
> `config/recurring.yml`) + `ChunkStore#list` + `lib/tasks/chunks.rake` — sweeps chunk bytes
> left in object storage by commits that uploaded but never finalized (objects with no DB row,
> invisible to the refcount GC), closing the abandoned-upload leak. **G5/G8/G10 — file-layer
> polish:** opt-in (default-OFF) outbox debounce for big CAD autosaves, a special-file `EPERM`
> guardrail (FIFO/socket/device nodes), and a delta-on-wire audit. **R2 validated live:** the
> S3 presign path was exercised end-to-end against a real R2 bucket and the per-chunk hydrate
> latency measured (~85–205 ms, invisible in the local-first UX — `docs/r2-migration.md` §5). A
> **parallel/pipelined chunk-hydration** optimization for large cold files (concurrent `io.get`/`io.put`
> across a bounded pool, `DaemonConfig::hydrate_concurrency` default 8, ~8× on a synthetic-latency
> bench) is **merged** (PR #15). See `docs/STATUS.md` for the current per-suite test counts.

**Built + verified (live cross-stack + cross-OS demos; current per-suite test counts in `docs/STATUS.md`):**
- Server (Rails): full v1 API, `Sync::*` services, ActionCable. **Server suite green
  (current count in `docs/STATUS.md`)** — commit/refcounts/dedup + GC prune/sweep + changelog
  prune, restore chains, tree + changelog pagination / `oldest_seq` backstop, tenant isolation,
  **real auth (signup/confirm/login/reset) + register hardening + device pairing**, **conflict
  detect/keep/split**, **best-effort edit locks**, **file-mode sync**, **GC retention +
  storage-orphan chunk reaper (G4)**, **concurrent-`next_seq!` no-deadlock (G2)**.
- `fs-provider`: local SQLite tree + FastCDC chunks + `export_tree`/`apply_remote`/`apply_remote_delete`/`truncate`. Hermetic suites (`tests/`; count in `docs/STATUS.md`): **caching** (mtime-freshness + random-write-on-hydrated), **chunking**
  (round-trip / dedup / block-delta boundary stability / pathological inputs, proptest),
  **posix_semantics** (rename-over replace, dup/missing, unicode/deep nesting),
  **convergence** (3-replica FakeFolder-style random op stream + durability + idempotency),
  **concurrency** (shared `Arc` threads + chunk-store race). Modeled on rclone-fstests /
  restic-chunker / ownCloud-FakeFolder / JuiceFS-pjdfstest.
- `fs-fuse`: FUSE mount (Linux/macOS-FUSE-T), verified live in Finder. Now also persists +
  syncs file **mode** (chmod/executable bit), local advisory **locks** (`setlk`/`getlk`),
  **freshness**-on-open, and best-effort **remote-lock** acquire/release.
- `sync-client`: typed API + chunk transfer + pull-apply, plus pairing/conflict/lock/
  versions methods (count in `docs/STATUS.md`).
- `sync-engine`: `push`/`pull_snapshot`/`pull_changes`/`hydrate`/`sync_once` **plus the
  daemon loop primitives** `push_outbox`/`sync_tick` + `EngineHydrator`/`EngineFreshness`/
  `EngineRemoteLock`. **Server-backed integration suite** (`tests/integration.rs`; count in
  `docs/STATUS.md`): roundtrip, delete/move delta, hydrate (only-missing/after-conflict), push
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
   **CfAPI migration — read+write loop VERIFIED LIVE** (2026-06-12): `client/fs-cfapi` — the
   **driverless** Windows path (Cloud Filter API; no GPL driver — §9), over the same `Provider`,
   wired as `sync_engine::CfApiMount` + `maker-cfsyncd`. Live on Windows 11: register +
   on-demand `FETCH_PLACEHOLDERS` + hydrate-on-open `FETCH_DATA` + remote-change invalidation
   (`CfUpdatePlaceholder`+`CfDehydratePlaceholder` via the Option-B `Invalidate` seam) +
   **local-edit capture** (`NOTIFY_FILE_CLOSE_COMPLETION` + content-compare →
   `Provider::ingest_bytes` → push). Hydrated files persist offline (Drop disconnects only).
   `Provider::bind_library` guards reused-DB library-mixing across all mounts. Reuses the
   Option-B seams (real nanos mtime → `FILETIME`). Pure logic unit-tested; FFI typechecks for the
   Windows target + compiled by the `cfapi-windows` CI job. ~~**WinFsp is still the default**
   Windows backend.~~ **Remaining (detailed handoff + per-step plan):
   `docs/plan-windows-cfapi-migration.md`** — ~~Phase 2b (new files/deletes/renames),
   remote-files-while-mounted, flip CfAPI to default, pin/unpin + lifecycle polish.~~
   *(Superseded 2026-06-14 — this paragraph is a snapshot of 2026-06-12: **CfAPI is now the
   DEFAULT** Windows backend, its Phase 2b is complete, and WinFsp sits behind the
   `winfsp-backend` feature. See the `fs-cfapi` row in §3. Note this "Phase 2b" is the **CfAPI
   migration's**, unrelated to the FileLayer Share phase 2b in step 10.)*
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
8. ~~**Postgres deploy validation**~~ **DONE** (2026-06-14; hardened 2026-06-16). The
   adapter-agnostic server runs green on Postgres (Docker); switch is config-only via
   `DATABASE_URL` (a `postgres` profile in `database.yml`; `next_seq!` `FOR UPDATE` exercised
   on PG). **Managed-Postgres hardening landed (G2, 2026-06-16):** TLS `sslmode` defaulting in
   `database.yml`; a **boot-time statement-pooler safety guard** (`lib/postgres_pooler_check.rb`
   + initializer — refuses to boot behind a statement-mode pooler, which would silently break
   the transaction-spanning `next_seq!` row lock); the Solid Queue/Cache/Cable roles documented
   for managed Postgres; and a **real concurrency deadlock fix** — `next_seq!` is now the first
   statement in `Sync::Commit#finalize`/`Mutation#apply`/`Restore`/`Conflicts`, so concurrent
   commits can't deadlock on a `FOR KEY SHARE`→`FOR UPDATE` lock upgrade
   (`test/services/sync/concurrent_seq_test.rb`). Still open for a real managed deploy: pick a
   session/transaction-mode pooler endpoint and run a concurrent-commit load test at scale. See
   `docs/SYNC_SERVER.md`.
   - **Also done (2026-06-14):** **GC/retention wired** (`Sync::RetentionPolicy` keep_all/tiered
     + `RetentionJob` nightly + S3 `delete_object` in `sweep_orphans!`; current+`pinned` never
     pruned) — closes unbounded-storage growth. **Adversarial fault harness** + **two-device E2E**
     added; **two changelog ordering bugs** found + fixed (topological outbox drain;
     defer-and-retry + `needs_resync`→`pull_snapshot` floor — 0 silent losses under soak).
   - **Also done (2026-06-16):** **storage-orphan chunk reaper (G4)** — `Sync::ChunkReaper` +
     `ChunkReaperJob` (weekly, `config/recurring.yml`) + `ChunkStore#list` + a `chunks.rake`
     task: sweeps chunk bytes left by commits that uploaded but never finalized (no DB row →
     invisible to the refcount GC). Closes the abandoned-upload storage leak (matters for
     managed R2 cost).
9. **The maker app layer** on top (projects/inventory/BOM/preview) — a *separate* Rails
   concern from file sync; references files by `node_id`. Groundwork landed: the Tauri app
   has a **file browser + version-history/restore UI + conflict-resolution popup + lock
   indicators** (`client/maker-app`). **Selective sync, progressive/range hydration, and client
   bandwidth controls all landed** (2026-06-15, engine-side; selective sync still needs an app
   surface). *Remaining optional file-layer item (non-correctness):* **at-rest chunk encryption**
   (deliberately last; `docs/parity-roadmap.md`, `docs/research-sync-competitors.md`).
   - **The maker WEB layer is where this step has actually been moving** (projects, model library,
     previews, the `/tools` addon framework, current-project, the 3D viewer, file organization) —
     server-rendered Hotwire on `Maker::*` models, session-authed, **never** the device-token v1
     API. Each arc is recorded in `docs/STATUS.md` rather than here; only the structural pieces
     belong in this file. The one added 2026-07-27: **`Maker::MoveNode`** — the maker layer's named
     home for the cross-backend **move** (`port_writable?` → `FileLayer.current.move`, else
     `Sync::Mutation.apply(op: "move")` + broadcast), the sibling of `Maker::LibraryFolder`'s
     `mkdir`, plus **`Maker::AttachToProject`**, which owns the attach-and-relocate policy now that
     it has two doors. **Controllers call these and never reach into `Sync::` or the port
     themselves** — that seam is what keeps step 10's §10 tripwire honest.
     **THE `port_writable?` TWO-DOOR BRANCH IS WRITTEN OUT FIVE TIMES, NOT THREE** (both this file
     and `docs/STATUS.md` said "the third appearance" until a review counted them):
     `Maker::LibraryFolder#mkdir`, `FilesController#destroy` (port `delete` vs
     `Sync::SubtreeDelete`), `TrashController#restore` (port `undelete` vs `Sync::Trash.restore`),
     `Maker::Addons::LibraryOutput.write` (port `write` vs a server-driven `Sync::Commit`), and
     `MoveNode`. Only two of the five have a name of their own; the other three are inline in the
     action that needs them, each for a stated reason. **So the rule is not "refuse a fourth copy"
     — it is that a NEW one needs an argument for being inline rather than a service**, and a
     verb that more than one caller performs does not have one. (Excluded from the count on
     purpose: the `require_capability!` gates and the views that pick an upload FORM. Those select
     a UI, which is `port_writable`'s stated one job — they do not open a door to the bytes.)
     **ONE file-type vocabulary, as of 2026-07-29.** `FilesHelper::EXT_FAMILIES` (the Files-page
     filter chips) is no longer a hand-written list that could disagree with
     `Maker::FileAttachment::ROLE_LABELS` (the project panel headings) — it is **derived** from
     `ROLE_BY_EXT`, grouped by role and labelled/ordered by `ROLE_LABELS`, with `other` dropping out
     because nothing maps to it. Add an extension in **`ROLE_BY_EXT` only**; the chips follow.
     **Two consequences a future editor must know:** every extension there must satisfy
     `FilesController::EXT_RE` (`/\A[a-z0-9]{1,8}\z/`) or it renders a chip that links and silently
     does nothing (`markdown` is the current bound at exactly 8 chars), and the `role` column is
     **behavioural** — cover-image selection reads `image`/`model`, and
     `Models::AttachmentsController` dispatches `ExtractPdfMetadataJob` on `instructions`, so `pdf`
     must stay `instructions`. A THIRD copy still exists in `importer_controller.js`'s `roleFor`
     and has drifted; it is browser-only and the server re-derives authoritatively, so nothing is
     broken — see `docs/STATUS.md`.
10. **Split the maker layer from the file layer** (2026-07-14) so a **web-only deployment can be
    backed by a plain network share or the user's own S3** instead of the FastCDC chunk store —
    the Immich/Photoprism "point it at my existing NAS" on-ramp. **✅ COMPLETE (2026-07-17,
    phases 1 → 4):** `LIBRARY_BACKEND=chunk|share|s3` all boot, index, write, deliver, and **tell
    the truth about themselves**. **Phase 1 DONE, merged
    (`f04ef61`), deployed, and verified live** (a 40k-byte presigned round-trip through
    SeaweedFS): the `FileLayer` port + `Chunk` adapter + the shared adapter contract, and
    `Maker::FileBytes` reduced to a shim. The maker layer no longer references chunks at all
    (`grep -rn "manifest_chunks\|ChunkStore" app/services/maker/ app/models/maker/ app/jobs/maker/
    | grep -v ':[0-9]*: *#'` — that grep IS the proof, not the test suite. The
    `grep -v` is load-bearing, not noise: without it the check reports two COMMENTS in
    `maker/file_bytes.rb` that describe the very coupling that was removed, so the bare grep has
    not returned nothing since phase 1 shipped. A proof that cries wolf gets ignored.)
    **CORRECTED 2026-07-28: this grep no longer returns NOTHING — it returns exactly ONE line, and
    that line is legitimate.** `app/services/maker/addons/library_output.rb:47` calls
    `Storage::ChunkStore.current.put` directly, because addon-generated output has no client to
    presign for: in chunk mode the server itself drives a single-chunk `Sync::Commit` plus the
    `put`, mirroring what the web uploader does from the browser. That is the addon framework
    (§3 "Addons"), which post-dates this sentence — the claim was true when written and the addon
    work made it false without anyone updating it. **The invariant to check is therefore "one hit,
    and it is `library_output.rb`", not "no hits"** — which is exactly the kind of drift this
    paragraph's own last sentence warns about, and it took a fresh reader running the command to
    notice.
    - **Design:** `docs/superpowers/specs/2026-07-14-maker-file-layer-split-design.md`.
      §2 = settled decisions (backend per **deployment**, not per user; index-existing AND
      write-new; **current-state only, no history** on share/s3; stable `node_id` reconciled by
      scan; periodic scan, not inotify; Rails streams share bytes). §9a = six issues the Phase 1
      review found, deferred with reasons. **§10 is a tripwire:** if work here needs to touch
      sync, the changelog, conflicts, locks, or the mounts, the boundary is wrong — stop.
    - **Two deliberate invariant departures, both scoped to storage we don't own:** §5
      ("keep versions so restore always works") cannot hold on a plain share — the user's
      overwrite in Finder destroys the old bytes — so share/s3 libraries are **current-state
      only** and restore stays a chunk-mode feature. §15 ("keep bytes out of Rails") cannot hold
      for a mounted directory, which has nothing to presign — share streams via **`send_file`**
      (X-Accel/X-Sendfile *only* if an operator puts a proxy that implements it in front; this
      deployment is kamal-proxy, so `x_sendfile_header` is nil and Rack::Files is the only branch
      that runs — see Phase 4 below); **S3 still presigns, so §15 holds where it was aimed**
      (managed/WAN egress). Do not "fix" these back.
    - **Phase 2a DONE** (2026-07-16, branch `worktree-file-layer-share-phase2a`, 11 commits):
      a share-backed library that was **read-only as of 2a** (the write path is 2b, below) —
      `docs/superpowers/plans/2026-07-14-file-layer-share-phase2a.md`. `LIBRARY_BACKEND=share`
      + `LIBRARY_PATH=/mnt/nas/models` now boots, indexes an existing NAS directory, and the
      maker layer browses/previews it with **attachments that survive a reorganization**.
      Server suite **523 → 635**, green on *both* backends (`LIBRARY_BACKEND=share bin/rails
      test` is a CI leg — it catches tests that silently depend on the ambient backend; the
      shared contract is what stops the adapters diverging).
    - **Phase 2b DONE** (2026-07-16, branch `worktree-file-layer-share-phase2b`) — **the write
      path + trash**, Share-only (a share library can now *grow*, not just be indexed). Suite
      **635 → 698**, still identical on both backends. The decisions a future reader must not
      undo:
      - **THE TWO TOMBSTONE KINDS — the thing most likely to get "simplified" away.** A **scan**
        tombstone **keeps** `storage_path` and is revivable by the scan's revive-by-path; a
        **trash** tombstone **NULLs it** (`deleted: true, storage_path: nil`) and is revivable
        only by `undelete`. Collapse them and `Reconciler#create_or_revive!` hands a **new,
        unrelated file the trashed node's `node_id`** — and with it every project attachment,
        BOM link and tag — while the old bytes sit in `.trash` awaiting an `undelete` that then
        collides. Silent.
      - **Trash layout `.trash/<node_id>/<name>`, keyed by `node_id`** — which is *why* two
        same-named deletes can't collide, and why `undelete` has one unambiguous place to look.
      - **`undelete` is a FOURTH port verb**, diverging from spec §3.2's three. The spec's
        *"undelete is just a move back"* is **precluded**: `move` starts with `live_node!` (a
        tombstone isn't live) and resolves its source via `absolute_path` → `storage_path`,
        which is NULL — it would rename the library root. Recorded so it isn't rediscovered as
        an inconsistency.
      - **Order is load-bearing, both ways:** `delete` is **move-then-tombstone** (the reverse
        fails *silently* — the next scan resurrects it); `undelete` is **move-then-revive**.
        `EXDEV` → `FetchError`, **never** a copy+delete fallback.
      - **`delete` refuses directories** (`FileLayer::UnsupportedOperation` — a *client*
        condition, not `NotImplementedError`, which means the deployment is mis-wired): a dir
        delete strands the children's nodes at paths that no longer exist while their bytes sit
        in `.trash`, where the scan refuses to look → the second permanent wedge (reproduced;
        the cheap cascade was tried and collapses both ways). **`move` ALLOWS directories** — a
        moved dir leaves the bytes *observable* **at an observable destination**, so pairing
        rescues the children. That qualifier is load-bearing: reasoning "a move is always
        self-healing" is what let `write`/`move` accept `.trash` as a destination — the **third**
        wedge, and the worst, since it also breaks every delete in the library (`observable!`).
      - **An unmounted share must never read as "your file is permanently gone":** `undelete`
        raises `FetchError`, not `NotFound`, when the library looks unmounted (same trade as
        `read`'s rescue — `NotFound` is terminal).
      - **`LIBRARY_TRASH_DAYS`** (default **30**; **`0` = keep forever, NOT purge everything** —
        `0.days.ago` is *now*, so the obvious implementation deletes the lot). Purges by
        **entry-dir mtime**, **never** touches the row, and **empties `.trash` but never removes
        `.trash` itself** (an empty root reads as unmounted → would flip `undelete`'s `NotFound`
        to `FetchError`).
      - **The boot guard touch-probes** for writability. **`File.writable?` is not the check** —
        it tests POSIX mode bits, not effective access, and is wrong under exactly the NFS/SMB
        ACLs this backend targets. The probe uses `TEMP_PREFIX` so a leak can't be indexed. The
        initializer had to move to **`after_initialize`**: app constants aren't autoloadable
        while initializers run, so the naive version raised `uninitialized constant Library` and
        **took the boot down while every test stayed green** (the test env skips it).
      - **`Share#write`** stamps the node's mtime from **the file's own stat**, not the clock —
        the scan compares against it.
      *(2b's "Next: Phase 3 = S3" pointer retired 2026-07-17 — phase 3 is done; see the bullet
      below.)*
    - **Hard-won during 2a — do not relitigate:** the mass-deletion guard must count the
      **post-pairing tombstone set**, never vanished paths (a rename vanishes its old path, so
      the naive guard refuses the reorganization the phase exists for). `Pathname#find`
      **silently swallows `EACCES`** and drops the unreadable subtree — for a tombstoner that
      is a mass-deletion bug wearing a clean scan; hence the hand-rolled walk + `unreadable_dirs`,
      which must be excluded from **both** sides of the guard's fraction *and* from
      `vanished_paths`. Filenames on a real NAS **are not guaranteed to be valid UTF-8**; one
      that isn't used to brick every subsequent scan (macOS can't even create the fixture).
    - ~~*Open (non-correctness) — carried from 2a:* `Reconciler` loads every live node into
      memory; `best_pairing` is O(n*m) (~2s per 10k renames).~~ **FIXED (2026-07-16), and the
      "~2s" was wrong — it measured 9s, 4.5x the claim.** The no-op scan (every 15 min, forever,
      nothing changed) `pluck`ed the four columns it compares instead of instantiating a live
      node per file, and materializes AR objects only in the two branches that WRITE — zero of
      them in a no-op scan (50k nodes: **+67 -> +23 MB**; 20k no-op: **0.159 -> 0.061s**).
      `best_pairing` buckets candidates by `[hash, size]` instead of scanning them all per
      vanished node (**10k renames 9.0 -> 3.5s; 50k renames ~4min -> 18.6s**, near-linear).
      **The old comment's argument is the lesson:** *"dwarfed by the hashing, not worth an index"*
      — hashing is LINEAR and that scan was QUADRATIC, so the crossover was built in; a
      reorganization big enough to matter is exactly where it stops being true. Behavior is
      byte-identical (two independent seeded differential probes, 100 seeds, digest match).
      *Still inherent:* an all-byte-identical bucket costs O(N) per probe — the deterministic
      tie-break must compare the old path against every identical candidate, and removing that
      trades the no-lost-file guarantee for speed.
    - **Phase 3 DONE** (2026-07-17, branch `worktree-file-layer-s3-phase3`, 13 commits) — **the
      user's own S3 bucket as a library**, `LIBRARY_BACKEND=s3` + `LIBRARY_S3_*`. It boots,
      indexes an existing bucket, and reads/writes/deletes/moves through the port. Suite
      **698 → 871**, **identical on all three backends** (`bin/rails test`,
      `LIBRARY_BACKEND=share`, `LIBRARY_BACKEND=s3` — the last is a new CI leg, self-hosted, no
      external service: a real `Aws::S3::Client` with stub lambdas, real error classes, real
      pagination at 2 keys/page). **The Phase 3 trap is DISARMED:** both gates
      (`ScanJob.scan_all!`, `TrashPurgeJob.purge_all!`) now key on `scannable?` instead of
      `is_a?(FileLayer::Share)`, which would have answered false for S3 and silently never
      indexed the library. The decisions a future reader must not undo:
      - **THE IDENTITY LADDER** (`FileLayer::S3::ObjectIdentity`). An S3 object has no content
        hash you can get for free, and the port asks **two different questions** of one value:
        `content_token` need only be an opaque content-**state** token (an ETag is one), but
        `content_hash` must be content-**determined** for move-pairing — and **a multipart ETag
        is not** (the same bytes at a different part size give a different ETag). One namespaced
        value, a strength ladder: **`sha256:`** (FULL_OBJECT only — a **COMPOSITE** sha256 is a
        checksum-of-checksums, the same defect wearing a better name, so the *type* is required
        and not the checksum alone) → **`md5:`** (a 32-hex single-part ETag **is** the md5; 32-hex,
        NOT merely "dash-free" — this backend points at stores free to emit any shape) →
        **`etag:`** (moves degrade to delete+create — a **missed** rename, never a **wrong**
        pairing; the safe direction). **TOTAL by construction — never nil**, and that is a
        data-loss guard rather than tidiness: `Reconciler#plan_moves` **drops** a nil-hash
        observation from `candidates`, and candidates is what becomes the leftovers that get
        indexed → the object is **never indexed at all**, no error, no log. Survivable on a share
        (a nil hash there is an EACCES blip the next pass fixes); **permanent** here.
        **Quotes come off in exactly ONE place** — S3 wraps every ETag in literal quotes, in
        list, head *and* put responses, so mixing the forms unpairs every move on every scan.
        **`S3Observer` WARNS once per scan** with the count of rung-3 objects, because where the
        headline promise does not hold the operator has to be told — silence there is a promise
        made and not kept. Advisory only (never raises, never skips, never logs per object — a
        target bucket holds millions). **Its blind spot is recorded at the method:** an
        **SSE-KMS** object has a 32-hex ETag that is **not** the content md5, so it takes rung 2,
        is stamped `md5:`, and the count reads **zero while no move pairs at all** (a re-encrypt
        on copy changes the ETag). A zero means "nothing we can see", **not** "moves are fine".
      - **Download-and-hash was rejected on the spec's own terms:** a full billed egress of the
        bucket to index a library the user already has is precisely the cost the "point it at my
        existing storage" on-ramp exists to avoid (§1).
      - **`LIBRARY_S3_HEAD_FOR_CHECKSUM` is NOT implemented — do NOT document it as working, and
        the plan's cost model was unachievable.** The plan priced it at "one HEAD per object on
        every **first sight**". **An observer cannot know what is new — the Reconciler does** —
        so a HEAD there is per-object-per-**scan**: on a 2M-object bucket that is **2M billed
        requests every 15 minutes**, not 2M once. Costing an operator that under a flag
        advertised as costing 2M once is worse than not offering it. **Consequence: the
        `sha256:` rung is unreachable from any production path today** (`list_objects_v2` never
        returns the checksum *value*; `write` uses put_object's ETag).
      - **LANDMINE 3 — copy → delete → TOMBSTONE.** The spec's *"tombstone only after the copy
        confirms"* is **necessary but not sufficient**, and the gap is only visible read against
        2b's storage_path-nulling: if the **delete** fails after a tombstone, the next scan finds
        an unclaimed key with **no tombstone to revive by path** → a **new `node_id`** → **every
        attachment orphaned**, by a scan that did nothing wrong, with no error anywhere. Proven
        end-to-end with a real attachment. (`undelete` is the same landmine wearing another hat:
        copy → revive → sweep the trash copy **best-effort, last**.)
      - **THE `CGI.escape` BUG — the phase's sharpest find, and its lesson is about testing, not
        S3.** The SDK does **not** escape `copy_source` (verified by capturing
        `x-amz-copy-source` at the `:sign` step). `CGI.escape` is *form* encoding, so
        `"Bracket v2.stl"` → `"Bracket+v2.stl"`, and real S3 reads `+` as a **literal plus** →
        the copy reads a nonexistent key, the delete removes the **right** one, the tombstone
        follows → **silent permanent data loss on a filename with a space**, the most ordinary
        thing in a CAD library. **`FakeS3` hid it by being the exact inverse** (`CGI.unescape`):
        **79/80 tests green**. Fixed with per-segment `ERB::Util.url_encode`. **A hermetic fake
        built from the same misunderstanding as the code CONFIRMS the misunderstanding — assert
        the WIRE format, not the round-trip.** Watch for this shape wherever a fake and the code
        under test share an assumption.
      - **The boot guard does NO NETWORK** — a boot that depends on a third party being up turns
        a blip into a crash loop. Config *presence* is what boot can honestly check; credential
        *validity* surfaces on first use as a **retryable `FetchError`**.
      - **`key_for` REJECTS, never normalizes:** `expand_path` would turn `a/../b` into a
        *valid* key and silently read the wrong object. Not theoretical — we sign **path-style**
        URLs, so a `..` segment lands in the URL path and any normalizing proxy resolves it out
        of our bucket.
      - **`write` has NO temp-and-rename, and its ABSENCE is the thing to read carefully** — a
        reader who knows `Share#write` will see a missing step and "restore" it. Share renames
        because a half-written file is *visible* in the share the whole time; **put_object is
        atomic**, so there is nothing to protect against and a temp key would only add a second,
        unobservable ghost. Clobber is **refused** (every backend here is current-state-only, so
        a clobber is the user's file **permanently gone** from a name collision in an upload
        form) — but it is a `head`-then-`put` **CHECK, NOT A LOCK**: TOCTOU, and S3 has no
        portable conditional put (R2/SeaweedFS/Ceph). It stops the ordinary case; it does not
        claim atomicity. **`put_object`'s response carries no `last_modified`** (verified) →
        **two billed HEADs per write**, stated rather than hidden.
      - **THE REAL-BUCKET RUN HAPPENED** (2026-07-17, SeaweedFS **4.39** on a local scratch
        instance — the DoD's requirement, closed). The whole point was to find where the
        hand-written `FakeS3` and a real store still disagree, since the fake had already hidden
        one silent data-loss bug by being the exact inverse of the code's misunderstanding.
        **Nothing the adapter or the observer does was found wrong.** What the store confirmed,
        by observation rather than reasoning: **`copy_object` stamps a NEW `Last-Modified`** (+2s
        on a copy of an aged object — the premise of the whole trash-retention window, and the
        one the fake models only *since* a review reasoned it out); **the ETag arrives QUOTED**
        (34 chars, in put, head AND list — the SDK does **not** strip them, so
        `ObjectIdentity`'s one strip point is load-bearing exactly as claimed, and `MD5_ETAG`
        does *not* match the raw form); **`copy_source_if_match` IS honored** (matching → copy;
        mismatched → `Aws::S3::Errors::PreconditionFailed`; quoted *and* bare both accepted);
        **a multipart ETag really carries `-N`**, lands on rung 3 and fires the warn; **the real
        page size is 1000** and the observer saw all 1050 of a >1000-object bucket; **the
        headline E2E passes on a real store** (out-of-band reorganization via the S3 API, five
        ballast files, attachment still resolves with `node_id` intact); and **head and list
        agree exactly** on `last_modified`/etag/size, so a written file does **not** churn on
        the next scan and the scan is idempotent.
        **THE ONE REAL DIVERGENCE FOUND WAS IN THE FAKE, and it is the same bug's home turf:**
        `do_copy` decoded with `CGI.unescape` (form decoding, `+` = space) while a real store
        percent-decodes (`+` = literal plus, verified: the store answers `InvalidArgument`). The
        adapter has been right since the `url_encode` fix, so this was the **missing regression
        guard**, not a live bug — reverting the adapter to `CGI.escape` still passed against the
        fake. Fixed + pinned by a test of the fake itself (mutation-checked).
        **STILL UNVERIFIED:** `copy_object`'s 5GB cap **and its error class** (cannot stage 5GB;
        the SDK mints error classes via `const_missing`, so "the class exists" is **not a
        check** — which is why the guard depends on no name and refuses from `node.size`
        instead); **R2/MinIO/Ceph specifics** (only SeaweedFS was exercised — and note AWS
        itself may differ where SeaweedFS is lenient); real-world non-UTF-8 key frequency.
        **Store-specific observations, none load-bearing today:** SeaweedFS returns
        `copy_object_result.etag` **unquoted** while put/head/list quote it (AWS quotes it too;
        nothing in production reads it); it has **no checksum API** at all (`checksum_sha256`
        nil, `checksum_algorithm` `[]`), so the `sha256:` rung is unreachable there by a second
        route on top of the listing one; and it **collapses `a//b`** and **refuses `./..`** keys
        outright, so `indexable?`'s guards against those are unreachable on this store while
        remaining correct for AWS, which permits them.
    - **Phase 4 DONE** (2026-07-17, branch `worktree-file-layer-phase4`, 10 commits) — **the web
      UI and the v1 API stop lying about what this deployment can do.** Suite **871 → 954** *(a
      snapshot at phase 4 — the CURRENT count is in the follow-up bullet below; this line records
      what the phase moved, not what the suite is today)*, **identical on all three legs**
      (`bin/rails test`, `LIBRARY_BACKEND=share`, `LIBRARY_BACKEND=s3`).
      Plan: `docs/superpowers/plans/2026-07-17-file-layer-capability-gating-phase4.md`.
      **The split is complete: `LIBRARY_BACKEND=chunk|share|s3` all boot, index, write, deliver,
      and tell the truth about themselves.** The decisions a future reader must not undo:
      - **`port_writable` IS NOT "accepts uploads", and this is the single most likely thing here
        to be misread.** It answers one question for one caller — **which upload flow the UI
        drives**: *true* → POST the bytes to the port (share, s3); *false* → drive `Sync::Commit`'s
        two-phase presigned flow (chunk). Chunk mode accepts uploads **all day** — that *is*
        `Sync::Commit` — so reading the name as "can this deployment take uploads" **hides the
        upload button in the product's main deployment**. The name is about the **port's** write
        path, not the deployment's. (It is also not `!syncable?` and not `scannable`; the full
        argument lives at `app/services/file_layer/capabilities.rb`, which is where a future
        reader will actually be standing.)
      - **The 501 is a capability gate BEFORE the call, never a `rescue NotImplementedError`** —
        and the *reasoning* is recorded (`app/controllers/concerns/library_capabilities.rb`),
        not just the rule, because otherwise someone adds "a backstop rescue": (1)
        `NotImplementedError` is a **`ScriptError`, not a `StandardError`**, so `rescue => e` and
        ActiveJob's `retry_on` **silently do not catch it** — the rescue-based gate does not have
        a gap, it does not work, failing to exactly the 500 the spec forbids; (2) a 501 from
        `Chunk#write` would be **factually wrong** — it means *the caller used the wrong door*,
        not that the deployment can't take uploads; (3) a controller rescue catches it from
        **anywhere below**, laundering an s3 **misconfiguration** at `FileLayer.build` into a
        routine-looking response. **`NotImplementedError` stays un-rescued, and that is a
        feature** — it is a programming error, it should be loud, and the gates are what keep it
        unreachable. `grep -rn "rescue.*NotImplementedError" app lib | grep -v ':[0-9]*: *#'` returns nothing;
        keep it so. (The `grep -v` matters for the same reason the maker grep's does: three
        COMMENTS say the words, so the bare form has never returned nothing.)
      - **What is gated, and what deliberately is not.** Gated: `changes`, `tree`, `conflicts`,
        `locks`, `commits`, `chunks#download`, v1 `trash`, `nodes`, `share_links`. **Ungated on
        purpose:** **`devices`** — the plan said to gate it, and gating it would have made a share
        deployment's **entire v1 API unauthenticatable** (a device token is the only credential
        the API accepts, `/v1/maker/*` included) *while the plan's own "maker is NOT gated" test
        stayed green*, because it minted a token in Ruby instead of calling the endpoint a real
        client must call; and **`V1::ShareController`** — the anonymous redeem side of **public
        file links**, nothing to do with `FileLayer::Share`, where a 501 would disclose the
        backend to any stranger holding any string and the existing 404 is honest and terminal.
        Two gates are **not** the capability they look like: **`chunks#download` → `syncable`,
        NOT `presignable`** (S3 answers `presignable: true` while having no chunk to hydrate),
        and **v1 `trash` → `syncable`** (it is the *chunk* trash — tombstone + retained version —
        and running its restore against a 2b share tombstone would revive a node with
        `storage_path` NULLed while its bytes sit in `.trash`). `begin_upload`/`finalize_upload`
        gate on **`syncable`**, not on `!port_writable?`: they need `Sync::Commit`, which is what
        `syncable` names — a backend with neither flow would be told "use the two-phase flow" by
        the derived gate and 500 inside it.
      - **The web trash is backend-neutral; the v1 trash is 501-gated. Same word, two surfaces,
        two answers, deliberately.** `trashed` is a **read** every adapter answers (chunk
        delegates to `Sync::Trash`), and `TrashController#restore` branches on `port_writable?`
        exactly as `#destroy` does — because what "restore" *means* differs (a tombstone in chunk
        mode, moved bytes on share/s3). The v1 trash is an API for the chunk mechanism only.
      - **`Delivery`'s three variants** — `Redirect(url)` / `SendFile(path)` / `Stream(enum)` —
        are three **mechanisms**, not three styles, and **§15 survives on S3 (`Redirect`) but not
        on share** (spec §2 decision 6): a mounted directory has nothing to presign. Do not "fix"
        the share case back to a presign. The disposition is **not** carried on the type: it goes
        *in* to `#download` and comes out *applied* (Redirect signs it into the URL, SendFile
        passes it, Stream sets a header).
      - **`send_file` + `x_sendfile_header` is the whole X-Accel story — there is no nginx here.**
        Deployment is **Kamal + kamal-proxy** (a Go proxy) and `x_sendfile_header` is **nil**, so
        `Rack::Sendfile` no-ops and the `Rack::Files` branch is **the only one that runs**. We
        call `send_file` and let Rails' existing knob do it; **nothing hand-rolled**. The knob is
        documented **commented** in `production.rb` on purpose: kamal-proxy does not implement
        x-sendfile, so enabling it would **silently serve empty bodies** for every share download.
      - **`FetchError` → 503** and **`UnsupportedOperation` → 422**, mapped once at
        `FilesController` rather than per-action. The 503 matters: an unmounted NAS must never
        read as the terminal 404 "your file is gone".
      - **`Chunk#download`'s `is_a?(S3ChunkStore)` is deliberately NOT `presignable?`** — the
        memory and local stores presign to URLs **Rails itself serves**, so redirecting to one
        sends the browser back through us. §9a-3/§9a-4 stay open; Phase 4 does not force them,
        and this is why. (The `chunks.size == 1` half is load-bearing too: a redirect names ONE
        object, so redirecting a multi-chunk file would hand the browser its first chunk with a
        200 and the right filename — **silent truncation**.)
      - **A final whole-branch review found five more, all fixed before merge (2026-07-17), and
        the pattern in them is the lesson.** Four of the five were **already recorded as
        unreachable, deferred, or verified** — the review's contribution was *checking* rather
        than *reasoning*, and every check that mattered was a probe:
        - 🔴 **A share/s3 deployment's ENTIRE v1 API answered 500** — `stash_request_base_url`
          resolved `Storage::ChunkStore.current` before every v1 action, and `STORAGE_BACKEND`
          defaults to **`s3` outside test** → `KeyError: CHUNK_BUCKET` for an operator who
          correctly set only `LIBRARY_*`. Login, `/v1/maker/*`, the anonymous `/v1/share/:token`,
          and **every gated endpoint 500 instead of 501** — the gate was perfect and unreachable,
          producing exactly the 500 spec §6 forbids. **The suite was green with and without the
          fix**: all nine gating tests set `FileLayer.current` and never touched
          `STORAGE_BACKEND`, which is **`memory` in test and `s3` in production** — so *none of
          them could fail for the reason they existed*, including the one Task 7 had just written
          to replace a vacuous test. Now gated on the capability that names a chunk data plane
          (`syncable`; `versioned` on `V1::ShareController`, matching its own owner-side gate) and
          pinned by `NoChunkStoreTest`, which runs with production's default and `CHUNK_*` unset.
          **A share/s3 deployment sets NO `STORAGE_BACKEND` and NO `CHUNK_*`** — `docs/STATUS.md`
          now says so, and the hand-verification it records was re-driven without them.
        - 🟠 **`FilesController#destroy` orphaned a directory's children in chunk mode** —
          `Sync::Mutation.apply(op: "delete")` tombstones only the node it is handed, so
          `/v1/tree` kept serving live children under a deleted parent while a
          changelog-following device dropped the subtree. **`Chunk::DELETE_MSG` named the right
          door (`Sync::SubtreeDelete`) three lines above the branch that used the wrong one.**
          Pre-existing; what Phase 4 added is the contradiction.
        - 🟠 **`Share#absolute_path` resolved a NULL `storage_path` to the library root** — and
          `#download` handed that **directory** to `send_file`. `read`/`delete`/`move` escaped
          only by *accident* (EISDIR, EINVAL); `download` has no read to hide behind. `allow_root:`
          is **gone**, not switched off: its justification ("a read may resolve to the root —
          harmless, `File.binread` of a directory is EISDIR anyway") was made false by Phase 4's
          `download`, and no producer ever wanted it. `S3#key_for` has had the check since Phase 3.
        - 🟡 **`Share#undelete` was missing `observable!` — and the "unreachable" was wrong.** It
          reconstructs its destination from the tombstone's **parent**, so a poisoned parent
          restores into `.maker-tmp-evil/` → a live node the Scanner skips at any depth → an
          unpairable ghost → **permanent mass-deletion wedge**. **The FOURTH instance of 2b's
          skip-list blind spot, each found only after the previous explanation said it couldn't
          happen.** All three writing paths now ask.
      - ~~**Shipped knowingly, do not let these fall off:** a measured N+1 in
        `FilesController#index`; `Share#write`/`S3#write` raise `NotFound` for a clobber.~~
        **BOTH CLOSED by the phase 4 follow-up — see the bullet below.** ~~The **unexplained
        intermittent** stays open: two agents each saw one `1 errors` run that never reproduced
        (~73 and ~15+ subsequent full runs), **neither captured the message**.~~ **CAPTURED
        2026-07-27** (`SQLite3::BusyException` in `Tools::GeneratorsControllerTest`'s `setup`) —
        **still unexplained, but no longer unobserved**, and the cross-worker cause offered with
        the capture is **disproved**: each parallel worker has its own SQLite file
        (`storage/test.sqlite3_0…_9`), so the lock holder is inside the failing worker. Full
        record + the corrected `test/test_helper.rb` comment: `docs/STATUS.md`, "The intermittent".
    - **Phase 4 follow-up DONE** (2026-07-17, branch `worktree-file-layer-followup`, 4 commits) —
      the three items phase 4 left open. Suite **954 → 978**, **identical on all three legs**
      (each **978 runs / 3029 assertions / 0 failures / 0 errors / 5 skips**). The decisions a
      future reader must not undo:
      - **`stat_all` IS A PORT VERB, AND IT IS NOT PAGINATION'S RIVAL.** The measured N+1 is
        closed: `GET /files` at 2000 nodes went **chunk 676→159 ms / 4002→4 queries**, **share
        439→160 / 2002→3**, **s3 444→162 / 2002→3**. The two fixes solve *different* problems and
        compose — `stat_all` removes the per-row query, pagination bounds the render — and this
        phase did the port one because the port is its lane. **The evidence the verb was missing:
        `Chunk#trashed` had already hand-rolled its exact two-query shape privately** ("One query,
        not one per node"), because the port could not express it and `FilesController#index`
        holds an *adapter*, not a `Chunk`. **Pagination is NOT deferred work this created**: the
        page never paginated, and what is left at 2000 nodes is ~160 ms of render — **now
        identical on all three backends**, which is the evidence the port's cost is gone and the
        residual is HTML.
      - **THE CONTRACT'S THIRD TEST IS THE ONLY ONE A LOOP FAILS**, and that is the lesson, not a
        detail. `stat_all` is pinned on three things in the shared READ contract (all three
        adapters): it answers exactly what `stat` answers; **a missing node is an ABSENT KEY, not
        a raise** (stat is asked about ONE node so NotFound is its whole answer — a bulk caller
        holds a LIST, and a row tombstoned mid-page must not 404 the page, which is what looping
        stat did); and **the query count does not grow with the list**. Mutation-verified:
        reverting all three adapters to `node_ids.map { stat }` is RED on the third **only** — the
        first two stay GREEN, because a loop is behaviorally identical. Asserted as *constant in
        N* rather than against a literal, since chunk needs 2 queries and share/s3 need 1: a
        literal would encode one backend's shape into a contract every backend runs.
      - **A CLOBBER IS `UnsupportedOperation`, ON THE AXIS THE TAXONOMY ACTUALLY HAS.** Both
        adapters raised `NotFound`, so a duplicate-name upload said **"File not found."** about a
        file in the list behind the alert. "Unsupported" reads oddly for it — share and s3 support
        writing fine, they refuse *this one* — and **that reading is the "how unsupported" axis
        `file_layer.rb` explicitly rejects**. On the real axis (**who is wrong, and when can you
        know**) a clobber is indistinguishable from the directory delete the class was written
        for. `FetchError` would be worse, not better: it is the RETRYABLE answer and a clobber
        never succeeds on retry. **If a caller ever needs to branch, the answer is a SUBCLASS** —
        every rescue keeps working.
      - **ALL THREE VERBS MOVED TOGETHER.** "The destination is taken" is ONE condition and
        `write`/`move`/`undelete` all meet it; fixing only the `write` the review named would have
        left renaming onto a taken name saying "File not found." while uploading onto one got an
        honest 422 — **one condition, two answers, inside one adapter**. The write contract pins
        the class **per-verb** for that reason.
      - **THE s3 WEB-WRITE COVERAGE FOUND A 500 ON ITS FIRST RUN, AND THE SHAPE IS THE POINT.**
        `TrashController` rescues `NotFound` but not `UnsupportedOperation`, so the clobber fix
        turned an occupied-destination restore into an uncaught 500 — **while the controller's own
        rescue comment already named that case** ("something is already at that path") as one of
        the four it exists to catch. The class moved out from under a sentence that still claimed
        it. Reading the rescue would not have shown it; **driving it did.** Reachable on share by
        the same route, so both adapters pin it now. **The gap was in the CONTROLLER, not in
        either adapter** — which is why no adapter suite could have found it, and the answer to
        "the `port_writable` branch is shared, so the asymmetry is low-risk".
      - **`docs/STATUS.md`'s open list was itself stale**, and two of its five entries claimed
        holes the code did not have: `Share#undelete`'s missing `observable!` and
        `Share#absolute_path`'s `allow_root:` were **both fixed by phase 4's own whole-branch
        review** and never retracted (`allow_root` survives only in the comments describing its
        removal — verified against the code, not the history). **A stale open-list is worse than
        none**: it spends the next reader's attention on finished work.

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
STORAGE_BACKEND=s3 CHUNK_ENDPOINT=http://192.168.1.8:8333 CHUNK_BUCKET=my-bucket \
CHUNK_REGION=us-east-1 CHUNK_ACCESS_KEY_ID=admin CHUNK_SECRET_ACCESS_KEY=secret \
  bin/rails server -p 3001
# …then push/hydrate real bytes through SeaweedFS via presigned URLs:
(cd client/sync-engine && SERVER_URL=http://localhost:3001 cargo run --example presigned_roundtrip)

# The daemon (mount + continuous loop). Needs a device token (register via the API) and
# the FUSE-T pkg-config alias + rpath (sync-engine has its own .cargo/config.toml now):
# PKG_CONFIG_PATH=/tmp/fuse-pc:/usr/local/lib/pkgconfig cargo build --bin maker-syncd
# ./target/debug/maker-syncd <mnt> <db> <chunks> http://localhost:3001 <device_token>

# Rust crate tests (per-suite counts in docs/STATUS.md)
(cd client/fs-provider && cargo test)   # chunking/posix/convergence/concurrency/caching (hermetic)
(cd client/sync-client && cargo test)
# sync-engine integration needs a running server (skips cleanly without one):
# SYNC_VERIFY_FINALIZE=0: finalize's verify-the-bytes-landed check defaults ON, but the engine
# suites move chunk bytes through SharedDirIO (a shared-dir cloud stand-in), not the server's
# store — so the server can't see them. See config/initializers/finalize_verification.rb.
STORAGE_BACKEND=memory SYNC_VERIFY_FINALIZE=0 bin/rails server -p 3001 &   # then:
(cd client/sync-engine && SYNC_IT_SERVER_URL=http://localhost:3001 cargo test --test integration)

# External conformance (battle-tested tools vs our real mounts — client/test-conformance/):
client/test-conformance/webdav-rclone.sh      # rclone ⇄ WebDAV round-trip (macOS+Linux)
client/test-conformance/fsx-fuse.sh           # fsx data-integrity exerciser ⇄ FUSE (Linux)
client/test-conformance/pjdfstest-fuse.sh     # pjdfstest POSIX map ⇄ FUSE (Linux, informational)

# Two-device REAL-MOUNT E2E (a file through ONE real kernel mount, read byte-for-byte through
# ANOTHER device's real mount — the layer above sync-engine/tests/two_device_e2e.rs). Uses
# STORAGE_BACKEND=local (real presigned data plane; memory:// can't move bytes). Per OS:
client/test-conformance/two-device-fuse.sh           # Linux, two real FUSE mounts (self-contained, CI-automatable)
client/test-conformance/two-device-webdav-macos.sh   # macOS, two real WebDAV mounts (run AT the machine — interactive)
client/test-conformance/two-device-cfapi.ps1         # Windows, two real CfAPI sync roots (interactive runner + deployed server)
# CI: `gh workflow run rust-client.yml -f target=two-device` (Linux auto; Windows on the interactive runner).

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

> The condensed **abandoned/superseded approaches** (remote mount, JuiceFS data plane,
> Cloudflare-native sync, WinFsp-as-default, last-writer-wins, the `mtime=now` hack, FSKit) —
> *what was considered → why rejected → current approach* — live in **`docs/roads-not-taken.md`**.
> Read it before reviving any of them.

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
  **Active Storage's `direct_uploads` route is REMOVED** (2026-07-29), because it was the one
  standing hole in this: `ActiveStorage::DirectUploadsController` descends from
  `ActiveStorage::BaseController`, **not** `ApplicationController`, so it shipped live and
  **unauthenticated** — an anonymous POST minted a real `Blob` and returned a signed upload URL.
  `config/routes.rb` shadows it with a 404. **The shadow path derives from
  `ActiveStorage.routes_prefix` and must never be hard-coded** (the engine scopes its own routes to
  that prefix, so a literal silently stops shadowing anything if it is ever configured), and
  `draw_routes = false` is NOT the fix — `Maker::Preview` uses `has_one_attached :asset` served via
  `url_for`, so the blob routes are load-bearing. Verify by driving a real request:
  `recognize_path` reports the engine's route for a proc endpoint and is the wrong instrument.
  Rich text is text-only on the server too (`Maker::TextOnlyRichText`), not just in the editor.
- **Local-first**: metadata reads hit local SQLite, never the WAN.
- Content-addressed chunks + immutable versions everywhere; **keep versions** for restore.
- Adapter-agnostic server code (SQLite + Postgres) without perf compromise.
- Write tests; verify end-to-end against the live server when wiring sync.
- **CI runs on SELF-HOSTED runners only — never GitHub-hosted.** Every job uses
  `runs-on: [self-hosted, linux|macos|windows]`. **Only ONE runner is registered today (2026-07-29):
  `charless-MacBook-Pro-maker-mac` (macOS). `flasher-maker-linux` and `CHAIMDESK-maker-windows` are
  NOT registered** — verify with `gh api repos/:owner/:repo/actions/runners` rather than trusting this
  line. Consequence: all 7 `ci.yml` jobs target linux and **queue forever** rather than failing, so a
  PR sits UNSTABLE at 0 elapsed and merging needs `--admin` (PR #94 did). Verify locally instead —
  see `docs/STATUS.md`, "CI cannot run".
  GitHub bills *only* hosted runners (`ubuntu/macos/windows-latest`; macOS 10×, Windows 2×),
  and self-hosted runners are **free** (confirmed against GitHub's billing docs, 2026-06-17).
  So **never add `*-latest` to a workflow** — any new job/workflow must target self-hosted.
  Self-hosted machines are persistent, so make dep-install steps idempotent (apt/choco/brew
  no-op if present) and don't assume the clean preinstalled toolchain of a hosted image.
- Update this file **and** `docs/STATUS.md` when the architecture moves.
