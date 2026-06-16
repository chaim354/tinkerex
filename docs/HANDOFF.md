# Handoff — state as of 2026-06-16

Snapshot for the next agent/developer. **Everything lives on `main`** (HEAD `94b7f02`, pushed).
Detailed running log: `docs/STATUS.md`. Architecture: `CLAUDE.md`. Strategy: `docs/parity-roadmap.md`,
`docs/research-sync-competitors.md`, `docs/feature-set-and-workflows.md`. This file = "where are we,
what's blocked, what's next." Persistent memory also holds key decisions/gotchas (see the project
memory: scope/lane, workflow-orchestration, sync-competitor-gaps, auth-decision, maker-app-layer,
per-os-mount-gotchas).

---

## TL;DR

The **file/sync layer is rock-solid and now has automated real-mount end-to-end on all three OSes.**
A web UI MVP + real auth landed. The product layer (the maker app: projects/inventory/BOM/preview)
is the next big arc and the file foundation is ready for it. A long cross-OS debugging saga this
session surfaced + fixed real bugs on actual hardware (3 Windows CfAPI receive-side bugs, a daemon
self-unmount, a stale FUSE dependency).

**Since the 2026-06-15 snapshot (HEAD now `94b7f02`):** three more PRs landed — **G2** managed-
Postgres hardening (statement-pooler boot guard + `sslmode` + a real `next_seq!` deadlock fix),
**G4** storage-orphan chunk reaper (closes the abandoned-upload leak — see Parked follow-ups, now
resolved), and **G5/G8/G10** file-layer polish (opt-in outbox debounce, special-file `EPERM`
guardrail, delta-on-wire audit). **R2 was also validated live** (per-chunk hydrate ~85–205 ms;
`docs/r2-migration.md` §5). Details: `docs/STATUS.md` (2026-06-16 section).

