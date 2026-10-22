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
        @off = File.binread(Rails.root.join("test/fixtures/files/tetra.off"))
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

      # ONE OF THE VIEWER WIDENING'S NEW FORMATS THROUGH THE REAL BINARY, and deliberately one the
      # ASSIMP PLUGIN reads (off, dae, fbx), not a native reader: the registry's nine new entries
      # rested on `f3d --list-readers` alone, read on the Homebrew build, so this is what proves the
      # plugin set the shipped tarball carries actually renders (the review's finding).
      test "renders an OFF (assimp plugin) to a PNG thumbnail via f3d" do
        skip "f3d not installed" unless Maker::Previews::Mesh.available?
        result = Maker::Previews::Mesh.render(@off, size: 128, ext: "off")
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

      # WHAT F3D IS TOLD TO PAINT, ASSERTED ON THE ARGV — DELIBERATELY WITHOUT F3D, so it runs on
      # every box including the CI runners, which ship no f3d and would SKIP every render test above.
      # F3D's packaged config draws a grid, an axis gizmo and a filename banner (the job's tempfile
      # path) over a #333333 ground; these flags are the only thing standing between that and the
      # library (see Mesh::PNG_FLAGS for the measurement).
      test "a render tells f3d to paint ink on paper and to draw no grid, axes or filename banner" do
        argv = captured_f3d_argv { Maker::Previews::Mesh.render(@obj, size: 64, ext: "obj") }

        assert_equal Maker::Previews::Mesh::F3D, argv.first, "the fake must have captured the f3d call"
        assert_includes argv, "--background-color=#{Maker::Previews::Palette::PAPER}"
        assert_includes argv, "--color=#{Maker::Previews::Palette::MATERIAL}"
        %w[--grid=false --axis=false --filename=false --metadata=false].each do |flag|
          assert_includes argv, flag
        end
        # THE `=` FORM IS THE FIX, NOT A STYLE: F3D reads `--grid false` as `--grid` (on) plus a
        # second input file named "false", so a bare value anywhere in the argv is that bug back.
        assert_not_includes argv, "false", "a boolean flag lost its `=` and became an input file"
        # `--no-config` would also drop the packaged Z-up iso camera and render a STEP from above.
        assert_not_includes argv, "--no-config"
      end

      test "raises RenderError when f3d cannot process the input" do
        skip "f3d not installed" unless Maker::Previews::Mesh.available?
        assert_raises(Maker::Previews::Mesh::RenderError) do
          Maker::Previews::Mesh.render("not a mesh".b, ext: "stl")
        end
      end

      private

      FakeStatus = Struct.new(:success?, :exitstatus)

      # The argv `Mesh` hands `Open3.capture3`, with no f3d involved: the fake writes a stand-in PNG
      # where `--output` says so, so `to_output` reads it back and returns exactly as it would.
      def captured_f3d_argv(&)
        argv = nil
        fake = lambda do |*args, **|
          argv = args
          File.binwrite(args[args.index("--output") + 1], "\x89PNG\r\n\x1A\n".b)
          [ "", "", FakeStatus.new(true, 0) ]
        end
        replacing(Open3, :capture3, fake, &)
        assert_not_nil argv, "Mesh.render never called Open3.capture3"
        argv
      end

      # The house replacement helper (Minitest 6 has no `Object#stub`): swap one singleton method for
      # the block's duration, restoring — or removing, if it was inherited — afterwards.
      def replacing(owner, name, replacement)
        mod = owner.singleton_class
        own = mod.instance_methods(false).include?(name)
        original = mod.instance_method(name)
        mod.define_method(name, &replacement)
        yield
      ensure
        own ? mod.define_method(name, original) : mod.remove_method(name)
      end
    end
  end
end
