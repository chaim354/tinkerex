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

      # Arcs and circles are flattened for measuring but drawn as EXACT primitives, so the
      # thumbnail stays crisp at any zoom. A consumer that used the curve descriptor INSTEAD of
      # the points would be reading a different geometry from the one the bbox came from.
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

      def build(bytes) = JSON.parse(DxfGeometry.render(bytes)[:bytes])

      def fixture(name) = File.binread(Rails.root.join("test/fixtures/files", name))

      def circle_dxf(radius:, insunits:)
        header = insunits ? "0\nSECTION\n2\nHEADER\n9\n$INSUNITS\n70\n#{insunits}\n0\nENDSEC\n" : ""
        header + "0\nSECTION\n2\nENTITIES\n0\nCIRCLE\n8\nA\n10\n0\n20\n0\n40\n#{radius}\n0\nENDSEC\n0\nEOF\n"
      end
    end
  end
end
