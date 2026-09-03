# DXF entity coverage — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: this repo's `.claude/commands/execute-plan.md`
> (`/execute-plan`). Steps use checkbox (`- [ ]`) syntax.

**Goal:** Stop silently mis-rendering DXF files. Parse `SPLINE`, honour `POLYLINE` bulges, place
`BLOCK` geometry at its `INSERT` transforms, and surface whatever remains unreadable instead of
dropping it without a word.

**Issues:** `tinkerex#216` (SPLINE + bulges + honesty), `tinkerex#219` (BLOCK/INSERT),
`tinkerex#215` (360° ARC thumbnail — rides along, see Stage 5).

**Architecture:** All of it lands in one traversal, `Dxf.each_geometry`, which feeds **both**
`Dxf.to_svg` (thumbnail) and `DxfGeometry` (measure payload). That is the central fact of this plan:
it forces one revision bump on each axis, and it forces the work to be **serial**.

---

## Measured facts — the plan rests on these, not on the issue text

Taken 2026-09-03 from the **live share library**, 129 real DXF files, by walking code/value pairs in
Ruby. (`tinkerex#216`'s original figures came from `grep -E "^SPLINE$"`, which cannot match a CRLF
file and undercounted by ~78×. Do not trust line-greps on DXF.)

| entity | count | files | current behaviour |
|---|---|---|---|
| `SPLINE` | **18,906** | 29 / 129 | **dropped entirely** |
| non-zero bulges | **3,869** | 26 | arc segments drawn as **straight chords** |
| `INSERT` | **1,094** | 24 | ignored; block bodies drawn once at **definition** coords |
| `ELLIPSE` | 0 | 0 | dropped — **not implemented here**, deliberately |

**SPLINE shape of the data (all 29 files):** degree is `3` everywhere; fit-point count (`74`) is `0`
everywhere, so every spline is control-point based. Flag `70` takes 0 / 8 / 11 / 24 / 27 — bit 0
(closed) and bit 1 (periodic) are **both present in quantity** (433 of 1702 in one family), so a
"knot multiplicity equals degree ⇒ chain of Béziers" shortcut is **not** sufficient; general de Boor
over the knot vector is required. Weight codes (`41`) appear in the macropad/elianadxf families while
the rational bit (4) is never set in flag 70 — normally meaning all weights are 1.0. **Assert that
rather than assuming it.**

**All 3,869 bulges are on old-style `POLYLINE` `VERTEX` records; ZERO are on `LWPOLYLINE`.** That
matters: a `VERTEX` is its own entity with its own codes hash, so its bulge is directly available.
`LWPOLYLINE` bulges are *not* addressable today — `parse_entities` groups values by code and loses
interleaving, and code `42` is optional per vertex — so they cannot be paired with their vertex
without restructuring the parser. **Do not restructure it. Detect and report them** through Stage 1.

**Observed harm, through the real renderer:**

```
elianadxf.dxf    shapes=0  job 0x0 mm      4 splines, nothing else — reads "No measurable geometry"
macropad v5.dxf  shapes=6  job 123.4x89.7  28 splines missing — the reported size is wrong
```

## Performance and payload baseline — Stage 3 must not blow these

Real files are in the scratchpad at `<scratchpad>/dxf-real/` (user data — **never commit them**).
Measured on this machine, today, with splines still dropped:

| file | render | shapes | payload |
|---|---|---|---|
| `cards.dxf` (8.7 MB, 3308 splines) | 0.50 s | 4840 | **563 KB** |
| `dxf3.dxf` (1195 bulges) | 0.03 s | 175 | 47 KB |
| `elianadxf.dxf` | 0.00 s | 0 | 0 KB |

`cards.dxf` is already 563 KB **before** a single spline is added. §14h's payload-cheapness rule is
live here. **Budget: after Stage 3, `cards.dxf` must render in ≤ 3 s and produce ≤ 1.5 MB.** If a
naive sample count blows that, thin harder — do not raise the budget without saying so.

