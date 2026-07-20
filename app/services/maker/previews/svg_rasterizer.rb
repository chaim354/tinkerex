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

      # THE THUMBNAIL STYLESHEET, injected into every render (resvg --stylesheet). It makes an
      # otherwise-invisible drawing legible without altering its geometry, and it is why one
      # rasterizer covers user SVGs AND our own DXF/LightBurn output:
      #   * `vector-effect: non-scaling-stroke; stroke-width: 1.5px` — a maker's laser/CAD source
      #     (Tinkercad, LightBurn, a DXF) sets a HAIRLINE stroke in real-world units (e.g.
      #     stroke-width="0.001mm" or "0.5" drawing units). Fitted into a ~512px thumbnail that
      #     collapses to a sub-pixel line and the preview reads as an EMPTY canvas. non-scaling-stroke
      #     pins the width to device pixels (independent of the viewBox scale) and 1.5px makes it
      #     visible, while leaving the SHAPE untouched. A presentation-attribute stroke-width is
      #     overridden by this rule (an inline style= would win, an acceptable gap).
      # Applied to `*`, so a fill-only shape (no stroke) is unaffected — nothing to stroke.
      STYLESHEET = "* { vector-effect: non-scaling-stroke; stroke-width: 1.5px; }\n".freeze

      # SVG bytes/string -> PNG bytes (a size×size raster; the SVG's preserveAspectRatio fits it).
      def to_png(svg, size: 512)
        Tempfile.create([ "resvg-in", ".svg" ]) do |fin|
          fin.binmode
          fin.write(svg.to_s.b)
          fin.flush

          Tempfile.create([ "resvg-css", ".css" ]) do |fcss|
            fcss.write(STYLESHEET)
            fcss.flush

            out_path = "#{fin.path}.png"
            begin
              # --background white: render onto an OPAQUE white canvas rather than transparent.
              # Thumbnails sit on a light card, and a transparent PNG of thin geometry reads as
              # blank; white gives dark geometry consistent contrast. --stylesheet: see STYLESHEET.
              _stdout, stderr, status = Open3.capture3(
                bin, "--width", size.to_s, "--height", size.to_s,
                "--background", "white", "--stylesheet", fcss.path, fin.path, out_path
              )
              unless status.success? && File.exist?(out_path) && File.size?(out_path)
                raise RasterizeError, "resvg failed (#{status.exitstatus}): #{stderr.to_s[0, 300]}"
              end
              File.binread(out_path)
            ensure
              File.delete(out_path) if File.exist?(out_path)
            end
          end
        end
      rescue Errno::ENOENT, Errno::EACCES => e
        raise RasterizeError, "resvg not runnable: #{e.message}"
      end
    end
  end
end
