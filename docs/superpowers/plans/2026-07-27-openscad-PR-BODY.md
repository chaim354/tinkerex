# PR body — OpenSCAD sidecar addon

> Written for the user to paste when they choose to open the PR. **No PR was opened and nothing was
> pushed** — the user scoped this arc to "build + test + PR, no deploy", and the deploy half is
> theirs to run. Suggested title:
> `feat(openscad): /tools/openscad — .scad + params → 3MF via a GPL-isolated sidecar`

---

## What this is

`/tools/openscad` — the **second server-sidecar addon** (after `sidecar/boxes`) and the **first that
renders 3D**. A user picks a bundled generator or points the tool at their own `.scad` in the
library, fills in a form derived from that file's **own** Customizer parameters, and gets a
`3mf` + `params.json` bundle written through `Maker::Addons::LibraryOutput` with a grid thumbnail.

Design/plan: `docs/superpowers/specs/2026-07-27-openscad-sidecar-addon-design.md`,
`docs/superpowers/plans/2026-07-27-openscad-sidecar-addon.md`.

**Spec §10 held.** Nothing here touches `Sync::*`, the changelog, conflicts, locks or the mounts,
and `LibraryOutput` / `AddonState` / `AddonFile` absorbed a brand-new addon **untouched** — which was
§6's claim, now tested rather than asserted.

## Shape

- **`sidecar/openscad`** — GPL-2.0, internal-only, `tinkerex-openscad:8000`. Extracts the official
  OpenSCAD **2026.07.26** AppImage, sha256-pinned. Flask API: `/up`, `/generators`, `/source/<key>`,
  `/params`, `/render`. Content-addressed render cache on the `openscad-cache` volume. Runs
  **non-root** (uid 10001) and carries its own `LICENSE`, `README.md` and `catalog/NOTICE` inside
  the image.
- **`OpenscadClient`** (mirrors `BoxesClient`) + **`Tools::OpenscadController`** + views.
- **`OpenscadParams`** — a coercion layer that is not in the plan's file table. It exists because a
  garbage parameter value **renders successfully**: OpenSCAD's parameterSet silently ignores what it
  cannot parse, so a typo yielded default geometry with no feedback anywhere.
- **ONE render path, TWO sources** (spec §3.1). Rails resolves a catalog key to source text via the
  sidecar's `GET /source/<key>` and then posts it to `/render` exactly as it posts a bring-your-own
  file's bytes — nothing downstream can tell them apart.
- **Catalog: three generators, not the plan's four** — see the licence finding below.
- **Deploy plumbing:** `bin/build-openscad-sidecar`, an `openscad` accessory in `deploy.yml`,
  `OPENSCAD_SIDECAR_URL` blanked in `deploy.ovh.yml`, `/sidecar/` in `.dockerignore`.

## The licence finding — READ THE FILE HEADER, NOT JUST THE REPO LICENSE