**File-layer hardening + prod-like infra wave (2026-06-16, later; all merged to `main`):**
- **Correctness/POSIX:** POSIX-conformance pass (errno/rename/`ENAMETOOLONG`/atime, PR #24);
  **symlinks end-to-end** — client (#25, git-on-mount works) *and* server-side sync (#26);
  **verify-on-hydrate** chunk-integrity (`ChunkCorrupt` rejection at the fetch chokepoint, #28);
  **N-way conflict** resolution — concurrent 3+-device edits no longer collapse to one record (#29);
  the rename-cycle + `apply_remote` cyclic-reparent **documented-reds both fixed** (#33). Result:
  `fs-provider` 170/0 with **0 ignored**.
- **Offline (the workshop use case):** `make-available-offline` / `offline_readiness` engine
  primitives + pin (an `Include` subscription) + a `maker-offline` CLI (#30). Engine done; UI hook
  left for the app team.
- **Conformance (#34, `docs/conformance-status.md`):** data plane **byte-perfect** — fsx (25k ops)
  + rclone⇄WebDAV (0 diffs); residual pjdfstest failures are deliberate non-goals only. Note: real
  FUSE **does** run locally in Docker (`--cap-add SYS_ADMIN --device /dev/fuse`).
- **Deploy infra:** shared **ghcr registry** (`ghcr.io/chaim354/tinkerex`) — Mac builds once, both
  boxes pull (PR #22). A **prod-like test box is LIVE**: OVH `b3-8` at **`15.204.216.249`** (US-East
  VA), deploy with **`kamal deploy -d ovh`** (`config/deploy.ovh.yml`, creds shell-sourced). Measured
  **11.2× parallel hydration over real WAN** there (`docs/r2-migration.md` §5 + `examples/parallel_hydrate_wan.rs`).
- **Cross-OS app build CI (#32):** `gh workflow run build-app.yml [-f os=macos]` → downloadable
  `.dmg`/`.msi`/`.AppImage` runnable on any machine of that OS (`docs/building-the-app.md`).
- **Research/plans landed:** self-host options (#31, `docs/research-self-host-options.md` — keep the
  engine; BYO-S3 works, rclone for any-cloud); **implementation plans for the next two big arcs:**
  **sharing/multi-user** (`docs/plan-sharing.md`) and **at-rest E2E encryption** (`docs/plan-encryption.md`).
  Ordering: **auth → sharing → encryption**.

> **⚠️ SECURITY ACTION — rotate two live credentials** that were pasted into a prior chat session
> and are therefore considered exposed: the **R2 API token** (Access Key ID `3fb277a9…` + secret,
> scoped to bucket `maker-chunks-prod`) and the **ghcr PAT** (`ghp_…`, the registry password). Mint
> fresh ones; the deploy reads both from the shell, so rotation is just new exports.

---

## ✅ Confirmed working (verified live / tested, not just compiled)

### Automated real-mount E2E on all three OSes (the headline this session)
Every OS exercises a real kernel mount + A↔B byte-for-byte (create/edit/delete/rename/nested/
multi-chunk) automatically in `nightly.yml`:
- **Linux FUSE** — `two-device-fuse-linux` ✅ green. (Fixed this session: `fuser` 0.14→0.17 upgrade
  + the real bug — `run_until_unmounted` used `umount_and_join()` [unmounts immediately in 0.17]
  instead of `join()` [wait-only]. See `[[linux-fuse-mount]]` memory.)
- **Windows CfAPI** — `two-device-cfapi-windows` ✅ green. (Fixed this session: 3 receive-side bugs
  — empty-dir enumeration `0x8007017C`, create-materialization parent-placeholders, delete/rename
  removal + echo-guard. See `[[cfapi-receive-side]]` memory + `docs/plan-windows-cfapi-migration.md`.)
- **macOS WebDAV** — `two-device-webdav-macos` ✅ green (runs on the interactive mac runner; boots
  its own `STORAGE_BACKEND=local` server).
- **Cross-machine 3-OS** — `cross-os-e2e.yml` (Win push→Mac pull→Linux edit→Mac+Win pull) **✅ PASSED
  end-to-end** (run 27579865391): all 6 legs green with real mounts, byte-for-byte, against the shared
  deployed server. The macOS→shared-server routing risk did NOT materialize (both mac legs reached
  `192.168.1.95`) — but it's the historical flake to watch if a future run's mac legs BLOCK.
- Single-mount conformance also green: rclone⇄WebDAV (0 diff), fsx⇄FUSE (100k ops), CfAPI 24-file.

### Sync engine / file layer
- **`fuser` 0.17** across `fs-fuse`+`sync-engine`; full per-PR build matrix green on `main`.
- **GC/retention wired** — `Sync::RetentionPolicy` (keep_all self-host / tiered managed; current +
  `pinned` never pruned), `RetentionJob` (nightly), real S3 `delete_object` in `sweep_orphans!`.
- **Selective sync** — per-device subtree subscriptions + a client-side proactive-hydration gate
  (server tree stays complete; on-demand open still hydrates out-of-scope files). API on the
  provider/engine; no app UI yet.
- **Progressive/range hydration** — `hydrate_range` fetches only chunks overlapping a read; write-open
  still full-hydrates.
- **Bandwidth controls** — `ThrottledChunkIO` token-bucket up/down caps (config via `DaemonConfig`).
- **Adversarial fault harness** (`fault_injection.rs`) — found + fixed 2 changelog ordering bugs
  (topological outbox drain; defer-and-retry + `needs_resync`→`pull_snapshot` floor). 0 silent losses
  under 1000×200 soak. See `[[sync-ordering-bugs]]`.
- **Stress/concurrency** (`concurrency_load.rs`, up to 50 devices) + **multi-filetype conformance**
  (`multifiletype_conformance.rs`, 15 types) — no corruption/loss/torn manifests under load.
- **Torn-write safety CONFIRMED** — `Sync::Commit.finalize` is one transaction; partial uploads are
  invisible (no corrupt state). `docs/torn-writes-and-batching.md`.
- **Postgres** validated (config-only via `DATABASE_URL`) **+ managed-hardened (G2)** — boot-time
  statement-pooler safety guard (`lib/postgres_pooler_check.rb`), `sslmode` defaulting
  (`config/database.yml`), and a real concurrency deadlock fix (`next_seq!` first in
  `Commit`/`Mutation`/`Restore`/`Conflicts`; `test/services/sync/concurrent_seq_test.rb`).
- **Storage-orphan chunk reaper (G4)** — `Sync::ChunkReaper` + `ChunkReaperJob` (weekly) +
  `ChunkStore#list` + `chunks.rake`: deletes object-storage bytes from never-finalized commits
  (no DB row → invisible to the refcount GC). Closes the leak in Parked follow-ups below.
- `STORAGE_BACKEND=local` added (a
  filesystem chunk store with HMAC-signed HTTP presigned URLs — for single-box testing/simple
  self-host; routes bytes through Rails, so NOT a production-scale path — s3/R2 stays that).

### Server + web (Rails)
- **Real auth (Rails 8 built-in)** — signup → email-confirm → login/logout → password reset, `Session`
  model (cookie + digest), OmniAuth seam (inert until configured). Replaced the web UI placeholder.
  Device-token + `DevicePairing` bootstrap untouched (auth sits in front). **Decision rationale +
  the OAuth-linking security constraint: `[[auth-decision]]` memory.**
- **Web UI MVP** (`client/maker-app` is the Tauri app; the *web* UI is server-rendered Rails) —
  file browser: upload (browser SHA-256 → presigned PUT → `Sync::Commit`), download, inline view
  (images/text), soft-delete. **Trash/undelete** view + restore. Bytes stay off Rails (presigned).
- **Security review** done on the new auth/web surface: 1 HIGH (OAuth account-takeover via unverified
  email-linking) **fixed**; session-fixation/cookies/tokens/CSRF/IDOR/blob-HMAC all sound. brakeman 0.
- Server suite **144/0**. Deployed via Kamal (Unraid VM `192.168.1.95`, SeaweedFS).

---

## ⛔ Blockers / known gaps

1. **Cross-OS 3-machine test — intermittent macOS→shared-server reachability risk.** The full
   `cross-os-e2e.yml` handoff PASSED (run 27579865391, all 6 legs green), so this is no longer a
   blocker — but the mac runner has *historically* sometimes failed to route to `192.168.1.95`. If a
   future cross-os run's mac legs BLOCK on server-unreachable, the fix is mac→server routing (or pass
   a reachable `server_url` to the workflow).
2. **FSKit (native macOS mount) — a DESIGN SKETCH, not built.** There is **no `client/fs-fskit`
   crate on `main`** — only the forward-looking sketch `docs/plan-macos-fskit-migration.md`
   ("no code lands from it"). An experimental port exists on the unmerged reference branch
   `worktree-agent-a1e15f52cc45cd0bf`. A first-party FSKit extension would additionally need a
   **paid Apple Developer membership ($99/yr)**. macOS uses WebDAV meanwhile (fully working).
   See `docs/roads-not-taken.md` §7. *(Earlier handoffs called this "code complete" — inaccurate
   for `main`; treat as unbuilt.)*
3. **macOS real-mount is interactive-runner-only** (native `mount_webdav` needs a desktop session).
   The mac runner must run interactively (Login Item / Aqua LaunchAgent), like the Windows CfAPI runner.
4. **`maker-app` (Tauri) isn't built by CI on Windows** — a `cargo check -p maker-app` Windows step
   would close it.
5. **The live CfAPI/mount nets don't gate per-PR** — `two-device-*`, `windows-smoke`, `cfapi-conformance`
   are nightly/on-demand (need interactive runners). Per-PR runs only build.
6. **Managed-Postgres — mostly hardened (G2), one item left.** TLS `sslmode`, the statement-pooler
   boot guard, the Solid-roles guidance, and the `next_seq!` concurrency deadlock are all **done**
   (G2). Remaining: stand up a real **session/transaction-mode pooler** endpoint (NOT statement —
   `FOR UPDATE` needs it) and run a concurrent-commit **load test** at scale; decide whether Solid
   Queue/Cache/Cable move off SQLite for managed.
7. **CfAPI pin/unpin + remove-library** need interactive-Explorer verification (code-complete).

### Parked follow-ups (small, non-blocking)
- **`ENAMETOOLONG` on `rmdir`/`unlink`** — an over-`NAME_MAX` name returns `ENOENT` not
  `ENAMETOOLONG` (create paths already enforce it). The one real conformance nit (PR #34).
- **`client/maker-app/src-tauri/Cargo.lock` stale** — missing already-declared `sync-client`/`sync-engine`
  deps; a `cargo update`-style refresh (flagged by the build-CI work, #32).
- **Distributable-build signing** — the cross-OS build CI (#32) produces *unsigned-but-runnable*
  artifacts; notarized/signed installers need paid Apple/Windows certs (wire into Tauri's secret seams).
- ~~**Orphaned-chunk reaper**~~ **DONE (G4, 2026-06-16)** — `Sync::ChunkReaper` + `ChunkReaperJob`
  (weekly) sweeps never-finalized-commit chunk bytes from object storage. `docs/torn-writes-and-batching.md` §5.
- ~~**Change-batching (debounce)**~~ **DONE (G5, 2026-06-16)** — an **opt-in (default-OFF)** outbox
  debounce for big CAD autosaves landed in `fs-provider`/`sync-engine`.
- ~~**Parallel/pipelined chunk hydration**~~ **DONE (PR #15, 2026-06-16)** — concurrent `io.get`/`io.put`
  across a bounded pool (`DaemonConfig::hydrate_concurrency`, default 8); ~8× on a synthetic-latency bench.
  The remaining cold-path lever is now a **concurrent/pipelined outbox drain across *files*** (a 10k-file
  push is ~113 s sequential — O(files) work, not an N+1; surfaced by G11). `docs/r2-migration.md` §5.
- **Windows `Get-FileHash` flake** — the CfAPI two-device edit-readback occasionally hits a file-sharing
  lock; add a read-retry in `two-device-cfapi.ps1`.
- **macOS multi-chunk hydrate timeout** — bumped to 300s; if it still flakes, investigate WebDAV
  hydration latency vs. the budget.

---

## ▶️ Next steps (rough priority)

1. **The maker app layer** (`CLAUDE.md` §12 step 9) — the actual product: **Projects → Inventory →
   BOM → preview**, referencing files by `node_id`. Separate Rails concern from sync. The file layer
   is ready (the gap doc confirms preview/inventory/BOM are *unbuilt product surface, not file-system
   limits*). **Suggested first slice: Projects** (exercises the file layer immediately). `image_processing`
   2.0 is in place for preview/thumbnails. Brainstorm scope before building (same Rails app vs separate;
   web vs Tauri surface).
2. **Parity roadmap** (`docs/parity-roadmap.md`, ordered): auth baseline ✅ done → **selective sync UI**
   (engine done, needs app surface) → trash UX ✅ → progressive hydration ✅ → bandwidth ✅ →
   **OAuth/OIDC layer** on the seam → **sharing/multi-user** (the big product fork) → **encryption (LAST,
   deliberately — keeps the other features debuggable against plaintext)**.
3. **R2 migration** — **validated live** (2026-06-15): presigned roundtrip OK + per-chunk hydrate
   latency measured (~85–205 ms; `docs/r2-migration.md` §5). Remaining for production cutover: the
   browser-CORS check against R2 (only a real browser catches a CORS mistake), the SeaweedFS→R2
   `rclone copy` migration + `kamal deploy` (push-button tooling now in `scripts/r2-cutover/`, PR #17).
   `CHUNK_REGION=auto` for R2. (Parallel hydration for large cold files already merged — PR #15.)
4. **CI hardening** — `cargo check -p maker-app` on Windows; make the mac/Windows runners durably
   interactive (auto-login) so the real-mount nets run reliably.
5. **FSKit** — currently only a design sketch (not built; see blocker 2). Build the `fs-fskit`
   crate (parallels `fs-fuse`, not `fs-cfapi`) when a paid Apple membership is available;
   `docs/plan-macos-fskit-migration.md` is the forward-looking design.

---

## Working notes for the next agent
- **Self-hosted CI is the only way to verify real mounts** (mac/Windows need interactive sessions;
  `fuser` only links on Linux). The Mac dev box CANNOT build `fuser`/fs-fuse. Trigger nightly /
  `cross-os-e2e.yml` / `rust-client.yml -f target=...` and read JOB LOGS (jobs are `continue-on-error`
  and leg scripts `exit 0` on BLOCKED — the green checkmark can hide a skipped test).
- **`nightly.yml`** has the heavy/real-mount jobs; concurrency is keyed on `event_name` so a manual
  dispatch and the cron don't cancel each other.
- **Run the app / demos**: `CLAUDE.md` §13 cheatsheet. Server: `STORAGE_BACKEND=memory bin/rails server`.
- **Regression nets** to keep green: server `bin/rails test` (144), `fs-provider` hermetic suites,
  `sync-engine` `integration`/`two_device_e2e`/`fault_injection`/`concurrency_load`/
  `multifiletype_conformance`, the FUSE smoke examples.

## Branch map
| Branch | What | State |
|---|---|---|
| `main` | Mainline — all work merged (HEAD `bab90bb`) | pushed, current |
| `worktree-agent-a1e15f52cc45cd0bf` | Canonical FSKit port (code + findings) | reference |
| `fskit-signing-personal-team` | FSKit signing-experiment findings | reference |
| `ui-rework` | OLD divergent UI reimpl — superseded; reference only | reference |
| `auth-caching-security`, `sync-engine-foundation`, `mac-webdav-mount`, `client-juicefs-mount-spike` | historical | — |

(All this-session feature/fix branches were merged to `main` and pruned.)

## Key docs
- `docs/STATUS.md` — detailed running status. `CLAUDE.md` — architecture (+ §12 plan).
- `docs/parity-roadmap.md` — sequenced roadmap (auth/encryption/sharing/etc.).
- `docs/research-sync-competitors.md` — vs Dropbox/Drive/Nextcloud/oCIS/Seafile/Syncthing + gaps.
- `docs/feature-set-and-workflows.md` — supported vs gap workflows (FILE-LAYER vs MAKER-APP).
- `docs/torn-writes-and-batching.md` — commit atomicity (we're safe) + batching analysis.
- `docs/r2-migration.md` — R2 migration plan + latency harness.
- `docs/plan-windows-cfapi-migration.md` — CfAPI design + remaining B6 verification.
- `docs/plan-macos-fskit-migration.md` — FSKit forward-looking sketch (NOT built; no `client/fs-fskit` crate on `main`).
- `docs/roads-not-taken.md` — condensed abandoned/superseded approaches (mount, JuiceFS, Cloudflare-native, WinFsp-default, LWW, FSKit).
- `docs/DEPLOY.md` — Kamal redeploy. `ci/runners/README.md` — self-hosted runners (interactive + /dev/fuse).
