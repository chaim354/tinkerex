#!/usr/bin/env bash
# The share deployment's library mount, checked and — only on request, only behind its guards —
# recovered. Runs ON the Unraid VM (kamal1@192.168.1.95), where the share container lives:
#
#   ssh kamal1@192.168.1.95 bash -s < ops/share-mount-recover.sh              # recover (no-op if healthy)
#   ssh kamal1@192.168.1.95 bash -s -- --check   < ops/share-mount-recover.sh # read-only, one line
#   ~/tinkerex-ops/share-mount-recover.sh --monitor                            # what cron runs
#
# THE FAILURE THIS EXISTS FOR. The share deployment mounts its library as a Docker `local`-driver
# CIFS volume (tinkerex_library_3dprinting, //192.168.1.146/3D Printing — config/deploy.share.yml).
# Docker mounts it when the first container using it starts and unmounts it when the last one
# stops. When Tower (the SMB server) reboots, the running share container keeps a mount that is
# now a STALE FILE HANDLE: `ls /library` inside it fails, while `/up` — which never touches the
# library — keeps answering 200, so nothing alerts. The next `kamal deploy -d share` then fails at
# container create with docker exit 125 (`error evaluating symlinks from mount source … stale file
# handle`), because docker hands the new container the dead mount the old one is still holding.
# Five deploys found it that way between 2026-10-22 and 2026-11-04 (docs/guides/DEPLOY.md §2).
#
# THE RECOVERY, AND WHY EACH GUARD IS IN FRONT OF IT. `docker stop` the old container (the cifs
# mount count drops 1 → 0), `docker rm` any half-created new one, and the next share deploy mounts
# the share fresh. Stopping a container that serves real data is the one irreversible step here,
# so nothing is stopped until: (1) exactly one share container is running — two means a deploy is
# mid-flight and will finish on its own; (2) its `ls /library` REALLY says "Stale file handle" —
# a healthy mount is a no-op, a hung or otherwise-failing one is a different problem; and
# (3) Tower answers on port 445 — if the SMB server is still down there is nothing to remount, and
# stopping the container would only trade a dead library for a dead /up. A guard that fails exits
# non-zero and touches nothing. Re-running after a recovery is a no-op (nothing running, mount
# released, exit 0): idempotent.
#
# THE MONITOR NEVER RECOVERS. `--monitor` is the cron entry point (bin/share-mount-monitor-install,
# every 5 minutes): the same check, plus a loud line in the log and syslog and an Uptime Kuma push
# (`status=down` with the diagnosis, `status=up` when healthy — a dead-man's switch, so a VM that is
# off or a cron that stopped is noticed too, exactly as the nightly backup's is). Restarting a
# container that is serving real data is an operator's decision, not a cron job's, which is why the
# recovery is a separate mode you run by hand. The ping key is PING_SHARE_MOUNT in the same
# ~/tinkerex-ops/ping.env the backup reads, parsed never sourced (ops/backup-db.sh says why), and a
# failed ping never fails the check.
#
# EXIT CODES ARE LOAD-BEARING (the deploy skill branches on them):
#    0  healthy (nothing done), or recovered (recover mode), or already recovered
#   10  stale — reported, not recovered (--check / --monitor)
#   20  refused: the SMB host does not answer on 445, so there is nothing to remount yet
#   21  refused: `ls /library` failed for a reason that is not a stale handle (or hung)
#   22  refused: no share container running (--check/--monitor), or more than one (recover)
#   23  recovery incomplete: the container was stopped and the mount is still held
#   64  usage
#
# Bash-3.2-safe (no associative arrays, no ${x,,}, no mapfile): test/ops_share_mount_test.rb drives
# every mode on a Mac against a fake `docker`, so the guards are proven to refuse before this ever
# stops a container on the box.