The plan listed **four** generators to bundle, each with a licence read off the repo's `LICENSE`
file (agreeing with GitHub's licence detector, which reads exactly that). On opening the actual
`.scad` files, **two of the four declared a more restrictive licence in their own header**:

- `universal_stand` — stock **MIT** `LICENSE`; header says **CC BY-NC-SA 4.0**. NonCommercial *and*
  ShareAlike, the precise pair spec §2 was written about.
- `vase_box` — `LICENSE.md` is the full **CC BY 4.0** text; header line 3 says
  **Attribution-ShareAlike**.

Both dropped. That is **50% of the audited set**, and it is a sixth audit bar worth stating plainly:
a repo-level LICENSE is not the licence of every file under it, and where the two disagree the
conflict is itself disqualifying for something we redistribute in a sold product. Every rejection is
recorded **with its reason** in `sidecar/openscad/catalog/NOTICE` so the audit is not run twice.

**Bundled: `hex_cell_holder` (Unlicense), `washer` (MIT), `probe_plate` (MIT, first-party).**

## Verification — measured, not "green"

| Check | Result |
|---|---|
| `bin/rails test` | **1478 runs / 5120 assertions / 0 failures / 0 errors / 14 skips** |
| `LIBRARY_BACKEND=share bin/rails test` (with `LIBRARY_PATH`) | **identical: 1478 / 5120 / 0 / 0 / 14** |
| `LIBRARY_BACKEND=s3 bin/rails test` (with CI's `LIBRARY_S3_*`) | **identical: 1478 / 5120 / 0 / 0 / 14** |
| In-image Python suite | **40 passed, 0 skipped** |
| Live integration vs a real container | **6 runs / 33 assertions / 0 failures** |
| `bin/rubocop` | 401 files, **1 offence — pre-existing on `main`** (see below) |

The rubocop offence is `config/routes.rb:46` `Layout/SpaceBeforeFirstArg`, on a `notes#create` line
this branch never touched — verified present on `main` by running the cop against `main`'s own copy
of the file. Left alone.

The 14 skips are the usual environment-gated ones (live sidecars, Postgres-only, uninstalled preview
binaries), identical across all three legs.

## Not done, deliberately

- **DoD #5 — a real Multiboard `.scad` driven end-to-end in a browser — is OPEN.** Spec §2 forbids
  us obtaining or redistributing MultiBuild files, so this is yours to run once deployed. The BYO
  code path is covered by the controller suite on all three backends and was driven against a live
  sidecar with an equivalent `.scad`.
- **DoD #2 is open: nothing is deployed.** No ghcr push, no `docker login`, no
  `kamal accessory boot`, no app deploy, no live verification on the three Unraid backends.
  `bin/build-openscad-sidecar` and the accessory config are written and ready.
- **The browser walkthrough (DoD #3, #4, #6 seen with human eyes) was not done.** Each of the three
  is covered by an automated test — the tile greying out, save-and-thumbnail on all three backends,
  and a *measured* cache hit — but nobody has looked at the page.

## Before merging: this branch is 26 commits behind `main`

Merge-base is `efde37e`. The **"file organization and views" arc (PR #86)** landed on `main`
afterwards, so `git diff main` reads as though this branch *deletes* that work — it does not, it
simply predates it. Merge `main` in before opening the PR. Expect small conflicts at the top of
`docs/STATUS.md` and in `CLAUDE.md` §12 step 9, where both sides added text.

## Deploy order when you are ready

The app boots fine without the sidecar (the tile just greys out), but boot the accessory first so
the addon is live the moment the app rolls.

```bash
KAMAL_REGISTRY_PASSWORD="$(op read 'op://Personal/ghcr.io/password')" bin/build-openscad-sidecar
bin/kamal accessory boot openscad
bin/kamal deploy && bin/kamal deploy -d s3 && bin/kamal deploy -d share
```

Per the standing rule, bare "deploy" is the **three Unraid backends only** — OVH is deliberately not
in that list, and `deploy.ovh.yml` blanks `OPENSCAD_SIDECAR_URL` so the addon greys out there rather
than reporting itself available and failing every call.

## One thing found while writing the docs, left out of scope

`sidecar/boxes` is a GPL-3.0 image we redistribute, and its `Dockerfile` **never copies its
`LICENSE` into the image** — only the newer `sidecar/openscad` does that. Not a regression from this
branch and not touched here; noted in `CLAUDE.md` §3's new Addons row and worth closing when boxes
is next touched.


---

## Merged with `main` (2026-07-27)

This branch was 26 commits behind when the work finished, so `origin/main` (through PR #86, the
file-organization arc) has been merged in. One conflict, in `docs/STATUS.md`, where both sides added
a "Latest" section at the top — resolved by keeping **both**, OpenSCAD first, with a single
`**Updated:**` line. No code conflicts.

**Post-merge verification, all three legs identical:**

```
bin/rails test                        1478 runs, 5120 assertions, 0 failures, 0 errors, 14 skips
LIBRARY_BACKEND=share bin/rails test  1478 runs, 5120 assertions, 0 failures, 0 errors, 14 skips
LIBRARY_BACKEND=s3    bin/rails test  1478 runs, 5120 assertions, 0 failures, 0 errors, 14 skips
bin/rubocop                           411 files, 1 offense (pre-existing on main: config/routes.rb:46)
```

The share leg needs `export LIBRARY_PATH=$(mktemp -d)` and the s3 leg needs CI's `LIBRARY_S3_*`
values, exactly as `.github/workflows/ci.yml` sets them.
