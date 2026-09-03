require "test_helper"

module Maker
  module Previews
    # The SHARED payload builder's own contract, plus the cross-format guards that no single
    # format's test can see. The per-format traversals are tested in lbrn_geometry_test.rb,
    # dxf_geometry_test.rb, svg_geometry_test.rb and mage_test.rb.
    class GeometryTest < ActiveSupport::TestCase
      # THE EXTENSIBILITY BACKSTOP FOR MEASURING, the same role RendererContractTest plays for
      # thumbnails. Every extension the UI offers Measure for is driven through the REAL
      # `render(..., kind: "geometry")` call the job makes — so a format listed in MEASURABLE_EXTS
      # whose renderer cannot actually build a payload fails here rather than in a browser.
      MEASURABLE_FIXTURES = {
        "lbrn2" => "real-export.lbrn2",
        "lbrn"  => "sample.lbrn2",
        "mage"  => "real-export.mage",
        "dxf"   => "sample.dxf",
        "svg"   => "square.svg"
      }.freeze

      test "every extension the UI offers Measure for can actually build a payload" do
        assert_equal MEASURABLE_FIXTURES.keys.sort, FilesController::MEASURABLE_EXTS.sort,
                     "MEASURABLE_EXTS and this test's fixture map must cover the same extensions"

        MEASURABLE_FIXTURES.each do |ext, fixture|
          renderer = Registry.for(ext)
          assert renderer, ".#{ext} must resolve to a renderer"

          result = renderer.render(fixture(fixture), kind: "geometry")
          assert_equal "application/json", result[:content_type], ".#{ext} must return a JSON payload"

          payload = JSON.parse(result[:bytes])
          assert_equal Geometry::SCHEMA_VERSION, payload["v"], ".#{ext} must stamp the shared schema"
          assert payload["shapes"].is_a?(Array), ".#{ext} must return a shapes array"
          assert payload["shapes"].any?, ".#{ext} fixture must actually measure something"
          %w[w h x y].each { |k| assert payload["job"].key?(k), ".#{ext} job box needs #{k}" }
        end
      end

      # A payload built by an OLDER BUILD is served forever unless its renderer's revision moves,
      # because a finished design's content never changes — that is exactly how four LightBurn
      # files kept serving mangled curves after the thinning fix deployed. So a change in THIS
      # module, which every format's output flows through, has to bump EVERY format's revision.
      #
      # ENUMERATED FROM THE CODE, NOT FROM THE LIST. Comparing REVISIONED_BY against itself would
      # assert nothing; discovering which modules actually declare a PAYLOAD_REVISION is what makes
      # a fifth format impossible to add without appearing in that list — and therefore impossible
      # to forget when this module changes.
      test "every module that builds a geometry payload is named in REVISIONED_BY" do
        Rails.application.eager_load!
        declared = Maker::Previews.constants.map { |c| Maker::Previews.const_get(c) }
                                 .select { |m| m.is_a?(Module) && m.const_defined?(:PAYLOAD_REVISION, false) }
                                 .map { |m| m.name.demodulize }

        assert_equal Geometry::REVISIONED_BY.sort, declared.sort,
                     "a geometry payload builder exists that Geometry::REVISIONED_BY does not name — " \
                     "a change to the shared builder would leave its output stale forever"
      end

      # `Geometry` OWNS PART OF EVERY FORMAT'S BYTES — simplify, diameter, job_box, the entry hash,
      # PRECISION — so it carries a term in every format's revision instead of the prose reminder it
      # used to carry. Enumerated from REVISIONED_BY, so a fifth format inherits this guard the day
      # it is added rather than the day someone remembers to extend the list.
      test "each format's geometry revision is the shared term plus its own" do
        Geometry::REVISIONED_BY.each do |name|
          mod = Maker::Previews.const_get(name)
          assert_equal Geometry::SHARED_REVISION + mod::FORMAT_REVISION, mod::PAYLOAD_REVISION,
                       "#{name}::PAYLOAD_REVISION must be Geometry::SHARED_REVISION + FORMAT_REVISION, " \
                       "or a change to the shared builder stops invalidating this format"
        end
      end

      # THE ABSOLUTE VALUES, AND THE RELATIONSHIP ABOVE IS NOT A SUBSTITUTE FOR THEM. A
      # relationship-only pin is satisfied by seeding SHARED_REVISION at ANY value and shifting all three
      # totals — arithmetic that stays internally consistent while silently re-measuring every
      # geometry payload in the library, on the one backend of three that holds real files. It also
      # catches the residual the arithmetic cannot close: a shared change bumped into a format's own
      # FORMAT_REVISION still moves that format's total, and lands here.
      #
      # FIVE NAMES, NOT THREE: .lbrn and .mage both route to LbrnGeometry, so a three-name check
      # cannot see a delegation regression.
      #
      # FOUR OF THE FIVE MOVED ON 2026-09-03 AND `a.dxf` DELIBERATELY DID NOT, which is this
      # table's whole job. The `"p"` bezier descriptor added `Geometry.path_curve` to the SHARED
      # builder, and the standing rule one file over says a change THERE bumps every format — so
      # the reviewer's question is why the shared term did not move. Because `path_curve` is
      # ADDITIVE: it changes no format's bytes until that format calls it, `LbrnGeometry` and
      # `SvgGeometry` now do and each bumped its own term, and `DxfGeometry` does not. Bumping the
      # shared term would re-render every `.dxf` payload in the library for a change that cannot
      # reach one. A DXF payload IS byte-identical across the change and
      # `dxf_geometry_test.rb`'s three digests, untouched, are what say so.
      GEOMETRY_REVISIONS = { "a.lbrn2" => 6, "a.lbrn" => 6, "a.mage" => 6, "a.dxf" => 4, "a.svg" => 3 }.freeze

      test "a format's geometry revision moves only when this pin moves with it" do
        GEOMETRY_REVISIONS.each do |filename, expected|
          assert_equal expected, Enqueue.revision_for_name(filename, "geometry"),
                       "#{filename} changed geometry revision — every stored payload of that format " \
                       "re-renders. Confirm that is intended before updating this number."
        end
      end

      # AND THE TABLE ITSELF IS ENUMERATED, so a sixth measurable format cannot slip in unpinned.
      # The relationship test above derives its subjects from `REVISIONED_BY` and the fixture test
      # from the controller's own `MEASURABLE_EXTS`, but until 2026-09-03 nothing tied THIS table to
      # either — a new format would be forced into both of those and could still reach Measure with
      # its absolute revision unpinned, free to drift. That is precisely the hole tinkerex#220
      # closed for the `thumbnail` kind (`thumbnail_revision_test.rb`), found there by mutation:
      # a relationship pin is satisfied by any value, so only an enumerated absolute table notices.
      test "every measurable extension is pinned in GEOMETRY_REVISIONS" do
        pinned = GEOMETRY_REVISIONS.keys.map { |name| File.extname(name).delete(".") }.sort

        assert_equal MEASURABLE_FIXTURES.keys.sort, pinned,
                     "a format the UI offers Measure for has no row in GEOMETRY_REVISIONS (or vice " \
                     "versa) — without one, forgetting to bump its payload revision is green, and " \
                     "every stored payload of that format serves an older build's bytes forever"
      end

      test "each measurable renderer versions its geometry independently of its thumbnail" do
        MEASURABLE_FIXTURES.each_key do |ext|
          renderer = Registry.for(ext)
          assert renderer.respond_to?(:payload_revision), ".#{ext} must declare per-kind revisions"
          assert_kind_of Integer, renderer.payload_revision("geometry")
          assert_kind_of Integer, renderer.payload_revision("thumbnail")
        end
      end

      # WITHOUT THIS, `Enqueue.revision_for` falls back to BASE_REVISION (1) for BOTH kinds, so
      # bumping a geometry payload silently rebuilds every thumbnail of that format too — on the
      # live share backend that was ~1400 rebuilds attached to an unrelated fix.
      test "Enqueue reads each renderer's per-kind revision rather than the base default" do
        assert_equal Maker::Previews::LbrnGeometry::PAYLOAD_REVISION,
                     Enqueue.revision_for_name("a.lbrn2", "geometry")
        assert_equal Maker::Previews::DxfGeometry::PAYLOAD_REVISION,
                     Enqueue.revision_for_name("a.dxf", "geometry")
        assert_equal Maker::Previews::SvgGeometry::PAYLOAD_REVISION,
                     Enqueue.revision_for_name("a.svg", "geometry")
        # .mage DELEGATES to LbrnGeometry's number because it delegates the payload itself.
        assert_equal Maker::Previews::LbrnGeometry::PAYLOAD_REVISION,
                     Enqueue.revision_for_name("a.mage", "geometry")

        assert_equal Maker::Previews::Lbrn2::THUMBNAIL_REVISION,
                     Enqueue.revision_for_name("a.lbrn2", "thumbnail")
      end

      # MEASURING NEEDS NO RASTERIZER, and a box without resvg must still do it. This is the whole
      # reason `available_for?` exists beside `available?`: a single toolchain gate marked a
      # perfectly measurable .svg/.dxf/.lbrn2 `unsupported`, while .mage — whose `available?` is
      # unconditionally true — measured fine, making the feature silently format-dependent on
      # exactly the boxes least likely to have the binary.
      #
      # THE RASTERIZER IS STUBBED ABSENT, WHICH IS THE ONLY WAY THIS ASSERTS ANYTHING. Asked
      # plainly on a box that HAS resvg, `available_for?("geometry")` is true however it is
      # implemented — the first draft did exactly that and stayed green when the method was
      # mutated to `available? && !kind.nil?`. The condition the guard exists for is a box
      # WITHOUT the binary, so the test has to create one.
      #
      # .lbrn2 LEFT THIS LIST DELIBERATELY and is covered by the test below instead. It is no
      # longer a format whose THUMBNAIL depends on the toolchain, so the last assertion here is
      # false of it — see Lbrn2#available?. Svg and Dxf have no embedded raster to fall back on,
      # so for them every word of this still holds.
      test "the measure payload does not depend on the SVG rasterizer" do
        without_svg_rasterizer do
          %w[dxf svg].each do |ext|
            renderer = Registry.for(ext)
            assert renderer.respond_to?(:available_for?), ".#{ext} must answer available_for?"
            assert_not renderer.available?, ".#{ext} must report its toolchain absent, or this proves nothing"
            assert renderer.available_for?("geometry"),
                   ".#{ext} must still be measurable with no rasterizer on the box"
            assert_not renderer.available_for?("thumbnail"),
                       ".#{ext} thumbnails must still depend on the toolchain"
          end
        end
      end

      # THE TWO FORMATS THAT CARRY THEIR OWN RENDER CLEAR A HIGHER BAR: not merely measurable
      # with no rasterizer, but THUMBNAIL-ABLE, because the embedded PNG is right there and
      # extracting it is pure Ruby. Neither declares `available_for?` at all — with `available?`
      # unconditionally true the override could only ever repeat it — so this asserts through the
      # JOB'S gate, which is what actually decides, rather than through a method one of them does
      # not have.
      test "lbrn2 and mage need no rasterizer for either kind" do
        job = Maker::GeneratePreviewJob.new
        without_svg_rasterizer do
          %w[lbrn2 mage].each do |ext|
            renderer = Registry.for(ext)
            assert_not Maker::Previews::SvgRasterizer.available?,
                       "precondition: the rasterizer must read absent, or this proves nothing"
            assert job.send(:available_for?, renderer, "geometry"),
                   ".#{ext} must be measurable with no rasterizer on the box"
            assert job.send(:available_for?, renderer, "thumbnail"),
                   ".#{ext} carries an embedded raster, so its thumbnail must not need the toolchain"
          end
        end
      end

      # THE JOB IS WHAT ASKS, and it asking `available?` directly is the bug this replaced. Driven
      # through `GeneratePreviewJob`'s own gate rather than the renderer's, because a renderer
      # answering correctly to a caller that never calls it changes nothing.
      test "the job's gate asks the kind-aware question" do
        job = Maker::GeneratePreviewJob.new
        without_svg_rasterizer do
          assert job.send(:available_for?, Svg, "geometry"),
                 "the job must let a geometry render through on a box with no rasterizer"
          assert_not job.send(:available_for?, Svg, "thumbnail")
        end

        # A renderer that does NOT declare available_for? must still be gated on available? —
        # ten of them produce only a thumbnail and must be untouched by this.
        assert_equal Maker::Previews::Stl.available?,
                     job.send(:available_for?, Maker::Previews::Stl, "thumbnail")
      end

      # `add` DROPS a degenerate contour rather than raising: a zero-length line or a Rect with no
      # W/H is ordinary in a real file and must not fail the whole render.
      test "a contour of fewer than two points is dropped, not raised on" do
        payload = Geometry.build do |out|
          out.add(layer: "a", points: [ [ 0.0, 0.0 ] ], closed: false, object_id: 1)
          out.add(layer: "a", points: [ [ 0.0, 0.0 ], [ 10.0, 5.0 ] ], closed: false, object_id: 2)
        end

        assert_equal 1, payload["shapes"].length
        assert_equal 2, payload["shapes"].first["o"], "the surviving contour must be the real one"
      end

      # The colours map describes the layers the document ACTUALLY DREW. A resolver returning nil
      # for a layer leaves it out entirely rather than emitting a null the client would have to
      # special-case — `this.colors[shape.c] || "#000000"` already reads a missing key as black.
      test "a layer with no colour is absent from the map, not present as null" do
        payload = Geometry.build(colors: ->(layers) { layers.to_h { |l| [ l, l == "red" ? "#ff0000" : nil ] } }) do |out|
          out.add(layer: "red", points: [ [ 0.0, 0.0 ], [ 1.0, 1.0 ] ], closed: false, object_id: 1)
          out.add(layer: "bare", points: [ [ 0.0, 0.0 ], [ 1.0, 1.0 ] ], closed: false, object_id: 2)
        end

        assert_equal({ "red" => "#ff0000" }, payload["colors"])
      end

      test "a format offering no colours at all still produces a valid empty map" do
        payload = Geometry.build do |out|
          out.add(layer: "0", points: [ [ 0.0, 0.0 ], [ 1.0, 1.0 ] ], closed: false, object_id: 1)
        end

        assert_equal({}, payload["colors"])
      end

      # ---- what a traversal could not read --------------------------------------------------

      # FORMAT-AGNOSTIC ON PURPOSE. DXF is where the gap was measured, but "the traversal met
      # something it could not draw" is a fact any of the four formats can have and none of them
      # had a way to say. See Geometry.build.
      test "a traversal reports what it could not read as a top-level u key" do
        payload = Geometry.build(unreadable: { "SPLINE" => 2, "ELLIPSE" => 1 }) do |out|
          out.add(layer: "a", points: [ [ 0.0, 0.0 ], [ 1.0, 1.0 ] ], closed: false, object_id: 1)
        end

        assert_equal({ "SPLINE" => 2, "ELLIPSE" => 1 }, payload["u"])
      end

      # ABSENT WHEN EMPTY, EXACTLY AS `g` IS ABSENT PER SHAPE. A `"u" => {}` on every well-read
      # file is bytes for nothing, and the client's check is truthiness — a null or an empty object
      # would read as "no report" while still being paid for.
      test "a payload with nothing unreadable carries no u key at all" do
        assert_not Geometry.build { |o|
          o.add(layer: "a", points: [ [ 0.0, 0.0 ], [ 1.0, 1.0 ] ], closed: false, object_id: 1)
        }.key?("u")

        assert_not Geometry.build(unreadable: {}) { |o|
          o.add(layer: "a", points: [ [ 0.0, 0.0 ], [ 1.0, 1.0 ] ], closed: false, object_id: 1)
        }.key?("u")
      end

      # THE HASH IS READ AFTER THE TRAVERSAL RUNS, NOT WHEN `build` IS CALLED, and that ordering is
      # the whole mechanism: a format hands in an empty hash and its traversal fills it. Reading it
      # at the top of `build` would emit nothing, silently, on every file.
      test "the tally a traversal fills during the yield still reaches the payload" do
        tally = {}
        payload = Geometry.build(unreadable: tally) do |out|
          tally["SPLINE"] = 3
          out.add(layer: "a", points: [ [ 0.0, 0.0 ], [ 1.0, 1.0 ] ], closed: false, object_id: 1)
        end

        assert_equal({ "SPLINE" => 3 }, payload["u"])
      end

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

      # TWO PRECISIONS IN ONE DESCRIPTOR, and the mixture is the point rather than an oversight:
      # `cx`, `cy` and `r` are millimetres and round at PRECISION, while `a0` and `delta` are
      # DEGREES and round at ANGLE_PRECISION, because 0.005° is 0.0175 mm of arc at r = 200 —
      # coarser than the very points the descriptor rides beside. The 0.0044° below survives; at
      # PRECISION it would have been rounded away entirely.
      # ONE ABSOLUTE `d` STRING, BUILT FROM NUMBERS. The rounding and the joining live here rather
      # than in each format module for the reason `ellipse_curve` does — three producers spelling
      # `"M #{x} #{y}"` is three copies that must agree about a wire format.
      #
      # A SEGMENT LIST IN, A STRING OUT, and the direction is the safety argument: a producer hands
      # this parsed NUMBERS, and `round` is what a String does not answer to, so there is no door
      # through which a byte of file text reaches the output.
      test "path_curve rounds to PRECISION and joins one absolute d string" do
        assert_equal [ "p", "M 1.23 -4.57 C 0 1 2 3 4 5 L 6.79 7 Z" ],
                     Geometry.path_curve([ [ :M, 1.234, -4.567 ], [ :C, 0.0, 1.0, 2.0, 3.0, 4.0, 5.0 ],
                                           [ :L, 6.789, 7.0 ], [ :Z ] ])
      end

      # A WHOLE NUMBER LOSES ITS `.0`, WHICH IS BYTES AND NOT COSMETICS. `Float#round(2)` returns a
      # Float, so `10.0.to_s` is "10.0" — three bytes per coordinate, six coordinates per cubic, on
      # the files this form exists for (49,030 bezier segments across the live LightBurn corpus).
      # It also removes `-0.0`, which is what a coordinate rounding up from -0.001 would otherwise
      # write into a geometry attribute.
      test "path_curve writes a whole coordinate without a trailing zero" do
        assert_equal [ "p", "M 10 0 L 0 -20" ],
                     Geometry.path_curve([ [ :M, 10.0, -0.001 ], [ :L, 0.0, -20.0 ] ])
      end

      test "arc_curve rounds millimetres at PRECISION and keeps its angles fine" do
        assert_equal [ "a", 1.23, -4.57, 10.0, 336.504401, -179.995604 ],
                     Geometry.arc_curve(1.234, -4.567, 10.0, 336.5044008, -179.9956044)
      end

      private

      def fixture(name) = File.binread(Rails.root.join("test/fixtures/files", name))
    end
  end
end
