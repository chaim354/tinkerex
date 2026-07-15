#!/usr/bin/env bash
#
# migrate-chunks.sh — copy the content-addressed `chunks/` keyspace between the
# SeaweedFS source store and a Cloudflare R2 bucket, using rclone.
#
# WHY THIS IS SAFE TO RE-RUN:
#   Chunks are immutable + content-addressed: every object lives at
#   chunks/<user_id>/<sha256> and the bytes EQUAL their hash (docs/r2-migration.md §3.5).
#   So a migration is an idempotent copy of a keyspace:
#     - `rclone copy` only transfers objects missing/different at the destination,
#       so re-running fills gaps (resumable) and a finished run is a no-op.
#     - `rclone check` compares hashes; content-addressing makes a hash match
#       authoritative proof the destination object is the right bytes.
#     - The SOURCE is never modified by `copy`/`check`, so rollback data stays intact.
#
# rclone remotes are configured ENTIRELY via env vars (RCLONE_CONFIG_<NAME>_*), so:
#     - no rclone.conf file is read or written,
#     - no secrets are passed on the command line (they live in env), and
#     - we avoid the `:backend,opt=val:path` connection-string colon-parsing pitfall.
#
# DO NOT hardcode secrets. All endpoints/creds come from the environment (see
# r2.env.example). This script touches storage only; it never touches the server.
#
set -euo pipefail

# Only the content-addressed chunk keyspace moves — nothing else in the bucket.
PREFIX="${CHUNK_PREFIX:-chunks}"

# Throughput knobs (override via env if needed).
TRANSFERS="${RCLONE_TRANSFERS:-32}"
CHECKERS="${RCLONE_CHECKERS:-64}"

# Paths are display-only until configure() validates the creds (so `help` needs no env).
SEAWEED_PATH="seaweed:${SEAWEED_BUCKET:-<SEAWEED_BUCKET>}/${PREFIX}"
R2_PATH="r2:${R2_BUCKET:-<R2_BUCKET>}/${PREFIX}"

# configure() — validate creds (from env; source r2.env first) and wire the rclone
# remotes ENTIRELY via env vars (no rclone.conf, no connection-string parsing). Called
# only by commands that actually touch storage, so `help` works without any env set.
configure() {
  # SeaweedFS (source) — the store config/deploy.yml currently points at.
  : "${SEAWEED_ENDPOINT:?set SEAWEED_ENDPOINT, e.g. http://192.168.1.8:8333}"
  : "${SEAWEED_BUCKET:?set SEAWEED_BUCKET, e.g. my-bucket}"
  : "${SEAWEED_ACCESS_KEY_ID:?set SEAWEED_ACCESS_KEY_ID}"
  : "${SEAWEED_SECRET_ACCESS_KEY:?set SEAWEED_SECRET_ACCESS_KEY}"
  local seaweed_region="${SEAWEED_REGION:-us-east-1}"

  # Cloudflare R2 (destination).
  : "${R2_ENDPOINT:?set R2_ENDPOINT, e.g. https://<ACCOUNT_ID>.r2.cloudflarestorage.com}"
  : "${R2_BUCKET:?set R2_BUCKET, e.g. maker-chunks-prod}"
  : "${R2_ACCESS_KEY_ID:?set R2_ACCESS_KEY_ID (R2 token Access Key ID)}"
  : "${R2_SECRET_ACCESS_KEY:?set R2_SECRET_ACCESS_KEY (R2 token Secret Access Key)}"
  local r2_region="${R2_REGION:-auto}"

  # Remote names: "seaweed" and "r2" → env keys RCLONE_CONFIG_SEAWEED_* / _R2_*.
  export RCLONE_CONFIG_SEAWEED_TYPE="s3"
  export RCLONE_CONFIG_SEAWEED_PROVIDER="Other"
  export RCLONE_CONFIG_SEAWEED_ENDPOINT="$SEAWEED_ENDPOINT"
  export RCLONE_CONFIG_SEAWEED_ACCESS_KEY_ID="$SEAWEED_ACCESS_KEY_ID"
  export RCLONE_CONFIG_SEAWEED_SECRET_ACCESS_KEY="$SEAWEED_SECRET_ACCESS_KEY"
  export RCLONE_CONFIG_SEAWEED_REGION="$seaweed_region"
  export RCLONE_CONFIG_SEAWEED_FORCE_PATH_STYLE="true"

  export RCLONE_CONFIG_R2_TYPE="s3"
  export RCLONE_CONFIG_R2_PROVIDER="Cloudflare"
  export RCLONE_CONFIG_R2_ENDPOINT="$R2_ENDPOINT"
  export RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
  export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
  export RCLONE_CONFIG_R2_REGION="$r2_region"

  SEAWEED_PATH="seaweed:${SEAWEED_BUCKET}/${PREFIX}"
  R2_PATH="r2:${R2_BUCKET}/${PREFIX}"
}

