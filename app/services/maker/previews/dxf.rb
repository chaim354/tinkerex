module Maker
  module Previews
    # DXF (`.dxf`) → SVG → PNG.
    #
    # DXF (AutoCAD interchange) is a tagged "group code / value" ASCII format: pairs of lines
    # where an integer group code is followed by its value. DWG (the binary sibling) has no
    # permissive parser (LibreDWG is GPL) and is intentionally NOT handled here. We ship a
    # minimal, dependency-free in-Ruby parser for the common 2D entities a maker's laser/CNC
    # source carries — LINE, LWPOLYLINE/POLYLINE, CIRCLE, ARC — and emit an SVG, then delegate
    # to the existing `Svg` renderer (SVG is itself browser-renderable, no rasterizer needed).
    #
    # No GPL/AGPL: pure stdlib Ruby (the ezdxf-via-Python path in the research doc is an
    # alternative; this minimal parser avoids the external Python runtime entirely while
    # staying permissive). See docs/research-format-processing.md §5.
    #
    # `available?` is always true (pure Ruby + the verbatim-SVG path).
    module Dxf
      module_function

      ParseError = Class.new(StandardError)

      EXTENSIONS = %w[dxf].freeze

      STROKE = "#000000".freeze

      def available? = Maker::Previews::Svg.available?

      def render(dxf_bytes, size: 512)
        svg = to_svg(dxf_bytes, size:)
        Maker::Previews::Svg.render(svg, size:)
      end

      def to_svg(dxf_bytes, size: 512)
        pairs = tokenize(dxf_bytes)
        entities = parse_entities(pairs)
        bbox = BBox.new
        els = entities.filter_map { |e| entity_to_svg(e, bbox) }
        wrap_svg(els, bbox, size)
      end

      # DXF is (code, value) pairs on alternating lines. Tolerant of CRLF and leading spaces.
      def tokenize(bytes)
        lines = bytes.to_s.b.force_encoding("UTF-8").scrub.split(/\r\n|\r|\n/)
        pairs = []
        i = 0
        while i + 1 < lines.length
          code = lines[i].strip
          value = lines[i + 1]
          pairs << [ code.to_i, value.to_s.strip ] if code.match?(/\A-?\d+\z/)
          i += 2
        end
        pairs
      end

      # Walk the pairs, slicing them into entity records keyed by their group codes. We only
      # look at the ENTITIES section's records; unknown entity types are skipped.
      def parse_entities(pairs)
        entities = []
        current = nil

        pairs.each do |(code, value)|
          if code.zero? # a "0" code starts a new entity (or section marker)
            entities << current if current
            # VERTEX is captured too (not drawn itself) so old-style POLYLINE can reclaim its
            # points — see fold_polyline_vertices.
            current =
              if ENTITY_TYPES.include?(value) || value == "VERTEX"
                { type: value, codes: Hash.new { |h, k| h[k] = [] } }
              end
          elsif current
            current[:codes][code] << value
          end
        end
        entities << current if current
        fold_polyline_vertices(entities)
      end

      # Old-style POLYLINE (as opposed to LWPOLYLINE) stores its points in the VERTEX entities that
      # FOLLOW it, terminated by SEQEND — NOT in its own group codes. The parser would otherwise
      # keep a POLYLINE with a single 10/20 pair and drop every VERTEX, so the polyline rendered as
      # nothing (a real DXF from many CAD tools is dominated by these). Attach each run of VERTEX
      # points to the preceding POLYLINE as :verts and drop the VERTEX records. LWPOLYLINE is
      # untouched — its points are inline repeated 10/20 codes.
      def fold_polyline_vertices(entities)
        out = []
        poly = nil
        entities.each do |e|
          case e[:type]
          when "POLYLINE"
            e[:verts] = []
            poly = e
            out << e
          when "VERTEX"
            next unless poly

            x = e[:codes][10].first
            y = e[:codes][20].first
            poly[:verts] << [ x, y ] if x && y
          else
            poly = nil
            out << e
          end
        end
        out
      end

      ENTITY_TYPES = %w[LINE LWPOLYLINE POLYLINE CIRCLE ARC].freeze

      def entity_to_svg(entity, bbox)
        case entity[:type]
        when "LINE"                 then line_svg(entity, bbox)
        when "CIRCLE"               then circle_svg(entity, bbox)
        when "ARC"                  then arc_svg(entity, bbox)
        when "LWPOLYLINE", "POLYLINE" then polyline_svg(entity, bbox)
        end
      end

      def line_svg(entity, bbox)
        c = entity[:codes]
        x1 = f1(c[10]); y1 = f1(c[20]); x2 = f1(c[11]); y2 = f1(c[21])
        return nil if [ x1, y1, x2, y2 ].any?(&:nil?)

        p1 = flip(x1, y1); p2 = flip(x2, y2)
        bbox.add(*p1); bbox.add(*p2)
        %(<line x1="#{n(p1[0])}" y1="#{n(p1[1])}" x2="#{n(p2[0])}" y2="#{n(p2[1])}" ) +
          %(stroke="#{STROKE}" stroke-width="0.5"/>)
      end

      def circle_svg(entity, bbox)
        c = entity[:codes]
        cx = f1(c[10]); cy = f1(c[20]); r = f1(c[40])
        return nil if [ cx, cy, r ].any?(&:nil?)

        fx, fy = flip(cx, cy)
        bbox.add(fx - r, fy - r); bbox.add(fx + r, fy + r)
        %(<circle cx="#{n(fx)}" cy="#{n(fy)}" r="#{n(r)}" fill="none" ) +
          %(stroke="#{STROKE}" stroke-width="0.5"/>)
      end

      # ARC → an SVG path arc. DXF angles are CCW degrees from +X; with the Y-flip we draw the
      # endpoints and let a large-arc/sweep flag approximate the segment.
      def arc_svg(entity, bbox)
        c = entity[:codes]
        cx = f1(c[10]); cy = f1(c[20]); r = f1(c[40])
        a0 = f1(c[50]); a1 = f1(c[51])
        return nil if [ cx, cy, r, a0, a1 ].any?(&:nil?)

        sweep = ((a1 - a0) % 360)
        sx = cx + (r * Math.cos(a0 * Math::PI / 180))
        sy = cy + (r * Math.sin(a0 * Math::PI / 180))
        ex = cx + (r * Math.cos(a1 * Math::PI / 180))
        ey = cy + (r * Math.sin(a1 * Math::PI / 180))
        ps = flip(sx, sy); pe = flip(ex, ey)
        bbox.add(*flip(cx - r, cy - r)); bbox.add(*flip(cx + r, cy + r))
        large = sweep > 180 ? 1 : 0
        # Y-flip reverses orientation, so the sweep flag flips from CCW (1) to 0.
        %(<path d="M #{n(ps[0])} #{n(ps[1])} A #{n(r)} #{n(r)} 0 #{large} 0 #{n(pe[0])} #{n(pe[1])}" ) +
          %(fill="none" stroke="#{STROKE}" stroke-width="0.5"/>)
      end

      # LWPOLYLINE: vertex X in code 10 (repeated), Y in code 20 (repeated). POLYLINE in older
      # DXF carries verts as following VERTEX entities — we approximate with the 10/20 lists,
      # which covers LWPOLYLINE (the common modern form) directly.
      def polyline_svg(entity, bbox)
        c = entity[:codes]
        raw =
          if entity[:verts]&.any?
            # Old-style POLYLINE: points reclaimed from its VERTEX sub-entities.
            entity[:verts].map { |(x, y)| [ Float(x, exception: false), Float(y, exception: false) ] }
          else
            # LWPOLYLINE: points are repeated 10/20 group codes on the entity itself.
            xs = c[10].map { |v| Float(v, exception: false) }
            ys = c[20].map { |v| Float(v, exception: false) }
            xs.zip(ys)
          end
        pts = raw.reject { |(x, y)| x.nil? || y.nil? }.map { |(x, y)| flip(x, y) }
        return nil if pts.length < 2

        pts.each { |(x, y)| bbox.add(x, y) }
        closed = (c[70].first.to_i & 1) == 1
        tag = closed ? "polygon" : "polyline"
        attr = pts.map { |(x, y)| "#{n(x)},#{n(y)}" }.join(" ")
        %(<#{tag} points="#{attr}" fill="none" stroke="#{STROKE}" stroke-width="0.5"/>)
      end

      # First value for a group code, as Float; nil when absent/unparseable.
      def f1(list)
        return nil if list.nil? || list.empty?

        Float(list.first, exception: false)
      end

      # DXF is Y-up; SVG is Y-down. Flip Y so the thumbnail renders right-side up.
      def flip(x, y) = [ x, -y ]

      def n(val)
        return "0" if val.nil?

        r = val.round(3)
        (r == r.to_i ? r.to_i : r).to_s
      end

      def wrap_svg(elements, bbox, size)
        vb = bbox.viewbox(fallback: size)
        body = elements.join("\n  ")
        <<~SVG
          <svg xmlns="http://www.w3.org/2000/svg" width="#{size}" height="#{size}" viewBox="#{vb}">
            #{body}
          </svg>
        SVG
      end

      # Bounding box over transformed SVG coords (reused shape as lbrn2's, kept local to avoid
      # coupling the two renderers).
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
          fmt = ->(v) { r = v.round(3); r == r.to_i ? r.to_i : r }
          "#{fmt.call(@min_x - pad)} #{fmt.call(@min_y - pad)} #{fmt.call(w)} #{fmt.call(h)}"
        end
      end
    end
  end
end
