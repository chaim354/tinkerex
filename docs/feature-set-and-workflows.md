# Feature set & workflows — what the file system does TODAY

**Date:** 2026-06-14 · **Branch:** `auth-caching-security` · **Scope:** the file-sync layer
(the maker product layer — projects/inventory/BOM/preview — is not built; see §12 step 9 in
`CLAUDE.md`).

This is an evidence-based capability map. Every "supported" claim cites the code, test, or
conformance result that proves it, with a verification tier:

- **verified live** — exercised against real hardware / the deployed server (live smoke,
  conformance run, or in-app demo).
- **tested (hermetic)** — covered by an automated test (unit / integration / convergence /
  conformance), but not a live-hardware demo.
- **built, not verified** — code-complete and compiles, but no test or live run proves it.

Use-case grounding: a maker managing 3D files (STL/3MF/OBJ), CAD (STEP/IGES, native
Fusion/FreeCAD/SolidWorks), LightBurn (`.lbrn2`), across a workstation + laptop, with large
libraries, self-hosted or via a managed service (`CLAUDE.md` §1).

---

## Part 1 — Supported feature set (today, with proof)

### Files & sync

| Feature | What it does | Proof | Tier |
|---|---|---|---|
| Create / read / write / delete / rename / mkdir through a native mount | Standard file ops on the synced folder, backed by a local SQLite tree (instant `stat`/`readdir`/`open`) | `client/fs-provider/src/lib.rs` (`apply_remote`, `delete_by_node_id`, `rename_by_node_id`, `ingest_bytes`); `fs-provider/tests/posix_semantics.rs` (12 tests) | tested (hermetic) + verified live |
| Content-defined chunking (FastCDC) + dedup | Files split into ~1–4 MB content-addressed chunks; identical chunks stored once; a small edit re-uploads only changed chunks | `fs-provider/tests/chunking.rs` (11 tests incl. block-delta boundary stability, dedup, proptest) | tested (hermetic) |
| Push: local write → server commit → chunks to object storage | A write enqueues an outbox entry; `push_outbox` commits (begin → upload missing chunks → finalize); bytes go client ⇄ storage via presigned URLs, never through Rails | `sync-engine/src/lib.rs` (`push_outbox`); `examples/roundtrip.rs`, `presigned_roundtrip.rs` (real bytes to SeaweedFS `192.168.1.7:8333`, byte-for-byte) | verified live |
| Pull: changelog delta → apply to local tree | Devices pull `seq > cursor`; `pull_changes` pages the backlog (no dropped entries) and full-resyncs if its cursor fell below the server's retained `oldest_seq` | `sync-engine/src/lib.rs` (`pull_changes_paged`); STATUS.md "offline/reconnect hardening" (`pull_changes_pages_through_a_backlog…`) | tested (hermetic) + verified live |
| Hydrate-on-read | Reading a not-yet-downloaded file fetches its missing chunks via presigned GET, then serves bytes | `sync-engine/src/lib.rs` (`hydrate`, `EngineHydrator`); `fs-fuse` `Hydrate` hook; live in `daemon_loop.rs` | verified live |
| Delete / move propagation across devices | A delete removes the node + whole subtree (recursive CTE, idempotent); a move updates the node row in place (same stable `node_id`) | `fs-provider` `apply_remote_delete`; `sync-engine/examples/delete_move.rs` (A deletes+moves, B converges via delta pull) | verified live |
| Truncate / overwrite-with-shorter | `O_TRUNC` and shrink leave no stale tail on any OS (`setattr(size)` / WinFsp `set_file_size` / truncating WebDAV PUT) | `fs-provider` `truncate`; `overwrite_with_shorter_leaves_no_stale_tail` test | tested (hermetic) |
| Continuous daemon loop + instant nudge | Background loop: outbox→push then changelog pull; an ActionCable `{head_seq}` broadcast wakes it in ~39 ms (poll fallback otherwise) | `sync-engine/src/daemon.rs`; `sync-client/examples/nudge.rs` (~39 ms local, ~130 ms deployed) | verified live |
| Offline reads | A hydrated file reads with no network (chunk cache persists; engine fetches only missing chunks) | STATUS.md `hydrated_file_stays_readable_offline` (dead server + erroring transport still reads) | tested (hermetic) |
| Real mtime preservation | True modification time synced end-to-end in unix nanoseconds (no more `mtime=now` hack that broke build tools); `utimensat`/`cp -p` via `set_mtime` | `fs-provider` `set_mtime`; integration `real_mtime_propagates_across_devices` (A's 2001 mtime verbatim on B) | tested (hermetic) |
| File-mode (executable bit) preservation | `chmod +x` syncs across devices (0644/0755) | server + integration `executable_bit_propagates_across_devices` | tested (hermetic) |

### Versioning & restore

| Feature | What it does | Proof | Tier |
|---|---|---|---|
| Native immutable versioning | Every commit = an immutable version → manifest; chunks refcounted + shared; versions kept (not pruned) | server `Sync::*`, `versions` model; CLAUDE.md §5 | tested (hermetic) |
| Version history (per file) | List all versions of a file, newest first, with size + timestamp | `maker-app` `file_versions` command → `GET /v1/nodes/:id/versions` | built, not verified (live) / API tested |
| Restore an old version | Re-point a node at an old manifest (zero new blocks, lossless); sync loop propagates it | `maker-app` `restore_version` → `POST /v1/nodes/:id/restore`; server restore tests (reuse manifest, bump refcounts, undelete, chain) | tested (hermetic) |

### Conflict detection & locking

| Feature | What it does | Proof | Tier |
|---|---|---|---|
| Conflict detection (not LWW) | Each commit sends its `base_version_id`; a stale base (divergent offline edit) records a conflict keeping both versions, instead of silently dropping an edit. Same-device stale base fast-forwards | server `Sync::Commit`/`Sync::Conflicts`; integration `offline_divergent_edit_raises_a_conflict`, `sequential_edits_fast_forward_without_a_conflict` | tested (hermetic) |
| Conflict resolution (keep / split) | Keep one side current, or split (incoming becomes a sibling "foo (conflict from …)" reusing its manifest, zero new blocks) | `maker-app` `conflicts`/`resolve_conflict_keep`/`resolve_conflict_split`; `conflicts_test.rb` | tested (hermetic) |
| Local advisory locks | POSIX byte-range advisory locks (`setlk`/`getlk`), owner-tracked, released on close | `fs-provider/src/locks.rs` `LockManager` (7 unit tests); `fs-fuse` wires `setlk`/`getlk` | tested (hermetic) |
| Best-effort cross-device edit lock | On open-for-write, acquire a server TTL lock so other connected devices see "being edited"; never blocks (offline just proceeds, conflict detection reconciles) | server `Sync::Locks` + `FileLock` (`locks_test.rb`, 6 tests); `EngineRemoteLock`; integration `best_effort_lock_coordinates_connected_devices`; app shows a 🔒 + holder | tested (hermetic) + verified live |

### Mounts (per-OS, all over the same `Provider`)

| OS | Backend | What it does | Proof | Tier |
|---|---|---|---|---|
| **Windows** | **CfAPI** (default, driverless — no GPL driver) | Sync-root folder, on-demand enumerate (`FETCH_PLACEHOLDERS`) + hydrate-on-open (`FETCH_DATA`) + remote-change invalidation + local edit/create/delete/rename capture (`ReadDirectoryChangesW`) | `client/fs-cfapi`; `windows-smoke` GREEN (7 checks incl. delete + rename); `cfapi-conformance` GREEN (24 files, churn, byte-for-byte on fresh device) | verified live (Win 11) |
| **Linux** | **FUSE** (`fuser`) | Drive mount; full op set + hydrate hook + kernel cache invalidation (`notify_inval_inode`) | `client/fs-fuse`; verified in Finder/live; `fsx-fuse.sh` conformance (100k randomized ops, no mismatch) | verified live |
| **macOS** | **WebDAV** (native `mount_webdav`) | Mount via native WebDAV (no kext/FUSE — FUSE-T can't mount on macOS 26) | `client/fs-webdav`; `webdav-rclone.sh` (rclone copy+check, 0 byte differences) | verified live |
| (Windows alt) | WinFsp (drive letter) | Earlier Windows path, behind `winfsp-backend` cargo feature for one release | `client/fs-winfsp`; compiled by `windows-build` CI | built, not verified (host) |

Caveats:
- macOS / FUSE-T native mounts need an **interactive session** (won't hold a mount headless).
- **POSIX-perms gaps are deliberate** (uid/gid/ownership, symlinks/hardlinks/special files,
  ctime/atime not synced — meaningless or out-of-scope for a personal maker drive). Mode/`+x`
  IS preserved.
- CfAPI **pin/unpin** + real "remove library" lifecycle (`CfUnregisterSyncRoot`) are roadmap
  (B6 polish, `docs/plan-windows-cfapi-migration.md`), not yet done.
- The live CfAPI write-path net (`windows-smoke`/`cfapi-conformance`) is on-demand, not a
  per-PR gate (HANDOFF.md blocker 3).

### Auth & devices

| Feature | What it does | Proof | Tier |
|---|---|---|---|
| Account registration (takeover-safe) | `register` creates a NEW account only (409 on existing email) — closed the `find_or_create_by` takeover hole | `auth_controller.rb`; `auth_test.rb` | tested (hermetic) |
| Device pairing (multi-device) | A new device joins an existing library via a single-use, 10-min, SHA256-digested pairing code minted by a signed-in device (Syncthing/Plex model) | `DevicePairing`; `POST /v1/devices/pairing` → `/v1/auth/pair`; `maker-app` `create_pairing`/`sync_pair`; live pairing integration test | tested (hermetic) + verified live |
| Token persistence | Device registers/pairs once, token saved + reused (never re-registers) | `maker-app/src-tauri/src/lib.rs` (`load_token`/`save_token`) | built, not verified |
| Cross-user isolation | Presigned URLs SigV4-signed for per-user key `chunks/<user>/<hash>` (untamperable); `/v1/chunks/download` mints only for owned chunks; node mutations scope through `current_user.nodes` | `chunks_controller.rb`; expanded `tenant_isolation_test.rb` | tested (hermetic) |
| Per-account local state | Local tree.db + chunk cache keyed by `(server, email)` so switching accounts can't surface another account's files | `maker-app` `account_dir`; `Provider::bind_library` (stale-DB guard, all 4 mounts) | tested (hermetic) |

### Storage & deployment

| Feature | What it does | Proof | Tier |
|---|---|---|---|
| S3-compatible chunk storage | Presigned PUT/GET to any S3 store (R2 managed, SeaweedFS/MinIO self-host) | `STORAGE_BACKEND=s3`; `presigned_roundtrip.rs` live vs SeaweedFS | verified live |
| Deployed server (Kamal) | Rails server deployed on an Unraid VM, SeaweedFS chunks, `/up`→200; client mounts+syncs against it on all 3 OSes | `docs/DEPLOY.md`; HANDOFF.md "Server" (56 server tests green) | verified live |
| Adapter-agnostic DB | Same models on Postgres (managed) or SQLite (self-host); switch is config-only | CLAUDE.md §7; tested on SQLite | tested (hermetic, SQLite) — **Postgres deploy NOT yet validated** (§12 step 8) |

---

## Part 2 — Supported workflows TODAY

Each enabled by the Part-1 features. These are things a maker can actually do now.

1. **Two-machine sync of a design file.** On my workstation I save a STEP/STL into the synced
   folder; the daemon chunks + pushes it; within ~40 ms my laptop (paired, same library) gets
   the nudge, pulls the metadata, and the file appears as a placeholder. (push + nudge + pull,
   all *verified live*.)

2. **On-demand hydration of a large library.** My laptop shows the whole tree as placeholders
   without downloading 100 GB; opening one file hydrates just that file's chunks on read.
   (hydrate-on-open, *verified live*; Windows CfAPI placeholders *verified live*.)

3. **Automatic versioning + restore.** Every save is an immutable version. In the app I open a
   file's history, see each version with size + timestamp, and one-click restore last week's
   STEP — losslessly, with zero new chunks uploaded. (`file_versions`/`restore_version`; restore
   *tested hermetic*.)

4. **Efficient iterative edits on big files.** I tweak one feature in a 200 MB CAD file and save;
   FastCDC re-chunks and only the changed chunks upload (block-delta), not the whole file —
   unlike Nextcloud/ownCloud. (chunking + dedup, *tested hermetic*; beats whole-file systems per
   research §3.)

5. **Offline editing on the bench, reconcile later.** I unplug the laptop, keep working on
   already-hydrated files (reads + writes work from the local cache), then reconnect — queued
   writes push, the changelog delta applies, and I'm converged. (offline reads *tested*; offline
   reconcile *tested*.)

6. **Safe concurrent edits across machines.** I edit a file on both machines while offline; on
   reconnect the system detects the divergence and keeps BOTH versions, then prompts me to keep
   one or split into two files — no silent data loss. (conflict detect + keep/split, *tested*.)

7. **Atomic app saves don't corrupt the tree.** Apps that save via write-temp-then-rename (most
   CAD/editors) work correctly — rename POSIX-replaces and tombstones the displaced node.
   (`rename` fix, *tested*.)

8. **Cross-platform working set.** I work on Windows (CfAPI folder), Linux (FUSE drive), and
   macOS (WebDAV mount) against the same library and deployed server, byte-for-byte consistent.
   (all 3 mounts *verified live*; CfAPI byte-for-byte conformance GREEN.)

9. **Build-tool-friendly mtimes.** A synced source tree keeps real modification times, so
   `make`/`cargo`/`ninja` incremental builds aren't tricked into rebuilding everything.
   (real-mtime preservation, *tested*.)

10. **Add a new device securely.** From a signed-in machine I mint a pairing code; on the new
    machine I redeem it to join the library — no shared password, no account-takeover surface.
    (pairing, *tested + verified live*.)

11. **Self-host or managed, same client.** I point the same app at my own Unraid box
    (SQLite + SeaweedFS) or a hosted server (Postgres + R2); only creds differ. (deployed via
    Kamal, *verified live*; Postgres path config-only but **not yet validated**.)

12. **See who's editing what.** When a teammate-device (my own other machine) has a file open
    for write, the browser shows a 🔒 + the holder's device name. (best-effort lock, *tested +
    verified live*.)

