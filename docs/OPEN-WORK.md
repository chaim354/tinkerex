# Open work — what still must be done (2026-07-30)

**Baseline:** `main` at `5051404`. Suite 1690 runs / 0 failures on all three FileLayer legs.

**How this list was built, and why that matters.** Every item was **checked against the code or
the live API**, not copied from another document. This repo has already been bitten by the
alternative: `docs/STATUS.md`'s own open-list once carried two items that had been fixed by a
review in the same branch and never retracted, and its verdict is worth restating —

> A stale open-list is worse than no open-list — it spends the next reader's attention on work
> that is already done.

Where a claim comes from a doc rather than from verification, it says so. Where verification
contradicted a doc, the contradiction is recorded rather than quietly corrected.

**One correction found while building this list.** My own memory note claimed force-SSL was
"env-gated" and live. It is not — nothing in the repo enables `force_ssl` or `assume_ssl`. See
audit S1.

---

## Legend

| | |
|---|---|
| **Blocking** | Something is wrong or exposed now. |
| **Next** | Nothing is broken, but this is the next real increment. |
| **Backlog** | Wanted, scoped, not urgent. |
| **Decision** | Waiting on a product/owner call, not on engineering. |

Sizes are rough: **S** ≈ under a day, **M** ≈ a few days, **L** ≈ a week or more.

---

## 1. From this audit

Full evidence in `docs/AUDIT-2026-07-30.md`; the fix sequence is
`docs/superpowers/plans/2026-07-30-audit-fixes-plan.md`.

| # | Item | Class | Size |
|---|---|---|---|
| S1 | Enable `force_ssl` + `assume_ssl`, **env-gated** so the plain-HTTP LAN deploys survive | Blocking | S |
| S9 | Switch on Solid Cache (`config.cache_store`) — provisioned, never wired; also a precondition for S3 | Blocking | S |
| S3 | Rate-limit login / password-reset / confirmation-resend / signup. **Do after S9** | Blocking | S |
| S2 | `config.paranoid = true` — closes user enumeration; changes flow copy, so tests move with it | Blocking | S |
| S10 | Require the current password to delete an account (today one request destroys everything) | Blocking | S |
| P1 | `projects#show` N+1: add `:rich_text_body` to the eager load | Blocking | S |
| T3 | Query-count guards on the main web pages — the class of test that would have caught P1 | Next | S |
| T1 | Tests for the 13 unexercised web actions (account deletion and update first) | Next | M |
| T2 | Cross-user authorization test per mutating web action | Next | M |
| S7 | Raise the password floor from 6 to 10–12; consider a breached-password check | Next | S |
| S4 | Content-Security-Policy — report-only first, then enforce | Next | S |
| S6 | Unique index on `maker_file_attachments`; needs a dedupe pass in the migration | Backlog | S |
| P2 | Collapse the four redundant `Node Load`s on `projects#show` | Backlog | S |
| S5 | Upload size cap + per-user quota — **needs a number from you**, and a wrong one rejects real CAD files | Decision | M |
| P3 | Pagination for the `files#index` folder view — carried, a file-browser decision on its own merits | Decision | M |

---

## 2. Infrastructure and CI

### 2.1 Linux and Windows CI coverage is skipped, not passing — Blocking, S

**Verified against the live API, not the doc:**

```
gh api repos/:owner/:repo/actions/runners --jq '.runners[] | "\(.name)  \(.os)  \(.status)"'
charless-MacBook-Pro-maker-mac  macOS  online
```

One runner. `flasher-maker-linux` and `CHAIMDESK-maker-windows` are **not registered**, so every
Linux and Windows job is `if:`-gated off by `ci/preflight.sh` reading the `CI_RUNNERS` repo
variable. The gate itself is correct and is the fix for a five-week outage — a job matching no
online runner does not fail, it queues 24 h at zero elapsed and is auto-cancelled, which is how
a PR sat UNSTABLE and needed `--admin` to merge.

**The consequence to keep in view: that coverage is not running.** Not running today — the FUSE
mount adapter, the CfAPI adapter, the two-device real-mount E2E on Linux and Windows, and the
external conformance suites (rclone/fsx/pjdfstest). The server suite runs on macOS and is fine.

**To restore:** register the two runners, then add them to `CI_RUNNERS`. Note `gh api …/runners`
needs an **admin-scoped** token — `administration` is not a permission a workflow `GITHUB_TOKEN`
can hold, so it 403s from inside Actions and only works from a developer shell.

### 2.2 The unexplained intermittent — Backlog, S

A single `SQLite3::BusyException` in `Tools::GeneratorsControllerTest#setup`, **captured
2026-07-27** after two agents each saw one unreproducible `1 errors` run without capturing the
message. Still unexplained. The cross-worker explanation offered with the capture is
**disproved** — each parallel worker gets its own SQLite file (`storage/test.sqlite3_0…_9`), so
the lock holder is inside the failing worker. Full record in `docs/STATUS.md`, "The
intermittent". Did not reproduce in this audit's runs.

### 2.3 Managed-Postgres load test at scale — Backlog, M

