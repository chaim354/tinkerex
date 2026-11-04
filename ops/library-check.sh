#!/usr/bin/env bash
# Is every share deployment's library actually readable? Runs ON the Unraid VM, every 5 minutes from
# cron; installed to /home/kamal1/tinkerex-ops/library-check.sh by bin/library-check-install.
#
#   library-check.sh --ping --quiet      # what cron runs: silent while healthy, tells Uptime Kuma either way
#   library-check.sh                     # a human asking: one line per deployment, exit 0 / 1, NO ping
#   ssh kamal1@192.168.1.95 bash -s < ops/library-check.sh   # the same from a checkout, nothing installed
#   library-check.sh --table             # the rows below; no docker, no ping
#
# WHY THIS EXISTS. The share deployment's /library is a Docker CIFS volume onto Tower's SMB share.
# When Tower reboots, the running container keeps a mount that is now a STALE FILE HANDLE: `ls
# /library` fails and every read of a file's bytes answers 503 (FileLayer::FetchError) — while `/up`
# stays 200 and the catalog keeps rendering from the local database, so the app LOOKS healthy. That
# happened on 2026-10-22, 10-26 and 11-01 (tinkerex#499), and each time it was found only because a
# deploy failed at container create. The recovery was never the hard part; knowing was.
#
# WHY NOT `/up`. A health check that depends on a third party turns that party's blip into an
# outage of everything (CLAUDE.md §14a's boot guards, for the same reason). kamal-proxy will not
# hand traffic to a container whose `/up` fails, so a library-probing `/up` would turn "the NAS is
# rebooting" into "the whole app is down and every deploy is refused" — trading a partial outage the
# catalog survives for a total one. The web banner never probes the port either (§14d).
#
# WHY BOX-SIDE, NOT A RECURRING JOB IN THE APP. The app has `FetchError` -> 503 and
# `Current.library_unreachable` already; what it has no way to do is TELL anyone, and nobody was
# looking at a page when the mount died. This reports through an Uptime Kuma PUSH monitor, the same
# dead-man's switch the nightly backup uses: Kuma alerts on a `down` ping AND on the ABSENCE of
# pings, so cron unloaded, the VM off or docker wedged go red too, which no job inside the app could
# report about itself.
#
# WHY IT ONLY ALERTS, AND NEVER RESTARTS ANYTHING. The recovery is known — `docker stop` the share
# container, then `kamal deploy -d share` remounts fresh (docs/DEPLOY.md §6b) — and automating it was
# considered and refused. (1) The box cannot run that recovery: kamal and its secrets live on the
# Mac, and the box-only substitute (`docker restart`) has never been tried on the real failure. A
# recovery that was argued, not probed, is this repo's dominant failure shape. (2) Port 445
# answering does not mean the share is exported again: a restart that races Tower's array start
# fails its CIFS mount at create, and the deployment goes from "catalog up, bytes down" to fully
# down with nothing serving it. (3) A flapping NAS would make a restart loop of a production
# container. What the owner lacked each time was the fact, and the alert carries the fact AND
# whether SMB answers yet — which is the one question the recovery needs answered first.
#
# EMPTY IS UNHEALTHY. An unmounted mount point is a real, readable, EMPTY directory, which is why
# FileLayer::Share#library_present? treats emptiness as "not mounted" (lib/library_backend_check.rb
# says why the boot cannot). The same reading here also catches the library volume recreated as a
# plain local one — Kamal recreates a removed volume empty — which would otherwise list cleanly.
# This checks the MOUNT, /library; the library root the app reads is a folder chosen within it
# (Tinkerex::LibraryRoot), and a stale mount fails at the mount.

set -euo pipefail
# cron's PATH is minimal. APPENDED, not assigned: test/ops_library_check_test.rb puts a fake docker
# ahead of everything, and assigning PATH here would quietly run the real one instead.
export PATH="${PATH:+$PATH:}/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# ---- the table --------------------------------------------------------------------------------
# One row per deployment whose library is a MOUNT: its name, the `docker ps -qf name=` filter for its
# container, and the path inside that container that must list. test/ops_library_check_test.rb holds
# the rows to the merged Kamal config: every box deployment with LIBRARY_BACKEND=share has exactly
# one row, its filter finds that deployment's container and no other's, and the path is its
# LIBRARY_PATH and a volume mount. So a second share deployment cannot go unwatched quietly.
# BASH-3.2-SAFE, because the test runs this on a Mac: no associative arrays, no ${x,,}, no mapfile.
read -r -d '' TABLE <<'TABLE' || true
# name  container filter          path
share   ^tinkerex-web-share-      /library
TABLE

