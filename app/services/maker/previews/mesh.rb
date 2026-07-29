require "open3"
require "tempfile"

module Maker
  module Previews
    # Mesh + CAD (`.stl`, `.obj`, `.step`/`.stp`, `.iges`/`.igs`) → thumbnail PNG. NOT GLB: F3D
    # renders rasters, it does not convert scenes — see `render`.
    #
    # Renders headless via the **F3D** CLI (BSD-3 — CLAUDE.md §9), one binary that covers all
    # meshes and (through its OCCT plugin) STEP/IGES. F3D is invoked as a SUBPROCESS, which keeps
    # the LGPL OpenCASCADE dependency out-of-process / out of our shipped binary (the same posture
    # §9 takes for FUSE drivers). See docs/research-format-processing.md §3/§6.
    #
    # `available?` gates on the `f3d` binary being on PATH (overridable via F3D_BIN), so a box
    # without F3D fails the preview gracefully (the job marks `unsupported`) and tests SKIP.
    module Mesh
      module_function

      RenderError = Class.new(StandardError)

      # NB: `stl` is NOT here — it routes to Maker::Previews::Stl (the euc rasterizer), not F3D.
      # The renderer contract test pins EXTENSIONS to what the Registry actually resolves, so a
      # stale `stl` here fails loudly rather than lying about ownership.
      EXTENSIONS = %w[obj step stp iges igs].freeze

      F3D = ENV.fetch("F3D_BIN", "f3d").freeze

      # Extension (without dot) → the tempfile suffix F3D needs to pick its loader plugin.
      def available?
        out, status = Open3.capture2e(F3D, "--version")
        # CASE-INSENSITIVE on purpose. F3D 3.x's banner is "F3D 3.5.0 / F3D - A fast and minimalist
        # 3D viewer / …" — there is NO lowercase "f3d" anywhere in it. A literal include?("f3d")
        # therefore reports a perfectly good binary as UNAVAILABLE, and every .obj/.step/.iges
        # silently falls through to `unsupported`. Match the name, not one release's capitalisation.
        status.success? && out.downcase.include?("f3d")
      rescue Errno::ENOENT, Errno::EACCES
        false
      end

      # kind: "thumbnail" → PNG. Returns { bytes:, content_type:, width:, height: }.
      #
      # `model_glb` is REFUSED, and the refusal is the point. F3D's `--output` is a raster
      # screenshot — `--help` spells the argument `<png file>` and it writes a PNG whatever the
      # output extension says. Asking it for a `.glb` therefore yielded PNG bytes that
      # GeneratePreviewJob attached as `model_glb-<id>.glb` with content_type model/gltf-binary and
      # marked "ready": a corrupt file presented as valid, reachable from the v1 previews API, which
      # permits a client-supplied `kind`. `.glb` is an INPUT format for F3D, not an output one.
      # This was unreachable only because `available?` never returned true (see above) — so it must
      # be closed in the same change that makes `available?` work. Raising lands the preview in
      # "failed" with a legible reason instead of shipping a broken model.
      def render(mesh_bytes, size: 512, kind: "thumbnail", ext: nil)
        if kind == "model_glb"
          raise RenderError, "f3d cannot export GLB: --output renders a raster image (.glb is an input format only)"
        end

        png = to_output(mesh_bytes, ext:, out_ext: ".png", size:)
        { bytes: png.b, content_type: "image/png", width: size, height: size }
      end

      # Write the input to a tempfile (F3D dispatches on the input extension), render to a
      # tempfile output, read it back. `--output` runs F3D fully headless (offscreen).
      def to_output(mesh_bytes, ext:, out_ext:, size: 512)
        in_suffix = ext ? ".#{ext.to_s.delete_prefix('.').downcase}" : ".stl"
        Tempfile.create([ "f3d-in", in_suffix ]) do |fin|
          fin.binmode
          fin.write(mesh_bytes.b)
          fin.flush

          out_path = "#{fin.path}#{out_ext}"
          begin
            args = [ F3D, fin.path, "--output", out_path ]
            args += [ "--resolution", "#{size},#{size}" ] if out_ext == ".png"

            _stdout, stderr, status = Open3.capture3(*args)
            unless status.success? && File.exist?(out_path) && File.size?(out_path)
              raise RenderError, "f3d failed (#{status.exitstatus}): #{stderr.to_s[0, 300]}"
            end
            File.binread(out_path)
          ensure
            File.delete(out_path) if File.exist?(out_path)
          end
        end
      rescue Errno::ENOENT => e
        raise RenderError, "f3d not runnable: #{e.message}"
      end
    end
  end
end
