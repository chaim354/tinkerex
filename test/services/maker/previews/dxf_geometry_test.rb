require "test_helper"

module Maker
  module Previews
    class DxfGeometryTest < ActiveSupport::TestCase
      # ---- units --------------------------------------------------------------------------

      # THE HEADLINE PROPERTY, and the one that fails invisibly: a wrong scale leaves the drawing
      # perfect and every reported number off by a constant factor.
      test "$INSUNITS scales the drawing into millimetres" do
        { 1 => 50.8, 4 => 2.0, 5 => 20.0, 6 => 2000.0 }.each do |code, expected_diameter|
          payload = build(circle_dxf(radius: 1, insunits: code))

          assert_in_delta expected_diameter, payload["shapes"].first["d"], 0.01,
                          "$INSUNITS #{code} must resolve through the table"
        end
      end

      # A DXF from a maker tool routinely has no HEADER at all — the sample fixture does not.
      # Millimetres is the documented default, and it has the property that a file which IS in mm
      # measures correctly with no header, which is the common case.
      test "a file with no $INSUNITS is read as millimetres" do
        payload = build(circle_dxf(radius: 5, insunits: nil))

        assert_in_delta 10.0, payload["shapes"].first["d"], 0.01
      end

      test "an unknown $INSUNITS code falls back rather than raising" do
        payload = build(circle_dxf(radius: 5, insunits: 19)) # light years

        assert_in_delta 10.0, payload["shapes"].first["d"], 0.01
      end

      # ---- layers -------------------------------------------------------------------------

      # An entity's own colour is usually absent or BYLAYER, so the LAYER TABLE is where a real
      # DXF's colours live. Reading only the entity leaves nearly every file colourless.
      test "layer colours come from the LAYER table" do
        payload = build(fixture("plate.dxf"))

        assert_equal({ "Cut" => "#ff0000", "Engrave" => "#0000ff" }, payload["colors"])
        assert_equal %w[Cut Engrave], payload["shapes"].map { |s| s["c"] }
      end

      # A NEGATIVE table colour means the layer is OFF — construction geometry the author chose
      # not to cut. Drawing it puts lines in the picture that are not in the job, and folds them
      # into the measured extent so the reported size describes something the machine never makes.
      #
      # plate.dxf's Scrap layer holds a r=25 circle at (200,200); measured, the job would be
      # 225 x 225 instead of 80 x 40.
      test "an off layer is neither drawn nor measured" do
        payload = build(fixture("plate.dxf"))

        assert_equal 2, payload["shapes"].length, "the off layer's circle must not be measured"
        assert_not_includes payload["shapes"].map { |s| s["c"] }, "Scrap"
        assert_in_delta 80.0, payload["job"]["w"], 0.01
        assert_in_delta 40.0, payload["job"]["h"], 0.01
      end

      test "an ACI index outside the standard table yields no colour rather than a guess" do
        dxf = "0\nSECTION\n2\nTABLES\n0\nLAYER\n2\nOdd\n62\n137\n0\nENDSEC\n" \
              "0\nSECTION\n2\nENTITIES\n0\nCIRCLE\n8\nOdd\n10\n0\n20\n0\n40\n5\n0\nENDSEC\n0\nEOF\n"
        payload = build(dxf)

        assert_equal "Odd", payload["shapes"].first["c"], "the layer still groups"
        assert_equal({}, payload["colors"], "but it claims no colour")
      end

      # ---- entities -----------------------------------------------------------------------

      test "the sample fixture's four entity types all measure" do
        payload = build(fixture("sample.dxf"))

        assert_equal 4, payload["shapes"].length
        assert_equal 4, payload["shapes"].map { |s| s["o"] }.uniq.length, "each entity is its own object"
      end

      test "a CIRCLE reports its diameter and a closed LWPOLYLINE does not" do
        payload = build(fixture("plate.dxf"))
        plate, hole = payload["shapes"]

        assert_nil plate["d"], "a rectangular plate is not round"
        assert_in_delta 10.0, hole["d"], 0.01
      end

      test "a closed polyline is flagged closed and an ARC is not" do
        payload = build(fixture("sample.dxf"))
        kinds = payload["shapes"].map { |s| [ s["o"], s["k"] ] }.to_h

        # sample.dxf, in document order: LINE, CIRCLE, LWPOLYLINE (code 70=1), ARC.
        assert_equal 0, kinds[1], "a LINE is open"
        assert_equal 1, kinds[2], "a CIRCLE is closed"
        assert_equal 1, kinds[3], "the fixture's LWPOLYLINE sets code 70 bit 1"
        assert_equal 0, kinds[4], "an ARC is open"
      end

      # ---- orientation --------------------------------------------------------------------

      # DXF IS Y-UP AND THE CLIENT IS Y-DOWN, so the payload must flip — the same flip the
      # thumbnail applies. Without it every DXF measures correctly and draws upside down relative
      # to its own poster, which is the confusing failure rather than the obvious one.
      test "the y axis is flipped to match the thumbnail" do
        dxf = "0\nSECTION\n2\nENTITIES\n" \
              "0\nCIRCLE\n8\nA\n10\n0\n20\n100\n40\n1\n" \
              "0\nCIRCLE\n8\nA\n10\n0\n20\n0\n40\n1\n" \
              "0\nENDSEC\n0\nEOF\n"
        high, low = build(dxf)["shapes"]

        assert_operator high["b"][1], :<, low["b"][1],
                        "the entity at the larger DXF y must end up with the smaller client y"
      end

      # ---- one traversal --------------------------------------------------------------------

      # THE GUARD THAT TIES THE TWO ARTIFACTS TOGETHER. The thumbnail and the payload read this
      # file through the SAME `each_geometry`, so nobody can optimise the walk for one caller
      # without this going red — §14b's LbrnMetadata second-copy bug is the precedent.
      #
      # The thumbnail's SVG is unscaled and the payload is in mm, so the comparison is of SHAPE:
      # the payload's extent divided by the SVG viewBox's must be exactly the unit scale.
      # entities.dxf EARNS ITS PLACE HERE MORE THAN THE OTHER TWO: it is the only fixture holding a
      # full-turn ARC, and that entity is drawn by a DIFFERENT branch on each leg — a `<circle>` in
      # the thumbnail, an `"e"` descriptor in the payload. Two branches for one fact is where the
      # two artifacts diverge, and tinkerex#215 was exactly that divergence left half-fixed.
      test "the payload and the thumbnail measure the same geometry" do
        %w[sample.dxf plate.dxf entities.dxf].each do |name|
          bytes = fixture(name)
          payload = build(bytes)
          scale = Dxf.mm_per_unit(Dxf.tokenize(bytes))

          # The viewBox pads by 2 user units on each side (see Dxf::BBox#viewbox).
          vb = Dxf.to_svg(bytes)[/viewBox="([^"]+)"/, 1].split.map(&:to_f)
          assert_in_delta (vb[2] - 4) * scale, payload["job"]["w"], 0.05, "#{name}: widths disagree"
          assert_in_delta (vb[3] - 4) * scale, payload["job"]["h"], 0.05, "#{name}: heights disagree"
        end
      end

      # THE FILE IS LEXED ONCE PER RENDER, AND THIS IS A GUARD ON WORK DONE rather than on
      # output — the only kind that can see this regression, because lexing twice produces the
      # identical picture and the identical payload at double the cost, so no assertion about the
      # result can fail. `lbrn2_test.rb`'s "a VertList is parsed exactly once per document" is the
      # same guard for the same reason. Measured before `each_geometry` took the pairs: TWO
      # `tokenize` calls on each of the two legs. The 2026-08-19 audit timed one pass of this
      # exact lexer at ~148 ms on a synthetic 4.4 MB drawing.
      test "the file is lexed exactly once per render, on both legs" do
        bytes = fixture("plate.dxf")

        payload_lexes = counting(:tokenize) { DxfGeometry.render(bytes) }
        thumbnail_lexes = counting(:tokenize) { Dxf.to_svg(bytes) }

        # NON-VACUITY FIRST: a counter whose hook failed to install reads 0, and diagnosing that
        # as "the lex count regressed" would be a guard reporting on nothing (§14e).
        assert_operator payload_lexes, :>, 0, "the tokenize hook never fired — it did not install"
        assert_operator thumbnail_lexes, :>, 0, "the tokenize hook never fired — it did not install"

        assert_equal 1, payload_lexes, "the payload leg must lex the file once, got #{payload_lexes}"
        assert_equal 1, thumbnail_lexes, "the thumbnail leg must lex the file once, got #{thumbnail_lexes}"
      end

      # THE BACKSTOP THAT LICENSES NOT BUMPING A REVISION. Handing `each_geometry` the pairs
      # instead of the bytes changed the traversal's plumbing and not its output, and these
      # digests are the evidence rather than the claim: they were taken from the pre-refactor code
      # and compared across eight inputs (both fixtures, $INSUNITS present/absent/unknown, an off
      # layer with a non-standard ACI, an empty ENTITIES section, and unparseable bytes) — all
      # byte-identical, which is what made re-measuring the whole library unnecessary.
      #
      # SO A CHANGE HERE IS NEVER JUST A FAILING DIGEST. A stored artifact goes stale on the CODE
      # axis as well as the CONTENT one (docs/invariants/measure-view.md, §14h): if the SVG moves,
      # `Dxf::THUMBNAIL_REVISION` must move with it; if the payload moves,
      # `DxfGeometry::FORMAT_REVISION` must. Update the digest only once the matching revision has
      # been bumped, or every already-measured DXF serves the old bytes forever — a finished
      # design's content never changes, so nothing else will ever invalidate it.
      #
      # THE PAYLOAD DIGESTS MOVED ON 2026-09-02 AND THE SVG ONES DELIBERATELY DID NOT, which is the
      # evidence that carrying the `g` curve descriptor touched the payload alone. Both fixtures
      # hold a CIRCLE and sample.dxf an ARC, so both payloads gained a `g`;
      # `DxfGeometry::PAYLOAD_REVISION` had already moved 1 -> 2 via `Geometry::SHARED_REVISION`,
      # which is the licence this comment demands. `Dxf::THUMBNAIL_REVISION` stays at 1 because
      # `Dxf.to_svg` was not touched — and these two unchanged SVG digests are what proves it.
      #
      # SAMPLE'S PAYLOAD DIGEST MOVED AGAIN LATER THE SAME DAY, WITH NO SECOND BUMP, and the split
      # between the two fixtures is the evidence that the change was the ARC form and nothing else.
      # `g`'s arc encoding became centre + angles instead of resolved `A` endpoints — see
      # `Geometry.arc_curve` — so sample.dxf, which holds an ARC, moved, and plate.dxf, which holds
      # CIRCLEs only, DID NOT. A revision invalidates STORED artifacts; revision 1 was defined and
      # redefined on the same unmerged branch and no deployment ever served an arc under it, so
      # there was nothing to invalidate. A move in plate's payload digest would mean the change
      # reached shapes it had no business touching.
      #
      # ON 2026-09-03 BOTH REVISIONS MOVED AND NEITHER OLD DIGEST DID, WHICH IS THE REVERSE OF THE
      # PARAGRAPH ABOVE AND IS NOT A MISTAKE. `each_geometry` learned SPLINE, POLYLINE bulges and
      # BLOCK/INSERT placement, and it feeds the thumbnail as well as the payload, so
      # `Dxf::THUMBNAIL_REVISION` went 1 -> 2 and `DxfGeometry::FORMAT_REVISION` 1 -> 2. Yet
      # sample.dxf and plate.dxf are byte-identical before and after — verified, not assumed:
      # BETWEEN THEM THEY CONTAIN ZERO SPLINES, ZERO NON-ZERO BULGES AND NO BLOCKS SECTION, so
      # there is nothing in either for the new code to reach. Their digests were deliberately NOT
      # updated. A REVISION TRACKS WHAT THE RENDERER DOES TO REAL FILES, NOT WHAT THESE TWO NARROW
      # FIXTURES HAPPEN TO HOLD: the change moved the output of 29, 26 and 24 of the 129-file live
      # corpus respectively, which is what makes re-rendering the library correct.
      #
      # AND THAT IS EXACTLY THE HOLE `entities.dxf` EXISTS TO CLOSE. For four stages this guard
      # reported "nothing moved" about changes that moved the picture for a fifth of every DXF in
      # the library — right about its fixtures and blind to the change, which is a guard that
      # cannot fail for the thing it exists to catch (§15). The third fixture is hand-authored to
      # hold one instance of each: a two-span degree-3 SPLINE, a closed POLYLINE with equal and
      # OPPOSITE bulges, a BLOCK placed by an INSERT at a non-zero offset, and the full-turn ARC
      # from tinkerex#215. Its own comment header says what each part pins. A fifth entity type
      # gets a fifth part of that fixture, not a fourth fixture.
      test "the traversal's two artifacts are byte-for-byte what they were before it took pairs" do
        {
          "sample.dxf" => %w[
            f32daab0e0264cb27c3d1ae8f3a9f74cda65b56c4b3009062c202900f9232352
            7efb394bb5c87eb18ba524eb00de78b004aa87331ba2bf35bab3231af6d8e9e0
          ],
          "plate.dxf" => %w[
            d8844eb6832b6d107fd1ad782ce34fc8a35d3b088b4609a6f0c8e6dba86e035d
            0839e1081f3a506a009ba31d643d59ebd8ca62242f4d6bcaaf10c79fb77af431
          ],
          "entities.dxf" => %w[
            a27713d1de9be2c8a8120323d1ec07adf26f32180a5d7c727edcea1764cdcdd5
            4eed13b16b2abfc2d478d756494327d2a2b26fa78b8b03ca8b38c64a1192cd27
          ]
        }.each do |name, (svg_sha, payload_sha)|
          bytes = fixture(name)

          assert_equal svg_sha, Digest::SHA256.hexdigest(Dxf.to_svg(bytes)),
                       "#{name}: the thumbnail SVG moved — bump Dxf::THUMBNAIL_REVISION"
          assert_equal payload_sha, Digest::SHA256.hexdigest(DxfGeometry.render(bytes)[:bytes]),
                       "#{name}: the measure payload moved — bump DxfGeometry::FORMAT_REVISION"
        end
      end

      # Arcs and circles are flattened for MEASURING and the exact primitive rides alongside, so
      # the thumbnail stays crisp at any zoom and the payload's `g` lets the client draw the same
      # curve. What `g` never does is displace the points: `b`, `d` and the job box are still
      # computed from the flattened ones, and a consumer that used the descriptor INSTEAD of them
      # would be reading a different geometry from the one the bbox came from.
      test "the thumbnail keeps exact primitives while the payload measures flattened points" do
        svg = Dxf.to_svg(fixture("sample.dxf"))

        assert_includes svg, "<circle", "a CIRCLE must still draw as an exact circle"
        assert_includes svg, "<path",   "an ARC must still draw as an exact arc"
        assert_operator build(fixture("sample.dxf"))["shapes"][1]["p"].length, :>, 4,
                        "the same circle must be flattened in the payload"
      end

      # A full circle must sample its axis extents EXACTLY, or the reported diameter is a chord's
      # rather than the circle's. That is what the multiple-of-4 rounding in arc_samples buys.
      test "a flattened circle reports its true diameter, not a chord" do
        [ 0.5, 5.0, 250.0 ].each do |r|
          payload = build(circle_dxf(radius: r, insunits: 4))

          assert_in_delta r * 2, payload["shapes"].first["d"], 1e-6,
                          "r=#{r} must measure exactly, at any size"
        end
      end

      # ---- curve descriptors ----------------------------------------------------------------

      # A CIRCLE entity is exact in both DXF and SVG. The traversal has always yielded the
      # descriptor (`Dxf.to_svg` draws a real <circle> from it); the payload discarded it by name.
      test "a CIRCLE entity carries an exact ellipse descriptor in client space" do
        payload = build(circle_dxf(radius: 5, insunits: nil))

        # Model space is Y-up and the client's is Y-down, so cy is negated — the same flip
        # to_client_space applies to the points. A centre of (0, 0) makes that invisible, which is
        # what the next test's off-axis centre is for.
        assert_equal [ "e", 0.0, 0.0, 5.0, 5.0 ], payload["shapes"].first["g"]
      end

      test "the descriptor is scaled and Y-flipped exactly as the points are" do
        # $INSUNITS 1 = inches, so 25.4 mm per unit.
        payload = build(circle_dxf(radius: 2, insunits: 1, cx: 3, cy: 4))

        assert_equal [ "e", 76.2, -101.6, 50.8, 50.8 ], payload["shapes"].first["g"]
      end

      # A 90-degree ARC from 0 to 90 about the origin, r=10. In MODEL space it runs counter-
      # clockwise from (10, 0) to (0, 10); the Y-flip mirrors that about the X axis, so in client
      # space it starts at the SAME angle 0 and sweeps NEGATIVELY to -90.
      #
      # THE SIGN OF DELTA IS THE WHOLE ORIENTATION STORY, and it must stay negative for a DXF.
      # `Dxf.arc_svg` makes the identical conversion for the thumbnail and its own comment says so.
      # A POSITIVE delta makes the client write sweep-flag 1, which draws the arc the long way
      # round: still an arc, still touching both endpoints, and the wrong 3/4 of the circle.
      test "an ARC becomes centre, start angle and a signed sweep with the flip applied" do
        payload = build(arc_dxf(cx: 0, cy: 0, r: 10, a0: 0, a1: 90))

        assert_equal [ "a", 0.0, 0.0, 10.0, 0.0, -90.0 ], payload["shapes"].first["g"]
      end

      # The angles are DEGREES and do not round at PRECISION — see Geometry::ANGLE_PRECISION. The
      # centre and radius are millimetres and do. `(360 - a0) % 360` is why the start angle comes
      # back as 336.5051 rather than -23.4949; both name the same direction, one of them without a
      # negative zero for the a0 = 0 case above.
      test "an arc's millimetres round at PRECISION and its angles do not" do
        payload = build(arc_dxf(cx: 1.234, cy: -4.567, r: 10, a0: 23.4949, a1: 143.4949))

        assert_equal [ "a", 1.23, 4.57, 10.0, 336.5051, -120.0 ], payload["shapes"].first["g"]
      end

      # THE DEFECT THE WIRE FORM EXISTS TO REMOVE, PINNED AS GEOMETRY RATHER THAN AS FIVE NUMBERS.
      # An assertion on the descriptor's literal contents cannot see it — the numbers were always
      # "right", and what was wrong was that SVG's ENDPOINT parameterisation must not be rounded.
      # It puts the centre sqrt(r² − d²) from the chord midpoint (d the half-chord), so near a
      # half-turn an error δ in an endpoint displaces the centre by about sqrt(2rδ): at r = 200 the
      # 0.005 mm half-step of `Geometry::PRECISION` measured 1.37 mm of drawn error, in a payload
      # whose own `p` points are good to 0.005 mm. A slot end cap is exactly that arc, and it is
      # the commonest arc in a laser or CNC DXF.
      #
      # SO THIS RESOLVES THE DESCRIPTOR BACK THE WAY A RENDERER DOES — the client's centre → `A`
      # endpoints, then SVG F.6.5's endpoints → centre — and asks the resulting curve the two
      # questions the rest of the payload already answers: does it pass through the shape's own
      # points, and does it reach the shape's own bbox.
      test "a half-turn arc's descriptor draws the curve its own points and bbox describe" do
        [ 0.0, 19.0, 23.4949, 137.5, 271.3 ].each do |a0|
          sh = build(arc_dxf(cx: -1.111, cy: 2.019, r: 200, a0:, a1: (a0 + 180) % 360))["shapes"].first
          arc = resolved_arc(sh["g"])

          worst = sh["p"].map { |(x, y)| distance_to_arc(x, y, arc) }.max
          assert_operator worst, :<=, 0.01,
                          "a0=#{a0}: the drawn arc strays #{worst.round(4)} mm from the shape's own points"

          # ONE-SIDED, ON PURPOSE. `b` is the bbox of the FLATTENED points, so it sits up to a
          # chord's sagitta INSIDE the true arc's — the drawn arc must CONTAIN it and cannot be
          # asked to match it. Containment is the direction the defect broke: the displaced centre
          # pulled the drawn arc 1.27 mm inside the bbox the same shape reports.
          box = arc_bbox(arc)
          [ [ box[0], :<=, sh["b"][0] + 0.01, "left" ], [ box[1], :<=, sh["b"][1] + 0.01, "top" ],
            [ box[2], :>=, sh["b"][2] - 0.01, "right" ], [ box[3], :>=, sh["b"][3] - 0.01, "bottom" ]
          ].each do |(got, op, want, edge)|
            assert_operator got, op, want, "a0=#{a0}: the drawn arc falls short of b's #{edge} edge"
          end
        end
      end

      # THE LARGE-ARC FLAG IS NO LONGER ON THE WIRE — lib/shape_svg.js derives it from |delta|,
      # which is the only place it can be derived once the endpoints are the client's to compute.
      # What the server owes it is a delta whose MAGNITUDE is the true sweep, so that is what this
      # asserts; measure_export_test.rb pins the flag the client writes from it.
      test "an arc sweeping more than half a turn carries the full sweep in delta" do
        payload = build(arc_dxf(cx: 0, cy: 0, r: 10, a0: 0, a1: 270))

        assert_equal(-270.0, payload["shapes"].first["g"][5])
      end

      # THE CASE THAT WOULD DRAW NOTHING. `Dxf.arc_points` turns a0 == a1 into a 360-degree sweep
      # ("the whole circle, not a zero-length arc" — its own comment), whose start and end points
      # are IDENTICAL. SVG's rule for an arc whose endpoints coincide is to omit the segment
      # ENTIRELY, so encoding it as an arc exports an empty path: no error, nothing logged, a shape
      # that is simply absent from the file. The honest encoding is an ellipse.
      #
      test "a full-circle ARC is encoded as an ellipse, not a degenerate arc" do
        payload = build(arc_dxf(cx: 0, cy: 0, r: 7, a0: 45, a1: 45))

        assert_equal [ "e", 0.0, 0.0, 7.0, 7.0 ], payload["shapes"].first["g"]
      end

      # THE SAME DEFECT, ON THE THUMBNAIL — tinkerex#215. The payload has answered this correctly
      # since the `g` descriptor shipped; `Dxf.arc_svg` went on writing one `A` command whose start
      # and end points it had just computed from the SAME angle, so the browser and resvg both
      # dropped the segment and the circle was absent from the picture. Nothing went red, because
      # a thumbnail is a PNG nobody asserts the contents of and no fixture held a full-turn ARC.
      #
      # THE SECOND ASSERTION IS THE ONE THAT GENERALISES, and it is not a restatement of the first.
      # A fix that emitted a circle AND left the dead path behind would satisfy an `assert_includes`
      # while still writing a segment no renderer draws; this asks the stronger question — that no
      # `A` command in the file ends where it began — which is the defect's actual shape and would
      # catch it on any arc, not just this fixture's.
      test "a full-circle ARC draws a circle in the thumbnail, not an arc that renders as nothing" do
        svg = Dxf.to_svg(fixture("entities.dxf"))

        assert_includes svg, %(<circle cx="120" cy="0" r="10" fill="none"),
                        "the entities.dxf full-turn ARC must draw as a circle"
        assert_empty degenerate_arc_paths(svg),
                     "an `A` command whose endpoints coincide is omitted by SVG — it draws nothing"
      end

      # An LWPOLYLINE has no exact primitive to offer, and a payload key present on every shape
      # would be bytes for nothing on exactly the densest files.
      test "a polyline carries no descriptor" do
        dxf = "0\nSECTION\n2\nENTITIES\n0\nLWPOLYLINE\n8\nA\n90\n3\n10\n0\n20\n0\n10\n10\n20\n0\n" \
              "10\n10\n20\n10\n0\nENDSEC\n0\nEOF\n"

        assert_not build(dxf)["shapes"].first.key?("g")
      end

      # ---- polyline bulges --------------------------------------------------------------------

      # A BULGE IS AN ARC SEGMENT RECORDED ON A VERTEX, AND READING ONLY THE COORDINATES DRAWS ITS
      # CHORD. That is a wrong picture, and — because an arc bulging outward reaches past the chord
      # it replaces — an UNDER-REPORTED bbox, which is the half that makes it a measurement bug.
      # 3,869 non-zero bulges across 26 of 129 real files (tinkerex#216).
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

      # THE SIGN IS LOAD-BEARING, AND DROPPING IT STILL DRAWS A PLAUSIBLE PICTURE — an arc of the
      # right radius spanning the right chord, on the WRONG SIDE. It has the same EXTENT as the
      # test above, so only WHERE the box sits tells the two apart: `|b|` passes every assertion up
      # there and fails both of these. `b` is [min_x, min_y, max_x, max_y] in the client's Y-down
      # space, so a positive (counter-clockwise) bulge lands BELOW the chord and this one ABOVE.
      test "a negative bulge arcs to the other side of the chord" do
        dxf = "0\nSECTION\n2\nENTITIES\n0\nPOLYLINE\n8\nA\n70\n0\n" \
              "0\nVERTEX\n8\nA\n10\n0\n20\n0\n42\n-1.0\n" \
              "0\nVERTEX\n8\nA\n10\n10\n20\n0\n" \
              "0\nSEQEND\n0\nENDSEC\n0\nEOF\n"
        b = build(dxf)["shapes"].first["b"]

        assert_in_delta(-5.0, b[1], 0.05, "the arc must reach 5 mm on the far side of the chord")
        assert_in_delta 0.0, b[3], 0.05, "and must not cross to the side a positive bulge takes"
      end

      # A BULGE ON THE LAST VERTEX OF A CLOSED POLYLINE DESCRIBES THE LAST→FIRST SEGMENT, which a
      # loop over consecutive pairs never visits. A slot — two straight sides and two semicircular
      # ends — is the commonest bulged contour in a laser DXF, and one of its two ends is exactly
      # this segment. Both bulges here, so the contour is a full circle and a missing closing arc
      # halves the height while leaving a perfectly plausible D-shape on screen.
      test "a closed polyline's last-to-first segment honours its bulge" do
        dxf = "0\nSECTION\n2\nENTITIES\n0\nPOLYLINE\n8\nA\n70\n1\n" \
              "0\nVERTEX\n8\nA\n10\n0\n20\n0\n42\n1.0\n" \
              "0\nVERTEX\n8\nA\n10\n10\n20\n0\n42\n1.0\n" \
              "0\nSEQEND\n0\nENDSEC\n0\nEOF\n"
        shape = build(dxf)["shapes"].first

        assert_in_delta 10.0, (shape["b"][2] - shape["b"][0]), 0.05, "the chord spans the diameter"
        assert_in_delta 10.0, (shape["b"][3] - shape["b"][1]), 0.05,
                        "and the two semicircles close into a circle as tall as it is wide"
        assert_equal 1, shape["k"], "the contour is still closed"
      end

      # A DEGENERATE BULGE DRAWS ITS CHORD RATHER THAN A SHAPE THE SIZE OF A SOLAR SYSTEM.
      # r = c / (2·sin(Δθ/2)) blows up as the included angle approaches EITHER zero or a full turn,
      # so a rounding artefact and a malformed value are the SAME defect from opposite ends: both
      # put the arc's centre astronomically far from its chord, where the sampled points come out
      # of catastrophic cancellation. A job box is a UNION, so one such vertex takes the whole
      # file's reported size with it — silently, and on a file that is otherwise fine. Drawing the
      # chord is what this renderer did for both cases before bulges existed.
      test "a bulge whose arc radius dwarfs its chord falls back to the chord" do
        %w[1e-20 -1e-20 1e20 -1e20].each do |bulge|
          dxf = "0\nSECTION\n2\nENTITIES\n0\nPOLYLINE\n8\nA\n70\n0\n" \
                "0\nVERTEX\n8\nA\n10\n0\n20\n0\n42\n#{bulge}\n" \
                "0\nVERTEX\n8\nA\n10\n10\n20\n0\n" \
                "0\nSEQEND\n0\nENDSEC\n0\nEOF\n"
          job = build(dxf)["job"]

          assert_in_delta 10.0, job["w"], 0.01, "bulge #{bulge}: the chord is 10 mm long"
          assert_in_delta 0.0, job["h"], 0.01, "bulge #{bulge}: and it is dead straight"
        end
      end

      # LWPOLYLINE BULGES ARE COUNTED, NOT DRAWN, AND THE ASYMMETRY IS THE PARSER'S SHAPE RATHER
      # THAN AN OVERSIGHT. `parse_entities` groups an entity's values BY CODE, so an LWPOLYLINE's
      # optional-per-vertex `42` cannot be paired with the vertex it belongs to — the interleaving
      # that says which is gone by then. A VERTEX record has its own codes hash, so its bulge is
      # unambiguous. Zero of the corpus's 3,869 bulges are on an LWPOLYLINE, so this is the honest
      # way to leave the half that would cost a parser rewrite unimplemented (tinkerex#216).
      test "an LWPOLYLINE bulge is reported rather than silently chorded" do
        dxf = "0\nSECTION\n2\nENTITIES\n0\nLWPOLYLINE\n8\nA\n90\n2\n70\n0\n" \
              "10\n0\n20\n0\n42\n1.0\n10\n10\n20\n0\n0\nENDSEC\n0\nEOF\n"
        payload = build(dxf)

        assert_equal 1, payload["shapes"].length, "the contour still draws"
        assert_in_delta 0.0, (payload["shapes"].first["b"][3] - payload["shapes"].first["b"][1]),
                        0.05, "as its chord — which is precisely what the tally is admitting to"
        assert_equal({ "LWPOLYLINE(bulge)" => 1 }, payload["u"])
      end

      # CODE 42 IS NOT "BULGE" — IT IS "THE 42nd THING THIS RECORD TYPE DECLARES", so the tally has
      # to ask what the entity IS and not merely which codes it carries. Measured on the corpus,
      # `cards.dxf` holds 3,308 SPLINE `42`s (a control-point tolerance) beside `42`s on VPORT,
      # STYLE and VISUALSTYLE records. None of those are drawable TODAY, which is exactly why this
      # is pinned now: the moment SPLINE joins `ENTITY_TYPES` a code-keyed check would report 3,308
      # unreadable things about a file containing no bulge at all.
      test "code 42 on an entity that is not an LWPOLYLINE is not a bulge" do
        dxf = "0\nSECTION\n2\nENTITIES\n0\nCIRCLE\n8\nA\n10\n0\n20\n0\n40\n5\n42\n1.0\n" \
              "0\nENDSEC\n0\nEOF\n"
        payload = build(dxf)

        assert_equal 1, payload["shapes"].length
        assert_not payload.key?("u")
      end

      # A ZERO `42` IS THE ORDINARY CASE AND CLAIMS NOTHING. Real exporters write a bulge of 0 on
      # every straight vertex, so a tally keyed on the code's PRESENCE would report most of the
      # corpus's LWPOLYLINEs as partly unreadable while drawing them perfectly.
      test "a zero LWPOLYLINE bulge is not a report of anything" do
        dxf = "0\nSECTION\n2\nENTITIES\n0\nLWPOLYLINE\n8\nA\n90\n2\n70\n0\n" \
              "10\n0\n20\n0\n42\n0.0\n10\n10\n20\n0\n42\n0\n0\nENDSEC\n0\nEOF\n"
        payload = build(dxf)

        assert_equal 1, payload["shapes"].length
        assert_not payload.key?("u")
      end

      # ---- splines ----------------------------------------------------------------------------

      # A SPLINE WAS NOT IN `ENTITY_TYPES`, SO `flatten` RETURNED NIL AND EVERY ONE OF THEM WAS
      # DROPPED — 18,906 across 29 of 129 real files, and a dropped entity is absent from the BBOX
      # as well as the picture. `elianadxf.dxf` is four splines and nothing else and reported
      # "No measurable geometry" about a file that is entirely geometry (tinkerex#216).
      #
      # THE BBOX AND A SAMPLED POINT, NEVER THE POINT COUNT. A count assertion is satisfied by a
      # curve of the wrong shape, which is the failure mode that matters here: de Boor evaluated
      # against the wrong knot span still emits exactly as many points.
      #
      # A CLAMPED CUBIC OVER FOUR CONTROL POINTS AND KNOTS [0,0,0,0,1,1,1,1] IS EXACTLY A CUBIC
      # BEZIER, which is what makes this hand-computable rather than copied out of the code under
      # test: the apex is at t = 0.5, (P0 + 3P1 + 3P2 + P3)/8 = (5, 7.5). Note 7.5 and not 10 — a
      # B-spline INTERPOLATES neither of its interior control points, so an implementation that
      # drew the control POLYGON would report a height of 10 and look entirely plausible.
      test "a SPLINE is evaluated over its knot vector rather than dropped" do
        shape = build(spline_dxf(points: ARCH, knots: ONE_SPAN))["shapes"].first

        assert_in_delta 0.0, shape["b"][0], 0.01
        assert_in_delta 10.0, shape["b"][2], 0.01
        assert_in_delta(-7.5, shape["b"][1], 0.01,
                        "the curve reaches 7.5 above its chord — the control polygon's 10 is not it")
        assert_in_delta 0.0, shape["b"][3], 0.01
        assert sampled?(shape, 5.0, -7.5), "the apex (5, 7.5), Y-flipped, must be on the curve"
      end

      # THE SPAN SEARCH IS WHAT MAKES A SPLINE A SPLINE RATHER THAN ONE POLYNOMIAL. Knots
      # [0,0,0,0,1,1,1,2,2,2,2] join two cubic Beziers at u = 1: P0..P3 then P3..P6. Evaluating
      # the second span's parameters against the FIRST span's control points extrapolates the
      # first polynomial past its domain — at u = 2 that is x = −40, a bbox nothing else in the
      # payload could disagree with. 3,308 of `cards.dxf`'s splines carry exactly this knot
      # pattern, up to 52 spans each.
      test "each knot span is evaluated against its own control points" do
        shape = build(spline_dxf(points: TWO_ARCHES, knots: TWO_SPANS))["shapes"].first

        assert_in_delta 0.0, shape["b"][0], 0.01, "the curve starts at x = 0"
        assert_in_delta 20.0, shape["b"][2], 0.01, "and ends at x = 20, having never left [0, 20]"
        assert_in_delta(-7.5, shape["b"][1], 0.01, "the first span arches 7.5 up")
        assert_in_delta 15.0, shape["b"][3], 0.01, "and the second 15 down"
        assert sampled?(shape, 15.0, 15.0), "the second span's own apex (15, −15), Y-flipped"
      end

      # FLAG BIT 0 IS "CLOSED", AND IT CLOSES THE CONTOUR THE WAY `polyline_points` DOES — the
      # first point repeated as the last, so `Geometry.simplify` (which always keeps both ends)
      # cannot leave a closed outline a point short of its own shape. 551 of `cards.dxf`'s 3,308
      # splines set it.
      test "a closed SPLINE closes its contour" do
        shape = build(spline_dxf(points: ARCH, knots: ONE_SPAN, flags: 1))["shapes"].first

        assert_equal 1, shape["k"], "the contour is closed"
        assert_equal shape["p"].first, shape["p"].last, "so its last point is its first"
      end

      # WEIGHTS ARE HONOURED WHETHER OR NOT FLAG BIT 2 (RATIONAL) IS SET, and this test sets it
      # CLEAR on purpose. Measured across the 29 real files that carry splines, code 41 appears in
      # two families and the rational bit is never set in flag 70 — which normally means every
      # weight is 1.0, and every weight in the corpus IS 1.0. That is a fact about today's corpus,
      # not a property of the format, so the evaluation runs in homogeneous coordinates always and
      # this pins that it does: a weight of 3 on the two interior control points pulls the apex
      # from 7.5 to 9.0, and an implementation that read the flag instead of the weights would
      # draw 7.5 and look perfectly reasonable.
      test "SPLINE weights are honoured even where the rational flag is clear" do
        weighted = build(spline_dxf(points: ARCH, knots: ONE_SPAN, weights: [ 1, 3, 3, 1 ]))
        unit = build(spline_dxf(points: ARCH, knots: ONE_SPAN, weights: [ 1, 1, 1, 1 ]))

        assert_in_delta(-9.0, weighted["shapes"].first["b"][1], 0.01,
                        "w = 3 on both interior points pulls the apex to 9.0")
        assert sampled?(weighted["shapes"].first, 5.0, -9.0)
        assert_in_delta(-7.5, unit["shapes"].first["b"][1], 0.01,
                        "and the corpus's all-1.0 weights change nothing, which is why they were " \
                        "never a reason to skip the homogeneous path")
      end

      # A REFUSED SPLINE IS TALLIED UNDER ITS OWN NAME, AND THIS IS THE TRAP THE WHOLE BACKSTOP
      # EXISTS TO CLOSE. Stage 1's tally is TYPE-based — `parse_entities` counts a `0`-code name
      # that is not in `ENTITY_TYPES` — so the moment SPLINE joined that list, a spline `flatten`
      # refuses stopped being counted there and would have vanished exactly as before, with the
      # status line now actively stating that nothing was skipped. A DISTINCT NAME, because "we
      # cannot read this type at all" and "we read this one and it was broken" are different
      # claims and must not add up into one number.
      test "a SPLINE the parser refuses is tallied under its own name rather than vanishing" do
        {
          "a knot count that is not control points + degree + 1" =>
            spline_dxf(points: ARCH, knots: ONE_SPAN.first(7)),
          "fewer control points than the degree needs" =>
            spline_dxf(points: ARCH.first(3), knots: [ 0, 0, 0, 0, 1, 1, 1 ]),
          "a degree below 1" =>
            spline_dxf(points: ARCH, knots: [ 0, 0, 1, 1, 2 ], degree: 0),
          "a knot vector that runs backwards" =>
            spline_dxf(points: ARCH, knots: [ 0, 0, 0, 0, 1, 1, 1, -1 ]),
          "a knot domain of zero width" =>
            spline_dxf(points: ARCH, knots: [ 0, 0, 0, 0, 0, 0, 0, 0 ])
        }.each do |why, dxf|
          payload = build(dxf)

          assert_equal [], payload["shapes"], "#{why}: must not draw a scribble"
          assert_equal({ "SPLINE(malformed)" => 1 }, payload["u"], "#{why}: must be said out loud")
        end
      end

      # THE OTHER DIRECTION, WITHOUT WHICH A TALLY THAT ALWAYS FIRES PASSES THE TEST ABOVE. A
      # spline this parser reads completely claims nothing — and it carries a code 42 while doing
      # so, because on a SPLINE 42 is a control-point tolerance and every one of `cards.dxf`'s
      # 3,308 splines has one. A tally keyed on the CODE rather than on the entity's TYPE would
      # report 3,308 unreadable "bulges" in a file that contains no bulge at all.
      test "a SPLINE the parser reads claims nothing, code 42 and all" do
        payload = build(spline_dxf(points: ARCH, knots: ONE_SPAN, extra: "42\n0.0000001\n"))

        assert_equal 1, payload["shapes"].length
        assert_not payload.key?("u")
      end

      # ---- blocks and inserts -----------------------------------------------------------------

      # THE FIX HAD TO REMOVE BEHAVIOUR, NOT ONLY ADD IT, WHICH IS WHY THIS ASSERTS THE COUNT.
      # `tokenize` returns every code/value pair in the file and `parse_entities` walked all of
      # them with no section filter, so a BLOCK's body was collected and drawn as a top-level shape
      # at its DEFINITION coordinates — while the INSERT that places it was not in `ENTITY_TYPES`
      # and was dropped. The net effect was never missing geometry: it was geometry in the WRONG
      # PLACE, drawn ONCE however many times the file places it. 1,094 INSERTs across 24 of 129
      # real files, 1,222 BLOCK definitions across 51 (tinkerex#219).
      #
      # A TEST ASSERTING ONLY "the inserted copy appears" PASSES WHILE THE GHOST STILL DRAWS. The
      # shape count is the only assertion that can see the half of the fix that deletes.
      test "a block draws at its INSERT, once, and not at its definition" do
        dxf = blocks_dxf({ "MYBLK" => "0\nLINE\n8\nA\n10\n0\n20\n0\n11\n10\n21\n0\n" },
                         "0\nINSERT\n8\nA\n2\nMYBLK\n10\n100\n20\n200\n")
        shapes = build(dxf)["shapes"]

        assert_equal 1, shapes.length, "once — not a ghost at the definition AND a copy at the insert"
        assert_in_delta 100.0, shapes.first["b"][0], 0.01
        assert_in_delta 110.0, shapes.first["b"][2], 0.01
        assert_in_delta(-200.0, shapes.first["b"][1], 0.01, "the Y-flip applies to the placed copy")
      end

      # A BLOCK NOBODY INSERTS DRAWS NOTHING, and that is the deletion stated on its own. It is
      # also the ordinary case rather than an edge one: `cards.dxf` defines 180 blocks and inserts
      # 177 of them, so three would draw at the origin for no reason at all.
      test "a block that is never inserted draws nothing" do
        dxf = blocks_dxf({ "UNUSED" => "0\nCIRCLE\n8\nA\n10\n0\n20\n0\n40\n5\n" }, "")

        assert_equal [], build(dxf)["shapes"]
        assert_not build(dxf).key?("u"), "an unplaced definition is not an unreadable entity"
      end

      # ONE INSERT, MANY COPIES — the property the old behaviour could not express at all. Two
      # INSERTs of one block are two shapes with their own object ids, because the client groups
      # and selects by that id and a user clicking the left copy must not highlight the right one.
      test "a block inserted twice draws twice, at both insertion points" do
        dxf = blocks_dxf({ "H" => "0\nLINE\n8\nA\n10\n0\n20\n0\n11\n4\n21\n0\n" },
                         "0\nINSERT\n8\nA\n2\nH\n10\n0\n20\n0\n" \
                         "0\nINSERT\n8\nA\n2\nH\n10\n50\n20\n0\n")
        shapes = build(dxf)["shapes"]

        assert_equal 2, shapes.length
        assert_equal [ 1, 2 ], shapes.map { |s| s["o"] }, "each placement is its own selectable object"
        assert_in_delta 0.0,  shapes[0]["b"][0], 0.01
        assert_in_delta 50.0, shapes[1]["b"][0], 0.01
      end

      # SCALE THEN ROTATE, IN THAT ORDER, AND THE FIXTURE IS CHOSEN SO THE ORDER SHOWS. The point
      # (10, 5) scaled by (2, 3) is (20, 15) and turning that a quarter turn CCW gives (-15, 20);
      # rotating FIRST would give (-10, 30) — a plausible drawing, the wrong part.
      #
      # 42 IS THE Y SCALE HERE AND HAS NOTHING TO DO WITH A BULGE. `tally_lwpolyline_bulge` keys on
      # the entity's TYPE for exactly this reason, and this fixture is the INSERT-shaped instance
      # of the trap the SPLINE tolerance already pins from the other side.
      test "an INSERT's scale and rotation transform the block, scale first" do
        dxf = blocks_dxf({ "L" => "0\nLINE\n8\nA\n10\n0\n20\n0\n11\n10\n21\n5\n" },
                         "0\nINSERT\n8\nA\n2\nL\n10\n0\n20\n0\n41\n2\n42\n3\n50\n90\n")
        payload = build(dxf)
        b = payload["shapes"].first["b"]

        assert_in_delta(-15.0, b[0], 0.01, "x runs from -15 to 0")
        assert_in_delta 0.0, b[2], 0.01
        assert_in_delta(-20.0, b[1], 0.01, "model y 0..20 is client y -20..0")
        assert_in_delta 0.0, b[3], 0.01
        assert_not payload.key?("u"), "code 42 on an INSERT is a scale factor, not a bulge"
      end

      # A NEGATIVE SCALE IS A MIRROR AND MUST NOT BE READ AS ITS MAGNITUDE — the same sign trap the
      # bulge work records, one entity type along. |sx| draws the block at the right size on the
      # wrong side of the insertion point, with a bbox of the identical WIDTH.
      test "a negative INSERT scale mirrors the block rather than scaling by its magnitude" do
        dxf = blocks_dxf({ "L" => "0\nLINE\n8\nA\n10\n1\n20\n0\n11\n10\n21\n0\n" },
                         "0\nINSERT\n8\nA\n2\nL\n10\n0\n20\n0\n41\n-1\n42\n1\n")
        b = build(dxf)["shapes"].first["b"]

        assert_in_delta(-10.0, b[0], 0.01, "the mirrored copy sits at negative x")
        assert_in_delta(-1.0, b[2], 0.01)
      end

      # THE BLOCK'S OWN BASE POINT IS SUBTRACTED BEFORE THE INSERT TRANSFORM — it is the block's
      # origin, not an offset to add. Getting it backwards puts every copy twice its base point
      # away from where the file says, which on a file whose bases are all zero (all 180 of
      # `cards.dxf`'s) is exactly zero evidence, hence a fixture with a non-zero one.
      test "a BLOCK's base point is the block's origin, subtracted before placement" do
        dxf = blocks_dxf({ "B" => "0\nLINE\n8\nA\n10\n5\n20\n5\n11\n15\n21\n5\n" },
                         "0\nINSERT\n8\nA\n2\nB\n10\n100\n20\n100\n", base: { "B" => [ 5, 5 ] })
        b = build(dxf)["shapes"].first["b"]

        assert_in_delta 100.0, b[0], 0.01
        assert_in_delta 110.0, b[2], 0.01
        assert_in_delta(-100.0, b[1], 0.01)
      end

      # NESTING COMPOSES THE WHOLE CHAIN, NOT JUST THE OUTERMOST STEP. 168 of `cards.dxf`'s 177
      # INSERTs are inside another block, four deep — so a renderer that honoured only the
      # top-level INSERT would place nine of its 8,148 contours and misplace the rest.
      #
      # THE OUTER TRANSFORM ROTATES, so applying the two translations in the wrong order is a
      # different answer rather than the same one: (5,0) → +(10,0) → turn → (0,15) → +(100,200).
      test "a nested INSERT composes the outer transform with the inner one" do
        dxf = blocks_dxf(
          { "INNER" => "0\nLINE\n8\nA\n10\n0\n20\n0\n11\n5\n21\n0\n",
            "OUTER" => "0\nINSERT\n8\nA\n2\nINNER\n10\n10\n20\n0\n" },
          "0\nINSERT\n8\nA\n2\nOUTER\n10\n100\n20\n200\n50\n90\n"
        )
        shapes = build(dxf)["shapes"]

        assert_equal 1, shapes.length, "the inner block draws once, through the outer one"
        assert_in_delta 100.0, shapes.first["b"][0], 0.01
        assert_in_delta 100.0, shapes.first["b"][2], 0.01
        assert_in_delta(-215.0, shapes.first["b"][1], 0.01)
        assert_in_delta(-210.0, shapes.first["b"][3], 0.01)
      end

      # A MINSERT IS AN ARRAY OF PLACEMENTS AND EACH CELL IS ITS OWN SHAPE. Zero occurrences in the
      # corpus, which is precisely why it is pinned: the codes are read whether or not a file has
      # ever used them, and `70`/`71` default to 1 rather than to 0.
      test "an INSERT's row and column counts place one copy per cell" do
        dxf = blocks_dxf({ "U" => "0\nLINE\n8\nA\n10\n0\n20\n0\n11\n1\n21\n0\n" },
                         "0\nINSERT\n8\nA\n2\nU\n10\n0\n20\n0\n70\n3\n71\n2\n44\n10\n45\n20\n")
        payload = build(dxf)

        assert_equal 6, payload["shapes"].length, "3 columns x 2 rows"
        assert_in_delta 21.0, payload["job"]["w"], 0.01, "two column steps of 10 plus the unit line"
        assert_in_delta 20.0, payload["job"]["h"], 0.01
      end

      # THE SECTION LABEL IS WHAT SCOPES THE REMOVAL, AND THE FAIL-SAFE DIRECTION IS DELIBERATE. A
      # `BLOCK` marker outside a labelled `BLOCKS` section defines nothing here, so its body still
      # draws where it always did. Keying on the BLOCK/ENDBLK markers ALONE would be enough for
      # every real file and would fail the other way: a stray marker in ENTITIES would swallow the
      # rest of the drawing into a definition nobody inserts — silent, total, and §14b's skip-list
      # blind spot exactly. A regression is bounded by yesterday's behaviour; a data loss is not.
      test "a BLOCK marker outside a labelled BLOCKS section still draws its body" do
        dxf = "0\nSECTION\n2\nENTITIES\n0\nBLOCK\n2\nSTRAY\n" \
              "0\nLINE\n8\nA\n10\n0\n20\n0\n11\n9\n21\n0\n0\nENDBLK\n" \
              "0\nCIRCLE\n8\nA\n10\n5\n20\n0\n40\n1\n0\nENDSEC\n0\nEOF\n"
        payload = build(dxf)

        assert_equal 2, payload["shapes"].length, "neither the body nor what follows it is lost"
        assert_in_delta 9.0, payload["job"]["w"], 0.01
      end

      # ---- an INSERT this parser refuses ------------------------------------------------------

      # EVERY REFUSAL IS TALLIED UNDER ITS OWN NAME, AND THE REASON IS THE TRAP THE SPLINE WORK
      # ALREADY PAID FOR ONCE. Stage 1's tally is TYPE-based — `parse_entities` counts a `0`-code
      # name that is not in `ENTITY_TYPES` — so adding INSERT to that list, which is what makes
      # blocks place at all, STOPS it reporting INSERT entirely. A refused insert would then vanish
      # in silence with the status line stating that nothing was skipped: the exact defect this
      # whole arc exists to close, re-opened by the fix for it.
      #
      # AN INSERT NAMING A BLOCK THE FILE DOES NOT DEFINE IS THE LIKELY REAL CASE — a file saved
      # without its dependencies, or a BLOCKS section this parser declined to read.
      test "an INSERT this parser cannot place is named and counted, never dropped" do
        {
          "INSERT(unknown-block)" =>
            blocks_dxf({ "A" => "0\nLINE\n8\nA\n10\n0\n20\n0\n11\n1\n21\n0\n" },
                       "0\nINSERT\n8\nA\n2\nNOPE\n10\n0\n20\n0\n"),
          "INSERT(cyclic)" =>
            blocks_dxf({ "SELF" => "0\nINSERT\n8\nA\n2\nSELF\n10\n1\n20\n0\n" },
                       "0\nINSERT\n8\nA\n2\nSELF\n10\n0\n20\n0\n"),
          "INSERT(too-deep)" => deep_insert_chain(Dxf::MAX_INSERT_DEPTH + 1),
          "INSERT(too-many)" =>
            blocks_dxf({ "A" => "0\nLINE\n8\nA\n10\n0\n20\n0\n11\n1\n21\n0\n" },
                       "0\nINSERT\n8\nA\n2\nA\n10\n0\n20\n0\n70\n99999\n71\n99999\n")
        }.each do |name, dxf|
          payload = build(dxf)

          assert_equal({ name => 1 }, payload["u"], "#{name}: must be said out loud")
          assert_equal [], payload["shapes"], "#{name}: and must not half-draw"
        end
      end

      # THE OTHER DIRECTION, WITHOUT WHICH A TALLY THAT ALWAYS FIRES PASSES THE TEST ABOVE — and
      # the case that matters most, since a nested INSERT is 168 of `cards.dxf`'s 177. Nesting
      # inside the cap claims nothing at all.
      test "an INSERT this parser places claims nothing" do
        payload = build(deep_insert_chain(Dxf::MAX_INSERT_DEPTH))

        assert_equal 1, payload["shapes"].length
        assert_not payload.key?("u")
      end

      # A SELF-REFERENCING BLOCK IS MALFORMED INPUT AND MUST NOT HANG THE RENDERER — the reason the
      # recursion carries a stack at all. What it must ALSO not do is lose the geometry beside the
      # cycle, which a bare `return` at the top of the expansion would.
      test "a cyclic block still draws what is not the cycle" do
        dxf = blocks_dxf({ "SELF" => "0\nLINE\n8\nA\n10\n0\n20\n0\n11\n7\n21\n0\n" \
                                     "0\nINSERT\n8\nA\n2\nSELF\n10\n1\n20\n0\n" },
                         "0\nINSERT\n8\nA\n2\nSELF\n10\n0\n20\n0\n")
        payload = build(dxf)

        assert_equal 1, payload["shapes"].length, "the LINE beside the cycle still draws"
        assert_in_delta 7.0, payload["job"]["w"], 0.01
        assert_equal({ "INSERT(cyclic)" => 1 }, payload["u"])
      end

      # A BLOCK REACHED TWICE BY TWO DIFFERENT PARENTS IS NOT A CYCLE, and the difference is why
      # the guard is the recursion's own PATH rather than a set of every block ever visited. A
      # global set draws the first placement and silently drops every later one — the same class of
      # loss as the ghost this stage removes, arriving through the guard that was meant to prevent
      # a hang.
      test "a block reached by two different parents draws under both" do
        dxf = blocks_dxf(
          { "LEAF"  => "0\nLINE\n8\nA\n10\n0\n20\n0\n11\n2\n21\n0\n",
            "LEFT"  => "0\nINSERT\n8\nA\n2\nLEAF\n10\n0\n20\n0\n",
            "RIGHT" => "0\nINSERT\n8\nA\n2\nLEAF\n10\n0\n20\n0\n" },
          "0\nINSERT\n8\nA\n2\nLEFT\n10\n0\n20\n0\n0\nINSERT\n8\nA\n2\nRIGHT\n10\n100\n20\n0\n"
        )
        payload = build(dxf)

        assert_equal 2, payload["shapes"].length
        assert_not payload.key?("u")
      end

      # ---- a placed curve keeps its descriptor, or honestly loses it --------------------------

      # A SIMILARITY MAPS A CIRCLE TO A CIRCLE, so the exact primitive survives the placement and
      # the thumbnail stays crisp. `g` is a RICHER RENDERING OF THE SAME POINTS, so it has to be
      # transformed by the same affine the points are or it describes a different shape from the
      # bbox beside it.
      test "a CIRCLE inside a uniformly scaled INSERT keeps its exact descriptor" do
        dxf = blocks_dxf({ "C" => "0\nCIRCLE\n8\nA\n10\n0\n20\n0\n40\n2\n" },
                         "0\nINSERT\n8\nA\n2\nC\n10\n50\n20\n60\n41\n3\n42\n3\n50\n45\n")
        shape = build(dxf)["shapes"].first

        assert_equal [ "e", 50.0, -60.0, 6.0, 6.0 ], shape["g"]
        assert_in_delta 12.0, shape["d"], 0.02, "and the measured diameter agrees with it"
      end

      # A NON-UNIFORM SCALE TURNS A CIRCLE INTO AN ELLIPSE THE WIRE CANNOT SPELL — its `e` form
      # carries rx and ry but no rotation, so a stretched-then-turned circle has no honest
      # descriptor. DROPPING IT IS ALWAYS SAFE and keeping it never is: the thumbnail draws the
      # descriptor INSTEAD of the points, so a wrong one is a wrong picture, while an absent one
      # falls back to the flattened points the bbox was computed from.
      test "a CIRCLE inside a non-uniformly scaled INSERT drops its descriptor, not its shape" do
        dxf = blocks_dxf({ "C" => "0\nCIRCLE\n8\nA\n10\n0\n20\n0\n40\n2\n" },
                         "0\nINSERT\n8\nA\n2\nC\n10\n0\n20\n0\n41\n3\n42\n1\n")
        payload = build(dxf)

        assert_not payload["shapes"].first.key?("g"), "no `e` can describe a rotated ellipse"
        assert_in_delta 12.0, payload["job"]["w"], 0.05, "but the points still measure the stretch"
        assert_in_delta 4.0, payload["job"]["h"], 0.05
      end

      # AN ARC CARRIES A START ANGLE AND A DIRECTION, AND A MIRROR REVERSES BOTH. DXF arcs always
      # sweep CCW from a0 to a1, so under a negative determinant the placed arc's CCW run starts
      # where the original ENDED — leaving a0 alone draws the complementary arc: same endpoints,
      # wrong side, and the thumbnail draws the descriptor rather than the points.
      #
      # RESOLVED THE WAY A RENDERER DOES, for `"a half-turn arc's descriptor..."`'s reason: the
      # question is whether the drawn curve passes through the shape's own points, not whether five
      # numbers look plausible.
      test "an ARC inside a mirrored INSERT keeps a descriptor that matches its own points" do
        [ [ 1, 1, 0 ], [ -1, 1, 0 ], [ 1, -1, 0 ], [ -1, -1, 0 ],
          [ 1, 1, 37 ], [ -1, 1, 37 ], [ 2, 2, 118 ], [ -2, 2, 118 ] ].each do |(sx, sy, rot)|
          dxf = blocks_dxf({ "A" => "0\nARC\n8\nA\n10\n3\n20\n1\n40\n10\n50\n20\n51\n200\n" },
                           "0\nINSERT\n8\nA\n2\nA\n10\n7\n20\n11\n41\n#{sx}\n42\n#{sy}\n50\n#{rot}\n")
          sh = build(dxf)["shapes"].first
          why = "sx=#{sx} sy=#{sy} rot=#{rot}"

          assert_equal "a", sh["g"].first, "#{why}: a similarity maps an arc to an arc"
          worst = sh["p"].map { |(x, y)| distance_to_arc(x, y, resolved_arc(sh["g"])) }.max
          assert_operator worst, :<=, 0.02,
                          "#{why}: the drawn arc strays #{worst.round(4)} mm from the shape's own points"
        end
      end

      # ---- what the parser could not read -----------------------------------------------------

      # THE BACKSTOP ITSELF. `Dxf.flatten` is a `case` with no `else`, so for years every entity
      # type this parser cannot draw returned nil and `each_geometry` skipped it with no error, no
      # log and no status — 18,906 SPLINEs across 29 of 129 real files, one of which reported "No
      # measurable geometry" about a file that is nothing but geometry (tinkerex#216).
      #
      # THE TYPES HERE WERE SPLINEs UNTIL SPLINE BECAME DRAWABLE, and swapping them is the point
      # rather than a repair: a type promoted into `ENTITY_TYPES` leaves this path entirely, which
      # is exactly the trap `tally_refusal` exists for. ELLIPSE and MTEXT are the corpus's real
      # remaining gaps — 0 and 13 occurrences — and are deliberately out of scope, so this keeps
      # asking about the TYPE-based tally and nothing else.
      test "an entity type the parser cannot draw is reported rather than dropped" do
        dxf = "0\nSECTION\n2\nENTITIES\n0\nELLIPSE\n8\nA\n0\nMTEXT\n8\nA\n0\nELLIPSE\n8\nA\n" \
              "0\nLINE\n8\nA\n10\n0\n20\n0\n11\n5\n21\n0\n0\nENDSEC\n0\nEOF\n"
        payload = build(dxf)

        assert_equal 1, payload["shapes"].length, "the LINE still draws"
        assert_equal({ "ELLIPSE" => 2, "MTEXT" => 1 }, payload["u"],
                     "and what could not be drawn is named and counted")
      end

      # A SKIPPED ENTITY IS ABSENT FROM THE BBOX, NOT MERELY FROM THE PICTURE — which is the half
      # that makes this a measurement bug rather than a cosmetic one. `elianadxf.dxf` was four
      # SPLINEs and nothing else: shapes=0, job 0x0, a reported job size describing none of the
      # file. It measures now; what this pins is that the SAME scenario one step further on — a
      # file of nothing but splines this parser REFUSES — still reaches the wire, under
      # `tally_refusal`'s name rather than `parse_entities`', and still reports an empty job box
      # rather than a made-up one. Bare SPLINE records with no knots and no control points are
      # exactly that.
      test "a file whose every entity is unreadable says so instead of measuring as empty" do
        payload = build("0\nSECTION\n2\nENTITIES\n0\nSPLINE\n8\nA\n0\nSPLINE\n8\nA\n0\nENDSEC\n0\nEOF\n")

        assert_equal [], payload["shapes"]
        assert_equal({ "w" => 0.0, "h" => 0.0, "x" => 0.0, "y" => 0.0 }, payload["job"],
                     "the job box is still honestly empty — the tally is what makes it legible"
        )
        assert_equal({ "SPLINE(malformed)" => 2 }, payload["u"])
      end

      # THE OTHER DIRECTION, AND IT IS THE ONE A NAIVE TALLY GETS WRONG. `parse_entities` has no
      # section filter, so the TABLES and OBJECTS sections' records arrive on the same `0`-code
      # stream as the entities. A real file carries 33 LAYERs, 16 VISUALSTYLEs and 180
      # BLOCK_RECORDs; reporting those as geometry we failed to draw is a lie about the file, and a
      # noisier one than the silence this replaced.
      test "structural markers and table records are not geometry and are never tallied" do
        dxf = "0\nSECTION\n2\nTABLES\n0\nTABLE\n2\nLAYER\n0\nLAYER\n2\nCut\n62\n1\n0\nENDTAB\n" \
              "0\nTABLE\n2\nLTYPE\n0\nLTYPE\n2\nCONTINUOUS\n0\nENDTAB\n0\nENDSEC\n" \
              "0\nSECTION\n2\nBLOCKS\n0\nBLOCK\n2\nB\n0\nENDBLK\n0\nENDSEC\n" \
              "0\nSECTION\n2\nENTITIES\n0\nPOLYLINE\n8\nCut\n70\n0\n" \
              "0\nVERTEX\n8\nCut\n10\n0\n20\n0\n0\nVERTEX\n8\nCut\n10\n5\n20\n0\n0\nSEQEND\n" \
              "0\nENDSEC\n0\nSECTION\n2\nOBJECTS\n0\nDICTIONARY\n0\nENDSEC\n0\nEOF\n"
        payload = build(dxf)

        assert_equal 1, payload["shapes"].length, "the POLYLINE still draws"
        assert_not payload.key?("u"), "nothing here is unreadable geometry, so nothing is claimed"
      end

      # VERTEX IS THE TRAP INSIDE THE TRAP. It is not in ENTITY_TYPES and is not a structural
      # marker either — it is a drawable POLYLINE's own points, reclaimed by
      # fold_polyline_vertices. Counting it turns the commonest entity in this corpus into a
      # report of 10,792 unreadable things on a file that renders perfectly.
      test "a POLYLINE's VERTEX records are its points, not unreadable entities" do
        dxf = "0\nSECTION\n2\nENTITIES\n0\nPOLYLINE\n8\nA\n70\n0\n" \
              "0\nVERTEX\n8\nA\n10\n0\n20\n0\n0\nVERTEX\n8\nA\n10\n5\n20\n0\n" \
              "0\nVERTEX\n8\nA\n10\n5\n20\n5\n0\nSEQEND\n0\nENDSEC\n0\nEOF\n"
        payload = build(dxf)

        assert_equal 3, payload["shapes"].first["p"].length, "the vertices became the polyline"
        assert_not payload.key?("u")
      end

      # The tally must not disturb what the traversal DRAWS — an unreadable entity between two
      # drawable ones cannot be allowed to break the POLYLINE/VERTEX fold or shift an object id.
      test "an unreadable entity between drawable ones changes neither" do
        dxf = "0\nSECTION\n2\nENTITIES\n" \
              "0\nLINE\n8\nA\n10\n0\n20\n0\n11\n5\n21\n0\n" \
              "0\nMTEXT\n8\nA\n1\nhello\n" \
              "0\nCIRCLE\n8\nA\n10\n0\n20\n0\n40\n3\n0\nENDSEC\n0\nEOF\n"
        payload = build(dxf)

        assert_equal [ 1, 2 ], payload["shapes"].map { |s| s["o"] }, "ids count DRAWN entities only"
        assert_equal({ "MTEXT" => 1 }, payload["u"])
      end

      # ---- documents ------------------------------------------------------------------------

      test "a DXF with no drawable entities returns the honest empty payload" do
        payload = build("0\nSECTION\n2\nENTITIES\n0\nENDSEC\n0\nEOF\n")

        assert_equal [], payload["shapes"]
        assert_equal({ "w" => 0.0, "h" => 0.0, "x" => 0.0, "y" => 0.0 }, payload["job"])
      end

      # DXF has no root element to check, so unlike SVG and LightBurn there is nothing here that
      # can honestly be called corrupt — a file with no recognisable group codes is simply a file
      # with no entities. Stated as a test so the asymmetry is deliberate rather than an omission.
      test "unparseable bytes measure as empty rather than raising" do
        assert_equal [], build("this is not a DXF at all")["shapes"]
      end

      test "render returns JSON bytes the job can attach" do
        result = DxfGeometry.render(fixture("plate.dxf"))

        assert_equal "application/json", result[:content_type]
        assert_equal 2, JSON.parse(result[:bytes])["shapes"].length
      end

      private

      # Counts calls to one of `Dxf`'s own module functions while the block runs, and returns the
      # count. HAND-ROLLED, NOT Object#stub: minitest 6 dropped minitest/mock, so `stub` is a
      # LoadError in this suite — the same reason `lbrn2_test.rb` and `test_helper.rb` count this
      # way. `module_function` puts the real implementation on the singleton class, so redefining
      # it there intercepts BOTH spellings: an external `Dxf.tokenize(...)` and the implicit-self
      # `tokenize(...)` inside `to_svg`, which dispatches to the same singleton method.
      def counting(name)
        calls = 0
        mod = Dxf.singleton_class
        original = mod.instance_method(name)
        mod.define_method(name) { |*args| calls += 1; original.bind(self).call(*args) }

        begin
          yield
        ensure
          mod.define_method(name, original)
        end

        calls
      end

      # A CUBIC BEZIER SPELLED AS A B-SPLINE, and the fixtures every spline test measures against.
      # Clamped knots (multiplicity degree+1 at each end) over four control points make the curve
      # exactly Bezier(P0..P3), so its apex is (P0 + 3P1 + 3P2 + P3)/8 = (5, 7.5) by hand rather
      # than by running the code under test. TWO_SPANS adds an interior knot of multiplicity 3 —
      # the pattern 3,308 of `cards.dxf`'s splines use — which joins a second Bezier, P3..P6,
      # apex (15, -15).
      ARCH = [ [ 0, 0 ], [ 0, 10 ], [ 10, 10 ], [ 10, 0 ] ].freeze
      ONE_SPAN = [ 0, 0, 0, 0, 1, 1, 1, 1 ].freeze
      TWO_ARCHES = (ARCH + [ [ 10, -20 ], [ 20, -20 ], [ 20, 0 ] ]).freeze
      TWO_SPANS = [ 0, 0, 0, 0, 1, 1, 1, 2, 2, 2, 2 ].freeze

      # A SPLINE record, in the group-code order a real exporter writes: the counts, then the knot
      # run, then the optional weight run, then the control points. `parse_entities` groups by code
      # so the order cannot matter to the parser — which is exactly why it is worth writing the
      # real one here, where a reader can check the fixture against a file.
      def spline_dxf(points:, knots:, degree: 3, flags: 0, weights: nil, extra: "")
        body = +"0\nSECTION\n2\nENTITIES\n0\nSPLINE\n8\nA\n70\n#{flags}\n71\n#{degree}\n" \
                "72\n#{knots.length}\n73\n#{points.length}\n74\n0\n#{extra}"
        knots.each { |k| body << "40\n#{k}\n" }
        weights&.each { |w| body << "41\n#{w}\n" }
        points.each { |(x, y)| body << "10\n#{x}\n20\n#{y}\n30\n0.0\n" }
        body + "0\nENDSEC\n0\nEOF\n"
      end

      # Is a point ON the drawn curve? Asked of the THINNED `p` deliberately: an apex is by
      # construction the point farthest from any chord spanning it, so `Geometry.simplify` keeps
      # it, and asking the payload rather than the traversal means this fails if either half stops
      # carrying the shape.
      def sampled?(shape, x, y)
        shape["p"].any? { |(px, py)| (px - x).abs < 0.05 && (py - y).abs < 0.05 }
      end

      # A DXF WITH A REAL BLOCKS SECTION, because the whole defect is that this parser had no
      # section filter — a fixture that skipped the `2\nBLOCKS` label would be testing a document
      # shape the bug never had. `bodies` is name => the block's entity records verbatim, `entities`
      # is the ENTITIES section's, and `base:` gives a block the non-zero base point real files
      # mostly do not have.
      def blocks_dxf(bodies, entities, base: {})
        out = +"0\nSECTION\n2\nBLOCKS\n"
        bodies.each do |name, body|
          bx, by = base[name] || [ 0, 0 ]
          out << "0\nBLOCK\n8\nA\n2\n#{name}\n70\n0\n10\n#{bx}\n20\n#{by}\n30\n0\n3\n#{name}\n"
          out << body << "0\nENDBLK\n8\nA\n"
        end
        out << "0\nENDSEC\n0\nSECTION\n2\nENTITIES\n" << entities << "0\nENDSEC\n0\nEOF\n"
      end

      # `links` INSERTs chained one inside the next, with a LINE at the bottom. Generated rather
      # than written out so the fixture is expressed in terms of `Dxf::MAX_INSERT_DEPTH` and cannot
      # drift away from the cap it is asking about.
      def deep_insert_chain(links)
        bodies = (1...links).each_with_object({}) do |i, h|
          h["B#{i}"] = "0\nINSERT\n8\nA\n2\nB#{i + 1}\n10\n1\n20\n0\n"
        end
        bodies["B#{links}"] = "0\nLINE\n8\nA\n10\n0\n20\n0\n11\n1\n21\n0\n"
        blocks_dxf(bodies, "0\nINSERT\n8\nA\n2\nB1\n10\n0\n20\n0\n")
      end

      # Every `<path>` in the SVG whose single `A` command ends exactly where its `M` began — the
      # form SVG resolves by omitting the segment. Read off the emitted string rather than
      # recomputed from the descriptor, because the defect is in what `arc_svg` WRITES.
      def degenerate_arc_paths(svg)
        svg.scan(/<path d="M (\S+) (\S+) A [\d.\- ]+ (\S+) (\S+)"/)
           .select { |(sx, sy, ex, ey)| [ sx, sy ] == [ ex, ey ] }
      end

      def build(bytes) = JSON.parse(DxfGeometry.render(bytes)[:bytes])

      def fixture(name) = File.binread(Rails.root.join("test/fixtures/files", name))

      def circle_dxf(radius:, insunits:, cx: 0, cy: 0)
        header = insunits ? "0\nSECTION\n2\nHEADER\n9\n$INSUNITS\n70\n#{insunits}\n0\nENDSEC\n" : ""
        header + "0\nSECTION\n2\nENTITIES\n0\nCIRCLE\n8\nA\n10\n#{cx}\n20\n#{cy}\n40\n#{radius}\n" \
                 "0\nENDSEC\n0\nEOF\n"
      end

      def arc_dxf(cx:, cy:, r:, a0:, a1:)
        "0\nSECTION\n2\nENTITIES\n0\nARC\n8\nA\n10\n#{cx}\n20\n#{cy}\n40\n#{r}\n" \
        "50\n#{a0}\n51\n#{a1}\n0\nENDSEC\n0\nEOF\n"
      end

      # An arc descriptor -> the arc a renderer actually draws, as [cx, cy, r, a0, delta] with the
      # angles in degrees. TWO CONVERSIONS, deliberately, because that is the round trip the wire
      # now makes: lib/shape_svg.js turns centre + angles into the `A` command's endpoints, and the
      # renderer turns those straight back into a centre. A defect in either shows up here.
      def resolved_arc(descriptor)
        _, cx, cy, r, a0, delta = descriptor
        x0, y0 = polar(cx, cy, r, a0)
        x1, y1 = polar(cx, cy, r, a0 + delta)
        endpoints_to_centre(x0, y0, x1, y1, r, delta.abs > 180 ? 1 : 0, delta > 0 ? 1 : 0)
      end

      # SVG 1.1 F.6.5, in the circular case (rx == ry, x-axis-rotation 0) — the conversion every
      # renderer performs on an `A` command. F.6.6's OUT-OF-RANGE CORRECTION is part of it, not a
      # nicety: a rounded half-turn's endpoints are routinely a hair more than 2r apart, and
      # without the scaling step the square root below goes negative.
      def endpoints_to_centre(x0, y0, x1, y1, radius, large, sweep)
        hx = (x0 - x1) / 2.0
        hy = (y0 - y1) / 2.0
        h2 = (hx * hx) + (hy * hy)
        lam = h2 / (radius * radius)
        r = lam > 1 ? radius * Math.sqrt(lam) : radius
        coef = Math.sqrt([ 0.0, ((r * r) - h2) / h2 ].max)
        coef = -coef if large == sweep
        cx = ((x0 + x1) / 2.0) + (coef * hy)
        cy = ((y0 + y1) / 2.0) - (coef * hx)
        a0 = Math.atan2(y0 - cy, x0 - cx) * 180 / Math::PI
        delta = ((Math.atan2(y1 - cy, x1 - cx) * 180 / Math::PI) - a0) % 360
        delta -= 360 if sweep.zero? && delta > 0
        [ cx, cy, r, a0, delta ]
      end

      # Distance from a point to a circular ARC — not to its circle. Analytic rather than sampled:
      # a point whose angle falls inside the sweep is |‖p − c‖ − r| away, one outside it is nearest
      # an endpoint. Sampling would need thousands of points per case to resolve 0.01 mm at r=200.
      def distance_to_arc(px, py, arc)
        cx, cy, r, a0, delta = arc
        ang = Math.atan2(py - cy, px - cx) * 180 / Math::PI
        lo = delta.negative? ? a0 + delta : a0
        return ((Math.hypot(px - cx, py - cy)) - r).abs if ((ang - lo) % 360) <= delta.abs

        [ polar(cx, cy, r, a0), polar(cx, cy, r, a0 + delta) ]
          .map { |(ex, ey)| Math.hypot(px - ex, py - ey) }.min
      end

      # The drawn arc's bbox: sampled rather than solved for the axis extremes it happens to span,
      # because 3600 steps put the sampling error at 2e-5 mm at r = 200 — three orders below what
      # is being asserted — and the closed form is four quadrant cases to get wrong.
      def arc_bbox(arc)
        cx, cy, r, a0, delta = arc
        pts = (0..3600).map { |i| polar(cx, cy, r, a0 + (i * delta / 3600.0)) }
        [ pts.map(&:first).min, pts.map(&:last).min, pts.map(&:first).max, pts.map(&:last).max ]
      end

      def polar(cx, cy, r, degrees)
        t = degrees * Math::PI / 180
        [ cx + (r * Math.cos(t)), cy + (r * Math.sin(t)) ]
      end
    end
  end
end