---

## Part 3 — Gap workflows (fit the maker, NOT yet supported)

Each gap notes whether it's a **FILE-LAYER gap** (the sync engine can't do it) or a
**maker-APP gap** (the product surface in `CLAUDE.md` §12 step 9 simply isn't built).
Cross-referenced to the roadmap (CLAUDE.md §12) and research rankings (`research-sync-competitors.md` §4).

### File-LAYER gaps (the sync engine can't do it yet)

1. **Selective-sync a subset of a 100 GB library to a laptop.**
   *Workflow:* "On my laptop, only sync the *Active Projects* folder; leave the 90 GB archive as
   metadata-only." *Why it fits:* makers accumulate huge libraries; a laptop SSD can't hold it
   all, and even placeholder enumeration of everything is undesirable. *Missing:* per-device
   subtree subscriptions + a client-side hydration gate (server tree stays complete). **Not
   built** — research §4 **#2 (ranked highest-leverage ergonomic gap)**; deferred in CLAUDE.md
   §2/§14 ("full tree on every device"). FILE-LAYER.

2. **Encrypted-at-rest libraries for the managed service.**
   *Workflow:* "On the hosted service, encrypt my CAD before it leaves my machine so the host
   can't read it." *Why it fits:* the SaaS trust story; makers ship commercial/IP-sensitive
   designs. *Missing:* per-user AEAD chunk encryption with content-addressing over ciphertext to
   preserve dedup. **Not built** (grep: no `encrypt` in client/server) — research §4 **#3**;
   CLAUDE.md §12 step 5 "chunk encryption" listed but unimplemented. FILE-LAYER.

3. **Open a 2 GB file and read just the header without full hydration.**
   *Workflow:* "Peek at a slicer/CAD file's metadata without downloading the whole multi-GB
   file." *Why it fits:* large 3D/CAD files; previewing or indexing shouldn't pull everything.
   *Missing:* range/progressive hydration policy (the manifest already maps ranges→chunks, but
   the mount hooks fetch per-chunk-on-read with no big-file range strategy). **Partial** —
   research §4 **#9**. FILE-LAYER.

4. **Bandwidth-throttle a big upload.**
   *Workflow:* "Cap upload to 2 MB/s while pushing a 5 GB project so I keep usable internet."
   *Why it fits:* makers on home/shop connections pushing large libraries. *Missing:* client-side
   rate caps in the chunk-transfer layer (no protocol change needed). **Not built** (grep:
   "throttle" exists only for the freshness-pull, not transfer) — research §4 **#6**. FILE-LAYER.

5. **LAN-sync between two machines on the same bench.**
   *Workflow:* "Workstation and laptop on the same shop LAN sync a 5 GB project directly, not
   round-tripping through the cloud." *Why it fits:* common maker setup (two machines + a NAS on
   one switch); much faster + no egress. *Missing:* mDNS/UDP peer discovery + hash-verified peer
   chunk fetch (must never serve a chunk cross-user — cf. Dropbox CVE-2021-28171). **Not built**
   — research §4 **#5**. FILE-LAYER.

