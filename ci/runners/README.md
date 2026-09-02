# Self-hosted GitHub Actions runners

We run CI on our own hardware instead of GitHub-hosted runners — GitHub bills only the hosted ones
(CLAUDE.md §15) — while GitHub Actions stays the orchestrator: every workflow YAML is unchanged
except `runs-on:`.

**Since 2026-08-31 that hardware is four Linux CONTAINERS on the Unraid Docker host, not the
developer's MacBook.** "The live runners" below is the section to read first. The bare-metal Linux
and Windows boxes and their `setup-*` scripts are still documented here and neither is registered;
the jobs that genuinely need real hardware — the live Windows CfAPI smoke, the two-device
real-mount e2e — moved to `chaim354/tinkerex-client` on 2026-08-25 and are not this repo's CI any
more.

## Labels

| Box | Labels |
|---|---|
| **Unraid containers ×4 (live)** | `self-hosted, linux, X64, maker-unraid` |
| Linux (bare metal, unregistered) | `self-hosted, linux, maker-linux` |
| macOS (still registered; deregistered as the fleet narrows to `linux`) | `self-hosted, macos, maker-mac` |
| Windows (unregistered) | `self-hosted, windows, maker-windows` |

Workflows target the **family** label — `runs-on: [self-hosted, linux]` — never the box label.
`maker-unraid` routes to the same containers, but `test/ci_hygiene_test.rb` treats a job that names
only a box label as an offender: nothing static can then tell which preflight output gates it, so it
ships ungated and queues for 24 h with nothing red anywhere.

The four containers take their labels from `LABELS:` in `ops/ci-runner-stack.yml`, not from a
`setup-*` script. GitHub echoes the family back capitalised (`Linux`) in the API listing; the value
the stack sets is lowercase.

## The live runners: four containers on Unraid (since 2026-08-31)

CI runs on **four container runners on the Unraid Docker host, `192.168.1.146`** ("Tower", the
Unraid box itself). **Three addresses are in play and confusing them costs an afternoon:**
`192.168.1.7` is Nginx Proxy Manager, where the `*.home` wildcard resolves — including
`portainer.home`; `192.168.1.95` is the Kamal VM the app deploys to. **This README named .95 as the
intended runner home until 2026-08-31; that was wrong.**

- **Image:** `ci/runner/Dockerfile` — Ruby 3.4.7 via mise, Chrome + chromedriver, and all four
  preview binaries (`vipsthumbnail`, `resvg`, `pdfium`, `stl-thumbnailer`). Built **natively on the
  box**, never cross-built on the ARM64 Mac. The base is `myoung34/github-runner:2.336.0-ubuntu-noble`
  and the suffix is load-bearing: the bare `2.336.0` tag is Ubuntu 20.04 Focal with glibc 2.31, on
  which **two of the four binaries will not run**. Any replacement base needs **glibc >= 2.34**.
- **Stack:** `ops/ci-runner-stack.yml`, deployed through Portainer as stack `ci-runners`. Portainer
  holds the running copy; the file is the reviewable one, and the two change in the same breath.
- **Credential:** a fine-grained PAT scoped to `chaim354/tinkerex` with **Administration: read &
  write and nothing else**, supplied as the Portainer stack variable `RUNNER_ACCESS_TOKEN`. It lives
  at `op://tinkerex/github runners/credential` (§14g); nothing is `export`ed and the value never
  enters this repo.
- **Work dirs:** bind-mounted to `/mnt/user/appdata/tinkerex-ci/runner-N/_work` on the array, never
  Docker named volumes — those live in the same loop device the prune step below is about. They must
  exist and be **`chown`ed to `1001:121`** before first boot. That uid:gid is measured, not the
  1000:1000 the usual first-user convention suggests, and a work dir the non-root runner cannot write
  is a first-boot failure that reads as a broken image.
- **`RUN_AS_ROOT=false` is baked into the image and `USER runner` must NOT be added back.** The
  entrypoint has to START as root so it can chown `/actions-runner`, the work dir and the toolcache
  before it `gosu runner`s. With a `USER` line, all four containers registered and then immediately
  deregistered in a restart loop — and the error names the user, so it reads as a credential problem
  when it is not. `ci/runner/Dockerfile` carries the log.

