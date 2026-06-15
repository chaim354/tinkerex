# Handoff — state as of 2026-06-14 (end of hardening session)

Snapshot for the next agent/developer. **Everything now lives on `main`** (HEAD `2e9df94`,
pushed). The long-lived `auth-caching-security` branch was squash-merged (PR #8); `main` is the
mainline. Detailed running log: `docs/STATUS.md`. Architecture: `CLAUDE.md`. This file is the
"where are we, what's blocked, what's next."

---

## ✅ Confirmed working (verified live / tested, not just compiled)

### The file layer is "rock-solid" — hardened + adversarially tested this session
- **`auth-caching-security` merged to `main`** (squash PR #8); the 3 Dependabot Actions bumps
  (#2/#3/#4) merged; `scan_ruby` fixed (brakeman 8.0.5).
- **Postgres validated** — server runs green on PG (56/0); config-only switch via `DATABASE_URL`.
- **GC/retention wired** — tiered policy + nightly `RetentionJob` + real S3 `delete_object`
  (current + `pinned` versions never pruned). Closes unbounded-storage growth.
- **CfAPI B6 polish** — pin/unpin↔hydrate, `CfUnregisterSyncRoot` lifecycle, streamed
  page-aligned `FETCH_DATA`, O(1) ino→path index. Windows CI green. (pin/unpin + remove-library
  are code-complete; need interactive-Explorer verification — see plan §4.)
- **Two-device E2E suite** (`client/sync-engine/tests/two_device_e2e.rs`, 9 tests) — the
  A→write→B→pull→edit→A→pull byte-for-byte roundtrip + delete/rename/dedup/restore/conflict/
  lock/offline. Per-OS CI jobs (`e2e-linux`/`e2e-macos`/`e2e-windows`) green.
- **Adversarial fault-injection harness** (`client/sync-engine/tests/fault_injection.rs`) —
  "Trinity": injected I/O faults, mid-op crashes, randomized interleaving, concurrent edits;
  asserts no-loss/convergence/idempotency; seeded, soak 1000×200.
- **Two real bugs found by the harness + fixed** (`ce72f25`): (1) child-before-parent outbox
  drain → `outbox_list_topo()`; (2) a pull hard-deleting a locally-renamed-but-unpushed node
  (silent convergence loss) → defer-and-retry + sticky `needs_resync`→`pull_snapshot` floor.
  Soak: **0 silent losses**. All suites green (fs-provider, integration 19/0, e2e 9/0, harness 10/0).
- **UI polish** (`client/maker-app`) — accessible states, closable conflict modal, restore
  confirm, pairing copy, per-OS backend label. Redone against current `index.html` (NOT a
  `ui-rework` merge); builds clean.
- **Loose ends cleared** — pairing codes from `SecureRandom`; `image_processing`→2.0.2;
  deterministic GC tests (frozen clock + `sweep_orphans!` `<=` so grace:0 = sweep-now).
  **Server suite 75/0.**
- **New strategy docs** — `docs/research-sync-competitors.md`, `docs/feature-set-and-workflows.md`.

### From the prior arcs (still green)
- **Server deployed via Kamal** (Unraid VM `192.168.1.95`, SeaweedFS chunks); `/up` 200.
- **Cross-OS mount + sync**: macOS WebDAV, Linux FUSE, Windows CfAPI (default). Conformance
  clean ×3 OS (fsx 100k/0, rclone byte-perfect, CfAPI byte-for-byte).
- **Self-hosted CI** (macOS/Linux/Windows runners; Windows interactive for CfAPI).

---

## ⛔ Blockers / known gaps

1. **FSKit (native macOS mount) — blocked on a PAID Apple Developer membership ($99/yr).** Code
   complete + proven to pass the FSKit delegate handshake, but the extension can't gain residency
   without a paid FSKit provisioning profile. No $0 path. Code on `worktree-agent-a1e15f52cc45cd0bf`;
   evidence in `client/fs-fskit/BUILD.md` §6b. macOS uses WebDAV meanwhile (fully working).
2. **The live CfAPI net doesn't gate per-PR.** `windows-smoke`/`cfapi-conformance` are
   `continue-on-error` + on-demand (need the interactive Windows session). Run `target=cfapi`/
   `cfapi-conf` or nightly to exercise the live write path; a per-PR run only builds it.
3. **`maker-app` (Tauri) isn't built by CI on Windows.** A `cargo check -p maker-app` Windows
   step would close it.
4. **CfAPI pin/unpin + remove-library need interactive-Explorer verification** (code-complete).
5. **Postgres: managed-deploy specifics unproven** — TLS sslmode, pooler in session/transaction
   mode (not statement — `FOR UPDATE`), concurrent-commit load test, Solid Queue/Cache/Cable
   still on SQLite. Local validation is done.

---

## ▶️ Next steps (rough priority)

1. **Real OAuth/OIDC email verification** (CLAUDE.md §12 step 5) — pairing + device-token stays
   underneath; proves email ownership at bootstrap.
2. **Maker app layer** (§12 step 9) — projects / inventory / BOM / preview, referencing files by
   `node_id`. The file layer is ready; the gap doc confirms preview/inventory/BOM are *unbuilt
   product surface, not file-system limits*. Suggested first slice: **Projects** (uses the file
   layer immediately). `image_processing` 2.0 is in place for preview/thumbnails.
3. **Open file-layer items (optional, non-correctness)** — **selective sync** (research #2) and
   **at-rest chunk encryption** (#3). Both fit the chunk/manifest/changelog model; they shape the
   maker/SaaS story but don't block building on top.
4. **CI hardening** — `cargo check -p maker-app` on Windows; consider a gating live-CfAPI path.
5. **FSKit** — finish when a paid Apple membership is available (code ready).

---

## Branch map

| Branch | What | State |
|---|---|---|
| `main` | Mainline — all work merged (HEAD `2e9df94`) | pushed, current |
| `worktree-agent-a1e15f52cc45cd0bf` | Canonical FSKit port (code + findings) | pushed, reference |
| `fskit-signing-personal-team` | FSKit signing-experiment findings | pushed, reference |
| `ui-rework` | OLD divergent UI reimpl — **superseded** by the merged UI polish; reference only | pushed |
| `auth-caching-security`, `sync-engine-foundation`, `mac-webdav-mount`, `client-juicefs-mount-spike` | historical | — |

## Key docs
- `docs/STATUS.md` — detailed running status. `CLAUDE.md` — architecture.
- `docs/research-sync-competitors.md` — competitor comparison + ranked gaps.
- `docs/feature-set-and-workflows.md` — supported vs gap workflows.
- `docs/plan-windows-cfapi-migration.md` — CfAPI design + remaining B6 verification.
- `docs/plan-macos-fskit-migration.md` + `client/fs-fskit/BUILD.md` §6b — FSKit + paid-membership blocker.
- `docs/DEPLOY.md` — Kamal redeploy. `ci/runners/README.md` — self-hosted runners.
