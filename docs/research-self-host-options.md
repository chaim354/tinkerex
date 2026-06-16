# Research — self-hosted server options + bring-your-own-storage

**Status:** research / recommendation (docs only — no code changes).
**Date:** 2026-06-16.
**Audience:** founder + the coding agent. Answers three open self-host questions and
gives a phased recommendation.

> TL;DR — **Don't drop the sync engine for a network share.** The share idea either
> regresses to the abandoned WAN-mount problem (remote share) or only solves the
> single-LAN case (local share) while losing offline, dedup, per-device hydration,
> cross-device convergence, and conflict detection. **Bring-your-own-S3 already works
> today** — the only gap is packaging/validation (a setup wizard + B2/Wasabi/Storj
> smoke tests). **Bring-your-own-ANY-cloud** (Dropbox/Drive/OneDrive/SFTP/…) is a real,
> bounded feature: add an **rclone-backed `ChunkStore`** behind the existing
> `Storage::ChunkStore` seam, accepting that non-S3 backends route bytes through the
> server (a deliberate, documented exception to "keep bytes out of Rails", scoped to
> self-host). Recommendation: **A (no) · B (ship the polish) · C (build it, phase 2).**

---

## 0. The three questions + the current state

The founder asked:

1. For self-hosters, should files just be a **network drive share (SMB/NFS)** with a
   **separate background process that chunks them** for versioning + backup? (i.e. drop
   the local-first sync engine for self-host and lean on a plain share + a sidecar
   versioner.)
2. OR can we **integrate with other clouds** so people who don't want our managed hosting
   point it at **their own cloud** (S3/B2/R2/Wasabi, or even Dropbox/Drive/OneDrive)?
3. What's the **right architecture** — weigh simplicity vs the local-first sync engine
   already built.

### What already exists (ground truth before we design anything)

**Self-host already works.** Per `docs/DEPLOY.md` and `docs/SYNC_SERVER.md`, a self-hoster
runs our Rails 8 server on their own box (Kamal on an Unraid VM is the worked example) on
**SQLite**, and points chunk storage at **any S3-compatible endpoint** via env:

```
STORAGE_BACKEND=s3
CHUNK_BUCKET=…  CHUNK_ENDPOINT=https://…  CHUNK_REGION=…
CHUNK_ACCESS_KEY_ID=…  CHUNK_SECRET_ACCESS_KEY=…
```

There is already a clean storage seam — `Storage::ChunkStore` (`app/services/storage/`)
with three concrete backends:

| Backend | `STORAGE_BACKEND` | Role |
|---|---|---|
| `S3ChunkStore` | `s3` | R2 / SeaweedFS / MinIO / **any S3-compatible** — the real data plane. Presigns PUT/GET; bytes go client⇄storage direct. |
| `LocalChunkStore` | `local` | Real filesystem data plane, **no external object store** — HMAC-signed `…/v1/chunks/blob/<user>/<hash>` URLs the client PUT/GETs. The **single-box self-host** option (no SeaweedFS/MinIO to run). |
| `MemoryChunkStore` | `memory` | Control-plane-only (mints fake URLs, stores nothing) — for HTTP-contract tests. |

The interface every backend implements is small and is exactly the seam any new option
plugs into:

```ruby
presign_put(user_id, hash, expires_in:)   # upload a missing chunk
presign_get(user_id, hash, expires_in:)   # hydrate a chunk
exists?(user_id, hash)
list(user_id)                             # storage-orphan reaper
delete(user_id, hash)                     # GC sweep
```

So the question is **not** "can self-hosters use their own storage" — they can, today, for
any S3-compatible store and even for plain local disk. The real questions are:
**(B)** how do we make BYO-S3 *easy and validated*, and **(C)** how do we reach the
*non*-S3 clouds (Dropbox/Drive/OneDrive/SFTP) that don't speak S3 or presigned URLs.

### The hard constraints this report honors (don't relitigate — `CLAUDE.md` §14, `docs/roads-not-taken.md`)

- **A remote-mounted filesystem does NOT work over the WAN.** Synchronous metadata
  round-trips are ~150 ms–1 s/file (Phase 0, measured). This is *the* reason the
  local-first sync engine exists. No recommendation here revives a WAN mount.
