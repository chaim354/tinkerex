require "nokogiri"
require "set"
require "base64"

module Maker
  module Previews
    # LightBurn (`.lbrn2`) → SVG → PNG.
    #
    # `.lbrn2` is LightBurn's XML project format: `<LightBurnProject>` with `<CutSetting>`
    # entries (a stroke color per cut, indexed) and `<Shape>` elements (Rect/Ellipse/Path/
    # Group/Text/Bitmap) carrying geometry, an `<XForm>` 2D affine and a `CutIndex` linking
    # the stroke color.
    #
    # We parse the subset needed for a thumbnail (Nokogiri, MIT — CLAUDE.md §9), emit an SVG,
    # and delegate to the existing `Svg` renderer (SVG bytes are themselves browser-renderable,
    # so no rasterizer is required — same as the Phase-1 SVG path).
    #
    # THE DIALECT HERE IS THE ONE LIGHTBURN ACTUALLY WRITES, and it is not the obvious one.
    # An earlier version of this file parsed a form LightBurn has never emitted; measured over
    # 58 real exports (1.4.04 → 1.7.08) it drew 96 of 9,436 shapes — 1.0%. The four things it
    # got wrong are each load-bearing, so they are called out where they are handled:
    #   * `<XForm>` is a CHILD ELEMENT (0 attribute vs 9,517 element occurrences).
    #   * `<VertList>` is `V<x> <y>c0x..c0y..c1x..c1y..`, not `V0x0y0`.
    #   * `<PrimList>` carries the connectivity, including curves.
    #   * A `VertID` with no `<VertList>` INSTANCES another shape's geometry.
    # The `real-export.lbrn2` fixture pins all four; `sample.lbrn2` is hand-authored and stays
    # only to prove the older/simpler form still parses.
    #
    # Pure-Ruby → `available?` is always true (the SVG path needs no external binary).
    module Lbrn2
      module_function

      ParseError = Class.new(StandardError)

      EXTENSIONS = %w[lbrn2 lbrn].freeze

      DEFAULT_STROKE = "#000000".freeze

      IDENTITY = [ 1.0, 0.0, 0.0, 1.0, 0.0, 0.0 ].freeze

      # Curves are flattened for rendering. Even (so t=0.5, a curve's usual extreme, is sampled)
      # and small — a 512px thumbnail cannot show more, and a big project holds ~9k paths.
      BEZIER_SAMPLES = 12

      # Divisible by 4, so an unrotated ellipse's axis extents are hit exactly.
      ELLIPSE_SAMPLES = 32

      def available? = Maker::Previews::Svg.available?

      # Embedded thumbnail FIRST — a LightBurn file carries its own full-colour render in a
      # <Thumbnail Source="base64png"> attribute, which is far better than re-drawing the geometry
      # as outlines. Fall back to the hand-rolled geometry parser (-> SVG -> PNG) only when a file
      # has no embedded thumbnail (older LightBurn versions, or a hand-authored file).
      def render(lbrn2_bytes, size: 512)
        meta = Maker::Previews::LbrnMetadata.parse(lbrn2_bytes)
        img = Maker::Previews::EmbeddedThumbnail.extract(lbrn2_bytes) ||
              Maker::Previews::Svg.render(to_svg(lbrn2_bytes, size:), size:)
        img.merge(metadata: meta)
      end

      # Parse a LightBurn document.
      #
      # `huge` is REQUIRED, not a tuning knob. LightBurn inlines a placed photo as base64 in
      # `Bitmap@Data`, and libxml2 caps a single attribute value at 10 MB. Past that it raises
      # "Buffer size limit exceeded, try XML_PARSE_HUGE" and `recover` hands back a TRUNCATED
      # tree — root intact, every Shape after the image gone. The failure is silent: the file
      # reports no geometry and no laser settings while looking like a clean parse, and the
      # regex-based EmbeddedThumbnail still finds its image, so even the preview looks fine.
      # Two of 58 real files here (13 MB and 24 MB) hit it.
      def parse_document(bytes)
        Nokogiri::XML(bytes) { |c| c.recover.huge }
      end

      # lbrn2 XML → an SVG string. Geometry is mapped into a viewBox sized to the shapes'
      # bounding box (with a Y-flip, since LightBurn is Y-up and SVG is Y-down).
      def to_svg(lbrn2_bytes, size: 512)
        doc = parse_document(lbrn2_bytes)
        raise ParseError, "not a LightBurn project" if doc.root.nil?

        colors = cut_colors(doc)
        elements = []
        bbox = BBox.new

        each_geometry(doc) do |cut_index, points, closed, ellipse, image|
          points.each { |(x, y)| bbox.add(x, y) }
          stroke = colors[cut_index.to_s] || DEFAULT_STROKE
          # `image` FIRST: a placed photo replaces its outline rather than being drawn under one.
          # The points are still added to the bbox above, so the picture bounds the drawing and
          # the reported job size either way.
          elements << if image
                        image_svg(image)
          elsif ellipse
                        ellipse_svg(ellipse, stroke)
          elsif closed
                        polygon(points[0..-2], stroke)
          else
                        polyline(points, stroke)
          end
        end

        wrap_svg(elements, bbox, size)
      rescue Nokogiri::XML::SyntaxError => e
        raise ParseError, "lbrn2 XML parse failed: #{e.message}"
      end

      # THE one traversal, shared with LbrnMetadata so the thumbnail and the reported job size
      # can never disagree. Yields every drawable leaf as
      #   (cut_index, [[x, y], ...], closed?, ellipse_or_nil, image_or_nil)
      # with the points already transformed into SVG space (composed affine, then Y-flipped).
      #
      # The last two are RICHER RENDERINGS OF THE SAME POINTS, never a substitute for them: a
      # measuring caller (`job_size`) reads only the points and is correct ignoring both, which is
      # what lets an ellipse stay exact and a bitmap show its photo without either of them
      # changing what the file measures.
      def each_geometry(doc, &block)
        return if doc.root.nil?

        walk_shapes(doc.root, IDENTITY, GeometryIndex.new(doc), hidden_cuts(doc), &block)
      end

      # The drawn extent in mm, or nil when there is no geometry. Lives HERE, beside the walk it
      # measures, so the thumbnail and the reported size can never be computed from different
      # geometry — `LbrnMetadata` used to keep a private second copy of the traversal, and that
      # copy independently inherited every dialect bug the parse had. Both metadata modules call
      # this one.
      def job_size(doc)
        bbox = BBox.new
        each_geometry(doc) { |_cut, points, _closed, _ellipse| points.each { |(x, y)| bbox.add(x, y) } }
        w, h = bbox.dimensions
        w && { "width" => w.round(1), "height" => h.round(1) }
      end

      # Layers LightBurn itself does not draw. Two things here are easy to get wrong, and each
      # was caught by comparing every file's computed job size against the aspect ratio of the
      # thumbnail LightBurn itself embedded.
      #
      # `hide` ONLY — `doOutput="0"` is NOT the same question, however alike they read. `hide`
      # is "not on the canvas"; one file hides six layers, and drawing them buried a small
      # zigzag under a bitmap frame and a whole second design. `doOutput` is "on the canvas but
      # don't fire the laser" — a registration mark or alignment box, which LightBurn still
      # draws and which still bounds the drawing. Over 57 thumbnails: hide alone agreed on 54,
      # no filter on 52, and either form of doOutput on 40.
      #
      # And visibility is keyed on (KIND, index), never index alone. A file writes BOTH
      # `<CutSetting type="Cut">` and `<CutSetting_Img type="Image">` AT THE SAME INDEX — they
      # are the vector and the image layer for that one number — and either can be hidden by
      # itself. gavrielengage hides the Cut side while its photo stays visible; power cover
      # does the exact reverse. Merged by index, the first file renders as a blank page with no
      # job size at all, which is how this was found.
      def hidden_cuts(doc)
        cut_settings(doc).filter_map do |cs|
          idx = cs["index"] || cs.at_xpath("index")&.[]("Value") || cs.at_xpath("index")&.text
          next if idx.nil? || setting(cs, "hide") != "1"

          cut_key(cs.name == "CutSetting_Img" ? "Bitmap" : nil, idx)
        end.to_set
      end

      # A Bitmap takes its layer from `CutSetting_Img`; every other shape from `CutSetting`.
      def cut_key(shape_type, cut_index)
        "#{shape_type == 'Bitmap' ? 'img' : 'vec'}:#{cut_index}"
      end

      def setting(cs, key)
        cs.at_xpath(key)&.[]("Value") || cs.at_xpath(key)&.text || cs[key]
      end

      # Recursive because a Group's `<XForm>` PLACES its `<Children>` — the children carry raw,
      # usually identity-transformed coordinates. A flat `//Shape` sweep sees the children but
      # drops the transform that positions them, and separately hands the Group itself every
      # descendant vertex (via `.//VertList` or `shape.text`), drawing a scribble through them.
      def walk_shapes(parent, parent_xform, index, hidden, &block)
        parent.xpath("./Shape").each do |shape|
          world = compose(parent_xform, shape_xform(shape))

          if shape["Type"] == "Group"
            kids = shape.at_xpath("./Children")
            walk_shapes(kids, world, index, hidden, &block) if kids
            next
          end

          # Before the BackupPath below, so hiding a Text hides its outline too.
          next if hidden.include?(cut_key(shape["Type"], shape["CutIndex"]))

          emit_shape(shape, world, index, &block)

          # A Text stores its rendered outline in `<BackupPath>`. Two things about it:
          #
          # It is NOT a `<Shape>`, so a `//Shape` sweep never sees text at all — all 74 Text
          # shapes in this corpus contributed nothing to any bounding box.
          #
          # And its `<XForm>` is already in DOCUMENT space: it composes with nothing, not the
          # Text's own transform and not the groups around it. 64 of the 74 write the very
          # same matrix as their Text, so composing the pair doubles the translation — that
          # is what threw "Polster Library" clean off its sign. The other 10 settle what the
          # value actually is: in logo.lbrn2 a Text at (99.216, -127.493) sits inside a group
          # scaled 0.825 at (249.244, 245.2), and 0.825 * 99.216 + 249.244 = 331.09 is
          # exactly the BackupPath's own e — it is group ∘ text, already flattened.
          bp = shape.at_xpath("./BackupPath")
          emit_shape(bp, shape_xform(bp), index, &block) if bp
        end
      end

      def emit_shape(shape, world, index)
        cut = shape["CutIndex"]

        case shape["Type"]
        when "Rect", "Bitmap"
          # Both are centered on the XForm origin and sized by W/H.
          w = num(shape["W"]); h = num(shape["H"])
          return if w.nil? || h.nil?

          corners = [ [ -w / 2, -h / 2 ], [ w / 2, -h / 2 ], [ w / 2, h / 2 ], [ -w / 2, h / 2 ] ]
          pts = corners.map { |(x, y)| apply(world, x, y) }
          image = shape["Type"] == "Bitmap" ? bitmap_image(shape, world, pts) : nil
          yield cut, pts + [ pts.first ], true, nil, image
        when "Ellipse"
          rx = num(shape["Rx"]); ry = num(shape["Ry"])
          return if rx.nil? || ry.nil?

          # Sampled rather than emitted straight as cx/rx: a real XForm carries scale AND
          # rotation (0.866 -0.5 0.5 0.866 = 30°, seen on this corpus), and neither survives
          # `apply(xform, 0, 0)` + raw Rx/Ry. When the transform turns out to be axis-aligned
          # the samples collapse back to an exact <ellipse>; otherwise they stay a polygon.
          pts = (0...ELLIPSE_SAMPLES).map do |i|
            t = i * (2 * Math::PI / ELLIPSE_SAMPLES)
            apply(world, rx * Math.cos(t), ry * Math.sin(t))
          end
          yield cut, pts + [ pts.first ], true, (axis_aligned?(world) ? ellipse_from(pts) : nil)
        when "Path", "Line"
          verts, prims = index.geometry_for(shape)
          polylines(verts, prims).each do |pts, closed|
            yield cut, pts.map { |(x, y)| apply(world, x, y) }, closed, nil
          end
        end
      end

      # Base64's alphabet, plus the whitespace an XML attribute may wrap it with. Anchored.
      BITMAP_DATA = %r{\A[A-Za-z0-9+/=\s]+\z}

      # A placed photo, ready to emit as an `<image>` — or nil, meaning "draw the outline
      # instead", which is what this shape did in every case before.
      #
      # `Bitmap` used to fall through to the `Rect` arm and render as four corners with
      # `fill="none"`, so a .lbrn2 built around a traced or engraved photo previewed as an EMPTY
      # BOX. Only reachable on files carrying no `<Thumbnail>` of their own — which is the only
      # path this renderer serves.
      #
      # Three refusals, each for a different reason, and each falling back to the old outline:
      #
      #   * NOT AXIS-ALIGNED — an `<image>` is an upright rectangle. Carrying a rotation onto the
      #     element is possible but drawing it WITHOUT one would put the photo somewhere it is
      #     not, which is worse than a box that claims nothing. The `Ellipse` arm already makes
      #     exactly this call with the same predicate.
      #   * NOT BASE64 — `Data` is bytes out of an uploaded file, about to be interpolated into
      #     an SVG attribute. A `"` in it closes the attribute and turns the remainder into
      #     markup. REQUIRING the alphabet is the guard; escaping afterwards would leave open the
      #     question of what else needs escaping.
      #   * NOT A PNG — `data:image/png` has to be true. Checked on the first few characters
      #     rather than the whole value, because this attribute is routinely megabytes (it is the
      #     reason `parse_document` needs `huge`) and the magic lives in the first 8 bytes.
      def bitmap_image(shape, world, pts)
        return nil unless axis_aligned?(world)

        data = shape["Data"].to_s
        return nil unless data.match?(BITMAP_DATA)

        b64 = data.gsub(/\s/, "")
        return nil unless Base64.decode64(b64[0, 16].to_s)[0, 8] == Maker::Previews::EmbeddedThumbnail::PNG_MAGIC

        xs = pts.map(&:first); ys = pts.map(&:last)
        { href: "data:image/png;base64,#{b64}",
          x: xs.min, y: ys.min, w: xs.max - xs.min, h: ys.max - ys.min }
      end

      # CutIndex (string) → stroke color "#rrggbb". LightBurn stores the color as a 0xBBGGRR
      # integer (or sometimes "#rgb"); normalize to "#rrggbb".
      #
      # Matches every `CutSetting*` element, not just `CutSetting`: an image layer is written as
      # `<CutSetting_Img type="Image">`, so an exact-name match silently drops its colour and
      # leaves it out of the laser-settings panel.
      #
      # EXPECT THIS TO FIND NOTHING on a real file, and do not read that as a bug: not one of
      # the 150 CutSetting blocks across this corpus carries a `<color>` at all. LightBurn keys
      # a layer's colour off its INDEX, from a fixed built-in palette it never writes into the
      # document, so the geometry SVG draws in `DEFAULT_STROKE`. That costs almost nothing in
      # practice — `render` prefers the file's own embedded thumbnail, which is LightBurn's
      # full-colour render, and 57 of 58 files here carry one. Reproducing the palette would
      # mean hard-coding 30 colours guessed from thumbnails, which is not worth being wrong
      # about; the parse below stays for files that do carry the field.
      def cut_colors(doc)
        out = {}
        cut_settings(doc).each do |cs|
          idx = cs["index"] || cs.at_xpath("index")&.[]("Value") || cs.at_xpath("index")&.text
          raw = cs.at_xpath("color")&.[]("Value") || cs.at_xpath("color")&.text || cs["color"]
          out[idx.to_s] = normalize_color(raw) if idx
        end
        out
      end

      def cut_settings(doc)
        doc.xpath("//*[starts-with(name(), 'CutSetting')]")
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

      # The affine for one shape. `<XForm>a b c d e f</XForm>` is the real form — LightBurn has
      # never written it as an attribute — but the attribute is still read so the hand-authored
      # `sample.lbrn2` shape keeps working.
      def shape_xform(shape)
        parse_xform(shape.at_xpath("./XForm")&.text || shape["XForm"])
      end

      # "1 0 0 1 tx ty" (a b c d e f) affine → [a, b, c, d, e, f]; identity on miss.
      def parse_xform(str)
        nums = str.to_s.split.map { |t| Float(t, exception: false) }.compact
        nums.length == 6 ? nums : IDENTITY.dup
      end

      # parent ∘ child — the child's coordinates expressed in the parent's frame.
      def compose(p, c)
        [ (p[0] * c[0]) + (p[2] * c[1]),
          (p[1] * c[0]) + (p[3] * c[1]),
          (p[0] * c[2]) + (p[2] * c[3]),
          (p[1] * c[2]) + (p[3] * c[3]),
          (p[0] * c[4]) + (p[2] * c[5]) + p[4],
          (p[1] * c[4]) + (p[3] * c[5]) + p[5] ]
      end

      # No rotation and no skew, so an ellipse stays axis-aligned under it.
      def axis_aligned?(xform)
        xform[1].abs < 1e-9 && xform[2].abs < 1e-9
      end

      def ellipse_from(pts)
        xs = pts.map(&:first); ys = pts.map(&:last)
        [ (xs.min + xs.max) / 2, (ys.min + ys.max) / 2, (xs.max - xs.min) / 2, (ys.max - ys.min) / 2 ]
      end

      # Apply the affine, then flip Y (LightBurn is Y-up; SVG is Y-down) so emitted points and
      # the bounding box share one coordinate system and the thumbnail renders right-side up.
      def apply(xform, x, y)
        a, b, c, d, e, f = xform
        tx = (a * x) + (c * y) + e
        ty = (b * x) + (d * y) + f
        [ tx, -ty ]
      end

      # One vertex plus its two cubic control points, both in absolute coordinates.
      # `c0` is the OUTGOING handle and `c1` the INCOMING one, so the cubic from A to B is
      # (A, A.c0, B.c1, B) — verified against a circle LightBurn wrote as four B segments.
      Vertex = Struct.new(:x, :y, :c0, :c1)

      # A shape's own vertices, or nil when it only references shared ones.
      def vertices(shape)
        list = shape.at_xpath("./VertList")
        return parse_vertlist(list.text) if list

        # Older/hand-authored files put the vertices in child <V vx=".." vy=".."> elements.
        nodes = shape.xpath("./V[@vx]")
        return nil if nodes.empty?

        nodes.filter_map do |v|
          x = num(v["vx"]); y = num(v["vy"])
          Vertex.new(x, y, [ x, y ], [ x, y ]) if x && y
        end
      end

      # "V<x> <y>c0x<..>c0y<..>c1x<..>c1y<..>" repeated, e.g.
      #   V-31 2.9915142c0x1c1x1V-31 14c0x1c1x1
      # A control component that is omitted defaults to the vertex's OWN matching coordinate
      # (LightBurn writes the placeholder `c0x1c1x1` on corner vertices, whose handles no
      # `L` segment ever reads).
      #
      # Falls back to the older "V0x0y0V1x100y0" form — index, then xNUM/yNUM — which the two
      # hand-authored fixtures use. The two are unambiguous: a real vertex separates x and y
      # with whitespace, the older one with a literal "y".
      NUM = /-?[\d.]+(?:[eE][-+]?\d+)?/
      VERT = /V(#{NUM})\s+(#{NUM})((?:c[01][xy]#{NUM})*)/
      CTRL = /c([01])([xy])(#{NUM})/

      def parse_vertlist(text)
        return [] if text.nil?

        s = text.to_s
        out = s.scan(VERT).filter_map do |(sx, sy, ctrl)|
          x = Float(sx, exception: false); y = Float(sy, exception: false)
          next if x.nil? || y.nil?

          c = { "0x" => x, "0y" => y, "1x" => x, "1y" => y }
          ctrl.to_s.scan(CTRL) { |(n, axis, v)| c["#{n}#{axis}"] = Float(v, exception: false) || c["#{n}#{axis}"] }
          Vertex.new(x, y, [ c["0x"], c["0y"] ], [ c["1x"], c["1y"] ])
        end
        return out if out.any?

        s.scan(/x(#{NUM})\s*y(#{NUM})/).filter_map do |(sx, sy)|
          x = Float(sx, exception: false); y = Float(sy, exception: false)
          Vertex.new(x, y, [ x, y ], [ x, y ]) if x && y
        end
      end

      # Vertices + a PrimList → one or more polylines as [[[x, y], ...], closed?].
      #
      # PrimList is the connectivity: "L<a> <b>" a straight segment, "B<a> <b>" a cubic through
      # the two vertices' handles, and "LineClosed"/"BezierClosed" a loop over every vertex in
      # order. Absent, it degrades to a single open polyline — which is what EVERY path used to
      # get, so a closed outline read as an open one and a curve as a chord.
      def polylines(verts, prims)
        return [] if verts.nil? || verts.length < 2

        ops = prim_ops(verts, prims)
        return [ [ verts.map { |v| [ v.x, v.y ] }, false ] ] if ops.empty?

        out = []
        current = nil
        prev = nil
        ops.each do |(op, ai, bi)|
          a = verts[ai]; b = verts[bi]
          next if a.nil? || b.nil?

          if current.nil? || prev != ai
            out << current if current
            current = [ [ a.x, a.y ] ]
          end
          current.concat(op == "B" ? bezier_points(a, b) : [ [ b.x, b.y ] ])
          prev = bi
        end
        out << current if current
        out.map { |pts| [ pts, pts.length > 2 && pts.first == pts.last ] }
      end

      def prim_ops(verts, prims)
        s = prims.to_s
        if s.match?(/Closed/i)
          op = s.match?(/Bezier/i) ? "B" : "L"
          idx = (0...verts.length).to_a
          return idx.each_cons(2).map { |a, b| [ op, a, b ] } + [ [ op, idx.last, idx.first ] ]
        end

        s.scan(/([LB])(\d+)\s+(\d+)/).map { |(op, a, b)| [ op, a.to_i, b.to_i ] }
      end

      # Cubic (a, a.c0, b.c1, b), sampled for t in (0, 1] — t=0 is already the previous point.
      def bezier_points(a, b)
        x0, y0 = a.x, a.y
        x1, y1 = a.c0
        x2, y2 = b.c1
        x3, y3 = b.x, b.y
        (1..BEZIER_SAMPLES).map do |i|
          t = i.to_f / BEZIER_SAMPLES
          u = 1.0 - t
          uu = u * u; tt = t * t
          [ (uu * u * x0) + (3 * uu * t * x1) + (3 * u * tt * x2) + (tt * t * x3),
            (uu * u * y0) + (3 * uu * t * y1) + (3 * u * tt * y2) + (tt * t * y3) ]
        end
      end

      # Resolves `VertID`/`PrimID` references. LightBurn writes a repeated shape's geometry ONCE
      # and gives every other copy the same VertID with no <VertList> of its own — 220 of hex
      # tiles' 490 shapes are such instances. Reading only inline lists drops them silently.
      # The two id spaces are independent (one PrimList is legitimately shared by two VertLists).
      class GeometryIndex
        def initialize(doc)
          @verts = {}
          @prims = {}
          doc.xpath("//Shape | //BackupPath").each do |s|
            if (id = s["VertID"]) && !@verts.key?(id) && (v = Lbrn2.vertices(s))
              @verts[id] = v
            end
            if (id = s["PrimID"]) && !@prims.key?(id) && (p = s.at_xpath("./PrimList"))
              @prims[id] = p.text
            end
          end
        end

        def geometry_for(shape)
          verts = Lbrn2.vertices(shape) || @verts[shape["VertID"]]
          prims = shape.at_xpath("./PrimList")&.text || @prims[shape["PrimID"]]
          [ verts, prims ]
        end
      end

      def ellipse_svg(ellipse, stroke)
        cx, cy, rx, ry = ellipse
        %(<ellipse cx="#{f(cx)}" cy="#{f(cy)}" rx="#{f(rx)}" ry="#{f(ry)}" ) +
          %(fill="none" stroke="#{stroke}" stroke-width="0.5"/>)
      end

      # `preserveAspectRatio="none"` because LightBurn STRETCHES a placed image to the shape's
      # W/H — it does not letterbox it — so honouring the raster's own ratio would draw the photo
      # at a size the file does not describe.
      #
      # No y-flip on the element. `apply` negates y, which puts the box's smaller y (its visual
      # top) at LightBurn's LARGER Y — and LightBurn's larger Y is the top of a Y-up canvas, which
      # is where the raster's row 0 belongs. The flip is already paid for; adding one here would
      # stand the photo on its head. Verified against jlucaso1/lbrn2-to-svg's own `image` fixture.
      def image_svg(img)
        %(<image x="#{f(img[:x])}" y="#{f(img[:y])}" width="#{f(img[:w])}" height="#{f(img[:h])}" ) +
          %(preserveAspectRatio="none" href="#{img[:href]}"/>)
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

        # [width, height] of the accumulated box, or nil when empty. Used by LbrnMetadata for job size.
        def dimensions
          return nil if empty?

          [ @max_x - @min_x, @max_y - @min_y ]
        end

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