### Rebuilding the image

```sh
# 1. Ship HEAD to the box. There is no checkout there to drift, on purpose.
git archive --format=tar HEAD | ssh root@192.168.1.146 \
  'rm -rf /tmp/tinkerex-ci && mkdir -p /tmp/tinkerex-ci && tar -x -C /tmp/tinkerex-ci'

# 2. Build natively, and propagate the REAL status — see the caveat below.
ssh root@192.168.1.146 'cd /tmp/tinkerex-ci && \
  docker build -t tinkerex-ci-runner:<new-tag> -f ci/runner/Dockerfile . > /tmp/build.log 2>&1; \
  ec=$?; tail -30 /tmp/build.log; exit $ec'

# 3. Reclaim the build cache. Not tidiness — see below.
ssh root@192.168.1.146 'docker builder prune -af'
```

Then bump `image:` in `ops/ci-runner-stack.yml`, paste it into the Portainer stack editor, and
redeploy.

**Piping the build into `tail` over ssh reports `tail`'s exit status, not the build's.** The remote
shell has no `pipefail`, so a pipeline's status is its LAST command's — probed on the box,
2026-08-31: `(exit 7) | tail -1; echo $?` prints `0`. The first build of this image reported success
over a hard failure exactly that way. Capture the status explicitly, as step 2 does. It is the same
trap `config/ci.rb` records about `tee` and `${PIPESTATUS[0]}` in the `test-chunk-remote` gate.

**Prune the build cache every time.** `/var/lib/docker` on that box is a **50 GB loop device**, and
**on Unraid a full `docker.img` takes down every container on the box, not just CI** — and it would
be CI that caused it. Measured 2026-08-31: five builds took the loop from 20 GB free to 9.0 GB
(82% used), of which **3.765 GB was build cache alone**; `docker builder prune -af` returned it to
12 GB free. The finished image is 4.39 GB and is the part you keep.

### When every job suddenly queues

Two causes look identical in the run list — every job sitting at 0 elapsed — and are fixed
completely differently:

1. **The PAT expired.** The containers are `running` and registered NOWHERE:
   `gh api repos/chaim354/tinkerex/actions/runners` lists none of them. Fine-grained PATs cannot be
   renewed in place, so mint a new one with the same scoping, update the Portainer stack variable
   `RUNNER_ACCESS_TOKEN`, and redeploy the stack.
2. **The box or the stack is down.** The containers are not running at all. Check Portainer, or
   `ssh root@192.168.1.146 'docker ps'`.

**`docker logs tinkerex-runner-1` distinguishes them in one command** — a rejected credential says so
explicitly, and a healthy runner's last line is `Listening for Jobs` (observed on runner-1,
2026-08-31).

## The sibling repos need their own registrations (since the client/ extraction, 2026-08-20)

`client/` — the Rust crates and the Tauri desktop app — moved to its own repo,
**`chaim354/tinkerex-client`** (`docs/superpowers/plans/2026-08-20-stage-1-extract-client.md`).
Most of the CI that used to run here moved with it: `build-app.yml`, `install-app-on-runners.yml`,
`cross-os-e2e.yml`, and `rust-client.yml` now live in `tinkerex-client`'s own workflows. The
handful that stayed behind went too on 2026-08-25, when `nightly.yml` and `client-contract.yml`
were deleted (`docs/superpowers/specs/2026-08-25-cross-repo-ci-handoff.md`). **`ci.yml` is the
only workflow left in this repo** — `preflight` plus one job per `bin/ci` gate — and since
2026-08-31 every one of its seven jobs runs on `linux`, i.e. on the containers above.

**Self-hosted runners register PER REPOSITORY, not per org** — a runner registered against
`chaim354/tinkerex` is invisible to `chaim354/tinkerex-client` and vice versa. So each physical box
needs a **second runner service** registered against the new repo before any of the moved CI can
run on it. This is not optional plumbing: until it's done, `tinkerex-client`'s workflows queue
against a runner family that does not exist and are auto-cancelled after 24h with nothing red
anywhere — the exact five-week-outage shape `ci/preflight.sh`'s header describes for this repo,
now possible in the new one too.

