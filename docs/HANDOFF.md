# Handoff — state as of 2026-06-14

Snapshot for the next agent/developer. Branch: **`auth-caching-security`** (HEAD `a9844bc`,
synced with origin). Detailed history lives in `docs/STATUS.md`, the plan docs, and the
findings docs referenced below. This file is the "where are we, what's blocked, what's next."

---

## ✅ Confirmed working (verified live / tested, not just compiled)

### Windows CfAPI — the headline: complete + the DEFAULT Windows backend
- Full read+write path **proven live** on a real Windows 11 box against the **deployed** server:
  register sync root → enumerate (`FETCH_PLACEHOLDERS`) → hydrate (`FETCH_DATA`) → **new-file
  capture** (B1, `ReadDirectoryChangesW` watcher) → **edit** → **delete** (B2) → **rename** (B3).
- **`windows-smoke` GREEN** (run 27505819156): all 7 checks incl. delete + rename-old-name-gone.
- **`cfapi-conformance` GREEN** (run 27505875085): 24 files, nested dirs, varied/multi-chunk sizes,
  create/edit/delete/rename churn, **byte-for-byte on a fresh device**.
- **CfAPI is now the DEFAULT Windows backend** (`maker-app` Mount alias flipped, B5). WinFsp stays
  behind the `winfsp-backend` cargo feature for one release.
