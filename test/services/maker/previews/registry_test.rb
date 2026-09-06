require "test_helper"

module Maker
  module Previews
    class RegistryTest < ActiveSupport::TestCase
      test "resolves the SVG renderer by extension (case-insensitive, dot-tolerant)" do
        assert_equal Maker::Previews::Svg, Maker::Previews::Registry.for("svg")
        assert_equal Maker::Previews::Svg, Maker::Previews::Registry.for("SVG")
        assert_equal Maker::Previews::Svg, Maker::Previews::Registry.for(".svg")
      end

      test "resolves the Phase-2 renderers by extension" do
        assert_equal Maker::Previews::Lbrn2,   Maker::Previews::Registry.for("lbrn2")
        assert_equal Maker::Previews::Lbrn2,   Maker::Previews::Registry.for("lbrn")
        assert_equal Maker::Previews::Dxf,     Maker::Previews::Registry.for("dxf")
        assert_equal Maker::Previews::ThreeMf, Maker::Previews::Registry.for("3mf")
        assert_equal Maker::Previews::Mage,    Maker::Previews::Registry.for("mage")
      end

      test "resolves obj/STEP/IGES to the F3D Mesh renderer, and STL to the euc Stl renderer" do
        %w[obj step stp iges igs].each do |ext|
          assert_equal Maker::Previews::Mesh, Maker::Previews::Registry.for(ext), ext
        end
        # STL uses the pure-CPU euc rasterizer (no GL/Mesa), not F3D.
        assert_equal Maker::Previews::Stl, Maker::Previews::Registry.for("stl")
      end

      # THE MESH FORMATS THE BROWSER VIEWER GAINED ON 2026-09-06 GOT A SERVER THUMBNAIL TOO, and
      # that pairing is the point: the thumbnail is the viewer's POSTER and the grid's only cell,
      # so a format that views but does not render is a blank card and a viewer that opens onto
      # nothing. Every one of these was read off `f3d --list-readers` on the shipped 3.5.0 —
      # gltf/glb/ply/wrl/3ds native, off/dae/fbx assimp, brep occt.
      test "the new browser-viewable mesh formats resolve to the F3D Mesh renderer" do
        %w[gltf glb ply off dae wrl 3ds fbx brep].each do |ext|
          assert_equal Maker::Previews::Mesh, Maker::Previews::Registry.for(ext), ext
        end
      end

      # THE THREE THE VIEWER READS AND F3D 3.5.0 DOES NOT, asserted so the gap is a recorded
      # decision rather than an oversight found later. Registering them would create a preview row
      # and a job for a render that can only ever fail; nil is what `Enqueue.call` reads as "no
      # renderer, do not litter the table". `.3mf` is nil-adjacent for the opposite reason and is
      # checked above: it has a BETTER renderer than F3D (the slicer's own embedded thumbnail).
      test "the viewable formats F3D cannot read have no renderer" do
        %w[3dm amf fcstd].each do |ext|
          assert_nil Maker::Previews::Registry.for(ext),
                     "f3d 3.5.0 lists no reader for .#{ext} — a row here is a job that must fail"
          assert_includes Maker::FileAttachment::VIEWABLE_3D_EXTS, ext,
                          "…but the BROWSER still opens it, which is why this pair is asserted together"
        end
      end

      test "returns nil for an unsupported extension" do
        assert_nil Maker::Previews::Registry.for("sldprt")
        assert_nil Maker::Previews::Registry.for("dwg")
        assert_nil Maker::Previews::Registry.for(nil)
      end

      # THE DERIVATION, AND THE DEFECT IT REPLACED. RENDERERS carried four hand-written TextThumb
      # entries while the vocabulary called 37 extensions text; the other 33 resolved to nil, which
      # `Enqueue.call` reads as "don't litter the table" — so no row, no job, a permanently blank
      # grid cell for every `.rb`, `.py`, `.gcode` and `.yml` in the library.
      test "every text extension the vocabulary knows resolves to TextThumb" do
        exts = Maker::FileAttachment::TEXT_EXTENSIONS
        assert_operator exts.size, :>, 50, "the sweep needs a subject"
        exts.each do |ext|
          assert_equal Maker::Previews::TextThumb, Maker::Previews::Registry.for(ext), ext
        end
      end

      # THE MERGE DIRECTION, AS A TRIPWIRE RATHER THAN A RE-DERIVATION. FORMAT_RENDERERS is merged
      # OVER the derived text entries so a text extension that ever gains a renderer of its own
      # keeps it — but with no overlap today, flipping the merge would change nothing and any test
      # that only compares the merged hash stays green. What IS checkable now is that the overlap
      # is still empty; the day it is not, this fails and whoever wired it reads the direction here
      # and confirms the intent, instead of finding out from a shadowed thumbnail.
      #
      # `renderer_contract_test.rb` catches the same collision from the other side (TextThumb's own
      # EXTENSIONS must resolve back to TextThumb), so neither is the only thing standing.
      test "no format renderer claims an extension the vocabulary calls text" do
        overlap = Maker::Previews::Registry::FORMAT_RENDERERS.keys &
                  Maker::FileAttachment::TEXT_EXTENSIONS
        assert_empty overlap,
                     "FORMAT_RENDERERS wins the merge, so these text extensions no longer get " \
                     "TextThumb. Intended? Then drop them from TEXT_EXTENSIONS' inputs too."
      end

      test "for_filename derives the extension from a filename or node path" do
        assert_equal Maker::Previews::Svg,   Maker::Previews::Registry.for_filename("drawing.SVG")
        assert_equal Maker::Previews::Mesh,  Maker::Previews::Registry.for_filename("part.STEP")
        assert_nil Maker::Previews::Registry.for_filename("part.sldprt")
      end
    end
  end
end
