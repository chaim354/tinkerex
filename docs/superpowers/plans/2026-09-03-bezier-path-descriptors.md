# Bezier path descriptors — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: this repo's `.claude/commands/execute-plan.md`
> (`/execute-plan`). Steps use checkbox (`- [ ]`) syntax.

**Goal:** A contour the file describes with curves reaches the client as a curve. Today only
file-declared ellipses and arcs do (`"e"` / `"a"`); every bezier flattens to a polyline, so the SVG
export hands a vector app and a CAD sketch a run of short segments where a curve belongs.

**Issue:** `tinkerex#217`.

**Architecture:** One new wire form, `"p"` — an absolute path of **cubics and lines only**. Every
input normalizes to that, which makes the client trivial and every affine placement a matter of
transforming control points.

---

## Measured facts — this is not speculative work

Live share library, 2026-09-03:

| leg | files with curves | volume |
|---|---|---|
| LightBurn / MillMage | **70 of 99** | 49,030 `B` bezier segments vs 41,317 `L` lines |
| SVG | **134 of 168** | 116,244 `C`, 8,011 `S`, 1,459 `Q`, 859 `A`, 2 `T` |

**Estimated payload cost** (one cubic ≈ 6 rounded numbers, one line ≈ 2), on the bezier-heaviest
real files:

```
metal test 1.lbrn2   574 KB  ->  +202 KB  (+35%)
gamebox v7.lbrn2     329 KB  ->  +178 KB  (+54%)
bookmark.lbrn2       744 KB  ->   +95 KB  (+12%)
```

**No hard budget is set, deliberately.** The last plan set one before counting and it was
arithmetically impossible (`tinkerex#216`, `cards.dxf`). Instead: **measure the real growth and
report it.** If it lands materially worse than +54% on these files, stop and say so rather than
tuning in the dark.

> **The offset lever, recorded and NOT taken in this arc.** `p` is used for hit-testing, for
> measurement inputs (`b`/`d` are computed server-side from FULL-resolution points, so they are
> unaffected either way), and for drawing when there is no descriptor. Where a descriptor exists the
> client draws THAT, so `p` is only a hit target — and a hit target does not need 0.01 mm fidelity.
> `metal test 1.lbrn2` retains ~6.6 points per bezier segment; thinning those harder could more than
> pay for the descriptor. **Do not do it in this arc** — it is a second, independent change to
> interaction fidelity and it would confound the measurement this plan exists to take.

> ### ⚠ OUTCOME (2026-09-03): growth is ~2×, the estimate above was wrong, and the cost was ACCEPTED
>
> Measured by Stage 1 on the three real files, against the estimate:
>
> ```
> metal test 1.lbrn2   574.3 ->  951.8 KB   +66%  (est. +35%)   gzipped 162 -> 285 KB
> gamebox v7.lbrn2     329.7 ->  555.5 KB   +69%  (est. +54%)   gzipped  86 -> 151 KB
> bookmark.lbrn2       744.5 -> 1476.2 KB   +98%  (est. +12%)   gzipped 210 -> 440 KB
> ```
> Render time moved 3–7%, which is noise.
>
> **WHY THE ESTIMATE WAS WRONG, since the failure is reusable.** Its baselines were exact and its
> per-cubic arithmetic was right (~48–57 measured bytes per cubic against "6 rounded numbers"). What
> it got wrong was the CUBIC COUNT: it counted `B<a> <b>` ops in the file TEXT, but LightBurn shares
> geometry between instances by `VertID`/`PrimID` (`Lbrn2::GeometryIndex`), so one `B` op in the text
> is DRAWN many times. `bookmark.lbrn2` has 2,169 `B` ops in its text and emits **14,825** cubics —
> 6.8×. **Counting a file's text is not counting what a traversal yields**, and this is the second
> time on this branch that a text-level count misled a plan (the first: `grep -E "^SPLINE$"` missing
> every CRLF file, `tinkerex#216`, off by 78×).
>
> **The decision.** The offset lever above was offered and DECLINED on 2026-09-03: ship the growth.
> The reasoning that makes it affordable — after RDP at 0.01 mm, `p` retains only ~2.9 points per
> cubic, so an exact cubic costs about what its own thinned polyline already cost — is also what
> makes the lever available later if the size ever bites. **A future reader finding a doubled payload
> here should know it was measured and accepted, not missed.**

