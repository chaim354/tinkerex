require "open3"
require "tempfile"

module Maker
  module Previews
    # Mesh + CAD (`.stl`, `.obj`, `.step`/`.stp`, `.iges`/`.igs`) → thumbnail PNG (and, for the
    # `model_glb` kind, a web-friendly GLB).
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
        status.success? && out.include?("f3d")
      rescue Errno::ENOENT, Errno::EACCES
        false
      end

      # kind: "thumbnail" → PNG; "model_glb" → GLB (web 3D). Defaults to a PNG thumbnail.
      # Returns { bytes:, content_type:, width:, height: }.
      def render(mesh_bytes, size: 512, kind: "thumbnail", ext: nil)
        if kind == "model_glb"
          glb = to_output(mesh_bytes, ext:, out_ext: ".glb")
          { bytes: glb.b, content_type: "model/gltf-binary", width: nil, height: nil }
        else
          png = to_output(mesh_bytes, ext:, out_ext: ".png", size:)
          { bytes: png.b, content_type: "image/png", width: size, height: size }
        end
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
