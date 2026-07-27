# OpenSCAD Sidecar Addon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a second `/tools` addon — a generic OpenSCAD engine that turns a parametric `.scad` file plus a form of its own parameters into a 3MF + params.json bundle in the user's library, with a working grid thumbnail.

**Architecture:** A GPL-2.0 Python/Flask sidecar (`sidecar/openscad`) execs the official OpenSCAD AppImage binary and exposes four JSON endpoints. Permissive Rails owns UI, auth, params and save-to-library, talking to it over HTTP via `OpenscadClient` — a direct clone of the proven `BoxesClient` shape. Bytes land in the library through the existing `Maker::Addons::LibraryOutput`; nothing in the sync/file layer is touched (spec §10 tripwire).

**Tech Stack:** Rails 8 + Hotwire (server-rendered ERB), Python 3.12 + Flask + gunicorn, OpenSCAD 2026.07.26 AppImage, Docker/Kamal accessory.

**Spec:** `docs/superpowers/specs/2026-07-27-openscad-sidecar-addon-design.md`. Read §2 (licensing) before adding any bundled generator.

---

## Verified facts this plan is built on

Every one of these was **observed** in a real `linux/amd64` container on 2026-07-27, not inferred. The
spec's §4 insists on this ("a build that looks right proves nothing"); these are the receipts. The
probe that produced them is reproduced as Task 2's build-time assertion.