6. **Share a project folder with a collaborator (different user).**
   *Workflow:* "Give my co-designer access to just the *Lamp v2* folder." *Why it fits:* makers
   collaborate / hand off to a fabricator. *Missing:* multi-user sharing primitive (Spaces-style)
   — new authz + cross-user dedup rework + changelog scoping; today **tenant = user** (one
   library = your own devices). **Not built** — research §4 **#7** (High effort, business
   decision); CLAUDE.md §8 "deferred". FILE-LAYER (also a product decision).

7. **Versioned CAD without unbounded storage growth.**
   *Workflow:* "Keep useful history but don't let 200 versions of a 200 MB assembly balloon my
   bucket forever." *Why it fits:* heavy versioning of large files is exactly the maker pattern;
   unbounded growth is a live cost/correctness bug, not a feature. *Missing:* a **scheduled
   retention/GC policy job** + actual S3 `delete_object`. The *mechanism* exists
   (`Sync::Gc.prune_version!`/`sweep_orphans!`/`prune_changelog!` in `app/services/sync/gc.rb`)
   but there is **no scheduled job** (`app/jobs/` has only `application_job.rb`) and **no S3
   delete wired**. **Partial / not wired** — research §4 **#1 (highest-leverage overall)**.
   FILE-LAYER.

