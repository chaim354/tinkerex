require "test_helper"

module Maker
  module Previews
    # Stl renderer = the in-repo `stl-thumbnailer` binary (pure-CPU euc rasterizer; no GL/Mesa).
    # Skips when the binary isn't installed (CI / dev box without it), exactly like the F3D Mesh
    # renderer — the deployed server bakes the binary into its Docker image. Point the suite at a
    # local build with `STL_THUMBNAILER_BIN=/path/to/stl-thumbnailer bin/rails test`.
    class StlTest < ActiveSupport::TestCase
      def tetra = File.binread(Rails.root.join("test/fixtures/files/tetra.stl"))

      test "renders an STL to a non-trivial PNG when the binary is available" do
        skip "stl-thumbnailer not installed (set STL_THUMBNAILER_BIN)" unless Maker::Previews::Stl.available?

        res = Maker::Previews::Stl.render(tetra, size: 128)

        assert_equal "image/png", res[:content_type]
        assert_equal 128, res[:width]
        assert_equal 128, res[:height]
        assert_operator res[:bytes].bytesize, :>, 200, "PNG should be a real image, not empty"
        assert_equal "\x89PNG\r\n\x1A\n".b, res[:bytes][0, 8].b, "valid PNG signature"
      end

      test "available? returns a boolean and never raises" do
        assert_includes [ true, false ], Maker::Previews::Stl.available?
      end

      test "registry routes .stl to the Stl renderer (not F3D Mesh)" do
        assert_equal Maker::Previews::Stl, Maker::Previews::Registry.for_filename("widget.STL")
      end

      # THE CACHE-INVALIDATION HALF OF THE Z-UP FIX (§14h). Changing the camera changes the PICTURE,
      # and a stored thumbnail is only re-rendered when `Enqueue` sees a different revision — a
      # file's content never changes, so without a declared revision above BASE_REVISION every STL
      # already in a library would keep serving the sideways image the old build made. This is the
      # assertion that goes red if someone "tidies away" the constant.
      test "the STL renderer declares a revision past the base, or its thumbnails never rebuild" do
        assert_operator Maker::Previews::Stl::THUMBNAIL_REVISION, :>,
                        Maker::Previews::Enqueue::BASE_REVISION,
                        "a renderer at BASE_REVISION cannot invalidate anything it already rendered"
        assert_equal Maker::Previews::Stl::THUMBNAIL_REVISION,
                     Maker::Previews::Enqueue.revision_for_name("a.stl", "thumbnail")
      end

      # 3MF's MESH FALLBACK RENDERS THROUGH THIS RENDERER — a CAD-exported 3MF has no embedded
      # slicer thumbnail, so `ThreeMf.render` calls `Stl.render` and inherits its camera. A renderer
      # whose output is built by another one has to track that one's revision or its cache never
      # invalidates: bumping Stl alone would leave every CAD-exported 3MF sideways, with nothing
      # anywhere to say so. Pinned as a RELATIONSHIP, not as a literal, so the two cannot drift.
      test "3MF tracks the STL revision, because its mesh fallback renders through it" do
        assert_equal Maker::Previews::Stl::THUMBNAIL_REVISION,
                     Maker::Previews::ThreeMf::THUMBNAIL_REVISION,
                     "ThreeMf renders its mesh fallback through Stl — the revisions move together"
        assert_equal Maker::Previews::ThreeMf::THUMBNAIL_REVISION,
                     Maker::Previews::Enqueue.revision_for_name("a.3mf", "thumbnail")
      end
    end
  end
end
