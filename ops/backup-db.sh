#!/usr/bin/env bash
# THE definition of how a backup is taken. Runs ON the Unraid VM; installed to
# /home/kamal1/tinkerex-ops/backup-db.sh by bin/backup-cron-install.
#
#   backup-db.sh --to-volume tinkerex_backups --keep 14 chunk share s3 sync  # what cron runs
#   backup-db.sh --to-stdout share > local.tar.gz                        # what bin/backup-db runs
#
# ONE IMPLEMENTATION, TWO CALLERS, ON PURPOSE. The nightly and the ad-hoc Mac command differ only
# in where the bytes land, and every hard-won detail below (the WAL-safe snapshot, the --anchored
# excludes, verify-before-you-trust-it) is a detail that a second copy would eventually not have.
# This repo's recorded failure shape is a rule that exists in one place and silently does not in
# another — §14b's Reconciler and §14d's file-type vocabulary are both here for that reason.
#
# WHY A HELPER CONTAINER RATHER THAN `docker exec` INTO THE APP. The helper mounts the storage
# volume directly, so a backup does not depend on the app container being UP — a nightly whose
# whole job is to run when things are broken must not require the thing that is broken. SQLite's
# locking is POSIX locks on the shared inode, so a `.backup` from a second container against the
# same volume is safe against the live app writing throughout; that is the same guarantee that
# makes it safe against Puma and Solid Queue inside one container.
#
# WHY NOT `cp`: these databases run in WAL mode, so committed state is split between the
# .sqlite3 and its -wal sidecar. A non-atomic copy of the pair still OPENS and mostly answers
# queries — the corruption surfaces later, on one row, with nothing to tie it back. `sqlite3
# .backup` is SQLite's online-backup API and is defined against concurrent writers.
#
# WHY THE ACTIVE STORAGE BLOBS ARE IN THE ARCHIVE: config.active_storage.service = :local, so
# preview assets sit on the same volume, and they are NOT rebuildable from a restored database —
# Maker::Previews::MissingBackfill skips any node that already HAS a preview row, so a DB-only
# restore leaves every row at `ready` pointing at a file that is gone. Silent blank thumbnails.

set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin   # cron's PATH is minimal

OUT_VOLUME=""; TO_STDOUT=false; KEEP="${KEEP:-14}"; DESTS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --to-volume) OUT_VOLUME="${2:?--to-volume needs a docker volume name}"; shift 2 ;;
    --to-stdout) TO_STDOUT=true; shift ;;
    --keep)      KEEP="${2:?--keep needs a number}"; shift 2 ;;
    chunk|share|s3|sync) DESTS+=("$1"); shift ;;
    *) echo "usage: backup-db.sh (--to-volume NAME [--keep N] | --to-stdout) <chunk|share|s3|sync>..." >&2; exit 64 ;;
  esac
