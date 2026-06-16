require "nokogiri"

module Maker
  module Previews
    # LightBurn (`.lbrn2`) → SVG → PNG.
    #
    # `.lbrn2` is LightBurn's XML project format: `<LightBurnProject>` with `<CutSetting>`
    # entries (a stroke color per cut, indexed) and `<Shape>` elements (Rect/Ellipse/Line/Path)
    # carrying geometry + an `XForm` 2D affine and a `CutIndex` linking the stroke color.
    #
    # We parse the subset needed for a thumbnail (Nokogiri, MIT — CLAUDE.md §9), emit an SVG,
    # and delegate to the existing `Svg` renderer (SVG bytes are themselves browser-renderable,
    # so no rasterizer is required — same as the Phase-1 SVG path). Porting reference:
    # jlucaso1/lbrn2-to-svg (MIT). See docs/research-format-processing.md §1.
    #
    # Pure-Ruby → `available?` is always true (the SVG path needs no external binary).
    module Lbrn2
      module_function

      ParseError = Class.new(StandardError)

      EXTENSIONS = %w[lbrn2 lbrn].freeze

      DEFAULT_STROKE = "#000000".freeze

      def available? = Maker::Previews::Svg.available?

      # Returns whatever `Svg.render` returns (SVG bytes verbatim by default).
      def render(lbrn2_bytes, size: 512)
        svg = to_svg(lbrn2_bytes, size:)
        Maker::Previews::Svg.render(svg, size:)
      end

      # lbrn2 XML → an SVG string. Geometry is mapped into a viewBox sized to the shapes'
      # bounding box (with a Y-flip, since LightBurn is Y-up and SVG is Y-down).
      def to_svg(lbrn2_bytes, size: 512)
        doc = Nokogiri::XML(lbrn2_bytes) { |c| c.recover }
        raise ParseError, "not a LightBurn project" if doc.root.nil?

        colors = cut_colors(doc)
        elements = []
        bbox = BBox.new

        doc.xpath("//Shape").each do |shape|
          stroke = colors[shape["CutIndex"]] || DEFAULT_STROKE
          xform  = parse_xform(shape["XForm"])
          svg_el = shape_to_svg(shape, stroke, xform, bbox)
          elements << svg_el if svg_el
        end

        wrap_svg(elements, bbox, size)
      rescue Nokogiri::XML::SyntaxError => e
        raise ParseError, "lbrn2 XML parse failed: #{e.message}"
      end

      # CutIndex (string) → stroke color "#rrggbb". LightBurn stores the color as a 0xBBGGRR
      # integer (or sometimes "#rgb"); normalize to "#rrggbb".
      def cut_colors(doc)
        out = {}
        doc.xpath("//CutSetting").each do |cs|
          idx = cs["index"] || cs.at_xpath("index")&.[]("Value") || cs.at_xpath("index")&.text
          raw = cs.at_xpath("color")&.[]("Value") || cs.at_xpath("color")&.text || cs["color"]
          out[idx.to_s] = normalize_color(raw) if idx
        end
        out
      end

      def normalize_color(raw)
        return DEFAULT_STROKE if raw.nil? || raw.to_s.strip.empty?

        s = raw.to_s.strip
        return s if s.start_with?("#")

        n = Integer(s, exception: false)
        return DEFAULT_STROKE if n.nil?

        # LightBurn packs colors little-endian as 0x00BBGGRR.
        r = n & 0xFF
        g = (n >> 8) & 0xFF
        b = (n >> 16) & 0xFF
        format("#%02x%02x%02x", r, g, b)
      end

      # "1 0 0 1 tx ty" (a b c d e f) affine → [a, b, c, d, e, f]; identity on miss.
      def parse_xform(str)
        nums = str.to_s.split.map { |t| Float(t, exception: false) }.compact
        nums.length == 6 ? nums : [ 1.0, 0.0, 0.0, 1.0, 0.0, 0.0 ]
      end

      # Apply the affine, then flip Y (LightBurn is Y-up; SVG is Y-down) so emitted points and
      # the bounding box share one coordinate system and the thumbnail renders right-side up.
      def apply(xform, x, y)
        a, b, c, d, e, f = xform
        tx = (a * x) + (c * y) + e
        ty = (b * x) + (d * y) + f
        [ tx, -ty ]
      end

      # Map one <Shape> to an SVG element string, accumulating its points into the bbox.
      def shape_to_svg(shape, stroke, xform, bbox)
        case shape["Type"]
        when "Rect"      then rect_svg(shape, stroke, xform, bbox)
        when "Ellipse"   then ellipse_svg(shape, stroke, xform, bbox)
        when "Line"      then line_svg(shape, stroke, xform, bbox)
        when "Path"      then path_svg(shape, stroke, xform, bbox)
        end
      end

      def rect_svg(shape, stroke, xform, bbox)
        w = num(shape["W"]); h = num(shape["H"])
        return nil if w.nil? || h.nil?

        # LightBurn rects are centered at the XForm origin.
        corners = [ [ -w / 2, -h / 2 ], [ w / 2, -h / 2 ], [ w / 2, h / 2 ], [ -w / 2, h / 2 ] ]
        pts = corners.map { |(x, y)| apply(xform, x, y) }
        pts.each { |(x, y)| bbox.add(x, y) }
        polygon(pts, stroke)
      end

      def ellipse_svg(shape, stroke, xform, bbox)
        rx = num(shape["Rx"]); ry = num(shape["Ry"])
        return nil if rx.nil? || ry.nil?

        cx, cy = apply(xform, 0, 0)
        bbox.add(cx - rx, cy - ry)
        bbox.add(cx + rx, cy + ry)
        %(<ellipse cx="#{f(cx)}" cy="#{f(cy)}" rx="#{f(rx)}" ry="#{f(ry)}" ) +
          %(fill="none" stroke="#{stroke}" stroke-width="0.5"/>)
      end

      def line_svg(shape, stroke, xform, bbox)
        verts = vertices(shape)
        return nil if verts.length < 2

        pts = verts.map { |(x, y)| apply(xform, x, y) }
        pts.each { |(x, y)| bbox.add(x, y) }
        polyline(pts, stroke)
      end

      def path_svg(shape, stroke, xform, bbox)
        verts = vertices(shape)
        return nil if verts.length < 2

        pts = verts.map { |(x, y)| apply(xform, x, y) }
        pts.each { |(x, y)| bbox.add(x, y) }
        polyline(pts, stroke)
      end

      # Pull a shape's vertices. LightBurn stores them as <VertList> text ("V0x0y0 V1x10y0 …")
      # or as child <V vx=".." vy=".."> elements. Best-effort across both shapes.
      def vertices(shape)
        nodes = shape.xpath(".//V[@vx]")
        if nodes.any?
          return nodes.map { |v| [ num(v["vx"]), num(v["vy"]) ] }.reject { |p| p.include?(nil) }
        end

        text = shape.at_xpath(".//VertList")&.text || shape["VertList"] || shape.text
        parse_vertlist(text)
      end

      # "V0x0y0V1x10y5" → [[0,0],[10,5]] (each Vn has an xNUM and yNUM token).
      def parse_vertlist(text)
        return [] if text.nil?

        text.to_s.scan(/x(-?[\d.]+)\s*y(-?[\d.]+)/).map do |(x, y)|
          [ Float(x, exception: false), Float(y, exception: false) ]
        end.reject { |p| p.include?(nil) }
      end

      def polygon(pts, stroke)
        %(<polygon points="#{points_attr(pts)}" fill="none" stroke="#{stroke}" stroke-width="0.5"/>)
      end

      def polyline(pts, stroke)
        %(<polyline points="#{points_attr(pts)}" fill="none" stroke="#{stroke}" stroke-width="0.5"/>)
      end

      def points_attr(pts)
        pts.map { |(x, y)| "#{f(x)},#{f(y)}" }.join(" ")
      end

      # Compose the final SVG. Empty projects still produce a valid (blank) SVG so the job
      # marks `ready` rather than crashing.
      def wrap_svg(elements, bbox, size)
        vb = bbox.viewbox(fallback: size)
        body = elements.join("\n  ")
        <<~SVG
          <svg xmlns="http://www.w3.org/2000/svg" width="#{size}" height="#{size}" viewBox="#{vb}">
            #{body}
          </svg>
        SVG
      end

      def num(str)
        Float(str, exception: false)
      end

      # Compact float formatting for SVG attributes.
      def f(val)
        return "0" if val.nil?

        r = val.round(3)
        (r == r.to_i ? r.to_i : r).to_s
      end

      # Accumulating bounding box over already-transformed (Y-flipped) SVG coordinates — see
      # `apply`. Used to size the viewBox to the geometry.
      class BBox
        def initialize
          @min_x = @min_y = Float::INFINITY
          @max_x = @max_y = -Float::INFINITY
        end

        def add(x, y)
          return if x.nil? || y.nil?

          @min_x = x if x < @min_x
          @min_y = y if y < @min_y
          @max_x = x if x > @max_x
          @max_y = y if y > @max_y
        end

        def empty? = @min_x == Float::INFINITY

        def viewbox(fallback:)
          return "0 0 #{fallback} #{fallback}" if empty?

          pad = 2.0
          w = [ @max_x - @min_x, 1.0 ].max + (pad * 2)
          h = [ @max_y - @min_y, 1.0 ].max + (pad * 2)
          fmt = ->(v) { (v.round(3) == v.round(3).to_i ? v.round(3).to_i : v.round(3)) }
          "#{fmt.call(@min_x - pad)} #{fmt.call(@min_y - pad)} #{fmt.call(w)} #{fmt.call(h)}"
        end
      end
    end
  end
end
