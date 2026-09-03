# Measure shape SVG export — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: this repo's `.claude/commands/execute-plan.md`
> (`/execute-plan`) is the DEFAULT and overrides any generic subagent loop — batch by FILE, run
> independent tasks in PARALLEL, no spec-compliance stage, cap each quality review to named claims.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an `SVG` button to the Measure view that downloads the selected shapes as a
standalone, to-scale SVG — and carry the exact curve primitives the parsers already produce into
the geometry payload so circles and arcs export as curves rather than polygons.

**Architecture:** `Geometry::Collector#add` gains a `curve:` slot; the three geometry modules stop
discarding the descriptors their traversals already yield. Client-side, one shared
`lib/shape_svg.js` decides element type for the Measure view, the print sheet and a new pure
`lib/export_svg.js`; the controller resolves the target set once for all three consumers.

**Tech Stack:** Rails 8, Nokogiri, Minitest; Stimulus + importmap-pinned ES modules, no bundler and
no JS test runner — browser-tier assertions run through Capybara/Selenium.

**Spec:** `docs/superpowers/specs/2026-09-02-measure-shape-svg-export-design.md`

---

## Background an engineer needs before starting

Read `docs/invariants/measure-view.md` (CLAUDE.md §14h) before touching anything here. The five
rules that bind hardest on this plan:

1. **Measurement never comes from drawing data.** `b` (bbox), `d` (diameter) and the job box are
   computed from full-resolution points *before* thinning. `p` is RDP-thinned at 0.01 mm and is for
   drawing only. The new `g` descriptor is likewise drawing-only.
2. **A change in `Geometry` bumps every format's revision**, done by bumping
   `Geometry::SHARED_REVISION` — one line, because each format's `PAYLOAD_REVISION` is
   `SHARED_REVISION + FORMAT_REVISION`.
3. **`SCHEMA_VERSION` is not `PAYLOAD_REVISION`** and is the easy one to bump by mistake. This plan
   does not bump it.
4. **`measure_controller.js` branches on no file type.** Descriptors therefore arrive already in
   client space (mm, Y-down).
5. **Mutation-check every guard.** After a guard test goes green, break the thing it guards and
   confirm RED, then restore.

**COMMIT BEFORE YOU MUTATE.** Every mutation check below says to break something, confirm RED, then
restore with `git checkout -- <file>`. That restores to **HEAD** — so if the task's own
implementation is still uncommitted, the restore wipes it too, and if the mutated file is brand new
it is untracked and `git checkout --` fails outright. **Do each task's commit step FIRST, then
mutate, then restore.** The commit is what makes the restore a real restore. (Learned the hard way
during this plan's own execution on 2026-09-02, and already recorded in the user's memory as
`git-checkout-destroys-parallel-agent-work`.) The one exception is Task 3, whose mutation targets
`lbrn2.rb` — a file that task never edits, so it is clean at HEAD either way.

Also: this suite has **no `Object#stub`** (minitest 6 dropped `minitest/mock`). Use the house
`counting`/`replacing` patterns already in `dxf_geometry_test.rb`.

Running tests from this worktree needs `TINKEREX_SYNC_DIR` set for the chunk_remote leg, and bare
`bin/rails test` needs `LIBRARY_PATH`:

```bash
LIBRARY_PATH=$(mktemp -d) bin/rails test test/services/maker/previews/geometry_test.rb
```

## File structure

**Created**

| path | responsibility |
|---|---|
| `app/javascript/lib/shape_svg.js` | One payload shape → one SVG element. Element type + geometry attributes only, no presentation. Also the home of `el` and `unionBox`, moved here so there is one door. |
| `app/javascript/lib/export_svg.js` | Selected shapes → a standalone SVG document string. Pure; no page access, no download. |
| `test/fixtures/files/rotated-ellipse.lbrn2` | Two ellipses, one axis-aligned and one rotated 30°. Closes the currently-untested `axis_aligned?` branch. |
| `test/system/measure_export_test.rb` | Both browser tiers for the exporter. |

**Modified**

| path | change |
|---|---|
| `app/services/maker/previews/geometry.rb` | `ellipse_curve` / `arc_curve` wire constructors; `Collector#add` gains `curve:`; `SHARED_REVISION` 0 → 1. |
| `app/services/maker/previews/lbrn_geometry.rb` | Stop discarding `_ellipse`. |
| `app/services/maker/previews/dxf_geometry.rb` | Stop discarding `_curve`; add `curve_to_client_space`. |
| `app/services/maker/previews/svg_geometry.rb` | `ellipse_curve_for` + axis-aligned gate; `walk` yields it; `build` scales it. |
| `app/javascript/lib/print_sheet.js` | Import + re-export `el`/`unionBox`; `contourNode` delegates to `shapeElement`. |
| `app/javascript/controllers/measure_controller.js` | `contourNode` delegates; `targetShapes`/`targetNoun`; `downloadSvg`; shared `unionBox`. |
| `app/views/files/_measure.html.erb` | The `SVG` button. |
| `config/importmap.rb` | Two pins. |
| `test/services/maker/previews/geometry_test.rb` | Revision pins 4/4/4/1/1 → 5/5/5/2/2. |
| `test/services/maker/previews/{lbrn,dxf,svg}_geometry_test.rb` | Descriptor tests. |
| `test/system/measure_print_test.rb` | Assertions that read `points=` on a now-`<ellipse>` shape. |
| `docs/invariants/measure-view.md` | The new rules. |

## Out of scope, recorded

**`Dxf.arc_svg` draws nothing for a 360° `ARC`.** `Dxf.arc_points` turns `a0 == a1` into a 360°
sweep (its own comment: *"the whole circle, not a zero-length arc"*), whose start and end points are
identical — and SVG's rule for an arc whose endpoints coincide is to omit the segment entirely. So
a full-circle `ARC` entity renders as nothing in the DXF **thumbnail** today. This plan does not fix
that (it would need a `Dxf::THUMBNAIL_REVISION` bump and a DXF thumbnail rebuild), but Task 4 must
not inherit the bug: the payload encodes a 360° arc as an **ellipse**.

---

## Task 1: The `curve:` slot and its wire form

**Files:**
- Modify: `app/services/maker/previews/geometry.rb`
- Test: `test/services/maker/previews/geometry_test.rb`

- [ ] **Step 1: Write the failing tests**

Add to `test/services/maker/previews/geometry_test.rb`, inside the existing class:

```ruby
      # ---- curve descriptors --------------------------------------------------------------

      # A DRAWING HINT AND NEVER A MEASUREMENT. The descriptor rides alongside the points; `b` and
      # `d` are still computed from the points, so a payload built WITH one and a payload built
      # WITHOUT one must report identical numbers. Asserted against a shape that is genuinely
      # round, so `d` is present and could plausibly have been recomputed from the descriptor.
      test "a curve descriptor changes no measured number" do
        points = (0..32).map { |i| t = i * (2 * Math::PI / 32); [ 10 * Math.cos(t), 10 * Math.sin(t) ] }

        plain = Geometry.build { |o| o.add(layer: 0, points:, closed: true, object_id: 1) }
        with  = Geometry.build do |o|
          o.add(layer: 0, points:, closed: true, object_id: 1,
                curve: Geometry.ellipse_curve(0.0, 0.0, 10.0, 10.0))
        end

        assert_equal plain["shapes"][0]["b"], with["shapes"][0]["b"]
        assert_equal plain["shapes"][0]["d"], with["shapes"][0]["d"]
        assert_equal plain["shapes"][0]["p"], with["shapes"][0]["p"]
        assert_equal plain["job"], with["job"]
      end

      # ABSENT, NOT NULL. A `"g" => nil` on every polygon is bytes on the wire for nothing, and the
      # client's own check is truthiness, so a null would read as "no descriptor" while still being
      # paid for on the densest files — the ones the payload's size budget exists for.
      test "a shape with no curve carries no g key at all" do
        payload = Geometry.build { |o| o.add(layer: 0, points: [ [ 0, 0 ], [ 1, 1 ] ], closed: false, object_id: 1) }

        assert_not payload["shapes"][0].key?("g")
      end

      test "ellipse_curve rounds to PRECISION and tags its type" do
        assert_equal [ "e", 1.23, -4.57, 10.0, 5.0 ],
                     Geometry.ellipse_curve(1.234, -4.567, 10.0, 5.0)
      end

      test "arc_curve rounds its coordinates and passes its flags through" do
        assert_equal [ "a", 0.0, 0.0, 10.0, 0.0, 5.0, 1, 0 ],
                     Geometry.arc_curve(0.0, 0.0, 10.0, 0.004, 5.0, 1, 0)
      end
```

- [ ] **Step 2: Run to verify they fail**

```bash
LIBRARY_PATH=$(mktemp -d) bin/rails test test/services/maker/previews/geometry_test.rb
```

Expected: FAIL — `NoMethodError: undefined method 'ellipse_curve'`.

- [ ] **Step 3: Add the wire constructors**

In `app/services/maker/previews/geometry.rb`, after the `PRECISION = 2` constant and before
`SHARED_REVISION`:

```ruby
      # THE WIRE FORM OF A CURVE DESCRIPTOR, WITH ONE DEFINITION HERE RATHER THAN THREE IN THE
      # FORMAT MODULES. A format supplies the numbers; the encoding lives here, so `["e", ...]` is
      # not a string spelled in LbrnGeometry, DxfGeometry and SvgGeometry that must then agree —
      # the N-copies-that-must-agree defect §14b records as four skip-list strings and §14d as five
      # port_writable? branches.
      #
      # ALREADY IN CLIENT SPACE — millimetres, Y-down. `measure_controller.js` branches on NO file
      # type and must not learn what a DXF Y-flip is; each format's geometry module puts its
      # descriptor into this space exactly as it already does for its points.
      #
      # A DRAWING HINT, NEVER A MEASUREMENT. `b`, `d` and the job box are computed from the
      # FULL-RESOLUTION points above and are untouched by anything here — the same contract
      # `Lbrn2.each_geometry` and `Dxf.each_geometry` already state about the descriptors they
      # yield ("a richer rendering of the same points, never a substitute for them"). A client
      # ignoring `"g"` draws what it drew before this existed and reports identical numbers.
      #
      # AND NOTHING INFERS ONE FROM THE POINTS. A shape gets a descriptor because the FILE said
      # <Ellipse> / CIRCLE / ARC / <circle>, never because it measured round. `Geometry.diameter`'s
      # accepted consequence — a genuine 16-gon reports as round — stays confined to the `d` LABEL
      # and must never reach exported geometry, where it would substitute a circle for a designed
      # polygon in a file somebody cuts.
      def ellipse_curve(cx, cy, rx, ry)
        [ "e", *[ cx, cy, rx, ry ].map { |v| v.round(PRECISION) } ]
      end

      # SVG `A`-command parameters, resolved. Centre-plus-angles would push the Y-flip's
      # orientation reversal onto the client, which is the one thing the client may not know.
      def arc_curve(x0, y0, x1, y1, r, large_arc, sweep)
        [ "a", *[ x0, y0, x1, y1, r ].map { |v| v.round(PRECISION) }, large_arc, sweep ]
      end
```

- [ ] **Step 4: Add the slot to `Collector#add`**

Change the signature and add one line before `@shapes << entry`:

```ruby
        def add(layer:, points:, closed:, object_id:, image: false, curve: nil)
```

```ruby
          entry["d"] = d.round(PRECISION) if d
          # ABSENT RATHER THAN NULL when a format has no exact primitive to offer — which is most
          # shapes in most files. See Geometry.ellipse_curve for what this is and is not.
          entry["g"] = curve if curve

          @shapes << entry
```

- [ ] **Step 5: Run to verify pass**

```bash
LIBRARY_PATH=$(mktemp -d) bin/rails test test/services/maker/previews/geometry_test.rb
```

Expected: PASS.

- [ ] **Step 6: Mutation-check**

Change `entry["g"] = curve if curve` to `entry["g"] = curve` (unconditional). Run the tests —
"a shape with no curve carries no g key at all" must go **RED**. Restore.

- [ ] **Step 7: Commit**

```bash
git add app/services/maker/previews/geometry.rb test/services/maker/previews/geometry_test.rb
git commit -m "Geometry: a curve slot on the collector, with one definition of its wire form"
```

---

## Task 2: LbrnGeometry stops discarding the ellipse