set -euo pipefail
# APPENDED, NOT REPLACED: cron's PATH is minimal, so the sbin dirs are added — but a caller's PATH
# stays in front, which is what lets the test put its fake docker/mount/timeout ahead of the real ones.
export PATH="$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# The share deployment, as config/deploy.share.yml spells it. test/ops_share_mount_test.rb holds all
# three to the merged Kamal config, so a renamed volume or a moved LIBRARY_PATH goes red here rather
# than making every check pass over the wrong mount.
CONTAINER_FILTER='^tinkerex-web-share-'
LIBRARY_VOLUME="${LIBRARY_VOLUME:-tinkerex_library_3dprinting}"
LIBRARY_PATH="${LIBRARY_PATH:-/library}"
SMB_PORT="${SMB_PORT:-445}"
# A soft CIFS mount bounds a hung `ls`, but a wedged dockerd does not bound anything; every docker
# call runs under this. 124 is `timeout`'s own exit status.
DOCKER_TIMEOUT="${DOCKER_TIMEOUT:-20}"
OPS_DIR="${OPS_DIR:-$HOME/tinkerex-ops}"
PING_FILE="${PING_FILE:-$OPS_DIR/ping.env}"
PING_KEY="PING_SHARE_MOUNT"
STATE_FILE="${STATE_FILE:-$OPS_DIR/share-mount.state}"
TAG="tinkerex-share-mount"

usage() { echo "usage: share-mount-recover.sh [--check | --monitor]   (no flag = recover, guards first)" >&2; }
MODE=recover
case "${1:-}" in
  "")          ;;
  --check)     MODE=check ;;
  --monitor)   MODE=monitor ;;
  -h|--help)   usage; exit 0 ;;
  *)           usage; exit 64 ;;
esac

dk() { timeout "$DOCKER_TIMEOUT" docker "$@"; }
say() { printf '%s\n' "$*"; }
now() { date '+%Y-%m-%d %H:%M:%S'; }

# ---- the check: what state is the share library in? --------------------------------------------
# Sets STATE to one of healthy | stale | hung | lserror | none | many, DETAIL to a human line,
# RUNNING to the "id name" lines of the running share containers (RUNNING_COUNT of them), and for a
# stale one STALE_ID/STALE_NAME. Read-only.
STATE=""; DETAIL=""; RUNNING=""; RUNNING_COUNT=0; STALE_ID=""; STALE_NAME=""
check() {
  RUNNING=$(dk ps --filter "name=$CONTAINER_FILTER" --filter status=running --format '{{.ID}} {{.Names}}')
  RUNNING_COUNT=$(printf '%s' "$RUNNING" | grep -c . || true)
  if [ "$RUNNING_COUNT" -eq 0 ]; then
    STATE=none; DETAIL="no share container is running (filter $CONTAINER_FILTER)"; return 0
  fi
  # Every running one is asked — during a deploy's overlap there are two, and the one being
  # retired may be the stale one. Stale is the state this script is FOR, so it outranks the others.
  STATE=healthy; DETAIL="$LIBRARY_PATH readable in $(printf '%s\n' "$RUNNING" | awk '{ print $2 }' | paste -s -d ' ' -)"
  local id name err rc
  while read -r id name; do
    [ -n "$id" ] || continue
    rc=0
    err=$(dk exec "$id" ls "$LIBRARY_PATH" 2>&1 >/dev/null) || rc=$?
    if [ "$rc" -eq 0 ]; then
      continue
    elif printf '%s' "$err" | grep -qi 'stale file handle'; then
      STATE=stale; STALE_ID=$id; STALE_NAME=$name
      DETAIL="$LIBRARY_PATH in $name is a stale file handle ($(printf '%s' "$err" | head -1))"
      break
    elif [ "$rc" -eq 124 ]; then
      STATE=hung; DETAIL="ls $LIBRARY_PATH in $name did not answer in ${DOCKER_TIMEOUT}s (is Tower reachable?)"
    elif [ "$STATE" = healthy ]; then
      STATE=lserror; DETAIL="ls $LIBRARY_PATH in $name failed (rc=$rc): $(printf '%s' "$err" | head -1)"
    fi
  done <<EOF
$RUNNING
EOF
  if [ "$RUNNING_COUNT" -gt 1 ] && [ "$STATE" = healthy ]; then STATE=many; fi
  return 0
}

