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
      test "the measure payload does not depend on the SVG rasterizer" do
        without_rasterizer do
          %w[lbrn2 dxf svg].each do |ext|
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

      # THE JOB IS WHAT ASKS, and it asking `available?` directly is the bug this replaced. Driven
      # through `GeneratePreviewJob`'s own gate rather than the renderer's, because a renderer
      # answering correctly to a caller that never calls it changes nothing.
      test "the job's gate asks the kind-aware question" do
        job = Maker::GeneratePreviewJob.new
        without_rasterizer do
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

      private

      def fixture(name) = File.binread(Rails.root.join("test/fixtures/files", name))

      # A box with no resvg, for the length of the block.
      #
      # HAND-ROLLED, NOT Object#stub: minitest 6 dropped minitest/mock, so `stub` does not exist
      # in this suite (requiring it is a LoadError) — same reason lbrn2_test's parse-count guard
      # and test_helper's `with_concurrent_file_attachment` rebind methods this way. `original` is
      # an UnboundMethod and `define_method` takes one directly, so the ensure reinstalls the
      # exact original implementation rather than hoping something else is underneath it.
      def without_rasterizer
        mod = SvgRasterizer.singleton_class
        original = mod.instance_method(:available?)
        mod.define_method(:available?) { false }
        yield
      ensure
        mod.define_method(:available?, original)
      end
    end
  end
end
