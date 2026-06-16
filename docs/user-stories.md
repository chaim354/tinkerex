# File-system user stories + the offline-workshop workflow

**Date:** 2026-06-16 · **Scope:** the file-sync layer only (the maker product layer —
projects/inventory/BOM/preview — is not built; see `CLAUDE.md` §12 step 9). **Audience:**
a smart reader who hasn't read the code. **Honesty contract:** every story distinguishes
three states —

- **Works today** — exercised by code that exists on `main` (cited), verified live or by a
  hermetic test.
- **Engine-API exists, no UI** — the capability is implemented as a Rust library/engine
  function, but **nothing the end user touches** (no Tauri app button, no `maker-syncd`
  flag, no CLI) calls it. A developer could wire it in an afternoon; a user can't reach it.
- **Not built** — no code.

This doc is grounded in the actual capability code, not the marketing. Key sources:
`client/fs-provider/src/subscriptions.rs` (selective sync), `client/sync-engine/src/lib.rs`
(`hydrate`/`hydrate_range`/`proactive_hydrate`/`subscribe`), `client/sync-engine/src/daemon.rs`
(the running loop + `DaemonConfig`), `client/sync-engine/tests/integration.rs` (offline tests),
`client/maker-app/src-tauri/src/lib.rs` (the 11 Tauri commands the user actually gets),
`client/fs-fuse/src/lib.rs` (POSIX guardrails), `client/fs-cfapi/src/lib.rs` (Windows pin).

A companion capability map (with verification tiers) is `docs/feature-set-and-workflows.md`;
the competitive framing is `docs/research-sync-competitors.md` / `docs/parity-roadmap.md`.

> **Two-line orientation.** The file layer is a **local-first sync engine** (Dropbox/Drive
> shape), *not* a remote mount: every device holds the **full tree as local SQLite**, so
> browsing/stat/readdir is instant and offline; file **bytes** are content-defined chunks
> (FastCDC) fetched on demand ("hydrated") and cached locally. The product surface is a
> native mount per OS — **Linux FUSE, Windows CfAPI (driverless), macOS WebDAV** — all over
> the *same* `Provider`.

---

## 1. User stories — what the file system supports today

Each story is *"As a maker, I want to ___ so that ___"*, with a **Works today** note and a
precise **Limitation / gap** note.

### 1.1 Sync CAD / 3D / LightBurn files across my devices

> *As a maker, I want a file I save on my workstation to appear on my laptop automatically,
> so that I always have my current designs wherever I'm working.*

- **Works today.** Saving a file through the mount enqueues an outbox entry; the daemon's
  background loop (`SyncEngine::push_outbox`, `client/sync-engine/src/lib.rs`) commits it
  (begin → upload only the *missing* content-addressed chunks → finalize) and the bytes go
  **client ⇄ object storage via presigned URLs, never through Rails**. The other device gets
  an ActionCable `{head_seq}` nudge (~39 ms locally, ~130 ms against the deployed server),
  pulls the changelog delta, and the file appears. Verified live across all three OSes
  against the Kamal-deployed server (SeaweedFS chunk storage), byte-for-byte. File **content**
  is format-agnostic — STL/3MF/OBJ, STEP/IGES, native Fusion/FreeCAD/SolidWorks, `.lbrn2` all
  ride as opaque bytes; a 15-filetype conformance run found no corruption.