state_code() {
  case "$1" in
    healthy|many) echo 0 ;;
    stale)        echo 10 ;;
    hung|lserror) echo 21 ;;
    none)         echo 22 ;;
  esac
}

# ---- the Uptime Kuma push, same rules as ops/backup-db.sh's ping_kuma ----------------------------
# ping.env is PARSED, NEVER SOURCED (a Kuma URL carries `&`, which `.`-sourcing reads as a job
# separator), exactly one line — the one BEGINNING `PING_SHARE_MOUNT=` — is read and the last wins,
# the query string Kuma's UI appends is STRIPPED (a duplicated `status` arrives as an array and every
# `down` reads as up), and a failed ping never fails the check: the check is the product.
ping_url() {
  [ -f "$PING_FILE" ] || return 0
  PK="$PING_KEY=" awk 'index($0, ENVIRON["PK"]) == 1 { url = substr($0, length(ENVIRON["PK"]) + 1) }
                       END { if (url != "") print url }' "$PING_FILE" 2>/dev/null || true
  return 0
}
ping_kuma() {  # up|down msg
  local url
  url=$(ping_url)
  [ -n "$url" ] || return 0
  url="${url%%\?*}"
  curl -fsS --max-time 10 --get --data-urlencode "status=$1" --data-urlencode "msg=$2" --data-urlencode "ping=" \
       "$url" >/dev/null 2>&1 || say "    (uptime-kuma ping failed — the check itself was fine)" >&2
  return 0
}

# ---- --check: one line, the exit code says which ------------------------------------------------
if [ "$MODE" = check ]; then
  check
  say "share library: $STATE — $DETAIL"
  exit "$(state_code "$STATE")"
fi

# ---- --monitor: the same check, said loudly and pushed to the monitor ---------------------------
# Quiet when healthy (a 5-minute cron would otherwise write 288 identical lines a day), loud on
# every unhealthy run, and one line at each TRANSITION so the log reads as a history. The state file
# is best-effort: a missing ops dir just means no transition lines.
if [ "$MODE" = monitor ]; then
  check
  previous=""
  if [ -r "$STATE_FILE" ]; then previous=$(cat "$STATE_FILE" 2>/dev/null || true); fi
  if [ -d "$(dirname "$STATE_FILE")" ]; then printf '%s\n' "$STATE" > "$STATE_FILE" 2>/dev/null || true; fi
  case "$STATE" in
    healthy|many)
      if [ -n "$previous" ] && [ "$previous" != healthy ] && [ "$previous" != many ]; then
        say "$(now) share library healthy again — $DETAIL"
        logger -t "$TAG" -p daemon.notice "share library healthy again: $DETAIL" 2>/dev/null || true
      fi
      ping_kuma up "$DETAIL"
      ;;
    *)
      say "$(now) !! share library $STATE — $DETAIL"
      if [ "$STATE" = stale ]; then
        say "   /up still answers 200 over a dead library. Recover by hand (an operator's call, never cron's):"
        say "     ssh kamal1@192.168.1.95 bash -s < ops/share-mount-recover.sh   # then: kamal deploy -d share --skip-push"
      fi
      logger -t "$TAG" -p daemon.err "share library $STATE: $DETAIL" 2>/dev/null || true
      ping_kuma down "share library $STATE: $DETAIL"
      ;;
  esac
  exit "$(state_code "$STATE")"
fi

# ---- recover: guards first, then stop, rm, confirm ------------------------------------------------
check
case "$STATE" in
  healthy)
    say "share library healthy — $DETAIL. Nothing to do."
    exit 0 ;;
  many)
    say "!! refusing: more than one share container is running — a deploy is in progress; let it finish:" >&2
    printf '%s\n' "$RUNNING" | sed 's/^/     /' >&2
    exit 22 ;;
  hung|lserror)
    say "!! refusing: $DETAIL" >&2
    say "   Only a stale handle is recovered here; this is something else. Look before stopping anything." >&2
    exit 21 ;;
  none)
    # Nothing running: either recovery already happened (idempotent re-run) or the deployment is
    # down for its own reasons. Finish the half that may be left — a `Created` container from a
    # failed deploy — and confirm the mount is released; never invent a container to stop.
    say "no share container is running."
    ;;
  stale)
    if [ "$RUNNING_COUNT" -gt 1 ]; then
      say "!! refusing: $DETAIL — but $RUNNING_COUNT share containers are running, so a deploy is in progress." >&2
      say "   Let it finish (it retires the stale one itself), then re-run if anything is still stale." >&2
      exit 22
    fi
    say "$DETAIL"
    ;;
