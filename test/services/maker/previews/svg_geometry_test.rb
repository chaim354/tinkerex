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

      private

      def build(bytes) = SvgGeometry.build(bytes)

      # A 1:1 mm document, so every number in the body IS its own measurement.
      def wrap(body)
        %(<svg xmlns="http://www.w3.org/2000/svg" width="100mm" height="100mm" viewBox="0 0 100 100">) +
          body + %(</svg>)
      end
    end
  end
end