## The wire form

```
["p", "M 0 0 C 1 2 3 4 5 6 L 8 8 Z"]
```

An absolute path string of `M` / `L` / `C` / `Z` **only**, in client space (mm, Y-down), numbers
rounded at `Geometry::PRECISION`.

- **Cubics only, because every input reduces to one exactly or near enough.** `C` already is one;
  `S` and `T` reflect the previous control point into one; **`Q` converts to a cubic EXACTLY**
  (`c1 = p0 + ⅔(c − p0)`, `c2 = p + ⅔(c − p)`); a LightBurn `B` segment IS a cubic
  (`(a, a.c0, b.c1, b)`).
- **`A` becomes cubics too, and that is not a compromise.** An SVG arc under a NON-UNIFORM scale is
  a different ellipse arc needing a rotation the `"e"` form cannot express — the case Stage 4 of the
  DXF arc had to drop a descriptor for. Cubics transform affinely, so converting sidesteps it
  entirely. Bounded error, ≤4 segments per arc.
- **A `d` STRING, not a segment array.** Smaller on the wire and directly usable. It is built
  server-side from parsed NUMBERS — no byte of user markup reaches it — so this is not the inlining
  §15 forbids, and `setAttribute("d", …)` is a geometry attribute, not markup. Say so in the comment;
  it is exactly the kind of thing a reviewer should challenge.
- **`"e"` and `"a"` stay.** An ellipse as four cubics is less exact and more bytes than
  `["e", cx, cy, rx, ry]`. The new form is for what has no exact primitive.

## Out of scope

- **DXF splines.** Newly eligible — since `tinkerex#216` they are parsed, degree 3 everywhere, and a
  degree-3 NURBS decomposes into exact cubics by Böhm knot insertion. But `cards.dxf` already sits
  at 3.4 MB and this would add to it, so it is a separate decision with its own measurement. Note it
  in the invariants as newly possible.
- **Thinning `p` where a descriptor exists** — the offset lever above.

---

## Stage 1: The seam, with LightBurn as its first producer

**Files:** `geometry.rb`, `lbrn2.rb`, `lbrn_geometry.rb`, `lib/shape_svg.js`, their tests.

- [ ] **Step 1: Failing test** — `bezier-circle.lbrn2`'s circle is a `<Shape Type="Path">` of four
  cubic `B` segments. It must gain a `"p"` descriptor. Assert **the resolved geometry**, not the
  string: parse the `d`, evaluate the cubics, and check the result tracks the shape's own `p` points
  and reaches its `b` bbox to a stated tolerance.

  > **A STRING-EQUALITY ASSERTION DOES NOT DISCHARGE THIS.** `tinkerex#213`'s arc descriptor passed
  > its own five-number equality test while drawing a curve 1.37 mm from the shape's own points.
  > The guard has to resolve the descriptor back into a curve the way a renderer does.

- [ ] **Step 2:** Run it; expect no `"g"` on that shape.

- [ ] **Step 3: `Geometry.path_curve(d)`** beside `ellipse_curve`/`arc_curve`, so the wire encoding
  keeps one definition. Carry the comment explaining the `d`-string safety argument above.

- [ ] **Step 4: `Lbrn2.polylines` emits a segment list beside its points.** It already holds
  `(a, a.c0, b.c1, b)` per `B` op and throws the control points away one line later. Build the
  absolute `M`/`L`/`C` list per CONTOUR and push the control points through the SAME
  `apply(world, x, y)` the vertices get.

  Traps: `prim_ops`' synthetic `Closed`/`Bezier` arm builds ops that come from no `PrimList`;
  `polylines` splits into MULTIPLE contours when `prev != ai`, so a descriptor belongs per contour;
  and a control point that misses the affine draws a plausible-but-wrong curve — this repo's
  recurring failure shape.