esac

# Resolve the mount from the volume the container actually mounts at LIBRARY_PATH (falling back to
# the configured name when nothing is running), so the host probed and the mount counted are the
# ones in use, not the ones this file remembers.
volume="$LIBRARY_VOLUME"
if [ "$STATE" = stale ]; then
  v=$(dk inspect --format "{{range .Mounts}}{{if eq .Destination \"$LIBRARY_PATH\"}}{{.Name}}{{end}}{{end}}" "$STALE_ID" 2>/dev/null || true)
  [ -n "$v" ] && volume="$v"
fi
device=$(dk volume inspect --format '{{.Options.device}}' "$volume" 2>/dev/null || true)
mountpoint=$(dk volume inspect --format '{{.Mountpoint}}' "$volume" 2>/dev/null || true)
if [ -z "$device" ] || [ -z "$mountpoint" ]; then
  say "!! refusing: docker volume $volume has no device/mountpoint — is this the share box? (docker volume inspect $volume)" >&2
  exit 21
fi
smb_host="${device#//}"; smb_host="${smb_host%%/*}"
mount_count() { mount | grep -cF " on $mountpoint type cifs" || true; }

if [ "$STATE" = stale ]; then
  # GUARD 3: something to remount. A hard power-cycle of Tower takes minutes; stopping the share
  # container before the SMB server is back trades a dead library for a dead /up as well.
  if ! timeout 3 bash -c "exec 3<>/dev/tcp/$smb_host/$SMB_PORT" 2>/dev/null; then
    say "!! refusing: $smb_host does not answer on $SMB_PORT, so there is nothing to remount yet." >&2
    say "   Wait for Tower, then re-run. The container was NOT stopped." >&2
    exit 20
  fi
  say "$smb_host answers on $SMB_PORT; cifs mounts of $device before: $(mount_count)"
  say "stopping $STALE_NAME (the only thing holding the dead mount) ..."
  dk stop "$STALE_ID" >/dev/null
  say "stopped."
fi

# A deploy that failed at create leaves its new container in `Created` — never started, holding no
# data (the storage volume is named and persists) — and `kamal deploy` would trip over the name.
# Only `created` ones: the `Exited` ones are kamal's rollback history and stay.
created=$(dk ps -a --filter "name=$CONTAINER_FILTER" --filter status=created --format '{{.ID}} {{.Names}}')
if [ -n "$created" ]; then
  while read -r cid cname; do
    [ -n "$cid" ] || continue
    say "removing half-created $cname ..."
    dk rm "$cid" >/dev/null
  done <<EOF
$created
EOF
fi

remaining=$(mount_count)
if [ "$remaining" -ne 0 ]; then
  say "!! the cifs mount of $device is still held ($remaining) with no share container running." >&2
  say "   Something else holds it — find it before going on:" >&2
  say "     mount | grep -F '$mountpoint'" >&2
  say "     docker ps -a --filter volume=$volume --format '{{.Names}} {{.Status}}'" >&2
  exit 23
fi
if [ "$STATE" = stale ]; then
  say "cifs mounts of $device after: 0 — the dead mount is released."
  say "Now, from the Mac:  kamal deploy -d share --skip-push   (the fresh container mounts the share anew;"
  say "its first boot may restart once if the mount is not yet visible to the boot guard — docker's restart policy absorbs it)."
else
  say "cifs mounts of $device: 0 — already recovered; nothing to stop. Deploy with: kamal deploy -d share --skip-push"
fi
exit 0
