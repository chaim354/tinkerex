require "nokogiri"

module Maker
  module Previews
    # SVG (.svg) -> the Measure view's geometry payload.
    #
    # THIS IS THE ONE FORMAT WHERE THE MEASURE VIEW AND THE THUMBNAIL DO NOT SHARE A TRAVERSAL,
    # and that is worth stating plainly rather than leaving a reader to notice. For .lbrn2, .mage
    # and .dxf the thumbnail is drawn by OUR parser, so a second parse for measuring would be a
    # second copy free to drift — §14b's `LbrnMetadata` bug. An SVG thumbnail is rasterized by
    # resvg, an external renderer we do not and should not reimplement, so there is no traversal
    # to share: this parser is necessarily a second, independent reading of the file.
    #
    # THE CONSEQUENCE IS REAL AND IS NOT PAPERED OVER: resvg understands the whole format, this
    # parser understands the geometry subset below, so a file using something outside it measures
    # fewer shapes than the picture shows. That is why the client reports the shape count it
    # actually received. The alternative — refusing to measure SVG at all — is worse for a format
    # that is the single most common laser source there is.
    #
    # WHAT IS DELIBERATELY NOT PARSED, each because reading it wrong is worse than not reading it:
    #   * `<text>` — needs font metrics and a shaping engine. LightBurn has the same problem and
    #     solves it by storing a `<BackupPath>` outline; a plain SVG carries no such fallback, so
    #     a text element contributes nothing rather than a guessed box. Convert text to paths.
    #   * `<use>` — would need href resolution back into `<defs>` plus its own transform stack.
    #     A real gap, not a judgement: an Inkscape "clone" measures as absent.
    #   * clip paths and masks — they REMOVE geometry. Ignoring them measures the unclipped shape,
    #     which is too much rather than too little; both are wrong, and this one is at least the
    #     shape the author drew.
    module SvgGeometry
      module_function

      # WHICH BUILD OF *THIS FILE* PRODUCED A STORED PAYLOAD — see `LbrnGeometry::FORMAT_REVISION`
      # for the full argument. A change in the SHARED payload builder does NOT belong here; it
      # belongs in `Geometry::SHARED_REVISION`, which the line below adds in.
      #
      #   1  original
      FORMAT_REVISION = 1

      # What `Enqueue` actually reads — see `Geometry::SHARED_REVISION`.
      PAYLOAD_REVISION = Geometry::SHARED_REVISION + FORMAT_REVISION

      # THE ONLY ELEMENTS THIS WALK RECURSES INTO — an ALLOWLIST, and deliberately not the
      # skip-list it started as.
      #
      # Everything else is reached only through `contours_for`, which draws the shapes it knows
      # and returns nothing for the rest. So `<defs>`, `<symbol>`, `<clipPath>`, `<mask>`,
      # `<pattern>` and `<marker>` — elements holding geometry that is never drawn WHERE IT IS
      # DEFINED — are excluded by not being here, rather than by being named somewhere else.
      #
      # THE FIRST DRAFT DID NAME THEM, in a SKIPPED constant, and it was DEAD CODE: none of them
      # was ever in this list, so nothing recursed into them either way. Removing an entry from
      # that constant left every test green, which is precisely the "guard that has never failed
      # has not been shown to work" shape §15 warns about — and §14b records the skip-list blind
      # spot as this repo's own recurring bug, four instances deep. An allowlist cannot have it:
      # a new template element is excluded the day it is invented, with nobody remembering to add
      # it. The cost is the opposite failure, a genuine container omitted here rendering as
      # absent, which is visible rather than silent.
      CONTAINERS = %w[svg g a switch].freeze

      # CSS absolute units in millimetres. `px` is 1/96 in BY DEFINITION in CSS/SVG — not a screen
      # pixel — which is what makes a viewBox-only SVG measurable at all.
      MM_PER_UNIT = {
        "mm" => 1.0, "cm" => 10.0, "in" => 25.4, "pt" => 25.4 / 72, "pc" => 25.4 / 6,
        "px" => 25.4 / 96, "q" => 0.25, "" => 25.4 / 96
      }.freeze

      # An unrotated ellipse sampled at a multiple of 4 hits its axis extents EXACTLY, so the
      # reported bbox is the true one — the same reason `Lbrn2::ELLIPSE_SAMPLES` is 32.
      ELLIPSE_SAMPLES = 64

      # Returns { bytes:, content_type: } — the shape GeneratePreviewJob attaches.
      def render(svg_bytes)
        Geometry.encode(build(svg_bytes))
      end

      def build(svg_bytes)
        doc = Nokogiri::XML(svg_bytes) { |c| c.recover.huge }
        root = doc.root
        # Matches `Lbrn2.to_svg`'s and `LbrnGeometry.build`'s contract: bytes we cannot make sense
        # of at all raise, so the job records `failed` instead of serving a READY Measure view
        # that says "No measurable geometry in this file" — a lie about the file. A well-formed
        # SVG that genuinely draws nothing is a different, honest case and reaches the empty
        # payload by walking a real document.
        raise ParseError, "not an SVG document" if root.nil? || root.name != "svg"

        sx, sy = scale(root)
        # The flatness bound for curve subdivision, converted from the payload's millimetres into
        # this document's user units. HALF the payload tolerance, so that sampling error and the
        # later thinning error cannot add up past what `SIMPLIFY_TOLERANCE` promises the reader.
        tolerance = (Geometry::SIMPLIFY_TOLERANCE / 2) / [ sx.abs, sy.abs, 1e-9 ].max

        counter = Counter.new
        Geometry.build(colors: ->(layers) { layers.to_h { |l| [ l, l ] } }) do |out|
          walk(root, IDENTITY, Inherited.new, tolerance, counter) do |paint, points, closed, image, curve, segments|
            out.add(layer: paint, points: points.map { |(x, y)| [ x * sx, y * sy ] },
                    closed:, image:, object_id: counter.value,
                    # AT MOST ONE DESCRIPTOR PER CONTOUR, AND THE `||` IS UNAMBIGUOUS RATHER THAN A
                    # PRIORITY. The two come from different branches of `contours_for`: only a
                    # <circle>/<ellipse> yields an ellipse and only a <path> yields segments, so
                    # there is no shape for which this chooses. Written as a fallthrough anyway so
                    # that a THIRD form arriving with an ordering question has to answer it here,
                    # where the comment is, rather than silently in whichever arm ran last.
                    curve: (curve && Geometry.ellipse_curve(curve[0] * sx, curve[1] * sy,
                                                            curve[2] * sx.abs, curve[3] * sy.abs)) ||
                           (segments && Geometry.path_curve(scale_segments(segments, sx, sy))))
          end
        end
      end

      # THE SAME sx/sy THE POINTS GET, per axis. A descriptor scaled differently from the contour
      # it describes draws a curve that does not sit on its own outline — and the outline is what
      # `b` was measured from, so the picture would disagree with the readout beside it. The two
      # axes are NOT the same number under `preserveAspectRatio="none"`, which is the case that
      # tells a working implementation from one that reaches for `sx` twice.
      #
      # THE COMMAND SYMBOL IS UNTOUCHED AND `[:Z]` HAS NO PAIRS, which is what keeps the closing
      # command out of the arithmetic.
      def scale_segments(segments, sx, sy)
        segments.map do |(cmd, *nums)|
          [ cmd, *nums.each_slice(2).flat_map { |(x, y)| [ x * sx, y * sy ] } ]
        end
      end

      ParseError = Class.new(StandardError)

      # SVG is ALREADY Y-DOWN, like the client's drawing space, so unlike DXF there is no flip —
      # only the scale. A flip added here "for symmetry with Dxf" turns every SVG upside down.
      IDENTITY = [ 1.0, 0.0, 0.0, 1.0, 0.0, 0.0 ].freeze

      # `object_id` groups the contours of one element (a `d` with several subpaths is one object
      # the user clicks once). Ticks per DRAWN ELEMENT, so ids are distinct but not dense — the
      # same contract `Lbrn2.each_geometry` documents.
      class Counter
        attr_reader :value

        def initialize = @value = 0
        def succ! = @value += 1
      end

      # Presentation state inherited down the tree. Only what this payload uses: the paint that
      # becomes a contour's layer key.
      Inherited = Struct.new(:paint) do
        def with(new_paint) = new_paint ? Inherited.new(new_paint) : self
      end

      def walk(node, xform, inherited, tolerance, counter, &block)
        node.element_children.each do |child|
          name = child.name
          world = compose(xform, parse_transform(child["transform"]))
          here = inherited.with(paint_of(child))

          if CONTAINERS.include?(name)
            walk(child, world, here, tolerance, counter, &block)
            next
          end

          contours = contours_for(child, tolerance)
          next if contours.empty?

          counter.succ!
          image = name == "image"
          curve = ellipse_curve_for(child, world)
          # ONE `apply` FOR THE POINTS AND THE CONTROL POINTS ALIKE, side by side so that dropping
          # the second is visible. A control point that misses the affine still yields a perfectly
          # well-formed curve — it is simply not the file's — and this repo's recorded failure
          # shape is exactly that: plausible output with nothing to go red.
          #
          # AND `ellipse_curve_for`'s AXIS-ALIGNED GATE DOES NOT BIND HERE, WHICH IS THE PART A
          # LATER READER WILL WANT TO "FIX". That gate exists because the `"e"` wire form carries
          # rx and ry with no rotation term, so under a rotation or a skew it would export an
          # upright ellipse the file does not contain. A CUBIC HAS NO SUCH LIMIT: it transforms
          # affinely under ANY matrix, because a Bézier is a convex combination of its own control
          # points and an affine map commutes with that. So a rotated or skewed <path> KEEPS its
          # descriptor, and refusing one here would be a downgrade with no defect behind it.
          contours.each do |(points, closed, segments)|
            block.call(here.paint, points.map { |(x, y)| apply(world, x, y) }, closed, image, curve,
                       segments && place_segments(segments, world))
          end
        end
      end

      # Each segment's coordinate PAIRS through `apply`, the command symbol untouched. `[:Z]` has
      # no pairs and passes through unchanged.
      def place_segments(segments, world)
        segments.map do |(cmd, *nums)|
          [ cmd, *nums.each_slice(2).flat_map { |(x, y)| apply(world, x, y) } ]
        end
      end

      # An element → [[points, closed], ...] in its OWN user units, before its transform — except
      # `path`, which adds a third element, its own cubic segment list (`SvgPath.parse`).
      #
      # ONLY `path` PRODUCES A DESCRIPTOR, AND THE OTHER SIX BRANCHES KEEP THEIR TWO-ELEMENT SHAPE.
      # Five of them are polygons already or have the exact `"e"` form; the sixth, a ROUNDED
      # `<rect>`, is the one that would acquire a descriptor by accident, since `rect_contours`
      # builds it out of four `A` commands and hands them to the same parser. It deliberately does
      # not — see there.
      def contours_for(node, tolerance)
        case node.name
        when "path"     then SvgPath.parse(node["d"], tolerance)
        when "rect"     then rect_contours(node)
        when "image"    then box_contour(num(node["x"]), num(node["y"]), num(node["width"]), num(node["height"]))
        when "circle"   then ellipse_contours(num(node["cx"]), num(node["cy"]), num(node["r"]), num(node["r"]))
        when "ellipse"  then ellipse_contours(num(node["cx"]), num(node["cy"]), num(node["rx"]), num(node["ry"]))
        when "line"     then line_contours(node)
        when "polyline" then points_contours(node["points"], closed: false)
        when "polygon"  then points_contours(node["points"], closed: true)
        else []
        end
      rescue SvgPath::ParseError
        # One malformed `d` must not fail the whole file — every other shape in it is still
        # measurable, and a partial drawing is what the client already reports honestly.
        []
      end

      # `rx`/`ry` (rounded corners) are NOT approximated as square. A rounded rect measured as
      # sharp reports a bbox that is correct and corners that are not; drawing the four arcs is
      # cheap and keeps the outline the one the file describes.
      def rect_contours(node)
        x = num(node["x"]) || 0.0
        y = num(node["y"]) || 0.0
        w = num(node["width"])
        h = num(node["height"])
        return [] if w.nil? || h.nil? || w <= 0 || h <= 0

        rx = num(node["rx"]) || num(node["ry"]) || 0.0
        ry = num(node["ry"]) || num(node["rx"]) || 0.0
        rx = [ rx, w / 2 ].min
        ry = [ ry, h / 2 ].min
        return box_contour(x, y, w, h) if rx <= 0 || ry <= 0

        d = "M#{x + rx},#{y} H#{x + w - rx} A#{rx},#{ry} 0 0 1 #{x + w},#{y + ry} " \
            "V#{y + h - ry} A#{rx},#{ry} 0 0 1 #{x + w - rx},#{y + h} " \
            "H#{x + rx} A#{rx},#{ry} 0 0 1 #{x},#{y + h - ry} " \
            "V#{y + ry} A#{rx},#{ry} 0 0 1 #{x + rx},#{y} Z"
        # THE SEGMENT LIST IS DROPPED HERE ON PURPOSE, AND IT IS THE ONE PLACE THAT HAPPENS. This
        # `d` is OURS — the shape of a `<rect>` with an `rx`, synthesised so the corners are arcs
        # rather than square — where every other descriptor in this app is geometry the FILE
        # declared. A curve descriptor is a claim about what the author drew, and extending it to
        # a shape we constructed is a separate change with its own payload measurement, so the
        # form stops at the door `path` came in by. `.map` rather than a flag on `parse`, because
        # the decision belongs to this caller and not to the parser.
        SvgPath.parse(d, Geometry::SIMPLIFY_TOLERANCE / 2).map { |(pts, closed)| [ pts, closed ] }
      end

      def box_contour(x, y, w, h)
        return [] if w.nil? || h.nil? || w <= 0 || h <= 0

        x ||= 0.0
        y ||= 0.0
        [ [ [ [ x, y ], [ x + w, y ], [ x + w, y + h ], [ x, y + h ], [ x, y ] ], true ] ]
      end

      def ellipse_contours(cx, cy, rx, ry)
        cx ||= 0.0
        cy ||= 0.0
        return [] if rx.nil? || ry.nil? || rx <= 0 || ry <= 0

        pts = (0..ELLIPSE_SAMPLES).map do |i|
          t = i * (2 * Math::PI / ELLIPSE_SAMPLES)
          [ cx + (rx * Math.cos(t)), cy + (ry * Math.sin(t)) ]
        end
        [ [ pts, true ] ]
      end

      # An axis-aligned <circle>/<ellipse> -> [cx, cy, rx, ry] in the SAME space as this element's
      # yielded points (post-transform, pre-viewBox-scale), or nil. `build` scales both together,
      # so the two can never disagree about which space they are in.
      #
      # GATED ON THE TRANSFORM, AND THAT REFUSAL IS THE POINT. Under a rotation or a skew an SVG
      # <ellipse> is no longer an SVG <ellipse>; emitting one would export geometry the file does
      # not contain — and a wrong SHAPE is not a wrong label, it is what a machine cuts. Same test
      # and same reason as `Lbrn2.axis_aligned?`.
      #
      # ONLY THESE TWO ELEMENTS CAN REACH IT. Everything else `contours_for` handles is either a
      # polygon already or a flattened path, and both may yield MORE THAN ONE contour, which a
      # single descriptor could not describe. A <rect> with rounded corners is the sharp case: it
      # is four arcs and four lines, not a primitive.
      def ellipse_curve_for(node, world)
        return nil unless %w[circle ellipse].include?(node.name)
        return nil if world[1].abs > 1e-9 || world[2].abs > 1e-9

        rx = num(node["r"]) || num(node["rx"])
        ry = num(node["r"]) || num(node["ry"])
        return nil if rx.nil? || ry.nil? || rx <= 0 || ry <= 0

        cx, cy = apply(world, num(node["cx"]) || 0.0, num(node["cy"]) || 0.0)
        [ cx, cy, rx * world[0].abs, ry * world[3].abs ]
      end

      def line_contours(node)
        x1 = num(node["x1"]) || 0.0
        y1 = num(node["y1"]) || 0.0
        x2 = num(node["x2"]) || 0.0
        y2 = num(node["y2"]) || 0.0
        return [] if x1 == x2 && y1 == y2

        [ [ [ [ x1, y1 ], [ x2, y2 ] ], false ] ]
      end

      def points_contours(raw, closed:)
        nums = raw.to_s.scan(SvgPath::NUMBER).map(&:to_f)
        pts = nums.each_slice(2).select { |s| s.length == 2 }.map { |(x, y)| [ x, y ] }
        return [] if pts.length < 2

        pts = pts + [ pts.first ] if closed && pts.first != pts.last
        [ [ pts, closed ] ]
      end

      # ---- paint (the layer key) ----------------------------------------------------------

      # WHAT A CONTOUR'S "LAYER" IS FOR AN SVG: THE COLOUR IT IS DRAWN IN.
      #
      # SVG has no layer concept the format guarantees (Inkscape's layers are `<g>` elements with
      # a private attribute; Illustrator's are not the same thing). Colour, though, is exactly how
      # this app's users already organise a laser file — LightBurn assigns cut settings BY STROKE
      # COLOUR on import, so "everything red" is a real, intentional grouping in the source file
      # rather than a category we invented for it.
      #
      # STROKE FIRST, THEN FILL. A cut line is stroked; a filled region with no stroke is an
      # engrave area, and its fill is the only colour it has. `none` on either is not a colour and
      # falls through to the next, then to nil — which the client draws black.
      def paint_of(node)
        style = inline_style(node["style"])
        %w[stroke fill].each do |prop|
          value = style[prop] || node[prop]
          next if value.nil?

          normalized = normalize_color(value)
          return normalized if normalized
        end
        nil
      end

      def inline_style(raw)
        return {} if raw.nil?

        raw.to_s.split(";").each_with_object({}) do |decl, out|
          key, value = decl.split(":", 2)
          out[key.to_s.strip.downcase] = value.strip if key && value
        end
      end

      NAMED_COLORS = {
        "black" => "#000000", "white" => "#ffffff", "red" => "#ff0000", "lime" => "#00ff00",
        "green" => "#008000", "blue" => "#0000ff", "yellow" => "#ffff00", "cyan" => "#00ffff",
        "aqua" => "#00ffff", "magenta" => "#ff00ff", "fuchsia" => "#ff00ff", "gray" => "#808080",
        "grey" => "#808080", "silver" => "#c0c0c0", "maroon" => "#800000", "olive" => "#808000",
        "navy" => "#000080", "purple" => "#800080", "teal" => "#008080", "orange" => "#ffa500"
      }.freeze

      # A colour we can hand the client as a stroke, or nil.
      #
      # NORMALIZED RATHER THAN PASSED THROUGH, because the value is BOTH the payload's layer key
      # AND a colour the client writes into an SVG attribute. Unnormalized, `#F00`, `red` and
      # `rgb(255,0,0)` are three layers of one colour in the panel; and passing an arbitrary
      # attribute value straight through is the kind of thing that stops being cosmetic. Anything
      # unrecognised (a `url(#gradient)` paint server, `currentColor`) returns nil and draws black.
      def normalize_color(raw)
        value = raw.to_s.strip.downcase
        return nil if value.empty? || value == "none" || value == "transparent"
        return NAMED_COLORS[value] if NAMED_COLORS.key?(value)

        if (m = value.match(/\A#([0-9a-f]{3})\z/))
          return "#" + m[1].chars.map { |c| c * 2 }.join
        end
        return value if value.match?(/\A#[0-9a-f]{6}\z/)

        if (m = value.match(/\Argba?\(\s*([\d.]+)\D+([\d.]+)\D+([\d.]+)/))
          return "#" + m[1..3].map { |c| c.to_f.round.clamp(0, 255).to_s(16).rjust(2, "0") }.join
        end
        nil
      end

      # ---- units --------------------------------------------------------------------------

      # MILLIMETRES PER USER UNIT, as [sx, sy].
      #
      # THE ONE PLACE AN SVG'S NUMBERS BECOME PHYSICAL. Three cases, and the third is the one that
      # makes viewBox-only files measurable:
      #
      #   * width/height WITH a viewBox — the honest case. The physical size divided by the
      #     viewBox's own extent is the scale, and it is exact.
      #   * width/height with NO viewBox — user units ARE the width's units.
      #   * a viewBox with no usable width/height — user units are CSS px, 1/96 in by definition.
      #     Inkscape and Illustrator both write real units, but plotter and generator output
      #     routinely does not, and 96 dpi is what every browser resolves such a file to.
      #
      # NON-UNIFORM SCALES ARE ONLY HONOURED FOR `preserveAspectRatio="none"`. Otherwise the
      # default `meet` fits the viewBox INSIDE the viewport preserving the aspect ratio, so the
      # real scale is the SMALLER of the two — taking them per-axis would report a stretch the
      # renderer never applies, on any file whose width:height differs from its viewBox's.
      def scale(root)
        vb = viewbox(root)
        w_mm = length_mm(root["width"])
        h_mm = length_mm(root["height"])

        return [ MM_PER_UNIT[""], MM_PER_UNIT[""] ] if vb.nil? && w_mm.nil?
        return [ 1.0, 1.0 ] if vb.nil? # width has units; user units are those units

        return [ MM_PER_UNIT[""], MM_PER_UNIT[""] ] if w_mm.nil? && h_mm.nil?

        sx = w_mm && vb[2].positive? ? w_mm / vb[2] : nil
        sy = h_mm && vb[3].positive? ? h_mm / vb[3] : nil
        sx ||= sy
        sy ||= sx
        return [ sx, sy ] if root["preserveAspectRatio"].to_s.strip.downcase.start_with?("none")

        uniform = [ sx, sy ].min
        [ uniform, uniform ]
      end

      def viewbox(root)
        nums = root["viewBox"].to_s.scan(SvgPath::NUMBER).map(&:to_f)
        return nil unless nums.length == 4 && nums[2].positive? && nums[3].positive?

        nums
      end

      # "210mm" -> 210.0; "8.5in" -> 215.9; "500" -> px in mm; "50%" -> nil (not resolvable).
      def length_mm(raw)
        value = raw.to_s.strip.downcase
        return nil if value.empty? || value.end_with?("%")

        m = value.match(/\A(#{SvgPath::NUMBER})\s*([a-z]*)\z/o)
        return nil if m.nil?

        per = MM_PER_UNIT[m[2]]
        # `em`/`ex`/`rem` depend on a font this parser has no access to. Refusing is what sends
        # `scale` to its px default rather than silently treating 10em as 10px.
        return nil if per.nil?

        m[1].to_f * per
      end

      def num(raw)
        return nil if raw.nil?

        m = raw.to_s.strip.match(/\A(#{SvgPath::NUMBER})/o)
        m && m[1].to_f
      end

      # ---- transforms ---------------------------------------------------------------------

      TRANSFORM = /(matrix|translate|scale|rotate|skewX|skewY)\s*\(([^)]*)\)/

      # `transform="A B"` applies A THEN B to the coordinate system, so the composed matrix is
      # A * B and a point is mapped by parent * A * B. Folding them in the other order mirrors and
      # mislocates every nested group — visible immediately on any Inkscape file, which nests.
      def parse_transform(raw)
        return IDENTITY if raw.nil?

        raw.to_s.scan(TRANSFORM).reduce(IDENTITY) do |acc, (op, args)|
          values = args.scan(SvgPath::NUMBER).map(&:to_f)
          compose(acc, transform_matrix(op, values))
        end
      end

      def transform_matrix(op, v)
        case op
        when "matrix"    then v.length >= 6 ? v[0, 6] : IDENTITY
        when "translate" then [ 1.0, 0.0, 0.0, 1.0, v[0] || 0.0, v[1] || 0.0 ]
        when "scale"     then [ v[0] || 1.0, 0.0, 0.0, v[1] || v[0] || 1.0, 0.0, 0.0 ]
        when "rotate"    then rotate_matrix(v)
        when "skewX"     then [ 1.0, 0.0, Math.tan((v[0] || 0.0) * Math::PI / 180), 1.0, 0.0, 0.0 ]
        when "skewY"     then [ 1.0, Math.tan((v[0] || 0.0) * Math::PI / 180), 0.0, 1.0, 0.0, 0.0 ]
        else IDENTITY
        end
      end

      # `rotate(a cx cy)` rotates ABOUT (cx, cy) — translate, rotate, translate back. Ignoring the
      # optional centre silently rotates about the origin, which throws the shape across the page
      # rather than turning it in place.
      def rotate_matrix(v)
        rad = (v[0] || 0.0) * Math::PI / 180
        cos = Math.cos(rad)
        sin = Math.sin(rad)
        r = [ cos, sin, -sin, cos, 0.0, 0.0 ]
        return r if v.length < 3

        cx = v[1]
        cy = v[2]
        compose(compose([ 1.0, 0.0, 0.0, 1.0, cx, cy ], r), [ 1.0, 0.0, 0.0, 1.0, -cx, -cy ])
      end

      # [a, b, c, d, e, f] where x' = a*x + c*y + e and y' = b*x + d*y + f.
      def compose(m1, m2)
        [ (m1[0] * m2[0]) + (m1[2] * m2[1]),
          (m1[1] * m2[0]) + (m1[3] * m2[1]),
          (m1[0] * m2[2]) + (m1[2] * m2[3]),
          (m1[1] * m2[2]) + (m1[3] * m2[3]),
          (m1[0] * m2[4]) + (m1[2] * m2[5]) + m1[4],
          (m1[1] * m2[4]) + (m1[3] * m2[5]) + m1[5] ]
      end

      def apply(m, x, y)
        [ (m[0] * x) + (m[2] * y) + m[4], (m[1] * x) + (m[3] * y) + m[5] ]
      end
    end
  end
end