## The constraint that shapes the sequencing

`app/services/maker/previews/dxf.rb` is touched by Stages 1–5. **They cannot run in parallel.** Run
them one at a time, each committing before the next starts. Only Stage 1's client-side surface and
Stage 6's docs are separable.

---

## Stage 1: The honesty backstop

**Why first:** it is the mechanism the later stages report *through*, and it is what would have
caught all three of these gaps years ago.

**Files:** `app/services/maker/previews/geometry.rb`, `dxf.rb`, `dxf_geometry.rb`,
`app/javascript/controllers/measure_controller.js`, plus tests.

- [ ] **Step 1: Failing test** — a DXF containing a `SPLINE` and an `ELLIPSE` reports them:

```ruby
test "an entity type the parser cannot draw is reported rather than dropped" do
  dxf = "0\nSECTION\n2\nENTITIES\n0\nSPLINE\n8\nA\n0\nELLIPSE\n8\nA\n0\nSPLINE\n8\nA\n" \
        "0\nLINE\n8\nA\n10\n0\n20\n0\n11\n5\n21\n0\n0\nENDSEC\n0\nEOF\n"
  payload = build(dxf)

  assert_equal 1, payload["shapes"].length, "the LINE still draws"
  assert_equal({ "SPLINE" => 2, "ELLIPSE" => 1 }, payload["u"],
               "and what could not be drawn is named and counted")
end
```

- [ ] **Step 2:** Run it; expect `payload["u"]` to be nil.

- [ ] **Step 3: `Geometry.build` gains `unreadable:`** — a `{type => count}` hash, emitted as the
  payload's top-level `"u"` key and **omitted entirely when empty**, exactly as `"g"` is omitted per
  shape. It is format-agnostic on purpose: any traversal can report what it could not read.

```ruby
      # WHAT THIS FORMAT COULD NOT DRAW, NAMED AND COUNTED — because the alternative is what DXF did
      # for years: `Dxf.flatten`'s `case` had no `else`, so SPLINE, ELLIPSE and INSERT returned nil
      # and `each_geometry` skipped them with no error, no log and no status. 18,906 splines across
      # 29 of 129 real files vanished that way, one file reporting "No measurable geometry" about a
      # file that is nothing but geometry (tinkerex#216).
      #
      # WORSE THAN A MISSING PICTURE: a skipped entity never reaches `add`, so it is absent from the
      # running bbox too — the job size and every extent describe a SUBSET of the file, with nothing
      # on screen to say so. That is §14h's measure-after-thinning failure at whole-entity scale.
      #
      # ABSENT WHEN EMPTY, like `"g"`. A `"u" => {}` on every well-read file is bytes for nothing,
      # and the client's check is truthiness.
```

- [ ] **Step 4: `Dxf.each_geometry` counts them.** An entity record whose `0`-code value is not in
  `ENTITY_TYPES`, not `VERTEX`, and not a structural marker (`SECTION`, `ENDSEC`, `EOF`, `TABLE`,
  `ENDTAB`, `BLOCK`, `ENDBLK`, `SEQEND`, `CLASS`, `DICTIONARY`, …) is unreadable. **`parse_entities`
  currently discards non-`ENTITY_TYPES` records at the `0` code**, so it must retain their *names*
  even though it retains no codes. Yield the tally to the caller.

  **Also fix the false comment** on `parse_entities`: it claims "We only look at the ENTITIES
  section's records". There is no section filter — that is `tinkerex#219`'s whole mechanism.

- [ ] **Step 5: The Measure view says so.** `measure_controller.js` appends a clause to the resting
  status when `payload.u` is present, e.g. `12 shapes · 2 SPLINE not readable · click one to
  measure`. Keep it in `restingStatus()`, which is already the one definition of that line.

- [ ] **Step 6: Commit**, then mutate: make `unreadable:` always emit (even empty) → the
  "omitted when empty" assertion must go **RED**. Restore.

---

## Stage 2: POLYLINE bulges

