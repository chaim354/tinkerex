# Sync server (Rails) — implementation notes

Implements `docs/sync-protocol.md`. The Rails app *is* the sync engine's source of
truth; client devices push to it and pull from it. Bytes never pass through Rails —
clients PUT/GET chunks directly to object storage via presigned URLs.

## What's built

- **Schema** (`db/migrate/.../create_sync_engine.rb`): `users(head_seq)`, `devices`,
  `nodes`, `versions`, `manifest_chunks`, `chunks(refcount)`, `changelog_entries`,
  `pending_commits`. Adapter-agnostic — runs on SQLite and PostgreSQL.
- **Models** (`app/models`): with the per-user changelog cursor (`User#next_seq!`).
- **Services** (`app/services`):
  - `Sync::Commit` — two-phase content commit (begin → missing/presign → finalize).
  - `Sync::Mutation` — the changelog invariant for metadata ops.
  - `Sync::Restore`, `Sync::Changes`, `Sync::Tree`, `Sync::Gc`.
  - `Storage::ChunkStore` (+ `S3ChunkStore` for R2/S3, `MemoryChunkStore` for tests).
- **API** (`app/controllers/v1`): see below.
- **ActionCable** (`LibraryChannel`): broadcasts `head_seq` on every commit.
- **Tests** (`test/`): 10 tests, green on SQLite — full HTTP flow + service-level
  dedup/refcount/restore/idempotency.

## API (v1)

| Method & path | Body / params | Returns |
|---|---|---|
| `POST /v1/auth/register` | `email`, `device_name` | `device_token`, `head_seq` (bootstrap; placeholder auth) |
| `POST /v1/devices` | `name` | another device token |
| `POST /v1/commit` | `commit_id, node_id, parent_node_id, name, base_version_id, size, manifest[]` | `missing[]`, `put_urls{}` |
| `POST /v1/commit/:commit_id/finalize` | — | `version_id`, `seq` |
| `GET /v1/changes` | `since`, `limit` | `changes[]`, `head_seq` |
| `GET /v1/tree` | `after_id`, `limit` | `nodes[]`, `head_seq`, `next_after_id` |
| `POST /v1/nodes` (mkdir) | `node_id, parent_node_id, name` | `seq` |
| `DELETE /v1/nodes/:node_id` | — | `seq` (tombstone; versions retained) |
| `POST /v1/nodes/:node_id/move` | `new_parent_node_id, new_name` | `seq` |
| `GET /v1/nodes/:node_id/versions` | — | `versions[]` |
| `POST /v1/nodes/:node_id/restore` | `version_id` | new `version_id`, `seq` |
| `POST /v1/chunks/download` | `hashes[]` | `urls{ hash => presigned GET }` |
| WebSocket `/cable` | `?token=` | `LibraryChannel` → `{head_seq}` on change |

Auth: `Authorization: Bearer <device_token>`.

## Adapter-agnostic, without compromising performance

Everything uses portable, fast ActiveRecord — no PostgreSQL-only SQL in the hot path:
- `insert_all` for manifest chunks + new chunks (bulk).
- `update_all("refcount = refcount + 1")` for refcount bumps.
- `User#next_seq!` uses `lock!` — `SELECT … FOR UPDATE` on Postgres (serializes a
  user's concurrent commits), a harmless reload on SQLite (which serializes writes
  globally anyway). Correct and fast on both.
- Stable cross-device ids are string UUIDs; internal PKs are bigint. Indexed lookups.

Dev/test run on **SQLite** (which proves the portability). Switch to **PostgreSQL**
for managed with config only:

```ruby
# Gemfile (managed)
gem "pg"
gem "aws-sdk-s3"   # the S3/R2 chunk store requires it lazily
```
```yaml
# config/database.yml — managed/production primary
production:
  primary:
    adapter: postgresql
    url: <%= ENV["DATABASE_URL"] %>
    pool: <%= ENV.fetch("RAILS_MAX_THREADS") { 5 } %>
  # keep Solid Queue/Cache/Cable on their own DBs (SQLite or Postgres) as desired
```

No model or service code changes — the schema and queries are identical.

## Storage config (R2/S3)

```
STORAGE_BACKEND=s3
CHUNK_BUCKET=...           CHUNK_ENDPOINT=https://<acct>.r2.cloudflarestorage.com
CHUNK_REGION=auto          CHUNK_ACCESS_KEY_ID=...  CHUNK_SECRET_ACCESS_KEY=...
```
Tests/dev default to the in-memory store (`STORAGE_BACKEND=memory`).

## Versioning & GC (built for restore from day one)

Every commit writes an immutable `version` → content-addressed manifest; versions
chain via `parent_version_id` and share chunks. `chunks.refcount` = number of live
versions referencing a chunk. **Deleting a node only tombstones it — versions and
their chunks are retained, so restore always works.** Chunks are freed only when a
*version* is pruned by a retention policy (`Sync::Gc.prune_version!` decrements
refcounts; `Sync::Gc.sweep_orphans!` deletes refcount-0 chunks after a grace period).
v1 keeps all history — set a retention policy later if storage demands it.

## Deferred (matches the spec)

Write-write conflict resolution (last-writer-wins now), sharing/multi-user, selective
sync, maker-app metadata, per-tenant chunk encryption, real OAuth (placeholder
device-token bootstrap today), and N+1 preloading in `Sync::Changes` (fine for small
deltas; the bulk path is `Sync::Tree`).

## Multi-tenancy note (per the 37signals reference)

v1 is **one user per library** with `user_id` scoping on a shared DB — simplest and
fully portable. If/when multi-user or db-per-tenant is wanted, the
[Active Record Tenanted](https://dev.37signals.com/rails-multi-tenancy/) pattern slots
over these same models (SQLite-per-tenant self-host, Postgres-per-tenant managed).