done
[ ${#DESTS[@]} -gt 0 ] || { echo "no destinations given" >&2; exit 64; }

# --keep IS VALIDATED HERE — BEFORE ANY BACKUP WORK AND BEFORE ANY PING — because the prune it
# feeds runs AFTER that destination's `up` ping has already gone out. A bad value therefore
# destroys the archive set on a run the monitor has already recorded as healthy, which is precisely
# the failure this arrangement exists to make impossible. Measured in the real app image (dash +
# GNU tail) against four stub archives, before this guard existed:
#   --keep 0    tail -n +1  pruned ALL FOUR, including the archive written seconds earlier — exit 0
#   --keep -1   tail -n +0  the same
#   --keep abc  dash aborts the arithmetic, but only inside a PIPELINE ELEMENT, so the pipeline's
#               status is the `while` loop's and sh still exits 0 — the prune silently does nothing
#               on every run from then on, and the leak is reported as success.
#
# ZERO IS REFUSED, NOT REINTERPRETED, AND THE DIVERGENCE FROM ITS SIBLING IS DELIBERATE. CLAUDE.md
# §14a gives LIBRARY_TRASH_DAYS=0 the meaning "keep forever", precisely because the obvious
# implementation purges the lot. That is the right call for a DURATION: "0 days of history" is a
# coherent thing to mean, and the generous reading is the safe one. It is the wrong call for a
# retention COUNT — `--keep 0` plainly reads as "keep zero", so silently keeping everything would
# just be the same surprise pointing the other way. A count has no safe reading of a value that is
# simply a typo, so this one fails loudly while whoever typed it is still watching.
case "$KEEP" in
  ''|*[!0-9]*)
    echo "--keep must be a positive integer, got '$KEEP'" >&2
    echo "  Neither way of getting this wrong is loud. A negative resolves to 'tail -n +0', which" >&2
    echo "  selects EVERY archive; anything non-numeric aborts the arithmetic inside a pipeline" >&2
    echo "  element, so nothing is pruned on any run from then on and each one still reports OK." >&2
    exit 64 ;;
esac
[ "$KEEP" -ge 1 ] || {
  echo "--keep 0 would delete EVERY archive, including the one this run is about to write" >&2
  echo "  — and the prune runs after the success ping, so nothing would report the loss." >&2
  echo "  Use --keep 1 to keep only the newest. There is no value meaning 'keep everything'." >&2
  exit 64
}

# ---- Uptime Kuma push monitors ---------------------------------------------------------------
# One push URL per destination, in ~/tinkerex-ops/ping.env (written by bin/backup-cron-install,
# never committed — the tokens are the whole authentication):
#
#   PING_CHUNK=http://192.168.1.146:3001/api/push/aBcD1234
#
# A PUSH MONITOR IS A DEAD-MAN'S SWITCH: Uptime Kuma alerts on the ABSENCE of a ping, which is the
# only thing that catches the failures that matter here — cron unloaded, the VM off, the script
# never reaching its own error handler. A monitor that only reports failures it was told about
# cannot see any of those.
PING_FILE="${PING_FILE:-$HOME/tinkerex-ops/ping.env}"

# PARSED, NEVER SOURCED — and this is not defensiveness, it is a bug that was already caught.
# A Kuma push URL copied out of its UI contains `&` (`…?status=up&msg=OK&ping=`). `. ping.env` on
# an unquoted line like that makes bash read the `&` as a JOB SEPARATOR: the assignment runs in a
# background subshell, the variable is never set in this shell, and the ping silently does not
# happen. Sourcing also means any value in that file is executable shell. Reading it with an
# explicit whitelist takes every value literally and cannot do either.
if [ -f "$PING_FILE" ]; then
  while IFS='=' read -r _k _v; do
    case "$_k" in
      PING_CHUNK) PING_CHUNK=$_v ;;
      PING_SHARE) PING_SHARE=$_v ;;
      PING_S3)    PING_S3=$_v ;;
    esac
  done < "$PING_FILE"
  unset _k _v
fi

