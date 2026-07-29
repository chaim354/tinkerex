require "test_helper"

module Maker
  module Previews
    # F3D (the mesh/CAD renderer) is an external BSD-3 binary that may not be installed on
    # this box. `available?` gates on it; the render tests SKIP when it's absent (matching the
    # SVG test's posture and docs/research-format-processing.md §8 point 6) rather than erroring.
    class MeshTest < ActiveSupport::TestCase
      setup do
        @stl = File.binread(Rails.root.join("test/fixtures/files/tetra.stl"))
        @obj = File.binread(Rails.root.join("test/fixtures/files/tetra.obj"))
      end

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

      # OBJ is the one extension Mesh::EXTENSIONS actually OWNS that had no render coverage — the
      # other three tests all feed STL, which routes to the euc Stl renderer in production and only
      # reaches F3D here because the test calls Mesh directly. So an F3D build that could not load an
      # OBJ would have passed the whole suite.
      test "renders an OBJ to a PNG thumbnail via f3d" do
        skip "f3d not installed" unless Maker::Previews::Mesh.available?
        result = Maker::Previews::Mesh.render(@obj, size: 128, ext: "obj")
        assert_equal "image/png", result[:content_type]
        assert_equal 128, result[:width]
        assert_equal "\x89PNG".b, result[:bytes][0, 4].b
      end

      # This test used to assert a GLB came back, and PASSED ONLY BY SKIPPING: `available?` never
      # returned true, so nobody ever saw that `--output out.glb` writes a PNG (f3d --help spells
      # the argument "<png file>"). The old code labelled those PNG bytes model/gltf-binary and
      # GeneratePreviewJob attached them as .glb marked "ready". Refusing is the honest answer.
      test "refuses the model_glb kind — f3d renders rasters, it does not export GLB" do
        skip "f3d not installed" unless Maker::Previews::Mesh.available?
        err = assert_raises(Maker::Previews::Mesh::RenderError) do
          Maker::Previews::Mesh.render(@stl, kind: "model_glb", ext: "stl")
        end
        assert_match(/cannot export GLB/, err.message)
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
