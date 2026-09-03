require "test_helper"

module Maker
  module Previews
    class SvgGeometryTest < ActiveSupport::TestCase
      # ---- units: the one place an SVG's numbers become physical ---------------------------

      # THE HEADLINE PROPERTY. Every other assertion in this file is about shapes; this is about
      # whether the numbers mean anything. A scale bug leaves the drawing pixel-perfect and every
      # reported measurement wrong by a constant factor.
      test "physical width over viewBox extent is the scale" do
        payload = build(%(<svg xmlns="http://www.w3.org/2000/svg" width="100mm" height="100mm" ) +
                        %(viewBox="0 0 200 200"><circle cx="100" cy="100" r="50"/></svg>))

        # 100 mm across 200 user units = 0.5 mm per unit, so r=50 units is a 50 mm diameter.
        assert_in_delta 50.0, payload["shapes"].first["d"], 0.05
      end

      test "a viewBox with no width falls back to CSS pixels at 96 dpi" do
        payload = build(%(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 96 96">) +
                        %(<rect x="0" y="0" width="96" height="96"/></svg>))

        assert_in_delta 25.4, payload["job"]["w"], 0.01, "96 CSS px is one inch by definition"
        assert_in_delta 25.4, payload["job"]["h"], 0.01
      end

      test "width in inches resolves through the same table" do
        payload = build(%(<svg xmlns="http://www.w3.org/2000/svg" width="2in" height="2in" ) +
                        %(viewBox="0 0 2 2"><rect x="0" y="0" width="2" height="2"/></svg>))

        assert_in_delta 50.8, payload["job"]["w"], 0.01
      end

      # A `%` width is not resolvable without a containing block, and `em` needs a font this
      # parser has no access to. Both must reach the px default rather than being read as a bare
      # number — `10em` measured as 10 px would be wrong by whatever the font size happens to be.
      test "unresolvable width units fall back to pixels rather than being read as numbers" do
        %w[50% 10em].each do |width|
          payload = build(%(<svg xmlns="http://www.w3.org/2000/svg" width="#{width}" height="#{width}" ) +
                          %(viewBox="0 0 96 96"><rect x="0" y="0" width="96" height="96"/></svg>))

          assert_in_delta 25.4, payload["job"]["w"], 0.01, "#{width} must not be read as a length"
        end
      end

      # The default `preserveAspectRatio` (meet) fits the viewBox INSIDE the viewport keeping the
      # ratio, so the real scale is the SMALLER of the two. Taking them per-axis reports a stretch
      # the renderer never applies.
      test "a mismatched aspect ratio uses the smaller scale, not one per axis" do
        payload = build(%(<svg xmlns="http://www.w3.org/2000/svg" width="200mm" height="100mm" ) +
                        %(viewBox="0 0 100 100"><rect x="0" y="0" width="100" height="100"/></svg>))

        assert_in_delta 100.0, payload["job"]["w"], 0.01, "meet uses min(sx, sy) on BOTH axes"
        assert_in_delta 100.0, payload["job"]["h"], 0.01
      end

      test "preserveAspectRatio none does stretch the axes independently" do
        payload = build(%(<svg xmlns="http://www.w3.org/2000/svg" width="200mm" height="100mm" ) +
                        %(viewBox="0 0 100 100" preserveAspectRatio="none">) +
                        %(<rect x="0" y="0" width="100" height="100"/></svg>))

        assert_in_delta 200.0, payload["job"]["w"], 0.01
        assert_in_delta 100.0, payload["job"]["h"], 0.01
      end

      # ---- transforms ---------------------------------------------------------------------

      test "a group transform moves its children" do
        payload = build(wrap(%(<g transform="translate(10,20)"><rect x="0" y="0" width="5" height="5"/></g>)))

        assert_equal [ 10.0, 20.0, 15.0, 25.0 ], payload["shapes"].first["b"]
      end

      # `transform="A B"` applies A THEN B, so the composed matrix is A*B. Folding them the other
      # way mirrors and mislocates every nested group — and Inkscape files nest constantly.
      test "transforms in one attribute compose left to right" do
        payload = build(wrap(%(<g transform="translate(10,0) scale(2)"><rect x="0" y="0" width="5" height="5"/></g>)))

        # translate THEN scale: the rect's corner is 10 + 2*0 = 10, its far corner 10 + 2*5 = 20.
        # Composed the other way it would sit at 20..30.
        assert_equal [ 10.0, 0.0, 20.0, 10.0 ], payload["shapes"].first["b"]
      end

      test "nested group transforms compose with their parents" do
        payload = build(wrap(%(<g transform="translate(10,10)"><g transform="translate(5,5)">) +
                             %(<rect x="0" y="0" width="1" height="1"/></g></g>)))

        assert_equal [ 15.0, 15.0, 16.0, 16.0 ], payload["shapes"].first["b"]
      end

      # `rotate(a cx cy)` turns the shape IN PLACE. Ignoring the optional centre rotates about the
      # origin, which throws the shape across the page rather than turning it.
      test "rotate honours its optional centre" do
        payload = build(wrap(%(<rect x="45" y="45" width="10" height="10" transform="rotate(90 50 50)"/>)))

        assert_equal [ 45.0, 45.0, 55.0, 55.0 ], payload["shapes"].first["b"],
                     "a square rotated about its own centre occupies the same box"
      end

      # ---- shapes -------------------------------------------------------------------------

      test "the primitive shapes all measure" do
        payload = build(wrap(%(<rect x="0" y="0" width="10" height="4"/>) +
                             %(<circle cx="50" cy="50" r="5"/>) +
                             %(<ellipse cx="80" cy="50" rx="6" ry="3"/>) +
                             %(<line x1="0" y1="90" x2="10" y2="90"/>) +
                             %(<polyline points="20,90 30,90 30,95"/>) +
                             %(<polygon points="40,90 50,90 50,95"/>)))

        assert_equal 6, payload["shapes"].length, "every primitive must contribute a contour"
        closed = payload["shapes"].map { |s| s["k"] }
        assert_equal [ 1, 1, 1, 0, 0, 1 ], closed, "line and polyline are open; the rest closed"
      end

      test "a circle reports its diameter and a same-sized square does not" do
        payload = build(wrap(%(<circle cx="20" cy="20" r="10"/><rect x="50" y="10" width="20" height="20"/>)))
        circle, square = payload["shapes"]

        assert_in_delta 20.0, circle["d"], 0.05
        assert_nil square["d"], "a square is not round, however equidistant its corners are"
      end

      # A rounded rect measured as sharp reports corners the file does not have. The bbox is the
      # same either way, so only the corner points can catch it.
      test "a rounded rect draws its corner arcs rather than squaring them" do
        rounded = build(wrap(%(<rect x="0" y="0" width="40" height="20" rx="5"/>)))["shapes"].first
        sharp = build(wrap(%(<rect x="0" y="0" width="40" height="20"/>)))["shapes"].first

        assert_equal sharp["b"], rounded["b"], "rounding must not move the bounding box"
        assert_operator rounded["p"].length, :>, sharp["p"].length,
                        "a rounded rect needs more than four points"
        assert_not_includes rounded["p"], [ 0.0, 0.0 ], "the sharp corner must be gone"
      end

      # ONE `d` HOLDING SEVERAL SUBPATHS IS ONE OBJECT the user clicks once, but SEVERAL contours —
      # so they share an object_id and stay separately measurable.
      test "subpaths of one path share an object id" do
        payload = build(wrap(%(<path d="M0,0 L10,0 L10,10 Z M20,20 L30,20 L30,30 Z"/>)))

        assert_equal 2, payload["shapes"].length
        assert_equal 1, payload["shapes"].map { |s| s["o"] }.uniq.length,
                     "both subpaths belong to the same clickable object"
      end

      test "object ids distinguish separate elements" do
        payload = build(wrap(%(<rect x="0" y="0" width="5" height="5"/><rect x="9" y="9" width="5" height="5"/>)))

        assert_equal 2, payload["shapes"].map { |s| s["o"] }.uniq.length
      end

      # ---- orientation --------------------------------------------------------------------

      # SVG IS ALREADY Y-DOWN, LIKE THE CLIENT'S SPACE, SO THERE IS NO FLIP. Adding one "for
      # symmetry with Dxf" turns every SVG upside down — and it still draws a plausible picture,
      # so only a positional assertion catches it.
      test "the y axis is not flipped" do
        payload = build(wrap(%(<rect x="0" y="0" width="10" height="5"/>) +
                             %(<rect x="0" y="80" width="10" height="5"/>)))
        top, bottom = payload["shapes"]

        assert_operator top["b"][1], :<, bottom["b"][1],
                        "the element nearer the document top must have the smaller y"
      end

      # ---- paint (the layer key) ----------------------------------------------------------

      # Colour is how a laser file is actually organised — LightBurn assigns cut settings BY
      # STROKE COLOUR on import — so equivalent spellings MUST collapse to one layer. Left
      # unnormalized, `#F00`, `red` and `rgb(255,0,0)` are three layers of one colour.
      test "equivalent colour spellings collapse to one layer" do
        payload = build(wrap(%(<rect x="0" y="0" width="5" height="5" stroke="#F00"/>) +
                             %(<rect x="9" y="0" width="5" height="5" stroke="red"/>) +
                             %(<rect x="18" y="0" width="5" height="5" stroke="rgb(255,0,0)"/>)))

        assert_equal [ "#ff0000" ], payload["shapes"].map { |s| s["c"] }.uniq
        assert_equal({ "#ff0000" => "#ff0000" }, payload["colors"])
      end

      test "stroke wins over fill, and a none stroke falls through to it" do
        payload = build(wrap(%(<rect x="0" y="0" width="5" height="5" stroke="blue" fill="green"/>) +
                             %(<rect x="9" y="0" width="5" height="5" stroke="none" fill="green"/>)))

        assert_equal [ "#0000ff", "#008000" ], payload["shapes"].map { |s| s["c"] }
      end

      test "a style attribute is read as well as a presentation attribute" do
        payload = build(wrap(%(<rect x="0" y="0" width="5" height="5" style="fill:none;stroke:#0000ff"/>)))

        assert_equal "#0000ff", payload["shapes"].first["c"]
      end

      test "paint is inherited from an ancestor group" do
        payload = build(wrap(%(<g stroke="#00ff00"><rect x="0" y="0" width="5" height="5"/></g>)))

        assert_equal "#00ff00", payload["shapes"].first["c"]
      end

      # A paint server or `currentColor` cannot be resolved to a stroke here. Passing it through
      # would put an arbitrary attribute value into the client's SVG; nil draws black instead.
      test "an unresolvable paint yields no layer rather than a raw attribute value" do
        payload = build(wrap(%(<rect x="0" y="0" width="5" height="5" stroke="url(#grad)"/>)))

        assert_nil payload["shapes"].first["c"]
        assert_equal({}, payload["colors"])
      end

      # ---- what is deliberately not parsed --------------------------------------------------

      # `<defs>` holds TEMPLATES instantiated elsewhere. Walking into it places their geometry at
      # coordinates nothing renders it at — and it would then be folded into the measured extent.
      test "defs content is not measured" do
        payload = build(wrap(%(<defs><rect x="500" y="500" width="10" height="10"/></defs>) +
                             %(<rect x="0" y="0" width="10" height="10"/>)))

        assert_equal 1, payload["shapes"].length
        assert_equal [ 0.0, 0.0, 10.0, 10.0 ], payload["shapes"].first["b"]
      end

      test "text contributes nothing rather than a guessed box" do
        payload = build(wrap(%(<text x="10" y="10">measured?</text><rect x="0" y="0" width="4" height="4"/>)))

        assert_equal 1, payload["shapes"].length
      end

      # ---- documents ------------------------------------------------------------------------

      # Matches Lbrn2.to_svg's and LbrnGeometry.build's contract: bytes we cannot make sense of
      # RAISE, so the job records `failed`. Returning the empty payload would present a corrupt
      # file as a working Measure view reading "No measurable geometry" — a lie about the file.
      test "a non-SVG document raises rather than measuring as empty" do
        assert_raises(SvgGeometry::ParseError) { SvgGeometry.build("not xml at all") }
        assert_raises(SvgGeometry::ParseError) { SvgGeometry.build("<html><body>hi</body></html>") }
      end

      # THE CASE THE GUARD ABOVE MUST NOT CATCH. An SVG that parses and genuinely draws nothing is
      # honest, not corrupt, and the client has a message for it.
      test "an SVG with no drawable content returns the honest empty payload" do
        payload = build(%(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"></svg>))

        assert_equal [], payload["shapes"]
        assert_equal({ "w" => 0.0, "h" => 0.0, "x" => 0.0, "y" => 0.0 }, payload["job"])
      end

      # One malformed `d` must not cost the file every other shape in it.
      test "a malformed path is skipped without failing the document" do
        payload = build(wrap(%(<path d="9 9 L 5 5"/><rect x="0" y="0" width="10" height="10"/>)))

        assert_equal 1, payload["shapes"].length
      end

      test "the fixture measures its plate and hole at their real sizes" do
        payload = build(File.binread(Rails.root.join("test/fixtures/files/plate.svg")))
        plate, hole = payload["shapes"]

        assert_in_delta 80.0, payload["job"]["w"], 0.01
        assert_in_delta 40.0, payload["job"]["h"], 0.01
        assert_in_delta 80.0, plate["b"][2] - plate["b"][0], 0.01
        assert_in_delta 10.0, hole["d"], 0.05
        assert_equal({ "#ff0000" => "#ff0000", "#0000ff" => "#0000ff" }, payload["colors"])
      end

      # EVERY REPORTED NUMBER COMES FROM FULL-RESOLUTION POINTS; thinning is drawing-only. An
      # implementation that thins first and measures after passes any "does it draw" test while
      # under-reporting every curve — and loses `d` entirely on a small hole, which is exactly
      # the feature a measuring tool exists for.
      test "a small circle keeps its diameter after its outline is thinned" do
        payload = build(%(<svg xmlns="http://www.w3.org/2000/svg" width="10mm" height="10mm" ) +
                        %(viewBox="0 0 10 10"><circle cx="5" cy="5" r="0.1"/></svg>))
        shape = payload["shapes"].first

        assert_operator shape["p"].length, :<, Geometry::MIN_CIRCLE_POINTS,
                        "the thinned outline must fall below the circularity floor, or this proves nothing"
        assert shape["d"], "no diameter — d was measured from the thinned outline"
        assert_in_delta 0.2, shape["d"], 0.01
      end

      test "render returns JSON bytes the job can attach" do
        result = SvgGeometry.render(File.binread(Rails.root.join("test/fixtures/files/plate.svg")))

        assert_equal "application/json", result[:content_type]
        assert_equal 2, JSON.parse(result[:bytes])["shapes"].length
      end

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

      # A STRAIGHT-ONLY PATH STILL CARRIES NO DESCRIPTOR, AND SINCE tinkerex#217 THAT IS A
      # DECISION RATHER THAN AN ABSENCE. `p` already IS the geometry of a run of `L` ops —
      # thinning only drops points within SIMPLIFY_TOLERANCE of the line the browser draws — so a
      # path descriptor there would restate the points in a second encoding and be paid for per
      # contour on every file. The form exists for what has no exact form already.
      test "a straight-only path carries no descriptor" do
        payload = build(%(<svg xmlns="http://www.w3.org/2000/svg" width="100mm" height="100mm" ) +
                        %(viewBox="0 0 100 100"><path d="M0,0 L50,0 L50,50 Z"/></svg>))

        assert_not payload["shapes"].first.key?("g")
      end

      # ---- path descriptors (tinkerex#217) ---------------------------------------------------

      # THE GUARD THAT DISCHARGES THIS LEG, AND IT RESOLVES THE DESCRIPTOR RATHER THAN READING IT.
      # A string-equality assertion cannot do this job: tinkerex#213's arc descriptor passed its
      # own five-number equality test while drawing 1.37 mm from the shape's own points, because
      # the numbers were never what was wrong. The live trap has the same shape — a control point
      # that misses the scale yields a well-formed `d` describing a plausible curve that is not the
      # file's — so this asks the two questions the rest of the payload already answers: does the
      # resolved curve pass through the shape's own `p`, and does it reach the shape's own `b`.
      test "a curved path is described by its own cubics, in millimetres" do
        shape = build(wrap(%(<path d="M10,10 C10,0 30,0 30,10 C30,20 10,20 10,10 Z"/>)))["shapes"].first

        assert_equal "p", shape["g"]&.first
        assert_curve_tracks_shape shape, "a two-cubic lens"
      end

      # THE ELEMENT'S OWN TRANSFORM AND THE DOCUMENT'S viewBox SCALE ARE TWO DIFFERENT MULTIPLIES IN
      # TWO DIFFERENT METHODS — `walk`'s `place_segments` and `build`'s `scale_segments` — so a
      # fixture with no `transform` on it cannot see the first at all, however many times it asserts
      # the second. This is the same curve as the test above with a translate over it, and it exists
      # so that the recorded failure shape (transform the endpoints, leave the control points raw)
      # has a SECOND independent catcher rather than resting on the rotation test alone.
      test "an enclosing transform moves a path's control points, not only its endpoints" do
        shape = build(wrap(%(<g transform="translate(25,35)">) +
                           %(<path d="M10,10 C10,0 30,0 30,10 C30,20 10,20 10,10 Z"/></g>)))["shapes"].first

        assert_in_delta 35.0, shape["b"][0], 0.01, "the whole contour moved by the translate"
        assert_curve_tracks_shape shape, "a translated two-cubic lens"
      end

      # THE SAME sx/sy THE POINTS GET, AND THE TWO AXES ARE NOT THE SAME NUMBER. Under
      # `preserveAspectRatio="none"` this document is 2 mm per unit across and 1 mm per unit down,
      # so applying `sx` to both axes doubles every y in the descriptor while `b` — measured from
      # the points — stays put. The curve then draws off its own outline, which is what the bbox
      # arm of the assertion below sees.
      test "a descriptor is scaled per axis, like the points beside it" do
        shape = build(%(<svg xmlns="http://www.w3.org/2000/svg" width="200mm" height="100mm" ) +
                      %(viewBox="0 0 100 100" preserveAspectRatio="none">) +
                      %(<path d="M10,10 C10,0 30,0 30,10 C30,20 10,20 10,10 Z"/></svg>))["shapes"].first

        # The lens spans x = 10..30 exactly (its control points share the endpoints' x) and
        # y = 2.5..17.5 (a symmetric cubic reaches ¾ of its control offset), so 20 user units
        # across at 2 mm/unit and 15 down at 1 mm/unit. The two are read off `b`, which comes from
        # the POINTS — this pair only establishes that the fixture is genuinely non-uniform; the
        # descriptor's own scaling is what the tracking assertion below tests.
        assert_in_delta 40.0, shape["b"][2] - shape["b"][0], 0.05, "20 units across at 2 mm/unit"
        assert_in_delta 15.0, shape["b"][3] - shape["b"][1], 0.05, "15 units down at 1 mm/unit"
        assert_curve_tracks_shape shape, "a cubic under a non-uniform scale"
      end

      # SVG IS ALREADY Y-DOWN, so unlike DxfGeometry there is no flip — only the scale. A flip
      # added here "for symmetry with Dxf" turns every SVG upside down and still draws a plausible
      # picture; only a POSITIONAL assertion catches it. The two cubics bulge in opposite
      # directions and the shape sits well away from the document's vertical centre, so neither a
      # flip about the origin nor one about the viewBox could leave this green.
      test "a descriptor is not flipped" do
        shape = build(wrap(%(<path d="M10,70 C10,60 30,60 30,70"/>)))["shapes"].first
        curve = resolve_path(shape["g"][1])

        assert_operator curve.map(&:last).min, :>, 55.0, "the curve stays near the document bottom"
        assert_operator curve.map(&:last).max, :<, 75.0
        assert_curve_tracks_shape shape, "an open cubic low in the document"
      end

      # THE AXIS-ALIGNED GATE DOES NOT APPLY TO `"p"`, AND SAYING SO IS THE POINT. It exists
      # because an `"e"` ellipse carries rx and ry with no rotation term, so under a rotation the
      # descriptor would export geometry the file does not contain. A CUBIC PATH HAS NO SUCH
      # LIMIT — it transforms affinely under ANY matrix, rotation and skew included — so a rotated
      # `<path>` KEEPS its descriptor. Refusing here would be a needless downgrade, and it is
      # exactly the "fix" a reader who knows `ellipse_curve_for` would reach for.
      test "a rotated or skewed path keeps its descriptor" do
        { "rotate(30 20 15)" => "rotated", "skewX(20)" => "skewed" }.each do |xform, label|
          shape = build(wrap(%(<g transform="#{xform}">) +
                             %(<path d="M10,10 C10,0 30,0 30,10 C30,20 10,20 10,10 Z"/></g>)))["shapes"].first

          assert_equal "p", shape["g"]&.first, "a #{label} path still transforms affinely"
          assert_curve_tracks_shape shape, "a #{label} cubic"
        end
      end

      # AN ELLIPSE UNDER THE SAME ROTATION STILL LOSES ITS DESCRIPTOR, which is what makes the
      # test above a distinction rather than a removal. Both arms are needed: an implementation
      # that gated neither and one that gated both each pass half of this pair.
      test "the gate that a path escapes still binds on an ellipse" do
        payload = build(wrap(%(<g transform="rotate(30)">) +
                             %(<ellipse cx="40" cy="40" rx="20" ry="10"/>) +
                             %(<path d="M60,10 C60,0 80,0 80,10"/></g>)))
        ellipse, path = payload["shapes"].sort_by { |s| s["b"][0] }

        assert_not ellipse.key?("g"), "a rotated <ellipse> is not an SVG <ellipse>"
        assert_equal "p", path["g"]&.first, "a rotated cubic is still a cubic"
      end

      # AN ARC REACHES THE CLIENT AS CUBICS AND NOT AS AN `A`. Endpoint arc parameterisation is
      # ill-conditioned under rounding (tinkerex#213: 1.37 mm of drawn error at r = 200), and an
      # SVG arc under a non-uniform scale is a different ellipse arc needing a rotation term no
      # primitive wire form carries. `resolve_path` RAISES on anything outside M/L/C/Z, so a
      # producer that started emitting a raw arc goes red here rather than drawing a wrong picture.
      test "an arc in a path arrives as cubics" do
        shape = build(wrap(%(<path d="M10,30 A10,10 0 0 1 30,30 L30,40 L10,40 Z"/>)))["shapes"].first

        assert_equal "p", shape["g"]&.first
        assert_curve_tracks_shape shape, "an arc-and-lines path"
      end

      # A ROUNDED `<rect>` IS BUILT FROM FOUR ARCS BY `rect_contours`, SO IT WOULD ACQUIRE A
      # DESCRIPTOR FOR FREE — AND IT DELIBERATELY DOES NOT. `contours_for`'s other six branches
      # answer for elements the FILE declared as primitives, and this arc run is OURS: it is the
      # shape of a `<rect>` with an `rx`, not geometry the author wrote. Extending the form to it
      # is a separate change with its own payload measurement, so the descriptor stops at the door
      # `path` came in by. Recorded rather than left to be noticed.
      test "a rounded rect gets no descriptor, though it is built from arcs" do
        payload = build(wrap(%(<rect x="0" y="0" width="40" height="20" rx="5"/>)))

        assert_not payload["shapes"].first.key?("g")
      end

      # A `d` WITH SEVERAL SUBPATHS IS ONE OBJECT AND SEVERAL CONTOURS, so each gets its OWN
      # descriptor. One list covering the whole `d` would be attached to both entries while each
      # `b` covers one subpath — the bbox arm below is what catches that.
      test "each subpath of one path gets its own descriptor" do
        shapes = build(wrap(%(<path d="M10,10 C10,0 30,0 30,10 C30,20 10,20 10,10 Z ) +
                             %(M60,60 C60,50 80,50 80,60 C80,70 60,70 60,60 Z"/>)))["shapes"]

        assert_equal 2, shapes.length
        assert_equal 1, shapes.map { |s| s["o"] }.uniq.length, "still one clickable object"
        shapes.each_with_index { |s, i| assert_curve_tracks_shape s, "subpath #{i}" }
        assert_not_equal shapes[0]["g"][1], shapes[1]["g"][1], "two contours cannot share one path"
      end

      # THE `d`-STRING SAFETY ARGUMENT, DISCHARGED MECHANICALLY RATHER THAN BY THE COMMENT ALONE.
      # The wire form is a string, and a reviewer should ask what stops a `d` attribute's own bytes
      # riding into it. The answer is that nothing does: `SvgPath.lex` turns every coordinate into
      # a Float before a segment exists, and `Geometry.path_curve` rounds each one. Asserted here
      # against a `d` carrying markup and a quote in the very attribute the descriptor is built
      # from — the only place in this leg where user text is even adjacent to the output.
      test "an emitted d string holds nothing but the command letters and numbers" do
        payload = build(wrap(%(<path d="M10,10 C10,0 30,0 30,10 &quot;&gt;&lt;script&gt; L5,5 Z"/>)))
        d = payload["shapes"].first["g"][1]

        assert_match(/\A[MLCZ0-9 .eE+-]+\z/, d, "a d string may hold only numbers and M/L/C/Z")
      end

      private

      def build(bytes) = SvgGeometry.build(bytes)

      # A 1:1 mm document, so every number in the body IS its own measurement.
      def wrap(body)
        %(<svg xmlns="http://www.w3.org/2000/svg" width="100mm" height="100mm" viewBox="0 0 100 100">) +
          body + %(</svg>)
      end

      # THE DESCRIPTOR RESOLVED THE WAY A RENDERER RESOLVES IT. STRICT ON PURPOSE: an unknown
      # command RAISES. The wire form is absolute M/L/C/Z and nothing else (`Geometry.path_curve`),
      # and a lenient parser that skipped an `A` or an `S` would let a producer start emitting one
      # while every assertion below stayed green — which is exactly how a client that does not
      # understand the command would fail, silently.
      def resolve_path(d, per_curve: 48)
        tokens = d.split
        pts = []
        cur = start = nil
        i = 0
        while i < tokens.length
          case tokens[i]
          when "M", "L"
            cur = [ Float(tokens[i + 1]), Float(tokens[i + 2]) ]
            start ||= cur
            pts << cur
            i += 3
          when "C"
            c1 = [ Float(tokens[i + 1]), Float(tokens[i + 2]) ]
            c2 = [ Float(tokens[i + 3]), Float(tokens[i + 4]) ]
            p3 = [ Float(tokens[i + 5]), Float(tokens[i + 6]) ]
            (1..per_curve).each { |k| pts << cubic_at(cur, c1, c2, p3, k.to_f / per_curve) }
            cur = p3
            i += 7
          when "Z"
            pts << (cur = start)
            i += 1
          else
            raise "unexpected path command #{tokens[i].inspect} — the wire form is absolute M/L/C/Z only"
          end
        end
        pts
      end

      def cubic_at(p0, c1, c2, p3, t)
        u = 1.0 - t
        [ 0, 1 ].map do |a|
          (u * u * u * p0[a]) + (3 * u * u * t * c1[a]) + (3 * u * t * t * c2[a]) + (t * t * t * p3[a])
        end
      end

      # THE TWO QUESTIONS THE REST OF THE PAYLOAD ALREADY ANSWERS, asked of the resolved curve —
      # the same helper `lbrn_geometry_test.rb` uses on the LightBurn leg, and for the same reason.
      #
      # 0.05 mm is where the roundings land, stated rather than tuned: `p` is thinned to within
      # SIMPLIFY_TOLERANCE (0.01) of the true contour and rounded at PRECISION (≤0.007 mm
      # diagonally), and the descriptor's control points are rounded at PRECISION too — which
      # displaces the drawn curve by at most that much, because a cubic is a convex combination of
      # its own control points. Roughly 0.03 mm of headroom, against a mutation that misses by
      # whole millimetres.
      #
      # THE BBOX IS ASSERTED AS CONTAINMENT-PLUS-REACH rather than as equality, because a cubic's
      # extreme does not in general fall on a flattened sample: the resolved curve may exceed `b`
      # by the flattening tolerance and must not fall short of it by more.
      def assert_curve_tracks_shape(shape, label, tol: 0.05)
        assert_equal "p", shape["g"]&.first, "#{label}: expected a path descriptor"

        curve = resolve_path(shape["g"][1])
        worst = max_deviation(shape["p"], curve)
        assert_operator worst, :<=, tol,
                        "#{label}: the drawn curve strays #{worst.round(4)} mm from the shape's own points"

        box = [ curve.map(&:first).min, curve.map(&:last).min,
                curve.map(&:first).max, curve.map(&:last).max ]
        %w[left top right bottom].each_with_index do |edge, i|
          assert_in_delta shape["b"][i], box[i], tol, "#{label}: the drawn curve misses b's #{edge} edge"
        end
      end

      # The largest distance from any point of `original` to the polyline `kept`. Point-to-SEGMENT,
      # not point-to-point: two samplings of one curve do not share sample positions.
      def max_deviation(original, kept)
        original.map { |p| kept.each_cons(2).map { |a, b| point_segment_distance(p, a, b) }.min || 0.0 }.max
      end

      def point_segment_distance(point, a, b)
        px, py = point
        ax, ay = a
        bx, by = b
        dx = bx - ax
        dy = by - ay
        return Math.hypot(px - ax, py - ay) if dx.abs < 1e-12 && dy.abs < 1e-12

        t = ((((px - ax) * dx) + ((py - ay) * dy)) / ((dx * dx) + (dy * dy))).clamp(0.0, 1.0)
        Math.hypot(px - (ax + (t * dx)), py - (ay + (t * dy)))
      end
    end
  end
end