usage() {
  cat <<EOF
Usage: $0 <command>

Commands (run in this order for a cutover):
  dry-run     Show what the bulk SeaweedFS -> R2 copy WOULD transfer (no writes).
  copy        Bulk copy SeaweedFS -> R2 (idempotent/resumable; source untouched).
  check       Verify SeaweedFS == R2 by hash (authoritative for content-addressed data).
  incremental Final top-up copy SeaweedFS -> R2 (run right AFTER the cutover flip to
              catch chunks written during the bulk copy window). Same as 'copy'; named
              for the runbook step.
  rollback    Reverse copy R2 -> SeaweedFS (backfill chunks that landed ONLY in R2 during
              the R2 window, BEFORE reverting the server env). Source (R2) untouched.

Source: ${SEAWEED_PATH}
Dest:   ${R2_PATH}

All endpoints/creds come from env (see r2.env.example). NEVER hardcode secrets.
EOF
}

# Loud banner so an operator always sees direction + paths before bytes move.
announce() {
  echo "================================================================"
  echo " rclone $1"
  echo "   FROM: $2"
  echo "   TO:   $3"
  echo "   transfers=${TRANSFERS} checkers=${CHECKERS}"
  echo "================================================================"
}

cmd="${1:-}"
case "$cmd" in
  dry-run)
    configure
    announce "copy --dry-run (NO WRITES)" "$SEAWEED_PATH" "$R2_PATH"
    rclone copy --dry-run --progress \
      --transfers="$TRANSFERS" --checkers="$CHECKERS" \
      "$SEAWEED_PATH" "$R2_PATH"
    echo "Dry-run complete. Nothing was written. Re-run with 'copy' to transfer."
    ;;
  copy|incremental)
    configure
    announce "copy (idempotent/resumable)" "$SEAWEED_PATH" "$R2_PATH"
    rclone copy --progress \
      --transfers="$TRANSFERS" --checkers="$CHECKERS" \
      "$SEAWEED_PATH" "$R2_PATH"
    echo "Copy complete (source untouched). Run '$0 check' to verify by hash."
    ;;
  check)
    configure
    announce "check (hash-authoritative)" "$SEAWEED_PATH" "$R2_PATH"
    # --checkers parallelism; default check compares size + hash. Content-addressed
    # data means a hash match == correct bytes. Non-zero exit on any mismatch.
    rclone check --checkers="$CHECKERS" "$SEAWEED_PATH" "$R2_PATH"
    echo "Check passed: every source chunk exists in R2 with a matching hash."
    ;;
  rollback)
    configure
    announce "ROLLBACK copy R2 -> SeaweedFS (backfill R2-only chunks)" "$R2_PATH" "$SEAWEED_PATH"
    echo "This backfills SeaweedFS with any chunks written ONLY to R2 during the R2"
    echo "window. Run this BEFORE reverting the server env, then verify, then revert."
    rclone copy --progress \
      --transfers="$TRANSFERS" --checkers="$CHECKERS" \
      "$R2_PATH" "$SEAWEED_PATH"
    echo "Rollback backfill complete. Verify with: rclone check $R2_PATH $SEAWEED_PATH"
    ;;
  ""|-h|--help|help)
    usage
    ;;
  *)
    echo "Unknown command: $cmd" >&2
    usage >&2
    exit 2
    ;;
esac