8. **Real email-verified sign-in (OAuth/OIDC).**
   *Workflow:* "Sign in with a verified email / Google on the managed service." *Why it fits:*
   table-stakes for a SaaS; the current bootstrap proves device possession, not email ownership.
   *Missing:* OmniAuth/OIDC email verification (the device-token + pairing mechanism stays
   underneath). **Partial** (pairing done, OIDC not) — research §4 **#8**; CLAUDE.md §12 step 5.
   FILE-LAYER (auth).

9. **Native macOS mount (Finder-integrated, no WebDAV).**
   *Workflow:* "A first-class macOS sync-root with on-demand placeholders like CfAPI on Windows."
   *Why it fits:* macOS makers want the OneDrive-class experience, not a WebDAV mount. *Missing:*
   FSKit — a **design sketch** (`docs/plan-macos-fskit-migration.md`; no `client/fs-fskit` crate
   exists yet), additionally **blocked on a paid Apple Developer membership** ($99/yr) for
   extension residency on macOS 26. **Platform-blocked + unbuilt** — HANDOFF.md blocker 2;
   `docs/plan-macos-fskit-migration.md`. FILE-LAYER (platform-blocked). *(Note: earlier handoffs
   described FSKit as "code-complete"; the dedicated plan doc and the repo show it is a sketch, not
   built — treat it as unbuilt.)*

