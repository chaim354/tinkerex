#!/bin/bash
# BUILD-TIME capability assertion (spec §4). OpenSCAD's Manifold backend and 3MF export are both
# COMPILE-TIME OPTIONAL, and a build missing either looks completely healthy at runtime — 3MF export
# without lib3mf writes nothing and still exits 0, and a CGAL fallback is only visible as slowness
# (measured 20x+ on grid-shaped models, which is exactly this addon's workload). So: assert, never
# assume. `set -e` makes any failure fail the docker build.
set -euo pipefail

# Assert against $OPENSCAD_BIN — the exact path render.py execs — not the raw binary underneath it.
# In the image that is the wrapper that scopes the AppImage's bundled libs to this one process (see
# the Dockerfile); a broken wrapper would otherwise leave all six assertions green and the sidecar
# dead. The fallback keeps this script runnable standalone against a bare extraction, which is what
# needs the LD_LIBRARY_PATH export below — the wrapper sets it itself.
BIN="${OPENSCAD_BIN:-/opt/openscad/usr/bin/openscad}"
export LD_LIBRARY_PATH=/opt/openscad/usr/lib

fail() { echo "CAPABILITY ASSERTION FAILED: $*" >&2; exit 1; }

# --- 1. the binary runs at all -------------------------------------------------------------------
# --version, NOT --info: --info constructs a GL OffscreenView and exits 1 with no X server, so it
# would fail here for a reason that has nothing to do with capabilities.
VERSION="$("$BIN" --version 2>&1)" || fail "openscad --version exited nonzero: $VERSION"
echo "$VERSION" | grep -q "OpenSCAD version" || fail "unexpected --version output: $VERSION"
echo "assert: $VERSION"

# --- 2. --backend=manifold is a REAL, PARSED flag ------------------------------------------------
# A build that doesn't know the flag would ignore it and silently use CGAL. Prove the parser is live
# by checking that a BOGUS backend is rejected. If this exits 0, the flag is being ignored and the
# manifold assertion below would be meaningless.
if "$BIN" --backend=definitely-not-a-backend -o /tmp/bogus.3mf /probe.scad >/dev/null 2>&1; then
  fail "a bogus --backend was ACCEPTED — the flag is not parsed, so --backend=manifold proves nothing"
fi
echo "assert: --backend is parsed (bogus value rejected)"

# --- 3. the render actually USES manifold --------------------------------------------------------
# The strongest available signal, and much better than an exit code: OpenSCAD prints the backend it
# used — "Top level object is a 3D object (manifold)". A CGAL fallback prints something else.
OUT="$("$BIN" --backend=manifold -o /tmp/t.3mf /probe.scad 2>&1)" || fail "manifold render failed: $OUT"
echo "$OUT" | grep -q "(manifold)" || fail "render did NOT use manifold — likely a silent CGAL fallback. Output: $OUT"
echo "assert: render used the manifold backend"

# --- 4. 3MF export really wrote a 3MF ------------------------------------------------------------
# THE TRAP: a build without lib3mf logs "Export to 3MF format was not enabled when building the
# application", writes nothing, and EXITS 0. So exit code proves nothing here. A 3MF is an OPC/zip
# container, so the first two bytes must be the zip magic "PK".
[ -s /tmp/t.3mf ] || fail "3MF export produced no bytes (lib3mf missing? it exits 0 either way)"
[ "$(head -c2 /tmp/t.3mf)" = "PK" ] || fail "3MF output is not a zip container — got $(head -c2 /tmp/t.3mf | xxd -p)"
echo "assert: 3MF export wrote $(stat -c%s /tmp/t.3mf) bytes starting with the zip magic"

# --- 5. the Customizer parameter dump exists -----------------------------------------------------
# --export-format=param landed in 2021-08 and is NOT in the 2021.01 stable release (which is what
# every Debian suite ships). The whole "parameters come from OpenSCAD, not from us" design (spec
# §3.2) collapses without it, so a stale binary must fail the build rather than the first request.
"$BIN" --export-format=param -o /tmp/p.json /probe.scad >/dev/null 2>&1 || fail "--export-format=param not supported"
python3 - <<'PY' || exit 1
import json, sys
d = json.load(open("/tmp/p.json"))
names = {p["name"] for p in d.get("parameters", [])}
missing = {"cols", "rows", "wall"} - names
if missing:
    sys.exit(f"CAPABILITY ASSERTION FAILED: param dump missing {missing}; got {sorted(names)}")
PY
echo "assert: --export-format=param dumped the Customizer schema"

# --- 6. parameter INJECTION works ----------------------------------------------------------------
# Rendering with the defaults is useless for a parametric generator. Prove -p/-P actually changes the
# geometry: 9x2=18 cells must not produce the same bytes as the default 4x3=12.
printf '{"parameterSets":{"s":{"cols":"9","rows":"2"}},"fileFormatVersion":"1"}' > /tmp/set.json
"$BIN" -p /tmp/set.json -P s -o /tmp/inj.3mf /probe.scad >/dev/null 2>&1 || fail "-p/-P injection failed"
[ -s /tmp/inj.3mf ] || fail "-p/-P injection produced no bytes"
if cmp -s /tmp/t.3mf /tmp/inj.3mf; then
  fail "-p/-P produced byte-identical output — parameters are being IGNORED"
fi
echo "assert: -p/-P parameter injection changes the geometry"

rm -f /tmp/t.3mf /tmp/inj.3mf /tmp/p.json /tmp/set.json /tmp/bogus.3mf
echo "ALL CAPABILITY ASSERTIONS PASSED"