- [ ] **Step 5: `LbrnGeometry` passes it through**, alongside the existing `ellipse &&` arm. A shape
  yields at most one descriptor: an `Ellipse` keeps `"e"`, a `Path` gets `"p"`.

- [ ] **Step 6: `shapeElement` gains a `"p"` branch** → `<path d=…>`. Note a `<path>` is hit-tested
  like the `<polygon>` it replaces for a closed contour (`.measure-contour { fill: transparent }`),
  and an open one keeps its polyline hit twin built from `shape.p`.

- [ ] **Step 7: Measure on real files** and report: payload before/after and render time for the six
  bezier-heaviest, from the scratchpad copies. Compare against the +12–54% estimate above.

- [ ] **Step 8: Commit, THEN mutate.** `git checkout --` restores to HEAD, so mutating first
  destroys the task's own work. Mutations, each with actual RED pasted:
  - skip the affine on the control points (transform only the endpoints) → the resolved-geometry
    test must go RED. *(A string-equality test would not catch this — that is the point.)*
  - emit one descriptor for a multi-contour Path → RED.

---

## Stage 2: The SVG leg

**Files:** `svg_path.rb`, `svg_geometry.rb`, their tests.

`SvgPath::State` already resolves every command to ABSOLUTE coordinates and dispatches to
`line_to` / `cubic` / `smooth_cubic` / `quadratic` / `smooth_quadratic` / `arc` / `close`. The
normalization work is done; each of those appends a segment beside the points it flattens.

- [ ] **Step 1: Failing tests**, one per command family, each asserting resolved geometry:
  `C`, `S` (reflection), `Q` (exact cubic conversion), `T`, `A` (≤4 cubics, bounded error), `H`/`V`,
  and a `Z` that closes.

- [ ] **Step 2: `State` accumulates a parallel absolute segment list** and `parse` returns it beside
  the contours. **Do not change `contours_for`'s seven-branch return shape** — only `path` produces
  a descriptor; `rect`/`circle`/`ellipse`/`line`/`polyline`/`polygon` already have exact forms or are
  polygons.

- [ ] **Step 3: `SvgGeometry` scales it** by the same `sx`/`sy` the points get, and applies `world`.
  **SVG IS ALREADY Y-DOWN — no flip.** A flip added "for symmetry with Dxf" turns every SVG upside
  down and still draws a plausible picture; only a positional assertion catches it.

- [ ] **Step 4: The axis-aligned gate does NOT apply here.** It exists because an `"e"` ellipse
  cannot express a rotation. **A cubic path can** — it transforms affinely under any matrix — so a
  rotated or skewed `<path>` keeps its descriptor. Say so in a comment, or the next reader will
  "fix" it into a needless refusal.

- [ ] **Step 5: Measure and report** on real SVG files.

- [ ] **Step 6: Commit, then mutate:** drop the `A`→cubic conversion and emit the raw arc → the
  arc test must go RED; apply `sx` to both axes → the non-uniform-scale test must go RED.

---

## Stage 3: Invariants, gates, close-out

- [ ] Record in `docs/invariants/measure-view.md`: the cubics-only normalization and why (one
  segment kind ⇒ affine transforms are control-point transforms); `Q`→`C` is exact while `A`→cubics
  is bounded; the `d`-string safety argument; why the axis-aligned gate binds on `"e"` and not on
  `"p"`; the measured payload growth; and that DXF splines are newly eligible but deliberately out.
- [ ] `bin/ci` — three backend legs must report identical run counts. `TINKEREX_SYNC_DIR` must be set
      from a worktree.
- [ ] `/finish-branch`; `bin/log arc --from-pr <n>`; close `tinkerex#217` at merge.
