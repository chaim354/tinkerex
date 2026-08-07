#!/usr/bin/env bash
# THE definition of how a backup is taken. Runs ON the Unraid VM; installed to
# /home/kamal1/tinkerex-ops/backup-db.sh by bin/backup-cron-install.
#
#   backup-db.sh --to-volume tinkerex_backups --keep 14 chunk share s3   # what cron runs
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
    chunk|share|s3) DESTS+=("$1"); shift ;;
    *) echo "usage: backup-db.sh (--to-volume NAME [--keep N] | --to-stdout) <chunk|share|s3>..." >&2; exit 64 ;;
  esac
done
[ ${#DESTS[@]} -gt 0 ] || { echo "no destinations given" >&2; exit 64; }
if $TO_STDOUT && [ ${#DESTS[@]} -ne 1 ]; then
  echo "--to-stdout takes exactly one destination (two archives cannot share one stream)" >&2; exit 64
fi
[ -n "$OUT_VOLUME" ] || $TO_STDOUT || { echo "need --to-volume or --to-stdout" >&2; exit 64; }

# `docker ps -a`, not `docker ps`: a STOPPED app container still names the image and the volume,
# and a nightly that skips a deployment because it happens to be down is a nightly that goes
# quiet exactly when it matters. Chunk is the base deployment, so its container is
# `tinkerex-web-<sha>` — the `[0-9a-f]` is what stops that prefix from also matching -share-/-s3-.
container_for() {
  case "$1" in
    chunk) docker ps -a -qf name='^tinkerex-web-[0-9a-f]' | head -1 ;;
    share) docker ps -a -qf name='^tinkerex-web-share-'   | head -1 ;;
    s3)    docker ps -a -qf name='^tinkerex-web-s3-'      | head -1 ;;
  esac
}
volume_for() {
  case "$1" in chunk) echo tinkerex_storage ;; share) echo tinkerex_storage_share ;; s3) echo tinkerex_storage_s3 ;; esac
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
  if [ -z "$cid" ]; then echo "!! $dest: no container found — skipped" >&2; status=1; continue; fi
  image=$(docker inspect --format '{{.Config.Image}}' "$cid")
  src=$(volume_for "$dest")

  if $TO_STDOUT; then
    docker run --rm --user 0 -v "$src:/src" "$image" sh -c "$WORKER" _ ""
  else
    echo "==> $dest"
    if docker run --rm --user 0 -v "$src:/src" -v "$OUT_VOLUME:/dst" "$image" \
         sh -c "$WORKER" _ "/dst/tinkerex-$dest-$STAMP.tar.gz"; then
      # PRUNE ONLY AFTER A VERIFIED WRITE, and only ever files this script names. `ls -t | tail -n
      # +N+1` keeps the N newest; with fewer than N present it selects nothing, so a fresh install
      # cannot delete its own first backup. A failed run above skips this entirely — the one thing
      # worse than a missing backup is a working one aged out by a broken run.
      docker run --rm --user 0 -v "$OUT_VOLUME:/dst" "$image" sh -eu -c '
        keep=$1; dest=$2
        cd /dst
        ls -1t "tinkerex-$dest-"*.tar.gz 2>/dev/null | tail -n +$((keep + 1)) | while read -r old; do
          echo "    pruned $old"; rm -f -- "$old"
        done
        rm -f "tinkerex-$dest-"*.tar.gz.partial
      ' _ "$KEEP" "$dest"
    else
      echo "!! $dest: FAILED" >&2; status=1
    fi
  fi
done

$TO_STDOUT || echo "== $(date -u +%Y-%m-%dT%H:%M:%SZ) finished, status=$status"
exit $status
