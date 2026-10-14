# Sync server — moved to `chaim354/tinkerex-sync`

**This document left on 2026-08-25.** It is now `docs/SYNC_SERVER.md` in
[`chaim354/tinkerex-sync`](https://github.com/chaim354/tinkerex-sync), which is where the code it
describes — the Rails implementation — lived from the 2026-08-20 extraction until Phase 6 deleted
it on 2026-10-14; it is marked HISTORICAL there, and the Rust binary is what runs.

This stub stays because roughly eight documents and code comments in this repo cite the old path
(`docs/r2-migration.md`, `docs/cost-model.md`, `docs/parity-roadmap.md`, `docs/sync-protocol.md`,
`docs/research-self-host-options.md`, `docs/FIX-LOG-2026-08-19.md`, and `config/database.yml`).
Deleting the file would break every one of them silently; a redirect costs nine lines.

**Why it moved rather than being rewritten here.** Its opening line — "the Rails app *is* the sync
engine's source of truth" — had become false in this repo and was true again in that one, until
Phase 6. The document was not stale about its subject; it was in the wrong repository. (CLAUDE.md
§12.13.)

## The one thing worth knowing before you follow the link

Its **connection-pooler** section describes a boot check that **did not run** while the Rails host
served — not here, and not there either: `Sync::PostgresPoolerCheck` was correct and tested, but
nothing invoked it once its initializer left THIS app with the extraction. That gap was first
recorded in `docs/FIX-LOG-2026-08-19.md` ("the probe itself never executes anywhere… a boot refusal
no gate exercises"), *before* the extraction, when it meant "unexercised"; after it, "unwired."

**The binary closed it.** `tinkerex-sync serve` runs the same probe at boot on Postgres — a warning
by default, a refused boot with `SYNC_DB_POOLER_CHECK=refuse` — and `tinkerex-sync doctor` runs it
on demand (`crates/tinkerex-sync/src/services/doctor.rs`; the banner on the moved document says so).

**The constraint itself is real and unchanged**: the sync server's `next_seq!` row lock must span a
transaction on one backend connection, so a pooler in front of it must be session or transaction
mode, never statement. **It does not bind this app** — nothing here calls `next_seq!` (CLAUDE.md
§14e).
