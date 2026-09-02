# Moving CI off the developer's Mac onto the Unraid box

**Date:** 2026-08-31
**Status:** design, approved for planning
**Touches:** `.github/workflows/ci.yml`, `ci/runner/Dockerfile` (new), `ops/ci-runner-stack.yml` (new),
`ci/preflight.sh`, `ci/runners/README.md`, `test/ci_hygiene_test.rb`, `test/ci_preflight_test.rb`,
`test/support/worker_budget.rb`, `test/worker_budget_test.rb`, `test/application_system_test_case.rb`,
CLAUDE.md §12.6/§15

---

## 1. What is moving, and what is not

Every CI job in this repo runs on **`charless-MacBook-Pro-maker-mac`** — the developer's own laptop.
All seven move to **four container runners on the Unraid Docker host**, deployed as a Portainer
stack. `CI_RUNNERS` becomes `linux`, and the Mac runner is deregistered.

**What this buys, in order of size:**

1. **CI stops competing with the dev box.** `test/support/worker_budget.rb` and
   `test/application_system_test_case.rb` both carry long comments whose central premise is that a
   local `bin/ci` and a CI job share one machine — the measured cause of a recurring
   `BoxSectionsTest` flake on PRs #235 and #237. That premise ends here.
2. **CI runs when the laptop is closed.** Today it does not.
3. **Linux is what production is.** Every Kamal destination is a Linux VM (§7). macOS CI has always
   been the odd one out.
4. **Coverage goes UP, not down** — see §3's `stl-thumbnailer` finding.

**Out of scope, decided:**

- **Windows.** `CHAIMDESK` is registered nowhere and the CfAPI jobs that needed it left for
  `tinkerex-client` on 2026-08-25. §12.6 keeps its slot; this arc does not close it.
- **The Kamal deploy path.** Deploys still build on the Mac and push to ghcr.io (`config/deploy.yml`).
  Nothing in `.kamal/`, `config/deploy*.yml` or §14g is touched. The Mac loses its *runner* role only.
- **`ci/runners/setup-linux.sh`.** It is Debian/apt-shaped and Unraid is Slackware-based with a
  non-persistent root filesystem; the container path replaces it rather than fixing it. The script
  stays for a future Debian VM. Only the README's framing changes.

---

## 2. What was measured

Every figure below was measured on 2026-08-31. Commands are named so a later reader can re-measure
rather than trust this paragraph — §15's rule that a doc row is a claim.

**The runner fleet today** — `gh api repos/chaim354/tinkerex/actions/runners`:

| | |
|---|---|
| runners registered | **1** |
| name / id | `charless-MacBook-Pro-maker-mac` / **21** |
| os, status, version | macOS ARM64, online, 2.336.0 |
| labels | `self-hosted`, `macOS`, `ARM64`, `maker-mac` |
| `CI_RUNNERS` (`gh variable list`) | **`macos`**, set 2026-07-30 |
| jobs in `ci.yml` | **7**, every one `runs-on: [self-hosted, macos]` |

One runner executes one job at a time, so **the seven jobs run serially today.**

**The target box** — `docker_proxy` against Portainer environment **3**, path `/info`:

| | |
|---|---|
| OS / kernel | Unraid OS 7.3 x86_64 / 6.18.38-Unraid |
| CPUs / RAM | **36** / **33,353,981,952 bytes (33.35 GB)** |
| Docker | 29.5.3, btrfs driver, root `/var/lib/docker` |
| containers | 24 total, **20 running**; no runner container exists |
| Portainer | **2.39.6** at `http://portainer.home` (`/api/system/status` → 200) |
| environment | id **3**, name `local`, type 1 (direct), status 1 (up), `unix:///var/run/docker.sock` |

**Three hosts, and confusing them costs an afternoon** — the trap `ops/kaneo-stack.yml` already
documents, with a third box this arc adds to it:

| address | what it is |
|---|---|
| 192.168.1.7 | Nginx Proxy Manager; where the `*.home` wildcard resolves, **including `portainer.home`** |
| **192.168.1.146** | **"Tower", the Unraid host itself — where Docker runs and the runners will live** |
| 192.168.1.95 | the Kamal VM (`chunk.tinkerex.local` &c). Ports 9443/9000/8000 **closed** — Portainer is *not* here |

`ci/runners/README.md` currently names **192.168.1.95** as "the intended home" for a Linux runner.
That is the Kamal VM, not the Docker host. The README is wrong on this point today and this arc
fixes it.

**Access** — `ssh root@192.168.1.146` succeeds on key auth (`Linux x86_64`, `Docker 29.5.3`);
`kamal1@192.168.1.146` is denied. The Mac has Docker **29.7.2** but is **ARM64**.