From `CLAUDE.md` §12 step 8: the adapter-agnostic server is green on Postgres and the
statement-pooler boot guard is in place, but a real managed deploy still wants a
session/transaction-mode pooler endpoint chosen and a **concurrent-commit load test at scale**.
Solid Queue/Cache/Cable are still on SQLite in the current deployment.

---

## 3. Product surfaces with no web UI

The maker layer's web UI covers projects, the model library, files, previews, sheets, notes, and
the `/tools` addons. From `CLAUDE.md` §3 and §12 step 9, these models exist server-side with a
v1 API and **no web surface at all**:

| Surface | Class | Size |
|---|---|---|
| **Inventory** — items, quantities, locations, suppliers | Next | L |
| **BOM** — the project↔inventory link, the reason inventory exists | Next | M |
| Collections, tags/taggings as first-class browse surfaces | Backlog | M |
| Selective-sync UI — engine and provider APIs exist, app wiring is the gap (`docs/plan-selective-sync-ui.md`) | Backlog | M |

Inventory + BOM are the largest genuine product gap. `CLAUDE.md` §1 names files, inventory and
projects as the three pillars; two of three have a web UI.

---

## 4. Auth

### 4.1 Real OAuth/OIDC email verification — Next, M

`CLAUDE.md` §12 step 5, **partly done**. Closed: the account-takeover hole (`register` is
new-account-only), device pairing via single-use expiring codes, and Rails 8 built-in auth
(signup/confirm/login/reset) with an OmniAuth seam. Open: real OAuth/OIDC so the bootstrap
**proves email ownership**. The device-token + pairing mechanism stays underneath either way.
Research: `docs/research-auth-providers.md`.

Audit items S2, S3 and S7 all live on this surface and are much cheaper — do them first
regardless of when OIDC lands.

---

## 5. File layer — remaining items, all non-correctness

| Item | Class | Size | Note |
|---|---|---|---|
| **At-rest chunk encryption** | Backlog | L | Deliberately last. `docs/plan-encryption.md` |
| **Full read/write sharing** (Spaces, per-Space keyspace) | Backlog | L | `ShareLink` today is a read-only, single-version capability token — a deliberately shallow slice. `docs/plan-sharing.md` |
| Server-side sync of **symlinks** | Backlog | M | `fs-provider` models them; the Rails server does not |
| `copy_object` 5 GB cap + its error class | Backlog | S | Unverifiable without staging 5 GB; the guard deliberately depends on no class name and refuses from `node.size` |
| R2 / MinIO / Ceph specifics | Backlog | M | Only SeaweedFS was exercised live; AWS may be stricter where SeaweedFS is lenient |
| §9a-3 / §9a-4 (deferred Phase-1 review items) | Backlog | S | Phase 4 explicitly did not force these |

---

## 6. Client / mount

| Item | Class | Size |
|---|---|---|
| macOS **FSKit** adapter — design sketch only, no `client/fs-fskit` crate; also needs a paid Apple Developer membership | Backlog | L |
| Windows **File-Provider** API (post-CfAPI polish) | Backlog | L |
| Remove `fs-winfsp` once CfAPI has shipped a release as default (it is behind the `winfsp-backend` feature for one release) | Backlog | S |
| FUSE-T deferred `release` — flush-on-close is not synchronous | Backlog | S |
| `Sync::Changes` N+1 preloading | Backlog | S |

---

## 7. Known drift to correct

Small, but each one costs the next reader real time.

| Item | Size |
|---|---|
| `CLAUDE.md` §4 claims the stack is "Solid Queue/Cache/Cable" — **Cache is not in effect** (audit S9). Correct it with the fix. | S |
| A third copy of the file-type vocabulary lives in `importer_controller.js`'s `roleFor` and has drifted from `ROLE_BY_EXT`. Browser-only and the server re-derives authoritatively, so nothing is broken — but it is a live second source of truth. | S |
| `docs/STATUS.md`'s suite-count entries **do not form a chain** and cannot be used as a baseline. Take a baseline by running the merge-base. Worth a one-line warning at the top of the file. | S |
| `maker_file_attachments` uniqueness (audit S6) is noted in STATUS as open and is still open. | S |

---

## 8. Backlog with its own document

Not restated here; these are already scoped elsewhere and none is blocking.

- **`/tools` addon ideas** — `docs/addon-backlog.md`, ~48 entries, grouped by shared engine with
  a five-phase build order. The CNC/MillMage gap is the notable hole.
- **Themes** — `docs/plan-maker-themes.md` (plan only, marked do-not-implement-yet).
- **Onboarding / first-run** — `docs/plan-onboarding.md` (plan/research, no code).
- **Maker-lite** — `docs/plan-maker-lite.md` (plan, no code).
- **Parity roadmap** vs Dropbox/Seafile/Syncthing — `docs/parity-roadmap.md`,
  `docs/research-sync-competitors.md`.

---

## The short answer

If you only do one block: **§1's five Blocking items plus §2.1.** Four are one-line config
changes, one is a one-line eager-load, and together they close every exposure this audit found
that is exposed *now*. Everything else in this document is either a product decision, a
deliberate deferral, or work that is genuinely large.
