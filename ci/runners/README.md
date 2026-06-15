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

## One-time setup (run ONCE per box)

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

All three should show `online`.

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

Verify: `gh workflow run nightly.yml` (or `gh workflow run rust-client.yml -f target=two-device`),
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
> automatically in `nightly.yml`.

## Security note

A self-hosted runner executes whatever a workflow tells it to. Because this repo is
private and runners only run our own workflows, that's acceptable. **Do not** enable
these runners for `pull_request` from forks — keep fork PRs on GitHub-hosted runners or
require approval. (Our `rust-client.yml`/`ci.yml` are trusted-author only.)