**Toolchain presence on the Mac runner** — `command -v`:

| binary | Mac runner |
|---|---|
| `vipsthumbnail` | ✅ |
| `resvg` | ✅ |
| `pdftoppm` | ✅ |
| **`stl-thumbnailer`** | ❌ **MISSING** |

**Other constants:** `.ruby-version` is `ruby-3.4.7`; `concurrent-ruby` is **1.3.8**; the repo is
**private**; the only Actions secret is `TINKEREX_SYNC_DEPLOY_KEY`; system tests are
`driven_by :selenium, using: :headless_chrome, screen_size: [1400, 1400]`.

---

## 3. The runner image

A committed **`ci/runner/Dockerfile`**, `FROM myoung34/github-runner`, built **natively on the box**
over root SSH.

**Why not built on the Mac and pushed to ghcr.io.** The Mac is ARM64 and the target is x86_64.
Cross-building Ruby, Chrome and a Rust crate under QEMU emulation is slow enough to make rebuilds a
thing nobody does — and an image nobody rebuilds is an image that drifts from its Dockerfile, which
is the failure `ops/kaneo-stack.yml`'s header calls out in the compose-file direction. The box is a
36-core native x86_64 Docker host; building there is both faster and architecturally correct. No
registry, no auth, no QEMU.

**What it bakes in:**

- **Ruby 3.4.7**, matching `.ruby-version` exactly. Baked rather than fetched by
  `ruby/setup-ruby`: the guard in `test/ci_hygiene_test.rb` would *permit* that action on a linux
  job (`setup_ruby_offenders` exempts any job whose families exclude `macos`), but it would re-download
  or rebuild Ruby on every job for no gain.
- **Chrome + a matching chromedriver**, for `bin/ci system`.
- **All four preview binaries** — `vipsthumbnail`, `resvg`, pdfium, and **`stl-thumbnailer` compiled
  from `tools/`**.
- `git`, `ssh`, `curl`, `lsof`, `bash`, SQLite — required by `bin/ci test-chunk-remote`'s script
  (`lsof -ti tcp:$PORT`, the two `curl` probes, `${PIPESTATUS[0]}`) and by the `tinkerex-sync`
  checkout step.

**`stl-thumbnailer` is the coverage finding.** It is absent on the Mac runner today, so
`Maker::Previews::Stl` renders `unsupported` and the STL preview path has never been exercised in
CI — `ci/ensure-resvg.sh`'s "**green about less than you think**" case, occurring silently and for a
different binary than the one that script watches. Baking it in makes the Linux runner **strictly
more honest** than the box it replaces.

**`ci/ensure-resvg.sh` needs no change.** Its first branch is `command -v resvg`, which now hits and
exits 0. Its brew/cargo fallbacks become dead on this runner, which is the correct outcome for a
cheapest-first ladder — not a reason to rewrite it.

**Consequence to state plainly:** baking in a binary the Mac lacked will **legitimately change suite
counts** by un-skipping tests. See §7.

**Licensing (§9) is clear, and the reason is the one this repo already uses.** `myoung34/github-runner`
and `actions/runner` are MIT; `resvg` is MPL-2.0 (already sanctioned in `ci/ensure-resvg.sh`); our own
`stl-thumbnailer` is Apache-2.0. libvips is LGPL and Chrome is proprietary — **neither is linked and
neither is shipped**: both are subprocesses on a CI runner, which is the same footing on which
`Maker::Previews::ImageThumb` already shells out to the `vipsthumbnail` binary rather than binding
`ruby-vips` (§4, §14e). **No artifact this repo distributes changes**, since the runner image is
build infrastructure that never reaches a user. The permissive-only rule holds on the Rails image,
which this arc does not touch.

---

## 4. The Portainer stack

Committed as **`ops/ci-runner-stack.yml`**, deployed through Portainer, following
`ops/kaneo-stack.yml`'s precedent in full — including its rule that **the committed file and the
running stack change in the same breath**, because a file that has silently diverged from what runs
reads as truth and nothing can go red for it.

**Four services — `runner-1` … `runner-4` — not one service with `replicas: 4`.** Each is a
long-lived registered runner with **its own named volume**, labelled
`self-hosted,linux,X64,maker-unraid`. The distinction is load-bearing: compose `replicas` share one
volume definition, so four replicas would contend over a single work directory and corrupt each
other's checkouts. Four because the seven jobs then run 4-wide instead of
serially and the four heavy legs — `test`, `test-s3`, `test-chunk-remote`, `system` — overlap. Eight
was rejected: the Rails parallel runner forks per-core *inside* each job, and eight concurrent suites
oversubscribe a 36-core box in exactly the way `test/sqlite_concurrency_test.rb` is sensitive to.

