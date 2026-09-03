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
      test "the payload and the thumbnail measure the same geometry" do
        %w[sample.dxf plate.dxf].each do |name|
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
      test "the traversal's two artifacts are byte-for-byte what they were before it took pairs" do
        {
          "sample.dxf" => %w[
            f32daab0e0264cb27c3d1ae8f3a9f74cda65b56c4b3009062c202900f9232352
            7efb394bb5c87eb18ba524eb00de78b004aa87331ba2bf35bab3231af6d8e9e0
          ],
          "plate.dxf" => %w[
            d8844eb6832b6d107fd1ad782ce34fc8a35d3b088b4609a6f0c8e6dba86e035d
            0839e1081f3a506a009ba31d643d59ebd8ca62242f4d6bcaaf10c79fb77af431
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

      # ---- what the parser could not read -----------------------------------------------------

      # THE BACKSTOP ITSELF. `Dxf.flatten` is a `case` with no `else`, so for years every entity
      # type this parser cannot draw returned nil and `each_geometry` skipped it with no error, no
      # log and no status — 18,906 SPLINEs across 29 of 129 real files, one of which reported "No
      # measurable geometry" about a file that is nothing but geometry (tinkerex#216).
      test "an entity type the parser cannot draw is reported rather than dropped" do
        dxf = "0\nSECTION\n2\nENTITIES\n0\nSPLINE\n8\nA\n0\nELLIPSE\n8\nA\n0\nSPLINE\n8\nA\n" \
              "0\nLINE\n8\nA\n10\n0\n20\n0\n11\n5\n21\n0\n0\nENDSEC\n0\nEOF\n"
        payload = build(dxf)

        assert_equal 1, payload["shapes"].length, "the LINE still draws"
        assert_equal({ "SPLINE" => 2, "ELLIPSE" => 1 }, payload["u"],
                     "and what could not be drawn is named and counted")
      end

      # A SKIPPED ENTITY IS ABSENT FROM THE BBOX, NOT MERELY FROM THE PICTURE — which is the half
      # that makes this a measurement bug rather than a cosmetic one. `elianadxf.dxf` is four
      # SPLINEs and nothing else: shapes=0, job 0x0, a reported job size describing none of the
      # file. The tally is the only thing on the wire that says so.
      test "a file whose every entity is unreadable says so instead of measuring as empty" do
        payload = build("0\nSECTION\n2\nENTITIES\n0\nSPLINE\n8\nA\n0\nSPLINE\n8\nA\n0\nENDSEC\n0\nEOF\n")

        assert_equal [], payload["shapes"]
        assert_equal({ "w" => 0.0, "h" => 0.0, "x" => 0.0, "y" => 0.0 }, payload["job"],
                     "the job box is still honestly empty — the tally is what makes it legible"
        )
        assert_equal({ "SPLINE" => 2 }, payload["u"])
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