Registering the second service is the same procedure as below, run again against the other repo:
mint a token with `gh api -X POST repos/chaim354/tinkerex-client/actions/runners/registration-token
--jq .token`, then run the matching `setup-*` script **from a checkout of `tinkerex-client`**
(its own copy — this repo's scripts still hardcode `chaim354/tinkerex` as their `REPO_URL`, on
purpose: a script that took the repo as an argument would make it easy to register the wrong box
against the wrong repo by a typo, which is worse than two small near-duplicate scripts). Give the
second service a service/directory name that does not collide with the first (both `setup-*`
scripts default to a fixed install path per OS) and remember to `gh variable set CI_RUNNERS` in
**both** repos — the declared fleet is also per-repository.

**Measured 2026-08-31** (`gh api repos/chaim354/<repo>/actions/runners`): the Mac's second
registration exists — `tinkerex-client` and `tinkerex-sync` each have **one online macOS runner**,
`charless-MBP-maker-mac`. **Neither sibling has a Linux or Windows runner**, and the four Unraid
containers are registered against `tinkerex` alone, so anything in `tinkerex-client` targeting those
families still has no runner to land on. Until 2026-08-31 this paragraph said only the macOS box had
either registration and that `tinkerex-client` had no runners on any OS; both were stale.

> **`setup-*.sh` is not how this repo's CI runs any more.** The live runners are the Unraid
> containers described above. These scripts remain for a bare-metal or VM runner — `setup-linux.sh`
> is Debian/apt-shaped and will **not** run on Unraid itself, which is Slackware-based with a
> non-persistent root filesystem.

## One-time setup (run ONCE per box, per repo — see above)

### 1. Mint a registration token (on any box with `gh` authed to `chaim354/tinkerex`)

Registration tokens are **single-use and expire in ~1 hour**, so mint one right before
running the setup script on a given box:

```sh
gh api -X POST repos/chaim354/tinkerex/actions/runners/registration-token --jq .token
```

(The containers use a long-lived PAT instead, for exactly this reason: a single-use token is the
wrong shape for four containers that must re-register themselves across a host reboot. The trade is
the expiry failure mode documented above.)

### 2. Run the matching script on the box, passing the token

```sh
# Linux box:
./ci/runners/setup-linux.sh   <TOKEN>
# macOS box:
./ci/runners/setup-macos.sh   <TOKEN>
```
```powershell
# Windows box (PowerShell as Administrator):
./ci/runners/setup-windows.ps1 -Token <TOKEN>
```

Each script: installs the toolchain/prereqs that box's jobs need, downloads the latest
runner, registers it with the labels above, and installs it as a **service** so it
survives reboots. The scripts are idempotent — re-running reconfigures rather than
duplicating.

## Verify the runners are online

```sh
gh api repos/chaim354/tinkerex/actions/runners --jq '.runners[] | "\(.name)\t\(.status)\t\(.labels | map(.name) | join(","))"'
```

**As of 2026-08-31 five runners are registered and online:** the four containers
`tinkerex-unraid-1` … `-4` (ids 68–71, `self-hosted,Linux,X64,maker-unraid`) and
`charless-MacBook-Pro-maker-mac` (id 21, `self-hosted,macOS,ARM64,maker-mac`). **The Mac is still
registered** — it is deregistered ("Removing a runner" below) as the fleet narrows to `linux`. The
bare-metal Linux and Windows boxes are not registered at all: this repo's Linux coverage comes from
the containers, not from `setup-linux.sh`.

> ⚠️ **This command works ONLY from a developer shell, never from inside a workflow.** Listing
> self-hosted runners requires the `administration` permission, which is **not among the permissions a
> workflow `GITHUB_TOKEN` can be granted** — a workflow calling it gets a **403**. It works here
> because your personal token carries admin scope, and that asymmetry is a trap: the obvious
> "preflight that checks which runners are online" cannot be built this way. `ci/preflight.sh` reads
> the repo variable `CI_RUNNERS` instead, and its header explains why at length.

## Registering a runner is only HALF the job