# A FAILED PING MUST NEVER FAIL THE BACKUP. The backup is the product; the ping is telemetry about
# it. Letting curl's exit status reach `status` would turn "Uptime Kuma is rebooting" into "last
# night's backup failed", and — because a nonzero exit skips the prune — into a slow leak too.
ping_kuma() {  # dest up|down msg seconds
  local var="PING_$(echo "$1" | tr '[:lower:]' '[:upper:]')" url
  url="${!var:-}"
  [ -n "$url" ] || return 0

  # STRIP ANY QUERY STRING, because Uptime Kuma's own UI hands you the push URL with one already
  # attached — `…/api/push/TOKEN?status=up&msg=OK&ping=` — and copying it verbatim is the obvious
  # thing to do. `curl --get` would then append a SECOND status, Express/qs parses the duplicate
  # into an ARRAY, and Kuma's `req.query.status === "down"` test compares against an array and is
  # false. Every failure would be recorded as UP: the monitor stays green precisely when it should
  # not, which is worse than having no monitor at all.
  url="${url%%\?*}"
  curl -fsS --max-time 10 --get \
       --data-urlencode "status=$2" --data-urlencode "msg=$3" --data-urlencode "ping=$4" \
       "$url" >/dev/null 2>&1 \
    || echo "    (uptime-kuma ping failed for $1 — the backup itself was fine)" >&2
}
if $TO_STDOUT && [ ${#DESTS[@]} -ne 1 ]; then
  echo "--to-stdout takes exactly one destination (two archives cannot share one stream)" >&2; exit 64
fi
[ -n "$OUT_VOLUME" ] || $TO_STDOUT || { echo "need --to-volume or --to-stdout" >&2; exit 64; }

# ---- the output volume must actually be the array ---------------------------------------------
# A DOCKER VOLUME NAME THAT DOES NOT RESOLVE IS NOT AN ERROR — `docker run -v name:/dst` CREATES
# IT, as a plain local volume under /var/lib/docker/volumes on the VM's own 31 GB disk. So the
# failure this guards is silent by construction: `docker volume rm tinkerex_backups`, or a Kamal
# run that re-ensures the name, and from that night on the job writes ~44 MB into the very disk
# the array was chosen to avoid, verifies its own archive there quite happily, and pings green.
# The archives on the NAS simply stop being added to, which nothing reports and `bin/backup-status`
# reads as healthy because it inspects the same recreated name.
#
# `bin/backup-cron-install` has always compared this against the path it composed. That check runs
# when a human is watching; this one runs at 03:30 for months. The DIVISION IS DELIBERATE: the
# installer knows BACKUP_NAS/BACKUP_SUBDIR and so can insist on the exact device, while this script
# is handed only a volume name and asks the weaker, sufficient question — *is there a device at
# all*, i.e. is this a driver-opt volume rather than a local directory. Do not "improve" it into an
# exact match by threading the path through the crontab line: a bare `%` in a cron command is a
# newline (see the header/footer note below), and this box has a share whose name contains a space.
#
# THIS PINGS `down` WHERE THE `--keep` GUARD ABOVE DELIBERATELY DOES NOT, and the two are not in
# tension. A bad `--keep` is a typo arriving from a human who is still at the keyboard. A volume
# that has stopped pointing at the array is box state that will fail unattended, exactly like the
# vanished-container arm below — so it gets the same treatment, for the same reason.
if [ -n "$OUT_VOLUME" ]; then
  out_device=""
  if docker volume inspect "$OUT_VOLUME" >/dev/null 2>&1; then
    # `<no value>` is what a Go template prints for the missing key on a volume with no options at
    # all, which is precisely the plain-local case; treat it as the empty string it means.
    out_device=$(docker volume inspect --format '{{.Options.device}}' "$OUT_VOLUME" 2>/dev/null || true)
    [ "$out_device" = "<no value>" ] && out_device=""
  fi
  if [ -z "$out_device" ]; then
    echo "!! $OUT_VOLUME is not a CIFS volume — refusing to run" >&2
    echo "   It has no device option, so it is either absent (and this run would CREATE it) or a" >&2
    echo "   plain local volume on the VM's own disk — the one place a backup must never live." >&2
    echo "   Nothing would have failed: the archives would be written and verified, and every" >&2
    echo "   monitor would go green, while the array stopped receiving backups." >&2
    echo "   Fix it with bin/backup-cron-install, which owns the NAS path. Do NOT 'docker volume" >&2
    echo "   rm' anything first — see docs/DEPLOY.md §6." >&2
    for dest in "${DESTS[@]}"; do
      ping_kuma "$dest" down "output volume $OUT_VOLUME is not on the array" ""
    done
    exit 1
  fi
fi

# `docker ps -a`, not `docker ps`: a STOPPED app container still names the image and the volume,
# and a nightly that skips a deployment because it happens to be down is a nightly that goes
# quiet exactly when it matters. Chunk is the base deployment, so its container is
# `tinkerex-web-<sha>` — the `[0-9a-f]` is what stops that prefix from also matching -share-/-s3-.
container_for() {
  case "$1" in
    chunk) docker ps -a -qf name='^tinkerex-web-[0-9a-f]' | head -1 ;;
    share) docker ps -a -qf name='^tinkerex-web-share-'   | head -1 ;;
    s3)    docker ps -a -qf name='^tinkerex-web-s3-'      | head -1 ;;
    # THE ONLY ANCHORED PATTERN HERE ($), AND IT MUST STAY ANCHORED. `sync` is a Kamal ACCESSORY,
    # so its container name is the fixed string `tinkerex-sync` rather than a per-deploy
    # `<name>-<sha>` — that is exactly what gives the maker app a stable network alias to put in
    # CHUNK_REMOTE_URL (config/deploy.yml's `sync:` block). Unanchored, `^tinkerex-sync` would
    # ALSO match a `tinkerex-sync-web-<sha>` container, which is what the STANDALONE deployment of
    # chaim354/tinkerex-sync names its containers — that service really was running on this box
    # until 2026-08-24, on the same volume, and `docker ps -a` still lists exited containers by
    # design (see the comment above). Matching one of those would source the helper image from a
    # stale revision while `head -1` hid that anything was ambiguous.
    sync)  docker ps -a -qf name='^tinkerex-sync$'        | head -1 ;;
  esac
}
volume_for() {
  # `sync` IS THE SYNC SERVER'S OWN DATABASE, NOT A FOURTH COPY OF THE MAKER'S. It is a different
  # Rails app (chaim354/tinkerex-sync) holding the chunk catalog — versions, manifest_chunks,
  # changelog_entries. A restore that recovers the maker database and not this one recovers a
  # library whose every file resolves to nothing. The volume happens to have the SAME internal
  # shape (production.sqlite3 at its root, plus a `nodes` table for the verify step to count), so
  # WORKER needs no arm of its own — checked, not assumed.
  case "$1" in chunk) echo tinkerex_storage ;; share) echo tinkerex_storage_share ;; s3) echo tinkerex_storage_s3 ;; sync) echo tinkerex_sync_storage ;; esac
}

