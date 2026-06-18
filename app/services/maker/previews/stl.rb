require "open3"
require "tempfile"

module Maker
  module Previews
    # STL → thumbnail PNG via the in-repo `stl-thumbnailer` binary (client/stl-thumbnailer):
    # a pure-CPU software rasterizer (euc, Apache/MIT) — NO GPU, NO OpenGL/Mesa, NO headless
    # browser. The same crate also runs in the Tauri desktop core, so a device that holds the
    # file can render + upload the thumbnail; this server-side path is the universal fallback
    # (e.g. web uploads). Replaces F3D for `.stl` (F3D still covers obj/step via its OCCT plugin).
    #
    # `available?` gates on the binary being on PATH (overridable via STL_THUMBNAILER_BIN), so a
    # box without it fails the preview gracefully (the job marks `unsupported`) and tests SKIP.
    module Stl
      module_function

      RenderError = Class.new(StandardError)

      EXTENSIONS = %w[stl].freeze

      BIN = ENV.fetch("STL_THUMBNAILER_BIN", "stl-thumbnailer").freeze

      def available?
        # Running the binary (even with no/invalid args → usage + non-zero exit) confirms it
        # exists; only a missing/inexecutable binary raises ENOENT/EACCES.
        Open3.capture2e(BIN)
        true
      rescue Errno::ENOENT, Errno::EACCES
        false
      end

      # PNG thumbnail. `kind` is ignored (this renderer only produces thumbnails; the interactive
      # 3D/GLB path is client-side Three.js, not this). Returns { bytes:, content_type:, width:, height: }.
      def render(stl_bytes, size: 512, kind: "thumbnail", ext: nil) # rubocop:disable Lint/UnusedMethodArgument
        Tempfile.create([ "stl-in", ".stl" ]) do |fin|
          fin.binmode
          fin.write(stl_bytes.b)
          fin.flush

          out_path = "#{fin.path}.png"
          begin
            _stdout, stderr, status = Open3.capture3(BIN, fin.path, out_path, size.to_s, size.to_s)
            unless status.success? && File.exist?(out_path) && File.size?(out_path)
              raise RenderError, "stl-thumbnailer failed (#{status.exitstatus}): #{stderr.to_s[0, 300]}"
            end

            { bytes: File.binread(out_path), content_type: "image/png", width: size, height: size }
          ensure
            File.delete(out_path) if File.exist?(out_path)
          end
        end
      rescue Errno::ENOENT => e
        raise RenderError, "stl-thumbnailer not runnable: #{e.message}"
      end
    end
  end
end
