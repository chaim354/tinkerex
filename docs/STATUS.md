# Build status — sync engine

**Updated:** 2026-06-11 (overnight autonomous build)

The local-first sync architecture (`docs/architecture-sync-engine.md` +
`docs/sync-protocol.md`) is now real, working code across all three tiers, with the
**multi-device convergence path verified end-to-end** (Rust client ⇄ live Rails
server). Below: what exists, what's proven, how to run it, what's next.

## What's built & verified

| Component | Path | State |
|---|---|---|
| **Local FS core** | `client/fs-provider` | ✅ SQLite tree + content-addressed FastCDC chunk store. 5 tests. |
| **FUSE mount** | `client/fs-fuse` | ✅ Mounts via FUSE-T; **verified in Finder**; persists across remount. |
| **Sync server** | Rails app (`app/`, `db/`) | ✅ Full protocol. 10 tests green on SQLite. |
| **Sync client** | `client/sync-client` | ✅ Typed API + chunk transfer + pull-apply. 5 tests. |
| **End-to-end** | `examples/e2e`, `examples/multi_device` | ✅ **Run live against the Rails server.** |

### Proven end-to-end (Rust client → live Rails server)
- **Single device:** register → mkdir → commit(begin/finalize) → changes → tree → restore.
- **Multi-device:** device A builds a tree; device B (second device, same user)
  initial-syncs via the snapshot, then **converges on A's delete via a delta pull**.
  Cursor advances to `head_seq`. This is the core sync claim, demonstrated.

## How to run it yourself

**The server + cross-stack demo:**
```sh
# from repo root
STORAGE_BACKEND=memory bin/rails server -p 3001        # terminal 1
# terminal 2:
cd client/sync-client
SERVER_URL=http://localhost:3001 cargo run --example e2e
SERVER_URL=http://localhost:3001 cargo run --example multi_device
```

**The FUSE mount (macOS/FUSE-T):** see `client/fs-fuse/BUILD.md`.

**Tests:**
```sh
bin/rails test                              # server: 10
(cd client/fs-provider   && cargo test)     # 5
(cd client/sync-client   && cargo test)     # 5
(cd client/maker-app-core && cargo test)    # 3 (Windows mount controller)
```

## Architecture in one line

Each device backs its filesystem with a **local SQLite tree** (instant ops) + a
**content-addressed chunk cache**; the **Rails server** is the source of truth (tree +
versions + per-user changelog); **chunks** live in R2/S3 and move **client ⇄ storage
directly via presigned URLs** (never through Rails). Devices stay consistent by
pulling the changelog (`seq > cursor`); changes propagate via ActionCable.

## What's NOT done yet (next session)

1. **fs-provider ⇄ sync-client integration (the daemon).** The two halves are
   built and individually tested; the connective `SyncEngine` that (a) watches the
   FUSE mount and *pushes* on write, (b) *pulls* the changelog and applies it to the
   local SQLite, (c) *hydrates* chunks on read — is not yet wired. The pure
   pull-apply algorithm exists and is tested (`LocalTree`); the real apply against
   `fs-provider`'s SQLite mirrors it.
   - **Design note:** needs a `node_id` (server UUID) column added to
     `fs-provider`'s local `nodes` (today it keys by integer inode). That ino↔node_id
     mapping is the main glue to add.
2. **Real chunk transfer to R2.** `sync-client` has `upload_chunk`/`download_chunk`
   (presigned PUT/GET via HTTP) — the mechanism is there but only the *control plane*
   was exercised live (the memory store returns non-HTTP URLs). Needs a real R2
   bucket to round-trip bytes.
3. **Windows `winfsp-rs`** FUSE adapter (Linux + macOS work via `fuser`).
4. **Postgres deploy** — code is adapter-agnostic and tested on SQLite; switching is
   config only (see `docs/SYNC_SERVER.md`). No Postgres available in the build env.
5. **Writeback hardening** (atomic saves; FUSE-T defers `release`), real OAuth
   (placeholder device-token bootstrap today), N+1 preloading in `Sync::Changes`,
   chunk encryption, retention/GC policy job.

## Decisions locked tonight (from your answers)

Tenant = user; full tree on every device; file-sync only; one protocol for managed
(Postgres + R2) and self-host (SQLite + their S3); last-writer-wins (conflict-copies
deferred). Server DB = Postgres for managed, SQLite for self-host — same code, adapter
per deployment (validated against the 37signals multi-tenancy writeup).