`test/ci_hygiene_test.rb` requires every job on a family OTHER than preflight's own to be
`needs: preflight` and `if:`-gated on the declared fleet, so a runner in a NEW family does
**nothing** until it is declared:

```sh
gh variable set CI_RUNNERS --body "linux"     # comma-separated; families are macos|linux|windows
```

**It reads `macos,linux` as of 2026-08-31** — both families while the Mac is still registered — and
narrows to `linux` when the Mac goes. When the variable is unset or blank, `ci/preflight.sh` defaults
to **`linux` alone**, never all three: a default of everything-available reproduces the exact bug the
gate exists to prevent.

Nothing in `ci.yml` is gated today, because all seven jobs are on preflight's own family and gating a
job on the family its own gate runs on is circular. So what the declaration buys this repo right now
is the step summary, which states on the run's own page which families are absent — check there first
if a runner "isn't picking up work". **The moment a macos or windows job returns here it must be
gated**, and `ci_hygiene_test` fails the build if it is not: an ungated job against an absent family
does not go red, it queues at 0 elapsed for 24 h and is auto-cancelled. Five weeks of dark CI came
from that.

## The bare-metal Linux and Windows boxes

Neither is registered. A bare-metal or VM **Linux** runner is still a supported shape —
`setup-linux.sh` applies unchanged on a Debian VM — it is simply not what runs CI today. Whichever
shape you use, finish with the `gh variable set` above, then confirm a previously-skipped job
actually runs: a registered-but-undeclared runner and a declared-but-offline runner look identical in
the run list (everything skipped) and are fixed differently.