- Key fix this session: the shutdown drain is now **idle-based** (a slow push can't eat the budget),
  so CfAPI's batched-at-unmount delete/rename callbacks always push. See
  `docs/cfapi-write-path-findings.md`.

### Server
- **Deployed via Kamal** on the Unraid VM (`kamal1@192.168.1.95`, SeaweedFS chunks), `/up` → 200,
  running the rev with the **same-device-conflict fix** (a stale base from the *same* device
  fast-forwards instead of falsely conflicting; cross-device conflicts still detected — no LWW
  regression). **56 server tests green.** Redeploy = rsync the clean tree + `~/kamalw deploy`
  (`docs/DEPLOY.md`); I have SSH/Docker access and verified the loop.

### Cross-OS mount + sync (from the prior arc, still green)
- **macOS = WebDAV** (`fs-webdav`, native `mount_webdav`) — the default + only viable macOS backend.
- **Linux = FUSE** (`fs-fuse`).
- **Windows = CfAPI** (now default; WinFsp behind feature).
- Hermetic suites green: `fs-provider` (~50), `fs-cfapi` (15), `sync-client`, sync-engine
  integration (server-backed).

### Self-hosted CI (migrated off GitHub-hosted)
- Three self-hosted runners online: **macOS, Linux, Windows** (all native, no VMs). Windows runs
  **interactive** (auto-login + a logon scheduled task) so CfAPI can mount.
- `rust-client.yml` = **fast per-PR gate**: `mac-tests` (all hermetic tests + windows-gnu
  cross-check + native build), `linux-build`, `engine-integration`, and **per-component path-gating**
  (a change only runs its relevant jobs). `windows-build` runs when Windows-affecting code changes.
- `workflow_dispatch` **`target`** input for single-slice runs:
  `gh workflow run rust-client.yml --ref <branch> -f target=cfapi|cfapi-conf|mac|linux|engine|all`.
- Warm caches (`clean: false`), concurrency guard, native git-diff gating (no API perms).
- `nightly.yml` = heavy/cross-platform (fsx/pjdfstest conformance + a Windows backstop).

---

## ⛔ Blockers

1. **FSKit (native macOS mount) — blocked on a PAID Apple Developer membership.** The code is
   complete and was **proven live** (in a SIP/AMFI-off Tart VM) to register, launch, and pass the
   FSKit delegate handshake. But the extension **exits before vending its XPC endpoint** (no mount)
   under ad-hoc, self-signed, AND the free "Apple Development" cert — while FUSE-T's **paid**-team
   module mounts on the same VM. macOS-26 extension *residency* is gated to a paid FSKit
   provisioning profile; AMFI-off does not bypass it. **No $0 path exists.** Code on branch
   `worktree-agent-a1e15f52cc45cd0bf`; full evidence in `client/fs-fskit/BUILD.md` §6b. To finish:
   enroll ($99/yr) → App ID + FSKit capability → profile → sign + notarize → mount → parity.

2. **`ui-rework` branch is not mergeable as-is.** It's a **divergent re-implementation** of the
   maker-app UI built on a stale base that predates the feature commits (`c68a406` file browser,
   `07c730c` conflict UI, `8aac676` locks) — it conflicts on `index.html` and a naive merge would
   clobber the current, working feature UI. Salvage the `styles.css` baseline + `docs/ui-audit.md`;
   **redo** the polish against the current `index.html`. Pushed to origin as `ui-rework` (reference).

3. **The live CfAPI net doesn't gate per-PR.** `windows-smoke` + `cfapi-conformance` are
   `continue-on-error` + on-demand (they need the interactive Windows session). So a per-PR `main`/PR
   run only exercises the *build* matrix — the live write path could regress without failing a gate.
   Run `target=cfapi`/`cfapi-conf` (or nightly) to actually exercise it.

4. **`maker-app` is not built by CI on Windows.** The B5 default-flip is verified by interface
   parity + host `cargo check` + the sync-engine `windows-build` job, but no CI compiles the Tauri
   *app* on Windows. Pre-existing gap; a `cargo check -p maker-app` Windows step would close it.

---

## ▶️ Next steps (rough priority)

1. **Decide `auth-caching-security` → `main`.** Big branch; downsides documented in chat/this
   session (self-hosted CI becomes the default-branch dependency; 5 open Dependabot PRs would run on
   your runners; no human review of a large diff; live net doesn't gate). Lowest-risk: open a PR,
   ensure fork-PR workflow approval is on, decide squash-vs-merge.
2. **Real OAuth/OIDC email verification** (CLAUDE.md §12 step 5) — the device-token + pairing
   mechanism stays underneath; this proves email ownership at bootstrap.
3. **Postgres deploy validation** (§12 step 8) — code is adapter-agnostic, tested on SQLite; the
   switch is config (`docs/SYNC_SERVER.md`).
4. **CfAPI B6 polish** (`docs/plan-windows-cfapi-migration.md` §4): pin/unpin ↔ hydrate/dehydrate,
   real "remove library" lifecycle (`CfUnregisterSyncRoot`), large-file streamed `FETCH_DATA`,
   ino→path index.
5. **Maker app layer** (§12 step 9): projects / inventory / BOM / preview — references files by
   `node_id`. Groundwork (file browser + version/restore + conflict + lock UI) already on the branch.
6. **UI**: redo the polish against the current branch (use `ui-rework` + `docs/ui-audit.md` as the
   reference, not a merge).
7. **FSKit**: when a paid Apple membership is available, finish signing/notarizing → mount → prove
   WebDAV parity (the code is ready).
8. **CI hardening** (optional): `cargo check -p maker-app` on Windows; fork-PR Actions approval.

---

## Branch map (what's preserved where)

| Branch | What | State |
|---|---|---|
| `auth-caching-security` | Mainline of all this work (HEAD `a9844bc`) | pushed, current |
| `ui-rework` | UI rework — divergent reimpl, **don't merge**; reference only | pushed |
| `worktree-agent-a1e15f52cc45cd0bf` | Canonical FSKit port (code + full findings) | pushed |
| `fskit-signing-personal-team` | FSKit signing-experiment findings (unique commits) | pushed |
| `main`, `sync-engine-foundation`, `mac-webdav-mount`, `client-juicefs-mount-spike` | pre-existing | — |

## Key docs
- `docs/STATUS.md` — detailed running status. `CLAUDE.md` — architecture (updated: CfAPI is default Windows).
- `docs/cfapi-write-path-findings.md` — CfAPI write-path root causes + fixes.
- `docs/plan-windows-cfapi-migration.md` — CfAPI design + remaining B6 polish.
- `docs/plan-macos-fskit-migration.md` + `client/fs-fskit/BUILD.md` §6b — FSKit design + the paid-membership blocker evidence.
- `ci/runners/README.md` — self-hosted runner setup (incl. the interactive-Windows requirement).
- `docs/DEPLOY.md` — Kamal redeploy procedure.