**Files:** `dxf.rb`, `dxf_geometry_test.rb`.

A bulge `b` on vertex *i* means the segment from vertex *i* to *i+1* is a circular arc, with
`b = tan(Δθ/4)` where `Δθ` is the signed included angle (positive = counter-clockwise). So
`Δθ = 4·atan(b)`; for a chord of length `c`, the radius is `r = c / (2·sin(Δθ/2))`, and the centre
lies on the perpendicular bisector at distance `r·cos(Δθ/2)` on the side the sign selects.

- [ ] **Step 1: Failing test** — a square polyline whose bottom edge bulges into a semicircle. A
  bulge of 1.0 is a half turn, so the arc must reach `r` beyond the chord and the **bbox must grow**:

```ruby
test "a POLYLINE bulge draws an arc, and the bbox grows to contain it" do
  # Two vertices 10 apart with bulge 1.0 on the first: a semicircle of radius 5 bulging below.
  dxf = "0\nSECTION\n2\nENTITIES\n0\nPOLYLINE\n8\nA\n70\n0\n" \
        "0\nVERTEX\n8\nA\n10\n0\n20\n0\n42\n1.0\n" \
        "0\nVERTEX\n8\nA\n10\n10\n20\n0\n" \
        "0\nSEQEND\n0\nENDSEC\n0\nEOF\n"
  b = build(dxf)["shapes"].first["b"]

  assert_in_delta 0.0,  b[0], 0.05
  assert_in_delta 10.0, b[2], 0.05
  # Y is flipped into client space; the arc's far side must be 5 mm from the chord.
  assert_in_delta 5.0, (b[3] - b[1]), 0.05, "a chord would give a zero-height bbox"
end
```

- [ ] **Step 2:** Run it; today the bbox height is 0 — the chord.

- [ ] **Step 3: `fold_polyline_vertices` keeps the bulge.** It currently pushes `[x, y]`; push
  `[x, y, bulge]` reading the VERTEX's own `codes[42]`. **This is the whole reason POLYLINE bulges
  are cheap and LWPOLYLINE bulges are not** — a VERTEX is its own record with its own codes hash.