- **Limitation / gap.** The file arrives on the other device as a **placeholder** (metadata
  only) — its bytes download on first open, not eagerly, *unless* that device's selective-sync
  default keeps it resident (see §1.4). This is the right default for a 100 GB library on a
  laptop, but it means "appears on my laptop" = "is listed and openable", not "is already
  downloaded" — which is exactly the offline-workshop trap (§2). macOS/FUSE-T mounts need an
  **interactive** session (the mount won't hold from a fully headless process).

### 1.2 Automatic versioning + one-click restore

> *As a maker, I want every save kept as a restorable version, so that I can roll back a CAD
> file to last week without manually copying "v1/v2/final" files.*

- **Works today.** Versioning is **native**: every commit is an immutable version → a
  content-addressed manifest; chunks are refcounted and shared, and versions are **kept** (not
  pruned). The Tauri app has real commands for this: `file_versions` (list every version,
  newest first, with size + timestamp → `GET /v1/nodes/:id/versions`) and `restore_version`
  (`POST /v1/nodes/:id/restore`). A restore re-points the node at an old manifest — **zero new
  chunks uploaded, lossless** — and the sync loop propagates it to other devices.
- **Limitation / gap.** Restore re-pointing is hermetically tested; the app commands are
  **built but not verified against a live server demo**. More importantly, **retention is
  bounded only by a server-side GC** — `Sync::RetentionPolicy` (keep_all / tiered) + a nightly
  `RetentionJob` + S3 `delete_object` are wired, so history doesn't grow *unbounded*, but the
  client has **no "pin this version forever" UI** beyond the server's `pinned` flag (which has
  no app surface yet).

### 1.3 Browse the whole library instantly, even offline

> *As a maker, I want to navigate my entire file tree instantly without waiting on the network,
> so that finding a design feels like a local disk, not a cloud drive.*

- **Works today.** Every device mirrors the **complete tree** into local SQLite
  (`fs-provider`). `stat` / `readdir` / `lookup` / `getattr` are pure local SQLite reads — **the
  WAN is never in the metadata path** — so browsing is instant and works with no network at
  all. This is the core architectural bet (`CLAUDE.md` §2) and the reason the abandoned
  remote-mount approach (~1 s/file) was dropped.
- **Limitation / gap.** "Instant browse" means metadata; the file *contents* may still be
  online-only placeholders. Listing a folder is local; **opening** a not-yet-downloaded file
  needs the network (§2). There is no per-folder "X of Y files downloaded" indicator anywhere
  in the UI.

### 1.4 Selectively sync only a subtree to a space-constrained laptop

> *As a maker, I want my laptop to keep only my "Active Projects" folder resident and leave the
> 90 GB archive as online-only, so that my laptop SSD isn't swamped by a library it can't hold.*

- **Engine-API exists, no UI.** This is fully implemented in the engine and is the mechanism
  the whole offline-workshop workflow rests on, so it's worth being precise:
  - `client/fs-provider/src/subscriptions.rs` stores per-device **subscription rules keyed by
    stable `node_id`** (survives renames/moves) in a local `subscriptions` table. Each rule is
    `Include` or `Exclude` and applies to a node **and its whole subtree**; resolution walks up
    the ancestry to the nearest rule (a recursive CTE), falling back to a **default policy**.
  - The default is `Include` ("mirror everything") so selective sync is **opt-in** — until you
    exclude something, every device proactively downloads everything. A device that wants the
    Dropbox "subscribe to a few folders" shape flips the default to `Exclude` and includes the
    subtrees it wants (`set_subscription_default`).
  - The gate is `proactively_hydrate(node_id)`. After every pull, the **running daemon loop**
    calls `SyncEngine::proactive_hydrate` (via `sync_tick_debounced` in
    `client/sync-engine/src/daemon.rs`), which hydrates exactly the **in-scope** files that have
    missing chunks (`proactive_hydration_targets`). Out-of-scope subtrees are left as
    placeholders and fetched **only on demand** — graceful degradation, the OneDrive online-only
    model. `SyncEngine::subscribe` subscribes a subtree *and immediately hydrates* it;
    `unsubscribe` stops proactive hydration **and reclaims disk** by dropping that subtree's
    cached bytes (`dehydrate_subtree`, dedup-safe — it never drops a chunk an in-scope file
    still shares).
