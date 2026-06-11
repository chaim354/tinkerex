# Architecture — Local-First Sync Engine (v1)

**Status:** active — supersedes the direct-mount / direct-client plans.
**Last updated:** 2026-06-10

## Why this exists

Phase 0 proved a remote-mounted filesystem (JuiceFS/WebDAV over the WAN) is too
slow: synchronous metadata round-trips at ~150 ms → ~1 s per file. **No
production system (Dropbox, Google Drive, OneDrive) mounts a remote filesystem.**
They all use the same pattern, which we adopt:

> **Local metadata + asynchronous sync + on-demand byte hydration.**
> The filesystem the user touches is backed by a **local SQLite database** (instant
> ops). Changes reconcile with the server in the **background**. Only file *bytes*
> are fetched remotely, on demand, from a **content-addressed chunk store**.

This is a **sync engine**, not a mount. It also happens to make multi-tenancy and
security *simpler* (coarse API + normal app authz, not raw-engine exposure), and it
stays **self-hostable** (Rails + Postgres + S3 — no proprietary D1/DO).

## Components

```
  Client (Tauri sync agent)              Rails (control plane)          Storage
  ┌──────────────────────────┐  OAuth   ┌──────────────────────┐
  │ native placeholders      │ ───────► │ Auth / identity      │
  │  (CfAPI/File Provider/FUSE)│         │ Metadata service     │  (tenant-scoped:
  │ LOCAL SQLite (the tree)  │ ◄──────► │  tree + versions +   │   tree, manifests,
  │ sync engine + fastcdc    │  commit/ │  manifests           │   change-log)
  │ chunk cache              │  changes │ Commit + changes API │   in Postgres
  └─────────┬────────────────┘  API     │ Presigned-URL minter │
            │                            │ ActionCable hub (WS) │
            │ chunk PUT/GET (presigned, direct — never through Rails)
            ▼
   ┌────────────────────────────────────────────────────────────┐
   │ R2 / S3: content-addressed chunks  chunks/<tenant>/<hash>   │
   └────────────────────────────────────────────────────────────┘
```

- **Client** never talks to the metadata engine directly — only the Rails API.
- **Bytes** flow client ↔ R2 directly via presigned URLs; never through Rails.
- **Metadata** lives in two places that mirror each other: the **server DB**
  (source of truth) and a **local SQLite** (the client's fast local view).

## Local SQLite schema (client) — the thing that makes ops instant

```sql
-- the file tree the OS sees (reads here are local = instant)
CREATE TABLE nodes (
  node_id     TEXT PRIMARY KEY,      -- stable uuid
  parent_id   TEXT,
  name        TEXT NOT NULL,
  kind        TEXT NOT NULL,         -- 'file' | 'dir'
  size        INTEGER,
  mtime_ns    INTEGER,
  manifest_id TEXT,                  -- current version's manifest (files only)
  state       TEXT NOT NULL,         -- 'placeholder'|'hydrated'|'dirty'|'conflict'
  pin         INTEGER NOT NULL DEFAULT 0,  -- 1 = always keep local
  server_seq  INTEGER                -- server change-log seq this node reflects
);

-- per-file-version recipe: ordered chunk list
CREATE TABLE manifests (
  manifest_id TEXT PRIMARY KEY,      -- = hash of the chunk list
  node_id     TEXT, size INTEGER, created_at INTEGER, device_id TEXT
);
CREATE TABLE manifest_chunks (
  manifest_id TEXT, seq INTEGER, chunk_hash TEXT, offset INTEGER, length INTEGER,
  PRIMARY KEY (manifest_id, seq)
);

-- local chunk cache index
CREATE TABLE chunks (
  chunk_hash TEXT PRIMARY KEY, size INTEGER,
  cached INTEGER NOT NULL DEFAULT 0, cache_path TEXT, last_used INTEGER
);

-- version history (for restore)
CREATE TABLE versions (
  version_id TEXT PRIMARY KEY, node_id TEXT, manifest_id TEXT,
  size INTEGER, created_at INTEGER, device_id TEXT
);

-- sync state
CREATE TABLE sync_cursor (id INTEGER PRIMARY KEY CHECK(id=1),
  server_seq INTEGER NOT NULL, device_id TEXT);

-- local changes not yet pushed (async outbox)
CREATE TABLE outbox (
  op_id INTEGER PRIMARY KEY AUTOINCREMENT, node_id TEXT,
  op TEXT NOT NULL,                  -- 'upsert'|'delete'|'move'
  base_version TEXT, payload TEXT, status TEXT NOT NULL DEFAULT 'pending'
);
```

`stat`/`readdir`/`open` read `nodes`/`manifest_chunks` — **zero WAN**. The WAN
only carries occasional manifest syncs and chunk transfers.

## Chunk & manifest format

- **Chunk**: a content-defined slice (~1–4 MB via **FastCDC**), keyed by
  `sha256` of its (uncompressed) bytes. Stored at `chunks/<tenant>/<hash>`,
  optionally zstd-compressed and per-tenant encrypted. Immutable, content-addressed
  → **dedup is automatic**; an edit re-chunks locally and only *new* chunk hashes
  upload.
- **Manifest**: ordered `[{chunk_hash, offset, length}]` + file metadata.
  Lives in the **server DB** (small — a 1 GB file ≈ 256 hashes ≈ few KB) and is
  mirrored into local SQLite. A **version = a manifest**; versions share chunks.

## Sync protocol (coarse, not chatty)

**Push (local edit → server):**
1. Watcher/provider marks the node `dirty`, enqueues in `outbox`.
2. Sync engine chunks the file (FastCDC) → chunk hashes + manifest.
3. `POST /commit { node, base_version, manifest:[hashes], meta }`.
4. Server replies `{ missing:[hashes], put_urls:{hash→presignedPUT} }`.
5. Client uploads **only missing** chunks directly to R2.
6. `POST /commit/finalize` → server records the version, bumps the file's current
   version, **increments the tenant change-log seq**, returns `version_id`.
7. **Conflict**: if `base_version` ≠ server current → server rejects; client writes
   a conflict copy (keep both, lossless).

**Pull (remote change → local):**
1. ActionCable pushes `{ tenant, seq }` to the device.
2. `GET /changes?since=cursor` → changed nodes + new manifests + versions.
3. Client updates local `nodes`/`manifest_chunks`; for changed files it
   **dehydrates** the placeholder (drops stale cached chunks). Bytes refetch on next
   open. Advance `sync_cursor`.

**Offline:** all ops run against local SQLite; `outbox` accumulates; on reconnect,
push outbox + pull since cursor. **Local-first** = never blocked on the network.

## On-demand hydration (CfAPI / File Provider / FUSE)

Register a sync root over a local folder; the SQLite tree drives the placeholders.

- **Enumerate** (CfAPI `FETCH_PLACEHOLDERS` / File Provider enumerator): read
  `nodes` for the directory → instant, local.
- **Hydrate** (`FETCH_DATA` / `fetchContents`): on open, look up the file's manifest
  → for each needed chunk, serve from cache or fetch from R2 via presigned GET →
  assemble → feed the OS → cache the chunk.
- **Writeback** (CfAPI notify / File Provider `itemChanged`): OS hands back the
  modified file → enter the push flow.
- **Dehydrate / "free up space"**: drop the file's cached chunks, keep the
  placeholder (metadata stays in SQLite).
- **Pin/unpin**: pinned = proactively kept hydrated; online-only = placeholder until
  accessed.

## Change-notification design

- **Transport:** ActionCable WebSocket per device, channel scoped to tenant.
- **Signal:** server keeps a per-tenant monotonic `changes(seq, node_id, op,
  version_id, ts)` log. Each commit increments seq and broadcasts `{tenant, seq}`.
- **Client:** on notify (or reconnect, or periodic backstop) → `GET /changes?since`.
- **Coarse:** one event per commit, batched pull — **no per-stat round-trips**.
- **Backstop:** periodic full reconcile (compare local vs server tree hash) to catch
  notifications missed while offline/disconnected.

## Multi-tenancy & security — *simpler than the mount model*

The mount model's hard problem (JuiceFS has no internal ACL → volume-per-tenant +
per-tenant DB roles + gateway) **disappears** here, because the client talks to a
**coarse Rails API**, not the raw metadata engine:

- **Metadata isolation** = ordinary Rails authorization (`tenant_id` scoping on every
  query). No per-tenant Postgres roles, no exposed engine, no pooler hardening.
- **Storage isolation** = chunks under `chunks/<tenant>/`; the client gets only
  **short-lived presigned URLs for specific chunk keys** — never an R2 key, never the
  whole store.
- **Credentials** = OAuth device token + ephemeral presigned URLs. No standing
  storage creds on the client; revoke by invalidating the token.
- **Encryption (optional)** = client-side per-tenant key before upload → R2 stores
  ciphertext. Dedup scoped per-tenant (avoids cross-tenant existence side-channel).

The architecture that's right for **performance** (local metadata) is also right for
**security** (coarse API + normal authz) and **cost** (cheap metadata DB + R2).

## Versioning

A commit creates a new version = a new manifest; versions share chunks
(content-addressed dedup). Restore = fetch the old manifest's chunks. Block-level
delta + full restorable history, native — no `clone` orchestration, no whole-object
copies.

## Self-host vs managed (the portability win)

Same architecture both ways — only the hosts differ:

| | Managed | Self-host |
|---|---|---|
| Control plane | Rails (cloud) | Rails (user's box) |
| Metadata DB | Postgres (Neon/RDS) | Postgres (local) |
| Chunk store | Cloudflare R2 | user's S3 (SeaweedFS/MinIO/local) |
| Notifications | ActionCable | ActionCable |

Because it's **Rails + Postgres + S3** (not D1/Durable Objects), it self-hosts
cleanly — which is exactly what disqualified the Cloudflare-native variant.

## Build vs adopt

- **Adopt (permissive):** `fastcdc-rs` (MIT) chunking, the R2/S3 SDK, SQLite, the
  native OS placeholder APIs (CfAPI/File Provider/FUSE), ActionCable.
- **Build:** the sync engine (chunk→commit→push, pull→apply, conflict), the local
  SQLite layer, the placeholder providers (hydration → chunk fetch), and the Rails
  metadata service (commit/changes API + presigned minter + change-log + WS hub).

The hard algorithmic part (CDC + dedup) is a library; the build is the orchestration.

## Phasing

- **Phase A — Engine, full-sync, one platform (no placeholders).** Local SQLite +
  chunk/commit/pull against Rails + R2, as a *plain synced folder* (download-all).
  Proves the sync core. Maps to "full-sync now, on-demand later composes."
- **Phase B — On-demand placeholders, Windows first (CfAPI — most mature).** Swap
  the synced folder for hydrate-on-access.
- **Phase C — macOS File Provider, then Linux FUSE.**
- **Phase D — Versioning UI, conflict handling, multi-device polish.**

## What carries over from earlier work

- The `juicefs-backend` trait (read_range/write/stat/readdir) is the right seam for
  the placeholder providers' hydration callbacks — repoint it at the chunk
  cache/manifest instead of WebDAV.
- The Tauri app shell, mount-controller supervision patterns, and OS-keychain auth
  all transfer.
- JuiceFS itself is **dropped** as the data plane; FastCDC + R2 + the manifest model
  replace it.
