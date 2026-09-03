# DXF spline descriptors — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: this repo's `.claude/commands/execute-plan.md`.

**Goal:** A DXF `SPLINE` reaches the client as the curve it is. Since `tinkerex#216` they are parsed
and flattened to points; `tinkerex#217` gave LightBurn and SVG a cubic path descriptor. This is the
third producer leg.

**Follows:** `tinkerex#216` (splines parsed), `tinkerex#217` (the `"p"` wire form), `tinkerex#219`
(BLOCK/INSERT placement — which is why the transform arm below matters).

---

## Measured facts, counted THROUGH THE PARSER

Text-level counting has misled a plan three times on this work (§14h now records it), so these come
from `Dxf.parse_document`, block bodies included:

| file | splines | knot spans | degree | non-unit weights | payload | est. growth |
|---|---|---|---|---|---|---|
| `cards.dxf` | 3,308 | 19,454 | 3 | **0** | 3365 KB | +911 KB (**+27%**) |
| `elianadxf.dxf` | 4 | 573 | 3 | **0** | 32 KB | +26 KB (**+81%**) |
| `macropad v5.dxf` | 28 | 226 | 3 | **0** | 26 KB | +10 KB (+38%) |

**Degree is 3 everywhere and NO spline carries a non-unit weight**, so Bézier extraction is EXACT
across the whole corpus — there is no rational case to approximate. Guard it anyway (below); the
corpus is evidence about today, not a proof about tomorrow.

**`cards.dxf`'s 3,308 splines live inside BLOCK definitions** (180 blocks, 8,316 block entities) and
reach the drawing through `INSERT` expansion. That is not a detail — it is why the transform arm is
the load-bearing part of this plan.

**Growth is accepted in advance**, consistent with `tinkerex#217`'s decision on 2026-09-03: `.dxf`
lands around 4.3 MB on the worst file of 129. Measure and report; do not tune in the dark, and do
not raise a budget silently. There is no hard budget.

---

## Stage 1: Bézier extraction, and the transform arm

**Files:** `dxf.rb`, `dxf_geometry.rb`, `test/services/maker/previews/dxf_geometry_test.rb`.

- [ ] **Step 1: Failing test.** A degree-3 SPLINE with an interior knot (so the extraction is
  exercised, not a single Bézier) must gain `g == ["p", …]` whose resolved curve tracks the shape's
  own `p` points and reaches its `b`. **Assert resolved geometry, never the `d` string** —
  `tinkerex#213`'s arc passed its own equality test while drawing 1.37 mm off.

- [ ] **Step 2: Extract Béziers.** For degree 3, each non-empty knot span yields exactly one cubic.
  Raise interior knot multiplicity to 3 by Böhm insertion (or apply the equivalent extraction
  operator directly) and read off the four control points per span. `elianadxf.dxf` is the easy
  case — its knots already sit at multiplicity 3, so it is a chain of Béziers and the extraction
  must be the identity there; that makes it a good first assertion.

- [ ] **Step 3: REFUSE a rational spline, and tally it.** A rational cubic Bézier is NOT expressible
  as an SVG cubic. If any weight differs from 1, emit no descriptor and tally `SPLINE(rational)` —
  the points still draw, so nothing is lost but exactness. Zero occur in the corpus; this is a guard,
  and per §14h's rule, **a refusal must be tallied explicitly** because `SPLINE` is now in
  `ENTITY_TYPES` and the type-based tally no longer fires for it.

- [ ] **Step 4: `transform_curve` gains a `:path` arm THAT NEVER DROPS.** The existing arms return
  `nil` under a non-similarity transform, and correctly so: a circle under a non-uniform scale is an
  ellipse the `"e"` form cannot spell, and an arc likewise. **A cubic has no such limit — it
  transforms affinely under ANY matrix**, so the arm maps every control point through `xf` and
  always succeeds. Comment it, or the next reader will "fix" it into a needless refusal by analogy
  with its neighbours.

  This is where `cards.dxf` is decided: its splines are inside blocks, so every one of them goes
  through this path.

- [ ] **Step 5: `curve_to_client_space` gains a `:path` arm** → `Geometry.path_curve`, with the same
  scale and Y-flip the points get. **DXF is Y-UP and must be flipped**; the flip belongs here, as it
  already does for the points and the other curve forms.

- [ ] **Step 6: Decide the thumbnail, and measure it.** `Dxf.to_svg`'s `element_svg` branches on
  `curve[:type]`. Adding a `:path` arm makes the thumbnail draw the exact curve; omitting one leaves
  it drawing the sampled polyline. **Prefer adding it** — the thumbnail SVG has no thinning stage, so
  a cubic (6 numbers) very likely REPLACES many sampled points and the SVG gets *smaller*. Measure
  `cards.dxf`'s thumbnail SVG both ways and report. If you add it, `Dxf::THUMBNAIL_REVISION` must
  move (Step 8) and `entities.dxf`'s SVG digest moves with it.

- [ ] **Step 7: Measure** all five scratch files: shapes, job box, payload KB, render seconds, and
  `cards.dxf`'s thumbnail SVG size. `dxf3.dxf` and `ore.dxf` have no splines and must be
  **byte-identical** — verify, do not assume.

- [ ] **Step 8: Revisions and digests.**
  - `DxfGeometry::FORMAT_REVISION` 2 → 3, and `GEOMETRY_REVISIONS["a.dxf"]` 3 → 4.
  - `Dxf::THUMBNAIL_REVISION` 2 → 3 **if and only if** Step 6 changed the SVG.
  - **`THUMBNAIL_REVISIONS["a.dxf"]` in `thumbnail_revision_test.rb` moves with it** — that absolute
    pin is new (`tinkerex#220`) and exists precisely so this cannot be forgotten.
  - **`entities.dxf`'s digests WILL move** — it carries a SPLINE, which is exactly why it was added.
    This is the first change on this line of work where that guard actually fires; `sample.dxf` and
    `plate.dxf` have no splines and must stay untouched.
  - **Do NOT bump `Geometry::SHARED_REVISION`.** DXF-only change; the qualification `tinkerex#217`
    added to §14h's rule covers this.

- [ ] **Step 9: Commit, THEN mutate.** `git checkout --` restores to HEAD. Mutations, actual RED each:
  - make the `:path` arm of `transform_curve` return `nil` under a non-similarity (copying its
    neighbours) → a placed-spline test must go RED
  - skip the Y-flip on the control points → the resolved-geometry test must go RED
  - drop the rational refusal → the `SPLINE(rational)` tally test must go RED
  - revert `DxfGeometry::FORMAT_REVISION` → `GEOMETRY_REVISIONS` goes RED
  - revert `Dxf::THUMBNAIL_REVISION` (if bumped) → `THUMBNAIL_REVISIONS` goes RED

## Stage 2: Invariants and close-out

- [ ] `docs/invariants/measure-view.md`: Bézier extraction is exact for degree 3 with unit weights,
  and refused otherwise; **the `:path` transform arm never drops where its neighbours must**, with
  the reason; the measured growth; and that `entities.dxf` finally made the digest guard fire.
- [ ] `bin/ci` — three legs, identical run counts. `TINKEREX_SYNC_DIR` set from a worktree.
- [ ] `/finish-branch`; `bin/log arc --from-pr <n>`.