- [ ] **Step 4: `polyline_points` emits arcs.** Between consecutive vertices with a non-zero bulge,
  emit arc samples instead of one straight segment; reuse `arc_samples(r, |Δθ|)` so the flattening
  stays bounded by **relative** sagitta (the traversal does not know the file's scale — that is
  `arc_samples`' own documented reason). A closed polyline's last→first segment can carry a bulge on
  the last vertex; cover it.

- [ ] **Step 5: LWPOLYLINE bulges are REPORTED, not parsed.** If an `LWPOLYLINE` carries a non-zero
  `42`, count it through Stage 1's mechanism under a distinct name (e.g. `LWPOLYLINE(bulge)`) so it
  is visible rather than silently chorded. Zero occur in the real corpus; this is the honest way to
  leave it unimplemented.

- [ ] **Step 6:** Verify against the real file: `dxf3.dxf` (1195 bulges). Report before/after.

  > **CORRECTED AFTER THE FACT (2026-09-03).** This step originally asserted the job box "must grow
  > or move". **It does not, on either available file, and the step was wrong to demand it.** Both
  > `dxf3.dxf` and `ore.dxf` bulge exclusively into CORNER FILLETS, which arc *inward*: a fillet cuts
  > a corner, so the straight edges still define the extent and the union cannot grow. Only 1 of 175
  > (dxf3) and 2 of 6 (ore) per-shape bboxes moved at all, each by 0.01 mm — one unit of `PRECISION`.
  >
  > "Arcs reach past their chords" is true of an OUTWARD bulge only, which is why the semicircle
  > fixture pins that direction synthetically. Verify the arcs are *present* instead: Stage 2 did it
  > by rendering with the arc path stubbed to nil and diffing per shape — 1,195 arcs drawn, 0
  > refused, 37 of them on the closing last→first segment, deepest chord deviation 0.043 mm, agreeing
  > with `r(1−cos(Δθ/2))` to 4 dp. That is the assertion this step should have asked for.

- [ ] **Step 7: Commit**, then mutate: ignore the bulge sign (use `|b|`) → a test with a
  negative bulge must go **RED** (the arc bulges the wrong side). Add that test if absent.

---

## Stage 3: SPLINE

**Files:** `dxf.rb`, `dxf_geometry_test.rb`. The largest stage; consider it its own review unit.

> ### ⚠ A GROUP CODE MEANS DIFFERENT THINGS ON DIFFERENT ENTITY TYPES — code 42 especially
>
> Measured by Stage 2, 2026-09-03: **`cards.dxf` carries 3,308 code-`42` pairs on SPLINE records**,
> where 42 is a control-point tolerance and has nothing to do with a polyline bulge. There are more
> on VPORT, STYLE and VISUALSTYLE.
>
> Stage 2's LWPOLYLINE-bulge tally therefore keys on `entity[:type] == "LWPOLYLINE"`, not on the
> presence of code 42 — and **that check is a green mutation today only because SPLINE is not yet
> drawable.** The moment you add `SPLINE` to `ENTITY_TYPES`, a code-keyed check would report 3,308
> unreadable "bulges" in a file that has none. Stage 2 left a test pinning this
> (`"code 42 on an entity that is not an LWPOLYLINE is not a bulge"`); **it must stay green through
> your change.** If it goes red you have re-keyed something on a code instead of a type.

- [ ] **Step 1: Failing test** — a degree-3 spline whose control points describe a known shape.
  Assert the **bbox and a sampled point**, not the point count.

- [ ] **Step 2: Parse.** `70` flags, `71` degree, `72`/`73`/`74` counts, `40` knots, `41` weights,
  `10`/`20` control points. Refuse when degree < 1, control points < degree+1, or the knot count
  ≠ control points + degree + 1 — a malformed spline must not raise and must not draw a scribble.

  > ### ⚠ A REFUSAL MUST BE TALLIED EXPLICITLY. Stage 1 will NOT catch it for you.
  >
  > This step originally read "return nil, and let Stage 1 report it". **That is false, and taking
  > it literally re-opens the exact hole this whole plan exists to close.** Stage 1's tally is
  > **type-based**: it is computed in `parse_entities` from the `0`-code name, for records whose type
  > is *not* in `ENTITY_TYPES`. The moment `SPLINE` joins `ENTITY_TYPES`, a SPLINE that `flatten`
  > refuses stops being tallied and vanishes silently again — with the status line now actively
  > reassuring the user that nothing was skipped.
  >
  > The plumbing is already there (the tally hash reaches `each_geometry`), so this is one line at
  > the `next if points.nil?` guard. **Tally a refusal under a DISTINCT name** — `SPLINE(malformed)`
  > rather than `SPLINE` — so "we cannot read this type at all" and "we read this one and it was
  > broken" do not collapse into the same number. Found by Stage 1's implementer, 2026-09-03.

  **The same trap applies to any stage that promotes a type into `ENTITY_TYPES` and can then refuse
  an instance of it** — Stage 4 Step 5 has it too, and it is called out there.

- [ ] **Step 3: Evaluate with de Boor** over the valid domain `[U[p], U[n+1]]`:

```
find span k with U[k] <= u < U[k+1]
d[j] = P[j+k-p]                             for j = 0..p
for r in 1..p:
  for j in p.downto(r):
    a = (u - U[j+k-p]) / (U[j+1+k-r] - U[j+k-p])
    d[j] = (1-a)*d[j-1] + a*d[j]
point = d[p]
```

  For weights, evaluate in homogeneous coordinates `(w·x, w·y, w)` and divide at the end. **Assert
  the all-weights-are-1 assumption** rather than trusting it: if the rational bit is clear but a
  weight differs from 1, honour the weights anyway (the homogeneous path is correct either way).

- [ ] **Step 4: Closed and periodic.** Flag bit 0 (closed) means the contour closes — append the
  first point if the last does not equal it, matching what `polyline_points` does for a closed
  polyline. Flag bit 1 (periodic) affects the knot vector's domain; evaluating strictly over
  `[U[p], U[n+1]]` is the safe reading. 433 of 1702 splines in one real family set bit 1, so this
  is exercised, not theoretical.

- [ ] **Step 5: Sampling, under the budget.** Sample per knot span with a **relative** flatness
  criterion and a bounded subdivision depth — the same constraint `arc_samples` documents (no scale
  is known here). A fixed high sample count per span will blow the budget: `cards.dxf` has 3308
  splines and one family has 514 spans in a single spline.

  **Budget, from the baseline: `cards.dxf` ≤ 3 s and ≤ 1.5 MB payload.** Measure it; report the
  numbers; if you cannot meet it, say so rather than quietly raising it.

- [ ] **Step 6: Verify against the real files.** `elianadxf.dxf` must go from `shapes=0, job 0×0` to
  a real outline. `macropad v5.dxf` must gain its 28 splines and its job box must change. Report
  before/after for both.

- [ ] **Step 7: Commit**, then mutate: drop the knot-vector span search (always use span `p`) →
  the bbox assertion must go **RED**.

---

## Stage 4: BLOCK and INSERT (`tinkerex#219`)

**Files:** `dxf.rb`, `dxf_geometry_test.rb`.

- [ ] **Step 1: Failing test** — the synthetic case already proven:

```ruby
test "a block draws at its INSERT, once, and not at its definition" do
  dxf = "0\nSECTION\n2\nBLOCKS\n0\nBLOCK\n2\nMYBLK\n" \
        "0\nLINE\n8\nA\n10\n0\n20\n0\n11\n10\n21\n0\n" \
        "0\nENDBLK\n0\nENDSEC\n" \
        "0\nSECTION\n2\nENTITIES\n0\nINSERT\n8\nA\n2\nMYBLK\n10\n100\n20\n200\n" \
        "0\nENDSEC\n0\nEOF\n"
  shapes = build(dxf)["shapes"]

  assert_equal 1, shapes.length, "once — not a ghost at the definition AND a copy at the insert"
  assert_in_delta 100.0, shapes.first["b"][0], 0.01
  assert_in_delta 110.0, shapes.first["b"][2], 0.01
end
```

  Today this returns one shape at `b=[0.0, -0.0, 10.0, -0.0]` — the definition coordinates.

- [ ] **Step 2: Parse the BLOCKS section** into `name => [entities]` (`2` names the block, `10`/`20`
  give its base point, which is subtracted before the insert transform).

- [ ] **Step 3: Make INSERT drawable.** `2` block name, `10`/`20` insertion point, `41`/`42`/`43`
  scale, `50` rotation (degrees, counter-clockwise), `70`/`71` column/row counts with `44`/`45`
  spacings. Emit the block's entities once per array cell with the composed affine applied.

- [ ] **Step 4: STOP drawing BLOCKS-section entities as top-level shapes.** This is the trap:
  **the fix is not additive.** A test asserting only "the inserted copy appears" passes while the
  ghost at the origin still draws — which is why Step 1 asserts the **shape count**.

- [ ] **Step 5: Nesting, with a cap.** Blocks may contain INSERTs. Recurse with a depth cap and a
  visited set; a self-referencing block is malformed input and must not hang the renderer.

  **Tally a refused nesting EXPLICITLY, under a distinct name** (e.g. `INSERT(too-deep)` /
  `INSERT(cyclic)` / `INSERT(unknown-block)`). Stage 1's tally is type-based and stops firing for
  `INSERT` the moment you add it to `ENTITY_TYPES` — see the boxed warning in Stage 3 Step 2. An
  INSERT naming a block that does not exist is the likely real case and must not be silent.

- [ ] **Step 6: Verify on real files** — any of the 24 with INSERTs; report shape-count and job-box
  before/after.

- [ ] **Step 7: Commit**, then mutate: keep collecting BLOCKS-section entities as drawables → the
  shape-count assertion must go **RED**.

---

## Stage 5: `tinkerex#215` rides along, then revisions

**Files:** `dxf.rb`, `dxf_geometry.rb`, `dxf_geometry_test.rb`.

- [ ] **Step 1: Fix the 360° ARC thumbnail bug.** `Dxf.arc_svg` emits a single `A` command whose
  endpoints coincide when the sweep is a full turn, and SVG omits such a segment entirely — so the
  shape draws as nothing. Give it the branch the payload already has: sweep ≥ 360 emits
  `<circle cx cy r>`. Add a fixture; without one the fix is a green mutation.

  **This is only free now because Stage 1–4 force `THUMBNAIL_REVISION` to move anyway** — that was
  the stated reason for deferring it.

- [ ] **Step 2: Bump BOTH revisions.** `Dxf.each_geometry` feeds the thumbnail *and* the payload, so
  the thumbnail SVG and the measure payload both change:
  - `Dxf::THUMBNAIL_REVISION` +1
  - `DxfGeometry::FORMAT_REVISION` +1 — **not** `Geometry::SHARED_REVISION`: this is a DXF-only
    change and bumping the shared term would needlessly re-render every `.lbrn2`, `.mage` and `.svg`
    payload as well.
  - `GeometryTest::GEOMETRY_REVISIONS` — `a.dxf` moves 2 → 3.

- [ ] **Step 3: Update BOTH byte digests** in `dxf_geometry_test.rb` for both fixtures, and record
  in that test's comment *why* both the SVG and the payload moved this time (last time only the
  payload did, and that asymmetry was the evidence the thumbnail was untouched).