**Port 3002 does not collide.** `bin/ci test-chunk-remote` boots a sync server on `SYNC_PORT`
(default 3002), but each container has its own network namespace, so four concurrent runs bind four
distinct ports. The gate's own `lsof -ti tcp:"$PORT" | xargs kill -9` leftover-process guard
correspondingly only ever sees its own container — which is the behaviour it wants.

**Registration uses a fine-grained PAT**, not a registration token. A registration token is
single-use and expires in ~1h (`ci/runners/README.md`), which is the wrong shape for four containers
that must re-register themselves across a host reboot. The PAT lives as a **Portainer stack
environment variable** and in **1Password**, mirroring exactly how Kaneo's `POSTGRES_PASSWORD` and
`AUTH_SECRET` are held (§14g). Nothing is `export`ed and no credential enters this repo.

**Memory limits are set** on each container — which is what makes §5 necessary rather than optional.

---

## 5. `WorkerBudget` must become cgroup-aware

**This is the change that would otherwise surface weeks later as unexplained OOM kills in the
`system` gate.**

`WorkerBudget.total_memory_bytes` reads `/proc/meminfo`'s `MemTotal` on Linux. **Inside a container
that reports the host's 33 GB regardless of the container's own limit.** So `browser_workers`
computes `min(33 GB / 4 GB, cores)` = **8 browser workers** — roughly 17 GB of Chrome by that file's
own measured figures (~6.7 GB baseline + ~1.3 GB marginal) — inside a container sized far smaller.
`available_memory_bytes` reads `MemAvailable` and is host-wide for the same reason.

`concurrent_browser_suite?` is affected too: its pidfile directory is `tmp/browser-suites` inside
each runner's own workspace, so **containers cannot see each other's suites**. That is precisely the
"both suites compute the same generous number and oversubscribe together" failure the file's header
describes, relocated one level up. In practice only the `system` gate runs browser tests (`bin/rails
test` does not include `test/system`), so at most one browser suite is live across the fleet — but
the detection is structurally blind now, and the design should say so rather than rely on that
accident holding.

**The fix: read the cgroup v2 limit first, fall back to `/proc/meminfo`.**

- `total_memory_bytes` → `/sys/fs/cgroup/memory.max`, falling back when the file is absent (not a
  container, or cgroup v1) or reads the literal `max` (no limit set).
- `available_memory_bytes` → `memory.max` minus `memory.current`, same fallback.

This makes both methods answer the question they already claim to answer — *how much memory may this
process use* — rather than a host fact that happens to be right on bare metal and wrong in a
container. Two alternatives were considered and rejected: **dropping the container memory limits**
(simplest, but a runaway suite then starves Jellyfin, Kaneo and eighteen other containers on a box
that is not CI's alone) and **an env override pinning the worker count** (works, but discards a
derived budget this repo built deliberately, and `worker_budget.rb`'s own header argues at length
against a literal).

**The CPU half needs nothing.** `Concurrent.available_processor_count` is cgroup-aware at
concurrent-ruby 1.3.8, and `browser_workers` already caps by it.

`test/worker_budget_test.rb` gains cases for: a container limit lower than `MemTotal`; `memory.max`
reading `max`; the file being absent. Its two existing contracts — "never returns zero, however
little memory there is" and "the budget is per-worker, so the count scales with memory" — are
preserved unchanged.

---

## 6. The preflight exemption must be derived, not hard-coded

`ungated_offenders` in `test/ci_hygiene_test.rb` computes `families - ["macos"]`. Its own comment
gives the reason: *"the preflight job itself runs on macos, so if that family were absent the gate
could not start either and gating a macos job on it would be circular."*

**That reasoning is about preflight's own family; the implementation is a literal.** Move `preflight`
to Linux and the literal is simply wrong in both directions: all six gate jobs would need
`needs: preflight` + `if: needs.preflight.outputs.linux == 'true'` pairs that protect nothing (a
missing Linux family stops `preflight` from starting anyway), while a future macOS job would be
silently exempt from a gate it now genuinely needs.

**Fix:** derive the exempt family from the `preflight` job's own `runs-on`. The planted-workflow
fixture test — which deliberately exercises these rules against offenders the real repo does not
ship — has its expectations updated in the same commit. Both changes are mutation-checked per §15:
break the derivation, confirm red, restore.

**`ci/preflight.sh`'s `DEFAULT` changes `macos` → `linux`, and this is a correctness fix, not
bookkeeping.** With the exemption derived, linux jobs become ungated, so they run whatever
`CI_RUNNERS` says — exactly the safety property macOS jobs have today. But the `--summary` branch
reports `targeted && !available` as "**absent — its jobs were SKIPPED**". Leave the default at
`macos` and a blank `CI_RUNNERS` produces a run whose summary says the Linux jobs were skipped while
they in fact ran. A summary that lies in the *safe* direction is still a summary that lies, and this
one exists specifically so a stale declaration is visible at the point where it does damage.
`test/ci_preflight_test.rb` asserts the old default explicitly at two places (lines 15–28) and moves
with it; the property those tests protect — *an unset variable is conservative, never
"everything"* — is unchanged.

