# Handoff — state as of 2026-06-15

Snapshot for the next agent/developer. **Everything lives on `main`** (HEAD `bab90bb`, pushed).
Detailed running log: `docs/STATUS.md`. Architecture: `CLAUDE.md`. Strategy: `docs/parity-roadmap.md`,
`docs/research-sync-competitors.md`, `docs/feature-set-and-workflows.md`. This file = "where are we,
what's blocked, what's next." Persistent memory also holds key decisions/gotchas (see the project
memory: auth decision, sync ordering bugs, CfAPI receive-side, Linux FUSE mount).

---

## TL;DR

The **file/sync layer is rock-solid and now has automated real-mount end-to-end on all three OSes.**
A web UI MVP + real auth landed. The product layer (the maker app: projects/inventory/BOM/preview)
is the next big arc and the file foundation is ready for it. A long cross-OS debugging saga this
session surfaced + fixed real bugs on actual hardware (3 Windows CfAPI receive-side bugs, a daemon
self-unmount, a stale FUSE dependency).

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
- **Postgres** validated (config-only via `DATABASE_URL`, 56/0). `STORAGE_BACKEND=local` added (a
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
2. **FSKit (native macOS mount) — blocked on a PAID Apple Developer membership ($99/yr).** Code
   complete; macOS uses WebDAV meanwhile (fully working). `client/fs-fskit/BUILD.md` §6b.
3. **macOS real-mount is interactive-runner-only** (native `mount_webdav` needs a desktop session).
   The mac runner must run interactively (Login Item / Aqua LaunchAgent), like the Windows CfAPI runner.
4. **`maker-app` (Tauri) isn't built by CI on Windows** — a `cargo check -p maker-app` Windows step
   would close it.
5. **The live CfAPI/mount nets don't gate per-PR** — `two-device-*`, `windows-smoke`, `cfapi-conformance`
   are nightly/on-demand (need interactive runners). Per-PR runs only build.
6. **Managed-Postgres specifics unproven** — TLS sslmode, session/transaction pooler (NOT statement —
   `FOR UPDATE`), concurrent-commit load test, whether Solid Queue/Cache/Cable move off SQLite.
7. **CfAPI pin/unpin + remove-library** need interactive-Explorer verification (code-complete).

### Parked follow-ups (small, non-blocking)
- **Orphaned-chunk reaper** — chunks from a never-finalized commit leak (no DB row → GC can't see them).
  Matters for managed R2 cost. (A task chip was filed; `docs/torn-writes-and-batching.md` §4.)
- **Windows `Get-FileHash` flake** — the CfAPI two-device edit-readback occasionally hits a file-sharing
  lock; add a read-retry in `two-device-cfapi.ps1`.
- **macOS multi-chunk hydrate timeout** — bumped to 300s; if it still flakes, investigate WebDAV
  hydration latency vs. the budget.
- **Change-batching (debounce)** — optional 2–3s outbox debounce for big CAD autosaves (research §3).

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
3. **R2 migration** — `docs/r2-migration.md` is a config-only plan + a latency harness
   (`examples/chunk_latency.rs`); needs Cloudflare creds for the 3 live checks (presigned roundtrip,
   latency numbers, browser CORS). Flip `CHUNK_REGION` to `auto` for R2.
4. **CI hardening** — `cargo check -p maker-app` on Windows; make the mac/Windows runners durably
   interactive (auto-login) so the real-mount nets run reliably.
5. **FSKit** — finish when a paid Apple membership is available.

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
- `docs/plan-macos-fskit-migration.md` + `client/fs-fskit/BUILD.md` §6b — FSKit + paid-membership blocker.
- `docs/DEPLOY.md` — Kamal redeploy. `ci/runners/README.md` — self-hosted runners (interactive + /dev/fuse).