**Files:**
- Modify: `app/services/maker/previews/lbrn_geometry.rb:67`
- Test: `test/services/maker/previews/lbrn_geometry_test.rb`

`Lbrn2.each_geometry` yields points already in SVG space (composed affine, then Y-flip) and
`ellipse_from` derives `[cx, cy, rx, ry]` from those same transformed points — so **no transform is
needed here**, unlike DXF.

- [ ] **Step 1: Write the failing test**

Add to `test/services/maker/previews/lbrn_geometry_test.rb`:

```ruby
      # ---- curve descriptors ----------------------------------------------------------------

      # `sample.lbrn2` carries an <Ellipse>, and the traversal has always yielded an exact
      # descriptor for it — `Lbrn2.to_svg` draws a real <ellipse> from it. The payload discarded it
      # by name (`_ellipse`) until now, so the Measure view drew a 32-gon beside a thumbnail
      # drawing an ellipse.
      test "an Ellipse shape carries an exact curve descriptor" do
        payload = build("sample.lbrn2")
        curves = payload["shapes"].filter_map { |s| s["g"] }

        assert_equal 1, curves.length, "sample.lbrn2 has exactly one Ellipse"
        assert_equal "e", curves.first[0]
      end

      # NOT "close to". ELLIPSE_SAMPLES is 32 — a multiple of 4 — so an axis-aligned ellipse's axis
      # extents are sampled EXACTLY and `ellipse_from` recovers the file's own radii rather than an
      # approximation of them. A tolerance here would pass just as well for a descriptor derived
      # from a coarse sample, which is the thing worth knowing.
      test "the descriptor recovers the file's own radii exactly" do
        payload = build("rotated-ellipse.lbrn2")
        upright = payload["shapes"].find { |s| s["g"] }

        assert_equal [ "e", 0.0, 0.0, 20.0, 10.0 ], upright["g"]
      end

      # THE SAFETY ARGUMENT, PINNED. `bezier-circle.lbrn2`'s circle is a <Shape Type="Path"> of four
      # cubic segments — it MEASURES round, so `d` is present and the readout says ⌀20 mm — but the
      # file never declared it a primitive, so it must carry NO descriptor. Nothing may infer one
      # from the points: `Geometry.diameter`'s accepted consequence is that a genuine 16-gon reports
      # as round, which is harmless in a LABEL and is wrong geometry in a file somebody cuts.
      #
      # This is the assertion that would catch a "helpfully" widened implementation, and it is the
      # one no Ellipse fixture can make.
      test "a Path that measures round carries no descriptor" do
        payload = build("bezier-circle.lbrn2")
        round = payload["shapes"].find { |s| s["d"] }

        assert_not_nil round, "the bezier circle still measures round"
        assert_not round.key?("g"), "but it was never DECLARED round, so nothing may say it is"
      end
```

- [ ] **Step 2: Run to verify it fails**

```bash
LIBRARY_PATH=$(mktemp -d) bin/rails test test/services/maker/previews/lbrn_geometry_test.rb
```

Expected: FAIL — `assert_equal 1, curves.length` gets 0. (The second test also errors on the
missing fixture; Task 3 creates it. Run only the first test here if you prefer:
`-n "/exact curve descriptor/"`.)

- [ ] **Step 3: Stop discarding it**

In `app/services/maker/previews/lbrn_geometry.rb`, replace the `each_geometry` block:

```ruby
        Geometry.build(colors: colors_for(doc)) do |out|
          # `ellipse` IS ALREADY IN CLIENT SPACE and needs no conversion, unlike DxfGeometry's.
          # `Lbrn2.each_geometry` yields points with the composed affine and the Y-flip already
          # applied, and `Lbrn2.ellipse_from` derives the descriptor from those same points — so
          # adding a transform here would apply the flip twice. `Lbrn2` also suppresses the
          # descriptor for a rotated XForm (`axis_aligned?`), which is what keeps a rotated ellipse
          # a polygon rather than an upright ellipse the file does not contain.
          Lbrn2.each_geometry(doc) do |cut, points, closed, ellipse, image, object_id|
            out.add(layer: cut, points:, closed:, image: !image.nil?, object_id:,
                    curve: ellipse && Geometry.ellipse_curve(*ellipse))
          end
        end
```

- [ ] **Step 4: Run the first test to verify pass**

```bash
LIBRARY_PATH=$(mktemp -d) bin/rails test test/services/maker/previews/lbrn_geometry_test.rb -n "/exact curve descriptor/"
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/services/maker/previews/lbrn_geometry.rb test/services/maker/previews/lbrn_geometry_test.rb
git commit -m "LbrnGeometry: carry the ellipse descriptor the traversal already yields"
```

---

## Task 3: The rotated-ellipse fixture, closing an untested branch

**Files:**
- Create: `test/fixtures/files/rotated-ellipse.lbrn2`
- Test: `test/services/maker/previews/lbrn_geometry_test.rb`

**Why this exists.** No fixture in the repo has a rotated transform — every `<XForm>` across all
seven `.lbrn2` and two `.mage` fixtures is a translate or a scale. So `Lbrn2.axis_aligned?` is an
untested branch *today*: deleting the gate is a green mutation. Task 2 raises its stakes, because
the gate stops governing thumbnail crispness and starts governing exported geometry.

`plate.svg` must not be modified — its own header states that every number in it is an assertion.

- [ ] **Step 1: Create the fixture**

```bash
cat > test/fixtures/files/rotated-ellipse.lbrn2 <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!-- Hand-authored, in the dialect real LightBurn writes (see real-export.lbrn2).

     THE ONLY FIXTURE IN THE REPO WITH A ROTATED XForm, and that is its whole reason for
     existing. Every other .lbrn2 and .mage fixture carries a translate or a scale, so
     Lbrn2.axis_aligned? had no test at all and deleting it was a green mutation.

     TWO ELLIPSES, DELIBERATELY BOTH DIRECTIONS — an implementation that always emits a
     descriptor and one that never does each pass half of a one-shape fixture:

       upright  Rx=20 Ry=10 at the origin, identity XForm
                -> MUST carry g == ["e", 0.0, 0.0, 20.0, 10.0]

       rotated  the same ellipse under 0.866025 -0.5 0.5 0.866025 (30 degrees), moved to x=100
                so the two do not overlap
                -> MUST carry NO g at all: under a rotation an SVG <ellipse> is not an SVG
                   <ellipse>, and emitting one exports geometry the file does not contain

     The radii differ (20 x 10, not a circle) on purpose: a rotated CIRCLE is still an upright
     circle, so it cannot tell a working gate from a missing one. -->
<LightBurnProject AppVersion="1.6.00" FormatVersion="1" MaterialHeight="0">
    <CutSetting type="Cut">
        <index Value="0"/>
        <name Value="C00"/>
        <speed Value="20"/>
        <maxPower Value="80"/>
    </CutSetting>
    <Shape Type="Ellipse" CutIndex="0" Rx="20" Ry="10">
        <XForm>1 0 0 1 0 0</XForm>
    </Shape>
    <Shape Type="Ellipse" CutIndex="0" Rx="20" Ry="10">
        <XForm>0.866025 -0.5 0.5 0.866025 100 0</XForm>
    </Shape>
</LightBurnProject>
EOF
```

- [ ] **Step 2: Write the refusal test**

Add to `test/services/maker/previews/lbrn_geometry_test.rb`:

```ruby
      # THE GATE, IN THE DIRECTION THAT MATTERS. Under a rotation an SVG <ellipse> is not an SVG
      # <ellipse>, so emitting a descriptor would export geometry the file does not contain — and
      # unlike a wrong LABEL, that is a shape somebody cuts. The upright ellipse in the same
      # fixture is asserted two tests up: an implementation that always emits and one that never
      # emits each pass exactly one of the pair.
      test "a rotated Ellipse carries no descriptor and stays a polygon" do
        payload = build("rotated-ellipse.lbrn2")

        assert_equal 2, payload["shapes"].length
        with, without = payload["shapes"].partition { |s| s.key?("g") }
        assert_equal 1, with.length, "the upright ellipse keeps its descriptor"
        assert_equal 1, without.length, "the rotated one does not acquire one"
        assert_operator without.first["p"].length, :>, 12, "it is still drawn as a polygon"
      end
```

- [ ] **Step 3: Run to verify pass**

```bash
LIBRARY_PATH=$(mktemp -d) bin/rails test test/services/maker/previews/lbrn_geometry_test.rb
```

Expected: PASS (all three curve tests).

- [ ] **Step 4: Mutation-check the gate**

In `app/services/maker/previews/lbrn2.rb`, change the `Ellipse` arm's
`(axis_aligned?(world) ? ellipse_from(pts) : nil)` to `ellipse_from(pts)`. Run:

```bash
LIBRARY_PATH=$(mktemp -d) bin/rails test test/services/maker/previews/lbrn_geometry_test.rb
```

Expected: **RED** on "a rotated Ellipse carries no descriptor". Restore the gate and re-run to
green. *(Before this task that mutation was green — that is the branch this closes.)*

- [ ] **Step 5: Commit**

```bash
git add test/fixtures/files/rotated-ellipse.lbrn2 test/services/maker/previews/lbrn_geometry_test.rb
git commit -m "A rotated-XForm fixture: axis_aligned? was a green mutation until now"
```

---

## Task 4: DxfGeometry carries circles and arcs

**Files:**
- Modify: `app/services/maker/previews/dxf_geometry.rb:37`
- Test: `test/services/maker/previews/dxf_geometry_test.rb`

DXF descriptors arrive in **model space** (native units, Y-up) and need the same
scale-then-flip `to_client_space` applies to points.

- [ ] **Step 1: Write the failing tests**

Add to `test/services/maker/previews/dxf_geometry_test.rb`, inside the class:

```ruby
      # ---- curve descriptors ----------------------------------------------------------------

      # A CIRCLE entity is exact in both DXF and SVG. The traversal has always yielded the
      # descriptor (`Dxf.to_svg` draws a real <circle> from it); the payload discarded it by name.
      test "a CIRCLE entity carries an exact ellipse descriptor in client space" do
        payload = build(circle_dxf(radius: 5, insunits: nil))

        # Model space is Y-up and the client's is Y-down, so cy is negated — the same flip
        # to_client_space applies to the points. Centre (0,0) makes that invisible, so this
        # fixture puts the circle off the y axis.
        assert_equal [ "e", 0.0, 0.0, 5.0, 5.0 ], payload["shapes"].first["g"]
      end

      test "the descriptor is scaled and Y-flipped exactly as the points are" do
        # $INSUNITS 1 = inches, so 25.4 mm per unit.
        payload = build(circle_dxf(radius: 2, insunits: 1, cx: 3, cy: 4))

        assert_equal [ "e", 76.2, -101.6, 50.8, 50.8 ], payload["shapes"].first["g"]
      end

      # A 90-degree ARC from 0 to 90 about the origin, r=10: it starts at (10, 0) and ends at
      # (0, 10) in MODEL space, so (10, 0) and (0, -10) once flipped.
      #
      # THE SWEEP FLAG IS 0, NOT 1. DXF sweeps counter-clockwise, and the Y-flip reverses
      # orientation — `Dxf.arc_svg` makes the identical conversion for the thumbnail and its own
      # comment says so. A `1` here draws the arc the long way round: still an arc, still touching
      # both endpoints, and the wrong 3/4 of the circle.
      test "an ARC becomes SVG A-command parameters with the flip applied" do
        payload = build(arc_dxf(cx: 0, cy: 0, r: 10, a0: 0, a1: 90))

        assert_equal [ "a", 10.0, 0.0, 0.0, -10.0, 10.0, 0, 0 ], payload["shapes"].first["g"]
      end

      test "an arc sweeping more than half a turn sets the large-arc flag" do
        payload = build(arc_dxf(cx: 0, cy: 0, r: 10, a0: 0, a1: 270))

        assert_equal 1, payload["shapes"].first["g"][6]
      end

      # THE CASE THAT WOULD DRAW NOTHING. `Dxf.arc_points` turns a0 == a1 into a 360-degree sweep
      # ("the whole circle, not a zero-length arc" — its own comment), whose start and end points
      # are IDENTICAL. SVG's rule for an arc whose endpoints coincide is to omit the segment
      # ENTIRELY, so encoding it as an arc exports an empty path: no error, nothing logged, a shape
      # that is simply absent from the file. The honest encoding is an ellipse.
      #
      # `Dxf.arc_svg` still has this bug for the THUMBNAIL and this test does not cover it — fixing
      # that needs a THUMBNAIL_REVISION bump and is recorded as out of scope in the design.
      test "a full-circle ARC is encoded as an ellipse, not a degenerate arc" do
        payload = build(arc_dxf(cx: 0, cy: 0, r: 7, a0: 45, a1: 45))

        assert_equal [ "e", 0.0, 0.0, 7.0, 7.0 ], payload["shapes"].first["g"]
      end

      # An LWPOLYLINE has no exact primitive to offer, and a payload key present on every shape
      # would be bytes for nothing on exactly the densest files.
      test "a polyline carries no descriptor" do
        dxf = "0\nSECTION\n2\nENTITIES\n0\nLWPOLYLINE\n8\nA\n90\n3\n10\n0\n20\n0\n10\n10\n20\n0\n" \
              "10\n10\n20\n10\n0\nENDSEC\n0\nEOF\n"

        assert_not build(dxf)["shapes"].first.key?("g")
      end
```

