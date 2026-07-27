# OpenSCAD sidecar addon (`.scad` + params → 3MF) — design

**Status:** approved, not yet implemented
**Date:** 2026-07-27
**Backlog entry this closes:** `docs/addon-backlog.md:61` — *"Engine ① — OpenSCAD sidecar
(GPL-isolated) · `.scad` + params → STL ⭐ one engine, whole catalog"* (Phase 3, "Server
sidecars — reuses the proven boxes.py deploy pattern").
**Prior art it clones:** `docs/superpowers/specs/2026-07-20-addon-framework-boxes-design.md`
(the boxes.py GPL sidecar) — read that first; this spec only records what *differs*.

---

## 1. Goal & scope

Add a second `/tools` addon: a **generic OpenSCAD engine**. A user picks a parametric
`.scad` generator, fills in a form derived from the file's own parameters, and gets a
**3MF + params.json** bundle written into their library with a working grid thumbnail.

The request that started this was *"Multiboard generators"*. **We do not ship Multiboard
files** — see §2. Multiboard is served by the bring-your-own path: the user puts their own
`.scad` in their library and points the tool at it.

**In scope (v1):** the sidecar, the Rails client + addon UI, a bundled permissive catalog,
bring-your-own `.scad` from the library, a content-addressed render cache, and 3MF +
params.json output.

**Out of scope (v1):** async/background rendering, formats other than 3MF, sidecar CI,
print-on-demand, sharing generator configs. See §12.

**§10 tripwire (from CLAUDE.md):** this work touches **none** of sync, the changelog,
conflicts, locks, or the mounts. All library writes go through the existing
`Maker::Addons::LibraryOutput`. If an implementer finds themselves editing `Sync::*`, the
boundary is wrong — stop.

---

## 2. THE LICENSING DECISION — read this before adding any bundled generator

**MultiBuild (formerly Multiboard; rebranded 2026, `multiboard.io` → `multibuild.io`)
licenses restrictively.** Verified by reading <https://multibuild.io/license> directly:

- *"You may not share or redistribute copies or mass link repositories of the original
  Designs."* → bundling their `.scad` into a Docker image we ship to **self-hosters** is
  redistribution. Prohibited.
- *"You may not use the designs for commercial purposes unless you hold a Commercial
  Subscription."* → Tinkerex is a commercial product (CLAUDE.md §1).
- Commercial Purposes is defined *"exclusive of selling or sublicensing any part of the
  Designs themselves"* → **even the paid tier does not cover shipping the Designs.**
- *"The license can be withdrawn or canceled by MULTIBOARD LTD at any time."*

Community OpenSCAD reimplementations are **not** an escape: the main one licenses its
source MIT but its **generated models CC BY-NC-SA 4.0** — NonCommercial, same wall.

**This is CLAUDE.md §9's concern wearing a different hat.** Not copyleft, but
NonCommercial + no-redistribution, which is *worse* for a commercial, self-hostable
product: GPL at least permits redistribution.

**Consequence, and the rule for anyone adding a generator later:**

> The bundled catalog is **permissive-licensed source only** (MIT / Apache-2.0 / BSD /
> CC0 / CC-BY). A generator whose *output* carries a NonCommercial or ShareAlike term does
> **not** go in the catalog, no matter how good it is. It is a bring-your-own file.

Bring-your-own carries zero redistribution exposure by construction: the **user** obtains
the file (personal use, which their licence permits) and it lives in the **user's** library.
We never hold, ship, or serve it.

---

## 3. Architecture

```
Rails (permissive)                      openscad-sidecar (GPL-2.0, internal-only)
─────────────────                       ─────────────────────────────────────────
Tools::OpenscadController               GET  /up            → "ok"
  └─ OpenscadClient  ───── HTTP ─────►  GET  /generators    bundled catalog + schemas
       (mirrors BoxesClient)            POST /params        .scad → Customizer schema
                                        POST /render        .scad + params → 3MF bytes
Maker::Addons::LibraryOutput                 └─ content-addressed cache on a volume
  └─ 3MF + params.json → library
Maker::Previews::ThreeMf → PNG thumb
```

Rails owns the UI, param handling, auth, and save-to-library. The sidecar **only renders**.
Identical division of labour to boxes.

### 3.1 One render path, two `.scad` sources

`POST /render` takes **source text**, never a catalog key. Therefore:

- a **catalog** generator is pre-seeded source the sidecar reads off its own disk and posts
  to its own renderer;
- a **bring-your-own** generator is source Rails reads from the library
  (`FileLayer.current.read`) and posts.