# Everything below runs INSIDE the helper. $1 = "" (stdout) or the archive path under /dst.
#
#   --anchored IS LOAD-BEARING. GNU tar matches --exclude patterns unanchored by default, against
#   any trailing part of a member name, so `./production*.sqlite3*` would also match the staged
#   snapshot at ./db-snapshot/production.sqlite3 — the archive would contain every blob and NO
#   DATABASE AT ALL, at a completely plausible size.
#   ./backup-*  is an older ad-hoc snapshot left in a volume by hand; not ours to ship.
read -r -d '' WORKER <<'INNER' || true
set -eu
out=$1
rm -rf /src/db-snapshot; mkdir -p /src/db-snapshot
for db in production production_cache production_queue production_cable; do
  [ -f "/src/$db.sqlite3" ] || continue
  sqlite3 "/src/$db.sqlite3" ".backup /src/db-snapshot/$db.sqlite3"
  c=$(sqlite3 "/src/db-snapshot/$db.sqlite3" "PRAGMA integrity_check;" | head -1)
  [ "$c" = ok ] || { echo "$db: integrity_check said '$c'" >&2; exit 1; }
done
tarball() { tar -cz -C /src --anchored --exclude='./production*.sqlite3*' --exclude='./backup-*' .; }
if [ -z "$out" ]; then
  tarball
else
  # .partial until it has been read back and checked: a truncated archive under the real name is
  # a backup that inventories fine and restores nothing, and would age out a good one.
  tarball > "$out.partial"
  rm -rf /tmp/vfy && mkdir -p /tmp/vfy
  tar -xzf "$out.partial" -C /tmp/vfy ./db-snapshot/production.sqlite3
  c=$(sqlite3 /tmp/vfy/db-snapshot/production.sqlite3 "PRAGMA integrity_check;" | head -1)
  [ "$c" = ok ] || { echo "written archive failed integrity_check: $c" >&2; rm -f "$out.partial"; exit 1; }
  n=$(sqlite3 /tmp/vfy/db-snapshot/production.sqlite3 "SELECT count(*) FROM nodes;")
  mv "$out.partial" "$out"
  echo "    $(basename "$out")  $(du -h "$out" | cut -f1)  ${n} nodes"
fi
rm -rf /src/db-snapshot
INNER

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
status=0