---

## 7. Cutover, and how it is verified

**Order is load-bearing.** Declaring before the runners are online, or deregistering the Mac before a
green run, both produce the "everything queues silently at 0 elapsed" failure that
`ci/preflight.sh`'s header records as five weeks of dark CI.

1. Build the image on the box (`ssh root@192.168.1.146`).
2. Deploy `ops/ci-runner-stack.yml` through Portainer; verify **out-of-band** — a Portainer mutation
   returns an empty body on success, which is indistinguishable from a swallowed error.
3. Confirm **4 runners online** via `gh api repos/chaim354/tinkerex/actions/runners`.
4. `gh variable set CI_RUNNERS --body linux`.
5. Force a run (`workflow_dispatch`), confirm it lands on the new fleet and is green.
6. **Only then** deregister runner id 21 and remove the Mac's service.

**The three-backend-legs rule needs care on the first run.** §15 requires `test`, `test-s3` and
`test-chunk-remote` to report identical run counts, and `bin/ci` prints the three counts but never
compares them — a human reads them. This move changes OS, architecture *and* available binaries at
once, and §3 means baking in `stl-thumbnailer` will legitimately raise counts by un-skipping tests.
**So the first green run's three counts are read against each other, never against the Mac's
history.** A structural difference *between the three legs* is still the real bug it always was;
`tinkerex#131`'s known ±2 assertion / ±1 skip flap still applies.

**A second honest check:** the `system` gate's wall time. Nine consecutive CI runs took 83–97 s
(median 84 s) on the Mac because macOS `available` memory never looks idle on a machine with apps
open, so `browser_workers` returned **1** permanently. On a dedicated container with a correct cgroup
reading it should return more than 1 and the gate should get materially faster. If it does not, §5's
fix is not working and the run is green about less than it appears.

---

## 8. Documentation that goes stale on merge

Part of the work, not cleanup afterwards (§15).

| file | what is false after this lands |
|---|---|
| `CLAUDE.md` §15 "CI" | The runner paragraph names a 2026-08-24 measurement and says to re-measure. `ci.yml`'s jobs no longer "target `macos`". |
| `CLAUDE.md` §12.6 | "Linux and Windows CI coverage is skipped, not passing" — Linux becomes the *only* coverage. Windows still is not. Keeps its number (§12 is a frozen pointer table). |
| `ci/runners/README.md` | "Adding a Linux runner on Unraid" is written as a proposal and names **192.168.1.95** — the Kamal VM, not the Docker host. Becomes the live path, at .146. The "only the macOS box has EITHER registration" line inverts. |
| `test/application_system_test_case.rb` | "the CI runner IS a developer's own Mac (§15)… so a local `bin/ci` and a CI job share one box" — load-bearing to its argument for `Capybara.default_max_wait_time = 10`. The *conclusion* stands (headroom is still right); the *reason* changes. |
| `test/support/worker_budget.rb` | Same premise, twice, plus "docs/DEPLOY.md's CI runner is a developer's own laptop today but need not stay one" — which is now history rather than a hypothetical. |

`ci.yml`'s own header comment ("EVERY JOB HERE RUNS ON macos, and that is a measurement rather than a
preference", verified on the maker-mac box 2026-07-29) is replaced by the equivalent measurement on
the new fleet — taken, not assumed.

---

## 9. What could go wrong

- **Chrome in a container needs `--no-sandbox` or a user namespace.** Running headless Chrome as
  root without it fails outright. The image runs the runner as a non-root user, which is the fix that
  does not weaken the sandbox. Loud failure, caught on the first `system` run — not a silent one.
- **`btrfs` + many small files.** The Docker root is btrfs; `bundle install` and a Rails test run
  create a lot of small files. If this is slow, a volume on a different share is the answer, not a
  storage-driver change.
- **The PAT expiring.** A fine-grained PAT has an expiry; when it lapses, all four containers fail to
  re-register and every job queues. This looks identical to "the box is down" and is fixed
  differently — the README gets both symptoms and both fixes.
- **§14e's warning applies to this arc's own guards.** `assert_workflows_scanned` exists because a
  guard whose subject is a path dies silently when the path moves. The preflight-exemption change is
  exactly the kind of edit that could make `ungated_offenders` scan nothing; the fixture test is what
  keeps it honest, and it is updated rather than relaxed.
