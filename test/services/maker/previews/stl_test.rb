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
    end
  end
end