### Maker-APP gaps (product surface simply not built — §12 step 9)

These are NOT file-system limitations. The sync engine references files by stable `node_id` and
is ready to support them; the product layer on top just hasn't been built.

10. **Preview an STL/3MF/CAD file in-browser.**
    *Workflow:* "Click a file in the web UI and see the 3D model / a thumbnail." *Why it fits:*
    core to a 3D/CAD maker tool (CLAUDE.md §1 "in-browser preview"). *Missing:* the Three.js
    browser viewer + FreeCAD/CadQuery server preview jobs — **not built** (grep: no `three.js`/
    `preview`/`thumbnail` anywhere). MAKER-APP (CLAUDE.md §4 "Preview (later)", §12 step 9).

11. **Manage inventory (materials/components, quantities, locations, suppliers).**
    *Workflow:* "Track filament/fasteners on hand, where they're stored, who I buy them from."
    *Why it fits:* one of the three product pillars (CLAUDE.md §1). *Missing:* the entire
    inventory model + UI — **not built** (no inventory models/controllers). MAKER-APP (§12 step 9).

12. **Projects + tasks + build log + a BOM that links to inventory and files.**
    *Workflow:* "A *Lamp v2* project: tasks, a build log, attached STEP files, a BOM whose rows
    link to inventory parts and to the synced design files." *Why it fits:* the third product
    pillar (CLAUDE.md §1). *Missing:* the projects/BOM model + UI (would reference files by
    `node_id`) — **not built**. MAKER-APP (§12 step 9). The file-layer groundwork it needs
    (stable `node_id`s, the browse/version/restore/conflict/lock UI) **does** exist.

