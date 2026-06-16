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
- **Tests** (`test/`): green on SQLite **and** Postgres — full HTTP flow + service-level
  dedup/refcount/restore/idempotency, conflict detect/keep/split, locks, retention/GC,
  auth/pairing, tenant isolation, concurrent-commit seq ordering, orphan-chunk reaper. The
  suite has grown to **144** on `main` (→ **154** with the G2+G4 hardening branches; see
  `docs/STATUS.md`).

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

### Connection pooler (managed Postgres) — MUST be session/transaction mode

`User#next_seq!` takes a `SELECT … FOR UPDATE` row lock on the `users` row that **must span the
read and the write of `head_seq` within one transaction**. A connection pooler in front of
Postgres (PgBouncer, Neon's pooled endpoint, RDS Proxy) therefore **must run in session or
transaction mode, never statement mode** — statement mode hands each statement a different
backend connection, breaking the transaction-spanning lock and risking **duplicate changelog
seqs** (changelog corruption). A boot-time guard enforces this:
`config/initializers/postgres_pooler_check.rb` (+ `lib/postgres_pooler_check.rb`) probes the
connection and **refuses to boot** behind a statement-mode pooler. Disable with
`DB_SKIP_POOLER_CHECK=1`; it's a no-op on SQLite and when no Postgres primary is configured.

### Lock ordering — why `next_seq!` runs FIRST in a commit (the deadlock fix)

In Postgres, every node/version/changelog/chunk insert in a commit FK-references `users` and so
takes a **`FOR KEY SHARE`** lock on the user's row. If a commit inserted those *first* and called
`next_seq!` (which takes the stronger `FOR UPDATE`) *second*, two concurrent same-user commits
would each hold KEY SHARE and both want UPDATE → a **lock-upgrade deadlock** (observed live under
a concurrent-commit load test). The fix: **`next_seq!` is the first statement** in every write
service (`Sync::Commit`, `Mutation`, `Restore`, `Conflicts`) — take the strong lock up front so a
user's commits serialize cleanly. Regression: `test/services/sync/concurrent_seq_test.rb`.

### TLS / `sslmode`

The managed profile honors `sslmode` via `DATABASE_URL` / `PGSSLMODE` (e.g. `sslmode=require` or
`verify-full` for Neon/RDS). `config/database.yml`'s `postgres` profile threads it through.

### Solid Queue / Cache / Cable on managed Postgres

The Solid stores can stay on SQLite or move onto the managed Postgres alongside the primary (a
managed deployment that doesn't want a writable SQLite volume puts them on PG). Config-only.

## Storage config (R2/S3)

```
STORAGE_BACKEND=s3
CHUNK_BUCKET=...           CHUNK_ENDPOINT=https://<acct>.r2.cloudflarestorage.com
CHUNK_REGION=auto          CHUNK_ACCESS_KEY_ID=...  CHUNK_SECRET_ACCESS_KEY=...
```
Tests/dev default to the in-memory store (`STORAGE_BACKEND=memory`).

Three backends:
- **`s3`** — R2/S3/SeaweedFS, the production + deployed data plane (bytes → object storage).
- **`memory`** — **control-plane only.** Mints fake `memory://` URLs and stores nothing, so the
  client's real PUT/GET data plane can't move bytes through it. Use it for HTTP-contract tests
  (the sync-engine integration suite), NOT for anything that actually transfers chunk bytes.
- **`local`** — a **real** filesystem-backed data plane with **no external object store** (no
  SeaweedFS/MinIO; permissive). Presigns real `http(s)://<host>/v1/chunks/blob/<user>/<hash>?exp&sig`
  URLs that the client PUTs/GETs; bytes land under `CHUNK_LOCAL_DIR` (default `tmp/chunk-store`).
  The URL is HMAC-signed with the Rails secret (keyed by user+hash+expiry), so it's untamperable +
  per-user-scoped — the same property as a presigned SigV4 key (§8). This is the self-hosted
  single-box option and what the **two-device real-mount tests** use to move bytes between two
  co-located mounts. Zero-config locally (presigned URLs point back at the request host); set
  `CHUNK_PUBLIC_URL` when the client reaches the server by a different host than it presents.
  ```
  STORAGE_BACKEND=local   CHUNK_LOCAL_DIR=/var/lib/maker/chunks   [CHUNK_PUBLIC_URL=http://host:3001]
  ```

## Versioning & GC (built for restore from day one)

Every commit writes an immutable `version` → content-addressed manifest; versions
chain via `parent_version_id` and share chunks. `chunks.refcount` = number of live
versions referencing a chunk. **Deleting a node only tombstones it — versions and
their chunks are retained, so restore always works.** Chunks are freed only when a
*version* is pruned by a retention policy (`Sync::Gc.prune_version!` decrements
refcounts; `Sync::Gc.sweep_orphans!` deletes refcount-0 chunk rows **and** their
storage objects after a grace period — `ChunkStore#delete` → S3/R2 `delete_object`,
best-effort/idempotent).

**Retention is wired** via `RetentionJob` (Solid Queue recurring, nightly 4am):

```
RETENTION_POLICY=keep_all   # default — self-host: never prunes (storage is the user's)
RETENTION_POLICY=tiered     # managed: <24h all, 1–30d daily, 30d–1y weekly, >1y monthly
```

Both modes ALWAYS keep a node's `current_version` and any **pinned** version
(`versions.pinned`). See `docs/versioning.md` for the keep-set math.

## Deferred (matches the spec)

Sharing/multi-user, maker-app metadata, and per-tenant chunk encryption. (Updated since:
**conflict resolution is built** — `base_version_id` conflict detection + keep/split replaced
last-writer-wins, 2026-06-12, §`Sync::Conflicts`; **selective sync** is built client-side, 2026-06-15;
**real auth** — Rails 8 built-in signup/confirm/login/reset + OmniAuth seam — replaced the
placeholder web bootstrap, 2026-06-15, with the device-token + pairing mechanism underneath.) Still
open: N+1 preloading in `Sync::Changes` (fine for small deltas; the bulk path is `Sync::Tree`).

## Multi-tenancy note (per the 37signals reference)

v1 is **one user per library** with `user_id` scoping on a shared DB — simplest and
fully portable. If/when multi-user or db-per-tenant is wanted, the
[Active Record Tenanted](https://dev.37signals.com/rails-multi-tenancy/) pattern slots
over these same models (SQLite-per-tenant self-host, Postgres-per-tenant managed).
