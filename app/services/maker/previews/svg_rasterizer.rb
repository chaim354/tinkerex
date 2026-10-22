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
      #
      # IT EXISTS FOR HAIRLINE VECTOR SOURCES, AND A SOURCE THAT CARRIES REAL WIDTHS MUST OPT OUT
      # (`stylesheet: nil`, since 2026-09-07). `Maker::Previews::Gerber` is the first: a tracespace
      # render writes the APERTURE'S OWN DIAMETER onto every path — measured against the vendored
      # bundle, a 0.5 mm round aperture emits `<path stroke-width="0.5">` (tools/gerber-svg/
      # render.mjs's header quotes the whole output) — so this rule would flatten a 0.5 mm signal
      # trace and a 2 mm power trace to one 1.5 px line and throw away the one thing a board
      # thumbnail is for. Worse on a composed board, whose substrate and mask are `<rect>`s
      # inheriting `stroke="currentColor"` at `stroke-width="0"`: 1.5 px paints a border on each.
      # The default stays what it was, so every existing caller is untouched.
      STYLESHEET = "* { vector-effect: non-scaling-stroke; stroke-width: 1.5px; }\n".freeze

      # SVG bytes/string -> PNG bytes (a size×size raster; the SVG's preserveAspectRatio fits it).
      #
      # `stylesheet: nil` PASSES NO `--stylesheet` FLAG AT ALL — it does not pass an empty one. An
      # empty stylesheet would be indistinguishable in the output today and is a different claim:
      # this is "resvg renders what the SVG says", not "we override it with nothing".
      def to_png(svg, size: 512, stylesheet: STYLESHEET)
        Tempfile.create([ "resvg-in", ".svg" ]) do |fin|
          fin.binmode
          fin.write(svg.to_s.b)
          fin.flush

          next rasterize(fin.path, size:, css_path: nil) if stylesheet.nil?

          Tempfile.create([ "resvg-css", ".css" ]) do |fcss|
            fcss.write(stylesheet)
            fcss.flush
            rasterize(fin.path, size:, css_path: fcss.path)
          end
        end
      rescue Errno::ENOENT, Errno::EACCES => e
        raise RasterizeError, "resvg not runnable: #{e.message}"
      end

      # ONE resvg INVOCATION. Split out of `to_png` when `stylesheet:` arrived so the two arms
      # share the argv, the success check and the output cleanup — the alternative (a conditional
      # inside the css Tempfile block) creates a temp file the flagless arm never names.
      def rasterize(in_path, size:, css_path:)
        out_path = "#{in_path}.png"
        # --background Palette::PAPER: render onto an OPAQUE white canvas rather than transparent.
        # The browser MULTIPLIES every thumbnail onto a themed card (`Maker::Previews::Palette`), so
        # the ground must be exactly white to become the card; a transparent PNG of thin geometry
        # would read as blank, and the file's own (often black) colours need a light ground in both
        # themes. --stylesheet: see STYLESHEET.
        #
        # NAMED FROM THE PALETTE, WITH NO REVISION BUMP ANYWHERE. resvg 0.47 takes a CSS colour, and
        # `#ffffff` rendered BYTE-IDENTICAL to the `white` this replaced (measured through this
        # method, stylesheet and all, on the three fixture SVGs), so no Svg/Dxf/Lbrn2/Gerber picture
        # changed through this line — bump a renderer only for a change its pixels can see.
        # (TextThumb's bump is for its INK, not for this.)
        argv = [ bin, "--width", size.to_s, "--height", size.to_s, "--background", Palette::PAPER ]
        argv.push("--stylesheet", css_path) if css_path
        argv.push(in_path, out_path)

        _stdout, stderr, status = Open3.capture3(*argv)
        unless status.success? && File.exist?(out_path) && File.size?(out_path)
          raise RasterizeError, "resvg failed (#{status.exitstatus}): #{stderr.to_s[0, 300]}"
        end
        File.binread(out_path)
      ensure
        File.delete(out_path) if out_path && File.exist?(out_path)
      end
    end
  end
end