Then extend the private helpers at the bottom of the file — replace `circle_dxf` and add `arc_dxf`:

```ruby
      def circle_dxf(radius:, insunits:, cx: 0, cy: 0)
        header = insunits ? "0\nSECTION\n2\nHEADER\n9\n$INSUNITS\n70\n#{insunits}\n0\nENDSEC\n" : ""
        header + "0\nSECTION\n2\nENTITIES\n0\nCIRCLE\n8\nA\n10\n#{cx}\n20\n#{cy}\n40\n#{radius}\n" \
                 "0\nENDSEC\n0\nEOF\n"
      end

      def arc_dxf(cx:, cy:, r:, a0:, a1:)
        "0\nSECTION\n2\nENTITIES\n0\nARC\n8\nA\n10\n#{cx}\n20\n#{cy}\n40\n#{r}\n" \
        "50\n#{a0}\n51\n#{a1}\n0\nENDSEC\n0\nEOF\n"
      end
```

- [ ] **Step 2: Run to verify they fail**

```bash
LIBRARY_PATH=$(mktemp -d) bin/rails test test/services/maker/previews/dxf_geometry_test.rb
```

Expected: FAIL — `payload["shapes"].first["g"]` is nil.

- [ ] **Step 3: Implement**

In `app/services/maker/previews/dxf_geometry.rb`, change the block and add the converter:

```ruby
        Geometry.build(colors: ->(layers) { layers.to_h { |l| [ l, colors[l] ] } }) do |out|
          Dxf.each_geometry(pairs) do |layer, points, closed, curve, object_id|
            out.add(layer:, points: to_client_space(points, scale), closed:, object_id:,
                    curve: curve_to_client_space(curve, scale))
          end
        end
```

Add below `to_client_space`:

```ruby
      # A DXF curve descriptor -> the payload's wire form, in the client's space. The same scale
      # and the same Y-flip `to_client_space` applies to the points, for the same reason: the
      # traversal yields model space because the thumbnail wants the flip WITHOUT the scale.
      #
      # A FULL-CIRCLE ARC IS ENCODED AS AN ELLIPSE, AND THAT IS NOT A ROUNDING CONVENIENCE.
      # `Dxf.arc_points` turns a0 == a1 into a 360-degree sweep — its own comment: "the whole
      # circle, not a zero-length arc" — whose start and end points are IDENTICAL. SVG's rule for
      # an arc whose endpoints coincide is to omit the segment ENTIRELY, so an `A` command here
      # would export a path that draws nothing: no error, nothing logged, a shape simply missing
      # from a file somebody cuts. (`Dxf.arc_svg` still has that bug for the thumbnail; fixing it
      # needs a THUMBNAIL_REVISION bump and is out of scope — see the design.)
      def curve_to_client_space(curve, scale)
        return nil if curve.nil?

        cx = curve[:cx] * scale
        cy = -curve[:cy] * scale
        r = curve[:r] * scale
        return Geometry.ellipse_curve(cx, cy, r, r) if curve[:type] == :circle || curve[:sweep] >= 360

        x0, y0 = arc_endpoint(curve, curve[:a0], scale)
        x1, y1 = arc_endpoint(curve, curve[:a1], scale)
        # THE SWEEP FLAG IS 0 BECAUSE THE Y-FLIP REVERSES ORIENTATION: DXF sweeps counter-clockwise
        # from a0 to a1, which is clockwise once drawn. `Dxf.arc_svg` writes the same 0 for the
        # same reason. A 1 here draws the complementary arc — same endpoints, wrong side.
        Geometry.arc_curve(x0, y0, x1, y1, r, curve[:sweep] > 180 ? 1 : 0, 0)
      end

      # One end of an arc, in client space. Computed from the centre and the angle rather than
      # taken from the flattened points, so the endpoint is the arc's true one and not its first
      # sample — the same reason every reported number comes from full-resolution data.
      def arc_endpoint(curve, degrees, scale)
        t = degrees * Math::PI / 180
        [ (curve[:cx] + (curve[:r] * Math.cos(t))) * scale,
          -(curve[:cy] + (curve[:r] * Math.sin(t))) * scale ]
      end
```

- [ ] **Step 4: Run to verify pass**

```bash
LIBRARY_PATH=$(mktemp -d) bin/rails test test/services/maker/previews/dxf_geometry_test.rb
```

Expected: PASS.


> **Commit first, then mutate** — `git checkout --` restores to HEAD, so mutating before the
> commit destroys this task's own work. See the note at the top of this plan.

- [ ] **Step 5: Commit**

```bash
git add app/services/maker/previews/dxf_geometry.rb test/services/maker/previews/dxf_geometry_test.rb
git commit -m "DxfGeometry: carry CIRCLE and ARC descriptors, with the full-circle case encoded as an ellipse"
```

- [ ] **Step 6: Mutation-check the two traps**

1. Drop `|| curve[:sweep] >= 360`. "a full-circle ARC is encoded as an ellipse" must go **RED**.
2. Change the sweep flag from `0` to `1`. "an ARC becomes SVG A-command parameters" must go **RED**.

Restore both.

---

## Task 5: SvgGeometry carries the ellipse, gated on the transform

**Files:**
- Modify: `app/services/maker/previews/svg_geometry.rb`
- Test: `test/services/maker/previews/svg_geometry_test.rb`

`contours_for` returns `[[points, closed], ...]` across seven branches. **Do not change its return
shape** — only `circle` and `ellipse` can produce a descriptor, and both yield exactly one contour,
so `walk` computes it separately.

- [ ] **Step 1: Write the failing tests**

Add to `test/services/maker/previews/svg_geometry_test.rb`:

```ruby
      # ---- curve descriptors ----------------------------------------------------------------

      # Unlike LightBurn and DXF, this leg had no descriptor at all — `ellipse_contours` flattened
      # a <circle> to 64 points and nothing carried the exact primitive forward. An SVG source is
      # the case where losing it is most obviously a downgrade: the user's own file said <circle>.
      test "a circle carries an exact descriptor in millimetres" do
        payload = build(%(<svg xmlns="http://www.w3.org/2000/svg" width="100mm" height="100mm" ) +
                        %(viewBox="0 0 100 100"><circle cx="30" cy="40" r="10"/></svg>))

        assert_equal [ "e", 30.0, 40.0, 10.0, 10.0 ], payload["shapes"].first["g"]
      end

      # SVG IS ALREADY Y-DOWN, so unlike DXF there is no flip here — only the scale. A flip added
      # "for symmetry with DxfGeometry" turns every SVG upside down and still draws a plausible
      # picture; only a positional assertion catches it, which is what cy = 20 is doing.
      test "the descriptor is scaled by the viewBox, never flipped" do
        payload = build(%(<svg xmlns="http://www.w3.org/2000/svg" width="100mm" height="100mm" ) +
                        %(viewBox="0 0 200 200"><ellipse cx="100" cy="40" rx="50" ry="20"/></svg>))

        # 100 mm across 200 user units = 0.5 mm per unit.
        assert_equal [ "e", 50.0, 20.0, 25.0, 10.0 ], payload["shapes"].first["g"]
      end

      test "an enclosing translate moves the descriptor's centre" do
        payload = build(%(<svg xmlns="http://www.w3.org/2000/svg" width="100mm" height="100mm" ) +
                        %(viewBox="0 0 100 100"><g transform="translate(10,20)">) +
                        %(<circle cx="30" cy="40" r="5"/></g></svg>))

        assert_equal [ "e", 40.0, 60.0, 5.0, 5.0 ], payload["shapes"].first["g"]
      end

      # THE GATE. Under a rotation an SVG <ellipse> is not an SVG <ellipse> — it is a rotated one,
      # which needs a transform this descriptor cannot carry. Emitting an upright ellipse would
      # export geometry the file does not contain. Radii differ on purpose: a rotated CIRCLE is
      # still an upright circle and could not tell a working gate from a missing one.
      test "a rotated ellipse carries no descriptor and stays a polygon" do
        payload = build(%(<svg xmlns="http://www.w3.org/2000/svg" width="100mm" height="100mm" ) +
                        %(viewBox="0 0 100 100"><g transform="rotate(30)">) +
                        %(<ellipse cx="40" cy="40" rx="20" ry="10"/></g></svg>))

        assert_not payload["shapes"].first.key?("g")
        assert_operator payload["shapes"].first["p"].length, :>, 12, "still drawn as a polygon"
      end

      test "a path carries no descriptor" do
        payload = build(%(<svg xmlns="http://www.w3.org/2000/svg" width="100mm" height="100mm" ) +
                        %(viewBox="0 0 100 100"><path d="M0,0 L50,0 L50,50 Z"/></svg>))

        assert_not payload["shapes"].first.key?("g")
      end
```

- [ ] **Step 2: Run to verify they fail**

```bash
LIBRARY_PATH=$(mktemp -d) bin/rails test test/services/maker/previews/svg_geometry_test.rb
```

Expected: FAIL — `"g"` is nil.

- [ ] **Step 3: Yield the descriptor from `walk`**

In `app/services/maker/previews/svg_geometry.rb`, in `walk`, replace the emit block:

```ruby
          counter.succ!
          image = name == "image"
          curve = ellipse_curve_for(child, world)
          contours.each do |(points, closed)|
            block.call(here.paint, points.map { |(x, y)| apply(world, x, y) }, closed, image, curve)
          end
```

- [ ] **Step 4: Add the descriptor builder**

Add beside `ellipse_contours`:

```ruby
      # An axis-aligned <circle>/<ellipse> -> [cx, cy, rx, ry] in the SAME space as this element's
      # yielded points (post-transform, pre-viewBox-scale), or nil. `build` scales both together,
      # so the two can never disagree about which space they are in.
      #
      # GATED ON THE TRANSFORM, AND THAT REFUSAL IS THE POINT. Under a rotation or a skew an SVG
      # <ellipse> is no longer an SVG <ellipse>; emitting one would export geometry the file does
      # not contain — and a wrong SHAPE is not a wrong label, it is what a machine cuts. Same test
      # and same reason as `Lbrn2.axis_aligned?`.
      #
      # ONLY THESE TWO ELEMENTS CAN REACH IT. Everything else `contours_for` handles is either a
      # polygon already or a flattened path, and both may yield MORE THAN ONE contour, which a
      # single descriptor could not describe. A <rect> with rounded corners is the sharp case: it
      # is four arcs and four lines, not a primitive.
      def ellipse_curve_for(node, world)
        return nil unless %w[circle ellipse].include?(node.name)
        return nil if world[1].abs > 1e-9 || world[2].abs > 1e-9

        rx = num(node["r"]) || num(node["rx"])
        ry = num(node["r"]) || num(node["ry"])
        return nil if rx.nil? || ry.nil? || rx <= 0 || ry <= 0

        cx, cy = apply(world, num(node["cx"]) || 0.0, num(node["cy"]) || 0.0)
        [ cx, cy, rx * world[0].abs, ry * world[3].abs ]
      end
```

- [ ] **Step 5: Scale it in `build`**

Replace the `walk` call in `build`:

```ruby
          walk(root, IDENTITY, Inherited.new, tolerance, counter) do |paint, points, closed, image, curve|
            out.add(layer: paint, points: points.map { |(x, y)| [ x * sx, y * sy ] },
                    closed:, image:, object_id: counter.value,
                    # THE SAME sx/sy THE POINTS GET. A descriptor scaled differently from the
                    # contour it describes draws an ellipse that does not sit on its own outline —
                    # and the outline is what `b` was measured from, so the picture would disagree
                    # with the readout.
                    curve: curve && Geometry.ellipse_curve(curve[0] * sx, curve[1] * sy,
                                                           curve[2] * sx.abs, curve[3] * sy.abs))
          end
```