- **Local-first stays.** Metadata reads hit local SQLite, never the WAN.
- **Permissive licensing only** (MIT/Apache/BSD; avoid GPL/AGPL in deps/artifacts).
- **Tenant = user**; self-host is single-user.

---

## Option A — Network share (SMB/NFS) + a sidecar chunker

**The idea:** for self-host, skip the sync engine. Expose files as a plain SMB/NFS share
the OS mounts as a network drive. Run a background watcher (inotify/FSEvents/
ReadDirectoryChangesW) that FastCDC-chunks changed files into a content-addressed store
for versioning + backup. Simpler: no client daemon, no placeholders, no per-OS mount
adapters.

### How it would actually work

```
  ┌── User's box ───────────────────────────────────────────────┐
  │  Samba / nfsd  ──serves──►  /srv/maker/library  (real files) │
  │        ▲                          │                          │
  │        │ SMB/NFS                  │ inotify/FSEvents watch    │
  │  client OS mounts a              ▼                            │
  │  network drive            sidecar versioner                  │
  │                           (FastCDC → content-addressed       │
  │                            chunk store + version manifests)  │
  └──────────────────────────────────────────────────────────────┘
```

The sidecar is essentially **restic/Kopia/Borg pointed at the share** — exactly what those
tools do. They use content-defined chunking + dedup over arbitrary backends
([restic uses Rabin-fingerprint CDC ~512 KB–8 MB][restic-cdc];
[Kopia is content-addressable with variable-length chunking + client-side encryption][kopia-feat];
Borg uses Buzhash CDC). [Seafile][seafile] is the closest production precedent for *our*
model — files split into deduplicated, content-addressed blocks (a Git-like data model) —
and it is the *performance winner* among self-host suites precisely because of block-level
dedup. [Syncthing's versioning][syncthing-ver] (simple / staggered / external) and
ZFS/btrfs snapshots are simpler version-retention precedents. Nextcloud "external storage"
mounts SMB/Dropbox/Drive/S3 as folders and layers its own versioning/activity log on top
([Nextcloud external storage][nc-ext]).

### Pros

- **Conceptually simple to explain** ("it's a network drive + automatic backups").
- **No client install for the file surface** — any OS mounts SMB/NFS natively.
- **The versioner is mostly off-the-shelf** — restic/Kopia/Borg already do CDC + dedup +
  any-backend, permissively licensed (restic BSD-2, Kopia Apache-2.0, Borg BSD).

### Cons — and why this **regresses the guarantees the project deliberately chose**

This is the crux. A network share trades away most of what the sync engine was *built* to
provide:

1. **Remote share = the abandoned WAN-mount problem, verbatim.** SMB and NFS are *LAN*
   protocols: distributed-RPC, many round-trips per operation. Over ~70–120 ms WAN latency
   they "destroy performance" — every `stat`/`open`/`readdir` pays the round-trip
   ([Microsoft on SMB/CIFS over WAN][ms-smb]; [EE Times: file sharing on the WAN is a matter
   of latency][eetimes]). This is *the same finding* as Phase 0 (`docs/roads-not-taken.md`
   #1) — a remote filesystem is structurally too slow. **A remote SMB/NFS share is a WAN
   mount with a different acronym.** §14 forbids exactly this.

   → So the share only works **on the LAN**. The moment a maker wants their files from a
   laptop at a makerspace, a second location, or on the road, the share model has no answer
   — and "access my library from anywhere" is the whole point of a sync product.

2. **No offline.** A share is online-or-nothing. The sync engine is local-first: every
   `stat`/`open` is instant against local SQLite and edits queue in an outbox while
   offline. A share has neither.

3. **No per-device on-demand hydration / selective sync.** The OneDrive/Dropbox model
   (placeholders, hydrate-on-open, "free up space", pin/unpin) — already built here across
   FUSE/CfAPI/WebDAV — is impossible over a dumb share. Either you mount the whole share
   (and stream every byte over the network on every open) or you copy it all down (and lose
   the share).

4. **Dedup is downgraded from native to after-the-fact.** In the sync engine a version
   *is* a content-addressed manifest sharing chunks — dedup is intrinsic and an edit only
   uploads new chunk hashes. A sidecar re-chunking files on the share is a *second*,
   parallel copy of the data (the share has the live bytes; the chunk store has another
   full copy) and the chunking races the writer (chunk-mid-write → torn snapshots; the
   project already proved finalize must be atomic — `docs/torn-writes-and-batching.md`).

5. **No cross-device convergence or conflict detection.** The changelog + `base_version_id`
   conflict model (keep-both, never silently drop a maker's edit — `docs/roads-not-taken.md`
   #5) lives in the sync protocol. A share has no notion of *which device* changed *which
   version from which base*; concurrent edits over SMB are last-writer-wins at the OS level
   — the exact behavior the project replaced.

6. **Two divergent codebases.** Self-host on a share + managed on the sync engine means two
   products, two backup stories, two support surfaces. The current win is **one protocol,
   two hosts** (`CLAUDE.md` §7) — identical models/API/client, only creds differ.

**Verdict on A: no.** Keep the share *idea* only as an optional **ingest convenience on the
server box** (a watched "dropbox" folder that feeds the existing commit path), never as the
primary file surface. The sidecar-versioner instinct is *already satisfied* by the engine —
FastCDC + immutable versions + refcounted chunks + retention/GC are built and tested. Adding
restic/Kopia *on top* would duplicate, not simplify. The one legitimately simpler piece —
"I don't want to run MinIO" — is **already solved** by `STORAGE_BACKEND=local` (real data
plane on plain disk, no object store).

---

## Option B — Bring-your-own-S3 (mostly already supported)

**The idea:** let self-hosters point the chunk store at *their* S3-compatible cloud —
Backblaze B2, Wasabi, Storj, Cloudflare R2, Scaleway, IDrive e2, MinIO, Ceph RGW, etc.

### Status: this already works. The gap is packaging + validation, not capability.

`S3ChunkStore.from_env` takes `CHUNK_ENDPOINT` + creds and uses `aws-sdk-s3` with
`force_path_style: true` — the standard recipe for S3-compatible providers. The data plane
is presigned PUT/GET, **SigV4**, per-user key `chunks/<user>/<hash>`. The relevant providers
all speak this:

- **Backblaze B2** — its S3-compatible API **supports presigned URLs and only SigV4**
  (v2 unsupported) ([Backblaze: does B2 support presigned URLs][b2-presign]). ✅
- **Wasabi, Storj, Scaleway, IDrive e2, MinIO, Ceph** — all advertise S3-compatible APIs
  with SigV4; the AWS SDK works by overriding the endpoint ([rclone's S3 backend lists
  40+ S3-compatible providers][rclone-s3]). ✅ (Storj has an S3-compatible gateway;
  path-style + SigV4 apply.)
- **Cloudflare R2** — already the managed target (`CHUNK_REGION=auto`). ✅

So **BYO-S3 is a config exercise the architecture already supports**. What's missing is the
last mile that turns "possible" into "a self-hoster can actually do it":

1. **A setup wizard / guided config.** Today it's hand-set env vars + a Kamal deploy. A
   first-run web flow ("pick your storage: local disk · S3 · B2 · Wasabi · R2 · other
   S3-compatible → enter endpoint/keys → **test connection**") removes the single biggest
   self-host friction. The "test connection" step = `presign_put` a throwaway key, PUT a
   few bytes, GET them back, `delete` — proves creds + path-style + CORS before the user
   trusts it.

2. **Per-provider validation + a compatibility matrix.** Run the existing presigned
   round-trip smoke (`examples/presigned_roundtrip.rs`) against B2 / Wasabi / Storj /
   Scaleway and record gotchas (path-style vs virtual-host, region quirks, multipart
   thresholds, `list_objects_v2` pagination for the orphan reaper, delete semantics).
   R2 was already validated live (`docs/r2-migration.md`); extend that doc into a
   **"verified S3 providers" table**.

3. **CORS guidance.** Presigned URLs are hit directly by the client; some providers need a
   bucket CORS policy for the PUT/GET to succeed from a non-browser client this is usually
   moot, but the web-UI upload path (bytes off Rails) does need it. Document the policy
   per provider.

4. **Lifecycle/cost notes.** Document that the **storage-orphan chunk reaper** (`Sync::
   ChunkReaper`, weekly) relies on `list(user_id)` — billed per-request on S3 — and that
   retention is `keep_all` by default on self-host (the user's disk, the user's call).

### Effort: small. Mostly a wizard + a validation pass + docs. No new architecture.

This is the **highest-leverage, lowest-risk** work in this report: it makes a capability the
codebase *already has* actually reachable by a non-expert self-hoster, and it honors every
constraint (bytes stay off Rails via presigned URLs; local-first untouched).

---

## Option C — Bring-your-own-ANY-cloud via an rclone-backed chunk store

**The idea:** reach the clouds that **don't** speak S3 — Dropbox, Google Drive, OneDrive,
SFTP/FTP, pCloud, Mega, Azure Blob, Backblaze B2 *native*, and ~70 more — so a self-hoster
can point the chunk store at storage they already pay for.

### Feasibility: yes, via the existing `ChunkStore` seam + rclone.

[rclone][rclone-gh] is "rsync for cloud storage" — one consistent interface over **70+
backends** (S3, Drive, OneDrive, Dropbox, B2, SFTP, Swift, Azure, pCloud, Mega, …)
([rclone overview][rclone-overview]). It is permissively licensed (**MIT**), so it's clean
under §9. The precedent is **Kopia**, which does exactly this: it backs onto S3/B2/GCS/Azure
natively, and for everything else it **manages an rclone subprocess** — "Kopia requires you
to download rclone… after that Kopia manages/runs rclone for you" ([Kopia features][kopia-feat]).
Borg takes the same route (S3/B2 only via rclone mount) ([restic/kopia/borg comparison][rbk]).

We'd add a fourth `ChunkStore`:

```
STORAGE_BACKEND=rclone
CHUNK_RCLONE_REMOTE=mydrive:maker-chunks      # any configured rclone remote
```

Two implementation shapes, both behind the same `presign_*`/`exists?`/`list`/`delete`
interface:

- **C1 — rclone `rcd` (recommended).** Run `rclone rcd` (its HTTP control daemon) as a
  sidecar; the `RcloneChunkStore` talks to it over localhost. Chunk PUT/GET = rclone
  `operations/uploadfile` / a streamed download. `list`/`delete` map to rclone's
  `operations/list` / `deletefile`. Object key stays `chunks/<user>/<hash>`.
- **C2 — rclone `serve s3`.** rclone can *present an S3 API* over any backend
  ([`rclone serve s3`][rclone-serve-s3]). Point the **existing** `S3ChunkStore` at
  `http://localhost:<port>` and get presigned-style URLs against a Drive/Dropbox backend
  with **zero new Ruby**. Cleanest reuse; the catch is rclone's S3 server has its own auth
  model and the "presigned" URL is then local-only (still fine — see the trade-off below).

### The unavoidable trade-off: bytes through the server (a scoped exception to §15)

The managed architecture's crown jewel is **bytes never flow through Rails** — the client
gets a presigned URL and talks to object storage *directly*. That property is **S3-shaped**:
it requires the storage to mint a time-limited, capability-scoped URL the client can hit.

- **True S3 providers** (Option B) keep this property intact. ✅
- **Some non-S3 clouds actually do support direct client upload/download too** — worth
  noting so we don't overstate the trade-off: **Dropbox** has `/get_temporary_upload_link`
  (a one-time presigned upload URL — "saves your server the network traffic of forwarding
  content") ([Dropbox temporary upload link][dropbox-tul]); **OneDrive/Azure** use SAS
  upload sessions; **Google Drive** uses resumable upload sessions + signed URLs. A future,
  per-provider direct-upload adapter *could* preserve bytes-off-server for these three.
- **The general rclone path, however, routes chunk bytes through the self-hoster's own
  server** (client → Rails/rclone-sidecar → Dropbox/Drive/SFTP). rclone has no universal
  presigned-URL concept; the bytes transit the box running rclone.

**Is that acceptable?** For **self-host: yes, deliberately.** "Keep bytes out of Rails" is a
**scaling/cost/security guarantee for the *managed multi-tenant* plane** — it keeps our
hosted Rails cheap and stops it being a bandwidth bottleneck or a cross-tenant byte path. On
a **single-user self-hosted box**, the server, the rclone sidecar, and often the client are
the same machine or the same LAN; routing your *own* bytes through your *own* server to your
*own* Dropbox is not a tenancy or cost violation — it's just a proxy hop you chose. The rule
should be restated as: **"bytes never flow through *our managed* Rails; on self-host with a
non-S3 backend, bytes may proxy through *your own* server as the price of using a non-S3
cloud."** Document it loudly; gate it to `STORAGE_BACKEND=rclone`; keep S3/local as the
recommended (direct-byte) defaults.

### Effort: medium, and cleanly bounded.

- New `RcloneChunkStore` (C1) **or** a documented `serve s3` recipe (C2 — near-zero code).
- A server-side **byte-proxy endpoint** for the non-presignable case (the one place bytes
  touch Rails — explicitly self-host-only, behind the rclone backend).
- The `list`/`delete` mappings for the orphan reaper + GC sweep (rclone supports both).
- Packaging rclone alongside the server image (it's a single Go binary; Kamal-friendly).
- Per-backend caveats: Dropbox/Drive **rate-limit** and dislike many tiny objects, so the
  content-addressed `chunks/<user>/<hash>` keyspace (potentially millions of ~1–4 MB blobs)
  should use a **sharded prefix** (`chunks/<user>/<hh>/<hash>`) to avoid giant directories;
  document chunk-size tuning for these backends.

**Recommendation on C: build it, but in phase 2**, starting with the `serve s3` recipe (C2)
to ship "point it at Dropbox/Drive" with minimal code, then graduate to a first-class
`RcloneChunkStore` (C1) if demand warrants. Lead with the honest framing that non-S3 = bytes
proxy through your own box.

---

## Recommendation + phased plan

**Architecture verdict (Q3): keep the local-first sync engine. It is the asset, not the
liability.** It already gives self-hosters everything the share model can't (offline,
instant local ops, on-demand hydration, native dedup, versioning, cross-device convergence,
conflict detection) over **one protocol on two hosts**. The share model is simpler only in a
way that throws those away and re-opens the WAN-latency wound the whole project exists to
avoid. The genuine self-host simplifications people actually want — "don't make me run
MinIO" and "let me use storage I already pay for" — are **storage-backend** questions, and
the `ChunkStore` seam already answers the first (`local`) and is the right place to answer
the rest.

| Q | Answer | Confidence |
|---|---|---|
| **A. Network share + sidecar chunker?** | **No.** Remote share = the abandoned WAN mount; local share loses offline/hydration/convergence/conflicts; the sidecar duplicates the engine's native dedup/versioning. Keep only as an optional server-side ingest folder. | High |
| **B. BYO-S3 (R2/B2/Wasabi/Storj/MinIO)?** | **Already works** via `STORAGE_BACKEND=s3` + `CHUNK_*`. Ship a **setup wizard + a validated-provider matrix**. | High |
| **C. BYO-any-cloud (Dropbox/Drive/OneDrive/SFTP)?** | **Yes, feasible** via an **rclone-backed `ChunkStore`** (the Kopia model). Accept (and document) that non-S3 = **bytes proxy through your own server** — a scoped, self-host-only exception, not a managed one. | Medium-High |

### Phased plan

**Phase 0 — Frame it (docs only; this report).**
State publicly: *self-host = our Rails + SQLite + storage of your choice; the file surface
is always the local-first sync engine, never a remote share.* Restate the bytes rule as
"never through *our managed* Rails."

**Phase 1 — Make BYO-S3 effortless (Option B). High leverage, low risk.**
1. First-run **storage setup wizard** (local disk · S3 · R2 · B2 · Wasabi · other) with a
   **live test-connection** (presign → PUT → GET → delete a probe key).
2. **Validate B2 / Wasabi / Storj / Scaleway** with the existing presigned round-trip
   smoke; publish a **compatibility matrix** + CORS/path-style/region notes (extend
   `docs/r2-migration.md`).
3. Surface `STORAGE_BACKEND=local` as the **"no object store needed"** default in the
   wizard for one-box self-hosters.

**Phase 2 — BYO-any-cloud via rclone (Option C). Bounded, opt-in.**
1. Ship the **`rclone serve s3` recipe** first (C2 — point `S3ChunkStore` at a local rclone
   S3 endpoint; near-zero new code) to claim "works with Dropbox/Drive/OneDrive/SFTP."
2. Then a first-class **`RcloneChunkStore`** (C1, `rclone rcd`) + a self-host-only **byte
   proxy** endpoint, sharded chunk prefixes, and per-backend rate-limit/chunk-size docs.
3. Loudly document the **bytes-proxy-through-your-own-box** trade-off and keep S3/local as
   the recommended direct-byte defaults.

**Phase 3 — (optional, later) Per-provider direct-upload adapters.**
For Dropbox / OneDrive / Google Drive specifically, use their native presigned-style upload
sessions (`/get_temporary_upload_link`, SAS, resumable) to *restore* bytes-off-server even
on non-S3 clouds. Only if demand justifies the per-provider maintenance.

**Explicitly NOT doing:** reviving a remote-mounted filesystem in any form (WAN SMB/NFS, or
an rclone *mount*). The sync engine stays the file surface on every host. (`CLAUDE.md` §14,
`docs/roads-not-taken.md` #1.)

---

## Sources

- Rclone — [GitHub repo (rsync for cloud storage)][rclone-gh] · [overview of cloud storage
  systems][rclone-overview] · [S3-compatible backend & provider list][rclone-s3] ·
  [`rclone serve s3`][rclone-serve-s3]
- Kopia — [features (content-addressable chunking, dedup, rclone-managed backends)][kopia-feat]
- restic / Kopia / Borg — [comparison: CDC algorithms, dedup, backend/rclone support][rbk] ·
  [restic content-defined chunking][restic-cdc]
- Seafile — [block-based content-addressed dedup vs Nextcloud][seafile]
- Syncthing — [file versioning (simple/staggered/external)][syncthing-ver]
- Nextcloud — [external storage (SMB/Dropbox/Drive/S3) + versioning][nc-ext]
- SMB/NFS over WAN latency — [Microsoft: SMB/CIFS performance over WAN][ms-smb] ·
  [EE Times: file sharing on the WAN is a matter of latency][eetimes]
- S3-compatible presigned URLs — [Backblaze B2: presigned URLs, SigV4-only][b2-presign]
- Non-S3 direct upload — [Dropbox `/get_temporary_upload_link`][dropbox-tul]

[rclone-gh]: https://github.com/rclone/rclone
[rclone-overview]: https://rclone.org/overview/
[rclone-s3]: https://rclone.org/s3/
[rclone-serve-s3]: https://rclone.org/commands/rclone_serve_s3/
[kopia-feat]: https://kopia.io/docs/features/
[rbk]: https://dev.to/selfhostingsh/restic-vs-kopia-vs-borgbackup-2lmn
[restic-cdc]: https://restic.readthedocs.io/en/stable/100_references.html
[seafile]: https://dev.to/selfhostingsh/owncloud-vs-seafile-which-file-server-to-use-1nho
[syncthing-ver]: https://docs.syncthing.net/users/versioning.html
[nc-ext]: https://docs.nextcloud.com/server/latest/admin_manual/configuration_files/external_storage_configuration_gui.html
[ms-smb]: https://learn.microsoft.com/en-us/archive/blogs/neilcar/smbcifs-performance-over-wan-links
[eetimes]: https://www.eetimes.com/file-sharing-on-the-wan-a-matter-of-latency/
[b2-presign]: https://help.backblaze.com/hc/en-us/articles/360047815993-Does-the-B2-S3-Compatible-API-support-Pre-Signed-URLs
[dropbox-tul]: https://dropbox.tech/developers/new-file-upload-link-api