# The run's own header/footer live HERE rather than in the crontab line, because **crontab treats
# a bare `%` as a newline** — the obvious `{ date -u +'%FT%TZ'; ...; }` wrapper in the cron entry
# does not fail loudly, it silently truncates the command at the first `%` and feeds the rest to
# the job as stdin. A nightly whose command line is quietly cut in half is precisely the failure
# this whole exercise exists to avoid.
$TO_STDOUT || echo "== $(date -u +%Y-%m-%dT%H:%M:%SZ) starting: ${DESTS[*]}"

for dest in "${DESTS[@]}"; do
  cid=$(container_for "$dest") || true
  # THE NIGHTLY ARM PINGS AND THE AD-HOC ONE MUST NOT — AND THIS GUARD SITS *ABOVE* THE
  # `if $TO_STDOUT` BRANCH BELOW, SO IT IS THE ONE PLACE THAT HAS TO SAY SO ITSELF. A vanished
  # container is a REAL failure of the nightly's backup and is knowable right now; leaving it to
  # the heartbeat window would report the one failure the job can name precisely as a generic
  # 25-hour silence. But `bin/backup-db` reaches this same line, and a manual run to someone's
  # laptop that pushes `status=down` marks the NIGHTLY as failing over a backup the nightly had
  # nothing to do with — the exact mirror of the rule 30 lines below, where an ad-hoc `up` would
  # paper over a nightly dead for a week. Both directions corrupt the same signal; both are refused.
  if [ -z "$cid" ]; then
    echo "!! $dest: no container found — skipped" >&2; status=1
    $TO_STDOUT || ping_kuma "$dest" down "no container matching this deployment" ""
    continue
  fi
  image=$(docker inspect --format '{{.Config.Image}}' "$cid")
  src=$(volume_for "$dest")

  if $TO_STDOUT; then
    # DELIBERATELY NO PING. An ad-hoc backup to someone's laptop is not the nightly, and letting it
    # touch the heartbeat would let a manual run paper over a nightly that has been dead for a
    # week — the monitor would read healthy for exactly as long as someone kept rescuing it by hand.
    docker run --rm --user 0 -v "$src:/src" "$image" sh -c "$WORKER" _ ""
  else
    echo "==> $dest"
    began=$(date +%s)
    if summary=$(docker run --rm --user 0 -v "$src:/src" -v "$OUT_VOLUME:/dst" "$image" \
         sh -c "$WORKER" _ "/dst/tinkerex-$dest-$STAMP.tar.gz"); then
      echo "$summary"
      ping_kuma "$dest" up "$(echo "$summary" | tr -s ' ' | sed 's/^ //')" "$(( ($(date +%s) - began) * 1000 ))"
      # PRUNE ONLY AFTER A VERIFIED WRITE, and only ever files this script names. `ls -t | tail -n
      # +N+1` keeps the N newest; with fewer than N present it selects nothing, so a fresh install
      # cannot delete its own first backup. A failed run above skips this entirely — the one thing
      # worse than a missing backup is a working one aged out by a broken run.
      # $KEEP IS ALREADY KNOWN TO BE AN INTEGER >= 1 — see the guard at the top, which is where it
      # belongs, since this runs after the `up` ping. Do NOT add a second check in here: one rule
      # living in two places, and eventually disagreeing, is this file's opening argument.
      docker run --rm --user 0 -v "$OUT_VOLUME:/dst" "$image" sh -eu -c '
        keep=$1; dest=$2
        cd /dst
        ls -1t "tinkerex-$dest-"*.tar.gz 2>/dev/null | tail -n +$((keep + 1)) | while read -r old; do
          echo "    pruned $old"; rm -f -- "$old"
        done
        rm -f "tinkerex-$dest-"*.tar.gz.partial
      ' _ "$KEEP" "$dest"
    else
      # `status=down` NOW rather than waiting for the heartbeat window to lapse: a backup that runs
      # and fails is knowable within seconds, and making you wait 25 hours to hear about it would
      # throw away the one case the job can actually report on itself.
      echo "!! $dest: FAILED" >&2; status=1
      ping_kuma "$dest" down "backup failed — see ~/tinkerex-ops/backup.log" ""
    fi
  fi
done

$TO_STDOUT || echo "== $(date -u +%Y-%m-%dT%H:%M:%SZ) finished, status=$status"
exit $status