| # | Fact | Evidence |
|---|---|---|
| F1 | AppImage pin: `https://files.openscad.org/snapshots/OpenSCAD-2026.07.26-x86_64.AppImage`, sha256 `570a39a199b443c2072312db458a405e18efe51d4c83756e76048ea1069d946c` | `sha256sum -c` → `os.AppImage: OK` |
| F2 | **There is NO `-latest-` alias.** A dated snapshot must be pinned; the "latest" pointer lives in `https://files.openscad.org/snapshots/.snapshots.js` (`LIN64_SNAPSHOT`) | fetched both |
| F3 | **`./x.AppImage --appimage-extract` FAILS on the Mac** — `Exec format error` (exit 126). The AppImage runtime is a static ELF and Docker Desktop's amd64 emulation refuses it. CLAUDE.md cross-builds every image on the Mac, so the Dockerfile must **never exec the AppImage** | probe v1 |
| F4 | **`unsquashfs -o <offset>` extracts it with no exec.** Offset = `e_shoff + e_shentsize*e_shnum` from the ELF header | probe v2 |
| F5 | Extracted layout is `squashfs-root/usr/bin/openscad` — plain name, **no** `-nightly` suffix | probe v2 `ls` |
| F6 | **`libgpg-error0` is the one and only apt package missing** from the excludelist-derived set. The AppImage bundles 113 libs under `usr/lib`; `LD_LIBRARY_PATH` must point there | probe v3 `ldd \| grep "not found"` → exactly one line; probe v4 → clean |
| F7 | `--version` → `OpenSCAD version 2026.07.26`. (**Do NOT smoke-test with `--info`** — it builds a GL context and exits 1 headless) | probe v4 |
| F8 | **Manifold is the DEFAULT.** With *and* without `--backend=manifold`, stdout says `Top level object is a 3D object (manifold)`. That literal string is a far stronger assertion than an exit code | probe v4 C + E |
| F9 | A bogus backend name is a **hard error**: `ERROR: Unknown rendering backend 'nosuchbackend'.`, exit 1. So `--backend=manifold` cannot silently degrade | probe v4 D |
| F10 | 3MF export works: 3091 bytes starting `PK` (zip magic). **Assert non-empty + `PK`, never exit code alone** — a lib3mf-less build logs a warning, writes nothing, and still exits **0** | probe v4 C |
| F11 | 20×20 = 400 cells renders in **160 ms** (spec §7 budgeted ~4 s from a wasm measurement — the native binary is ~25× faster). Sync execution is comfortably justified | probe v4 J |
| F12 | `--export-format=param` works and emits `{"title":…,"parameters":[…]}` — exact shape in §A below | probe v4 F |
| F13 | **A zero-parameter file omits the `parameters` key entirely** — `{"title":"empty"}`, not `[]` | probe v4 G |
| F14 | `-p <sets.json> -P <name>` injects params (verified by output geometry changing: 9×2=18 cells → 3881 bytes vs 4×3=12 → 3091). Values are **strings**, incl. `"[1,2,3]"` for a vector and `"false"` for a bool | probe v4 H |
| F16 | **OpenSCAD's 3MF output is NOT byte-reproducible.** Three renders of the same file with the same params gave 3096 / 3098 / 3099 bytes, and the inner `3D/3dmodel.model` differs too. The stable, parameter-determined signal is the **vertex count** (one cube = 8 vertices, so 4x3 -> 96 and 9x2 -> 144). **Never assert byte-equality across two fresh renders** — a cache HIT is fine, it replays stored bytes | measured in the built image |
| F15 | `include <../../etc/hostname>` resolves and reads outside the temp dir (fails only because it isn't valid SCAD). Spec §10's "accepted, documented" note is real, not theoretical | probe v4 L |

### §A — the exact `--export-format=param` JSON

Observed verbatim for a probe file exercising every type:

```json
{"parameters":[
  {"caption":"number of columns","group":"Grid","initial":4.0,"name":"cols","step":1.0,"type":"number"},
  {"group":"Walls","initial":1.6,"name":"wall","step":1.0,"type":"number"},
  {"group":"Walls","initial":true,"name":"rounded","type":"boolean"},
  {"group":"Walls","initial":"demo","name":"label","type":"string"},
  {"caption":"render mode","group":"Walls","initial":1.0,"name":"mode",
   "options":[{"name":"solid","value":1.0},{"name":"hollow","value":2.0}],"type":"number"},
  {"group":"Walls","initial":[10.0,20.0,30.0],"name":"span","type":"number"},
  {"group":"Walls","initial":"b","name":"choice",
   "options":[{"name":"a","value":"a"},{"name":"b","value":"b"},{"name":"c","value":"c"}],"type":"string"},
  {"group":"Walls","initial":5.0,"max":10.0,"min":1.0,"name":"ranged","step":1.0,"type":"number"}
],"title":"probe"}
```

**Five traps in that payload, each of which silently produces a wrong form:**

1. **`parameters` is ABSENT for a zero-param file** (F13). `data["parameters"]` → `None`, and
   `for p in None` raises. Use `data.get("parameters", [])`.
2. **A vector reports `"type":"number"` with a LIST `initial`.** There is no `"vector"` type. Branch
   on `isinstance(initial, list)`, *never* on `type`.
3. **An enum is `"type":"number"` or `"type":"string"` PLUS `options`.** Branch on the presence of
   `options` first, before looking at `type`.
4. **`caption` is present only when a `//` description comment precedes the assignment** (`wall`
   above has none). Fall back to the name.
5. **Everything numeric is a float** — `4.0`, not `4`. An int-looking param must be recognised by
   value (`float.is_integer()`), or every count renders as `4.0` in the form.

### §A2 — how OpenSCAD decides what is a parameter (affects the catalog + BYO)

Verified against OpenSCAD's `CommentParser.cc`/`ParameterObject.cc` via source review:

- **Top-level assignments in the MAIN file only** — `include`/`use` files contribute nothing.
- **Literal values only.** `x = 12;` is a parameter; `x = 6*2;` is **not**.
- **Collection stops at the first `{` character** in the file (outside strings/comments) — not "the
  first module", literally the first brace.
- `/* [Hidden] */` group is excluded entirely.
- `/* [Group] */` sets the group; `// text` on the **preceding** line sets the caption; `// [1:10]`
  on the **same** line sets range/options.

**Consequence for the catalog (Task 6):** a `.scad` whose parameters are computed expressions, or
which opens a `{` early, will expose few or no parameters. Candidate files must be checked for this,
not assumed.

---

## File structure

**New — sidecar (GPL-2.0, never imported by `app/`):**

| Path | Responsibility |
|---|---|
| `sidecar/openscad/Dockerfile` | AppImage fetch + sha256 pin + exec-free extraction + **build-time capability assertion** |
| `sidecar/openscad/app.py` | Flask API: `/up`, `/generators`, `/source/<key>`, `/params`, `/render` |
| `sidecar/openscad/schema.py` | OpenSCAD param JSON → the normalized schema Rails renders |
| `sidecar/openscad/render.py` | subprocess exec, temp dir, timeout, memory cap, content-addressed cache |
| `sidecar/openscad/catalog/` | vendored permissive `.scad` files + `catalog.json` + `NOTICE` |
| `sidecar/openscad/{LICENSE,README.md,requirements.txt,.dockerignore,.gitignore}` | licence + isolation posture |
| `sidecar/openscad/tests/{test_schema.py,test_api.py}` | pytest (run by hand, as boxes does) |

**New — Rails (permissive):**

| Path | Responsibility |
|---|---|
| `app/services/openscad_client.rb` | typed HTTP client; `configured?` gates addon availability |
| `app/controllers/tools/openscad_controller.rb` | `index`/`new`/`preview`/`create`/`show` |
| `app/helpers/tools/openscad_helper.rb` | prefill-path helper (the `:params` url_for trap) |
| `app/views/tools/openscad/{index,new,show}.html.erb`, `_form`, `_field` | UI, cloned from `tools/boxes` |
| `bin/build-openscad-sidecar` | build + push the sidecar image |
| `test/support/fake_openscad.rb` | PORO stub |
| `test/services/openscad_client_test.rb`, `test/controllers/tools/openscad_controller_test.rb`, `test/integration/tools/openscad_live_test.rb` | tests |

**Modified:** `.dockerignore` (+`/sidecar/`), `config/deploy.yml` (accessory + env), `config/deploy.ovh.yml` (clear both sidecar URLs), `config/routes.rb`, `app/services/maker/addons/registry.rb` (one entry), `docs/STATUS.md`, `docs/addon-backlog.md`.

**Deliberately NOT modified:** `Maker::Addons::LibraryOutput`, `Maker::AddonState`, `Maker::AddonFile`. Spec §6 — if a task needs to change these, the addon framework's central claim is wrong and that must be surfaced rather than patched around.

---

## Task 1: Fix the two pre-existing bugs (spec §8.1)

Neither is caused by this feature; both would be inherited by it. Doing them first means the new
sidecar is added to a clean base.

**Files:**
- Modify: `.dockerignore`
- Modify: `config/deploy.ovh.yml`
- Test: `test/deploy_hygiene_test.rb` (create)

**Bug 1 — GPL source ships inside the permissive Rails image.** `Dockerfile:47` is `COPY . .` and
`.dockerignore` excludes `/docs/`, `/test/`, `/ci/`, `/scripts/`, `/client/` but **not `/sidecar/`**.
The GPL-3.0 boxes tree is baked into the app image today (8 tracked files). Never imported, never
executed — but it *ships*, which is exactly what CLAUDE.md §9 forbids. About to get worse: this plan
adds a second GPL tree.

**Bug 2 — `deploy.ovh.yml` inherits a dead sidecar hostname.** Kamal deep-merges `env.clear` (a
hash), so the OVH overlay silently inherits `BOXES_SIDECAR_URL: http://tinkerex-boxes:8000`. That
name does not resolve there — the accessory's `host:` is the Unraid IP. So the addon reports
`configured? == true` and then fails on **every** call, which is strictly worse than showing
unavailable. (Contrast `env.secret`, an array, which Kamal *replaces* — the overlay's own comment
already documents that asymmetry.)

- [ ] **Step 1: Write the failing test**

Create `test/deploy_hygiene_test.rb`:

```ruby
require "test_helper"

# Guards two deployment invariants that no other test can see, because both live in files the Rails
# process never loads. Both were real, shipped bugs (spec §8.1).
class DeployHygieneTest < ActiveSupport::TestCase
  ROOT = Rails.root

  test "the GPL sidecar tree is excluded from the permissive Rails image" do
    # Dockerfile:47 is `COPY . .`, so anything not ignored is baked into the app image. CLAUDE.md §9:
    # no copyleft in our shipped artifacts. sidecar/boxes is GPL-3.0 and sidecar/openscad is GPL-2.0.
    ignore = ROOT.join(".dockerignore").read.lines.map(&:strip)
    assert_includes ignore, "/sidecar/",
                    "add `/sidecar/` to .dockerignore — `COPY . .` ships the GPL sidecars otherwise"
  end

  test "the OVH overlay clears every sidecar URL it cannot reach" do
    # Kamal DEEP-MERGES env.clear (a hash), so the overlay inherits deploy.yml's sidecar hostnames.
    # Those resolve only on the Unraid host, where the accessories actually run. Inheriting one makes
    # `configured?` true and every call fail — worse than the addon showing as unavailable.
    base    = YAML.load_file(ROOT.join("config/deploy.yml"),     aliases: true)
    overlay = YAML.load_file(ROOT.join("config/deploy.ovh.yml"), aliases: true)
    base_urls = base.dig("env", "clear").to_h.keys.grep(/_SIDECAR_URL\z/)
    assert base_urls.any?, "expected deploy.yml to define at least one *_SIDECAR_URL"

    cleared = overlay.dig("env", "clear").to_h
    base_urls.each do |key|
      assert cleared.key?(key), "deploy.ovh.yml must explicitly clear #{key} (it deep-merges otherwise)"
      assert cleared[key].blank?, "#{key} must be blank in the OVH overlay, got #{cleared[key].inspect}"
    end
  end
end
```

- [ ] **Step 2: Run it and watch both fail**

```bash
bin/rails test test/deploy_hygiene_test.rb
```

Expected: **2 failures** — `add \`/sidecar/\` to .dockerignore…` and `deploy.ovh.yml must explicitly clear BOXES_SIDECAR_URL…`.

- [ ] **Step 3: Fix `.dockerignore`**

Append after the `/scripts/` line:

```
# GPL sidecar images (sidecar/boxes = GPL-3.0, sidecar/openscad = GPL-2.0) are built + pushed
# SEPARATELY, each from its own directory as build context. The Rails Dockerfile does `COPY . .`,
# so without this line the copyleft trees are baked into the PERMISSIVE app image — never imported
# or executed, but shipped, which is exactly what CLAUDE.md §9 exists to prevent.
/sidecar/
```

- [ ] **Step 4: Fix `config/deploy.ovh.yml`**

Inside the existing `env: clear:` block, append:

```yaml
    # Sidecar accessories run on the UNRAID host (see `accessories:` in deploy.yml, whose `host:` is
    # 192.168.1.95), so `tinkerex-boxes` / `tinkerex-openscad` do not resolve on this box. Kamal
    # DEEP-MERGES env.clear, so without these explicit blanks the overlay inherits the Unraid
    # hostnames, each addon reports configured? == true, and every call fails — strictly worse than
    # the addon greying out. Blank -> `configured?` is false -> "Unavailable here". Set these to a
    # real URL if a sidecar is ever booted on OVH.
    BOXES_SIDECAR_URL: ""
    OPENSCAD_SIDECAR_URL: ""
```

- [ ] **Step 5: Run the test again**

```bash
bin/rails test test/deploy_hygiene_test.rb
```

Expected: `2 runs, 3 assertions, 0 failures, 0 errors`.

> Note: the second test asserts over **whatever `*_SIDECAR_URL` keys `deploy.yml` defines**, so it
> starts guarding `OPENSCAD_SIDECAR_URL` automatically the moment Task 12 adds it. That is why it is
> written as a loop over discovered keys rather than two hard-coded assertions.

- [ ] **Step 6: Commit**

```bash
git add .dockerignore config/deploy.ovh.yml test/deploy_hygiene_test.rb
git commit -m "fix(deploy): keep GPL sidecars out of the app image; clear dead sidecar URLs on OVH

Two pre-existing bugs found while surveying the boxes sidecar (spec §8.1):

1. .dockerignore excluded /docs/, /test/, /ci/, /scripts/ and /client/ but not
   /sidecar/, and the Rails Dockerfile does \`COPY . .\` — so the GPL-3.0 boxes
   tree was baked into the permissive app image. Never imported or executed, but
   shipped, which CLAUDE.md §9 exists to prevent.

2. Kamal deep-merges env.clear, so deploy.ovh.yml silently inherited
   BOXES_SIDECAR_URL=http://tinkerex-boxes:8000 — a name that only resolves on
   the Unraid host where the accessory runs. The addon reported configured? ==
   true and then failed on every call, which is worse than showing unavailable.

Guarded by test/deploy_hygiene_test.rb, which reads both files directly since
neither is loaded by the Rails process. The URL test loops over the keys
deploy.yml actually defines, so it covers OPENSCAD_SIDECAR_URL on arrival."
```

---

## Task 2: The sidecar image — capabilities asserted at build time

**Files:**
- Create: `sidecar/openscad/Dockerfile`, `sidecar/openscad/assert-capabilities.sh`, `sidecar/openscad/probe.scad`, `sidecar/openscad/.dockerignore`, `sidecar/openscad/.gitignore`

This is spec §4's core demand: *"the Dockerfile MUST assert both capabilities at build time … A
silently-CGAL image is the failure mode this guards, and it is invisible at runtime except as
slowness."* Every assertion below is one the probe already proved distinguishes pass from fail.

- [ ] **Step 1: Write the capability assertion script**

Create `sidecar/openscad/assert-capabilities.sh`:

```bash
#!/bin/bash
# BUILD-TIME capability assertion (spec §4). OpenSCAD's Manifold backend and 3MF export are both
# COMPILE-TIME OPTIONAL, and a build missing either looks completely healthy at runtime — 3MF export
# without lib3mf writes nothing and still exits 0, and a CGAL fallback is only visible as slowness
# (measured 20x+ on grid-shaped models, which is exactly this addon's workload). So: assert, never
# assume. `set -e` makes any failure fail the docker build.
set -euo pipefail

BIN=/opt/openscad/usr/bin/openscad
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
```

- [ ] **Step 2: Write the probe model the assertions render**

Create `sidecar/openscad/probe.scad`:

```scad
// Build-time probe ONLY — not a catalog generator, never served to users.
// Deliberately shaped like this addon's real workload (a grid), and deliberately exercises the
// Customizer: three top-level LITERAL assignments with description comments, all before the first
// `{` character (OpenSCAD stops collecting parameters at that brace).
/* [Probe] */
// number of columns
cols = 4;
// number of rows
rows = 3;
// wall thickness in mm
wall = 2;

module plate() {
    for (i = [0:cols - 1], j = [0:rows - 1])
        translate([i * 10, j * 10, 0]) cube([8, 8, wall]);
}

plate();
```

- [ ] **Step 3: Write the Dockerfile**

Create `sidecar/openscad/Dockerfile`:

```dockerfile
# openscad-sidecar — GPL-2.0 image (ships OpenSCAD; see LICENSE / README.md). Internal-only; the
# permissive Rails app calls it over HTTP on the kamal network and never links it. Built + pushed
# SEPARATELY from the Rails app image (bin/build-openscad-sidecar).
FROM python:3.12-slim

# THE PIN. There is deliberately no "latest" here, for two reasons: openscad.org publishes no
# `-latest-` alias at all (the nightly pointer lives in snapshots/.snapshots.js), and an unpinned
# geometry engine would silently change users' output between rebuilds. Bump both lines together;
# .sha256 sits beside every file on the server.
ARG OPENSCAD_VERSION=2026.07.26
ARG OPENSCAD_SHA256=570a39a199b443c2072312db458a405e18efe51d4c83756e76048ea1069d946c

# Runtime libs. The AppImage bundles 113 of its own (Qt6, lib3mf, boost, cairo…) under usr/lib, so
# this list is only what linuxdeploy's excludelist leaves to the host. It was derived by running
# `ldd` on the extracted binary and installing exactly what came back "not found" — libgpg-error0
# was the single gap, and it is easy to miss because python:3.12-slim is more minimal than the
# excludelist assumes. libasound2 was renamed libasound2t64 in the trixie time64 transition, hence
# the fallback: a hardcoded name breaks on one suite or the other.
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
      curl ca-certificates squashfs-tools \
      libgl1 libglx-mesa0 libegl1 libglvnd0 libopengl0 libglapi-mesa libgbm1 libdrm2 \
      libx11-6 libx11-xcb1 libxcb1 libxcb-dri2-0 libxcb-dri3-0 libxcb-cursor0 \
      libwayland-client0 fontconfig libfontconfig1 libfreetype6 libharfbuzz0b \
      libfribidi0 libexpat1 libuuid1 zlib1g libice6 libsm6 libusb-1.0-0 libgmp10 \
      libstdc++6 libgcc-s1 libgpg-error0 \
    && (apt-get install -y --no-install-recommends libasound2t64 \
        || apt-get install -y --no-install-recommends libasound2) \
    && rm -rf /var/lib/apt/lists/*

# Fetch + verify + extract. NOTE THE EXTRACTION METHOD: `./x.AppImage --appimage-extract` is the
# documented way and it DOES NOT WORK HERE — the AppImage runtime is a static ELF and Docker
# Desktop's amd64 emulation rejects it with "Exec format error" (exit 126). Every image in this repo
# is cross-built on an arm64 Mac (CLAUDE.md §13), so the build must never EXEC the downloaded
# binary. A type-2 AppImage is just an ELF with a squashfs appended at
# e_shoff + e_shentsize*e_shnum, so unsquashfs reads it directly with no execution at all.
WORKDIR /opt
RUN curl -fsSL -o os.AppImage \
      "https://files.openscad.org/snapshots/OpenSCAD-${OPENSCAD_VERSION}-x86_64.AppImage" && \
    echo "${OPENSCAD_SHA256}  os.AppImage" | sha256sum -c - && \
    OFFSET=$(python3 -c "\
import struct;\
f=open('os.AppImage','rb');\
f.seek(0x28); shoff=struct.unpack('<Q', f.read(8))[0];\
f.seek(0x3a); ent,num=struct.unpack('<HH', f.read(4));\
print(shoff+ent*num)") && \
    unsquashfs -q -o "$OFFSET" -d /opt/openscad os.AppImage && \
    rm os.AppImage && \
    apt-get purge -y curl squashfs-tools && apt-get autoremove -y

# The bundled Qt6/lib3mf/boost libraries live here; AppRun would normally set this. We invoke the
# binary directly (AppRun also exports PYTHONHOME into the AppDir's own Python 3.10, which would
# fight this image's 3.12), so the sidecar sets it explicitly instead.
ENV LD_LIBRARY_PATH=/opt/openscad/usr/lib
# Qt is linked in and resolves its plugins at startup even for a pure-CPU export. Cheap insurance
# against a headless container: no X server is needed for 3MF (only PNG preview builds a GL context).
ENV QT_QPA_PLATFORM=offscreen
ENV OPENSCAD_BIN=/opt/openscad/usr/bin/openscad

# THE BUILD-TIME CAPABILITY ASSERTION (spec §4). Manifold and 3MF are compile-time optional and a
# build missing either is invisible at runtime — 3MF without lib3mf writes nothing and exits 0.
# `set -e` in the script means any failure fails this RUN and therefore the whole build.
COPY probe.scad /probe.scad
COPY assert-capabilities.sh /assert-capabilities.sh
RUN chmod +x /assert-capabilities.sh && /assert-capabilities.sh

WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY catalog/ ./catalog/
COPY *.py ./

# The render cache (spec §5.1) lives on a mounted volume; create it so an unmounted run still works.
RUN mkdir -p /cache
ENV OPENSCAD_CACHE_DIR=/cache

EXPOSE 8000
# --timeout 120 must stay ABOVE the 60 s per-render timeout in render.py. Gunicorn's timeout kills
# the WORKER, so setting it at or below the render timeout means a slow render is reported as a
# worker crash instead of the clean 422 the app knows how to display.
CMD ["gunicorn", "-b", "0.0.0.0:8000", "-w", "2", "--timeout", "120", "app:app"]
```

- [ ] **Step 4: Write the supporting files**

`sidecar/openscad/requirements.txt`:

```
flask==3.1.0
gunicorn==23.0.0
```

`sidecar/openscad/.dockerignore`:

```
tests/
.venv/
__pycache__/
*.pyc
```

`sidecar/openscad/.gitignore`:

```
.venv/
__pycache__/
*.pyc
```

- [ ] **Step 5: Prove the assertion PASSES on a good build**

```bash
docker buildx build --platform linux/amd64 --progress=plain -t openscad-sidecar sidecar/openscad
```

Expected, near the end of the output:

```
assert: OpenSCAD version 2026.07.26
assert: --backend is parsed (bogus value rejected)
assert: render used the manifold backend
assert: 3MF export wrote 3091 bytes starting with the zip magic
assert: --export-format=param dumped the Customizer schema
assert: -p/-P parameter injection changes the geometry
ALL CAPABILITY ASSERTIONS PASSED
```

- [ ] **Step 6: Prove the assertion FAILS when a capability is missing**

Spec §13-1 requires the assertion "demonstrably fails if either is missing". An assertion never seen
to fail is not known to work — this is the same lesson as the `FakeS3` bug in CLAUDE.md §12 step 10.
Simulate a build whose OpenSCAD lacks Manifold, by shadowing the version check with one that reports
CGAL:

```bash
cd sidecar/openscad
sed 's/grep -q "(manifold)"/grep -q "(NOT-GOING-TO-MATCH)"/' assert-capabilities.sh > /tmp/broken.sh
docker buildx build --platform linux/amd64 --progress=plain \
  --build-arg NOPE=1 -f - . <<'EOF' 2>&1 | tail -20
EOF
```

Simpler and sufficient — run the shadowed script against the already-built image:

```bash
docker run --rm -v /tmp/broken.sh:/broken.sh --entrypoint bash openscad-sidecar \
  -c 'chmod +x /broken.sh && /broken.sh'; echo "EXIT=$?"
```

Expected:

```
CAPABILITY ASSERTION FAILED: render did NOT use manifold — likely a silent CGAL fallback. Output: ...
EXIT=1
```

Then delete `/tmp/broken.sh`. Record in the commit message that the negative case was observed.

- [ ] **Step 7: Commit**

```bash
git add sidecar/openscad/
git commit -m "feat(openscad): GPL-isolated sidecar image with build-time capability assertions

Extracts the official OpenSCAD 2026.07.26 AppImage (sha256-pinned) into a
python:3.12-slim base and asserts, AT BUILD TIME, the two capabilities the addon
depends on. Both are compile-time optional in OpenSCAD and both fail invisibly:

  - 3MF export without lib3mf writes NOTHING and still exits 0, so the assertion
    checks for non-empty output starting with the zip magic 'PK', never the exit
    code.
  - A missing Manifold backend silently falls back to CGAL, which is 20x+ slower
    on exactly the grid-shaped models this addon exists to render. The assertion
    greps stdout for '(manifold)' and separately proves the --backend flag is
    parsed at all by checking a bogus value is REJECTED — otherwise
    --backend=manifold would prove nothing.

Extraction deliberately does NOT exec the AppImage: --appimage-extract dies with
'Exec format error' under Docker Desktop's amd64 emulation on the arm64 Mac that
cross-builds every image here (CLAUDE.md §13). A type-2 AppImage is an ELF with
squashfs appended at e_shoff + e_shentsize*e_shnum, so unsquashfs reads it with
no execution.

The apt list is what \`ldd\` on the extracted binary actually reported missing —
libgpg-error0 was the only gap (the AppImage bundles 113 libs of its own).
libasound2 needs the t64 fallback for trixie.

Verified both ways: the assertions pass on a good build, and a shadowed script
simulating a CGAL fallback fails the build with a named error."
```

---

## Task 3: Schema normalization (`schema.py`)

**Files:**
- Create: `sidecar/openscad/schema.py`
- Test: `sidecar/openscad/tests/test_schema.py`

This is where §A's five traps get handled. Pure functions, no subprocess — so it is fast to test and
is where the real logic risk lives.

- [ ] **Step 1: Write the failing tests**

Create `sidecar/openscad/tests/test_schema.py`:

```python
"""Schema normalization. Every fixture here is REAL --export-format=param output, captured from
OpenSCAD 2026.07.26 in a container — not hand-invented. A fake built from the same misunderstanding
as the code confirms the misunderstanding (CLAUDE.md §12 step 10, the FakeS3 lesson)."""
from schema import normalize

# Captured verbatim from `openscad --export-format=param` on a probe exercising every type.
REAL_DUMP = {
    "title": "probe",
    "parameters": [
        {"caption": "number of columns", "group": "Grid", "initial": 4.0, "name": "cols",
         "step": 1.0, "type": "number"},
        {"group": "Walls", "initial": 1.6, "name": "wall", "step": 1.0, "type": "number"},
        {"group": "Walls", "initial": True, "name": "rounded", "type": "boolean"},
        {"group": "Walls", "initial": "demo", "name": "label", "type": "string"},
        {"caption": "render mode", "group": "Walls", "initial": 1.0, "name": "mode",
         "options": [{"name": "solid", "value": 1.0}, {"name": "hollow", "value": 2.0}],
         "type": "number"},
        {"group": "Walls", "initial": [10.0, 20.0, 30.0], "name": "span", "type": "number"},
        {"group": "Walls", "initial": "b", "name": "choice",
         "options": [{"name": "a", "value": "a"}, {"name": "b", "value": "b"}], "type": "string"},
        {"group": "Walls", "initial": 5.0, "max": 10.0, "min": 1.0, "name": "ranged",
         "step": 1.0, "type": "number"},
    ],
}


def by_name(result):
    return {p["name"]: p for p in result["params"]}


def test_zero_parameter_file_yields_no_params_and_does_not_crash():
    # THE TRAP: OpenSCAD OMITS the "parameters" key entirely for a file with none — it is not [].
    # `for p in d["parameters"]` raises KeyError and `for p in None` raises TypeError.
    result = normalize({"title": "empty"})
    assert result["params"] == []
    assert result["param_groups"] == []


def test_an_integral_number_becomes_int_not_float():
    # EVERYTHING numeric arrives as a float (4.0, never 4). Without this, a count renders as "4.0"
    # in the form and round-trips back as a float.
    assert by_name(normalize(REAL_DUMP))["cols"]["type"] == "int"
    assert by_name(normalize(REAL_DUMP))["cols"]["default"] == 4


def test_a_fractional_number_stays_float():
    assert by_name(normalize(REAL_DUMP))["wall"]["type"] == "float"
    assert by_name(normalize(REAL_DUMP))["wall"]["default"] == 1.6


def test_boolean_maps_to_bool():
    p = by_name(normalize(REAL_DUMP))["rounded"]
    assert p["type"] == "bool" and p["default"] is True


def test_string_maps_to_str():
    p = by_name(normalize(REAL_DUMP))["label"]
    assert p["type"] == "str" and p["default"] == "demo"


def test_options_make_an_enum_even_though_type_says_number():
    # TRAP: an enum is "type":"number" PLUS "options". Reading `type` first mislabels it as numeric
    # and the form renders a spinner instead of a dropdown.
    p = by_name(normalize(REAL_DUMP))["mode"]
    assert p["type"] == "enum"
    assert p["choices"] == [1, 2]
    assert p["choice_labels"] == ["solid", "hollow"]


def test_string_options_also_make_an_enum():
    p = by_name(normalize(REAL_DUMP))["choice"]
    assert p["type"] == "enum" and p["choices"] == ["a", "b"]


def test_a_vector_is_detected_by_its_value_not_its_type():
    # TRAP: a vector reports "type":"number" with a LIST initial. There is no "vector" type, so
    # branching on `type` renders a number input that cannot hold [10,20,30].
    p = by_name(normalize(REAL_DUMP))["span"]
    assert p["type"] == "vector"
    assert p["default"] == "10,20,30"


def test_min_max_step_are_carried_through():
    p = by_name(normalize(REAL_DUMP))["ranged"]
    assert (p["min"], p["max"], p["step"]) == (1, 10, 1)


def test_caption_becomes_help_and_falls_back_to_the_name():
    params = by_name(normalize(REAL_DUMP))
    assert params["cols"]["help"] == "number of columns"
    # `wall` has NO caption key — OpenSCAD only emits one when a // comment precedes the assignment.
    assert params["wall"]["help"] == ""


def test_params_are_grouped_in_declaration_order():
    groups = normalize(REAL_DUMP)["param_groups"]
    assert [g["title"] for g in groups] == ["Grid", "Walls"]
    assert [p["name"] for p in groups[0]["params"]] == ["cols", "rows"] or \
           [p["name"] for p in groups[0]["params"]] == ["cols"]


def test_a_group_named_advanced_is_flagged_advanced():
    dump = {"parameters": [
        {"group": "Advanced", "initial": 1.0, "name": "a", "type": "number"},
        {"group": "Main", "initial": 1.0, "name": "b", "type": "number"},
    ]}
    groups = {g["title"]: g for g in normalize(dump)["param_groups"]}
    assert groups["Advanced"]["advanced"] is True
    assert groups["Main"]["advanced"] is False
```

- [ ] **Step 2: Run them and watch them fail**

```bash
cd sidecar/openscad && python3 -m venv .venv && .venv/bin/pip install -q -r requirements.txt pytest && .venv/bin/python -m pytest tests/test_schema.py -q
```

Expected: `ModuleNotFoundError: No module named 'schema'` — every test errors.

- [ ] **Step 3: Implement `schema.py`**

```python
"""OpenSCAD's Customizer schema -> the normalized shape the Rails form renders.

Rails renders a param as {name, type, default, help, choices, min, max, step}, grouped into
{title, advanced, params} sections — deliberately the SAME shape BoxesClient::Generator uses, so the
two addons' field partials stay near-identical instead of diverging.

Everything here exists because OpenSCAD's dump has five sharp edges (all observed, not assumed):
  1. "parameters" is ABSENT for a zero-param file — not [].
  2. Every number is a float: 4.0, never 4.
  3. An enum is type "number"/"string" PLUS "options" — `type` alone mislabels it.
  4. A vector is type "number" with a LIST initial. There is no "vector" type.
  5. "caption" appears only when a // description comment precedes the assignment.
"""

# OpenSCAD has no notion of an "advanced" group; this is OUR convention, so a catalog author can
# push tuning knobs into a collapsed section the way boxes.py's per-edge groups are collapsed.
ADVANCED_GROUPS = {"advanced", "tuning", "expert"}
DEFAULT_GROUP = "Parameters"


def normalize(dump):
    """dump: parsed --export-format=param JSON. -> {"params": [...], "param_groups": [...]}"""
    # TRAP 1: `.get` with a default, because the key is missing (not empty) when there are none.
    raw = dump.get("parameters") or []
    params = [_param(p) for p in raw]
    return {"params": params, "param_groups": _group(params)}


def _param(p):
    initial = p.get("initial")
    out = {
        "name": p.get("name"),
        "type": _type(p, initial),
        "default": _default(p, initial),
        # TRAP 5: no caption key at all when the .scad has no description comment.
        "help": (p.get("caption") or "").strip(),
        "group": (p.get("group") or DEFAULT_GROUP).strip(),
        "choices": None,
        "choice_labels": None,
        "min": _num(p.get("min")),
        "max": _num(p.get("max")),
        "step": _num(p.get("step")),
    }
    if p.get("options"):
        # TRAP 3: options win over `type`. Keep values and labels separate — OpenSCAD's
        # `// [10:S,20:M]` syntax gives a numeric value a human label, and posting the label back
        # would be a type error.
        out["choices"] = [_num(o.get("value")) for o in p["options"]]
        out["choice_labels"] = [str(o.get("name")) for o in p["options"]]
    return out


def _type(p, initial):
    if p.get("options"):
        return "enum"                       # TRAP 3
    if isinstance(initial, list):
        return "vector"                     # TRAP 4 — by VALUE, never by p["type"]
    t = p.get("type")
    if t == "boolean":
        return "bool"
    if t == "string":
        return "str"
    if t == "number":
        # TRAP 2: 4.0 means "4". Treat an integral value with an integral step as an int so the form
        # shows a clean count rather than "4.0".
        return "int" if _is_integral(initial) and _is_integral(p.get("step", 1.0)) else "float"
    return "str"


def _default(p, initial):
    if isinstance(initial, list):
        # A vector is edited as a comma-separated text field; render.py turns it back into "[a,b,c]".
        return ",".join(_fmt(v) for v in initial)
    return _num(initial)


def _is_integral(v):
    return isinstance(v, float) and v.is_integer() or isinstance(v, int) and not isinstance(v, bool)


def _num(v):
    # bool is a subclass of int in Python — check it FIRST or True becomes 1.
    if isinstance(v, bool) or v is None:
        return v
    if isinstance(v, float) and v.is_integer():
        return int(v)
    return v


def _fmt(v):
    n = _num(v)
    return str(n)


def _group(params):
    """Group in first-appearance order — the order the .scad declares them, which is the order the
    author meant. dict preserves insertion order in 3.7+."""
    groups = {}
    for p in params:
        groups.setdefault(p["group"], []).append(p)
    return [
        {"title": title, "advanced": title.strip().lower() in ADVANCED_GROUPS, "params": ps}
        for title, ps in groups.items()
    ]
```

- [ ] **Step 4: Run the tests**

```bash
cd sidecar/openscad && .venv/bin/python -m pytest tests/test_schema.py -q
```

Expected: `12 passed`.

- [ ] **Step 5: Commit**

```bash
git add sidecar/openscad/schema.py sidecar/openscad/tests/test_schema.py
git commit -m "feat(openscad): normalize the Customizer schema, handling five real traps

--export-format=param has five sharp edges, each of which silently produces a
wrong form rather than an error. All five were OBSERVED against OpenSCAD
2026.07.26 in a container and the test fixtures are that captured output
verbatim, not hand-invented:

  1. 'parameters' is ABSENT (not []) for a zero-parameter file.
  2. Every number is a float — 4.0, never 4 — so counts render as '4.0'.
  3. An enum is type 'number'/'string' PLUS 'options'; reading type first
     renders a spinner where a dropdown belongs.
  4. A vector is type 'number' with a LIST initial. There is no 'vector' type,
     so branching on type gives a number input that cannot hold [10,20,30].
  5. 'caption' exists only when a // comment precedes the assignment.

Normalizes to the same {name,type,default,help,choices} + grouped shape
BoxesClient::Generator uses, so the two addons' field partials stay aligned."
```

---

*(Tasks 4–14 continue below.)*

## Task 4: The render path (`render.py`) — subprocess, limits, cache

> **Do not assert byte-equality across two FRESH renders anywhere in this task or Task 5** (F16): OpenSCAD's 3MF output is not byte-reproducible. The cache tests are safe because a HIT replays stored bytes — that is a different claim from "rendering twice gives the same bytes", which is false.

**Files:**
- Create: `sidecar/openscad/render.py`
- Test: `sidecar/openscad/tests/test_render.py`

Spec §5.1 (content-addressed cache), §7 (sync, hard 60 s timeout), §10 (fresh temp dir, timeout,
memory cap, non-root).

- [ ] **Step 1: Write the failing tests**

Create `sidecar/openscad/tests/test_render.py`:

```python
"""Render path. The OpenSCAD binary is real here (these run inside the built image), but the cache
and param-file construction are pure logic and are tested directly."""
import json
import os
import tempfile

import pytest

import render


SIMPLE = "/* [P] */\ncols = 2;\nlabel = \"hi\";\ncube([cols, 1, 1]);\n"


def test_cache_key_changes_with_every_input_that_can_change_the_bytes():
    a = render.cache_key(SIMPLE, {"cols": 2}, "3mf", "2026.07.26")
    assert a == render.cache_key(SIMPLE, {"cols": 2}, "3mf", "2026.07.26")     # stable
    assert a != render.cache_key(SIMPLE, {"cols": 3}, "3mf", "2026.07.26")     # params
    assert a != render.cache_key(SIMPLE + "\n", {"cols": 2}, "3mf", "2026.07.26")  # source
    assert a != render.cache_key(SIMPLE, {"cols": 2}, "stl", "2026.07.26")     # format
    # VERSION IS IN THE KEY ON PURPOSE (spec §5.1): a version bump can legitimately change output
    # geometry, and a stale cache would serve the old mesh forever.
    assert a != render.cache_key(SIMPLE, {"cols": 2}, "3mf", "2027.01.01")


def test_cache_key_is_insensitive_to_param_ordering():
    # Two identical renders must not miss the cache because a dict serialized differently.
    assert render.cache_key(SIMPLE, {"a": 1, "b": 2}, "3mf", "v") == \
           render.cache_key(SIMPLE, {"b": 2, "a": 1}, "3mf", "v")


def test_param_set_stringifies_every_value_including_bools_and_vectors():
    # OpenSCAD's parameterSets format takes STRINGS. A raw Python bool serializes as `true`, which
    # OpenSCAD does not accept, and a list serializes as `[1, 2]` with spaces.
    body = json.loads(render.param_set_json({"n": 4, "flag": False, "v": [1, 2, 3], "s": "x"}))
    values = body["parameterSets"]["s"]
    assert values["n"] == "4"
    assert values["flag"] == "false"
    assert values["v"] == "[1,2,3]"
    assert values["s"] == "x"


def test_a_comma_string_from_a_vector_field_is_rebracketed():
    # schema.py renders a vector default as "10,20,30" for a text input; it must go back as a
    # bracketed OpenSCAD vector, not the bare string.
    values = json.loads(render.param_set_json({"span": "10,20,30"}, vector_names={"span"}))["parameterSets"]["s"]
    assert values["span"] == "[10,20,30]"


@pytest.mark.skipif(not os.path.exists(os.environ.get("OPENSCAD_BIN", "/nope")),
                    reason="needs the real OpenSCAD binary (run inside the image)")
def test_render_produces_a_3mf_and_the_second_call_is_a_cache_hit():
    with tempfile.TemporaryDirectory() as cache:
        r1 = render.render(SIMPLE, {"cols": 2}, "3mf", cache_dir=cache)
        assert r1.bytes[:2] == b"PK" and len(r1.bytes) > 0
        assert r1.cached is False
        r2 = render.render(SIMPLE, {"cols": 2}, "3mf", cache_dir=cache)
        assert r2.cached is True
        assert r2.bytes == r1.bytes


@pytest.mark.skipif(not os.path.exists(os.environ.get("OPENSCAD_BIN", "/nope")),
                    reason="needs the real OpenSCAD binary (run inside the image)")
def test_a_broken_scad_raises_rendererror_not_a_crash():
    with tempfile.TemporaryDirectory() as cache:
        with pytest.raises(render.RenderError):
            render.render("this is not scad {{{", {}, "3mf", cache_dir=cache)


@pytest.mark.skipif(not os.path.exists(os.environ.get("OPENSCAD_BIN", "/nope")),
                    reason="needs the real OpenSCAD binary (run inside the image)")
def test_an_empty_model_is_a_rendererror_not_an_empty_file():
    # OpenSCAD exits nonzero with "Current top level object is empty" — but a lib3mf-less build
    # exits 0 having written nothing, so the size check is the backstop that matters.
    with tempfile.TemporaryDirectory() as cache:
        with pytest.raises(render.RenderError):
            render.render("x = 1;\n", {}, "3mf", cache_dir=cache)
```

- [ ] **Step 2: Run and watch them fail**

```bash
cd sidecar/openscad && .venv/bin/python -m pytest tests/test_render.py -q
```

Expected: `ModuleNotFoundError: No module named 'render'`.

- [ ] **Step 3: Implement `render.py`**

```python
"""Exec OpenSCAD in a bounded sandbox and cache the result by content.

Spec §7: synchronous, hard 60 s timeout. Spec §10: user-supplied .scad is arbitrary code execution
BY DESIGN (that is what a generator is), so the bound is resource-shaped, not sanitization-shaped —
the sidecar holds no secrets and no user data, and the real risk is a runaway loop DoSing a worker.
"""
import hashlib
import json
import os
import resource
import subprocess
import tempfile
from dataclasses import dataclass

OPENSCAD_BIN = os.environ.get("OPENSCAD_BIN", "/opt/openscad/usr/bin/openscad")
CACHE_DIR = os.environ.get("OPENSCAD_CACHE_DIR", "/cache")
TIMEOUT_S = int(os.environ.get("OPENSCAD_TIMEOUT", "60"))
# Address-space cap. Manifold on a big grid is comfortably under this; a runaway allocation hits it
# and dies with a clean MemoryError-ish exit instead of taking the container's RAM with it.
MEMORY_LIMIT_BYTES = int(os.environ.get("OPENSCAD_MEMORY_MB", "2048")) * 1024 * 1024
SET_NAME = "s"


class RenderError(Exception):
    """A bad .scad or bad params — a CLIENT condition. The app turns this into 422, never 500."""


@dataclass
class Result:
    bytes: bytes
    cached: bool


def openscad_version():
    try:
        out = subprocess.run([OPENSCAD_BIN, "--version"], capture_output=True, text=True, timeout=15)
        return (out.stdout + out.stderr).strip().splitlines()[0]
    except Exception:
        return "unknown"


def cache_key(scad, params, fmt, version):
    """sha256 over EVERY input that can change the bytes (spec §5.1). Version is included on
    purpose: a bump can legitimately change output geometry, and a stale cache would otherwise serve
    the old mesh forever. sort_keys makes two identical renders hash the same regardless of the
    order the form submitted the fields in."""
    blob = json.dumps(
        {"scad": scad, "params": params, "fmt": fmt, "version": version},
        sort_keys=True, separators=(",", ":"),
    )
    return hashlib.sha256(blob.encode("utf-8")).hexdigest()


def param_set_json(params, vector_names=frozenset()):
    """Build OpenSCAD's own parameterSets file. Chosen over -D deliberately: -D puts user text
    straight into an argv the shell-free exec still has to type-guess, while this is the
    Customizer's native format and needs no quoting. Note EVERY value is a STRING here — that is
    the file format, not a shortcut."""
    values = {}
    for k, v in (params or {}).items():
        if isinstance(v, bool):
            values[k] = "true" if v else "false"
        elif isinstance(v, (list, tuple)):
            values[k] = "[" + ",".join(str(x) for x in v) + "]"
        elif k in vector_names and isinstance(v, str) and "," in v and not v.startswith("["):
            # schema.py renders a vector as "10,20,30" for a plain text input; put the brackets back.
            values[k] = "[" + v.replace(" ", "") + "]"
        else:
            values[k] = str(v)
    return json.dumps({"parameterSets": {SET_NAME: values}, "fileFormatVersion": "1"})


def _limit():
    # Applied in the child between fork and exec.
    resource.setrlimit(resource.RLIMIT_AS, (MEMORY_LIMIT_BYTES, MEMORY_LIMIT_BYTES))


def render(scad, params, fmt="3mf", cache_dir=None, vector_names=frozenset()):
    cache_dir = cache_dir or CACHE_DIR
    key = cache_key(scad, params, fmt, openscad_version())
    path = os.path.join(cache_dir, f"{key}.{fmt}")
    if os.path.exists(path) and os.path.getsize(path) > 0:
        with open(path, "rb") as f:
            return Result(f.read(), cached=True)

    # A FRESH EMPTY temp dir per render (spec §10). It is also the CWD, so a relative `include <>`
    # resolves here rather than anywhere interesting. (This bounds the blast radius; it does not
    # seal it — OpenSCAD's include/import can still walk up. Accepted + documented in the README:
    # nothing sensitive lives in this container.)
    with tempfile.TemporaryDirectory(prefix="oscad-") as work:
        scad_path = os.path.join(work, "model.scad")
        set_path = os.path.join(work, "params.json")
        out_path = os.path.join(work, f"out.{fmt}")
        with open(scad_path, "w") as f:
            f.write(scad)
        with open(set_path, "w") as f:
            f.write(param_set_json(params, vector_names))

        cmd = [OPENSCAD_BIN, "--backend=manifold", "-p", set_path, "-P", SET_NAME,
               "-o", out_path, scad_path]
        try:
            proc = subprocess.run(cmd, capture_output=True, text=True, cwd=work,
                                  timeout=TIMEOUT_S, preexec_fn=_limit)
        except subprocess.TimeoutExpired:
            raise RenderError(f"render exceeded {TIMEOUT_S}s")

        if proc.returncode != 0:
            raise RenderError(_message(proc))
        # THE 3MF TRAP: a build without lib3mf logs a warning, writes nothing, and EXITS 0. So a
        # zero return code is not evidence of output. Check the bytes.
        if not os.path.exists(out_path) or os.path.getsize(out_path) == 0:
            raise RenderError(_message(proc) or "render produced no output")

        with open(out_path, "rb") as f:
            data = f.read()

    os.makedirs(cache_dir, exist_ok=True)
    # Write-then-rename: two concurrent identical renders must never let a reader see a half file.
    tmp = path + f".{os.getpid()}.tmp"
    with open(tmp, "wb") as f:
        f.write(data)
    os.replace(tmp, path)
    return Result(data, cached=False)


def _message(proc):
    """OpenSCAD's useful diagnostics go to stderr, newest last. Surface the ERROR/WARNING lines the
    user can act on rather than the geometry-cache statistics."""
    lines = [l.strip() for l in (proc.stderr or "").splitlines() if l.strip()]
    useful = [l for l in lines if l.startswith(("ERROR", "WARNING", "Parser error"))]
    return " / ".join((useful or lines)[-3:])[:500]


def params_for(scad):
    """--export-format=param on arbitrary source -> the raw Customizer dump (schema.py normalizes)."""
    with tempfile.TemporaryDirectory(prefix="oscad-p-") as work:
        scad_path = os.path.join(work, "model.scad")
        out_path = os.path.join(work, "p.json")
        with open(scad_path, "w") as f:
            f.write(scad)
        try:
            proc = subprocess.run([OPENSCAD_BIN, "--export-format=param", "-o", out_path, scad_path],
                                  capture_output=True, text=True, cwd=work, timeout=30,
                                  preexec_fn=_limit)
        except subprocess.TimeoutExpired:
            raise RenderError("parameter extraction timed out")
        if proc.returncode != 0 or not os.path.exists(out_path):
            raise RenderError(_message(proc) or "could not read parameters")
        with open(out_path) as f:
            return json.load(f)
```

- [ ] **Step 4: Run the pure-logic tests on the host**

```bash
cd sidecar/openscad && .venv/bin/python -m pytest tests/test_render.py -q
```

Expected: `4 passed, 3 skipped` (the three needing the real binary skip on the host).

- [ ] **Step 5: Run the FULL set inside the image, where nothing skips**

```bash
docker buildx build --platform linux/amd64 -t openscad-sidecar sidecar/openscad
docker run --rm -v "$PWD/sidecar/openscad/tests:/app/tests" openscad-sidecar \
  sh -c "pip install -q pytest && python -m pytest tests/ -q"
```

Expected: `19 passed` (12 schema + 7 render), **0 skipped**. If any render test skips here, `OPENSCAD_BIN` is not set in the image and the skipif is silently hiding the tests that matter.

- [ ] **Step 6: Commit**

```bash
git add sidecar/openscad/render.py sidecar/openscad/tests/test_render.py
git commit -m "feat(openscad): bounded render path with a content-addressed cache

Sync execution (spec §7) with a hard 60s timeout and a 2GB address-space cap
applied between fork and exec. User .scad is arbitrary code execution BY DESIGN
— that is what a generator is — so the bound is resource-shaped: the sidecar
holds no secrets and no user data, and the real risk is a runaway loop taking a
worker down.

Params go in via OpenSCAD's own parameterSets file (-p/-P) rather than -D: it is
the Customizer's native format and needs no argv quoting of user text. Every
value in that format is a STRING, including 'false' for bools and '[1,2,3]' for
vectors.

The cache key includes the OpenSCAD VERSION on purpose (spec §5.1) — a bump can
legitimately change output geometry and a stale cache would serve the old mesh
forever — and sorts keys so two identical renders hash the same regardless of
form field order. Cache writes are write-then-rename so concurrent identical
renders can never expose a half-written file.

Output is validated by BYTES, not exit code: a build without lib3mf writes
nothing and still exits 0."
```

---

## Task 5: The Flask API (`app.py`)

**Files:**
- Create: `sidecar/openscad/app.py`
- Test: `sidecar/openscad/tests/test_api.py`

Spec §5's four endpoints, plus `GET /source/<key>` — see the note below on why.

> **Why a fifth endpoint.** Spec §3.1 requires **one** render path: `POST /render` takes source text,
> never a catalog key, and warns *"Do not 'optimize' this into a `generator_key` fast path."* But
> Rails does not hold the catalog source — the sidecar does. So Rails **fetches** the catalog source
> (`GET /source/<key>`) and then posts it exactly as it posts a bring-your-own file's bytes. The
> catalog is genuinely data: after the fetch, the two sources are indistinguishable to every line of
> code downstream. The alternative — letting `/render` accept a key — is the two-path design the
> spec forbids.

- [ ] **Step 1: Write the failing tests**

Create `sidecar/openscad/tests/test_api.py`:

```python
import json
import os

import pytest

from app import app


@pytest.fixture
def client():
    app.config.update(TESTING=True)
    return app.test_client()


NEEDS_BIN = pytest.mark.skipif(not os.path.exists(os.environ.get("OPENSCAD_BIN", "/nope")),
                               reason="needs the real OpenSCAD binary (run inside the image)")


def test_up(client):
    r = client.get("/up")
    assert r.status_code == 200 and r.data == b"ok"


def test_generators_lists_the_bundled_catalog_with_its_licence(client):
    gens = client.get("/generators").get_json()
    assert isinstance(gens, list) and gens, "the bundled catalog must not be empty"
    g = gens[0]
    # Spec §2: a bundled generator without a recorded licence is exactly what the catalog rule
    # exists to prevent, so the API surfaces it rather than hiding it in a file.
    assert {"key", "title", "description", "license", "attribution", "source_url"} <= set(g)
    assert g["license"]
    assert "param_groups" in g


def test_generators_never_advertises_a_noncommercial_or_sharealike_licence(client):
    # Spec §2, made mechanical. NC/SA output terms are the trap that motivated the whole section;
    # a future contributor adding a generator gets stopped here rather than in review.
    banned = ("-NC", "NonCommercial", "-SA", "ShareAlike", "GPL", "AGPL")
    for g in client.get("/generators").get_json():
        assert not any(b.lower() in g["license"].lower() for b in banned), \
            f"{g['key']} has a forbidden licence: {g['license']}"


def test_source_returns_the_raw_scad_for_a_catalog_key(client):
    key = client.get("/generators").get_json()[0]["key"]
    r = client.get(f"/source/{key}")
    assert r.status_code == 200
    assert b"=" in r.data, "expected .scad source"


def test_source_rejects_a_traversing_key(client):
    # The key indexes a file on our disk, so it must never be usable as a path.
    assert client.get("/source/..%2f..%2fetc%2fpasswd").status_code in (404, 400)
    assert client.get("/source/nope-not-a-generator").status_code == 404


@NEEDS_BIN
def test_params_derives_a_schema_from_arbitrary_source(client):
    src = "/* [G] */\n// how many\ncols = 4;\nwall = 1.5;\ncube([cols, wall, 1]);\n"
    body = client.post("/params", json={"scad": src}).get_json()
    names = {p["name"] for p in body["params"]}
    assert {"cols", "wall"} <= names
    assert body["param_groups"][0]["title"] == "G"


@NEEDS_BIN
def test_params_on_a_file_with_no_parameters_is_an_empty_list_not_an_error(client):
    body = client.post("/params", json={"scad": "cube(10);\n"}).get_json()
    assert body["params"] == []


@NEEDS_BIN
def test_render_returns_3mf_bytes(client):
    src = "cols = 2;\ncube([cols, 1, 1]);\n"
    r = client.post("/render", json={"scad": src, "params": {"cols": 3}, "format": "3mf"})
    assert r.status_code == 200
    assert r.mimetype == "model/3mf"
    assert r.data[:2] == b"PK"


@NEEDS_BIN
def test_render_reports_a_cache_hit_in_a_header(client):
    src = "cols = 5;\ncube([cols, 1, 1]);\n"
    a = client.post("/render", json={"scad": src, "params": {}})
    b = client.post("/render", json={"scad": src, "params": {}})
    assert a.headers.get("X-Openscad-Cache") == "miss"
    assert b.headers.get("X-Openscad-Cache") == "hit"
    assert a.data == b.data


@NEEDS_BIN
def test_a_broken_scad_is_422_not_500(client):
    r = client.post("/render", json={"scad": "not scad {{{", "params": {}})
    assert r.status_code == 422
    assert "error" in r.get_json()


def test_render_without_source_is_422(client):
    assert client.post("/render", json={"params": {}}).status_code == 422


def test_render_rejects_an_oversized_source(client):
    r = client.post("/render", json={"scad": "x" * (app.config["MAX_SCAD_BYTES"] + 1), "params": {}})
    assert r.status_code == 422
```

- [ ] **Step 2: Run and watch them fail**

```bash
cd sidecar/openscad && .venv/bin/python -m pytest tests/test_api.py -q
```

Expected: `ModuleNotFoundError: No module named 'app'`.

- [ ] **Step 3: Implement `app.py`**

```python
# openscad-sidecar — GPL-2.0 (ships OpenSCAD; see LICENSE / README).
#
# A thin JSON API over the OpenSCAD binary: list the bundled catalog, derive a Customizer parameter
# schema from ARBITRARY source, and render source+params to 3MF. Runs as an isolated internal-only
# sidecar; the permissive Tinkerex Rails app calls it over HTTP and never imports this code.
import json
import os
import re

from flask import Flask, request, jsonify, Response

import render
import schema

app = Flask(__name__)
# A generator is a text file; anything larger is not one. Bounds the parser and the cache key.
app.config["MAX_SCAD_BYTES"] = int(os.environ.get("OPENSCAD_MAX_SCAD_BYTES", "1000000"))

CATALOG_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "catalog")
# The key indexes a file on OUR disk. Reject anything that is not a bare slug rather than trying to
# normalize it — `..` inside a name that later gets joined is how a read escapes the directory.
KEY_RE = re.compile(r"\A[A-Za-z0-9_-]+\Z")


def _catalog():
    with open(os.path.join(CATALOG_DIR, "catalog.json")) as f:
        return json.load(f)


def _source_path(key):
    if not KEY_RE.match(key or ""):
        return None
    entry = next((e for e in _catalog() if e["key"] == key), None)
    if entry is None:
        return None
    path = os.path.join(CATALOG_DIR, entry["file"])
    # Belt and braces: the file name comes from our own catalog.json, but confirm the resolved path
    # is still inside CATALOG_DIR before opening it.
    if os.path.commonpath([os.path.realpath(path), os.path.realpath(CATALOG_DIR)]) != os.path.realpath(CATALOG_DIR):
        return None
    return path if os.path.isfile(path) else None


@app.get("/up")
def up():
    return "ok", 200


@app.get("/generators")
def generators():
    """The bundled catalog + each generator's derived parameter schema. Schema derivation shells out
    to OpenSCAD once per generator, so the result is memoized for the process lifetime — the catalog
    is immutable in the image."""
    out = []
    for entry in _catalog():
        path = _source_path(entry["key"])
        if path is None:
            continue
        item = {k: entry.get(k) for k in ("key", "title", "description", "license",
                                          "attribution", "source_url")}
        try:
            with open(path) as f:
                normalized = schema.normalize(render.params_for(f.read()))
            item.update(normalized)
        except Exception:
            # A generator whose schema will not derive is skipped, not a 500 for the whole list —
            # the same posture the boxes sidecar takes for an uninspectable generator.
            continue
        out.append(item)
    return jsonify(out)


@app.get("/source/<key>")
def source(key):
    """The raw .scad for a catalog key. This is what keeps ONE render path (spec §3.1): Rails fetches
    catalog source here and then posts it to /render exactly as it posts a bring-your-own file's
    bytes, so nothing downstream can tell the two apart."""
    path = _source_path(key)
    if path is None:
        return jsonify({"error": "unknown generator"}), 404
    with open(path) as f:
        return Response(f.read(), mimetype="text/plain; charset=utf-8")


def _scad_from(body):
    scad = (body or {}).get("scad")
    if not isinstance(scad, str) or not scad.strip():
        return None, "no .scad source supplied"
    if len(scad.encode("utf-8")) > app.config["MAX_SCAD_BYTES"]:
        return None, f"source exceeds {app.config['MAX_SCAD_BYTES']} bytes"
    return scad, None


@app.post("/params")
def params():
    scad, err = _scad_from(request.get_json(force=True, silent=True))
    if err:
        return jsonify({"error": err}), 422
    try:
        return jsonify(schema.normalize(render.params_for(scad)))
    except render.RenderError as e:
        return jsonify({"error": str(e)}), 422


@app.post("/render")
def do_render():
    body = request.get_json(force=True, silent=True) or {}
    scad, err = _scad_from(body)
    if err:
        return jsonify({"error": err}), 422
    fmt = body.get("format") or "3mf"
    if fmt != "3mf":
        # Spec §12: 3MF only in v1. Refuse explicitly rather than passing an unknown suffix to
        # OpenSCAD, whose error for that is far less clear.
        return jsonify({"error": f"unsupported format {fmt!r}"}), 422
    vectors = {p["name"] for p in schema.normalize(_safe_params(scad))["params"]
               if p["type"] == "vector"}
    try:
        result = render.render(scad, body.get("params") or {}, fmt, vector_names=vectors)
    except render.RenderError as e:
        # A client condition (bad source / bad params), never a 500.
        return jsonify({"error": str(e)}), 422
    resp = Response(result.bytes, mimetype="model/3mf")
    resp.headers["X-Openscad-Cache"] = "hit" if result.cached else "miss"
    return resp


def _safe_params(scad):
    """Vector params need re-bracketing on the way in, which means knowing which they are. A schema
    failure here must not fail the render — worst case a vector field is passed through verbatim."""
    try:
        return render.params_for(scad)
    except Exception:
        return {}
```

- [ ] **Step 4: Run on the host, then in the image**

```bash
cd sidecar/openscad && .venv/bin/python -m pytest tests/ -q
```

Expected: `~7 passed, 6 skipped` (binary-dependent tests skip).

```bash
docker buildx build --platform linux/amd64 -t openscad-sidecar sidecar/openscad
docker run --rm -v "$PWD/sidecar/openscad/tests:/app/tests" openscad-sidecar \
  sh -c "pip install -q pytest && python -m pytest tests/ -q"
```

Expected: all pass, **0 skipped**.

- [ ] **Step 5: Smoke it over real HTTP**

```bash
docker run -d --name oscad-smoke -p 18000:8000 openscad-sidecar
curl -s localhost:18000/up
curl -s localhost:18000/generators | python3 -m json.tool | head -30
curl -s -X POST localhost:18000/render -H 'Content-Type: application/json' \
  -d '{"scad":"cols=3;\ncube([cols,1,1]);","params":{"cols":5}}' -D- -o /tmp/out.3mf | grep -i cache
ls -l /tmp/out.3mf && head -c2 /tmp/out.3mf
docker rm -f oscad-smoke
```

Expected: `ok`; a JSON catalog; `X-Openscad-Cache: miss`; a non-empty `/tmp/out.3mf` starting `PK`.

- [ ] **Step 6: Commit**

```bash
git add sidecar/openscad/app.py sidecar/openscad/tests/test_api.py
git commit -m "feat(openscad): Flask API — catalog, schema derivation, render

Four endpoints from spec §5 plus GET /source/<key>, which is what preserves the
ONE render path §3.1 demands. /render takes source text and never a catalog key;
since Rails does not hold catalog source, it FETCHES it here and posts it
exactly as it posts a bring-your-own file's bytes. After that fetch the two
sources are indistinguishable downstream — the catalog is data, not a code path.

A catalog key indexes a file on our disk, so it is validated against a bare-slug
regex and the resolved path is re-checked against the catalog dir before opening.
/generators surfaces each entry's licence, and a test asserts none is
NonCommercial/ShareAlike/GPL — spec §2's rule made mechanical, so a future
contributor is stopped by a red test rather than by review.

Bad source and bad params are 422 (client conditions), never 500."
```

## Task 7: `OpenscadClient` — the typed HTTP client

**Files:**
- Create: `app/services/openscad_client.rb`
- Test: `test/services/openscad_client_test.rb`

Mirrors `BoxesClient` exactly (spec §6): `configured?`/`base_url`/`current`/`stub=`/`stubbed?`/`reset!`.
`configured?` is what greys the addon out on a deployment with no sidecar.

- [ ] **Step 1: Write the failing test**

Create `test/services/openscad_client_test.rb`:

```ruby
require "test_helper"

class OpenscadClientTest < ActiveSupport::TestCase
  test "configured? reflects OPENSCAD_SIDECAR_URL" do
    with_env("OPENSCAD_SIDECAR_URL" => nil) { assert_not OpenscadClient.configured? }
    with_env("OPENSCAD_SIDECAR_URL" => "http://openscad:8000") { assert OpenscadClient.configured? }
  end

  test "configured? is false for a BLANK url, not just a missing one" do
    # deploy.ovh.yml clears the sidecar URLs by setting them to "" (Task 1) — Kamal deep-merges
    # env.clear, so blanking is the only way to un-inherit. If blank read as configured, that
    # overlay would report the addon available and then fail on every call.
    with_env("OPENSCAD_SIDECAR_URL" => "") { assert_not OpenscadClient.configured? }
  end

  private

  def with_env(vars)
    old = {}
    vars.each { |k, v| old[k] = ENV.key?(k) ? ENV[k] : :unset; v.nil? ? ENV.delete(k) : (ENV[k] = v) }
    yield
  ensure
    old.each { |k, v| v == :unset ? ENV.delete(k) : (ENV[k] = v) }
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

```bash
bin/rails test test/services/openscad_client_test.rb
```

Expected: `NameError: uninitialized constant OpenscadClient`.

- [ ] **Step 3: Implement the client**

Create `app/services/openscad_client.rb`:

```ruby
require "net/http"
require "json"

# Typed client for the OpenSCAD sidecar. Real HTTP; the sidecar is a separate GPL-2.0 image we never
# link (CLAUDE.md §9). `configured?` gates the addon's availability — no OPENSCAD_SIDECAR_URL and the
# tool greys out, the same graceful degradation Boxes and the preview renderers use. Tests inject
# FakeOpenscad via `OpenscadClient.stub` (test/support/fake_openscad.rb).
class OpenscadClient
  # param_groups: Array<Hash{"title","advanced",bool,"params"=>Array<Hash>}> — the .scad's own
  # Customizer groups, normalized by the sidecar into the SAME shape BoxesClient::Generator uses so
  # the two addons' field partials stay aligned rather than drifting apart.
  Generator = Data.define(:key, :title, :description, :license, :attribution, :source_url,
                          :params, :param_groups)
  class Error < StandardError; end

  # Renders can legitimately take up to the sidecar's 60 s cap, so this read timeout must sit ABOVE
  # it — otherwise Rails gives up on a render that is about to succeed and the user sees a generic
  # failure instead of the sidecar's specific 422.
  RENDER_READ_TIMEOUT = 90
  READ_TIMEOUT = 30
  OPEN_TIMEOUT = 3

  class << self
    attr_writer :stub

    def configured? = ENV["OPENSCAD_SIDECAR_URL"].present?
    def base_url = ENV.fetch("OPENSCAD_SIDECAR_URL")
    def current = @stub || new(base_url)
    def stubbed? = !@stub.nil?
    def reset! = @stub = nil
  end

  def initialize(base_url) = @base = base_url

  def generators
    get("/generators").map do |g|
      Generator.new(**g.symbolize_keys.slice(:key, :title, :description, :license, :attribution,
                                             :source_url, :params, :param_groups))
    end
  end

  # The raw .scad for a bundled generator. Rails fetches this and posts it to #render exactly as it
  # posts a bring-your-own file's bytes — that is what keeps ONE render path (spec §3.1).
  def source(key)
    http(Net::HTTP::Get.new(URI.join(@base, "/source/#{key}"))).body
  end

  # Customizer schema for ARBITRARY source -> { "params" => [...], "param_groups" => [...] }.
  def params_for(scad)
    JSON.parse(post("/params", { scad: }))
  end

  # 3MF bytes (String). Raises Error on 4xx/5xx.
  def render(scad:, params:, format: "3mf")
    post("/render", { scad:, params:, format: }, accept: "model/3mf", read_timeout: RENDER_READ_TIMEOUT)
  end

  private

  def get(path)
    JSON.parse(http(Net::HTTP::Get.new(URI.join(@base, path))).body)
  end

  def post(path, body, accept: "application/json", read_timeout: READ_TIMEOUT)
    req = Net::HTTP::Post.new(URI.join(@base, path))
    req["Content-Type"] = "application/json"
    req["Accept"] = accept
    req.body = body.to_json
    http(req, read_timeout:).body
  end

  def http(req, read_timeout: READ_TIMEOUT)
    uri = req.uri
    res = Net::HTTP.start(uri.host, uri.port, open_timeout: OPEN_TIMEOUT, read_timeout:) { |h| h.request(req) }
    unless res.is_a?(Net::HTTPSuccess)
      # Surface the sidecar's own {"error": …} when it sent one — it names the actual OpenSCAD
      # complaint ("Parser error: syntax error…"), which is the only thing the user can act on.
      detail = (JSON.parse(res.body)["error"] rescue nil) || res.body.to_s[0, 200]
      raise Error, detail.presence || "openscad sidecar #{res.code}"
    end

    res
  end
end
```

- [ ] **Step 4: Run the test**

```bash
bin/rails test test/services/openscad_client_test.rb
```

Expected: `2 runs, 3 assertions, 0 failures, 0 errors`.

- [ ] **Step 5: Commit**

```bash
git add app/services/openscad_client.rb test/services/openscad_client_test.rb
git commit -m "feat(openscad): typed sidecar client mirroring BoxesClient

configured? gates the addon's availability, and treats a BLANK url as
unconfigured — deploy.ovh.yml un-inherits Kamal's deep-merged env.clear by
setting the URL to \"\", so blank-means-configured would make that overlay
advertise an addon that fails on every call.

The render read timeout (90s) deliberately exceeds the sidecar's own 60s render
cap; below it, Rails would abandon a render about to succeed and replace the
sidecar's specific 422 with a generic failure. Errors unwrap the sidecar's
{\"error\":…} body so the user sees OpenSCAD's actual complaint."
```

---

## Task 8: `FakeOpenscad` — the test stub

**Files:**
- Create: `test/support/fake_openscad.rb`

Same shape as `FakeBoxes`, so the whole addon is exercisable without Docker.

> **The fake-fidelity rule (CLAUDE.md §12 step 10, and a memory entry of its own).** A fake built
> from the same misunderstanding as the code *confirms* the misunderstanding — that is how a silent
> data-loss bug survived 79/80 green tests in the S3 phase. So this fake's `params_for` returns the
> **normalized** shape the real sidecar returns, taken from Task 3's captured fixtures, and its
> `render` returns **real zip magic** rather than a plain string. The sidecar's own pytest suite
> (Tasks 3–5) is what tests the OpenSCAD-facing wire format; this fake is only allowed to stand in
> for the HTTP boundary.

- [ ] **Step 1: Write the fake**

Create `test/support/fake_openscad.rb`:

```ruby
# In-memory stand-in for the OpenSCAD sidecar, injected via OpenscadClient.stub in tests. Mirrors
# the OpenscadClient API shape so the whole addon is exercisable without the Python sidecar.
#
# The param shapes below are the NORMALIZED output of sidecar/openscad/schema.py, whose own tests
# use OpenSCAD's real --export-format=param output as fixtures. Keeping this fake downstream of that
# is deliberate: a fake invented independently of the real wire format is how a fake ends up
# confirming the code's misunderstanding instead of catching it.
class FakeOpenscad
  HEX = {
    "key" => "hex_plate", "title" => "Hex grid plate",
    "description" => "A honeycomb plate", "license" => "MIT",
    "attribution" => "Example Author", "source_url" => "https://example.invalid/hex",
    "param_groups" => [
      { "title" => "Grid", "advanced" => false, "params" => [
          { "name" => "cols", "type" => "int", "default" => 4, "help" => "number of columns",
            "choices" => nil, "min" => nil, "max" => nil, "step" => 1 },
          { "name" => "wall", "type" => "float", "default" => 1.6, "help" => "",
            "choices" => nil, "min" => nil, "max" => nil, "step" => nil } ] },
      { "title" => "Advanced", "advanced" => true, "params" => [
          { "name" => "mode", "type" => "enum", "default" => 1, "help" => "render mode",
            "choices" => [ 1, 2 ], "choice_labels" => %w[solid hollow],
            "min" => nil, "max" => nil, "step" => nil } ] }
    ]
  }.freeze

  TRAY = {
    "key" => "divider_tray", "title" => "Divider tray",
    "description" => "A compartment tray", "license" => "BSD-3-Clause",
    "attribution" => "Other Author", "source_url" => "https://example.invalid/tray",
    "param_groups" => [
      { "title" => "Tray", "advanced" => false, "params" => [
          { "name" => "x", "type" => "float", "default" => 100, "help" => "width (mm)",
            "choices" => nil, "min" => nil, "max" => nil, "step" => nil } ] }
    ]
  }.freeze

  def generators
    [ HEX, TRAY ].map do |g|
      OpenscadClient::Generator.new(
        key: g["key"], title: g["title"], description: g["description"], license: g["license"],
        attribution: g["attribution"], source_url: g["source_url"],
        params: g["param_groups"].flat_map { |grp| grp["params"] },
        param_groups: g["param_groups"]
      )
    end
  end

  def source(key)
    raise OpenscadClient::Error, "unknown generator" unless [ "hex_plate", "divider_tray" ].include?(key)

    "/* [Grid] */\n// number of columns\ncols = 4;\nwall = 1.6;\ncube([cols, wall, 1]);\n"
  end

  # Any source with a top-level assignment yields that one param — enough for the BYO flow's form.
  def params_for(_scad)
    { "params" => HEX["param_groups"].flat_map { |g| g["params"] },
      "param_groups" => HEX["param_groups"] }
  end

  # REAL zip magic: a 3MF is an OPC/zip container, and Maker::Previews::ThreeMf opens it as one. A
  # plain "fake bytes" string would make every preview path fail for a reason no production run has.
  def render(scad:, params:, format: "3mf")
    @rendered = { scad:, params:, format: }
    FakeOpenscad.minimal_3mf
  end

  attr_reader :rendered

  # A genuinely valid, minimal 3MF: a zip containing one 3D/3dmodel.model with a single triangle, so
  # Maker::Previews::ThreeMf's mesh fallback can actually parse it.
  def self.minimal_3mf
    require "zip"
    buf = Zip::OutputStream.write_buffer(StringIO.new("".b)) do |z|
      z.put_next_entry("3D/3dmodel.model")
      z.write(<<~XML)
        <?xml version="1.0" encoding="UTF-8"?>
        <model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
          <resources><object id="1" type="model"><mesh>
            <vertices>
              <vertex x="0" y="0" z="0"/><vertex x="10" y="0" z="0"/><vertex x="0" y="10" z="0"/>
            </vertices>
            <triangles><triangle v1="0" v2="1" v3="2"/></triangles>
          </mesh></object></resources>
          <build><item objectid="1"/></build>
        </model>
      XML
    end
    buf.string
  end
end
```

- [ ] **Step 2: Verify the fake's 3MF is genuinely parseable**

The point of a real container is that the preview pipeline can read it. Check that directly:

```bash
bin/rails runner 'require "./test/support/fake_openscad"; \
  b = FakeOpenscad.minimal_3mf; \
  puts "magic=#{b[0,2]} bytes=#{b.bytesize}"; \
  puts "mesh_to_stl=#{Maker::Previews::ThreeMf.mesh_to_stl(b)&.bytesize.inspect}"'
```

Expected: `magic=PK bytes=…` and a non-nil `mesh_to_stl` byte count (the mesh fallback found the triangle). A `nil` there means the fake would silently produce blank thumbnails in every test.

- [ ] **Step 3: Commit**

```bash
git add test/support/fake_openscad.rb
git commit -m "test(openscad): sidecar stub returning a REAL 3MF container

Mirrors OpenscadClient's API so the addon is exercisable without Docker. Two
deliberate fidelity choices, both from the FakeS3 lesson in CLAUDE.md §12 step 10
(a fake built from the same misunderstanding as the code confirms it — 79/80
green while a silent data-loss bug shipped):

  - the param shapes are the NORMALIZED output of schema.py, whose own tests use
    OpenSCAD's real --export-format=param output as fixtures, rather than a
    shape invented here;
  - render returns a genuine zip/OPC container with a parseable mesh, verified
    through Maker::Previews::ThreeMf.mesh_to_stl, not a placeholder string that
    would make every preview path fail for a reason production never sees."
```

---

## Task 9: Registry entry + routes

**Files:**
- Modify: `app/services/maker/addons/registry.rb`
- Modify: `config/routes.rb`
- Test: `test/controllers/tools/openscad_controller_test.rb` (created here, grown in Task 11)

> **The routing trap.** `resources :openscad` does **not** give the helper the `/tools` gallery
> needs. Rails derives the collection helper from `name.pluralize` and the member helper from
> `name.singularize`; `"openscad".pluralize` is `"openscads"`, so index becomes
> `tools_openscads_path` while **`tools_openscad_path` is the SHOW helper and requires an id**. The
> gallery does `send("tools_#{addon.key}_path")` with no arguments, so it would raise
> `ActionController::UrlGenerationError` — on the /tools page, for every user, the moment the addon
> is registered. Explicit routes give the exact helper names instead of fighting the inflector.

- [ ] **Step 1: Write the failing test**

Create `test/controllers/tools/openscad_controller_test.rb`:

```ruby
require "test_helper"
require_relative "../../support/fake_openscad"

module Tools
  class OpenscadControllerTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "oscad@example.com", password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      OpenscadClient.stub = FakeOpenscad.new
      Storage::ChunkStore.reset!
      if ENV["LIBRARY_BACKEND"] == "s3"
        require_relative "../../support/fake_s3"
        @fake = FakeS3.new
        FileLayer.current = FileLayer::S3.new(bucket: "b", region: "us-east-1", access_key_id: "ak",
                                              secret_access_key: "sk", prefix: "library",
                                              client: @fake.client)
      end
    end
    teardown do
      OpenscadClient.reset!
      FileLayer.reset!
    end

    test "the /tools gallery links the addon without raising on the helper" do
      # REGRESSION GUARD: `resources :openscad` would make tools_openscad_path the SHOW helper, which
      # needs an id — and the gallery calls send("tools_#{key}_path") with no args, so /tools itself
      # would 500 for every user the moment this addon is registered.
      get tools_path
      assert_response :success
      assert_select "a.addon-card[href=?]", "/tools/openscad"
    end

    test "index lists the bundled catalog" do
      get tools_openscad_path
      assert_response :success
      assert_select ".addon-card .addon-title", text: "hex_plate"
    end
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

```bash
bin/rails test test/controllers/tools/openscad_controller_test.rb
```

Expected: `NameError: undefined local variable or method 'tools_openscad_path'`.

- [ ] **Step 3: Add the routes**

In `config/routes.rb`, inside the existing `namespace :tools do` block, after the `resources :generators` line:

```ruby
    # OpenSCAD addon. Deliberately NOT `resources :openscad`: Rails derives the collection helper
    # from name.pluralize ("openscads") and the member helper from name.singularize ("openscad"), so
    # `resources` would leave tools_openscad_path meaning SHOW — which needs an id. The /tools
    # gallery calls send("tools_#{addon.key}_path") with no arguments, so /tools would raise
    # UrlGenerationError for every user. Explicit routes name the helpers instead of fighting the
    # inflector. `new` and `preview` precede `:id` so neither is swallowed as an id.
    get  "openscad",         to: "openscad#index",   as: :openscad
    get  "openscad/new",     to: "openscad#new",     as: :new_openscad
    post "openscad/preview", to: "openscad#preview", as: :preview_openscad
    post "openscad",         to: "openscad#create"
    get  "openscad/:id",     to: "openscad#show",    as: :openscad_design
```

- [ ] **Step 4: Add the registry entry**

In `app/services/maker/addons/registry.rb`, add to `REGISTRY` after the `"generators"` entry:

```ruby
        "openscad" => Addon.new(
          key: "openscad", title: "OpenSCAD", icon: "🧊",
          description: "Parametric .scad + params → 3MF",
          available: -> { OpenscadClient.configured? }
        )
```

- [ ] **Step 5: Verify the helper names are what the gallery needs**

```bash
bin/rails routes -g openscad
```

Expected — note `tools_openscad` with **no** `_index` suffix and **no** `:id`:

```
        tools_openscad GET    /tools/openscad(.:format)         tools/openscad#index
    new_tools_openscad GET    /tools/openscad/new(.:format)     tools/openscad#new
preview_tools_openscad POST  /tools/openscad/preview(.:format)  tools/openscad#preview
                       POST  /tools/openscad(.:format)          tools/openscad#create
 tools_openscad_design GET    /tools/openscad/:id(.:format)     tools/openscad#show
```

- [ ] **Step 6: Run the test — first assertion passes, second still fails**

```bash
bin/rails test test/controllers/tools/openscad_controller_test.rb
```

Expected: the gallery test **passes**; the index test fails with `uninitialized constant Tools::OpenscadController`. That is the correct state — the controller is Task 10.

- [ ] **Step 7: Commit**

```bash
git add config/routes.rb app/services/maker/addons/registry.rb test/controllers/tools/openscad_controller_test.rb
git commit -m "feat(openscad): register the addon + explicit routes

One registry entry, gated on OpenscadClient.configured? so the tile greys out on
a deployment with no sidecar — the same graceful degradation Boxes uses.

Routes are explicit rather than \`resources :openscad\` on purpose. Rails derives
the collection helper from name.pluralize ('openscads') and the member helper
from name.singularize ('openscad'), so \`resources\` leaves tools_openscad_path
meaning SHOW, which requires an id. The /tools gallery calls
send(\"tools_#{addon.key}_path\") with no arguments, so registering the addon
under \`resources\` would make /tools raise UrlGenerationError for every user.
Guarded by a test that loads /tools and asserts the link renders."
```

## Task 6: The bundled catalog (spec §2 — read it before touching this)

**Files:**
- Create: `sidecar/openscad/catalog/catalog.json`, `sidecar/openscad/catalog/NOTICE`, and one vendored `.scad` per entry
- Test: `sidecar/openscad/tests/test_catalog.py`

### What was audited, and what was rejected

Every candidate was checked against five bars: permissive source licence · no NC/SA/copyleft · **no
separate OUTPUT licence** · self-contained single file · a usable Customizer surface. The rejections
are the useful half:

| Rejected | Bar it failed |
|---|---|
| **Multiboard / MultiBuild** | Output is **CC BY-NC-SA 4.0** — NC *and* SA, on the generated models. Exactly spec §2's trap. Never ship. |
| `kennetek/gridfinity-rebuilt-openscad` | Licence is fine (dual MIT) but it is 20 files with 9 `include`/`use` lines and vendors `threads-scad` |
| `vector76/gridfinity_openscad` | MIT but 9 files with cross-includes |
| Ultimate Box Maker | **CC BY-NC** |
| `mgfarmer/openscad_tray_generator`, `ostat/gridfinity_extended_openscad`, `franpoli/OpenSCADutil` | GPL-2.0 / GPL-3.0 |
| `JennyList/Jennys-rectangular-project-box` | CC-BY-**SA** |
| `mikeydotio/opengrid-scad` | needs BOSL2 |
| `wromijn/openscad-gridfinity-block`, `xypwn/scadqr` | only 3 and 0 Customizer params — module-shaped, nothing to put on a form |
| **DrLex Customizable Screw Cap** | Licence and output terms are *ideal* (CC-BY-4.0, and the README explicitly permits selling generated models). **Rejected anyway:** it incorporates `screw_extrude` from a Thingiverse original (thing:1648580) whose licence could not be verified (Thingiverse 403s automated fetches), and Thingiverse defaults are frequently NC or SA. Unverified upstream provenance is not a licence. Revisit by opening that page in a browser. |
| `cfinke/LEGO.scad` | MIT and 42 params, but "LEGO" is an **active trademark** and the file is explicitly a LEGO-compatible brick generator — a trademark exposure distinct from copyright |

> **THE `include`-GREP IS NOT SUFFICIENT, and this is the lesson to carry.** One candidate
> (`print3d-more-printable-assembled-wrench`) passed an `include`/`use` grep cleanly and *still*
> depended on three external STLs via `import("raw_parts/inserts.stl")`. OpenSCAD treats a missing
> `import()` as a **WARNING, not an error** — it exited 0 and produced a 1,788-facet stub containing
> the lettering and no wrench. **A silently wrong model, with a zero exit code.** Same shape as the
> lib3mf trap in Task 2. Hence Step 4 below renders every catalog entry and asserts the geometry is
> non-trivial, rather than trusting a grep or an exit code.

### The four that ship

| key | What | Licence | Params | Source (pinned) |
|---|---|---|---|---|
| `vase_box` | Spiral/vase-mode box + friction-fit lid | **CC-BY-4.0** | 12 | `DrLex0/print3d-customizable-vase-mode-box@5dbc4c9` |
| `hex_cell_holder` | Honeycomb holder for cylindrical cells | **Unlicense** | 54 | `Addy771/Hex-Cell-Holder@a0078b3` |
| `universal_stand` | Angled stand for phones/tablets | **MIT** | 11 | `IOIO72/scad-universal-stand@78446ad` |
| `washer` | Round/hex/square washers + spacers | **MIT** | 12 | `Theo-Ghanem/Parametric-3D-Print-Washer-Generator@983fb04` |

`hex_cell_holder` is the closest thing in the set to the grid-shaped workload that motivated this
addon, and Unlicense is the strongest licence position available (public domain, no attribution
obligation). It is also the one with a timing question — see Step 5.

- [ ] **Step 1: Vendor the four files at their pinned SHAs**

Vendored into git rather than downloaded at build time: reproducible, auditable in review, and no
build-time dependency on GitHub staying up. All four licences permit redistribution.

```bash
mkdir -p sidecar/openscad/catalog
cd sidecar/openscad/catalog
curl -fsSL -o vase_box.scad \
  "https://raw.githubusercontent.com/DrLex0/print3d-customizable-vase-mode-box/5dbc4c92446ab0088dcc5ed080a2b079de8fb012/Vase_mode_box.scad"
curl -fsSL -o hex_cell_holder.scad \
  "https://raw.githubusercontent.com/Addy771/Hex-Cell-Holder/a0078b346166e806f6ade21366ed0d5ff7ab157b/hex_cell.scad"
curl -fsSL -o universal_stand.scad \
  "https://raw.githubusercontent.com/IOIO72/scad-universal-stand/78446ad102f49be3f27e7ae9cf0e52492e3c317b/Universal%20Stand.scad"
curl -fsSL -o washer.scad \
  "https://raw.githubusercontent.com/Theo-Ghanem/Parametric-3D-Print-Washer-Generator/983fb045d07be07204ef5b712f45bff85d56d647/ParametricWasher.scad"
wc -c *.scad
cd -
```

Expected roughly: `vase_box.scad` ~6.1 KB, `hex_cell_holder.scad` ~47.5 KB, `universal_stand.scad` ~6.9 KB, `washer.scad` ~4.6 KB. A file that comes back far smaller is an HTML error page — check before continuing.

- [ ] **Step 2: Write `catalog.json`**

```json
[
  {
    "key": "vase_box",
    "file": "vase_box.scad",
    "title": "Vase-mode box",
    "description": "Spiral/vase-mode box with a matching friction-fit lid; rectangular or cylindrical, optional rounded corners.",
    "license": "CC-BY-4.0",
    "attribution": "Vase Mode Box by DrLex (Alexander Thomas) — CC BY 4.0",
    "source_url": "https://github.com/DrLex0/print3d-customizable-vase-mode-box",
    "source_ref": "5dbc4c92446ab0088dcc5ed080a2b079de8fb012"
  },
  {
    "key": "hex_cell_holder",
    "file": "hex_cell_holder.scad",
    "title": "Hex cell holder",
    "description": "Honeycomb holders, caps and insulators for cylindrical cells (18650 and friends).",
    "license": "Unlicense",
    "attribution": "Hex Cell Holder by Addy771 — Unlicense (public domain)",
    "source_url": "https://github.com/Addy771/Hex-Cell-Holder",
    "source_ref": "a0078b346166e806f6ade21366ed0d5ff7ab157b"
  },
  {
    "key": "universal_stand",
    "file": "universal_stand.scad",
    "title": "Universal stand",
    "description": "Angled stand for phones, tablets and handhelds, with configurable width, angle and feet.",
    "license": "MIT",
    "attribution": "Universal Stand by Tamio Honma (IOIO72) — MIT",
    "source_url": "https://github.com/IOIO72/scad-universal-stand",
    "source_ref": "78446ad102f49be3f27e7ae9cf0e52492e3c317b"
  },
  {
    "key": "washer",
    "file": "washer.scad",
    "title": "Washer / spacer",
    "description": "Round, hex or square washers and spacers with screw-size presets, chamfer and countersink.",
    "license": "MIT",
    "attribution": "Parametric Washer Generator by Theo Ghanem — MIT",
    "source_url": "https://github.com/Theo-Ghanem/Parametric-3D-Print-Washer-Generator",
    "source_ref": "983fb045d07be07204ef5b712f45bff85d56d647"
  }
]
```

- [ ] **Step 3: Write `catalog/NOTICE`**

```
Third-party OpenSCAD generators bundled in this image.

Each file below is redistributed under its own licence, unmodified, at the pinned upstream commit.
Spec §2 governs what may be added here: PERMISSIVE SOURCE ONLY (MIT / Apache-2.0 / BSD / CC0 /
CC-BY), and a generator whose OUTPUT carries a NonCommercial or ShareAlike term does NOT go in this
catalog no matter how good it is — it is a bring-your-own file. That rule exists because Tinkerex is
a commercial product AND this image is redistributed to self-hosters, so both "commercial use" and
"redistribution" have to be permitted.

--------------------------------------------------------------------------------
vase_box.scad
  Vase Mode Box by DrLex (Alexander Thomas)
  CC BY 4.0 — https://creativecommons.org/licenses/by/4.0/
  https://github.com/DrLex0/print3d-customizable-vase-mode-box
  commit 5dbc4c92446ab0088dcc5ed080a2b079de8fb012

hex_cell_holder.scad
  Hex Cell Holder by Addy771
  The Unlicense (public domain dedication) — https://unlicense.org/
  https://github.com/Addy771/Hex-Cell-Holder
  commit a0078b346166e806f6ade21366ed0d5ff7ab157b

universal_stand.scad
  Universal Stand by Tamio Honma (IOIO72)
  MIT — Copyright (c) 2022 Tamio Honma
  https://github.com/IOIO72/scad-universal-stand
  commit 78446ad102f49be3f27e7ae9cf0e52492e3c317b

washer.scad
  Parametric Washer Generator by Theo Ghanem
  MIT
  https://github.com/Theo-Ghanem/Parametric-3D-Print-Washer-Generator
  commit 983fb045d07be07204ef5b712f45bff85d56d647
--------------------------------------------------------------------------------

Considered and REJECTED, so the reasoning is not lost:

  Multiboard / MultiBuild  — generated models are CC BY-NC-SA 4.0. NonCommercial AND ShareAlike, on
                             the OUTPUT. This is the exact trap spec §2 was written about. Never.
  Ultimate Box Maker       — CC BY-NC.
  gridfinity (kennetek,    — licences acceptable, but multi-file with cross-includes; OpenSCAD's
   vector76)                 Customizer only reads top-level assignments in the MAIN file.
  DrLex Screw Cap          — licence and output terms are ideal, but it incorporates code from a
                             Thingiverse original whose licence could not be verified. Unverified
                             upstream provenance is not a licence.
  LEGO.scad                — MIT, but "LEGO" is an active trademark; a trademark exposure is not a
                             copyright question and the permissive licence does not answer it.
```

- [ ] **Step 4: Write the catalog test — the one that catches a silently-wrong model**

Create `sidecar/openscad/tests/test_catalog.py`:

```python
"""Catalog integrity. Two of these encode audit findings that a grep or an exit code would miss."""
import json
import os

import pytest

import render
import schema
from app import CATALOG_DIR, _catalog, _source_path

NEEDS_BIN = pytest.mark.skipif(not os.path.exists(os.environ.get("OPENSCAD_BIN", "/nope")),
                               reason="needs the real OpenSCAD binary (run inside the image)")

BANNED = ("-NC", "noncommercial", "-SA", "sharealike", "gpl", "agpl", "lgpl")


def test_every_entry_resolves_to_a_real_file():
    for e in _catalog():
        assert _source_path(e["key"]) is not None, f"{e['key']} -> missing {e['file']}"


def test_every_entry_records_a_permissive_licence_and_attribution():
    # Spec §2 made mechanical: a contributor adding an NC/SA/copyleft generator is stopped by a red
    # test rather than by review catching it.
    for e in _catalog():
        assert e["license"], f"{e['key']} has no licence"
        assert e["attribution"], f"{e['key']} has no attribution"
        assert e["source_ref"], f"{e['key']} has no pinned upstream commit"
        low = e["license"].lower()
        assert not any(b in low for b in BANNED), f"{e['key']}: forbidden licence {e['license']}"


def test_every_bundled_file_is_listed_in_notice():
    notice = open(os.path.join(CATALOG_DIR, "NOTICE")).read()
    for e in _catalog():
        assert e["file"] in notice, f"{e['file']} is bundled but not credited in NOTICE"
        assert e["source_ref"] in notice, f"{e['file']}'s pinned commit is not recorded in NOTICE"


def test_no_scad_in_the_catalog_dir_is_unlisted():
    # A file that got vendored but never added to catalog.json would be redistributed with no
    # licence record at all — the worst case, and invisible from the other direction.
    listed = {e["file"] for e in _catalog()}
    on_disk = {f for f in os.listdir(CATALOG_DIR) if f.endswith(".scad")}
    assert on_disk == listed, f"unlisted .scad files: {on_disk - listed}"


def test_no_entry_pulls_in_an_external_file():
    # A grep for include/use is NOT enough — import() and surface() also pull external files, and
    # OpenSCAD treats a MISSING import as a warning, exiting 0 with a silently wrong model. One
    # audited candidate passed the include-grep and still depended on three external STLs.
    for e in _catalog():
        src = open(_source_path(e["key"])).read()
        for bad in ("include <", "use <", "import(", "surface("):
            assert bad not in src, f"{e['key']} references an external file: {bad}"


@NEEDS_BIN
def test_every_entry_exposes_parameters():
    # A module-shaped .scad yields an empty form — a catalog tile that does nothing. OpenSCAD stops
    # collecting at the first `{` and only accepts literal values, so this cannot be eyeballed.
    for e in _catalog():
        src = open(_source_path(e["key"])).read()
        params = schema.normalize(render.params_for(src))["params"]
        assert len(params) >= 5, f"{e['key']} exposes only {len(params)} params"


@NEEDS_BIN
def test_every_entry_renders_a_substantial_model_at_its_defaults():
    # THE AUDIT'S SHARPEST FINDING, made mechanical: a missing import() is a WARNING, so OpenSCAD
    # exits 0 and writes a stub. Asserting "it rendered" would pass on a model with the geometry
    # missing. Assert the OUTPUT IS BIG ENOUGH to be a real model instead.
    for e in _catalog():
        src = open(_source_path(e["key"])).read()
        result = render.render(src, {}, "3mf", cache_dir="/tmp/catalog-cache")
        assert result.bytes[:2] == b"PK"
        assert len(result.bytes) > 2000, \
            f"{e['key']} rendered only {len(result.bytes)} bytes — likely a stub from a missing import"
```

- [ ] **Step 5: Run it in the image and MEASURE each render**

The audit's timings were taken on OpenSCAD **2021.01**, i.e. the CGAL backend. This image runs
**Manifold**, measured 20×+ faster on grid-shaped models — so those numbers are expected to be
pessimistic here. Expected, not assumed: measure.

```bash
docker buildx build --platform linux/amd64 -t openscad-sidecar sidecar/openscad
docker run --rm -v "$PWD/sidecar/openscad/tests:/app/tests" openscad-sidecar sh -c '
  pip install -q pytest && python -m pytest tests/test_catalog.py -q &&
  python - <<PY
import time, render, json
from app import _catalog, _source_path
for e in _catalog():
    src = open(_source_path(e["key"])).read()
    t = time.time()
    r = render.render(src, {}, "3mf", cache_dir="/tmp/t")
    print(f"{e[\"key\"]:20s} {int((time.time()-t)*1000):6d} ms  {len(r.bytes):8d} bytes")
PY'
```

Expected: all catalog tests pass, and a timing line per generator.

**Decision rule, applied to the measured numbers — not to the audit's CGAL ones:**
- Every generator must render at its **defaults** in **under 15 s**. The sidecar's hard cap is 60 s
  (spec §7) and a user will raise the parameters well above the defaults, so a default-case render
  anywhere near the cap is a tile that times out in normal use.
- `hex_cell_holder` is the one at risk (54 s under CGAL at 4×8 cells). If it measures **over 15 s**
  here, do **not** drop it — lower its bundled defaults instead, since it is the closest generator
  in the set to this addon's motivating workload. Reduce `num_rows`/`num_cols` in the vendored file
  to a 3×3 default, record the edit at the top of `NOTICE` (all four licences permit modification;
  CC-BY and MIT require the change be visible), and re-measure.
- If it still exceeds 15 s at 3×3, drop it from `catalog.json`, leave the file unvendored, and note
  it in `docs/addon-backlog.md` as a candidate for the async-rendering follow-up (spec §12).

- [ ] **Step 6: Commit**

```bash
git add sidecar/openscad/catalog/ sidecar/openscad/tests/test_catalog.py
git commit -m "feat(openscad): bundled catalog — four audited permissive generators

Vase-mode box (CC-BY-4.0), hex cell holder (Unlicense), universal stand (MIT)
and washer generator (MIT), vendored at pinned upstream commits with a NOTICE
crediting each. Vendored rather than fetched at build time so the catalog is
reproducible and auditable in review.

Rejections are recorded in NOTICE because the reasoning is the valuable part.
Multiboard/MultiBuild is out for the reason spec §2 exists: its generated models
are CC BY-NC-SA 4.0 — NonCommercial AND ShareAlike, on the OUTPUT, behind
permissive-looking source. Also out: Ultimate Box Maker (CC BY-NC), the
gridfinity forks (multi-file with cross-includes, which OpenSCAD's Customizer
cannot read), a screw cap whose upstream Thingiverse provenance could not be
verified, and LEGO.scad (trademark, which a permissive licence does not answer).

The catalog test asserts rendered output is SUBSTANTIAL, not merely successful.
An audited candidate passed an include/use grep and still pulled three external
STLs via import() — and OpenSCAD treats a missing import as a WARNING, exiting 0
with a 1,788-facet stub. Same shape as the lib3mf trap: a zero exit code proving
nothing. So the test checks byte counts and bans import()/surface() alongside
include/use."
```

## Task 10: `Tools::OpenscadController`

**Files:**
- Create: `app/controllers/tools/openscad_controller.rb`, `app/helpers/tools/openscad_helper.rb`

Spec §3.1 in code: **both `.scad` sources resolve to source text before anything renders**, so
`#preview` and `#create` cannot tell a catalog generator from a bring-your-own file.

- [ ] **Step 1: Implement the helper**

Create `app/helpers/tools/openscad_helper.rb`:

```ruby
module Tools
  module OpenscadHelper
    # Build the editor URL that PREFILLS the form from a saved design's params.
    #
    # `:params` is a RESERVED url_for option: it appends its hash straight onto the query string, so
    # the flat form emits `?...&cols=4` and `new`'s `params[:params]` read sees nil — the form
    # silently doesn't prefill. Nesting one level emits `?...&params[cols]=4`, which is exactly what
    # the fields (`params[<name>]`) and `new` expect. Do NOT "simplify" this. (Same trap already
    # documented and tested in Tools::BoxesHelper — it shipped broken there once.)
    def openscad_prefill_path(source_key, scad_params)
      new_tools_openscad_path(**source_key, params: { params: scad_params || {} })
    end

    # A saved design's source, as the {generator:} or {node_id:} pair `new` expects.
    def openscad_source_key(state)
      state.data["node_id"].present? ? { node_id: state.data["node_id"] } : { generator: state.data["generator"] }
    end
  end
end
```

- [ ] **Step 2: Implement the controller**

Create `app/controllers/tools/openscad_controller.rb`:

```ruby
require "json"

module Tools
  # The OpenSCAD addon. Rails owns the UI, param handling, auth and save-to-library; the sidecar
  # (via OpenscadClient) only renders.
  #
  # THE CENTRAL DESIGN POINT (spec §3.1): there is ONE render path and TWO sources of .scad. Every
  # action resolves its source to TEXT first — a catalog key via the sidecar's /source, a
  # bring-your-own file via FileLayer#read — and from there nothing downstream can tell them apart.
  # Do not add a `generator_key` fast path that lets the sidecar resolve the catalog itself: two
  # paths means two caches, two error surfaces, and a catalog that can drift from BYO behaviour.
  class OpenscadController < BaseController
    include Tools::LibraryFolders

    ADDON_KEY = "openscad".freeze
    before_action :require_openscad!

    def index
      @generators = client.generators
      @scad_files = library_scad_files
      @saved = current_user.maker_addon_states.for_addon(ADDON_KEY)
                           .includes(:files).order(updated_at: :desc, id: :desc)
    end

    def new
      @source = resolve_source
      return redirect_to(tools_openscad_path, alert: "Unknown generator.") if @source.nil?

      @param_groups = @source[:param_groups]
      @values = params[:params]&.to_unsafe_h || {} # optional prefill ("duplicate & tweak")
      # BEFORE folder_options: ensures the project folder exists so it is a selectable option.
      @default_parent_node_id = current_project_folder_node_id
      @folders = folder_options
      @prior = prior_designs_for(@source)
    rescue OpenscadClient::Error, FileLayer::NotFound, FileLayer::FetchError => e
      redirect_to tools_openscad_path, alert: "Couldn't read that generator: #{e.message}"
    end

    # POST /tools/openscad/preview -> PNG, inline.
    # Renders 3MF then rasterizes it server-side through the SAME preview renderer the library uses,
    # rather than shipping a mesh to the browser — matching Boxes' "rasterize server-side, never
    # inline untrusted markup" posture.
    def preview
      scad = source_text!
      bytes = client.render(scad:, params: scad_params)
      png = Maker::Previews::ThreeMf.render(bytes, size: 512)
      send_data png[:bytes], type: png[:content_type], disposition: "inline"
    rescue OpenscadClient::Error, Maker::Previews::ThreeMf::NoThumbnail => e
      render plain: e.message, status: :unprocessable_entity
    rescue FileLayer::NotFound, FileLayer::FetchError => e
      render plain: e.message, status: :unprocessable_entity
    end

    # POST /tools/openscad -> save the state + write the tied bundle (3mf output + params file).
    def create
      scad = source_text!
      p = scad_params
      bytes = client.render(scad:, params: p)

      state = current_user.maker_addon_states.create!(
        addon_key: ADDON_KEY, name: params.require(:name),
        # Record WHICH source produced this so `show` and "duplicate & tweak" can reopen it. We do
        # NOT store the .scad itself (spec §6.1): for a bring-your-own file that would copy a
        # possibly restrictively-licensed design around the user's library and into any future
        # share/export path. params.json records what was rendered; the source stays where the user
        # put it.
        data: { generator: params[:generator], node_id: params[:node_id], params: p }.compact
      )
      base = state.name.parameterize.presence || "model"
      addon_files = Maker::Addons::LibraryOutput.write(
        user: current_user, state:, parent_node_id: chosen_parent_node_id,
        files: [
          { name: "#{base}-#{state.id}.3mf", bytes:, content_type: "model/3mf", role: "output" },
          { name: "#{base}-#{state.id}.params.json",
            bytes: JSON.pretty_generate(state.data), content_type: "application/json",
            role: "parameters" }
        ]
      )
      attach_addon_files_to_current_project(addon_files)
      redirect_to tools_openscad_design_path(state), notice: "Saved “#{state.name}”."
    rescue OpenscadClient::Error, FileLayer::NotFound, FileLayer::FetchError => e
      redirect_to tools_openscad_path, alert: "Generation failed: #{e.message}"
    end

    def show
      @state = current_user.maker_addon_states.for_addon(ADDON_KEY).find(params[:id])
    end

    private

    def client = OpenscadClient.current

    def require_openscad!
      return if OpenscadClient.configured? || OpenscadClient.stubbed?

      redirect_to tools_path, alert: "OpenSCAD isn't configured on this deployment."
    end

    # --- the two sources, resolved to ONE thing: text -----------------------------------------

    # -> .scad source text for whichever source this request names. Raises rather than returning
    # nil: #preview and #create both have a rescue that turns these into a 422/alert.
    def source_text!
      if params[:node_id].present?
        FileLayer.current.read(current_user, node_id: own_scad_node_id!)
      else
        client.source(params.require(:generator))
      end
    end

    # -> { title:, subtitle:, key:, param_groups: } or nil, for the editor heading + form.
    def resolve_source
      if params[:node_id].present?
        node_id = own_scad_node_id!
        node = current_user.nodes.present.find_by(node_id:)
        scad = FileLayer.current.read(current_user, node_id:)
        { title: node.name, subtitle: "Your file", node_id:,
          param_groups: client.params_for(scad)["param_groups"] }
      else
        g = client.generators.find { |x| x.key == params[:generator] }
        return nil unless g

        { title: g.title, subtitle: "#{g.description} · #{g.license}", generator: g.key,
          license: g.license, attribution: g.attribution, source_url: g.source_url,
          param_groups: g.param_groups }
      end
    end

    # SCOPED to the user's own live files, so a forged or foreign node_id can neither read someone
    # else's bytes nor be handed to FileLayer#read at all. Raises NotFound (caught by the callers'
    # rescue) rather than returning nil, so a bad id can never fall through to a nil read.
    def own_scad_node_id!
      id = current_user.nodes.present.find_by(node_id: params[:node_id], kind: "file")&.node_id
      raise FileLayer::NotFound, "no such .scad in your library" if id.nil?

      id
    end

    # The user's .scad files, for the bring-your-own picker. `.scad` is matched case-insensitively
    # because a NAS or an S3 bucket will happily hold `Part.SCAD`.
    def library_scad_files
      current_user.nodes.present.where(kind: "file")
                  .where("LOWER(name) LIKE ?", "%.scad")
                  .order(:name).pluck(:node_id, :name)
    end

    # Saved designs made from THIS same source, newest first. Filtered in Ruby, not SQL: `data` is a
    # JSON column and `data->>'generator'` is Postgres-only, which would break the SQLite/Postgres
    # adapter-agnostic rule (CLAUDE.md §14). One user's saved designs is a small set.
    def prior_designs_for(source)
      key, value = source[:node_id] ? [ "node_id", source[:node_id] ] : [ "generator", source[:generator] ]
      current_user.maker_addon_states.for_addon(ADDON_KEY)
                  .includes(:files).order(updated_at: :desc, id: :desc)
                  .select { |s| s.data[key] == value }
    end

    # A flat hash of the generator's fields. The sidecar validates against the real Customizer
    # schema; this is a plain pass-through of the submitted values.
    def scad_params
      params[:params]&.to_unsafe_h || {}
    end
  end
end
```

- [ ] **Step 3: Commit (tests land in Task 12)**

```bash
git add app/controllers/tools/openscad_controller.rb app/helpers/tools/openscad_helper.rb
git commit -m "feat(openscad): controller resolving both .scad sources to one render path

Spec §3.1 in code: a catalog key and a bring-your-own library file are both
resolved to SOURCE TEXT before anything renders, so #preview and #create cannot
tell them apart. No generator_key fast path — that would mean two caches, two
error surfaces, and a catalog free to drift from BYO behaviour.

The .scad itself is deliberately NOT written back into the library (spec §6.1):
for a bring-your-own file that would copy a possibly restrictively-licensed
design around the user's library and into any future share/export path.
params.json records what was rendered; the source stays where the user put it.

A bring-your-own node_id is resolved against the user's OWN live files and
RAISES when it doesn't match, so a forged or foreign id can never reach
FileLayer#read. Prior-design filtering happens in Ruby because data->>'generator'
is Postgres-only and would break the adapter-agnostic rule."
```

---

## Task 11: Views

**Files:**
- Create: `app/views/tools/openscad/{index,new,show}.html.erb`, `_form.html.erb`, `_field.html.erb`

Cloned from `tools/boxes` per spec §6. The duplication is deliberate: the two schemas genuinely
differ (OpenSCAD has min/max/step and vector params; boxes has markdown manual links), and
refactoring a deployed addon's views to share a partial is a bigger risk than two small files.

- [ ] **Step 1: `_field.html.erb`**

```erb
<%#
  One parameter field. Locals: param (Hash{name,type,default,help,choices,choice_labels,min,max,step}),
  values (Hash prefill). Every field posts as params[<name>] regardless of its group.
%>
<% pname = param["name"] %>
<% val = (values && values[pname]) %>
<% val = param["default"] if val.nil? %>
<label class="box-field">
  <span class="box-field-label">
    <%= pname %>
    <% if param["help"].present? %><span class="muted">— <%= param["help"] %></span><% end %>
  </span>
  <% if param["choices"].present? %>
    <%# choice VALUES and LABELS are separate: OpenSCAD's `// [10:S,20:M]` gives a numeric value a
        human label, and posting the label back would be a type error. %>
    <select name="params[<%= pname %>]">
      <% param["choices"].each_with_index do |c, i| %>
        <option value="<%= c %>" <%= "selected" if c.to_s == val.to_s %>>
          <%= (param["choice_labels"] || [])[i] || c %>
        </option>
      <% end %>
    </select>
  <% elsif param["type"] == "bool" %>
    <input type="hidden" name="params[<%= pname %>]" value="false">
    <input type="checkbox" name="params[<%= pname %>]" value="true" <%= "checked" if val.to_s == "true" %>>
  <% elsif param["type"] == "vector" %>
    <%# A vector is edited as comma-separated text; the sidecar re-brackets it into [a,b,c]. %>
    <input type="text" name="params[<%= pname %>]" value="<%= val %>" placeholder="10,20,30">
  <% elsif %w[float int].include?(param["type"]) %>
    <input type="number" step="<%= param["type"] == "int" ? (param["step"] || 1) : "any" %>"
           <% if param["min"] %>min="<%= param["min"] %>"<% end %>
           <% if param["max"] %>max="<%= param["max"] %>"<% end %>
           name="params[<%= pname %>]" value="<%= val %>">
  <% else %>
    <input type="text" name="params[<%= pname %>]" value="<%= val %>">
  <% end %>
</label>
```

- [ ] **Step 2: `_form.html.erb`**

```erb
<%#
  Grouped param form. Each group from the sidecar becomes a section: ordinary groups are open
  <fieldset>s; a group the sidecar flagged advanced collapses into <details> so the common
  dimensions stay front and centre. Advanced fields stay in the DOM, so they are always submitted.
  Locals: param_groups (Array<Hash>), values (Hash, optional prefill).
%>
<% param_groups.each do |grp| %>
  <% if grp["advanced"] %>
    <details class="param-group param-group-adv">
      <summary><%= grp["title"] %></summary>
      <div class="box-params">
        <% grp["params"].each do |param| %><%= render "field", param:, values: %><% end %>
      </div>
    </details>
  <% else %>
    <fieldset class="param-group">
      <legend><%= grp["title"] %></legend>
      <div class="box-params">
        <% grp["params"].each do |param| %><%= render "field", param:, values: %><% end %>
      </div>
    </fieldset>
  <% end %>
<% end %>
```

- [ ] **Step 3: `index.html.erb`**

```erb
<% content_for :title, "OpenSCAD — Tinkerex" %>

<div class="page-head"><h1>🧊 OpenSCAD</h1></div>

<section class="box-generators" data-controller="boxfilter">
  <h2>Bundled generators</h2>
  <input type="search" class="box-search" placeholder="Filter generators…"
         aria-label="Filter generators"
         data-boxfilter-target="query" data-action="input->boxfilter#filter">

  <div class="box-group" data-boxfilter-target="group">
    <div class="tools-grid">
      <% @generators.each do |g| %>
        <%= link_to new_tools_openscad_path(generator: g.key), class: "addon-card",
                    data: { boxfilter_target: "card", terms: "#{g.title} #{g.key}".downcase } do %>
          <span class="addon-title"><%= g.key %></span>
          <span class="addon-desc muted"><%= g.description %></span>
          <%# The licence is shown on the tile, not buried: these are third-party designs and the
              attribution terms travel with whatever the user generates. %>
          <span class="addon-desc muted"><%= g.license %></span>
        <% end %>
      <% end %>
    </div>
  </div>
  <p class="box-noresults muted" data-boxfilter-target="empty" hidden>No generators match your filter.</p>
</section>

<section class="box-generators">
  <h2>Your own .scad</h2>
  <% if @scad_files.empty? %>
    <p class="muted">
      No <code>.scad</code> files in your library yet — <%= link_to "upload one", files_path %>
      and it will appear here.
    </p>
  <% else %>
    <ul class="saved-boxes">
      <% @scad_files.each do |node_id, name| %>
        <li><%= link_to name, new_tools_openscad_path(node_id: node_id) %></li>
      <% end %>
    </ul>
  <% end %>
</section>

<h2>Saved designs</h2>
<% if @saved.empty? %>
  <p class="muted">No saved designs yet.</p>
<% else %>
  <ul class="saved-boxes">
    <% @saved.each do |s| %>
      <li>
        <%= link_to s.name, tools_openscad_design_path(s) %>
        <div class="muted">
          <%= s.data["generator"] || "your .scad" %> · <%= s.updated_at.strftime("%Y-%m-%d") %>
        </div>
      </li>
    <% end %>
  </ul>
<% end %>
```

- [ ] **Step 4: `new.html.erb`**

```erb
<% content_for :title, "#{@source[:title]} — OpenSCAD" %>

<div class="page-head">
  <div>
    <h1><%= @source[:title] %></h1>
    <p class="page-subtitle muted"><%= @source[:subtitle] %></p>
  </div>
  <%= link_to "Back", tools_openscad_path, class: "btn ghost" %>
</div>

<div class="box-editor" data-controller="boxpreview"
     data-boxpreview-url-value="<%= preview_tools_openscad_path %>">
  <%= form_with url: tools_openscad_path, method: :post, data: { boxpreview_target: "form" } do %>
    <%# Carry whichever source this editor is for, so preview and create resolve the same one. %>
    <% if @source[:generator] %>
      <input type="hidden" name="generator" value="<%= @source[:generator] %>">
    <% else %>
      <input type="hidden" name="node_id" value="<%= @source[:node_id] %>">
    <% end %>

    <label class="box-field">
      <span class="box-field-label">Name</span>
      <input type="text" name="name" required>
    </label>

    <label class="box-field">
      <span class="box-field-label">Save to folder</span>
      <%= select_tag :parent_node_id, options_for_select(@folders, @default_parent_node_id) %>
    </label>

    <% if @param_groups.blank? %>
      <p class="muted">
        This file exposes no Customizer parameters. OpenSCAD only offers top-level assignments with
        literal values that appear before the first <code>{</code> — you can still render it as-is.
      </p>
    <% end %>
    <%= render "form", param_groups: @param_groups, values: @values %>

    <div class="page-actions">
      <button type="button" data-action="boxpreview#preview" class="btn ghost">Preview</button>
      <button type="submit" class="btn">Save to library</button>
    </div>
  <% end %>

  <aside class="box-side">
    <div class="preview box-preview">
      <img data-boxpreview-target="image" alt="Model preview" class="preview-image">
    </div>

    <% if @source[:attribution].present? %>
      <p class="muted">
        <%= @source[:attribution] %>
        <% if @source[:source_url].present? %>
          — <%= link_to "source", @source[:source_url], target: "_blank", rel: "noopener noreferrer" %>
        <% end %>
      </p>
    <% end %>

    <% if @prior.any? %>
      <div class="box-prior" data-controller="thumbs" data-thumbs-url-value="<%= thumbnails_files_path %>">
        <h3>Made with this</h3>
        <ul class="box-prior-list">
          <% @prior.each do |s| %>
            <% out = s.files.find { |f| f.role == "output" } %>
            <%= tag.li class: "box-prior-item",
                       data: (out ? { thumbs_target: "cell", node_id: out.node_id, ext: "3MF" } : {}) do %>
              <% if out %>
                <%= render "files/thumb", thumb: nil, ext_label: "3MF" %>
              <% end %>
              <div class="box-prior-meta">
                <div class="box-prior-name"><%= s.name %></div>
                <div class="box-prior-date"><%= s.updated_at.strftime("%Y-%m-%d") %></div>
              </div>
              <%= link_to "Load", openscad_prefill_path(openscad_source_key(s), s.data["params"]),
                          aria: { label: "Load #{s.name}" } %>
            <% end %>
          <% end %>
        </ul>
      </div>
    <% end %>
  </aside>
</div>
```

- [ ] **Step 5: `show.html.erb`**

```erb
<% content_for :title, "#{@state.name} — OpenSCAD" %>

<div class="page-head">
  <h1><%= @state.name %></h1>
  <%= link_to "Back", tools_openscad_path, class: "btn ghost" %>
</div>

<dl class="meta">
  <dt>Source</dt><dd><%= @state.data["generator"] || "your .scad" %></dd>
  <dt>Saved</dt><dd><%= @state.created_at.strftime("%Y-%m-%d %H:%M") %></dd>
</dl>

<h2>Bundle</h2>
<%# The tied files: the 3MF output AND the parameters that made it. %>
<ul class="bundle-files">
  <% @state.files.each do |af| %>
    <li><%= link_to af.role, file_path(af.node_id) %>
        <span class="muted mono"><%= af.content_type %></span></li>
  <% end %>
</ul>

<%= link_to "Duplicate & tweak",
      openscad_prefill_path(openscad_source_key(@state), @state.data["params"]),
      class: "btn ghost" %>
```

- [ ] **Step 6: Commit**

```bash
git add app/views/tools/openscad/
git commit -m "feat(openscad): addon views

Cloned from tools/boxes rather than sharing partials: the two schemas genuinely
differ (OpenSCAD carries min/max/step and vector params; boxes carries markdown
manual links), and refactoring a deployed addon's views to share is a bigger
risk than two small files.

Two things the field partial gets right that a copy would not: enum VALUES and
LABELS stay separate, because OpenSCAD's '// [10:S,20:M]' syntax gives a numeric
value a human label and posting the label back would be a type error; and a
vector is edited as comma-separated text, which the sidecar re-brackets.

The editor carries whichever source it was opened for (generator key or library
node_id) in a hidden field, so preview and create resolve the same one. Each
bundled generator's LICENCE is shown on its tile and its attribution beside the
editor — these are third-party designs and the terms travel with the output."
```

## Task 12: Controller tests — including the one that must not be vacuous

**Files:**
- Modify: `test/controllers/tools/openscad_controller_test.rb` (created in Task 9)

> **Spec §11's requirement, quoted:** *"the create path must assert the bundle actually landed — two
> `AddonFile`s with the right roles and a real node in the library — not merely that the controller
> redirected. The Phase 4 lesson in CLAUDE.md is that a gating test which mints its object in Ruby
> instead of driving the real endpoint stays green for the wrong reason."*

- [ ] **Step 1: Add the tests**

Append inside the existing `OpenscadControllerTest` class:

```ruby
    # --- the catalog source ------------------------------------------------------------------

    test "index lists both the bundled catalog and the user's own .scad files" do
      @user.nodes.create!(node_id: SecureRandom.uuid, name: "bracket.scad", kind: "file")
      get tools_openscad_path
      assert_response :success
      assert_select ".addon-card .addon-title", text: "hex_plate"
      assert_select "a[href=?]", new_tools_openscad_path(node_id: @user.nodes.last.node_id)
    end

    test "index shows each bundled generator's licence on its tile" do
      # These are third-party designs; the attribution terms travel with whatever the user makes.
      get tools_openscad_path
      assert_response :success
      assert_select ".addon-card", text: /MIT/
    end

    test "new renders a grouped form from the generator's own Customizer params" do
      get new_tools_openscad_path(generator: "hex_plate")
      assert_response :success
      assert_select "fieldset.param-group > legend", text: "Grid"
      assert_select "fieldset.param-group input[name=?]", "params[cols]"
      assert_select "details.param-group-adv > summary", text: "Advanced"
      assert_select "details.param-group-adv select[name=?]", "params[mode]"
    end

    test "an enum renders its LABELS while submitting its VALUES" do
      # OpenSCAD's `// [1:solid, 2:hollow]` gives a numeric value a human label. Posting the label
      # back would be a type error, so the two must not be conflated.
      get new_tools_openscad_path(generator: "hex_plate")
      assert_response :success
      assert_select "select[name='params[mode]'] option[value='1']", text: /solid/
    end

    test "an unknown generator redirects instead of 500ing" do
      get new_tools_openscad_path(generator: "no-such-generator")
      assert_redirected_to tools_openscad_path
    end

    # --- the bring-your-own source -----------------------------------------------------------

    test "new builds a form from a .scad in the user's own library" do
      node = create_scad_node("bracket.scad")
      get new_tools_openscad_path(node_id: node.node_id)
      assert_response :success
      assert_select ".page-head h1", text: "bracket.scad"
      assert_select "input[name=?]", "params[cols]"
      assert_select "input[type=hidden][name='node_id'][value=?]", node.node_id
    end

    test "a node_id belonging to ANOTHER user is refused, not read" do
      other = User.create!(email: "other-oscad@example.com", password: PASSWORD, confirmed_at: Time.current)
      foreign = other.nodes.create!(node_id: SecureRandom.uuid, name: "theirs.scad", kind: "file")
      get new_tools_openscad_path(node_id: foreign.node_id)
      assert_redirected_to tools_openscad_path
    end

    test "create refuses a foreign node_id rather than rendering it" do
      other = User.create!(email: "other2-oscad@example.com", password: PASSWORD, confirmed_at: Time.current)
      foreign = other.nodes.create!(node_id: SecureRandom.uuid, name: "theirs.scad", kind: "file")
      assert_no_difference("Maker::AddonState.count") do
        post tools_openscad_path, params: { name: "Nope", node_id: foreign.node_id, params: {} }
      end
      assert_redirected_to tools_openscad_path
    end

    # --- render / preview / create ------------------------------------------------------------

    test "preview returns a PNG rasterized from the rendered 3MF" do
      post preview_tools_openscad_path, params: { generator: "hex_plate", params: { cols: 6 } }
      assert_response :success
      assert_includes %w[image/png image/jpeg], response.media_type
    end

    test "a sidecar error becomes a 422, never a 500" do
      OpenscadClient.stub = Class.new(FakeOpenscad) do
        def render(**) = raise(OpenscadClient::Error, "Parser error: syntax error")
      end.new
      post preview_tools_openscad_path, params: { generator: "hex_plate", params: {} }
      assert_response :unprocessable_entity
      assert_match "Parser error", response.body
    end

    # THE TEST SPEC §11 SINGLES OUT. Asserts the bundle actually LANDED — two AddonFiles with the
    # right roles AND real nodes in the library — not merely that the controller redirected.
    test "create writes a real 3mf + params.json bundle into the library" do
      assert_difference("Maker::AddonState.count", 1) do
        post tools_openscad_path, params: { name: "My Plate", generator: "hex_plate",
                                            params: { cols: 6, wall: 2.0 } }
      end
      state = @user.maker_addon_states.for_addon("openscad").order(:id).last

      assert_equal %w[output parameters], state.files.map(&:role)
      assert_equal [ "model/3mf", "application/json" ], state.files.map(&:content_type)

      # Real nodes, not just join rows.
      state.files.each { |af| assert @user.nodes.exists?(node_id: af.node_id), "no node for #{af.role}" }

      out = state.files.find { |f| f.role == "output" }
      node = @user.nodes.find_by(node_id: out.node_id)
      assert node.name.end_with?(".3mf"), "output should be a .3mf, got #{node.name}"

      # The BYTES landed and are a real 3MF container — the whole point of the bundle. Reading them
      # back through FileLayer also proves this passes identically on chunk, share and s3.
      bytes = FileLayer.current.read(@user, node_id: out.node_id)
      assert_equal "PK", bytes[0, 2], "output is not a zip/OPC container"

      # The params file records what was rendered, so the design can be reproduced.
      params_node = state.files.find { |f| f.role == "parameters" }
      saved = JSON.parse(FileLayer.current.read(@user, node_id: params_node.node_id))
      assert_equal "hex_plate", saved["generator"]
      assert_equal "6", saved["params"]["cols"].to_s

      assert_redirected_to tools_openscad_design_path(state)
    end

    test "create does NOT write the .scad source into the library" do
      # Spec §6.1: for a bring-your-own file that would copy a possibly restrictively-licensed
      # design around the user's library and into any future share/export path.
      node = create_scad_node("private.scad")
      post tools_openscad_path, params: { name: "From Mine", node_id: node.node_id, params: {} }
      state = @user.maker_addon_states.for_addon("openscad").order(:id).last
      names = @user.nodes.where(node_id: state.files.map(&:node_id)).pluck(:name)
      assert_empty names.grep(/\.scad\z/), "the .scad source must not be copied into the library"
    end

    test "create saves the bundle into the chosen folder" do
      folder = @user.nodes.create!(node_id: SecureRandom.uuid, name: "CNC", kind: "dir")
      captured = :unset
      original = Maker::Addons::LibraryOutput.method(:write)
      Maker::Addons::LibraryOutput.define_singleton_method(:write) do |user:, state:, parent_node_id:, files:|
        captured = parent_node_id
        []
      end
      begin
        post tools_openscad_path, params: { name: "Placed", generator: "hex_plate", params: {},
                                            parent_node_id: folder.node_id }
      ensure
        Maker::Addons::LibraryOutput.define_singleton_method(:write, original)
      end
      assert_equal folder.node_id, captured
    end

    test "create attaches both output files to the current project" do
      project = @user.maker_projects.create!(name: "Desk Lamp")
      folder = project.ensure_library_folder!(@user)
      patch current_project_path, params: { project_id: project.id }
      assert_difference "project.file_attachments.count", 2 do
        post tools_openscad_path, params: { name: "Cur", generator: "hex_plate", params: {},
                                            parent_node_id: folder.node_id }
      end
    end

    test "show reopens a saved design and offers a prefilled duplicate link" do
      post tools_openscad_path, params: { name: "Reopen Me", generator: "hex_plate",
                                          params: { cols: 9 } }
      state = @user.maker_addon_states.for_addon("openscad").order(:id).last
      get tools_openscad_design_path(state)
      assert_response :success
      assert_select "*", text: /Reopen Me/
      # WIRE FORMAT, asserted deliberately: params must be NESTED (params[cols]=9), not flattened.
      # `:params` is a reserved url_for option that appends its hash to the query string, so the
      # flat form is silently ignored by #new and nothing prefills. This exact bug shipped in the
      # Boxes addon once; comparing against the helper on both sides would reproduce it and pass.
      href = css_select("a").map { |a| a["href"] }.compact.find { |h| h.include?("params%5B") }
      assert href, "expected a prefill link with nested params"
      assert_includes href, "params%5Bcols%5D=9"

      get href
      assert_response :success
      assert_select "input[name='params[cols]'][value=?]", "9"
    end

    test "the addon greys out on a deployment with no sidecar" do
      OpenscadClient.reset!
      with_env("OPENSCAD_SIDECAR_URL" => nil) do
        get tools_path
        assert_response :success
        assert_select ".addon-card.disabled .addon-title", text: "OpenSCAD"
        get tools_openscad_path
        assert_redirected_to tools_path
      end
    end

    private

    # A .scad file in the user's library, with real bytes, written through whichever FileLayer
    # backend this leg is running — so the BYO read path is exercised on chunk, share and s3.
    def create_scad_node(name)
      src = "/* [Grid] */\n// number of columns\ncols = 4;\ncube([cols, 1, 1]);\n"
      info = Maker::Addons::LibraryOutput.write(
        user: @user,
        state: @user.maker_addon_states.create!(addon_key: "test-fixture", name: "fixture-#{name}"),
        parent_node_id: nil,
        files: [ { name:, bytes: src, content_type: "text/plain", role: "output" } ]
      ).first
      @user.nodes.find_by(node_id: info.node_id)
    end

    def with_env(vars)
      old = {}
      vars.each { |k, v| old[k] = ENV.key?(k) ? ENV[k] : :unset; v.nil? ? ENV.delete(k) : (ENV[k] = v) }
      yield
    ensure
      old.each { |k, v| v == :unset ? ENV.delete(k) : (ENV[k] = v) }
    end
```

- [ ] **Step 2: Run on the default (chunk) backend**

```bash
bin/rails test test/controllers/tools/openscad_controller_test.rb
```

Expected: all green.

- [ ] **Step 3: Run on all three backends — `LibraryOutput` is backend-branching**

```bash
bin/rails test test/controllers/tools/openscad_controller_test.rb
LIBRARY_BACKEND=share bin/rails test test/controllers/tools/openscad_controller_test.rb
LIBRARY_BACKEND=s3    bin/rails test test/controllers/tools/openscad_controller_test.rb
```

Expected: identical counts on all three. A test that passes on chunk and fails on share is almost always the fixture helper, not the controller.

- [ ] **Step 4: Mutation-check the create test**

Spec §11's warning is that this test could pass for the wrong reason. Prove it cannot:

```bash
# Temporarily make create write only ONE file, then confirm the test goes RED.
# (Edit app/controllers/tools/openscad_controller.rb: delete the params.json entry from `files:`.)
bin/rails test test/controllers/tools/openscad_controller_test.rb -n "/writes a real 3mf/"
```

Expected: **FAIL** on `assert_equal %w[output parameters]`. Revert the edit and confirm green again. Record in the commit that the mutation check was run.

- [ ] **Step 5: Commit**

```bash
git add test/controllers/tools/openscad_controller_test.rb
git commit -m "test(openscad): full UI flow, both sources, all three backends

The create test asserts what spec §11 demands and what CLAUDE.md's Phase 4
lesson says is easy to fake: two AddonFiles with the right roles, real nodes in
the library, and the BYTES read back through FileLayer and confirmed to be a
zip/OPC container. Reading through FileLayer is also what makes it meaningful on
share and s3, not just chunk. Mutation-checked: dropping params.json from the
bundle turns it RED.

Also covered: a foreign node_id is refused rather than read (both #new and
#create); the .scad source is NOT copied into the library (spec §6.1); a sidecar
error is 422 not 500; enum labels render while values submit; and the prefill
link's NESTED params wire format, which shipped broken in Boxes once because
:params is a reserved url_for option that silently flattens."
```

---

## Task 13: Live integration test

**Files:**
- Create: `test/integration/tools/openscad_live_test.rb`

Clone of `boxes_live_test.rb`: drives the REAL client against a live sidecar, skips cleanly without one.

- [ ] **Step 1: Write it**

```ruby
require "test_helper"

module Tools
  # Drives the REAL OpenscadClient (no stub) against a live sidecar. Skips cleanly when
  # OPENSCAD_SIDECAR_URL is unset — the same "skips with no server" pattern the sync-engine
  # integration suite uses. Run it against the Task 2 container:
  #   docker run -d --name oscad -p 18000:8000 openscad-sidecar
  #   OPENSCAD_SIDECAR_URL=http://localhost:18000 bin/rails test test/integration/tools/openscad_live_test.rb
  class OpenscadLiveTest < ActiveSupport::TestCase
    setup do
      skip "set OPENSCAD_SIDECAR_URL to run against a live openscad sidecar" if ENV["OPENSCAD_SIDECAR_URL"].blank?
      OpenscadClient.reset!
    end

    test "lists the bundled catalog with licences and derived params" do
      gens = OpenscadClient.current.generators
      assert gens.any?, "expected a non-empty catalog"
      g = gens.first
      assert g.license.present?, "every bundled generator must carry its licence"
      assert g.param_groups.any?, "#{g.key} derived no parameter groups"
    end

    test "derives a Customizer schema from arbitrary source" do
      src = "/* [G] */\n// how many\ncols = 4;\nwall = 1.5;\ncube([cols, wall, 1]);\n"
      names = OpenscadClient.current.params_for(src)["params"].map { |p| p["name"] }
      assert_includes names, "cols"
      assert_includes names, "wall"
    end

    test "renders real 3MF bytes that the preview pipeline can actually read" do
      src = "cols = 3;\ncube([cols, 2, 1]);\n"
      bytes = OpenscadClient.current.render(scad: src, params: { "cols" => 5 })
      assert_equal "PK", bytes[0, 2], "expected a zip/OPC container"
      # END-TO-END: the thumbnail is the user-visible payoff (spec §6.1 verified the mesh fallback
      # exists; this proves it works on OUR bytes). A pass here is what makes DoD #4 credible.
      assert Maker::Previews::ThreeMf.mesh_to_stl(bytes).to_s.bytesize.positive?,
             "ThreeMf could not read a mesh out of the sidecar's 3MF — thumbnails would be blank"
    end

    test "a repeat render of identical params is a cache hit" do
      src = "cols = 7;\ncube([cols, 1, 1]);\n"
      a = OpenscadClient.current.render(scad: src, params: {})
      t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      b = OpenscadClient.current.render(scad: src, params: {})
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t
      assert_equal a, b, "a cache hit must return identical bytes"
      assert elapsed < 1.0, "expected a cache hit to be fast, took #{elapsed.round(2)}s"
    end

    test "a broken .scad raises a client Error carrying OpenSCAD's own complaint" do
      e = assert_raises(OpenscadClient::Error) do
        OpenscadClient.current.render(scad: "this is not scad {{{", params: {})
      end
      assert e.message.present?
    end
  end
end
```

- [ ] **Step 2: Run it against a live sidecar**

```bash
docker run -d --name oscad-live -p 18000:8000 openscad-sidecar
OPENSCAD_SIDECAR_URL=http://localhost:18000 bin/rails test test/integration/tools/openscad_live_test.rb
docker rm -f oscad-live
```

Expected: `5 runs, 0 failures, 0 errors, 0 skips`. **If it says `5 skips`, the env var did not reach the test** and nothing was actually verified — the skip is the failure mode to watch for here.

- [ ] **Step 3: Confirm it skips cleanly without a sidecar**

```bash
bin/rails test test/integration/tools/openscad_live_test.rb
```

Expected: `5 runs, 5 skips` — the default suite must not require Docker.

- [ ] **Step 4: Commit**

```bash
git add test/integration/tools/openscad_live_test.rb
git commit -m "test(openscad): live sidecar integration, skipping without one

Drives the real client over HTTP: catalog + licences, schema derivation from
arbitrary source, real 3MF bytes, the cache hit, and an error carrying OpenSCAD's
own complaint.

The render test also feeds the bytes to Maker::Previews::ThreeMf.mesh_to_stl.
Spec §6.1 established by reading the source that a mesh fallback exists (3MF from
OpenSCAD carries no embedded thumbnail); this proves it works on OUR bytes, which
is what makes the grid thumbnail in DoD #4 a verified claim rather than a
reasoned one."
```

---

## Task 14: Build script + deployment

**Files:**
- Create: `bin/build-openscad-sidecar`
- Modify: `config/deploy.yml`
- Modify: `sidecar/openscad/LICENSE`, `sidecar/openscad/README.md` (create)

- [ ] **Step 1: The build script** — `bin/build-openscad-sidecar`

```bash
#!/usr/bin/env bash
# Build + push the OpenSCAD Python sidecar image (sidecar/openscad) to ghcr. This is a SEPARATE,
# GPL-2.0 image from the Rails app — the app never links it (see sidecar/openscad/README.md, §9).
#
# Requires KAMAL_REGISTRY_PASSWORD in the env (the same ghcr token the app deploy uses):
#   KAMAL_REGISTRY_PASSWORD="$(op read 'op://Personal/ghcr.io/password')" bin/build-openscad-sidecar
# Then boot/update the accessory on the box:  bin/kamal accessory reboot openscad
set -euo pipefail

: "${KAMAL_REGISTRY_PASSWORD:?set KAMAL_REGISTRY_PASSWORD (ghcr token) first}"
IMAGE="ghcr.io/chaim354/openscad-sidecar:latest"

echo "$KAMAL_REGISTRY_PASSWORD" | docker login ghcr.io -u chaim354 --password-stdin
# The box is amd64; build for it (buildx emulates on an arm64 Mac, like the app image). The build
# runs the capability assertions (Manifold + 3MF + param dump), so a push implies they passed.
docker buildx build --platform linux/amd64 -t "$IMAGE" --push sidecar/openscad
echo "pushed $IMAGE"
```

```bash
chmod +x bin/build-openscad-sidecar
```

- [ ] **Step 2: `sidecar/openscad/LICENSE`**

Copy the GPL-2.0 text:

```bash
curl -fsSL -o sidecar/openscad/LICENSE https://www.gnu.org/licenses/old-licenses/gpl-2.0.txt
head -3 sidecar/openscad/LICENSE   # expect: GNU GENERAL PUBLIC LICENSE / Version 2, June 1991
```

- [ ] **Step 3: `sidecar/openscad/README.md`**

```markdown
# openscad-sidecar

A small, **GPL-2.0** service that wraps the OpenSCAD binary and exposes a JSON API the Tinkerex
app's `OpenscadClient` speaks:

- `GET /generators` — the bundled catalog + each generator's derived Customizer schema.
- `GET /source/<key>` — the raw `.scad` for a bundled generator.
- `POST /params` `{scad}` — derive a Customizer schema from **arbitrary** source.
- `POST /render` `{scad, params, format}` — render to **3MF** bytes.
- `GET /up` — health.

## Licensing (important)

This entire directory is **GPL-2.0** (OpenSCAD's licence). It ships as a **separate container** and
is invoked **only over HTTP** on an internal network. The permissive Tinkerex Rails app never
imports or links any of this — that arm's-length aggregation is why the app stays permissive (see
CLAUDE.md §9). **Do not import anything under `sidecar/` into `app/`.**

*Honest note on the boundary:* unlike the boxes sidecar (whose wrapper **imports** the GPL `boxes`
library and is therefore a derivative work), this wrapper only **execs** a binary — arm's length, and
ordinarily mere aggregation. We adopt GPL-2.0 for the whole directory anyway, because the *image*
unquestionably ships GPL software and must carry the licence and a source offer regardless. Cheaper
to be uniform than to litigate the distinction.

**Written offer for source:** the OpenSCAD source corresponding to the binary in this image is
available from <https://github.com/openscad/openscad> at the tag matching `OPENSCAD_VERSION` in the
Dockerfile, and on request from the maintainer of this repository.

Bundled third-party `.scad` generators are **permissive-licensed only** and credited individually in
`catalog/NOTICE`. See spec §2 before adding one: a generator whose *output* carries a NonCommercial
or ShareAlike term does not belong here no matter how good it is.

## The OpenSCAD binary

Extracted from the official x86-64 AppImage, sha256-pinned in the Dockerfile.

**Two things that will bite you if you change that step:**

1. **Do not `./x.AppImage --appimage-extract`.** The AppImage runtime is a static ELF and dies with
   `Exec format error` under Docker Desktop's amd64 emulation — which is how every image in this
   repo is built (an arm64 Mac cross-building, CLAUDE.md §13). The Dockerfile computes the squashfs
   offset from the ELF header and runs `unsquashfs`, executing nothing.
2. **Do not use a distro package.** Debian ships **2021.01 in every suite**, which predates both the
   Manifold backend (~20× faster on the grid-shaped models this addon serves) and
   `--export-format=param`, on which the whole "parameters come from OpenSCAD, not from us" design
   depends.

The Dockerfile **asserts** both capabilities at build time, plus parameter injection, and fails the
build if any is missing. Both are compile-time optional and fail invisibly at runtime — notably, 3MF
export without lib3mf writes nothing and **still exits 0**.

## Security

User-supplied `.scad` is **arbitrary code execution by design** — that is what a generator is.
Bounded by: no secrets and no user data in this container; no published port (kamal network only);
a per-render timeout and address-space cap; and a fresh empty temp dir per render, used as the CWD.

*Accepted and documented:* OpenSCAD's `include <>` / `import()` can read paths inside the container
(verified — a traversing `include` does resolve). Nothing sensitive lives here, so this is noted
rather than mitigated.

## Dev

```sh
python3 -m venv .venv && .venv/bin/pip install -U pip && .venv/bin/pip install -r requirements.txt pytest
.venv/bin/python -m pytest -q          # binary-dependent tests skip on the host
docker buildx build --platform linux/amd64 -t openscad-sidecar .
docker run --rm -v "$PWD/tests:/app/tests" openscad-sidecar \
  sh -c "pip install -q pytest && python -m pytest tests/ -q"    # nothing should skip here
```
```

- [ ] **Step 4: Wire the accessory + env into `config/deploy.yml`**

Under `accessories:`, after the `boxes:` entry:

```yaml
  # The OpenSCAD addon's sidecar (sidecar/openscad) — a SEPARATE GPL-2.0 image, built + pushed with
  # bin/build-openscad-sidecar. NO `port:` -> internal-only, reachable on the kamal network as
  # `tinkerex-openscad`. One accessory serves all three app deployments on this host.
  openscad:
    image: ghcr.io/chaim354/openscad-sidecar:latest
    host: 192.168.1.95
    volumes:
      # The content-addressed render cache. On a volume so it survives an accessory reboot —
      # a cold cache just means the first render of each design pays full price.
      - openscad-cache:/cache
```

In `env: clear:`, after `BOXES_SIDECAR_URL`:

```yaml
    # The OpenSCAD addon's sidecar (the `openscad` accessory below). Internal-only; never published.
    # Unset or blank -> the addon shows as unavailable (graceful). All three app deployments share
    # the one accessory. NOTE: deploy.ovh.yml must blank this — Kamal deep-merges env.clear, so the
    # OVH box would otherwise inherit a hostname that does not resolve there (see §8.1).
    OPENSCAD_SIDECAR_URL: http://tinkerex-openscad:8000
```

- [ ] **Step 5: Confirm Task 1's guard now covers the new variable**

```bash
bin/rails test test/deploy_hygiene_test.rb
```

Expected: **green**. It loops over the `*_SIDECAR_URL` keys `deploy.yml` defines, so it started
guarding `OPENSCAD_SIDECAR_URL` the moment Step 4 added it — and Task 1 already blanked it in the
OVH overlay. If this goes red, the overlay is missing the blank.

- [ ] **Step 6: Commit**

```bash
git add bin/build-openscad-sidecar sidecar/openscad/LICENSE sidecar/openscad/README.md config/deploy.yml
git commit -m "feat(openscad): build script, GPL-2.0 licence + README, Kamal accessory

Internal-only accessory (no port:), reachable as tinkerex-openscad on the kamal
network, with the render cache on a volume so it survives a reboot. One
accessory serves all three app deployments on the host.

OPENSCAD_SIDECAR_URL is added to deploy.yml only — the OVH overlay already
blanks it (Task 1), and test/deploy_hygiene_test.rb picks the new variable up
automatically because it loops over whatever *_SIDECAR_URL keys deploy.yml
defines.

The README records the two AppImage traps in the place someone editing that step
will actually be standing: --appimage-extract cannot run under the arm64 Mac's
amd64 emulation that builds every image here, and a distro package would be
2021.01, predating both Manifold and --export-format=param."
```

---

## Task 15: Docs + full verification

**Files:**
- Modify: `docs/STATUS.md`, `docs/addon-backlog.md`, `CLAUDE.md`

- [ ] **Step 1: Strike Engine ① off the backlog**

In `docs/addon-backlog.md`, replace the `### Engine ① — OpenSCAD sidecar…` heading line with:

```markdown
### Engine ① — OpenSCAD sidecar (GPL-isolated) · `.scad` + params → 3MF ✅ **BUILT** (2026-07-27)
Shipped as the `/tools/openscad` addon: `sidecar/openscad` + `OpenscadClient`, bundled permissive
catalog + bring-your-own `.scad` from the library, content-addressed render cache, 3MF output with
a grid thumbnail. Spec: `docs/superpowers/specs/2026-07-27-openscad-sidecar-addon-design.md`.
**Multiboard is NOT and will not be in the bundled catalog** — its generated models are CC
BY-NC-SA 4.0 (NonCommercial + ShareAlike, on the output). It is served by the bring-your-own path.
Remaining ideas below are now "add a `.scad` to the catalog", not new engine work:
```

- [ ] **Step 2: Add a `docs/STATUS.md` entry**

Append to the addon section:

```markdown
### OpenSCAD addon (2026-07-27)

`/tools/openscad` — the second server-sidecar addon and the first that renders 3D. A user picks a
bundled generator or points the tool at their own `.scad` in the library, fills in a form derived
from the file's **own** Customizer parameters, and gets a `3mf` + `params.json` bundle written
through `Maker::Addons::LibraryOutput` with a working grid thumbnail.

- **Sidecar:** `sidecar/openscad` (GPL-2.0, internal-only, `tinkerex-openscad:8000`). Extracts the
  official OpenSCAD **2026.07.26** AppImage, sha256-pinned. Content-addressed render cache on the
  `openscad-cache` volume.
- **Env:** `OPENSCAD_SIDECAR_URL`. Unset or blank → the tile greys out. **Set on the three Unraid
  deployments only**; `deploy.ovh.yml` blanks it deliberately.
- **Catalog:** four audited permissive generators (CC-BY-4.0 / Unlicense / MIT ×2), vendored at
  pinned commits with `catalog/NOTICE`.

**Things that will bite a future editor** (all observed, not reasoned):
- `--appimage-extract` **fails on the build Mac** (`Exec format error`) — the AppImage runtime is a
  static ELF and amd64 emulation refuses it. The Dockerfile computes the squashfs offset and runs
  `unsquashfs`, executing nothing.
- Both required OpenSCAD capabilities are **compile-time optional and fail invisibly**: 3MF export
  without lib3mf writes nothing and **exits 0**; a missing Manifold backend silently falls back to
  CGAL (~20× slower on grids). The Dockerfile asserts both at build time.
- `--export-format=param` **omits the `parameters` key entirely** for a file with none; a vector
  reports `type: "number"` with a list `initial`; an enum is `type: number/string` **plus**
  `options`; every number is a float.
- `resources :openscad` would make `tools_openscad_path` the **show** helper (needs an id), and the
  `/tools` gallery calls it with none — routes are explicit for that reason.

**Open:** DoD #5 (a real Multiboard `.scad` driven end-to-end in a browser) is **not closed** — §2
forbids us obtaining the file, so it is the user's to run post-deploy. Not deployed yet.
```

- [ ] **Step 3: Add the addon to `CLAUDE.md` §3's component table**

After the `Library scan` row:

```markdown
| **Addons (Tools)** | `app/services/maker/addons/`, `app/controllers/tools/`, `sidecar/` | The `/tools` gallery + per-addon UI. Output lands via **one** path, `Maker::Addons::LibraryOutput` (backend-neutral: port `write` on share/s3, a single-chunk `Sync::Commit` on chunk). Two addons are **GPL sidecars invoked only over HTTP, never linked** (§9): `sidecar/boxes` (boxes.py → SVG) and `sidecar/openscad` (`.scad` + params → 3MF). **`/sidecar/` is in `.dockerignore`** — the Rails `Dockerfile` does `COPY . .`, so without it the copyleft trees ship inside the permissive app image. Each sidecar's URL env var must be **explicitly blanked in `deploy.ovh.yml`**: Kamal deep-merges `env.clear`, so the OVH box otherwise inherits an Unraid-only hostname and the addon reports available then fails every call. Both facts are guarded by `test/deploy_hygiene_test.rb`. |
```

- [ ] **Step 4: THE FULL VERIFICATION — all three legs**

```bash
bin/rails test 2>&1 | tail -3
LIBRARY_BACKEND=share bin/rails test 2>&1 | tail -3
LIBRARY_BACKEND=s3    bin/rails test 2>&1 | tail -3
```

Expected: **identical** `runs / assertions / failures / errors / skips` on all three, 0 failures and 0 errors. Record the actual numbers in the commit message — do not write "green" without them.

```bash
bin/rubocop
```

Expected: no offenses.

- [ ] **Step 5: Re-verify the sidecar image end to end**

```bash
docker buildx build --platform linux/amd64 --progress=plain -t openscad-sidecar sidecar/openscad 2>&1 | grep -E "^#[0-9]+ [0-9.]+ (assert|ALL)"
docker run --rm -v "$PWD/sidecar/openscad/tests:/app/tests" openscad-sidecar \
  sh -c "pip install -q pytest && python -m pytest tests/ -q" | tail -3
```

Expected: all six `assert:` lines plus `ALL CAPABILITY ASSERTIONS PASSED`, and the full pytest suite passing with **0 skipped**.

- [ ] **Step 6: Drive the real thing in a browser (DoD #3, #4, #6)**

```bash
docker run -d --name oscad-ui -p 18000:8000 openscad-sidecar
OPENSCAD_SIDECAR_URL=http://localhost:18000 bin/rails server -p 3001
```

Check, in the browser:
1. `/tools` shows the OpenSCAD tile as **enabled**. Stop the sidecar and reload — it greys out.
2. `/tools/openscad` lists all four bundled generators with their licences.
3. Open one; the form is grouped and populated from its own parameters; **Preview** shows a PNG.
4. **Save to library** → the bundle appears, and the `.3mf` gets a **grid thumbnail** in `/files`.
5. Upload a `.scad` via `/files`, then open it from the "Your own .scad" section, render and save.
6. Re-render identical params — the second is visibly instant (cache hit).

```bash
docker rm -f oscad-ui
```

- [ ] **Step 7: Commit and open the PR**

```bash
git add docs/ CLAUDE.md
git commit -m "docs(openscad): STATUS + backlog + CLAUDE.md for the OpenSCAD addon

Strikes Engine ① off the addon backlog and records the traps a future editor
will hit: --appimage-extract failing on the build Mac, both OpenSCAD
capabilities being compile-time optional and failing invisibly, the four sharp
edges in --export-format=param, and why the routes are explicit.

Notes DoD #5 as OPEN: driving a real Multiboard .scad end-to-end is the user's
to run, since spec §2 forbids us obtaining the file."
```

Open the PR with a body that states plainly what is **not** done:

```markdown
## Not done, deliberately

- **DoD #5 — a real Multiboard `.scad` driven end-to-end in a browser — is OPEN.** Spec §2 forbids
  us obtaining or redistributing MultiBuild files, so this is yours to run once deployed. The BYO
  code path is covered by tests and was driven with an equivalent `.scad`.
- **Not deployed.** No ghcr push, no `kamal accessory boot`, no live verification on the three
  Unraid backends. `bin/build-openscad-sidecar` and the accessory config are ready.

## Deploy order when you are ready

The app will boot fine without the sidecar (the tile just greys out), but boot the accessory first
so the addon is live the moment the app rolls:

```bash
KAMAL_REGISTRY_PASSWORD="$(op read 'op://Personal/ghcr.io/password')" bin/build-openscad-sidecar
bin/kamal accessory boot openscad
bin/kamal deploy && bin/kamal deploy -d s3 && bin/kamal deploy -d share
```
```

---

## Notes for whoever executes this

- **Task order matters twice.** Task 1 before everything (it clears the ground the sidecar lands
  on, and its test auto-covers Task 14's new env var). Tasks 3–5 before 6, because the catalog test
  imports `schema` and `render`.
- **The three `LIBRARY_BACKEND` legs are not optional.** `LibraryOutput` branches on
  `port_writable?`, so a create test green on chunk proves nothing about share or s3.
- **If a task needs to modify `LibraryOutput`, `AddonState` or `AddonFile`, stop and say so.**
  Spec §6 makes the claim that these absorb a brand-new addon untouched; if that is false, it is
  worth surfacing rather than patching around.
- **Spec §10 is a tripwire.** Nothing here should touch `Sync::*`, the changelog, conflicts, locks
  or the mounts. If you find yourself there, the boundary is wrong.
