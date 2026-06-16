#!/usr/bin/env bash
#
# smoke.sh — pre-flight / post-cutover smoke check against a server pointed at R2.
#
# Runs the existing presigned_roundtrip example (device A -> presigned PUT to R2 ->
# device B pulls + hydrates via presigned GET -> byte-for-byte compare) and confirms
# the "PRESIGNED ROUNDTRIP OK" line. This proves the REAL production data plane works
# against R2: presign (server) + PUT/GET (client <-> R2) + head_object verify.
#
# The client only needs SERVER_URL; the store is decided by the SERVER's STORAGE_BACKEND
# + CHUNK_* env. So to smoke R2 you point the SERVER at R2 and run this — no client
# change (docs/r2-migration.md §3.4 / §5).
#
# Usage:
#   SERVER_URL=https://<your-server> ./smoke.sh
#
set -euo pipefail

SERVER_URL="${SERVER_URL:?set SERVER_URL to the Rails server pointed at R2, e.g. https://maker.example.com}"

# Locate the repo root + the sync-engine crate (script lives in scripts/r2-cutover/).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
ENGINE_DIR="$REPO_ROOT/client/sync-engine"

[ -d "$ENGINE_DIR" ] || { echo "sync-engine crate not found at $ENGINE_DIR" >&2; exit 1; }

echo "================================================================"
echo " R2 pre-flight smoke: presigned_roundtrip against the data plane"
echo "   SERVER_URL=$SERVER_URL"
echo "   (the server must be configured STORAGE_BACKEND=s3 + R2 CHUNK_*)"
echo "================================================================"
echo "Running the example (this pushes one real chunk to R2 and reads it back)..."

# Capture output so we can assert on the success line and fail loudly otherwise.
out="$(cd "$ENGINE_DIR" && SERVER_URL="$SERVER_URL" cargo run --quiet --example presigned_roundtrip 2>&1)" || {
  echo "$out"
  echo ""
  echo "SMOKE FAILED: the example exited non-zero. R2 data plane is NOT verified." >&2
  exit 1
}

echo "$out"

if grep -q "PRESIGNED ROUNDTRIP OK" <<<"$out"; then
  echo ""
  echo "SMOKE OK — real bytes round-tripped through R2 byte-for-byte. Safe to proceed."
else
  echo ""
  echo "SMOKE FAILED: did not see 'PRESIGNED ROUNDTRIP OK'. R2 data plane is NOT verified." >&2
  exit 1
fi