- [ ] **Step 4: Commit.**

---

## Stage 6: Record the invariants

**Files:** `docs/invariants/measure-view.md`, `app/services/maker/previews/dxf.rb` comments.

- [ ] Write the rules, in the file's voice, consequence named:
  - **A `case` with no `else` over a file format's entity types is a silent data-loss bug.** 18,906
    splines across 29 of 129 real files; one file reported "No measurable geometry" about a file
    that is entirely geometry. The skipped entity is absent from the **bbox** as well as the
    drawing, so the reported size describes a subset.
  - **Never line-grep a DXF.** `^SPLINE$` misses every CRLF file; it undercounted by 78×. Walk
    code/value pairs.
  - **All real bulges are on `POLYLINE` `VERTEX` records, none on `LWPOLYLINE`** — and why one is
    addressable and the other is not (`parse_entities` groups by code and loses interleaving).
  - **`tokenize` does not scope to the ENTITIES section**, which is why block bodies used to draw at
    their definition coordinates; the fix had to *remove* that behaviour, not just add INSERT.
  - **Both DXF revisions move together** whenever `each_geometry` changes, because it feeds the
    thumbnail and the payload.
  - **The payload budget is real:** `cards.dxf` was 563 KB before splines; state where it landed.

- [ ] Commit.

---

## Stage 7: Gates and close-out

- [ ] `bin/ci` (from a worktree, `TINKEREX_SYNC_DIR` must be set). Three backend legs must report
      identical run counts.
- [ ] `/finish-branch`; `bin/log arc --from-pr <n>`; close `tinkerex#215`, `#216` and `#219` at merge.

## Out of scope, deliberately

- **`ELLIPSE`** — zero occurrences in 129 real files. Stage 1's backstop surfaces one the day it
  appears, which is the honest way to defer it.
- **`LWPOLYLINE` bulges** — zero occurrences; reported, not parsed (Stage 2 Step 5).
- **`TEXT`/`MTEXT`** — 13 occurrences; text outlines are a different problem from geometry (LightBurn
  supplies a `BackupPath`; DXF supplies none). Reported by Stage 1.
- **Curve descriptors (`g`) for splines** — that is `tinkerex#217`. Stage 2's bulge arcs *could*
  cheaply emit the existing arc descriptor; do it only if it falls out for free.
