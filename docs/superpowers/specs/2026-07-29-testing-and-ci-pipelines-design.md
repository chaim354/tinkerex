# Fix the testing & CI pipelines — design

**Status:** approved, not yet implemented
**Date:** 2026-07-29
**Supersedes:** `docs/STATUS.md` § *"CI cannot run — no Linux runner is registered (2026-07-29)"*,
which recorded the diagnosis and explicitly deferred the fix ("assigned elsewhere: a separate agent
owns fixing CI + testing infrastructure"). This is that work.
**Touches:** `.github/workflows/*.yml`, a new `bin/ci`, `test/system/**`, `ci/runners/README.md`,
CLAUDE.md §15, `docs/STATUS.md`.

---

## 1. Goal & scope

Two failures that read as one problem and are not:

- **P1 — the pipeline is dark.** CI has had **zero successful runs since 2026-06-24** (five weeks).
  Root cause is a runner/label mismatch. The *reason nobody noticed* is a second, separate bug: a
  job whose labels match no online runner **queues silently for 24 h and is then auto-cancelled**,
  so the outage never produced a red signal.
- **P2 — the browser tier does not exist.** 1,035 lines of Stimulus across 13 controllers, plus 67
  ERB views, are gated by **6 system-test examples in 2 files** — and all three controllers with any
  browser coverage got it only *after* a bug shipped.

**The code is green.** Everything below was measured on the maker-mac box on 2026-07-29, not
inferred:

| Gate | Result |
|---|---|
| `bin/rails test` | 1628 runs / 5678 assertions / **0F 0E** / 11 skips, 5.2 s |
| `LIBRARY_BACKEND=share` | identical 1628 / **0F 0E** |
| `LIBRARY_BACKEND=s3` | identical 1628 / **0F 0E** |
| `bin/rails test:system` | 6 runs / 28 assertions / **0F 0E** (headless Chrome) |
| `bin/rubocop` | 435 files, no offenses |
| `bin/brakeman` / `bin/bundler-audit` / `bin/importmap audit` | exit **0 / 0 / 0** |

**In scope:** retargeting workflows at the runner that exists; a preflight that makes a missing
runner *fail fast instead of queueing*; `bin/ci` as the single local gate; and building
`test/system` into a real tier with a written policy and a risk-ordered coverage list.

**Out of scope** — see §8 for each with its reason: no JS unit-test toolchain, the SQLite
`BusyException` intermittent, the `importer_controller.js` third role table, Windows runner
re-registration, and (deliberately) registering the Linux runner itself.

**CLAUDE.md §15 tripwire:** **no `*-latest` runner may appear in any workflow.** GitHub bills only
hosted runners; self-hosted are free. Every `runs-on` in this design stays `[self-hosted, …]`.

---

## 2. The measured diagnosis

### 2.1 One runner exists, and nothing points at it

`gh api repos/:owner/:repo/actions/runners` → `total_count: 1`:

| Name | OS | Labels | Status |
|---|---|---|---|
| `charless-MacBook-Pro-maker-mac` | macOS / ARM64 | `self-hosted`, `macOS`, `ARM64`, `maker-mac` | **online, idle** |

`flasher-maker-linux` and `CHAIMDESK-maker-windows` are **not registered**. All 7 `ci.yml` jobs
declare `runs-on: [self-hosted, linux]`. So the one healthy runner sits idle while every job queues.

Hardware probed 2026-07-29: **`flasher` does not respond** (off or gone). **`CHAIMDESK` is UP** on
the LAN but unregistered. **Unraid `192.168.1.95` is UP with SSH open** (deploy user `kamal1`, a
Docker host) — a viable Linux runner home.

### 2.2 The blast radius, from the run history

Last 300 runs, by workflow:

| Workflow | success | cancelled | queued | Last success |
|---|---|---|---|---|
| CI | 10 | 106 | 8 | **2026-06-24** |
| Rust client | 4 | 60 | 1 | **2026-06-24** |
| Cross-OS E2E | 7 | 33 | 1 | **2026-06-25** |
| Nightly | 5 | 27 | 1 | **2026-06-25** |

11 runs are queued right now, including **4 Dependabot PRs** and the daily `nightly` (08:00 UTC) and
`cross-OS` (08:30 UTC) schedules, which fire into the void and are cancelled 24 h later.

### 2.3 Queuing rather than failing is a SEPARATE bug from the missing runner

Fixing the runner topology alone leaves this in place, and it is what turned a one-day outage into a
five-week one. A label set with no online runner produces **no failure** — the job is pending at
**0 elapsed**, `mergeStateStatus` stays UNSTABLE, `gh pr merge` refuses, and the merge happens with
`--admin` (PR #94 did exactly this). **`timeout-minutes` does not help:** it starts counting when a
job *starts*, not when it is queued. There is no queue timeout to set. The only fix is to not
schedule the job at all — hence §4.3.

### 2.4 A Linux-only *gate* job blocks work the Mac could do today

`rust-client.yml`'s `changes` job is `runs-on: [self-hosted, linux]`, and **every other job in that
workflow `needs: changes`** — including `mac-tests`, which targets the online Mac runner. So the
entire Rust workflow is dark even though its largest job could run right now. `cross-os-e2e.yml` has
the same shape: `seed` on linux, every leg `needs: seed`.

Neither gate job has a real Linux dependency. `changes` is `git diff` + bash. `seed` is `curl` +
`cargo run --example pair_three_devices`.

### 2.5 Three CI edits have never executed once

The last green CI run (2026-06-24) predates every subsequent change to `ci.yml` — **three additions
across two commits**:

| Change | Landed | Commit |
|---|---|---|
| the `test-share-backend` job | 2026-07-16 | `63544ee` |
| the `test-s3-backend` job | 2026-07-16 | `63544ee` |
| the `resvg` install step (in 3 jobs) | 2026-07-20 | `e1864e5` |

They are unverified YAML. The first run after this fix is also their first execution — expect to
debug them, and do not read a failure there as a regression this design introduced.

---

## 3. Two feasibility risks that change the design

These were found while checking whether the obvious implementation works. **It does not.** Both are
recorded here because the "obvious" version will be re-attempted by anyone who does not know why it
was rejected.

### 3.1 `ruby/setup-ruby@v1` cannot be assumed on this runner

All 7 `ci.yml` jobs use `ruby/setup-ruby@v1` with `bundler-cache: true`. But `nightly.yml`'s
`e2e-macos` job **deliberately avoids it**, with a dated comment: *"Use the runner's preinstalled
Ruby/bundler (the maker-mac dev box) — ruby/setup-ruby assumes the GitHub-hosted /Users/runner
layout this self-hosted runner doesn't have."*

Retargeting at the Mac while keeping that action fails at step 2 of every job — and it fails on
*infrastructure*, which is the least legible kind of red.

**The mitigation is verified, not hoped for.** The runner service's own PATH
(`~/actions-runner-tinkerex/.path`) already carries everything the Rails jobs need:

```
…/.nvm/versions/node/v18.20.8/bin : …/mise/installs/ruby/3.4.7/bin : ~/.local/bin :
/opt/homebrew/bin : … : ~/.cargo/bin
```

Ruby **3.4.7**, exactly matching `.ruby-version` (`ruby-3.4.7`); bundler 4.0.3; Homebrew (so
`resvg`, `f3d`, `vipsthumbnail` all resolve); and cargo. So the Mac jobs adopt `e2e-macos`'s
already-proven pattern: **no `setup-ruby`, `bundle install --quiet` against the runner's Ruby.**
Losing `bundler-cache` costs nothing here — a self-hosted runner is persistent, so the gems are
already installed.

### 3.2 The preflight CANNOT list runners with `GITHUB_TOKEN`

Listing self-hosted runners requires the **`administration`** permission. That permission is **not
among those a workflow `GITHUB_TOKEN` can be granted** (the grantable set is actions, checks,
contents, deployments, id-token, issues, discussions, packages, pages, pull-requests,
repository-projects, security-events, statuses). A preflight written the obvious way — `gh api
repos/:owner/:repo/actions/runners` — **403s on every run**.

The diagnosis in §2.1 used exactly that call and it worked, which is the trap: it worked because the
*local* `gh` holds an admin-scoped PAT. `ci/runners/README.md:53` documents the same command as the
way to verify runners, reinforcing the wrong instinct. **A workflow is not that shell.**

Design consequence: §4.3 declares the fleet in a repo **variable** rather than querying it.

---

## 4. Part A — make CI run

### 4.1 Retarget the 7 `ci.yml` jobs at the Mac

`[self-hosted, linux]` → `[self-hosted, macos]` for `scan_ruby`, `scan_js`, `lint`, `test`,
`test-share-backend`, `test-s3-backend`, `system-test`; and per §3.1 replace `ruby/setup-ruby` with
`bundle install --quiet`.

Every one of those gates is measured green on this box (§1). Two objections, both answered:

- **"Serialising 7 jobs on one runner will be slow."** STATUS.md raised this. Measured away: the
  suite is **5.2 s** and the whole 7-job set is ~30 s of actual work. Wall-clock is dominated by
  checkout and bundle, not tests.
- **"`system-test` needs headless Chrome and `db:test:prepare` on the Mac."** Also from STATUS.md.
  Verified working: `bin/rails db:test:prepare test:system` → 6 runs, 0F, 0E, Chrome launched
  Puma and drove the browser.

**Label case is proven, not assumed.** The runner's auto-applied label is `macOS`; workflows write
`macos`. That matches — `cross-os-e2e`'s `mac-pull-1` and `mac-pull-2` jobs
(`runs-on: [self-hosted, macos]`) both **succeeded on 2026-06-25** against this runner. This
repo's own history is the evidence; no appeal to documentation is needed.

**The `resvg` step gets fixed, not just moved.** Today it is `cargo install resvg --version 0.47.0
|| true`. On a cold box that is a multi-minute from-source build, and `|| true` means a failure is
*silent* — the preview tests then branch on `SvgRasterizer.available?` and quietly render
`unsupported`, so the job stays green while the PNG path it exists to exercise never runs. **That is
the brakeman-exit-3 pattern exactly** (§4.4): a gate that is not a gate. New order: use it if
present (it is, at `/opt/homebrew/bin/resvg`), else `brew`, else `cargo`, and if all fail **write a
loud step-summary warning naming the coverage lost**. Still non-fatal — the honest state is
"degraded and said so", not "green".

### 4.2 Move the two blocking gate jobs

`rust-client.yml`'s `changes` and `cross-os-e2e.yml`'s `seed` → `[self-hosted, macos]`. Per §2.4
neither has a Linux dependency. This one line in `rust-client.yml` revives `mac-tests`: the hermetic
Rust suites (fs-provider **192 tests**, sync-client, fs-cfapi, fs-fskit), the
`x86_64-pc-windows-gnu` CfAPI FFI cross-check, and the native macOS `fs-webdav` + `sync-engine`
build — all of which target the online runner and are dark only because their gate is not.

`seed` moving is necessary but **not sufficient** for cross-OS: its downstream legs are Windows and
Linux, so the workflow will still skip most of itself under §4.3. Moving it is still right — it
turns "the whole workflow hangs" into "the workflow runs and reports what it could not do".

Note also: `seed` reaches the deployed server at `192.168.1.95`. From the Mac, `curl http://192.168.1.95/up`
returns **404** (kamal-proxy routes by Host header, so a bare-IP request matches no route). `seed`
treats an unreachable server as `BLOCKED` and exits 0, so this is a clean skip, not a failure — but
do not claim cross-OS reachability from the Mac without re-testing with the right Host.

### 4.3 The preflight — the real fix for "queues forever"

A new ~2 s job on `[self-hosted, macos]`, at the top of `ci.yml`, `rust-client.yml`,
`nightly.yml` and `cross-os-e2e.yml`:

1. Reads the repo variable **`vars.CI_RUNNERS`** — a comma-separated declared fleet, e.g. `macos`
   today, `macos,linux` once Unraid is registered. Absent → default `macos`.
2. Emits one boolean output per family: `macos`, `linux`, `windows`.
3. Writes a **step summary** listing which families are available and — the load-bearing half —
   **naming every job that will be skipped and the coverage that gives up.**

Every Linux/Windows job gains `needs: preflight` and
`if: needs.preflight.outputs.<family> == 'true'`. A job whose runner is absent is therefore **never
scheduled**, so it cannot queue. PRs go green and mergeable without `--admin`.

**Why a declared variable rather than a live API check.** Forced by §3.2: the live check is not
authorizable from a workflow. Given that, the variable is the better of the two remaining options —
no new secret, no admin scope inside CI, and the fleet becomes an explicit reviewed fact in the repo
instead of ambient infrastructure state.

**Its failure mode is bounded and visible, which is why it is acceptable.** A stale variable claiming
`linux` when no Linux runner exists puts *only the jobs it wrongly claims* back to queueing, and the
step summary states the claim on every run, so the lie is legible at the point of damage. Compare
the status quo, where the claim is invisible and *everything* queues.

**Documented upgrade, not built now:** if an admin-scoped PAT is ever added as a secret, the
preflight should *cross-check* the variable against the API and fail on mismatch. That converts the
declaration into an assertion. It is not built here because it requires minting an admin-scoped
credential and storing it in CI — a real security decision, not a detail.

**Do not "simplify" this into a `rescue`-style fallback that queues when the variable is missing.**
The default must be the conservative one (`macos` only). A missing variable that defaults to
"everything is available" reproduces the original bug precisely.

### 4.4 `bin/ci` — one command that IS the gate (Part B)

```sh
bin/ci          # every gate
bin/ci test     # the three backend legs only
bin/ci scan     # the three security scanners only
bin/ci system   # the browser tier only
```

Prints one row per gate — **gate → exit code → duration** — and exits non-zero if any gate did.

**Exit codes are the substance, not the formatting.** Until 2026-07-29 `bin/brakeman` exited **3**,
and because `scan_ruby` runs brakeman as step 1 and `bin/bundler-audit` as step 2, **the audit gate
had never executed at all**. The job looked like two gates and was zero — which is how five gems
drifted behind 18 published advisories, one High on the always-on `/cable` path. Reading these by
*output* rather than by *exit code* is what hid it.

**`bin/ci` is the single source; `ci.yml` calls it.** Each job runs `bin/ci <gate>`, so the jobs keep
their independent statuses in the PR UI while there is exactly one definition of what a gate is.
This replaces the hand-copied 8-command checklist in `docs/STATUS.md` — and a hand-copied checklist
is precisely the artifact that let a non-gate pass as a gate. STATUS.md's block is replaced by a
pointer to `bin/ci`.

The three backend legs need their env exactly as `ci.yml` has it (share: a `mktemp -d`
`LIBRARY_PATH`; s3: the five `LIBRARY_S3_*` knobs pointing at a bucket that **deliberately does not
exist** — any test making a real S3 call must fail, which is the point).

### 4.5 Leave the schedules armed

`nightly` (08:00 UTC) and `cross-OS` (08:30 UTC) stay scheduled. Under §4.3 a scheduled run now
**completes in seconds** with a summary saying which coverage was skipped, instead of queueing for
24 h and being cancelled. Commenting out the cron would stop the noise by making the loss silent —
the same failure class as everything else in this document.

---

## 5. Part C — the browser test tier

### 5.1 The gap, measured

| Surface | Size | Browser coverage |
|---|---|---|
| ERB views | 67 files | — |
| Stimulus controllers | 13 files, **1,035 lines** | 3 |
| JS unit tests | — | **0** (no `package.json`, no `test/javascript`) |
| System tests | 2 files | **6 examples** |

Per controller:

```
modelviewer   219 lines   0 system tests    ← the 3D viewer
sheet         165 lines   1
importer      153 lines   0                 ← Printables .zip import
generator      98 lines   1
filemenu       97 lines   0
traylayout     90 lines   1
thumbs         74 lines   0
uploader       54 lines   0                 ← the chunk two-phase upload path
boxfilter/boxpreview/textpreview/thumbfallback/hello    85 lines total   0
```

**Ten of thirteen have zero browser coverage, and all three exceptions were written after a bug
shipped.** `test/system/tray_layout_test.rb` is recorded in project memory as *the repo's first
system test*, written for a bug where `<input type=text>` silently strips newlines and broke five
generators — one of them **silently**. No request-level test could have caught it, and none did.

**A premise correction worth keeping, because it changes what to build.** The framing that prompted
this work was *"most of our tests are for the file system"*. By test-file count that is not what the
tree shows — `test/integration/web` is the **largest single directory in the suite** (31 files), and
web/maker totals ~111 files against ~31 for file-layer + sync + storage + library combined. The
instinct was right but the target was one layer off: the web is thoroughly covered **at the request
level** (POST, assert redirect, assert row changed) and **barely at all in a browser**. So writing
more tests *of the kind that already exist* would add little. **Building the missing tier is the
work.**

### 5.2 Harness first

`test/system/support/` — a Devise sign-in helper, a library-fixture helper (a project with files,
per-backend-neutral), and assertion helpers for the shapes that recur (modal open/close, flash
message, grid tile present). Zero new dependencies: `capybara` and `selenium-webdriver` are already
in the Gemfile's `:test` group and Chrome is installed.

### 5.3 The policy — required, because the tier costs ~290× per test

Measured on this box: **932 ms** per system example (6 in 5.59 s) against **3.2 ms** per unit test
(1628 in 5.16 s) — a factor of **294**. Without a written rule the tier either stays at 6 tests
forever or grows until it dominates the suite.

> **A behavior earns a system test if and only if it is observable only in a browser.**

Qualifying: Stimulus DOM reading/writing and event wiring; form-control semantics (the
`<input type=text>` newline class); Turbo/redirect/reload flows; rendered-HTML → JS contracts (data
attributes and Stimulus values). **Not** qualifying — these stay at the request level where they
already have cheap coverage: authorization, persistence, the FileLayer port, and backend selection.
Explicitly do **not** re-run the three-backend matrix through the browser; the port's behavior is
contract-tested and ambient-backend drift is caught by the `ci.yml` legs.

This policy is written into `test/system/README.md` so it is where an author is standing.

### 5.4 Coverage order, by risk × size

1. **`uploader`** (54) — the chunk two-phase presigned upload: the **main deployment's** upload
   path, zero browser coverage. Its server endpoints are covered by 6 request tests; the browser
   orchestration between them is not.
2. **`importer`** (153) — client-side JSZip unzip → per-backend upload → attach. Notable because it
   depends on the hand-patched `buffer.js` vendoring, which re-running `bin/importmap pin` reverts.
3. **`filemenu`** (97) — attach / move / rename, touching `Maker::MoveNode` and the collision-rename
   prompt.
4. **`thumbs` + `thumbfallback`** (88) — grid tiles and the degrade path.
5. Tool UIs — `boxfilter`, `boxpreview`, `textpreview`, `generator`.
6. **`modelviewer`** (219) — last, and with a **stated limit rather than a pretence**: assert it
   mounts, requests the model URL, and logs no console error. **Do not assert rendered geometry** —
   the canvas is opaque to Capybara, and a test that appears to check the render while checking
   nothing is worse than no test.

Each new test is **mutation-checked**: revert the behavior it pins and confirm it goes red. This
repo's own standard, and the reason `FakeS3` once hid a data-loss bug behind 79/80 green.

### 5.5 CI placement

`system-test` stays its own job (moved to the Mac per §4.1; the screenshot-on-failure artifact
upload is already wired) so the tier's growing cost stays visible instead of inflating the unit-test
job.

---

## 6. What this design deliberately does NOT change

- **Every `runs-on` stays `[self-hosted, …]`.** §15: hosted runners are the only billed ones.
- **No workflow is deleted.** The Linux and Windows jobs keep their labels and their content; they
  become conditional. Deleting them would make the coverage loss permanent and invisible — the exact
  failure this document exists to fix.
- **`--admin` merges stop being necessary, not forbidden.** Branch protection is unavailable on this
  repo (private, free plan — `gh api …/branches/main/protection` returns 403 "Upgrade to GitHub
  Pro"), so the discipline stays manual either way. The change is that a green run is now reachable.

---

## 7. Verification

1. **A green `CI` run on the branch — the first since 2026-06-24.** `gh run list --workflow=ci.yml`
   shows `success`, not `queued`.
2. **No job in any workflow reports `queued`** after the run settles. This is the §2.3 fix, and it
   is the one that must be checked by *status*, not by wall-clock.
3. **`bin/ci` exits 0** and prints every gate with its exit code. Then, as a mutation check, break
   one gate deliberately (e.g. add a rubocop offense) and confirm `bin/ci` exits non-zero **and
   names that gate** — a summary script that swallows a failure is the failure mode being fixed.
4. **The preflight step summary names the skipped Linux/Windows coverage** on a run where those
   families are absent.
5. **Each new system test is mutation-checked** (§5.4).
6. **The three never-executed `ci.yml` changes actually run** (§2.5) — the two backend legs and the
   resvg step. Expect to debug them; a failure there is five weeks old, not new.
7. Re-run the three security gates **by exit code** (`bin/ci scan`) and confirm 0/0/0.

---

## 8. Out of scope, each with its reason

- **No JS unit-test toolchain (`package.json` + vitest/jest).** Decided: it introduces a node
  dependency tree to a repo that deliberately has no JS build step (importmap + hand-vendored ESM,
  with documented patches that `bin/importmap pin` reverts), needs node provisioned on every runner,
  and tests modules under **jsdom rather than the real browser+importmap path** — which is exactly
  the seam the known shipped bugs lived in. The `<input type=text>` newline behavior is real-browser
  DOM semantics that jsdom would likely not reproduce. **Revisit trigger:** a controller grows
  substantial pure logic that is genuinely awkward to reach through the DOM.
- **Registering the Linux runner on Unraid.** The decision is made (Unraid, `192.168.1.95`) and the
  design is built so it slots in by adding `linux` to `vars.CI_RUNNERS` — but registration mints a
  token and changes infrastructure, so it is a separate, user-run step. Note `ci/runners/setup-linux.sh`
  is Debian/apt-shaped and Unraid is not; it needs a containerized or VM path.
- **Windows re-registration on CHAIMDESK.** The machine is UP, but it is the same class of infra
  task. The preflight skips Windows jobs cleanly until then.
- **The SQLite `BusyException` intermittent.** Captured once (2026-07-27, `Tools::GeneratorsControllerTest`
  setup); the offered cross-worker explanation is already disproved (each parallel worker has its own
  `storage/test.sqlite3_N`). Open-ended debugging with no guaranteed result, and **not** what is
  keeping CI dark.
- **The `importer_controller.js` third extension→role table.** Already recorded open in STATUS.md;
  nothing is broken because the server re-derives authoritatively. The importer system test (§5.4)
  covers its observable effect. Fixing the duplication means plumbing the Ruby vocabulary into JS —
  a source change, not test infrastructure.
- **Clearing the 11 queued runs and 4 stuck Dependabot PRs.** Housekeeping, folded into §7 as the
  step that makes the first real run readable rather than a work item of its own.

---

## 9. Docs to update on completion

- **`docs/STATUS.md`** — replace the *"CI cannot run"* section (its 8-command checklist becomes a
  pointer to `bin/ci`) and record the new topology plus what the preflight skips.
- **`CLAUDE.md` §15** — the runner list is already corrected to "only one is registered"; add that
  `ci.yml` targets `macos`, that `vars.CI_RUNNERS` gates the rest, and keep the "verify with
  `gh api …/actions/runners` rather than trusting this line" instruction.
- **`ci/runners/README.md`** — note that its verify command needs an **admin-scoped** token and
  therefore **cannot** be used from inside a workflow (§3.2), and add the Unraid Linux path.
- **`test/system/README.md`** (new) — the §5.3 policy.