Both hit the same endpoint, the same cache, the same schema parser. **The catalog is data,
not a code path** — the same insight that makes perplexinglabs' `/ui` endpoint work (one
schema-driven form renderer over N generators; adding one is a file plus a registry line,
zero frontend code).

Do **not** "optimize" this into a `generator_key` fast path. Two paths means two caches,
two error surfaces, and a catalog that can drift from BYO behaviour.

### 3.2 Parameters come from OpenSCAD, not from us

OpenSCAD's built-in **Customizer** derives a parameter schema from plain top-level variable
declarations. `openscad --export-format=param` dumps it as JSON. Neither the catalog nor BYO
needs hand-authored schema files.

*Verified:* injecting a bare `.scad` (no annotations) into the OpenSCAD playground produced
a complete form — rows, cols, pitch, th, hex_r, peg_r — automatically.

---

## 4. THE SIDECAR IMAGE — capabilities are compile-time optional, so ASSERT them

**`apt-get install openscad` is a trap.** Debian ships **2021.01 in every suite, including
sid/forky** (checked against `sources.debian.org`). 2021.01 predates the Manifold backend
entirely.

**This is not a minor perf note — it is a 20×+ cliff, measured:**

| Build | Backend | 36 cells | 64 cells | 400 cells |
|---|---|---|---|---|
| `openscad-wasm-prebuilt` (2025.01.19) | CGAL | **24,804 ms** | — | — |
| openscad-playground build | **Manifold** | — | **1,188 ms** | **4,041 ms** |

CGAL is superlinear and unusable for grid-shaped models; Manifold is ~linear. A hex grid
benchmark shaped like a Multiboard board is the exact workload this addon exists to serve.

**Both required capabilities are compile-time optional and BOTH were absent from a
plausible-looking build.** In the 2025.01.19 wasm build:

- `--enable=manifold` → `WARNING: Ignoring request to enable unknown feature 'manifold'.`
  and a **silent** fall back to CGAL. It does not fail. It gets slow.
- `-o out.3mf` → **hard abort** (no lib3mf). `-o out.stl` and `-o out.off` worked fine, so a
  naive smoke test on STL would have passed.

**Decision: extract the official x86-64 AppImage** (`openscad-nightly` / 2025.x) into a
`python:3.12-slim` image, matching the boxes sidecar's base. Rejected: distro packages
(stale), Arch/Fedora base (changes base distro for one binary), source build (very slow).

**Decision: the Dockerfile MUST assert both capabilities at build time** — render a test
cube with `--backend=manifold` *and* `-o /tmp/t.3mf`, and `exit 1` if either fails or if
stderr contains the "unknown feature" warning. A silently-CGAL image is the failure mode
this guards, and it is invisible at runtime except as slowness.

> Same lesson as the Phase 3 `FakeS3` bug recorded in CLAUDE.md §12 step 10 — a fake (or
> here, a base image) built from a plausible assumption *confirms* the assumption. A build
> that looks right proves nothing. Assert the capability; don't trust the package name.

**Flag naming:** newer OpenSCAD uses `--backend=manifold`; older uses `--enable=manifold`.
The build assertion must pin whichever the chosen AppImage actually accepts and record it
in the README, rather than passing both and hoping.

---

## 5. The sidecar API (`sidecar/openscad/app.py`, Flask)

| Method | Path | In | Out |
|---|---|---|---|
| GET | `/up` | — | `ok` |
| GET | `/generators` | — | `[{key, title, description, license, params}]` — bundled catalog |
| POST | `/params` | `{scad}` | `{params: [...]}` — Customizer schema for arbitrary source |
| POST | `/render` | `{scad, params, format}` | 3MF bytes (`model/3mf`) |

`/render` is **synchronous** with a hard **60 s** timeout (see §7 for why sync).

### 5.1 Render cache

Key: `sha256(scad_source + canonical_json(params) + format + openscad_version)` → file on a
Docker volume. A hit returns bytes without invoking OpenSCAD.

