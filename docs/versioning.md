# File versioning & restore — design sketch

How we keep full version history while storing **close to only the delta** per version,
and restore any version cheaply. Most of this is already built; this doc names the pieces,
explains *why* it's storage-efficient, and sketches the retention/GC policy that bounds
growth. (See also `architecture-sync-engine.md`, `sync-protocol.md`.)

## TL;DR

A version is an **immutable manifest** — an ordered list of **content-addressed chunks**.
Chunks are shared across versions and files and **refcounted**. Because chunking is
**content-defined** (FastCDC), editing a file re-chunks only *around the edit*, so a new
version's manifest reuses almost all of the previous version's chunks and only a few new
blocks are stored. **Restore** points a file at an older manifest — reusing its chunks,
storing **zero** new blocks. Growth is bounded later by a **retention policy** that prunes
old versions and GCs chunks whose refcount hits 0.

## What a version is (already built)

```
node (file)            versions (immutable, parent-linked)        chunks (content-addressed, refcounted)
┌──────────────┐       ┌───────────────────────────────┐         ┌───────────────────────────┐
│ node_id      │──┬───▶│ v1: manifest_id = M1          │         │ hash → bytes (in R2/S3 at │
│ current_ver  │  │    │ v2: manifest_id = M2, parent v1│         │ chunks/<user>/<hash>)     │
└──────────────┘  │    │ v3: manifest_id = M1, parent v2│ (restore)│ refcount: # live manifests│
                  │    └───────────────────────────────┘         │ that reference it         │
   manifest_chunks (ordered: manifest_id → [ (seq, chunk_hash, offset, length) ] )
```

Tables: `versions(version_id, node_id, manifest_id, size, parent_version_id)`,
`manifest_chunks(manifest_id, seq, chunk_hash, offset, length)`,
`chunks(chunk_hash, refcount, size)`. A `manifest_id` is the hash of its ordered
chunk-hash list, so **identical content dedupes to one manifest** (proven in
`commit_test.rb` / `fs-provider` chunking tests).

## Why each new version is ~delta-sized, not a full copy

The block-delta property is the whole reason this is cheap, and it's content-defined
chunking that delivers it:

- **A small edit re-chunks only locally.** FastCDC's cut points are determined by a
  rolling hash over the *content*, not by fixed offsets. Insert/modify a few bytes and the
  boundaries **resynchronize** within a chunk or two — every chunk before and after the
  edit is byte-identical, so its hash is unchanged and it is **already stored**. We verify
  this directly: `fs-provider/tests/chunking.rs` asserts a front-insert keeps ≥half the
  chunks, an append keeps all-but-the-last, and a 1-byte edit perturbs only a handful.
- **So committing version N+1 uploads only the chunks whose content changed.** The commit
  protocol already does this: `Sync::Commit.begin` returns `missing` = the manifest's
  hashes the user doesn't already have; the client uploads **only those** (presigned PUT).
  Unchanged chunks are reused by hash.

**Worked example.** A 100 MB CAD file, avg 1 MB chunks → ~100 chunks. Tweak one feature
(a few KB in the middle): FastCDC re-cuts ~1–2 chunks around the change. Version 2 stores
**~1–2 MB** of new blocks and shares the other ~98 — not another 100 MB. Append-heavy logs
are even cheaper (only the tail chunk changes).

## Restore stores zero new blocks (already built — `Sync::Restore`)

Restore is *not* a re-upload. It creates a **new version that reuses an old version's
`manifest_id`**, bumps that manifest's chunks' refcounts (+1), re-points the node, and
appends a `put` to the changelog so it propagates like any edit:

```
v3 = create_version(node, manifest_id: v1.manifest_id, parent: current)   # reuse M1
chunks(M1.hashes).refcount += 1                                            # keep bytes alive
node.current_version = v3
```

The bytes for `M1` already exist (they were never deleted — we keep versions), so restore
moves **0 blocks**. It's lossless and O(manifest size) in metadata. (See `restore_test.rb`.)

## Bounding growth: retention + GC (WIRED — 2026-06-14)

"Keep every version forever" grows without bound, so a **retention policy** decides which
versions to drop; dropping a version decrements its chunks' refcounts, and chunks at
refcount 0 are swept (DB row **and** the object-storage bytes). Both the mechanism and the
scheduled policy job are now wired.

- **`Sync::Gc.prune_version!(user, version)`** — decrement refcounts for the version's
  chunks and delete the version row. Tree + current version untouched. (tested)
- **`Sync::Gc.sweep_orphans!(user, grace:)`** — delete chunk metadata + storage objects at
  refcount 0 past a grace window. Never frees a still-referenced or freshly-zeroed chunk.
  **Wired to the storage delete** (`ChunkStore#delete(user_id, hash)` → S3/R2 `delete_object`;
  no-op on the memory backend): destroys the DB row **first**, then a best-effort storage
  delete (rescued + logged), so a storage outage can never corrupt refcount state — orphaned
  bytes are reclaimed on a later sweep (delete is idempotent, tolerates already-gone). (tested)
- **`Sync::RetentionPolicy`** — computes the per-node **keep-set**. `keep_all` (self-host
  default — never prunes) and `tiered` (managed: the table below). Both modes ALWAYS keep the
  node's `current_version` and any **pinned** version (the `versions.pinned` column, default
  false). Config via `RETENTION_POLICY` env. (tested)
- **`Sync::Gc.apply_retention!(user, policy:, grace:)`** — orchestrator: per node, keep-set →
  `prune_version!` the rest → `sweep_orphans!`. Calls the mechanism, never reimplements it. (tested)
- **`RetentionJob`** — Solid Queue recurring task (nightly 4am, queue `background`,
  `config/recurring.yml`): applies `RetentionPolicy.default` across every user. (tested)
- **Keep-newest invariant:** a node's `current_version` is never pruned, so restore-to-now
  always works and the live tree never loses bytes.

**Tiered policy** (the managed mode — Time Machine / Dropbox 30-day; keep the newest in each bucket):

| Age of version        | Keep                         |
|-----------------------|------------------------------|
| < 24 h                | every version                |
| 1–30 days             | one per day                  |
| 30 days – 1 year      | one per week (ISO year-week) |
| > 1 year              | one per month                |
| always                | current version + any pinned |

Because chunks are shared, pruning a version frees **only** the blocks no surviving version
references — typically just that version's unique delta.

### Configuring managed vs. self-host

- **Self-host:** leave `RETENTION_POLICY` unset (defaults to `keep_all`) — `apply_retention!`
  prunes nothing; storage is the user's own box. (The job still runs but is a no-op.)
- **Managed:** set `RETENTION_POLICY=tiered`. Optionally surface "extended history" by pinning
  versions (`versions.pinned = true`, exempt from pruning) for a paid tier.

## What's built vs. to-build

- ✅ Content-addressed, refcounted, deduped chunks; immutable parent-linked versions;
  commit uploads only `missing`; `Sync::Restore` (reuse manifest, zero new blocks);
  `prune_version!` + `sweep_orphans!` (storage delete wired); **`RetentionPolicy`
  (keep_all/tiered) + `apply_retention!` + the `RetentionJob` recurring schedule**;
  **`pinned` flag** exempt from pruning; version-history + restore API + app UI.
- ⏳ Optional polish: a **pin/unpin API + UI control**, and a per-version size attribution
  ("this version added N MB") for a storage breakdown in the UI.
