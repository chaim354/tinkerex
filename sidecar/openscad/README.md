# openscad-sidecar

A small, **GPL-2.0** service that wraps the OpenSCAD binary and exposes a JSON API the Tinkerex
app's `OpenscadClient` speaks:

- `GET /generators` — the bundled catalog + each generator's derived Customizer schema.
- `GET /source/<key>` — the raw `.scad` for a bundled generator.
- `POST /params` `{scad}` — derive a Customizer schema from **arbitrary** source.
- `POST /render` `{scad, params, format}` — render to **3MF** bytes (`format` is 3MF-only in v1;
  anything else is a 422 rather than an unknown suffix handed to OpenSCAD).
- `GET /up` — health.

**`/render` takes source TEXT and never a catalog key**, and that is the design, not an oversight
(spec §3.1): Rails fetches catalog source from `/source/<key>` and then posts it exactly as it posts
a bring-your-own file's bytes, so the two are indistinguishable to everything downstream. One render
path, one cache, one error surface.

## `/render` refuses a value it cannot coerce

**A garbage parameter value renders SUCCESSFULLY, with the DEFAULT geometry.** OpenSCAD's
`parameterSet` silently *ignores* a value it cannot parse, so `{"cols": "))("}` used to come back 200
with a model nobody asked for. `/render` therefore checks every submitted value against the schema
`/params` derives for that same source and answers **422** for one that will not coerce:

```json
{"error": "“cols” must be a number (got “))(”)", "code": "invalid_params"}
```

`error` is prose, for a human. `code` is there because **the status alone cannot tell this apart from
a `.scad` the parser rejected** — also a 422 — and a caller that shows a form must: a rejected value
is something the user can fix in place, a broken source is not. A parse failure carries no `code`.
Callers must branch on the **code, never on the prose**, which is free to be reworded here.

`coerce.py` owns this and is the **only** copy — it lived in the Rails app until 2026-08-12, where a
browser-side addon bundle could not reach it. Read its header before changing it; in particular
min/max are deliberately **not** enforced (OpenSCAD honours an out-of-range number rather than
ignoring it, so refusing one prevents nothing and adds false rejections). Coercion runs **before** the
cache key is computed, so the key stays keyed on the values that actually determine the bytes.

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

**Written offer for source:** the complete corresponding source for the OpenSCAD binary in this
image is available on request from the maintainer of this repository. The exact build is identified
by `OPENSCAD_VERSION` + `OPENSCAD_SHA256` in the Dockerfile; upstream is
<https://github.com/openscad/openscad>.

> **Do not rewrite that offer as "the tag matching `OPENSCAD_VERSION`" — checked, and there is no
> such tag.** We pin a dated **nightly snapshot**, and upstream tags only releases
> (`openscad-2021.01`, …); `git ls-remote --tags` has nothing named `2026.07.26`. Nor is there a
> source tarball to point at: `files.openscad.org/snapshots/` publishes the AppImage, the Windows
> zip/installer and the WebAssembly builds for our version, and no source artifact. The binary
> itself records only the date (`--version` → `OpenSCAD version 2026.07.26`, and the AppDir's
> `X-AppImage-Version` agrees), so a URL-shaped offer here would be one nobody could actually
> redeem. GPL-2.0 §3(b) wants an offer that can be honoured, so this one names a human.

**The licence text and this README are INSIDE the image** (`COPY LICENSE README.md ./`,
plus `catalog/NOTICE`), because someone who runs `docker pull` never sees
`sidecar/openscad/` — without them they would receive GPL binaries with no licence and no
written offer beside them. The AppImage brings no `COPYING` of its own (searched: only
Liberation-fonts, CC0-examples and bundled-Python licences are in there), so this is the
only copy. **Note the boxes sidecar still has this gap** — worth closing there too.

Bundled third-party `.scad` generators are **permissive-licensed only** and credited individually in
`catalog/NOTICE`. See spec §2 before adding one: a generator whose *output* carries a NonCommercial
or ShareAlike term does not belong here no matter how good it is. `catalog/NOTICE` also records the
audit's sharpest lesson — **read the file header, not the repo LICENSE**; they disagreed on half the
audited set, and the header was the more restrictive one both times.

## The OpenSCAD binary

Extracted from the official x86-64 AppImage, sha256-pinned in the Dockerfile.

**Two things that will bite you if you change that step:**

1. **Do not `./x.AppImage --appimage-extract`.** The AppImage runtime is a static ELF and dies with
   `Exec format error` under Docker Desktop's amd64 emulation — which is how every image in this
   repo is built (an arm64 Mac cross-building, CLAUDE.md §13). The Dockerfile computes the squashfs
   offset from the ELF header and runs `unsquashfs`, executing nothing.