rows() { printf '%s\n' "$TABLE" | awk 'NF && $1 !~ /^#/'; }

# ---- Uptime Kuma ------------------------------------------------------------------------------
# One push URL per row, in ~/tinkerex-ops/library-ping.env, written ONLY by bin/library-check-install
# (chmod 600, never committed: the token is the whole authentication):
#
#   PING_LIBRARY_SHARE=http://192.168.1.146:3001/api/push/aBcD1234
#
# A SEPARATE FILE FROM THE BACKUP'S ping.env, so each file has exactly one writer. The key carries
# LIBRARY_ anyway: a backup destination name is a bare word, so `PING_LIBRARY_<X>` can never be a
# backup key, and a line pasted into the wrong file pings no wrong monitor.
#
# THE TWO URL TRAPS ARE ops/backup-db.sh's, RESTATED HERE BECAUSE THIS SCRIPT IS INSTALLED ALONE,
# and the test drives both through this file rather than trusting that they were copied: the file is
# PARSED, NEVER SOURCED (Kuma's own URL carries `&`, a job separator to `.`), and any query string is
# STRIPPED before curl adds its own (a duplicate `status` reaches Kuma as an array, and every `down`
# is recorded as UP).
PING_FILE="${LIBRARY_PING_FILE:-$HOME/tinkerex-ops/library-ping.env}"

ping_url() {  # name -> the push URL, or nothing. ALWAYS status 0: no URL is never a check failure.
  local key
  key="PING_LIBRARY_$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')="
  [ -f "$PING_FILE" ] || return 0
  PING_KEY="$key" awk 'index($0, ENVIRON["PING_KEY"]) == 1 { url = substr($0, length(ENVIRON["PING_KEY"]) + 1) }
                       END { if (url != "") print url }' "$PING_FILE" \
    || echo "    (could not read $PING_FILE, so no ping for $1)" >&2
  return 0
}

# A FAILED PING NEVER CHANGES THE ANSWER. The exit status says whether the library is readable; Kuma
# being down is a different fact, and folding it in would make the two indistinguishable.
ping_kuma() {  # name up|down msg
  local url
  url=$(ping_url "$1")
  if [ -z "$url" ]; then
    echo "    (no PING_LIBRARY_$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]') in $PING_FILE — nothing will hear this; re-run bin/library-check-install)" >&2
    return 0
  fi
  url="${url%%\?*}"
  curl -fsS --max-time 10 --get --data-urlencode "status=$2" --data-urlencode "msg=$3" --data-urlencode "ping=" \
       "$url" >/dev/null 2>&1 </dev/null \
    || echo "    (uptime-kuma ping failed for $1 — the check itself ran)" >&2
}

usage() { echo "usage: library-check.sh [--ping] [--quiet] | --table" >&2; }

# EVERY DOCKER CALL IS BOUNDED: a wedged dockerd or a CIFS read that blocks must not let five-minute
# runs pile up behind each other. And none reads stdin, though `main` below is what makes that safe.
d() { timeout 30 docker "$@" </dev/null; }

