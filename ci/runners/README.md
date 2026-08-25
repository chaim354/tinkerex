# Self-hosted GitHub Actions runners

We run CI on our own three machines (macOS, Linux, Windows) — native, no VMs — instead
of GitHub-hosted runners. This keeps GitHub Actions as the orchestrator (all workflow
YAML is unchanged except `runs-on:`) while letting us run the jobs that only real
hardware can: the live Windows CfAPI smoke and the macOS cross-compile check.

## Labels

Each runner self-applies `self-hosted` + its OS + arch, and these scripts add a stable
custom label so workflows can target a specific box:

| Box | Labels |
|---|---|
| Linux | `self-hosted, linux, maker-linux` |
| macOS | `self-hosted, macos, maker-mac` |
| Windows | `self-hosted, windows, maker-windows` |

Workflows then use e.g. `runs-on: [self-hosted, linux]`.

## Two repos now share these boxes (since the client/ extraction, 2026-08-20)

`client/` — the Rust crates and the Tauri desktop app — moved to its own repo,
**`chaim354/tinkerex-client`** (`docs/superpowers/plans/2026-08-20-stage-1-extract-client.md`).
Most of the CI that used to run here moved with it: `build-app.yml`, `install-app-on-runners.yml`,
`cross-os-e2e.yml`, and `rust-client.yml` now live in `tinkerex-client`'s own workflows. The
handful that stayed behind went too on 2026-08-25, when `nightly.yml` and `client-contract.yml`
were deleted (`docs/superpowers/specs/2026-08-25-cross-repo-ci-handoff.md`). **`ci.yml` is the
only workflow left in this repo**, and every one of its jobs runs on `macos`.

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

**As of this writing, only the macOS box has EITHER registration** (see "Verify the runners are
online" below) — the Linux and Windows physical boxes are not registered against `tinkerex` today,
so the equivalent statement for `tinkerex-client` is stronger: it has **no runners registered on
any OS**, including macOS, until this is done at least once. Every workflow that moved to
`tinkerex-client` is *skipped, not passing* until then.

## One-time setup (run ONCE per box, per repo — see above)

### 1. Mint a registration token (on any box with `gh` authed to `chaim354/tinkerex`)

Registration tokens are **single-use and expire in ~1 hour**, so mint one right before
running the setup script on a given box:

```sh
gh api -X POST repos/chaim354/tinkerex/actions/runners/registration-token --jq .token
```

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

**As of 2026-07-29 only `charless-MacBook-Pro-maker-mac` is registered** — not all three.

> ⚠️ **This command works ONLY from a developer shell, never from inside a workflow.** Listing
> self-hosted runners requires the `administration` permission, which is **not among the permissions a
> workflow `GITHUB_TOKEN` can be granted** — a workflow calling it gets a **403**. It works here
> because your personal token carries admin scope, and that asymmetry is a trap: the obvious
> "preflight that checks which runners are online" cannot be built this way. `ci/preflight.sh` reads
> the repo variable `CI_RUNNERS` instead, and its header explains why at length.

## Registering a runner is only HALF the job

CI gates every linux/windows job on the declared fleet, so a newly registered runner does **nothing**
until it is declared:

```sh
gh variable set CI_RUNNERS --body "macos,linux"     # comma-separated; families are macos|linux|windows
```

Omit this and the jobs stay skipped with a green run — the step summary on every run says which
families are absent, so check there first if a runner "isn't picking up work".

## Adding a Linux runner on Unraid

`192.168.1.95` is the intended home: up, SSH open, already a Docker host, deploy user `kamal1`.

**`setup-linux.sh` will not run there as-is** — it is Debian/apt-shaped and Unraid is Slackware-based
with a non-persistent root filesystem. Two workable paths:

1. **A container** on the Unraid Docker host (`myoung34/github-runner` or a hand-rolled image),
   with the runner's work dir on a persistent share. Needs `/dev/fuse` + `--cap-add SYS_ADMIN` if the
   FUSE mount jobs are to work, since those are most of what a Linux runner buys.
2. **An Unraid VM** running Debian, where `setup-linux.sh` applies unchanged.

Either way, finish with the `gh variable set` above, then confirm a previously-skipped job actually
runs — a registered-but-undeclared runner and a declared-but-offline runner look identical in the run
list (everything skipped) and are fixed differently.

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
require approval. (Our `rust-client.yml`/`ci.yml` are trusted-author only.)
