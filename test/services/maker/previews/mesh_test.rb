require "test_helper"

module Maker
  module Previews
    # F3D (the mesh/CAD renderer) is an external BSD-3 binary that may not be installed on
    # this box. `available?` gates on it; the render tests SKIP when it's absent (matching the
    # SVG test's posture and docs/research-format-processing.md §8 point 6) rather than erroring.
    class MeshTest < ActiveSupport::TestCase
      setup { @stl = File.binread(Rails.root.join("test/fixtures/files/tetra.stl")) }

      test "available? reflects whether the f3d binary is on PATH" do
        assert_includes [ true, false ], Maker::Previews::Mesh.available?
      end

      test "covers the mesh + CAD extensions (NOT stl — that routes to the euc Stl renderer)" do
        assert_equal %w[obj step stp iges igs], Maker::Previews::Mesh::EXTENSIONS
      end

      test "renders an STL to a PNG thumbnail via f3d" do
        skip "f3d not installed" unless Maker::Previews::Mesh.available?
        result = Maker::Previews::Mesh.render(@stl, size: 128, ext: "stl")
        assert_equal "image/png", result[:content_type]
        assert_equal 128, result[:width]
        assert_equal "\x89PNG".b, result[:bytes][0, 4].b
      end

      test "renders a GLB for the model_glb kind via f3d" do
        skip "f3d not installed" unless Maker::Previews::Mesh.available?
        result = Maker::Previews::Mesh.render(@stl, kind: "model_glb", ext: "stl")
        assert_equal "model/gltf-binary", result[:content_type]
        # GLB magic = "glTF".
        assert_equal "glTF".b, result[:bytes][0, 4].b
      end

      test "raises RenderError when f3d cannot process the input" do
        skip "f3d not installed" unless Maker::Previews::Mesh.available?
        assert_raises(Maker::Previews::Mesh::RenderError) do
          Maker::Previews::Mesh.render("not a mesh".b, ext: "stl")
        end
      end
    end
  end
end