Two reasons this is v1 and not deferred: it makes the sync decision defensible (a repeat
render is instant, so the tune-and-re-render loop doesn't pay the render cost twice), and it
is the same content-addressed instinct already used throughout this codebase (FastCDC
chunks, `manifest_id`) and by perplexinglabs (SHA-1 of the param set → `/download/<sha>.stl`).

**`openscad_version` is in the key on purpose:** a version bump can legitimately change
output geometry, and a stale cache would serve the old mesh forever.

---

## 6. Rails side

| File | Role |
|---|---|
| `sidecar/openscad/` | `Dockerfile`, `app.py`, `LICENSE` (GPL-2.0), `README.md`, `.dockerignore`, `tests/` |
| `bin/build-openscad-sidecar` | Clone of `bin/build-boxes-sidecar`; `ghcr.io/chaim354/openscad-sidecar:latest`, `--platform linux/amd64` |
| `app/services/openscad_client.rb` | Mirrors `BoxesClient`: `configured?`/`base_url`/`current`/`stub=`/`stubbed?`/`reset!` |
| `app/controllers/tools/openscad_controller.rb` | `index`/`new`/`preview`/`create`/`show` |
| `app/services/maker/addons/registry.rb` | **One** entry: `available: -> { OpenscadClient.configured? }` |
| `app/views/tools/openscad/` | Views cloned from `tools/boxes` |
| `test/support/fake_openscad.rb` | PORO stub, same shape as `FakeBoxes` |

**Nothing in `Maker::Addons::LibraryOutput`, `AddonState`, or `AddonFile` changes.** That
those three absorb a brand-new addon untouched is the addon framework's own claim; if this
implementation needs to modify them, the framework was wrong and that is worth surfacing.

### 6.1 Output bundle

`LibraryOutput.write` with two files, mirroring boxes' `svg + params.json`:

- `<name>-<state.id>.3mf` — role `output`, content type `model/3mf`
- `<name>-<state.id>.params.json` — role `parameters`

**3MF, not STL** — better print format (units, metadata) and already previewable.

**Why the thumbnail still works, verified:** OpenSCAD-exported 3MF has **no embedded
thumbnail**, and `Maker::Previews::ThreeMf` prefers one. But that renderer already has a
**mesh fallback** — parse `3D/*.model` → binary STL → the deployed `stl-thumbnailer`
(`three_mf.rb:102-123`). So `enqueue_preview` yields a grid thumbnail with **no new preview
code**. This was checked in the source, not assumed; had the fallback been absent, 3MF would
have shipped with silently blank thumbnails.

**We do NOT write the `.scad` back into the library.** For a bring-your-own Multiboard file
that would copy a restrictively-licensed Design around the user's library and into any
future share/export path. `params.json` records what was rendered; the source stays where
the user put it.

### 6.2 Preview

`POST /tools/openscad/preview` renders 3MF, runs it through `Maker::Previews::ThreeMf`, and
returns PNG inline — the same "rasterize server-side, never inline untrusted markup" posture
`Tools::BoxesController#preview` takes with SVG.

---

## 7. Execution model: synchronous

Sync, hard 60 s timeout, mitigated by forcing Manifold (§4) and the render cache (§5.1).

Rationale: mirrors boxes; introduces no job/state-machine/progress-UI surface; and with
Manifold a 400-cell grid renders in ~4 s. The upgrade path to a Solid Queue job stays open
and is a contained change (the sidecar API does not change — only who calls it).

**Known accepted cost:** a slow render occupies a Puma worker for its duration. Acceptable
at current scale; revisit if renders routinely exceed ~10 s or concurrency grows.

---

## 8. Deployment

Kamal accessory, exactly like boxes — `config/deploy.yml`:

```yaml
accessories:
  openscad:
    image: ghcr.io/chaim354/openscad-sidecar:latest
    host: 192.168.1.95
    volumes:
      - openscad-cache:/cache        # the render cache (§5.1)
```

No `port:` → internal-only on the kamal network as `tinkerex-openscad`. One accessory serves
all three Unraid app legs. `OPENSCAD_SIDECAR_URL: http://tinkerex-openscad:8000` goes in
`env.clear` of `deploy.yml`, `deploy.s3.yml`, and `deploy.share.yml`.

### 8.1 Two pre-existing bugs this work fixes

Both found while surveying the boxes sidecar. Neither is caused by this feature; both would
be inherited by it if left alone.

1. **`deploy.ovh.yml` inherits a dead sidecar hostname.** It never mentions boxes, and Kamal
   deep-merges hashes, so the OVH leg inherits `BOXES_SIDECAR_URL:
   http://tinkerex-boxes:8000` — a name that does not resolve there (the accessory's `host:`
   is the Unraid IP). The addon therefore reports `configured? == true` and then **fails on
   every call**, which is worse than showing unavailable. Fix: explicitly clear the sidecar
   URLs in the OVH overlay, for boxes **and** OpenSCAD.

2. **GPL source ships inside the permissive Rails image.** `.dockerignore` excludes
   `/docs/`, `/test/`, `/ci/`, `/scripts/`, `/client/` — but **not `/sidecar/`** — and the
   Rails `Dockerfile:47` does `COPY . .`. The GPL-3.0 boxes tree is baked into the app image
   today. Never imported or executed, but it *ships*, which is precisely what CLAUDE.md §9
   says to avoid. Fix: add `/sidecar/` to `.dockerignore` before adding a second GPL tree.

---

## 9. Licensing posture of the sidecar itself

`sidecar/openscad/` carries **GPL-2.0** (OpenSCAD's licence) plus a written offer for
source, and a `README.md` stating the isolation posture verbatim from
`sidecar/boxes/README.md`: separate container, invoked only over HTTP on an internal
network, **never imported into `app/`**.

**Honest note on the boundary:** unlike boxes (whose wrapper *imports* the GPL `boxes`
library and is therefore a derivative work), this wrapper only **execs** a binary — arm's
length, ordinarily mere aggregation. We nevertheless adopt the same GPL-2.0 posture for the
whole directory, because the *image* unquestionably ships GPL software and must carry the
licence and source offer regardless. Cheaper to be uniform than to litigate the distinction.

---

## 10. Security

User-supplied `.scad` is **arbitrary code execution by design** — that is what a generator
is. Bounded by:

- The sidecar holds **no secrets and no user data**. Blast radius is a stateless renderer.
- No published port; reachable only on the kamal network.
- Non-root; per-render **timeout** and **memory cap** (the real risk is a runaway loop → DoS,
  not exfiltration).
- Each render gets a **fresh empty temp dir**; the `.scad` is written there and removed after.

Accepted, documented: OpenSCAD's `include <>` / `import()` can read paths inside the
container. Nothing sensitive lives there, so this is noted rather than mitigated.

---

## 11. Testing

- `test/services/openscad_client_test.rb` — `configured?` flips with the env var (clone of
  the boxes test).
- `test/controllers/tools/openscad_controller_test.rb` — full UI flow against
  `FakeOpenscad`: catalog list, BYO pick, param form, preview, create-writes-bundle,
  unknown-generator, sidecar-error → 422.
- `test/integration/tools/openscad_live_test.rb` — real HTTP smoke; **skips** unless
  `OPENSCAD_SIDECAR_URL` is set (clone of `boxes_live_test.rb`).
- `sidecar/openscad/tests/test_api.py` — pytest, run by hand (boxes has no sidecar CI
  either; not adding one here, see §12).
- **All Rails tests must pass on all three legs** — `bin/rails test`,
  `LIBRARY_BACKEND=share`, `LIBRARY_BACKEND=s3` — since `LibraryOutput` is backend-branching.

**The one test that must not be vacuous:** the create path must assert the bundle actually
landed — two `AddonFile`s with the right roles and a real node in the library — not merely
that the controller redirected. The Phase 4 lesson in CLAUDE.md is that a gating test which
mints its object in Ruby instead of driving the real endpoint stays green for the wrong
reason.

---

## 12. Deferred / out of scope

| Item | Why |
|---|---|
| Async / background rendering | YAGNI at current scale; §7 keeps the path open |
| STL / AMF / OFF export | 3MF covers it; each extra format is another render |
| Sidecar CI job | boxes never got one; not this feature's job to invent |
| Print-on-demand | Different product decision entirely |
| Sharing generator configs | `AddonState` already persists them; sharing is separate |
| Multiboard in the bundled catalog | **Prohibited** — §2. Not a "later"; a never, absent a licence change |

---

## 13. Definition of done

1. `sidecar/openscad/` builds; the **build-time capability assertion** for Manifold + 3MF
   passes (and demonstrably fails if either is missing).
2. `bin/build-openscad-sidecar` pushes to ghcr; `kamal accessory boot openscad` runs;
   `curl http://tinkerex-openscad:8000/up` → `ok` from an app container.
3. The addon appears in `/tools`, greys out when `OPENSCAD_SIDECAR_URL` is unset.
4. A catalog generator renders, saves, and shows a **grid thumbnail** on all three backends.
5. A bring-your-own `.scad` from the library renders and saves — **driven end-to-end in a
   browser with a real Multiboard `.scad`**, since that is the request that started this and
   the only proof the BYO path actually serves it.
6. Repeat render of identical params is a cache hit (measurably faster).
7. `.dockerignore` excludes `/sidecar/`; the OVH overlay no longer inherits a dead sidecar
   hostname (§8.1).
8. Suite green on all three legs; `docs/STATUS.md` and `docs/addon-backlog.md` updated
   (Engine ① struck off).
