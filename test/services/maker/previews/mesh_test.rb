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

      # THE LITERAL IS THE TEST, and it is deliberately not re-derived from the Registry — the
      # renderer contract test already asserts every entry here resolves back through `Registry.for`,
      # so a derivation would agree with itself. What this catches is an extension added to one and
      # not the other, in either direction.
      #
      # `stl` IS NOT HERE (it routes to the euc Stl rasterizer) and neither are `3dm`, `amf` or
      # `fcstd`, which the BROWSER viewer opens and F3D 3.5.0 lists no reader for. Every entry that
      # IS here came off `f3d --list-readers` on the shipped 3.5.0: obj/gltf/glb/ply/wrl/3ds native,
      # off/dae/fbx assimp, step/stp/iges/igs/brep occt.
      test "covers exactly the mesh + CAD extensions f3d can read and no others" do
        assert_equal %w[obj step stp iges igs brep gltf glb ply off dae wrl 3ds fbx],
                     Maker::Previews::Mesh::EXTENSIONS
        %w[stl 3dm amf fcstd].each do |ext|
          assert_not_includes Maker::Previews::Mesh::EXTENSIONS, ext
        end
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
      #
      # DELIBERATELY NOT SKIPPED when f3d is absent, unlike every other test here: the raise is the
      # first statement in `render`, so no subprocess runs and the binary is irrelevant. Nothing in
      # .github/ installs f3d, so a skip guard would mean this guard never runs in CI at all — the
      # exact "passes only by skipping" hole that hid the bug it was written for.
      test "refuses the model_glb kind — f3d renders rasters, it does not export GLB" do
        err = assert_raises(Maker::GeneratePreviewJob::Unsupported) do
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