- [ ] **Step 6: Run to verify pass**

```bash
LIBRARY_PATH=$(mktemp -d) bin/rails test test/services/maker/previews/svg_geometry_test.rb
```

Expected: PASS.


> **Commit first, then mutate** — `git checkout --` restores to HEAD, so mutating before the
> commit destroys this task's own work. See the note at the top of this plan.

- [ ] **Step 7: Commit**

```bash
git add app/services/maker/previews/svg_geometry.rb test/services/maker/previews/svg_geometry_test.rb
git commit -m "SvgGeometry: an exact descriptor for circle and ellipse, refused under rotation"
```

- [ ] **Step 8: Mutation-check the gate and the flip**

1. Delete the `world[1]`/`world[2]` guard line. "a rotated ellipse carries no descriptor" → **RED**.
2. Negate `cy` in the `ellipse_curve` call (`curve[1] * -sy`). "the descriptor is scaled by the
   viewBox, never flipped" → **RED**.

Restore both.

---

## Task 6: Bump the shared revision

**Files:**
- Modify: `app/services/maker/previews/geometry.rb`
- Modify: `test/services/maker/previews/geometry_test.rb:82`

Three formats now emit different bytes for the same input, so every stored payload is from an older
build. `Geometry::SHARED_REVISION` is the one line that moves all of them.

- [ ] **Step 1: Update the absolute pins first (they should now fail)**

In `test/services/maker/previews/geometry_test.rb`, change:

```ruby
      GEOMETRY_REVISIONS = { "a.lbrn2" => 5, "a.lbrn" => 5, "a.mage" => 5, "a.dxf" => 2, "a.svg" => 2 }.freeze
```

- [ ] **Step 2: Run to verify it fails**

```bash
LIBRARY_PATH=$(mktemp -d) bin/rails test test/services/maker/previews/geometry_test.rb
```

Expected: FAIL — `Expected: 5, Actual: 4`.

- [ ] **Step 3: Bump the shared term**

In `app/services/maker/previews/geometry.rb`, change `SHARED_REVISION = 0` to:

```ruby
      #   1  shapes gained the optional `g` curve descriptor (Collector#add's `curve:`)
      SHARED_REVISION = 1
```

- [ ] **Step 4: Run to verify pass**

```bash
LIBRARY_PATH=$(mktemp -d) bin/rails test test/services/maker/previews/geometry_test.rb
```

Expected: PASS — including "each format's geometry revision is the shared term plus its own".

- [ ] **Step 5: Confirm `SCHEMA_VERSION` was NOT touched**

```bash
grep -n "SCHEMA_VERSION" app/services/maker/previews/geometry.rb app/javascript/controllers/measure_controller.js
```

Expected: both still read `1`. `"g"` is additive and optional — a client ignoring it draws what it
drew before. Bumping `v` would make `payload.v !== SCHEMA_VERSION` throw *"This preview needs a
newer version of the page"* for payloads the client reads perfectly.

- [ ] **Step 6: Run the whole preview suite**

```bash
LIBRARY_PATH=$(mktemp -d) bin/rails test test/services/maker/previews/
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add app/services/maker/previews/geometry.rb test/services/maker/previews/geometry_test.rb
git commit -m "Bump SHARED_REVISION: every format's payload gained the g descriptor"
```

---

## Task 7: `lib/shape_svg.js` — one element builder

**Files:**
- Create: `app/javascript/lib/shape_svg.js`
- Modify: `app/javascript/lib/print_sheet.js`
- Modify: `config/importmap.rb`

`el` and `unionBox` move here so there is one door; `print_sheet.js` **re-exports both**, which
keeps `measure_print_test.rb`'s existing `import("lib/print_sheet")` assertions working untouched.

- [ ] **Step 1: Create the module**

```javascript
// One geometry-payload shape -> one SVG element. THE ONE DEFINITION, shared by the Measure view,
// the print sheet and the SVG export.
//
// GEOMETRY ONLY. This module picks the ELEMENT TYPE and writes the attributes that describe the
// outline. It never writes a colour, a class, a stroke width or a dash: its three callers want
// three different presentations of the same shape — a layer-coloured line under a transparent hit
// twin, a black 0.2 mm print line, a layer-coloured export line — and each applies its own. A
// third copy of the element-picking is exactly what this exists to prevent; §14d records that
// shape as five port_writable? branches and §14b as four skip-list strings.
//
// `shape.g` IS A DRAWING HINT, NEVER A MEASUREMENT. The server computes `b` and `d` from
// full-resolution points and sends `g` only where the FILE supplied an exact primitive — a
// LightBurn <Ellipse>, a DXF CIRCLE/ARC, an SVG <circle>/<ellipse> under an axis-aligned
// transform. NOTHING HERE INFERS ONE FROM THE POINTS, so a designed 16-gon stays a 16-gon even
// though the server's circularity test would call it round for the ⌀ label. A payload with no `g`
// on any shape draws exactly what this drew before `g` existed.
export const SVG_NS = "http://www.w3.org/2000/svg"

// THE ONE DOOR EVERY ELEMENT IN THIS FAMILY OF MODULES IS BUILT THROUGH. Moved here from
// print_sheet.js, which now imports and re-exports it — one door, and measure_print_test.rb's
// existing pin of the guard below keeps working through that re-export.
export function el(doc, tag, attrs, text) {
  // A STRING IN THE `attrs` SLOT DOES NOT THROW, WHICH IS THE WHOLE REASON THIS EXISTS.
  // `el(doc, "text", "Sheet 1,1 of 2×1")` — one dropped `{}` away from the five <text> sites in
  // print_sheet's `furniture` — was expected to raise InvalidCharacterError, since an attribute
  // name cannot begin with a digit. Probed in Chrome: it does not. `Object.entries` walks the
  // string's own indices and `setAttribute` accepts "0" as a name, so the result is
  // `<text 0="S" 1="h" 2="e" ...>` — sixteen junk attributes, no text content, an empty <text>
  // that renders nothing on a page that is otherwise perfectly formed, with nothing thrown and
  // nothing logged. Measured verbatim in measure_print_test.rb, which pins this.
  if (typeof attrs === "string") {
    throw new Error("el(doc, tag, attrs, text): the third argument is the attribute map, not " +
                    "the text — pass el(doc, tag, {}, text).")
  }
  const node = doc.createElementNS(SVG_NS, tag)
  for (const [ key, value ] of Object.entries(attrs)) {
    // An undefined value writes the literal string "undefined" (a null writes "null"). Sheet
    // furniture is full of conditional attributes, so skip here rather than making every call
    // site remember.
    if (value != null) node.setAttribute(key, value)
  }
  // THE TEXT DOOR EXISTS SO THAT `textContent` IS THE ONLY SPELLING. The print header carries a
  // library filename — user-controlled, and legitimately able to contain `<` on a NAS-scanned
  // share — so building it as markup is an injection into a same-origin iframe. Six call sites
  // each remembering that is six chances to forget; one door is none.
  if (text != null) node.textContent = text
  return node
}

// The bounding box of a set of shapes, from `b` — the server's FULL-RESOLUTION bbox, never the
// thinned drawing points. One definition for all three callers; it was written out twice (here
// and as measure_controller's `unionOf`) before the exporter needed a third.
export function unionBox(shapes) {
  return [
    Math.min(...shapes.map((s) => s.b[0])), Math.min(...shapes.map((s) => s.b[1])),
    Math.max(...shapes.map((s) => s.b[2])), Math.max(...shapes.map((s) => s.b[3])),
  ]
}

// A CIRCLE GETS <circle>, NOT AN <ellipse> WITH EQUAL RADII. Both are valid SVG and both draw the
// same picture, but the export's stated destinations are a vector editor and a CAD sketch import,
// where <circle> is the unambiguous primitive and an ellipse may arrive as a spline.
export function shapeElement(doc, shape) {
  const g = shape.g
  if (g && g[0] === "e") {
    const [ , cx, cy, rx, ry ] = g
    return rx === ry ? el(doc, "circle", { cx, cy, r: rx })
                     : el(doc, "ellipse", { cx, cy, rx, ry })
  }
  if (g && g[0] === "a") {
    const [ , x0, y0, x1, y1, r, large, sweep ] = g
    return el(doc, "path", { d: `M ${x0} ${y0} A ${r} ${r} 0 ${large} ${sweep} ${x1} ${y1}` })
  }
  // NO DESCRIPTOR -> THE THINNED POINTS, which is every path, polygon, polyline, rect and bitmap
  // and every curve the file did not describe as a primitive.
  return el(doc, shape.k ? "polygon" : "polyline",
            { points: shape.p.map(([ x, y ]) => `${x},${y}`).join(" ") })
}
```

- [ ] **Step 2: Rewire `print_sheet.js`**