2. **Do not use a distro package.** Debian ships **2021.01 in every suite**, which predates both the
   Manifold backend (~20× faster on the grid-shaped models this addon serves) and
   `--export-format=param` (landed 2021-08), on which the whole "parameters come from OpenSCAD, not
   from us" design depends.

The Dockerfile **asserts** both capabilities at build time, plus parameter injection, and fails the
build if any is missing (`assert-capabilities.sh`, six assertions). Both are compile-time optional
and fail invisibly at runtime — notably, 3MF export without lib3mf writes nothing and **still exits
0**, so an exit code proves nothing and the assertions check the bytes and the vertex counts
instead. Two of the six exist only to keep the other four honest: a *bogus* `--backend` must be
**rejected** (otherwise `--backend=manifold` would prove nothing, being silently ignored), and
injection is asserted by **vertex count**, never by comparing bytes — OpenSCAD's 3MF output is not
byte-reproducible, so a byte compare always reports "different" and can never fail.

The binary is invoked through a **one-line wrapper** at `/usr/local/bin/openscad` that scopes
`LD_LIBRARY_PATH` to that one process. Setting it globally instead breaks the image's *own* Python
(the AppImage bundles an older `libcrypto.so.3`, so `_ssl` fails to load and every outbound HTTPS
call dies) while all six OpenSCAD assertions stay green.

## Security

User-supplied `.scad` is **arbitrary code execution by design** — that is what a generator is.
Bounded by: no secrets and no user data in this container; no published port (kamal network only —
the accessory in `config/deploy.yml` deliberately has no `port:`); a per-render timeout
(`OPENSCAD_TIMEOUT`, 60 s) and address-space cap (`OPENSCAD_MEMORY_MB`, 2 GB) applied between fork
and exec; a source-size cap (`OPENSCAD_MAX_SCAD_BYTES`, 1 MB); and a fresh empty temp dir per
render, used as the CWD, removed after.

*Accepted and documented:* OpenSCAD's `include <>` / `import()` can read paths inside the container.
**Verified against this image, not assumed:** an include of a *nonexistent* path is a warning and
the render still succeeds, while `include </etc/hostname>` **and** the relative
`include <../../../etc/hostname>` both resolve and are parsed — their contents come back as a
parser error attributed to the model. So the fresh temp CWD bounds the blast radius; it does not
seal it. Nothing sensitive lives here, so this is noted rather than mitigated. The container runs as the
non-root user `openscad` (uid 10001) — nothing here needs privilege once the build steps are
done, and since this service execs user-supplied code by design, keeping the privilege bound
as well as the resource bound costs nothing. Note the build itself runs as root (the AppImage
extraction and the capability assertions need to write to `/opt`); `USER` is the last step.

The one thing that *is* sanitization-shaped is `GET /source/<key>`: the key indexes a file on our
disk, so it is matched against `\A[A-Za-z0-9_-]+\Z` and **rejected** rather than normalized, then
resolved and re-checked against `commonpath(CATALOG_DIR)`.

## Cache

Renders are cached by a sha256 over **every** input that can change the bytes — source, params,
format, **and the OpenSCAD version** (a bump can legitimately change geometry, and a stale cache
would otherwise serve the old mesh forever). `OPENSCAD_CACHE_DIR` (default `/cache`) is a mounted
volume in the deploy, so a cold cache is only the first render of each design paying full price.
Entries are written to a per-write unique temp name and `os.replace`d in, so a concurrent identical
render can never see a half file.

## Dev

```sh
python3 -m venv .venv && .venv/bin/pip install -U pip && .venv/bin/pip install -r requirements.txt pytest
.venv/bin/python -m pytest -q          # 66 passed, 13 skipped — the binary-dependent ones skip on the host
docker buildx build --platform linux/amd64 -t openscad-sidecar .
docker run --rm -v "$PWD/tests:/app/tests" openscad-sidecar \
  sh -c "pip install -q pytest && python -m pytest tests/ -q"    # 79 passed — NOTHING should skip here
```

A skip in the second command is a finding, not noise: it means a test that exists to exercise the
real binary quietly did not.

Against a running container, the Rails-side live test drives the real client over HTTP:

```sh
docker run -d --name oscad-live -p 18000:8000 openscad-sidecar
OPENSCAD_SIDECAR_URL=http://localhost:18000 bin/rails test test/integration/tools/openscad_live_test.rb
docker rm -f oscad-live
```

`6 skips` there means the env var never reached the test and nothing was verified.
