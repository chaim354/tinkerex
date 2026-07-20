require "open3"
require "tempfile"

module Maker
  module Previews
    # SVG string -> PNG bytes, via the `resvg` CLI (Rust, MPL-2.0/Apache -- permissive, CLAUDE.md
    # §9). A single static binary, NO GPU / OpenGL / Mesa / headless browser -- the same posture as
    # `stl-thumbnailer`. This is the ONE rasterize step: Svg/Dxf/Lbrn2 all route their generated
    # SVG through here, so every 2D-vector thumbnail comes out as a uniform PNG (which is also why
    # the web layer can inline it -- an SVG could carry <script>, a PNG cannot).
    #
    # `available?` gates on the binary being runnable (overridable via RESVG_BIN), so a box without
    # resvg degrades the SVG/DXF/LightBurn renderers to `unsupported` rather than crashing -- the
    # same graceful path Stl/Mesh take when their toolchain is absent.
    module SvgRasterizer
      module_function

      RasterizeError = Class.new(StandardError)

      def bin = @bin ||= ENV.fetch("RESVG_BIN", "resvg")

      def reset_bin! = @bin = nil

      def available?
        # Running with no args prints usage + a non-zero exit; only a missing/inexecutable binary
        # raises ENOENT/EACCES.
        Open3.capture2e(bin)
        true
      rescue Errno::ENOENT, Errno::EACCES
        false
      end

      # SVG bytes/string -> PNG bytes (a size×size raster; the SVG's preserveAspectRatio fits it).
      def to_png(svg, size: 512)
        Tempfile.create([ "resvg-in", ".svg" ]) do |fin|
          fin.binmode
          fin.write(svg.to_s.b)
          fin.flush

          out_path = "#{fin.path}.png"
          begin
            _stdout, stderr, status = Open3.capture3(
              bin, "--width", size.to_s, "--height", size.to_s, fin.path, out_path
            )
            unless status.success? && File.exist?(out_path) && File.size?(out_path)
              raise RasterizeError, "resvg failed (#{status.exitstatus}): #{stderr.to_s[0, 300]}"
            end
            File.binread(out_path)
          ensure
            File.delete(out_path) if File.exist?(out_path)
          end
        end
      rescue Errno::ENOENT, Errno::EACCES => e
        raise RasterizeError, "resvg not runnable: #{e.message}"
      end
    end
  end
end