---

## Executive summary

**Headline supported workflows (verified live unless noted):**
1. Save a design file on the workstation → it appears on the laptop in ~40 ms (push + ActionCable nudge + pull).
2. On-demand hydration — a huge library shows as placeholders; opening a file downloads only its chunks.
3. Automatic immutable versioning with one-click lossless restore from the app's history UI.
4. Block-delta edits — a tweak to a 200 MB CAD file uploads only changed chunks (beats whole-file systems).
5. Cross-platform consistency (Windows CfAPI / Linux FUSE / macOS WebDAV) with offline reads + safe conflict keep/split.

**Top gap workflows + what each needs:**
1. **Selective sync** (100 GB library, partial laptop) — per-device subtree subscriptions + hydration gate. *Not built* (research #2). FILE-LAYER.
2. **Versioned-CAD retention** — a scheduled GC job + S3 `delete_object`; the prune *mechanism* exists but isn't wired/scheduled. *Partial* (research #1). FILE-LAYER.
3. **At-rest/E2E chunk encryption** for the SaaS trust story — per-user AEAD over content-addressed ciphertext. *Not built* (research #3). FILE-LAYER.
4. **In-browser STL/3MF/CAD preview** — Three.js viewer + server preview jobs. *Not built*. MAKER-APP (§12 step 9), not a file-system limit.
5. **Inventory + projects/BOM** — the other two product pillars; models + UI unbuilt, file layer is ready (refs by `node_id`). MAKER-APP (§12 step 9).

Also notable: LAN sync, bandwidth throttling, collaborator sharing (all file-layer, research
#5–#7), real OAuth/OIDC (auth, partial), and a native macOS FSKit mount (a **design sketch,
not built** — no `client/fs-fskit` crate; additionally **blocked on a paid Apple membership**).
