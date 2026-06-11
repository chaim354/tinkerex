# Sync Protocol — Clients ⇄ Server ⇄ Storage

**Status:** active spec · **Last updated:** 2026-06-11

## Scope & assumptions (decided)

- **Tenant = user.** One person owns one library, synced across *their own* devices.
  No sharing, no per-user permissions in v1.
- **Full tree on every device.** Every device holds the entire file tree as
  on-demand placeholders; each pulls the full per-user changelog. (Selective sync
  deferred.)
- **File sync only.** This spec covers files ⇄ chunks ⇄ tree. Maker-app data
  (projects/inventory/BOM/previews) is a separate Rails layer, out of scope here.
- **One protocol, both deployments.** Managed (Rails cloud + R2) and self-host
  (Rails on the user's box + their S3) run the *same* protocol; only hosts/creds
  differ.
- **No write-write conflict handling yet.** Last-writer-wins via a version chain;
  conflict-copies deferred.

## Actors & topology

```
   Device A ─┐                  ┌──────────── Rails (control plane) ────────────┐
   Device B ─┼─ HTTPS API ─────►│ auth · devices · tree · commit · changes      │
   Device C ─┘   WebSocket  ◄───│ presign/token minter · changelog · CableHub   │
        │                       │ Postgres: nodes, versions, manifests,         │
        │                       │           chunks(refcount), changelog         │
        │ direct chunk          └───────────────────────────────────────────────┘
        │ PUT/GET (presigned / scoped token — bytes NEVER through Rails)
        ▼
   ┌──────────────────────────────────────────────────────────────────────┐
   │ R2 / S3:  chunks/<user>/<hash>   (content-addressed, immutable)        │
   └──────────────────────────────────────────────────────────────────────┘
```

Rails is the **authoritative source of truth** for the tree, manifests, and the
changelog. Each device keeps a **local SQLite mirror** (the `fs-provider` tree) and a
**local chunk cache**. Bytes flow device ⇄ storage directly.

## Three communication channels

| Channel | Direction | Carries |
|---|---|---|
| **HTTPS JSON API** | device → Rails | auth, device registration, tree snapshot, commit, changes pull, credential minting |
| **ActionCable (WebSocket)** | Rails → device | real-time "changelog advanced to seq N — pull" + presence |
| **Direct to storage** | device ⇄ R2/S3 | chunk `PUT`/`GET` via presigned URLs / scoped token |

## Data model

**Server (Postgres, authoritative):**
- `users(id, head_seq)` — `head_seq` is the per-user monotonic changelog cursor.
- `devices(id, user_id, name, last_seen)`.
- `nodes(node_id, user_id, parent_id, name, kind, current_version_id, deleted, updated_seq)`
  — `node_id` is a stable UUID shared across devices; `deleted` is a tombstone.
- `versions(version_id, node_id, manifest_id, size, created_at, device_id, parent_version_id)`.
- `manifests(manifest_id)` + `manifest_chunks(manifest_id, seq, chunk_hash, offset, length)`
  — `manifest_id` = hash of the ordered chunk list (identical content dedups).
- `chunks(chunk_hash, size, refcount)` — refcount drives GC.
- `changelog(seq, user_id, node_id, op, version_id, ts)` — the ordered feed;
  `seq` per-user monotonic (= `users.head_seq` at write time).

**Client (local SQLite — extends `fs-provider`):**
- `nodes` / `manifests` / `manifest_chunks` — mirror of the server tree (already built).
- `sync_cursor(server_seq, device_id)` — last applied changelog seq.
- `outbox(op_id, node_id, op, base_version, status)` — local changes pending push.
- chunk cache on disk (content-addressed; `LocalChunkStore` = the cache, R2 = origin).

## The changelog & cursor (the heart of it)

Every mutation appends one `changelog` row and bumps `users.head_seq`. A device's
`sync_cursor.server_seq` is its position. **Pull = "give me changelog entries where
seq > cursor."** Applying is idempotent and ordered, so a device always converges to
the server state. This is the only mechanism that keeps N devices consistent.

## Identity, devices, auth

1. User authenticates (OIDC / Rails auth) → user token.
2. `POST /devices {name}` → `device_id` + device token (stored in OS keychain).
3. The device token authorizes the API + the ActionCable subscription, scoped to that
   user's library. Revoke a device by invalidating its token.

## Credential / storage model

The client never holds standing storage keys.
- **Upload (write):** per-commit **presigned PUT URLs**, one per *missing* chunk key —
  so Rails controls exactly what's written and runs the dedup negotiation.
- **Hydration (read):** a short-lived (~1 h) **read-only token scoped to
  `chunks/<user>/`**, refreshed by Rails — so the latency-sensitive read path fetches
  chunks directly without a Rails round-trip per chunk. (Reads are the user's own
  data; the token can't write and expires.)

## Protocol flows

### 1. Device onboarding + initial sync
```
Device                         Rails
  │ POST /devices ───────────────►│  register, issue device token
  │ GET /tree (paginated) ───────►│  full current tree: nodes + manifests + head_seq
  │ ◄── nodes/manifests, head_seq │
  │ build local SQLite, cursor = head_seq
  │ open WebSocket, subscribe LibraryChannel
```
Files arrive as placeholders (no chunks fetched); bytes hydrate on first access.

### 2. Push (local edit → server)
```
Device                                   Rails                         R2
  │ FUSE write→flush: FastCDC chunks, local manifest, mark dirty/outbox
  │ POST /commit {node, base_version, manifest:[hash,off,len], size} ─►│
  │ ◄── {commit_id, missing:[hashes], put_urls:{hash→presigned}} ──────│  (dedup: only missing)
  │ PUT missing chunks ───────────────────────────────────────────────────────►│  (direct)
  │ POST /commit/{id}/finalize ───────────────────────────►│ verify chunks, create
  │ ◄── {version_id, seq} ─────────────────────────────────│ version, set current,
  │ mark synced, cursor=seq, clear outbox                  │ head_seq++, changelog++,
  │                                                        │ chunk refcount++
  │                          Rails ──ActionCable {seq}──► OTHER devices (pull)
```

### 3. Pull (server change → device)
```
Device                         Rails
  │ ◄── Cable {head_seq:N} ──────│   (or reconnect / periodic backstop)
  │ GET /changes?since=cursor ──►│
  │ ◄── ordered entries: {node, op, manifest, version, seq} ──│
  │ apply to local SQLite; for changed files → dehydrate placeholder (drop stale chunks)
  │ cursor = last applied seq
```
On next open of a changed file, hydration fetches the new chunks.

### 4. Hydration (on-demand bytes)
```
FUSE read(node, range)
  │ fs-provider → needed chunk hashes for the range
  │ cache hit → serve; miss → GET chunks/<user>/<hash> from R2 (read token) → cache → serve
```

### 5. Offline + reconnect + reconcile backstop
- **Offline:** ops run against local SQLite; `outbox` accumulates; cached/pinned files
  still readable.
- **Reconnect:** push `outbox` in order, then `GET /changes?since=cursor`.
- **Backstop:** the changelog is pruned on a retention policy. If a device's cursor is
  older than the oldest retained `seq` (offline too long), it falls back to a **full
  `GET /tree` resync** and resets its cursor. A periodic lightweight reconcile (compare
  a tree summary hash) catches anything a missed Cable event dropped.

## Versioning & restore

Each commit is a new `version` (a manifest); versions chain via `parent_version_id`
and share chunks. **Restore** = `POST /nodes/{id}/restore {version_id}` → server makes
a *new* version whose manifest = the old one (chunks already exist) → propagates as a
normal change. `GET /nodes/{id}/versions` lists history.

## Chunk lifecycle & GC

- `chunks.refcount` ++ when a committed manifest references it, -- when a version is
  pruned/deleted.
- A GC job deletes `chunks` with `refcount = 0` from R2 after a grace period.
- Version-pruning policy (keep last N / daily-for-30d) lowers refcounts → frees chunks.
- **Orphans:** chunks uploaded for a commit that never finalized have refcount 0 → GC'd.

## API surface

| Endpoint | Purpose |
|---|---|
| `POST /devices` | register device → token |
| `GET /tree` | full tree snapshot + head_seq (initial sync; paginated) |
| `GET /changes?since=<seq>` | ordered changelog delta |
| `POST /commit` | begin commit → `{commit_id, missing, put_urls}` |
| `POST /commit/{id}/finalize` | create version → `{version_id, seq}` |
| `POST /storage/read-token` | short-lived prefix-scoped R2 read credential |
| `GET /nodes/{id}/versions` · `POST /nodes/{id}/restore` | history / restore |

## ActionCable

`LibraryChannel` subscribed per device, scoped to the user's stream. Any commit
broadcasts `{head_seq}` to all the user's devices; each pulls `/changes`. The
committing device no-ops (its cursor already advanced). Heartbeats update
`devices.last_seen`.

## Idempotency & failure modes

- **Commit** keyed by client-generated `commit_id` → retry-safe.
- **Chunk upload** is content-addressed → re-PUT is a no-op (idempotent).
- **Changelog apply** is idempotent; the cursor advances only after a successful apply.
- **Finalize after upload fails** → retry finalize (chunks already present).
- **Uploaded-but-never-finalized** → orphan chunks (refcount 0) → GC.
- **Mid-pull drop** → resume from cursor.

## Managed vs self-host (same protocol, different hosts)

| | Managed | Self-host |
|---|---|---|
| Rails | our cloud | user's box |
| Postgres | Neon/RDS | local |
| Storage | R2 | their S3 (SeaweedFS/MinIO/local) |
| Multi-tenant | by `user_id` scoping | single user (trivial) |
| Client config | our server URL | their server URL |

The client only needs the server URL + a token; everything else is identical.

## Deferred (explicitly out of v1)

- Write-write **conflict** resolution (currently last-writer-wins).
- **Sharing / multi-user** workspaces + permissions.
- **Selective sync** (per-device folder subscriptions).
- **Maker-app metadata** sync (projects/inventory/previews) — separate layer.
- Per-tenant **chunk encryption** (designed-for; not v1).

## Build order

1. **Server skeleton:** `nodes`/`versions`/`manifests`/`chunks`/`changelog` + `users.head_seq`; `commit` (+ presign), `finalize`, `changes`, `tree`.
2. **`R2ChunkStore`** in the client (object_store + presigned/token) — chunks leave `/tmp`.
3. **Client sync engine:** outbox push (commit→upload→finalize), changelog pull→apply, cursor + reconcile backstop.
4. **ActionCable** `LibraryChannel` + the client listener (real-time pull).
5. **Hydration** wired to the read-token path; versions/restore; GC job.