Replace its local `SVG_NS` constant, its `unionBox` function and its whole `el` function with an
import + re-export at the top of the file (keep the module's header comment):

```javascript
import { SVG_NS, el, unionBox, shapeElement } from "lib/shape_svg"

// RE-EXPORTED RATHER THAN REDEFINED. `el` and `unionBox` moved to lib/shape_svg so the exporter
// could share them without importing the print module; re-exporting keeps every existing importer
// — measure_print_test.rb's pin of el's mis-call guard included — working unchanged, and keeps
// one definition rather than two spellings of the same function.
export { SVG_NS, el, unionBox }
```

Then replace `contourNode`:

```javascript
// BUILT FRESH FROM THE SHAPE, NEVER CLONED FROM THE ON-SCREEN NODE. A clone drags the transparent
// fat hit-twin (.measure-contour--hit, an 8px stroke), the hover/selected/marked classes and the
// layer colour onto paper.
//
// BLACK, not the layer colour: a mono printer turns a layer palette into indistinguishable greys,
// and this sheet exists to be measured and cut against. 0.2 mm is a line you can cut to.
//
// THE ELEMENT ITSELF COMES FROM lib/shape_svg, which is what gives the sheet real curves. With
// Lbrn2::ELLIPSE_SAMPLES at 32, a ⌀50 mm circle's sampled chords sit 0.12 mm INSIDE the true
// curve — the RDP thinning is bounded at 0.01 mm but cannot recover error the sampler already
// introduced. That is visible on paper, on the one sheet whose job is to be measured against.
function contourNode(doc, shape) {
  const node = shapeElement(doc, shape)
  node.setAttribute("fill", "none")
  node.setAttribute("stroke", "#000")
  node.setAttribute("stroke-width", 0.2)
  // A bitmap's base64 is deliberately absent from the payload; it is the RECTANGLE a photo
  // occupies that matters for fit, and it draws dashed here exactly as it does on screen.
  if (shape.i) node.setAttribute("stroke-dasharray", "4 3")
  return node
}
```

- [ ] **Step 3: Pin both modules**

In `config/importmap.rb`, beside the existing `pin "lib/print_sheet"`:

```ruby
pin "lib/shape_svg", to: "lib/shape_svg.js"
pin "lib/export_svg", to: "lib/export_svg.js"
```

- [ ] **Step 4: Run the print system test**

```bash
LIBRARY_PATH=$(mktemp -d) bin/rails test test/system/measure_print_test.rb
```

**Expect FEW or NO failures, and know why before you start changing things.** Of this file's four
fixtures, only `sample.lbrn2` (`OPEN`) contains a `<Shape Type="Ellipse">`:

| fixture | shape types | affected? |
|---|---|---|
| `nested-plate.lbrn2` (`NESTED`) | `Path` + `Rect` | no — the ⌀10 hole is a BEZIER PATH, so it has no descriptor and still prints as a `<polygon>` |
| `bezier-circle.lbrn2` (`APART`) | `Path` + `Rect` | no — same, its circle is four cubic segments |
| `text-backup-path.lbrn2` (`TEXT`) | `Path` ×2 + `Rect` + `Text` | no |
| `sample.lbrn2` (`OPEN`) | `Ellipse` + `Line` + `Rect` | **yes** — the ⌀20 ellipse now prints as `<circle cx="50" cy="-30" r="10">` |

So only an assertion that reads `points=` on `sample.lbrn2`'s ellipse needs updating. Change it to
the new element and its attributes, keeping the assertion **literal** — assert the attribute a
printer will see, never a round-trip through our own reader. Re-run to green.

- [ ] **Step 5: Add a print assertion that can hold the guard**

Updating whatever happens to fail is not enough: if no existing assertion touches `sample.lbrn2`'s
ellipse, Step 6's mutation is **green** and the change to the sheet is untested. Add this to
`test/system/measure_print_test.rb` beside the other `in_print_sheet` tests:

```ruby
  # THE SHEET DRAWS THE PRIMITIVE THE FILE DESCRIBED, and this is a correctness fix rather than a
  # cosmetic one. With Lbrn2::ELLIPSE_SAMPLES at 32, a ⌀50 mm circle's sampled chords sit 0.12 mm
  # INSIDE the true curve — the RDP thinning is bounded at 0.01 mm but cannot recover error the
  # SAMPLER already introduced, and 0.12 mm is measurable on the one sheet whose whole job is to be
  # measured and cut against.
  #
  # SYNTHETIC, not a fixture: the descriptor's numbers are chosen so the assertion is a literal,
  # the same reason the tiling tests above use synthetic shapes.
  test "a shape carrying a curve descriptor prints as a real circle" do
    markup = in_print_sheet(<<~JS)
      (() => {
        const shapes = [{ b: [0, 0, 50, 50], p: [[0, 0], [50, 50]], k: 1, c: 0,
                          g: ["e", 25, 25, 25, 25] }]
        const { pages } = m.buildSheets(shapes, { name: "Letter", w: 215.9, h: 279.4 })
        return m.renderSheet(document, pages[0],
          { name: "t.lbrn2", date: "2026-09-02", sizeLabel: () => null }).outerHTML
      })()
    JS

    assert_includes markup, '<circle cx="25" cy="25" r="25"'
    assert_includes markup, 'stroke-width="0.2"', "still the print sheet's own black hairline"
    assert_not_includes markup, "<polygon"
  end
```

- [ ] **Step 6: Mutation-check the shared builder**

In `shape_svg.js`, make `shapeElement` ignore `shape.g` (return the polygon branch
unconditionally). Run `test/system/measure_print_test.rb` — the assertion added in Step 5 must go
**RED**. Restore.

- [ ] **Step 7: Commit**

```bash
git add app/javascript/lib/shape_svg.js app/javascript/lib/print_sheet.js config/importmap.rb test/system/measure_print_test.rb
git commit -m "One element builder for the measure view, the print sheet and the exporter"
```

---

## Task 8: The Measure view draws through the shared builder

**Files:**
- Modify: `app/javascript/controllers/measure_controller.js:292-324` and `:532-538`
- Test: `test/system/lbrn_measure_test.rb`

- [ ] **Step 1: Add the one fixture that has an `Ellipse`**

`lbrn_measure_test.rb`'s two fixtures are `bezier-circle.lbrn2` and `nested-plate.lbrn2`, and
**neither contains a `<Shape Type="Ellipse">`** — both of their circles are bezier `Path`s, which by
design carry no descriptor. `sample.lbrn2` is the fixture that does (`Ellipse Rx="10" Ry="10"` at
`XForm 1 0 0 1 50 30`, so a ⌀20 circle centred at 50, −30 after the Y-flip), and
`measure_print_test.rb` already uses it.

Add the constant beside the existing two, extend the setup's fixture list, and index it:

```ruby
  # THE ONLY FIXTURE HERE WITH A <Shape Type="Ellipse">, which is the only shape kind that reaches
  # the curve-descriptor path on this leg — bezier-circle's and nested-plate's circles are Paths of
  # cubic segments and stay polygons by design. Rx = Ry = 10 at XForm 1 0 0 1 50 30, so it draws as
  # <circle cx="50" cy="-30" r="10"> once the Y-flip is applied.
  SAMPLE = "sample.lbrn2".freeze
```

```ruby
    [ FIXTURE, NESTED, SAMPLE ].each do |f|
```

```ruby
    @sample_id = @user.nodes.find_by!(storage_path: SAMPLE).node_id
    render_geometry!(@sample_id, SAMPLE)
```

- [ ] **Step 2: Write the failing tests**

```ruby
  # THE VIEW AND THE THUMBNAIL BESIDE IT NOW DRAW THE SAME PRIMITIVE. Until the payload carried
  # `g`, this drew a 32-gon while Lbrn2.to_svg drew a real <ellipse> from the very same descriptor
  # the traversal handed both of them.
  test "an Ellipse draws as a real circle rather than a polygon" do
    visit file_path(@sample_id)
    click_on "Measure"
    assert_selector ".measure-view--ready", wait: 10

    assert_selector ".measure-stage circle.measure-contour"
    assert_equal "10", find(".measure-stage circle.measure-contour")["r"]
  end

  # THE HIGHLIGHT MECHANISM MUST SURVIVE THE ELEMENT CHANGE. The layer colour is a PRESENTATION
  # attribute so that .measure-contour--selected can outrank it, and `.measure-contour { fill:
  # transparent }` is what makes a closed contour's interior clickable — a <circle> gets both from
  # the same code path a <polygon> did, but only a driven click proves it. Reading the stroke
  # ATTRIBUTE back would report what we wrote even when a rule outranks it, so assert the COMPUTED
  # style (#d40 = rgb(221, 68, 0)).
  test "a curve contour is clickable and still recolours on selection" do
    visit file_path(@sample_id)
    click_on "Measure"
    assert_selector ".measure-view--ready", wait: 10

    find(".measure-stage circle.measure-contour").click
    assert_text "⌀20 mm"
    assert_equal "rgb(221, 68, 0)", page.evaluate_script(<<~JS)
      getComputedStyle(document.querySelector(".measure-contour--selected")).stroke
    JS
  end
```

- [ ] **Step 3: Run to verify it fails**

```bash
LIBRARY_PATH=$(mktemp -d) bin/rails test test/system/lbrn_measure_test.rb
```

Expected: FAIL — no `circle`/`ellipse` in the stage.

- [ ] **Step 4: Delegate `contourNode`**

At the top of `measure_controller.js`, extend the import:

```javascript
import { PAPERS, printSheets } from "lib/print_sheet"
import { shapeElement, unionBox } from "lib/shape_svg"
```

Replace `contourNode`:

```javascript
  // A bitmap draws as a dashed placeholder: its base64 is excluded from the payload on purpose
  // (one real file is 1.45 MB as SVG and 0.1 KB as geometry), and a measuring view has no use
  // for the photo — only for the rectangle it occupies.
  //
  // THE ELEMENT COMES FROM lib/shape_svg, shared with the print sheet and the exporter — so a
  // LightBurn <Ellipse>, a DXF CIRCLE/ARC and an SVG <circle> draw as the primitive the FILE
  // described, the same one the thumbnail beside this view has always drawn.
  contourNode(shape) {
    const node = shapeElement(document, shape)
    node.setAttribute("class", shape.i ? "measure-bitmap" : (shape.k ? "measure-contour" : "measure-contour measure-contour--open"))
    // LightBurn's own layer colour, sent by the server so the palette has ONE definition (see
    // LbrnGeometry#layer_colors).
    //
    // A PRESENTATION ATTRIBUTE, NOT node.style — and the difference is the whole highlight
    // mechanism. An inline style beats a stylesheet, so setting style.stroke here would make
    // .measure-contour--hover and --selected unable to recolour anything: clicking a contour would
    // change its width and nothing else. A presentation attribute sits BELOW every CSS rule in
    // the cascade, so the layer colour shows at rest and the highlight classes still win. For the
    // same reason .measure-contour must not declare a stroke of its own — a class rule would beat
    // this attribute and every layer would draw identically.
    if (!shape.i) node.setAttribute("stroke", this.colors[shape.c] || "#000000")
    node.__shape = shape
    if (shape.k || shape.i) return node

    // An open contour has no interior to click and a hairline stroke to aim at. Group it with a
    // transparent fat twin so the hit area is finger-sized while the drawn line stays 1px.
    //
    // THE TWIN IS ALWAYS A POLYLINE FROM shape.p, EVEN WHEN THE DRAWN NODE IS AN ARC. It is an
    // invisible 8px target, so approximating the arc costs nothing visible and keeps the twin one
    // element — and it must be built from the points here rather than reusing a `points` string,
    // because the visible node no longer necessarily has one.
    const group = document.createElementNS(SVG_NS, "g")
    const hit = document.createElementNS(SVG_NS, "polyline")
    hit.setAttribute("points", shape.p.map(([ x, y ]) => `${x},${y}`).join(" "))
    hit.setAttribute("class", "measure-contour--hit")
    hit.__shape = shape
    hit.__visible = node // so hover/selection colours the drawn line, not the invisible twin
    group.appendChild(hit)
    group.appendChild(node)
    // So draw() can resolve a group to the line it should style, the same way styleNode() does.
    group.__visible = node
    return group
  }
```

- [ ] **Step 5: Drop the duplicated `unionOf`**

Delete the `unionOf(shapes) { ... }` method and replace its three call sites
(`pick`, `contourLabel`, `objectLabel`, `selectionStatus`) with `unionBox(...)`:

```bash
grep -n "unionOf" app/javascript/controllers/measure_controller.js
```

Replace each `this.unionOf(` with `unionBox(`. Add a note where the method was:

```javascript
  // `unionOf` LIVED HERE AND WAS BYTE-IDENTICAL TO print_sheet's `unionBox`. The exporter would
  // have been a third copy, so the one definition moved to lib/shape_svg and both import it.
```

Then delete this controller's local `SVG_NS` constant (line 26) and take it from the same import,
so the namespace string is not spelled twice either:

```javascript
import { SVG_NS, shapeElement, unionBox } from "lib/shape_svg"
```

`draw()` and the hit twin are its two readers and neither changes.

- [ ] **Step 6: Run to verify pass**

```bash
LIBRARY_PATH=$(mktemp -d) bin/rails test test/system/lbrn_measure_test.rb test/system/measure_formats_test.rb
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add app/javascript/controllers/measure_controller.js test/system/lbrn_measure_test.rb
git commit -m "Measure view draws the primitive the file described, through the shared builder"
```

---

## Task 9: `lib/export_svg.js`

**Files:**
- Create: `app/javascript/lib/export_svg.js`
- Create: `test/system/measure_export_test.rb`

- [ ] **Step 1: Write the failing tests**

```ruby
require "application_system_test_case"

# Exporting selected Measure shapes as a standalone SVG.
#
# TWO TIERS IN ONE FILE, the split measure_print_test.rb established. lib/export_svg.js is pure and
# is exercised directly with synthetic shapes, because an export assertion wants inputs whose
# numbers are chosen rather than whatever a fixture happens to produce. The end-to-end test below
# drives a real click against a real payload, because the builder being right about synthetic input
# proves nothing about whether the selection ever reaches it.
#
# WHY PURE CODE EARNS A PLACE IN THIS TIER. test/system/README.md's rule is that a behaviour
# qualifies only if it is observable ONLY in a browser. This repo has NO JS test runner, so a
# browser is the only executor there is for lib/export_svg.js — the same precedent
# measure_print_test.rb and plan_export_test.rb set.
#
# ASSERT THE WIRE FORMAT, NEVER A ROUND-TRIP THROUGH OUR OWN READER. §14e: FakeS3 decoded
# copy_source with the exact inverse of the encoder, so 79/80 tests were green over silent
# permanent data loss. Parsing our own SVG with our own parser would be that shape again.
# SHARE BACKEND, ASSIGNED DIRECTLY, exactly as lbrn_measure_test.rb and measure_print_test.rb do it
# and for the same reason: the geometry job has to read REAL BYTES back out of the port. The
# FileLayer.reset! in teardown is load-bearing — a direct assignment does not set
# @file_layer_backend_pinned, so test_helper's teardown will not clean up after it and a Share
# adapter pointing at a deleted tmpdir would leak into the next test in this forked worker.
class MeasureExportTest < ApplicationSystemTestCase
  # A ⌀20 Ellipse (Rx = Ry = 10 at XForm 1 0 0 1 50 30, so centred 50, -30 after the Y-flip) beside
  # a 40 x 20 Rect and an open Line. THE ONLY FIXTURE IN THE REPO WITH A <Shape Type="Ellipse"> that
  # this file needs — nested-plate's and bezier-circle's circles are bezier Paths and carry no
  # descriptor at all, so neither can exercise the export's whole point.
  SAMPLE = "sample.lbrn2".freeze

  setup do
    @root = Pathname.new(Dir.mktmpdir("measure-export"))
    # The fixture lands BEFORE the first page render on purpose: FileLayer::Share reads an EMPTY
    # root as an unmounted mount point, and sign_in_as ends on /files, which renders through the
    # port.
    File.binwrite(@root.join(SAMPLE), File.binread(Rails.root.join("test/fixtures/files", SAMPLE)))
    FileLayer.current = FileLayer::Share.new(root: @root.to_s)

    @user = sign_in_as("measure-export@example.com")
    Library::Scanner.call(@user, root: @root.to_s, max_delete_pct: 100)
    @sample_id = @user.nodes.find_by!(storage_path: SAMPLE).node_id
    render_geometry!(@sample_id, SAMPLE)
  end

  teardown { FileLayer.reset! }

  # ---- lib/export_svg.js: the document ---------------------------------------------------

  # ONE USER UNIT IS ONE MILLIMETRE, and the width/height + viewBox pair is the entire scale
  # mechanism — no transform, no dpi constant. A px width over the same viewBox draws an
  # identical-looking file that is silently the wrong size in an application that will cut it.
  test "the document carries the selection's own size in millimetres" do
    head = in_export_svg(<<~JS)
      m.exportSvg([{ b: [0, 0, 60, 40], p: [[0, 0], [60, 0], [60, 40], [0, 40]], k: 1, c: 0 }], {})
       .match(/<svg[^>]*>/)[0]
    JS

    assert_includes head, 'width="60mm"'
    assert_includes head, 'height="40mm"'
    assert_includes head, 'viewBox="0 0 60 40"'
  end

  # NORMALIZED TO THE ORIGIN, so a part pulled out of a big sheet imports at 0,0 rather than
  # somewhere out in an empty canvas. ONE TRANSLATE FOR THE WHOLE SET, so several selected parts
  # keep their relative positions.
  test "the whole selection is translated by one transform" do
    body = in_export_svg(<<~JS)
      m.exportSvg([{ b: [100, 50, 110, 60], p: [[100, 50], [110, 60]], k: 0, c: 0 },
                   { b: [120, 50, 130, 60], p: [[120, 50], [130, 60]], k: 0, c: 0 }], {})
    JS

    assert_includes body, 'transform="translate(-100 -50)"'
    assert_equal 1, body.scan("<g ").length, "one group, not one per shape"
    assert_includes body, 'points="100,50 110,60"', "coordinates are untouched; the group moves them"
  end

  # THE LAYER COLOUR, not print's black: a mono printer flattens a palette to greys, which is why
  # the sheet chose black — an argument that does not transfer to a file, where LightBurn maps
  # stroke colour back to layers on import.
  test "each outline carries its layer colour and no fill" do
    body = in_export_svg(<<~JS)
      m.exportSvg([{ b: [0, 0, 10, 10], p: [[0, 0], [10, 10]], k: 0, c: 3 }], { colors: { 3: "#ff0000" } })
    JS

    assert_includes body, 'stroke="#ff0000"'
    assert_includes body, 'fill="none"'
  end

  test "a layer with no colour falls back to black" do
    body = in_export_svg(<<~JS)
      m.exportSvg([{ b: [0, 0, 10, 10], p: [[0, 0], [10, 10]], k: 0, c: 9 }], { colors: {} })
    JS

    assert_includes body, 'stroke="#000000"'
  end

  # THE WHOLE POINT OF THE `g` DESCRIPTOR, on the surface it exists for: a circle exports as a
  # circle, not as 49 line segments a CAD app cannot constrain.
  test "a shape the file described as round exports as a circle" do
    body = in_export_svg(<<~JS)
      m.exportSvg([{ b: [0, 0, 20, 20], p: [[0, 0], [20, 20]], k: 1, c: 0, g: ["e", 10, 10, 10, 10] }], {})
    JS

    assert_includes body, "<circle "
    assert_includes body, 'r="10"'
    assert_not_includes body, "<polygon"
  end

  test "an arc exports as an A-command path" do
    body = in_export_svg(<<~JS)
      m.exportSvg([{ b: [0, 0, 10, 10], p: [[10, 0], [0, 10]], k: 0, c: 0,
                     g: ["a", 10, 0, 0, 10, 10, 0, 0] }], {})
    JS

    assert_includes body, 'd="M 10 0 A 10 10 0 0 0 0 10"'
  end

  # A photo's base64 is deliberately absent from the payload, but the RECTANGLE it occupies is
  # real information about where an engrave sits. Selected means exported — a shape the user
  # picked must never vanish silently from the file.
  test "a bitmap exports as the dashed rectangle it shows on screen" do
    body = in_export_svg(<<~JS)
      m.exportSvg([{ b: [0, 0, 10, 10], p: [[0, 0], [10, 0], [10, 10], [0, 10]], k: 1, i: 1, c: 0 }], {})
    JS

    assert_includes body, 'stroke-dasharray="4 3"'
  end

  test "exporting nothing refuses rather than writing an empty document" do
    err = in_export_svg(<<~JS)
      (() => { try { m.exportSvg([], {}); return "NO THROW" } catch (e) { return e.message } })()
    JS

    assert_match(/nothing selected/i, err)
  end

  private

    # Import the exporter and evaluate `body` against it (the module object is bound to `m`). The
    # page must already be an app page so the importmap and same-origin both hold — the shapes
    # below are synthetic, so WHICH page does not matter, only that one is loaded.
    def in_export_svg(body)
      visit file_path(@sample_id) unless page.current_path == file_path(@sample_id)
      result = page.evaluate_async_script(<<~JS)
        const done = arguments[arguments.length - 1];
        import("lib/export_svg")
          .then((m) => done(#{body}))
          .catch((e) => done("ERROR: " + (e && e.message ? e.message : String(e))));
      JS
      raise result if result.is_a?(String) && result.start_with?("ERROR:")
      result
    end

    # The geometry preview, rendered through the REAL renderer against the REAL fixture bytes, in
    # this process rather than by the job runner. A system test cannot wait for the job: ActiveJob's
    # test adapter never runs what it queues, and `perform_enqueued_jobs`' block form only inlines
    # jobs enqueued DURING the block — the geometry job is enqueued by the browser's own first poll,
    # inside the server thread. `perform_now` sidesteps the adapter and is deterministic, while
    # still being the real pipeline. (Copied from measure_print_test.rb, which copied it from
    # lbrn_measure_test.rb — three system tests need the same bootstrap and none can share a
    # superclass with the rest of the suite.)
    def render_geometry!(node_id, filename)
      token = FileLayer.current.stat(@user, node_id: node_id).content_token
      preview = Maker::Previews::Enqueue.call(user: @user, node_id: node_id, name: filename,
                                              version_id: token, kind: "geometry")
      Maker::GeneratePreviewJob.perform_now(preview.id, filename: filename)
    end
end
```

- [ ] **Step 2: Run to verify they fail**

```bash
LIBRARY_PATH=$(mktemp -d) bin/rails test test/system/measure_export_test.rb
```

Expected: FAIL — the module does not exist.

- [ ] **Step 3: Create the exporter**

```javascript
// The Measure view's selected shapes -> one standalone SVG document, as a string.
//
// PURE. It builds a DETACHED document and serialises it: nothing here touches the page, starts a
// download, or knows what a Stimulus controller is. measure_controller.js owns that half — the
// same split print_sheet.js draws between renderSheet (pure) and buildPrintFrame (not).
//
// ONE USER UNIT IS ONE MILLIMETRE, and the width/height + viewBox pair is the ENTIRE scale
// mechanism. There is no transform and no dpi constant. Write the width in px, or let the viewBox
// span anything other than the selection's own millimetres, and the file looks identical while
// every part in it is the wrong size — in an application that will happily cut it. The print sheet
// and the boxes bundle's library SVG use the same mechanism for the same reason.
//
// NORMALIZED TO THE ORIGIN rather than keeping the file's coordinates: a part pulled out of a
// 1200 mm sheet otherwise imports as a speck in an empty canvas. The canvas size IS the part size,
// which is what makes the document tell you something.
import { SVG_NS, el, unionBox, shapeElement } from "lib/shape_svg"

// Hairline. Stroke width is ignored outright on CAD import and is a display choice everywhere
// else; 0.1 mm is thin enough not to obscure a small feature at 1:1. NOT print's 0.2 mm — that
// number is "a line you can cut to" on paper, which is not this file's job.
const STROKE_WIDTH = 0.1

// Match the payload's own PRECISION (Geometry::PRECISION = 2). The inputs are already rounded
// there; this keeps the width/height and the translate from picking up float dust when they are
// derived by subtraction.
const round = (v) => Math.round(v * 100) / 100

export function exportSvg(shapes, { colors = {} } = {}) {
  // REFUSES RATHER THAN WRITING AN EMPTY DOCUMENT. A 0 x 0 mm SVG opens in every viewer and shows
  // nothing, which reads as "the export is broken" rather than "you selected nothing" — and the
  // caller has a readout to put a message in. printSheets' own "Nothing to print." is the same
  // choice.
  if (!shapes || !shapes.length) throw new Error("Nothing selected to export.")

  const box = unionBox(shapes)
  // The root is created IN the SVG namespace, so XMLSerializer writes the xmlns declaration
  // itself. Do not also setAttribute("xmlns", ...) — that adds a second, null-namespace attribute
  // of the same name and the serialised document carries `xmlns` twice, which is not well-formed
  // XML and which some importers reject outright.
  const doc = document.implementation.createDocument(SVG_NS, "svg", null)
  const svg = doc.documentElement
  svg.setAttribute("width", `${round(box[2] - box[0])}mm`)
  svg.setAttribute("height", `${round(box[3] - box[1])}mm`)
  svg.setAttribute("viewBox", `0 0 ${round(box[2] - box[0])} ${round(box[3] - box[1])}`)

  // ONE TRANSLATE FOR THE WHOLE SET, not one per shape: several selected parts keep their relative
  // positions because they are all moved by the same amount. renderSheet puts its page translate
  // on one group for the identical reason.
  const group = el(doc, "g", { transform: `translate(${round(-box[0])} ${round(-box[1])})` })
  for (const shape of shapes) {
    const node = shapeElement(doc, shape)
    node.setAttribute("fill", "none")
    // THE LAYER COLOUR, sent by the server so the palette has one definition. Print chose black
    // because a mono printer turns a palette into indistinguishable greys; that argument does not
    // transfer to a file, and LightBurn maps stroke colour back to layers on import.
    node.setAttribute("stroke", colors[shape.c] || "#000000")
    node.setAttribute("stroke-width", STROKE_WIDTH)
    // A photo's base64 is deliberately absent from the payload, but the RECTANGLE it occupies is
    // real information. Selected means exported: a shape the user picked must not vanish silently.
    if (shape.i) node.setAttribute("stroke-dasharray", "4 3")
    group.appendChild(node)
  }
  svg.appendChild(group)

  return `<?xml version="1.0" encoding="UTF-8"?>\n${new XMLSerializer().serializeToString(doc)}`
}
```

- [ ] **Step 4: Run to verify pass**

```bash
LIBRARY_PATH=$(mktemp -d) bin/rails test test/system/measure_export_test.rb
```

Expected: PASS.


> **Commit first, then mutate** — `git checkout --` restores to HEAD, so mutating before the
> commit destroys this task's own work. See the note at the top of this plan.

- [ ] **Step 5: Commit**

```bash
git add app/javascript/lib/export_svg.js test/system/measure_export_test.rb
git commit -m "lib/export_svg: selected shapes to a standalone to-scale SVG document"
```

- [ ] **Step 6: Mutation-check the scale mechanism**

Change `width` to `${round(box[2] - box[0])}px`. "the document carries the selection's own size in
millimetres" must go **RED**. Restore. Then change the translate to `translate(0 0)` — "the whole
selection is translated by one transform" must go **RED**. Restore.

---

## Task 10: One definition of the target set

**Files:**
- Modify: `app/javascript/controllers/measure_controller.js`

`print()` and `refreshPrintBar()` each spell the three arms today, under a comment saying they
"must not drift." A third consumer makes that untenable.

- [ ] **Step 1: Extract the two readers**

Add to `measure_controller.js`, immediately above `refreshPrintBar`:

```javascript
  // THE THREE ARMS, IN PRECEDENCE ORDER, WITH ONE DEFINITION. They were written out twice — once
  // in print() and once in refreshPrintBar() — under a comment saying the two "must not drift",
  // which is prose where a mechanism belongs. The exporter would have been a third copy, and three
  // copies of a precedence rule is §14d's five port_writable? branches in miniature.
  //
  //   marked set        -> the set          "Print 3 parts"
  //   else selected     -> the contour under the measurement, so measuring a part is enough to
  //                        target it and Select parts is not a toll gate
  //   else              -> the whole file
  targetShapes() {
    return this.marked.size ? [ ...this.marked ]
      : this.selected ? [ this.selected.__shape ]
      : this.allShapes
  }

  // WHAT THE BUTTONS CALL THAT SET. Same three arms, same order, derived from the same state, so a
  // label can no longer describe one target while an action performs another.
  targetNoun() {
    const n = this.marked.size
    return n ? `${n} part${n === 1 ? "" : "s"}` : this.selected ? "selected" : "all"
  }
```

- [ ] **Step 2: Point `print()` at it**

Replace the three-arm expression in `print()` with:

```javascript
    const shapes = this.targetShapes()
```

Keep the existing guard and its comment below it unchanged:

```javascript
    // NOT DEAD, BUT ONLY REACHABLE BY DRIVING THIS METHOD DIRECTLY. `allShapes` is undefined
    // between connect() and the first successful draw(), and in that window the button is
    // display:none (`.measure-actions` without --ready), so no click can get here. What the guard
    // buys is the difference between doing nothing and putting a raw TypeError from buildSheets
    // into the readout as the answer to a button press. Pinned by a test that calls print()
    // directly, because nothing else can.
    if (!shapes || !shapes.length) return
```

- [ ] **Step 3: Point `refreshPrintBar()` at it**

```javascript
  refreshPrintBar() {
    this.printButtonTarget.textContent = `Print ${this.targetNoun()}`
  }
```

- [ ] **Step 4: Run the print tests**

```bash
LIBRARY_PATH=$(mktemp -d) bin/rails test test/system/measure_print_test.rb
```

Expected: PASS — the labels are unchanged ("Print all", "Print selected", "Print 3 parts").

- [ ] **Step 5: Commit**

```bash
git add app/javascript/controllers/measure_controller.js
git commit -m "One definition of the Measure target set, for print and export alike"
```

---

## Task 11: The SVG button

**Files:**
- Modify: `app/views/files/_measure.html.erb`
- Modify: `app/javascript/controllers/measure_controller.js`
- Test: `test/system/measure_export_test.rb`

- [ ] **Step 1: Write the failing end-to-end test**

Add to `test/system/measure_export_test.rb`, before the `private` section:

```ruby
  # ---- the button ------------------------------------------------------------------------

  # DRIVES THE REAL CLICK, because the builder being right about synthetic input proves nothing
  # about whether the SELECTION ever reaches it. The anchor's click is stubbed rather than allowed
  # to download: headless Chrome here has no configured download directory, and capturing the Blob
  # is both hermetic and a stronger assertion than a file appearing somewhere on disk.
  #
  # THE NUMBERS COME FROM sample.lbrn2 AND ARE ALL LITERALS. Its Ellipse is Rx = Ry = 10 at
  # XForm 1 0 0 1 50 30, so after the Y-flip it is a ⌀20 circle centred (50, -30) with a 20 x 20 mm
  # bbox — and its 40 x 20 Rect (bbox 30..70, -40..-20) ENCLOSES that bbox, which is what makes the
  # click a paint-order test: contours are appended in descending bbox area (Rect 800, circle 400),
  # so the circle is on top and a click at its own centre selects it rather than the Rect.
  test "the SVG button exports exactly the marked parts" do
    visit file_path(@sample_id)
    click_on "Measure"
    assert_selector ".measure-view--ready", wait: 10

    page.execute_script(<<~JS)
      window.__blob = null
      window.__downloads = []
      const realCreate = URL.createObjectURL
      URL.createObjectURL = (blob) => { window.__blob = blob; return realCreate.call(URL, blob) }
      HTMLAnchorElement.prototype.click = function () { window.__downloads.push(this.download) }
    JS

    click_on "Select parts"
    find(".measure-stage circle.measure-contour").click
    assert_text "1 part"

    find("[data-measure-target='svgButton']").click

    svg = page.evaluate_async_script(<<~JS)
      const done = arguments[arguments.length - 1];
      window.__blob ? window.__blob.text().then(done) : done("NO BLOB");
    JS

    # THE CIRCLE ALONE — not the 40 x 20 Rect around it and not the 100 mm Line. A width of 100mm
    # would mean the whole file was exported; 40mm would mean the Rect came too.
    assert_includes svg, 'width="20mm"'
    assert_includes svg, 'height="20mm"'
    assert_includes svg, "<circle "
    assert_includes svg, 'r="10"'
    # Normalized to the origin: the circle's own bbox starts at (40, -40).
    assert_includes svg, 'transform="translate(-40 40)"'
    # The SOURCE base name plus a suffix, never the source name itself.
    assert_equal [ "sample-parts.svg" ], page.evaluate_script("window.__downloads")
  end

  # THE BUTTON MUST NOT LIE ABOUT WHAT IT DOES. Its visible text is constant because the bar
  # already carries seven controls, so the accessible name is what tracks the target — written by
  # the same refreshPrintBar() that writes the Print label, from the same targetNoun(). The at-rest
  # literal is also in the ERB, so this catches the two drifting apart.
  test "the button's accessible name names the set it will export" do
    visit file_path(@sample_id)
    click_on "Measure"
    assert_selector ".measure-view--ready", wait: 10

    assert_selector "[data-measure-target='svgButton'][aria-label='Download all as SVG']"

    click_on "Select parts"
    find(".measure-stage circle.measure-contour").click
    assert_selector "[data-measure-target='svgButton'][aria-label='Download 1 part as SVG']"
  end

  test "the exported blob is typed as an SVG image" do
    visit file_path(@sample_id)
    click_on "Measure"
    assert_selector ".measure-view--ready", wait: 10

    page.execute_script(<<~JS)
      window.__blob = null
      const realCreate = URL.createObjectURL
      URL.createObjectURL = (blob) => { window.__blob = blob; return realCreate.call(URL, blob) }
      HTMLAnchorElement.prototype.click = function () {}
    JS

    find("[data-measure-target='svgButton']").click

    assert_equal "image/svg+xml", page.evaluate_script("window.__blob.type")
  end
```

- [ ] **Step 2: Run to verify it fails**

```bash
LIBRARY_PATH=$(mktemp -d) bin/rails test test/system/measure_export_test.rb
```

Expected: FAIL — no `svgButton` target.

- [ ] **Step 3: Add the button**

In `app/views/files/_measure.html.erb`, between the Print and Reset buttons:

```erb
      <%#
        VISIBLE TEXT IS CONSTANT, THE ACCESSIBLE NAME IS NOT. The bar already carries six controls,
        so a second count-bearing label beside "Print 3 parts" is noise — but the button must still
        say what it will do, so refreshPrintBar() writes aria-label/title from the same
        targetNoun() the Print label uses. The literals here are the at-rest state the controller
        writes on draw(); they must agree with it, exactly as "Print all" does above.
      %>
      <button type="button" class="btn small ghost" data-action="measure#downloadSvg"
              data-measure-target="svgButton"
              aria-label="Download all as SVG" title="Download all as SVG">SVG</button>
```

- [ ] **Step 4: Register the target and implement the action**

In `measure_controller.js`, add `"svgButton"` to `static targets`:

```javascript
  static targets = ["stage", "dims", "fallback", "selectToggle", "paper", "printButton", "svgButton"]
```

Extend `refreshPrintBar()`:

```javascript
  refreshPrintBar() {
    const noun = this.targetNoun()
    this.printButtonTarget.textContent = `Print ${noun}`
    // THE SVG BUTTON'S TEXT DOES NOT MOVE, SO ITS ACCESSIBLE NAME MUST. Both are written here,
    // from one targetNoun(), so the two buttons cannot come to describe different sets.
    const label = `Download ${noun} as SVG`
    this.svgButtonTarget.setAttribute("aria-label", label)
    this.svgButtonTarget.setAttribute("title", label)
  }
```

Add `downloadSvg()` immediately after `print()`:

```javascript
  // THE SAME TARGET SET print() USES, resolved by the same method — so the two buttons beside each
  // other can never act on different shapes.
  //
  // THE BLOB IS BUILT AND RELEASED HERE; lib/export_svg builds the DOCUMENT and knows nothing about
  // downloads. That is the split print_sheet.js draws between renderSheet and buildPrintFrame, and
  // it is what lets the export be asserted as a string in a test rather than as a file on disk.
  downloadSvg() {
    const shapes = this.targetShapes()
    // The same guard, and the same window, as print()'s: `allShapes` is undefined between
    // connect() and the first successful draw(), and the button is display:none throughout it.
    if (!shapes || !shapes.length) return

    let url
    try {
      const blob = new Blob([ exportSvg(shapes, { colors: this.colors }) ], { type: "image/svg+xml" })
      url = URL.createObjectURL(blob)
      const a = document.createElement("a")
      a.href = url
      // The SOURCE file's base name plus a suffix, never the source name itself: exporting a
      // subset of `plate.svg` to a file also called `plate.svg` is a download that silently
      // shadows the original in the browser's download folder.
      a.download = `${this.nameValue.replace(/\.[^.]+$/, "")}-parts.svg`
      a.click()
    } catch (e) {
      // REACHES THE READOUT, not just the console — exportSvg throws before any file exists, so a
      // swallowed message is a button that does nothing whatsoever. AND IT LOGS, because this
      // catch cannot tell a refusal from a bug: print()'s own catch carries the same pair for the
      // same reason.
      console.warn("[measure] export refused:", e)
      this.setStatus(e.message)
    } finally {
      // RELEASED EVEN WHEN THE CLICK THREW. An object URL pins its Blob for the lifetime of the
      // document, and this view is reachable repeatedly through the ✕ Image -> Measure round trip.
      if (url) URL.revokeObjectURL(url)
    }
  }
```

Extend the import at the top:

```javascript
import { exportSvg } from "lib/export_svg"
```

- [ ] **Step 5: Run to verify pass**

```bash
LIBRARY_PATH=$(mktemp -d) bin/rails test test/system/measure_export_test.rb
```

Expected: PASS. If the CSP blocks the `blob:` anchor, the SEVERE-console check in
`ApplicationSystemTestCase` will report it — §14e: a CSP header that parses is not a CSP that
works, and only a browser knows. The policy is report-only today, so a report is a finding to
record in the invariants doc, not a failure to route around.


> **Commit first, then mutate** — `git checkout --` restores to HEAD, so mutating before the
> commit destroys this task's own work. See the note at the top of this plan.

- [ ] **Step 6: Commit**

```bash
git add app/views/files/_measure.html.erb app/javascript/controllers/measure_controller.js test/system/measure_export_test.rb
git commit -m "Measure: download the selected shapes as SVG"
```

- [ ] **Step 7: Mutation-check the shared target set**

In `downloadSvg()`, replace `this.targetShapes()` with `this.allShapes`. "the SVG button exports
exactly the marked parts" must go **RED** — it would export the Rect and the 100 mm Line too, so
the document comes out `width="100mm"` rather than `width="20mm"`. Restore.

Then, in `refreshPrintBar()`, hard-code the SVG button's label to `"Download all as SVG"`. "the
button's accessible name names the set it will export" must go **RED** on its second assertion —
the half that proves the name TRACKS the target rather than merely existing. Restore.

---

## Task 12: Record the invariants

**Files:**
- Modify: `docs/invariants/measure-view.md`
- Modify: `docs/adding-a-preview-format.md`

CLAUDE.md §15: update the docs **in the branch that moves the architecture**. §14h is a stub in
CLAUDE.md and needs no change — the rules go in the pointed-at file.

- [ ] **Step 1: Add the new rules to `docs/invariants/measure-view.md`**

Append to the bullet list, in the same voice as its neighbours:

```markdown
- **`g` IS A DRAWING HINT AND NOTHING MEASURES FROM IT — the same contract the traversals already
  stated about the descriptors they yield, extended to a second consumer.** `Lbrn2.each_geometry`
  and `Dxf.each_geometry` have always emitted an exact ellipse/circle/arc beside the flattened
  points, and both thumbnail renderers have always drawn it; `Geometry::Collector#add` had no
  parameter for one, so the payload discarded it by name (`_ellipse`, `_curve`) and the Measure
  view drew a 32-gon beside a thumbnail drawing an ellipse. `b`, `d` and the job box are still
  computed from FULL-RESOLUTION POINTS and a client ignoring `g` reports identical numbers.
- **NOTHING INFERS A DESCRIPTOR FROM THE POINTS, AND THAT IS THE WHOLE SAFETY ARGUMENT.** A shape
  gets one because the FILE said `<Ellipse>` / `CIRCLE` / `ARC` / `<circle>`. `Geometry.diameter`'s
  accepted consequence — a genuine 16-gon reports as round — stays confined to the ⌀ LABEL, which
  is advisory. Reaching it into `g` would substitute a circle for a designed polygon in a file
  somebody CUTS, which is the label trap one surface further out and one degree worse.
- **THE AXIS-ALIGNED GATE IS LOAD-BEARING ON BOTH LEGS, AND HAD NO TEST AT ALL UNTIL 2026-09-02.**
  Under a rotation an SVG `<ellipse>` is not an SVG `<ellipse>`. Every `<XForm>` in the fixture
  corpus was a translate or a scale, so `Lbrn2.axis_aligned?` was a GREEN MUTATION for as long as
  it existed — it only governed thumbnail crispness, so nothing noticed. `rotated-ellipse.lbrn2`
  carries an upright ellipse AND a 30° one, because an implementation that always emits and one
  that never emits each pass half of a one-shape fixture. `SvgGeometry.ellipse_curve_for` applies
  the same test for the same reason.
- **A 360° DXF `ARC` IS ENCODED AS AN ELLIPSE, NEVER AS AN ARC.** `Dxf.arc_points` turns
  `a0 == a1` into a 360° sweep, whose start and end points are IDENTICAL — and SVG's own rule for
  an arc whose endpoints coincide is to omit the segment ENTIRELY. An `A` command there exports a
  path that draws nothing: no error, nothing logged, a shape simply missing from a file somebody
  cuts. **`Dxf.arc_svg` STILL HAS THIS BUG FOR THE THUMBNAIL** — recorded, not fixed, because the
  fix needs a `THUMBNAIL_REVISION` bump; the payload path must not inherit it.
- **THE ELEMENT A SHAPE DRAWS AS HAS ONE DEFINITION, `lib/shape_svg.js`, AND IT WRITES NO
  PRESENTATION.** Three callers want three presentations of one shape — the Measure view's
  class + layer colour + hit twin, the print sheet's black 0.2 mm, the exporter's layer colour —
  so the shared module picks the ELEMENT TYPE and the geometry attributes only. `el` and
  `unionBox` moved there too and `print_sheet.js` RE-EXPORTS both, which is what keeps
  `measure_print_test.rb`'s pin of `el`'s mis-call guard working through the move.
  `measure_controller.js`'s `unionOf` was byte-identical to `unionBox` and is gone; the exporter
  would have made three.
- **THE HIT TWIN IS ALWAYS A POLYLINE FROM `shape.p`, EVEN UNDER AN ARC.** It is an invisible 8 px
  target, so approximating the curve costs nothing visible and keeps the twin one element. It must
  be built from the points rather than reusing the visible node's `points` string — the visible
  node no longer necessarily has one.
- **THE EXPORT IS NORMALIZED TO THE ORIGIN AND ITS CANVAS SIZE IS THE PART SIZE.**
  `width="{w}mm"` + a viewBox spanning the same `w` is the entire scale mechanism, the same one
  `renderSheet` uses; there is no transform and no dpi constant. ONE translate for the whole
  selection, so several parts keep their relative positions. A px width draws an identical-looking
  file that is silently the wrong size in an application that will cut it.
- **THE EXPORT USES THE LAYER COLOUR WHERE THE PRINT SHEET USES BLACK, AND THAT DIVERGENCE IS
  ARGUED.** The sheet is black because a mono printer turns a palette into indistinguishable
  greys. A file has no such constraint, and LightBurn maps stroke colour back to layers on import.
- **`lib/export_svg.js` BUILDS THE DOCUMENT AND `downloadSvg()` BUILDS THE BLOB.** The same split
  `print_sheet.js` draws between `renderSheet` (pure) and `buildPrintFrame` (not), and it is what
  lets the export be asserted as a STRING rather than as a file on disk — headless Chrome here has
  no configured download directory, so the system test shims `URL.createObjectURL` and
  `HTMLAnchorElement.prototype.click` instead.
- **THE SVG BUTTON'S VISIBLE TEXT IS CONSTANT AND ITS ACCESSIBLE NAME IS NOT.** The bar carries
  seven controls, so a second count-bearing label beside "Print 3 parts" is noise — but a button
  must not lie about what it does, so `refreshPrintBar()` writes its `aria-label`/`title` from the
  same `targetNoun()` the Print label uses. `targetShapes()` and `targetNoun()` replaced the three
  arms written out twice under a comment saying they "must not drift"; the exporter would have
  been a third copy.
```

- [ ] **Step 2: Note the descriptor in the format walkthrough**

`docs/adding-a-preview-format.md` is entirely about the **thumbnail** path — four numbered steps,
`render(bytes, size:)`, the Registry, the contract test — and says nothing about the geometry
payload at all. So there is no "what a traversal supplies" section to extend; add a fifth numbered
step instead, after step 4 and before the "Thumbnails generate eagerly" paragraph:

```markdown
5. **If it is 2D vector, it can also measure.** A format that can yield contours gets the Measure
   view by supplying a traversal to `Maker::Previews::Geometry.build` (see `LbrnGeometry`,
   `DxfGeometry`, `SvgGeometry`) and declaring `FORMAT_REVISION` / `PAYLOAD_REVISION` — the latter
   as `Geometry::SHARED_REVISION + FORMAT_REVISION`, never a bare integer, and the module must be
   named in `Geometry::REVISIONED_BY` or `GeometryTest` fails.

   A traversal MAY also supply a **curve descriptor** through `Collector#add`'s `curve:` keyword,
   built with `Geometry.ellipse_curve` or `Geometry.arc_curve` and already in client space (mm,
   Y-down). It is optional and **drawing-only**: `b`, `d` and the job box are computed from the
   full-resolution points regardless, so a format supplying none is complete. Supply one ONLY where
   the file itself declared an exact primitive — never inferred from the points — and refuse it
   under a rotated or skewed transform. `docs/invariants/measure-view.md` is the binding set of
   rules here; read it before writing a traversal.
```

- [ ] **Step 3: Two code comments the earlier tasks deliberately left**

Both were spotted during Task 1 and consciously deferred here, because they are documentation of
the collector rather than part of its implementation.

**a. `app/services/maker/previews/geometry.rb`'s module header** carries the onboarding example a
new format author reads to learn the interface, and it now lists 5 of the 6 keywords:

```ruby
    #   Geometry.build(colors: ->(layers) { ... }) do |out|
    #     out.add(layer:, points:, closed:, image:, object_id:)
    #   end
```

Add the optional keyword and one line saying what it is — a traversal author who reads only this
header would otherwise never learn the descriptor exists:

```ruby
    #   Geometry.build(colors: ->(layers) { ... }) do |out|
    #     out.add(layer:, points:, closed:, image:, object_id:, curve: nil)
    #   end
    #
    # `curve:` IS OPTIONAL AND DRAWING-ONLY — an exact primitive the FILE declared, built with
    # `ellipse_curve`/`arc_curve`. A format supplying none is complete; see those two methods.
```

**b. `test/services/maker/previews/geometry_test.rb`'s absolute-pin comment** argues that "a
relationship-only pin is satisfied by seeding SHARED_REVISION at 1 and shifting all three totals".
That argument is still correct, but 1 is now the live value, so it reads as though it were
describing what this branch just did. Reword the hypothetical so it cannot be misread — e.g. "by
seeding SHARED_REVISION at any value and shifting all three totals to match".

- [ ] **Step 4: Correct the design spec, which the implementation overtook**

`docs/superpowers/specs/2026-09-02-measure-shape-svg-export-design.md:86` reads:

> `ellipse_contours` returns a descriptor, `walk` yields it, and `build` scales it by `sx`/`sy`.

The first clause is **false**. Planning changed course deliberately: `contours_for` returns
`[[points, closed], ...]` across seven branches, and widening it for the two element names that can
carry a descriptor would have touched all seven. The shipped design leaves `ellipse_contours`
untouched and computes the descriptor separately in `walk` via `ellipse_curve_for(node, world)`.

Correct it **in place, with the correction visible** — this repo's own convention for a claim that
turned out wrong (CLAUDE.md is full of "this read X until <date>; measured: Y"). Do not silently
rewrite it and do not delete it:

```markdown
- **`SvgGeometry`** — the only genuinely new work. A new `ellipse_curve_for(node, world)` computes
  the descriptor and `walk` yields it alongside the points; `build` scales both by `sx`/`sy`. It
  must be **gated on the accumulated `world` transform being axis-aligned**, mirroring
  `Lbrn2.axis_aligned?` — a rotated `<circle>` is not an SVG ellipse and must stay a polygon.
  *(This read "`ellipse_contours` returns a descriptor" until implementation on 2026-09-02.
  `contours_for` returns `[[points, closed], ...]` across seven branches and only two of them can
  carry a descriptor, so it was left untouched rather than widened.)*
```

Leave every OTHER dated record alone — `docs/superpowers/specs|plans/2026-08-19-*` describe finished
work and retro-editing them would falsify the record. This one documents the branch in progress and
is wrong about it.

- [ ] **Step 5: Confirm the docs guard still passes**

```bash
LIBRARY_PATH=$(mktemp -d) bin/rails test test/docs_hygiene_test.rb
```

Expected: PASS — every §14 stub still has its file, and CLAUDE.md is untouched and under its
ceiling.

- [ ] **Step 6: Commit**

```bash
git add docs/invariants/measure-view.md docs/adding-a-preview-format.md \
        docs/superpowers/specs/2026-09-02-measure-shape-svg-export-design.md \
        app/services/maker/previews/geometry.rb \
        test/services/maker/previews/geometry_test.rb
git commit -m "Record the curve-descriptor and export invariants"
```

---

## Task 13: Full gates

- [ ] **Step 1: Run the three backend legs**

```bash
bin/ci
```

Expected: all gates green. **`test`, `test-s3` and `test-chunk-remote` must report identical run
counts** — `bin/ci` prints them but does not compare them, so read them. A ±2 assertion / ±1 skip
difference is the known flap recorded as `tinkerex#131`; a structural difference means a test
depends on the ambient `LIBRARY_BACKEND` and is a real bug.

`test-chunk-remote` needs `../tinkerex-sync` checked out. From this worktree, set
`TINKEREX_SYNC_DIR` or the leg cannot find it:

```bash
TINKEREX_SYNC_DIR=/Users/charlesschwartz/Desktop/repos/tinkerex-sync bin/ci
```

- [ ] **Step 2: Confirm no stray macOS duplicate files**

```bash
find . -name '* 2.*' -not -path './node_modules/*' -delete
```

- [ ] **Step 3: Finish the branch**

Use `/finish-branch`: commit, push, open the PR, then `bin/log arc --from-pr <n>`. State in the PR
what was verified and what was not — specifically that the `Dxf.arc_svg` 360° thumbnail bug was
found and deliberately left unfixed.

---

## Verification checklist

- [ ] `Geometry::SHARED_REVISION` is 1 and `SCHEMA_VERSION` is still 1 in **both** Ruby and JS
- [ ] `GEOMETRY_REVISIONS` reads 5/5/5/2/2
- [ ] `rotated-ellipse.lbrn2` exists; deleting `Lbrn2.axis_aligned?`'s gate turns the suite RED
- [ ] `bezier-circle.lbrn2`'s Path circle has `d` and **no** `g` — nothing infers a primitive
- [ ] `measure_controller.js` contains no `unionOf`, no local `SVG_NS`, and no literal three-arm
      precedence expression
- [ ] `print_sheet.js` defines neither `el` nor `unionBox`, and re-exports both
- [ ] A 360° DXF `ARC` yields `["e", …]`, not `["a", …]`
- [ ] The exported document declares `xmlns` exactly once
- [ ] Every mutation named in Tasks 1, 3, 4, 5, 7, 9 and 11 was performed and produced RED
- [ ] `bin/ci` green, three backend legs' run counts read and matching