- **Limitation / gap (important).** **Nothing the user touches calls any of this.** The Tauri
  app's commands are `sync_start/sync_stop/sync_status/sync_pair/create_pairing/browse/
  file_versions/restore_version/conflicts/resolve_conflict_keep/resolve_conflict_split` — there
  is **no `subscribe`, no `set_default_policy`, no "make this folder available offline"** command.
  `maker-syncd`/`maker-cfsyncd`/`maker-webdavd` take only `<mnt> <db> <chunks> <url> <token>` —
  **no `--include`/`--exclude` flag**. So today selective sync is reachable **only from Rust
  code** (a test, an example, or a custom binary). The `docs/parity-roadmap.md` still lists
  selective sync among "remaining items" precisely because it needs an app/CLI surface, not new
  engine work.

### 1.5 Open a huge file and read just its header without downloading gigabytes

> *As a maker, I want to peek at a 2 GB CAD/slicer file's header or metadata without pulling the
> whole file, so that previewing or indexing doesn't cost me the entire download.*

- **Engine-API exists, no UI.** `SyncEngine::hydrate_range(node_id, offset, size)` fetches only
  the chunks overlapping `[offset, offset+size)` (the manifest records each chunk's offset/length;
  `manifest_range_hashes` maps the range → the minimal chunk set), and
  `hydrate_range_concurrent` does it over a bounded worker pool. The **CfAPI (Windows) read hook
  already uses range hydration** — `FETCH_DATA` for a byte range pulls only those chunks
  (`daemon.rs` `cfapi` hydrate closure). On FUSE/WebDAV the read hook currently calls the
  **whole-file** `hydrate_concurrent` (a `read` triggers a full download of that file).
- **Limitation / gap.** There's no *policy* that decides whole-vs-range from read intent on
  FUSE/WebDAV, and no user control over it; it's "first touch hydrates the whole file" on those
  two backends. Range hydration is proven by integration tests (a header read pulls a strict
  subset; chunks outside the range stay un-hydrated) but is wired end-to-end **only on CfAPI**.

### 1.6 Edit a 200 MB assembly and upload only what changed

> *As a maker, I want a small tweak to a big CAD file to upload only the changed parts, so that
> iterating on large assemblies doesn't re-upload hundreds of MB each save.*

- **Works today.** Files are split with **FastCDC content-defined chunking**; a small edit shifts
  only the chunks around the change (block-delta boundary stability is proptest-covered), and the
  commit uploads only chunks the server doesn't already have. Identical chunks are stored once
  (content-addressed dedup). This beats whole-file systems (Nextcloud/ownCloud re-send the file).
- **Limitation / gap.** Chunk **bandwidth caps** exist in the engine (`DaemonConfig::with_bandwidth`,
  a shared `RateLimiter` token bucket on up/down transfers) but, like selective sync, there's **no
  UI/CLI flag** to set them — engine-API only. An opt-in **outbox debounce** (coalesce rapid
  autosaves into one push, `Debounce::MAKER_DEFAULT`) is built and default-OFF.

### 1.7 Safe concurrent edits — no silent data loss

> *As a maker, I want the system to never silently throw away an edit when I change the same file
> on two machines, so that I can trust it with the only copy of my work.*

- **Works today.** Each commit sends its `base_version_id`. If that base is no longer current (a
  concurrent/offline edit slipped in), the server records a **conflict keeping BOTH versions**
  instead of last-writer-wins. The app surfaces it: `conflicts` lists them, and the user resolves
  with `resolve_conflict_keep` (keep one side) or `resolve_conflict_split` (the incoming side
  becomes a sibling `"foo (conflict from …)"`, reusing its manifest — zero new chunks). A base
  that *is* current is a clean fast-forward. Tested hermetically (`offline_divergent_edit_raises_a_conflict`,
  keep/split) and the lock path is verified live.
- **Limitation / gap.** Conflict resolution is **manual** (no auto-merge — correct for binary CAD,
  which can't be merged). There's a **best-effort** cross-device edit lock (a server TTL lock shows
  a 🔒 + holder on connected devices) but it **never blocks** — offline edits just proceed and
  reconcile via conflict detection. Two truly-offline machines editing the same file *will* produce
  a conflict to resolve on reconnect; that's by design, not a bug.

### 1.8 Atomic application saves don't corrupt the tree

> *As a maker, I want CAD apps that save via write-temp-then-rename to work correctly, so that a
> save never leaves a half-written or duplicated file.*

- **Works today.** `Provider::rename` POSIX-replaces an existing target and tombstones the
  displaced node (this was a real bug the conformance suite caught — `rename`-over hit a unique
  index and broke atomic saves; now fixed). `O_TRUNC` / overwrite-with-shorter leaves **no stale
  tail** on any OS (`truncate` via FUSE `setattr(size)` / WinFsp `set_file_size` / truncating
  WebDAV PUT). Torn-write safety is confirmed: finalize is atomic.
- **Limitation / gap.** None material for the maker save pattern; this is solid.

### 1.9 Preserve the executable bit on scripts

> *As a maker, I want a `chmod +x` build/flash script to stay executable on my other machines, so
> that my firmware/build tooling runs without re-chmod-ing everywhere.*

- **Works today.** File **mode** (0644/0755, the executable bit) is synced end-to-end across
  devices (`executable_bit_propagates_across_devices`). Real **mtime** is also preserved verbatim
  in unix nanoseconds, so `make`/`cargo`/`ninja` incremental builds aren't tricked into rebuilding.
- **Limitation / gap.** Only the executable bit / basic mode is modeled. **uid/gid ownership,
  full POSIX permission bits, ctime/atime, ACLs, xattrs are NOT synced** — deliberate non-goals
  for a personal maker drive (see §3). Symlinks and special files are **rejected** (§3), so a tool
  that depends on them won't round-trip.

---

## 2. THE HEADLINE WORKFLOW — going offline at a workshop

**Scenario.** You're taking a laptop to a workshop / makerspace / client site with **no
internet**. You need a specific set of files (the STEP files for the job, the slicer profiles,
the LightBurn cut files) to be **already downloaded** on the laptop so you can open and edit
them with no network. You'll make changes on the bench, and sync them back when you get home.

This section documents **exactly** how to achieve that with TODAY's capabilities, what works
offline, what fails, and the gaps that make it rough.

### 2.0 The honest headline

> **The bytes-on-disk machinery all exists and is tested. The *user-facing controls to target
> and verify it* do not.** A maker cannot, from the app, say "make this folder available offline"
> and see a "✓ 142/142 files downloaded" confirmation. The reliable path today is either (a) let
> the default-`Include` policy download the *whole* library while online (works, but not targeted),
> or (b) drive the engine's selective-sync + verification from Rust/an example binary. Closing
> this is a small, well-scoped wiring job on top of a complete engine.

### 2.1 Pre-downloading the files (three honest options)

**Option A — "download everything" (works today, no targeting).**
The selective-sync default policy is `Include`, meaning the running daemon's sync loop calls
`proactive_hydrate` every tick and **eagerly downloads every file** that has missing chunks
(`sync_tick_debounced` → `proactive_hydrate` → `proactive_hydration_targets`, in
`client/sync-engine/src/daemon.rs` / `lib.rs`). So: **start the daemon, leave it connected and
running until the loop has hydrated the whole library, then disconnect.** Everything is now local.
- *Pros:* requires zero new UI; it's the default behavior.
- *Cons:* downloads the **entire** library (no good for a 100 GB archive on a laptop SSD), and
  there's **no signal that it has finished** — you're guessing when "caught up" happened.

**Option B — targeted selective sync (engine-API only, not user-reachable).**
The correct, targeted mechanism: set the device default to `Exclude`, then `subscribe` exactly the
folder(s) you need. `SyncEngine::subscribe(provider, client, io, node_id)` records the include rule
**and immediately hydrates** that subtree; the running loop keeps it resident.
```text
provider.set_subscription_default(SubRule::Exclude);   // online-only by default
SyncEngine::subscribe(&provider, &client, &io, "<node_id of /Jobs/ClientX>");  // download just this
```
- *Pros:* downloads only what you asked for; survives renames (keyed by `node_id`); dedup-safe.
- *Cons (the gap):* **there is no app button, no `maker-syncd --include` flag, no CLI** that calls
  `subscribe`/`set_subscription_default`. As of `main`, this is reachable **only from Rust code**
  (a custom binary or an example). A user cannot do this from the shipped app today.

**Option C — Windows only: Explorer "Always keep on this device" (engine wired, OS-native UI).**
On the Windows CfAPI backend, the OS gives you the pin UI for free: right-click → *Always keep on
this device* maps to `CF_PIN_STATE_PINNED`, which the adapter turns into a force-hydrate
(`pin_hydration_action` → `Hydrate`, `client/fs-cfapi/src/lib.rs`); *Free up space* unpins →
dehydrate. This is a **real, user-facing pre-download control — but only on Windows**, and it's
per-file/folder via Explorer, not a managed "offline set."

### 2.2 Verifying files are actually local before you disconnect

This is the step most likely to bite you, because **there is no verification UI or command.**

- **What exists (engine primitives):** for any file you can list its chunk hashes
  (`provider.node_manifest_hashes(node_id)`) and check each is cached (`provider.has_chunk(hash)`).
  "Fully hydrated" = *all* hashes return `has_chunk == true`. This is exactly what the integration
  tests assert (`assert!(hashes.iter().all(|h| b.has_chunk(h)))` in `integration.rs`).
- **What does NOT exist:** any packaged `is_fully_hydrated(node_id)` helper, any "X of Y files
  available offline" indicator in the app, any `verify` CLI, and any **guard that warns you before
  you disconnect** that some needed files are still online-only. You assemble the check yourself
  from the two primitives, or you trust that the loop "looked done."
- **Practical check today (Linux/macOS):** after the loop has run, you can `find` your mount and
  `cat`/`sha256sum` the files you care about **while still online** — a successful read forces (and
  proves) hydration. If a read hangs or errors, that file wasn't local. This is a manual smoke test,
  not a feature.

### 2.3 What works offline (with no network)

Once the relevant files are hydrated and you pull the plug:

- **Full tree browse / stat / readdir** — every device holds the complete tree in local SQLite, so
  navigation is fully functional offline (§1.3). You see *all* your files listed, including the ones
  whose bytes aren't downloaded.
- **Reading hydrated files** — a hydrated file's chunks live in the local content-addressed cache,
  so reads serve entirely from disk with **zero network**. This is directly tested:
  `hydrated_file_stays_readable_offline` points the engine at a **dead server + an erroring chunk
  transport** and confirms a re-hydrate is a no-op (nothing missing) and the file still reads
  byte-for-byte (`integration.rs:392`).
- **Local edits** — creating, writing, renaming, deleting, `chmod`-ing files all work offline. Each
  change writes the local SQLite tree **and enqueues an outbox entry atomically**; the outbox simply
  accumulates while there's no network (`offline_writes_reconcile_with_remote_changes_on_reconnect`).
- **Local advisory locks** — POSIX `setlk`/`getlk` byte-range locks are local and work offline.

### 2.4 What FAILS offline

- **Opening an un-hydrated (online-only) file.** A `read` on a file whose chunks aren't cached
  triggers the hydrate hook, which needs presigned URLs from the server + bytes from object storage.
  With no network this **fails** (the read errors / the open can't complete). This is the whole point
  of §2.1–2.2: anything you didn't pre-download is unreadable at the workshop. There is **no offline
  pre-flight warning** that you're about to open something that isn't local.
- **Pushing your edits to the server** — the outbox can't drain; your work is safely queued locally
  but not yet anywhere else (no second copy until you reconnect).
- **Cross-device freshness** — you won't see edits made on your other machines, and they won't see
  yours, until reconnect (no nudge, no delta pull).
- **Open-for-write on a *partially* hydrated file** — write-open seeds its staging buffer from the
  committed content, so it calls the **whole-file** `hydrate` (a partial/range hydrate would leave
  un-fetched regions wrong). Offline, if that file wasn't fully resident, the write-open fails.

### 2.5 Reconnecting — how queued edits sync back

When the laptop is back online and the daemon is running:

1. **Push drains the outbox.** `push_outbox` walks the queued changes in **topological order**
   (parents before children — a real ordering bug the fault harness caught and fixed), commits each
   (upload missing chunks → finalize), and the server appends changelog entries + bumps `head_seq`.
2. **Pull applies what changed elsewhere.** The loop pulls the changelog delta since its cursor and
   applies it locally. If the device fell so far behind that the server **pruned** the changelog past
   its cursor, it detects the gap (`cursor < oldest_seq`) and does a **full snapshot resync** instead
   of silently missing entries.
3. **Conflicts surface, both sides kept.** If one of your offline edits has a stale `base_version_id`
   because another device touched the same file while you were away, the server records a **conflict**
   (both versions kept) rather than dropping either — and you resolve it in the app via keep/split
   (§1.7). Convergence (both devices end up with both sides' non-conflicting files) is tested.

### 2.6 The gaps that make the offline-workshop rough today, and what closes them

| Gap | Impact | What closes it |
|---|---|---|
| **No "make this folder available offline" in the app/CLI** | Targeted pre-download (Option B) is Rust-only; users fall back to "download everything" or Windows Explorer pin | Wire `SyncEngine::subscribe` / `set_subscription_default` to a Tauri command + a folder right-click, and a `maker-syncd --include <path>` flag |
| **No verification that files are local before disconnect** | You guess whether the loop finished; a missed file is silently unreadable at the workshop | A packaged `is_fully_hydrated(node_id)` + a per-folder "X/Y downloaded" indicator + a "ready for offline ✓" badge |
| **No progress UI for proactive hydration** | A big pre-download has no progress bar or completion signal | Emit hydration progress events from the loop to the app |
| **No offline pre-flight / "you're about to open an online-only file" guard** | A confusing hang/error when opening an un-hydrated file offline | A mount-level "online-only" attribute + a warning (CfAPI already shows placeholders natively; FUSE/WebDAV don't surface online-only state) |
| **Whole-file hydrate on FUSE/WebDAV read** | First open of a big file offline-prep downloads the whole file even if you only needed a slice | Wire read-intent range hydration on FUSE/WebDAV (already done on CfAPI) |
| **Bandwidth caps not user-settable** | A big pre-download saturates the shop's last good connection | Surface `DaemonConfig::with_bandwidth` in the app/CLI |

**Bottom line:** the offline-workshop scenario is **achievable today** (Option A everywhere; Option C
on Windows; Option B from Rust), and everything that *runs* offline — full browse, reading hydrated
files, queuing edits, reconnect-and-reconcile — is real and tested. What's missing is the **thin
user-facing control + verification layer** on top of a complete engine: a way to *target* the
pre-download and a way to *confirm* it before you walk out the door.

---

## 3. Limitations — an honest catalogue of what the FS can't do

These are **as of `main` today (2026-06-16)**. Two sibling efforts are separately probing
**git-on-mount** and **POSIX conformance**; where those touch the items below, the specifics may be
improving — treat the POSIX/symlink/git notes as a snapshot, not a verdict.

### POSIX / filesystem-semantics non-goals (deliberate)

- **No uid/gid ownership, no full permission bits, no ACLs/xattrs.** Only the file **mode**'s
  executable bit (0644/0755) is synced. Ownership and the broader permission model are meaningless
  for a single-user personal drive and are not modeled.
- **No ctime/atime sync.** Real **mtime** is preserved verbatim (nanoseconds, end-to-end); ctime and
  atime are not synced.
- **No symlinks.** `symlink()` is rejected with **EPERM** (a deliberate guardrail in
  `client/fs-fuse/src/lib.rs`) — the tree models only `File` and `Dir`. `ln -s`, `cp -a` of a
  symlink, etc. fail cleanly rather than corrupting.
- **No hardlinks.** Not modeled; each node is a single tree entry.
- **No special files** — FIFOs, sockets, block/char device nodes via `mknod` are rejected with
  **EPERM** (G8 guardrail), rather than the default `ENOSYS` that confuses `cp -a`/`tar`.
- **Implication for git-on-mount:** git checkouts that materialize symlinks (and some hooks/index
  edge cases) will hit the EPERM guardrails; a plain text repo without symlinks fares better, but
  **git-on-mount is not a supported/tested workflow as of `main`** (a sibling agent is probing the
  specifics — this may be refined).

### Sync / hydration limitations

- **Offline editing of an un-hydrated file is not possible.** Reading or write-opening a file whose
  chunks aren't cached needs the network (§2.4). There is no "download-on-demand while offline" — by
  definition.
- **No automatic targeting of what to keep offline from the app.** Selective sync and bandwidth caps
  exist in the engine but have **no UI/CLI surface** (§1.4, §1.6) — the central limitation behind the
  offline-workshop friction.
- **Whole-file hydrate on FUSE/WebDAV reads.** Range/progressive hydration is wired only on CfAPI
  (§1.5); on the other two backends a read of any byte hydrates the entire file.
- **Conflict resolution is manual.** No auto-merge (correct for binary CAD) — you must pick keep or
  split. The cross-device edit lock is best-effort and never blocks.

### Tenancy / sharing limitations

- **Tenant = user. No sharing with other users.** A library is *your* devices only; there is no way
  to share a folder with a collaborator/fabricator (no cross-user authz, no changelog scoping). This
  is a deliberate v1 scope decision, not a bug.
- **No at-rest / end-to-end chunk encryption (yet).** On the managed service, chunks are stored
  un-encrypted-by-us; per-user AEAD over content-addressed ciphertext is the explicitly-last roadmap
  item (`docs/parity-roadmap.md`). For IP-sensitive CAD on a hosted box, that gap matters — self-host
  sidesteps it.

### Platform limitations

- **macOS uses WebDAV, not a native Finder-integrated sync root.** It works (verified live, rclone
  conformance clean) but it's a WebDAV mount, not the OneDrive-class placeholder experience. A native
  **FSKit** backend is a **design sketch only** (no `client/fs-fskit` crate on `main`) and is
  additionally blocked on a paid Apple Developer membership.
- **macOS / FUSE-T mounts need an interactive session** — they won't hold a mount from a fully
  detached/headless process.
- **Windows CfAPI is the default; WinFsp is behind a cargo feature** for one release. The live CfAPI
  write-path conformance is an on-demand CI job, not a per-PR gate.

### Product-layer (NOT file-system) limitations

For completeness — these are **not** file-system limits; the sync engine references files by stable
`node_id` and is ready for them, but the product surface in `CLAUDE.md` §12 step 9 simply isn't built:
in-browser STL/3MF/CAD **preview**, **inventory**, and **projects/tasks/build-log/BOM**.

---

## Appendix — capability state at a glance

| Capability | State | Where |
|---|---|---|
| Cross-device sync (push/nudge/pull) | **Works today** (verified live, all 3 OSes) | `sync-engine` `push_outbox`/`pull_changes`; ActionCable |
| On-demand hydration of placeholders | **Works today** (verified live) | `SyncEngine::hydrate`; FUSE/CfAPI/WebDAV hooks |
| Offline read of hydrated files | **Works today** (tested) | `hydrated_file_stays_readable_offline` |
| Offline edits queued + reconciled | **Works today** (tested) | `offline_writes_reconcile_…`; topological `push_outbox` |
| Native versioning + restore | **Works today** (restore tested; app cmds built) | `file_versions`/`restore_version` |
| Conflict detect + keep/split | **Works today** (tested; lock verified live) | `conflicts`/`resolve_conflict_*` |
| Block-delta dedup uploads | **Works today** (tested) | FastCDC chunking + dedup |
| Exec-bit + real-mtime preservation | **Works today** (tested) | `executable_bit_…`, `real_mtime_…` |
| Selective sync (subtree subscriptions) | **Engine-API exists, no UI** | `fs-provider/src/subscriptions.rs`; `SyncEngine::subscribe` |
| Range / progressive hydration | **Engine-API exists; wired only on CfAPI** | `SyncEngine::hydrate_range_concurrent` |
| Client bandwidth caps | **Engine-API exists, no UI** | `DaemonConfig::with_bandwidth` |
| Windows "Always keep on device" pin | **Works today (Windows, OS-native UI)** | `fs-cfapi` `pin_hydration_action` |
| "Make folder available offline" (cross-platform UI) | **Not built** | — (wire `subscribe` to app/CLI) |
| Verify files are local before disconnect | **Not built** (primitives exist) | `node_manifest_hashes` + `has_chunk` |
| Symlinks / hardlinks / special files | **Not supported (EPERM guardrail)** | `fs-fuse` `symlink`/`mknod` |
| uid/gid / full perms / ACLs / xattrs | **Not supported (non-goal)** | — |
| Cross-user sharing | **Not built (tenant = user)** | — |
| At-rest / E2E encryption | **Not built (roadmap, last)** | — |
| Native macOS FSKit mount | **Design sketch only** | `docs/plan-macos-fskit-migration.md` |