# Why a deployment's library is unreadable, told the way the recovery needs it: the SMB host from the
# volume's own device option (never restated here) and whether its port 445 answers YET. Stopping the
# container while it does not answer would fail the remount and leave nothing serving at all.
# if-blocks throughout this file, never `[ x ] && y`: under `set -e` a bare test-and-act returns the
# TEST's status, the trap bin/backup-status names too.
smb_hint() {  # container-id path
  local vol device host port
  vol=$(d inspect -f "{{range .Mounts}}{{if eq .Destination \"$2\"}}{{.Name}}{{end}}{{end}}" "$1" 2>/dev/null) || vol=""
  if [ -z "$vol" ]; then echo "$2 is not a volume mount"; return 0; fi
  device=$(d volume inspect -f '{{.Options.device}}' "$vol" 2>/dev/null) || device=""
  if [ "$device" = "<no value>" ]; then device=""; fi
  if [ -z "$device" ]; then
    echo "volume $vol has no device option: it is a PLAIN LOCAL volume, not the share — do not 'docker volume rm' it, see docs/DEPLOY.md §6b"
    return 0
  fi
  host=${device#//}; host=${host%%/*}
  port="${LIBRARY_SMB_PORT:-445}"
  if timeout 5 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$host" "$port" </dev/null 2>/dev/null; then
    echo "SMB $host:$port answers — recover now: docs/DEPLOY.md §6b"
  else
    echo "SMB $host:$port does NOT answer — the NAS is down or rebooting; recover once it does (docs/DEPLOY.md §6b)"
  fi
}

main() {
  local ping=false quiet=false status=0
  local name filter path problem healthy hint cids cid cname rc listing found stamp msg
  while [ $# -gt 0 ]; do
    case "$1" in
      --table) rows; exit 0 ;;
      # OPT-IN, because only the cron run may touch the monitor: an ad-hoc `up` from a deploy
      # pre-check would refresh the heartbeat by hand and hide a dead cron, and an ad-hoc `down` would
      # page about a run nobody scheduled. The same rule, for the same reason, as the backup's
      # --to-stdout.
      --ping)  ping=true; shift ;;
      --quiet) quiet=true; shift ;;
      *)       usage; exit 64 ;;
    esac
  done

  errfile=$(mktemp)
  trap 'rm -f "$errfile"' EXIT

  while read -r name filter path _ <&3; do
    problem=""; healthy=""; hint=""
    if ! cids=$(d ps -q --filter "name=$filter" 2>"$errfile"); then
      problem="docker did not answer: $(head -1 "$errfile")"
    elif [ -z "$cids" ]; then
      # A deployment that is not running is not serving its library either, and saying nothing about
      # it would be a check reporting all-clear over a set it could not look at.
      problem="no running container matches $filter"
    else
      # EVERY match, not `head -1`: during a deploy the old and new containers run side by side, and
      # either one serving a dead mount is a dead library for whoever kamal-proxy routes to it.
      for cid in $cids; do
        cname=$(d inspect -f '{{.Name}}' "$cid" 2>/dev/null) || cname="/$cid"
        cname=${cname#/}
        # `timeout` INSIDE the container as well as around docker: killing the docker CLI does not
        # kill the process it started, so only the inner one stops a blocked `ls` outliving this run.
        rc=0
        listing=$(timeout 60 docker exec "$cid" timeout -k 5 20 ls -A -- "$path" </dev/null 2>"$errfile") || rc=$?
        found=""
        if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
          found="$path did not answer within 20 s"
        elif [ "$rc" -ne 0 ]; then
          found=$(head -1 "$errfile")
          if [ -z "$found" ]; then found="listing $path exited $rc"; fi
        elif [ -z "$listing" ]; then
          found="$path is EMPTY — an unmounted mount point reads exactly like this"
        else
          healthy="${healthy:+$healthy; }$cname: $(printf '%s\n' "$listing" | wc -l | tr -d ' ') entries in $path"
        fi
        if [ -n "$found" ]; then
          problem="${problem:+$problem; }$cname: $found"
          if [ -z "$hint" ]; then hint=$(smb_hint "$cid" "$path"); fi
        fi
      done
    fi

    stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    if [ -z "$problem" ]; then
      if ! $quiet; then echo "$stamp ok  $name  $healthy"; fi
      if $ping; then ping_kuma "$name" up "$healthy"; fi
    else
      status=1
      msg="$problem${hint:+ | $hint}"
      echo "$stamp !!  $name  $msg"
      if $ping; then ping_kuma "$name" down "$msg"; fi
    fi
  done 3<<ROWS
$(rows)
ROWS

  exit $status
}

# THE WHOLE FILE IS DEFINITIONS UNTIL THIS LINE, AND THAT IS WHAT MAKES `ssh … bash -s <
# ops/library-check.sh` SAFE. bash reads a script on stdin one command at a time, so a command that
# read stdin before the last line would swallow the rest of the script, and the check would end
# early having said nothing. By the time `main` runs there is nothing left to swallow, and the rows
# come in on fd 3, so nothing in the loop can eat a row either. The test's fake docker drains stdin.
main "$@"