**CHAIMDESK (Windows) is reachable on the LAN but unregistered.** Same two steps: `setup-windows.ps1`
with a fresh token, then add `windows` to `CI_RUNNERS`. Note the CfAPI jobs additionally need an
**interactive** login session — the runner-as-service runs in Session 0, where a Cloud Files mount
enumerates empty (see the `windows-smoke` job's comment in `rust-client.yml`).

## Removing a runner

```sh
# get the id, then:
gh api -X DELETE repos/chaim354/tinkerex/actions/runners/<RUNNER_ID>
```
On the box, remove the service + deregister first:
- **Unix:** `sudo ./svc.sh stop && sudo ./svc.sh uninstall`, then `./config.sh remove --token <removal-token>`.
- **Windows** (no `svc.cmd` exists — the service is created by `config.cmd --runasservice`):
  `sc.exe stop "<service-name>"; sc.exe delete "<service-name>"`, then
  `./config.cmd remove --token <removal-token>`.

Get a removal token with `gh api -X POST repos/chaim354/tinkerex/actions/runners/remove-token --jq .token`.

A **container** runner mostly does this itself: the entrypoint deregisters when the container stops
(`Caught EXIT - Deregistering runner`, the line `ci/runner/Dockerfile` quotes from the `USER runner`
restart loop), so removing a service from `ops/ci-runner-stack.yml` and redeploying the stack is the
procedure. A container that is *killed* rather than stopped never reaches that trap and leaves an
offline registration behind — clear it with the `gh api -X DELETE` above.

## The live CfAPI smoke needs an INTERACTIVE Windows session

The `windows-build` job runs fine headless (as the `NETWORK SERVICE` runner service). The live
`windows-smoke` job does **not**: CfAPI / Cloud Files requires an interactive user session, but a
runner installed as a service runs in **Session 0** with no desktop — the sync root registers but
enumerates empty (`An invalid name request was made`). So `windows-smoke` is `continue-on-error`
and on-demand only.

To make the live smoke pass, run the Windows runner **interactively** in a logged-in session
instead of as a service:

```powershell
# stop/remove the service runner, then run it in your interactive session:
sc.exe stop  "actions.runner.chaim354-tinkerex.<name>"
sc.exe delete "actions.runner.chaim354-tinkerex.<name>"
cd C:\actions-runner-tinkerex
./run.cmd        # stays up while you're logged in; CfAPI works here
```
For always-on interactive, set `run.cmd` to launch at logon (Task Scheduler "At log on", run with
highest privileges, on a machine set to auto-login and never sleep).

## Enabling the two-device REAL-MOUNT e2e (Linux `/dev/fuse` + macOS interactive)

> **These suites no longer run from this repo.** `nightly.yml` was deleted on 2026-08-25 and the
> jobs moved to `chaim354/tinkerex-client`
> (`docs/superpowers/specs/2026-08-25-cross-repo-ci-handoff.md`). The runner *setup* below is
> unchanged and still required — read `nightly.yml` below as "the workflow in tinkerex-client".

The nightly `two-device-*` jobs mount **two real kernel mounts at once** and pass files between
them through the mounts (the syscall→adapter→Provider leg the engine-level e2e can't reach). Each
self-detects a missing prerequisite and exits `0` with a `BLOCKED` notice (never a false red), so
they only turn green once the runner can actually mount.

### Linux — give the runner `/dev/fuse` access (one-time)

FUSE mounts headlessly (no desktop needed), so the only requirement is that the runner's service
user can open `/dev/fuse`. The job itself installs `libfuse-dev`/`fuse` and adds `user_allow_other`
to `/etc/fuse.conf`; you just need device access for the runner user.

```sh
# Bare-metal / VM runner: add the runner's service user to the fuse group, then restart the runner.
sudo groupadd -f fuse
sudo usermod -aG fuse "$(whoami)"      # or the user the runner service runs as
ls -l /dev/fuse                        # should be group 'fuse', mode 0660 (or 0666)
# restart the runner service so it picks up the new group:
cd ~/actions-runner-tinkerex && sudo ./svc.sh stop && sudo ./svc.sh start
```

If the runner runs inside a **container**, give the container the device + capability instead:
`--device /dev/fuse --cap-add SYS_ADMIN` (and `--security-opt apparmor:unconfined` on some hosts).
**The four live containers carry neither** — `ops/ci-runner-stack.yml` grants `SYS_PTRACE` only, for
Chrome's crash handling — because these mount jobs run in `tinkerex-client`, not here. Adding
`/dev/fuse` + `SYS_ADMIN` to that stack is a real decision about what branch code can do on the
Unraid box, not a formality.

Verify (from a `tinkerex-client` checkout): `gh workflow run rust-client.yml -f target=two-device`,
then check the `two-device-fuse-linux` job logs say `mounted` + the A↔B checks, not `BLOCKED`.

### macOS — run the runner INTERACTIVELY (one-time)

`/sbin/mount_webdav` will **not** hold a mount from a headless launchd/ssh/Session context — it
needs a real desktop login session (the same class of wall as Windows CfAPI). So the macOS runner
must run in a logged-in desktop session, not as a background `launchd` service.

```sh
# stop/remove the service-mode runner, then run it inside your interactive desktop session:
cd ~/actions-runner-tinkerex
sudo ./svc.sh stop && sudo ./svc.sh uninstall
./run.sh        # stays up while you're logged in; mount_webdav works here
```

For always-on: set the Mac to **auto-login** to a desktop user, add `run.sh` as a Login Item (or a
`launchd` *LaunchAgent* in the **Aqua** session, not a LaunchDaemon), and disable sleep
(`sudo pmset -a sleep 0 disablesleep 1`). Then the nightly `two-device-webdav-macos` job mounts two
real `mount_webdav` mounts and passes files A↔B; otherwise it reports `BLOCKED` and stays green.

> Same pattern as the Windows interactive requirement above. After enabling Linux `/dev/fuse` +
> the macOS/Windows interactive sessions, the full three-OS real-mount e2e
> (`two-device-fuse-linux`, `two-device-webdav-macos`, `two-device-cfapi-windows`) runs
> automatically — in `tinkerex-client`'s workflows, not here.

## Security note

A self-hosted runner executes whatever a workflow tells it to. Because this repo is
private and runners only run our own workflows, that's acceptable. **Do not** enable
these runners for `pull_request` from forks — keep fork PRs on GitHub-hosted runners or
require approval. (`ci.yml`, the only workflow here, is trusted-author only.) That acceptance is
what makes the PAT's scoping load-bearing: `RUNNER_ACCESS_TOKEN` sits in four container environments
where any job can read it out of `env`, so it is a fine-grained token for this repo alone and
deliberately **not** the classic ghcr.io token — `ops/ci-runner-stack.yml` records the argument.
