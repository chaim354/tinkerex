# E — Finish the Rust cutover: design

**Date:** 2026-10-13 (written at the end of the watch week's sixth day) · **Status:** design, executed
in slices (plan: `docs/superpowers/plans/2026-10-13-e-cutover-finish.md`) · **Source:**
`docs/AUDIT-2026-10-12-readiness.md` §2.4 and §4 row E; the sync repo's
`docs/superpowers/plans/2026-10-07-rust-cutover.md` §5–§7 and `2026-09-30-rust-rewrite.md` §7.4, §9.
**Cross-repo:** most of the work is in `chaim354/tinkerex-sync`; the maker app carries D3/D4 and the
accessory's env; the client carries one documentation row.

## Where the cutover stands (measured 2026-10-14 ~02:00 UTC)

The `sync` accessory has run the Rust binary (`tinkerex-sync serve`, revision `38931307…`, image
`:latest` = `9409d6ce…`) since 2026-10-07 18:22 UTC. Nothing recorded the watch week; this did:

| check (cutover plan §5) | result |
|---|---|
| nightly `sync` backups | six, 2026-10-08 → 10-13, all `status=0`, 16 KB each, `bin/backup-status` |
| accessory log, 150 h, `ERROR` or `response failed` | none |
| maker app log, 150 h, `FileLayer::FetchError` | none |
| `stats --brief` | 13 nodes / 4 versions at the swap → 20 nodes / 7 versions today |
| volume `tinkerex_sync_storage` | 982 kB |
| `gc reap-pending --dry-run` / `reap-storage --dry-run` / `retention --dry-run` | 0 / 0 / 0 (retention is `KeepAll`) |
| rollback | never needed; `ruby-4148fcd6…` still resolves and sits on the box |
| maker deploys against it this week | three (F, D1 twice counted once as #358), each probed, none with a FetchError |

Not run by hand: one manual file round-trip through the maker UI; the node count grew through
ordinary use instead. The week ends 2026-10-14 18:22 UTC.

## Decisions

1. **The week is recorded where the plan says, with these numbers**, in the cutover plan's §0.5 and
   as ticks on the rewrite plan's §7.3 (done on the day, never ticked) and §7.4 (the week and the
   dry-runs; D3 is the maker PR below).
2. **`bin/build-and-push` defaults to `rust`.** The audit's footgun: a bare run built the Ruby image
   and moved `:latest`, so a bare run followed by `kamal accessory reboot sync` rolled production
   back to Ruby silently. `SYNC_IMPL=ruby` stays available until Phase 6 deletes it (it is how the
   rollback image would be rebuilt), and the test that drove the bare invocation now pins the Rust
   arm. `Dockerfile.rust` builds on `rust:1.99.0-bookworm`, the toolchain CI pins, not a floating
   `rust:1`.
3. **D4 now: the maker's `bin/sync-server` defaults to `rust`.** The blocker named in the plan
   (cargo in `ci/runner/Dockerfile`) is already gone — the runner image installs rustup to build
   resvg. The `test-chunk-remote` job gets a persistent `CARGO_TARGET_DIR` under the runner's
   `/_work` bind mount so only the first run on each runner pays a cold build. The Ruby arm stays
   until Phase 6 deletes it.
4. **D3 now, as a PR that is merged and rebooted at the week's end:** `SYNC_SCHEDULER: "1"` under
   the accessory's `env.clear`. The dry-runs read 0 / 0 / 0 and retention is `keep_all`, so the
   scheduler's first real `reap-pending` at :30 reaps nothing; the morning log is the proof.
5. **Phase 6 (the decommission of the Ruby) is prepared as a stacked PR and merged only when the
   operator calls the rollback window closed** (rewrite plan §9: delete the engine, `host/`,
   `test/dummy`, `db/`, the gemspec, the Ruby `Dockerfile` and CI jobs; keep the verifier and the
   recorder, with the route-coverage guard reading a checked-in list the binary prints via a new
   `tinkerex-sync routes` subcommand; `conformance-rust` becomes `conformance`; CLAUDE.md and
   README rewritten for the binary; `docs/SYNC_SERVER.md` marked HISTORICAL). The maker side of
   Phase 6 (delete `bin/sync-server`'s Ruby arm, drop `CABLE_ADAPTER` / `RAILS_LOG_TO_STDOUT` from
   the accessory env, the §3 row, `bin/restore-db`'s Ruby fallback) is its own PR, after the sync
   one merges.
6. **The client gets one row**: its CLAUDE.md §7 says the nudge "starts working at that cutover";
   it now says it does, with the measured 6.6 / 5.2 / 8.0 ms. The CI legs that point devices at
   `http://192.168.1.95` keep doing so until the operator adds the NPM proxy host for
   `sync.tinkerex.home` (recorded with D1); switching them first would break the legs.

## Out of scope (recorded)

Postgres in CI (the sync repo's one runner is a Mac with no Postgres; the Linux runners are
registered to the maker repo only — an operator decision about runners), the auth-parity pins the
audit's §2.4.5 lists (the corpus pins the cases that matter; the rest is a follow-up), and the
client's `Origin`-less cable connection (the Rust server accepts it; nothing to fix).

## Verification

Each slice is gated by its repo's own gates: the sync repo's `bundle exec rake test`, `cargo
test`, `bin/conformance-rust` (18 runs, 0 skips) and `test/build_and_push_test.rb`; the maker's
`bin/ci` with the `test-chunk-remote` leg now booting the Rust binary by default (identical run
counts on the three legs); Phase 6's PR body must show the corpus green against the binary with
the Ruby gone and the route list matching. D3's proof is the accessory log the morning after the
reboot.
