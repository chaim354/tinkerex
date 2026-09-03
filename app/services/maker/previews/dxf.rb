module Maker
  module Previews
    # DXF (`.dxf`) → SVG → PNG, and → the Measure view's geometry payload.
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
    # ONE TRAVERSAL, TWO ARTIFACTS — `each_geometry` — AND THAT IS NOT TIDINESS. Both the
    # thumbnail and the Measure payload read this file, and until they shared a walk the payload
    # would have been a second parse free to drift from the picture beside it. That is §14b's
    # `LbrnMetadata` bug exactly: a private second copy of a traversal independently inherited
    # every dialect bug the first one had, so a file could render one way and measure another with
    # nothing to catch it. `Lbrn2.each_geometry` is the same shape for the same reason.
    #
    # `available?` gates the THUMBNAIL only. Measuring is arithmetic over parsed pairs and needs
    # no rasterizer — see `render`.
    module Dxf
      module_function

      ParseError = Class.new(StandardError)

      EXTENSIONS = %w[dxf].freeze

      STROKE = "#000000".freeze

      def available? = Maker::Previews::Svg.available?

      # THE MEASURE PAYLOAD NEEDS NO RASTERIZER — parsing group-code pairs is pure Ruby. See
      # `GeneratePreviewJob#available_for?`.
      def available_for?(kind) = kind == "geometry" || available?

      # Which build produced a stored artifact — see `Enqueue.revision_for`. PER KIND, so bumping
      # the measure payload does not re-render every DXF thumbnail in the library.
      #
      #   1  original (thumbnail)
      THUMBNAIL_REVISION = 1

      def payload_revision(kind)
        kind == "geometry" ? Maker::Previews::DxfGeometry::PAYLOAD_REVISION : THUMBNAIL_REVISION
      end

      # `kind` selects the ARTIFACT, mirroring Lbrn2's and Mage's branch.
      #
      # THE GEOMETRY ARM RUNS EVEN WHERE `available?` IS FALSE, deliberately. `available?` asks
      # whether resvg is on this box, because the THUMBNAIL is a rasterized SVG; the measure
      # payload is JSON built from parsed numbers and needs nothing external. That is what
      # `available_for?` above declares and what `GeneratePreviewJob#available_for?` asks.
      def render(dxf_bytes, size: 512, kind: "thumbnail")
        return Maker::Previews::DxfGeometry.render(dxf_bytes) if kind == "geometry"

        Maker::Previews::Svg.render(to_svg(dxf_bytes, size:), size:)
      end

      # ---- the one traversal -------------------------------------------------------------

      # Takes the TOKENIZED PAIRS, not the raw bytes — the same shape as `Lbrn2.each_geometry`,
      # which takes the parsed document. Both artifacts already need the pairs for their own
      # reasons (`layer_colors` here, `mm_per_unit` too in `DxfGeometry`), so a traversal that
      # lexed for ITSELF made every render lex the file twice — measured, both legs. The lex is
      # the expensive half: the 2026-08-19 audit timed this exact `tokenize` body at ~148 ms per
      # pass on a synthetic 4.4 MB drawing (300k pairs). `dxf_geometry_test.rb` guards the count
      # by counting `tokenize` calls — a guard on WORK DONE, because lexing twice draws the
      # identical picture and no assertion about the output can see it.
      #
      # Yields every drawable entity as
      #   (layer_name, [[x, y], ...], closed?, curve_or_nil, object_id)
      # with points in DXF MODEL SPACE: native drawing units, Y-UP, exactly as the file records
      # them. Neither the Y-flip (SVG is Y-down) nor the unit scale is applied here, because the
      # two consumers need different things — the thumbnail wants a flip and no scale, the payload
      # wants both — and a traversal that pre-applied either would force one of them to undo it.
      #
      # `curve` is a RICHER RENDERING OF THE SAME POINTS, never a substitute for them — the same
      # contract as `Lbrn2.each_geometry`'s ellipse/image. A CIRCLE and an ARC are exact primitives
      # in both DXF and SVG, so the thumbnail draws them as `<circle>`/`<path A>` and stays crisp
      # at any zoom, while a measuring caller reads the flattened points and is correct ignoring
      # `curve` entirely. A consumer that used `curve` INSTEAD of the points would be reading a
      # different geometry from the one the bbox was computed from.
      #
      # `object_id` counts yielded entities in document order, from 1 — the id the client groups
      # and selects by. Entities that yield nothing (a LINE missing an endpoint, an LWPOLYLINE
      # with one vertex) do NOT consume an id here, unlike `Lbrn2`'s counter which ticks before
      # the emit; DXF has no Group/BackupPath structure forcing an id to be reserved ahead of the
      # decision to draw. Callers may rely on equality only, never on any relationship to the
      # entity's position in the file.
      #
      # `unreadable:` IS AN OPTIONAL TALLY THE CALLER OWNS — a `{ "SPLINE" => 2 }` hash this walk
      # fills in with the entity types it met and cannot draw, so the payload can say so instead of
      # dropping them without a word (see `Geometry.build`). Handed IN rather than returned because
      # `Geometry.build` binds its own `unreadable:` before the traversal block runs; the caller
      # gives both the same object. The THUMBNAIL leg passes none — a picture has nowhere to put a
      # tally — and that is not a second traversal: which entities DRAW is identical either way,
      # this is one extra fact one consumer asks for.
      def each_geometry(pairs, unreadable: nil)
        off = layers_off(pairs)
        counter = 0

        parse_entities(pairs, unreadable:).each do |entity|
          layer = entity[:codes][8].first
          # A DXF layer can be switched OFF, recorded as a NEGATIVE colour on its table entry.
          # Honoured rather than ignored for the same reason `Lbrn2.hidden_cuts` is: a hidden
          # layer is construction geometry the author chose not to cut, and drawing it puts lines
          # in the picture that are not in the job — and, worse here, folds them into the measured
          # extent so the reported size describes something the machine will never make.
          next if layer && off.include?(layer)

          points, closed, curve = flatten(entity)
          next if points.nil? || points.length < 2

          counter += 1
          yield layer, points, closed, curve, counter
        end
      end

      # An entity → [points (model space, Y-up), closed?, curve_or_nil]. nil when undrawable.
      def flatten(entity)
        case entity[:type]
        when "LINE"                   then line_points(entity)
        when "CIRCLE"                 then circle_points(entity)
        when "ARC"                    then arc_points(entity)
        when "LWPOLYLINE", "POLYLINE" then polyline_points(entity)
        end
      end

      def line_points(entity)
        c = entity[:codes]
        x1 = f1(c[10]); y1 = f1(c[20]); x2 = f1(c[11]); y2 = f1(c[21])
        return nil if [ x1, y1, x2, y2 ].any?(&:nil?)

        [ [ [ x1, y1 ], [ x2, y2 ] ], false, nil ]
      end

      def circle_points(entity)
        c = entity[:codes]
        cx = f1(c[10]); cy = f1(c[20]); r = f1(c[40])
        return nil if [ cx, cy, r ].any?(&:nil?) || r <= 0

        n = arc_samples(r, 2 * Math::PI)
        pts = (0..n).map do |i|
          t = i * (2 * Math::PI / n)
          [ cx + (r * Math.cos(t)), cy + (r * Math.sin(t)) ]
        end
        [ pts, true, { type: :circle, cx:, cy:, r: } ]
      end

      # DXF arc angles are CCW DEGREES from +X, and the sweep always runs CCW from a0 to a1 — so
      # a1 < a0 wraps through 360 rather than sweeping backwards. `% 360` on the difference is
      # what encodes that; a plain subtraction draws the complement of the intended arc.
      def arc_points(entity)
        c = entity[:codes]
        cx = f1(c[10]); cy = f1(c[20]); r = f1(c[40])
        a0 = f1(c[50]); a1 = f1(c[51])
        return nil if [ cx, cy, r, a0, a1 ].any?(&:nil?) || r <= 0

        sweep = (a1 - a0) % 360
        sweep = 360.0 if sweep.zero? # a0 == a1 means the whole circle, not a zero-length arc
        rad = sweep * Math::PI / 180
        n = arc_samples(r, rad)
        start = a0 * Math::PI / 180
        pts = (0..n).map do |i|
          t = start + (i * rad / n)
          [ cx + (r * Math.cos(t)), cy + (r * Math.sin(t)) ]
        end
        [ pts, false, { type: :arc, cx:, cy:, r:, a0:, a1:, sweep: } ]
      end

      # LWPOLYLINE: vertex X in code 10 (repeated), Y in code 20 (repeated). Old-style POLYLINE
      # carries its verts as following VERTEX entities, reclaimed by fold_polyline_vertices.
      def polyline_points(entity)
        c = entity[:codes]
        raw =
          if entity[:verts]&.any?
            entity[:verts].map { |(x, y)| [ Float(x, exception: false), Float(y, exception: false) ] }
          else
            xs = c[10].map { |v| Float(v, exception: false) }
            ys = c[20].map { |v| Float(v, exception: false) }
            xs.zip(ys)
          end
        pts = raw.reject { |(x, y)| x.nil? || y.nil? }
        return nil if pts.length < 2

        closed = (c[70].first.to_i & 1) == 1
        # A CLOSED polyline REPEATS ITS FIRST POINT AS ITS LAST, matching what `Lbrn2` yields for
        # a Rect/Ellipse. `Geometry.simplify` always keeps the first and last point, so a closed
        # contour still closes after thinning — and the client draws a <polygon>, which closes
        # itself, so the duplicate is invisible there. Omitting it would leave the payload's
        # closed contours a point short of their own outline.
        pts = pts + [ pts.first ] if closed && pts.first != pts.last
        [ pts, closed, nil ]
      end

      # HOW MANY SEGMENTS TO FLATTEN AN ARC OF `radius` SPANNING `radians` INTO.
      #
      # Bounded by RELATIVE sagitta rather than an absolute mm error, because this runs in the
      # file's own units and the traversal deliberately does not know the scale yet (see
      # `each_geometry`). Chord sagitta for n segments is r(1 - cos(θ/2n)); holding it under
      # SAGITTA_RATIO of the radius makes the flattening equally accurate on a 2 mm hole and a
      # 2 m sheet, which an absolute tolerance cannot do without the scale.
      #
      # ROUNDED UP TO A MULTIPLE OF 4 for a full circle, so the axis extents are sampled EXACTLY
      # and the reported bbox — and therefore `d` — is the true diameter rather than a chord's.
      # `Lbrn2::ELLIPSE_SAMPLES` is 32 for the same reason and says so.
      SAGITTA_RATIO = 0.001
      MIN_ARC_SAMPLES = 8
      MAX_ARC_SAMPLES = 512

      def arc_samples(_radius, radians)
        # 1 - cos(θ/2n) <= ratio  =>  n >= θ / (2 * acos(1 - ratio))
        n = (radians / (2 * Math.acos(1 - SAGITTA_RATIO))).ceil
        n = n.clamp(MIN_ARC_SAMPLES, MAX_ARC_SAMPLES)
        n += (4 - (n % 4)) % 4
        n
      end

      # ---- header / tables ---------------------------------------------------------------

      # MILLIMETRES PER DRAWING UNIT, from the header's $INSUNITS.
      #
      # THE ONE PLACE A DXF'S NUMBERS BECOME PHYSICAL, and getting it wrong makes every reported
      # measurement wrong by a constant factor while the drawing still looks perfect — which is
      # why it is a named table rather than a magic multiplier at the call site.
      #
      # 0 IS "UNITLESS" AND RESOLVES TO MILLIMETRES. That is a choice, not a reading: the file
      # genuinely does not say. Millimetres is the right default for this app's corpus (laser and
      # CNC sources are overwhelmingly mm, and a DXF exported from a maker tool routinely omits
      # the header entirely — the sample fixture here has no HEADER section at all), and it has
      # the property that a file which IS in mm measures correctly with no header, which is the
      # common case. A file in inches without $INSUNITS will read 25.4x small; nothing in the
      # format lets us know that, so the alternative is refusing to measure DXF at all.
      INSUNITS_MM = {
        1 => 25.4,        # inches
        2 => 304.8,       # feet
        4 => 1.0,         # millimetres
        5 => 10.0,        # centimetres
        6 => 1000.0,      # metres
        8 => 0.0000254,   # microinches
        9 => 0.0254,      # mils
        10 => 914.4,      # yards
        12 => 0.000001,   # nanometres
        13 => 0.001,      # microns
        14 => 100.0       # decimetres
      }.freeze

      DEFAULT_MM_PER_UNIT = 1.0

      def mm_per_unit(pairs)
        code = header_int(pairs, "$INSUNITS")
        INSUNITS_MM.fetch(code, DEFAULT_MM_PER_UNIT)
      end

      # The integer value of a header variable, or nil. A header var is a (9, "$NAME") pair
      # followed by its typed value pair — for $INSUNITS a (70, int). Scanned rather than indexed
      # because the HEADER section is small and this runs once per file.
      def header_int(pairs, name)
        idx = pairs.index { |(code, value)| code == 9 && value == name }
        return nil if idx.nil?

        found = pairs[(idx + 1)..(idx + 4)]&.find { |(code, _)| code == 70 }
        found && Integer(found.last, exception: false)
      end

      # Layer name → "#rrggbb", read from the TABLES section's LAYER records (code 2 = name,
      # code 62 = AutoCAD Color Index).
      #
      # THE LAYER TABLE IS WHERE A DXF'S COLOURS ACTUALLY LIVE. An entity's own code 62 is usually
      # absent or 256 (BYLAYER), so reading only the entity would leave nearly every real file
      # colourless — the reverse of LightBurn, where the file carries no colour and the palette is
      # the fallback.
      def layer_colors(pairs)
        layer_records(pairs).each_with_object({}) do |(name, aci), out|
          hex = aci_color(aci)
          out[name] = hex if hex
        end
      end

      # Layers switched off — recorded as a NEGATIVE colour index on the table entry.
      def layers_off(pairs)
        layer_records(pairs).filter_map { |(name, aci)| name if aci&.negative? }.to_set
      end

      # [[name, aci_or_nil], ...] for every LAYER record in the TABLES section.
      #
      # Walks the pairs directly rather than going through `parse_entities`, which by design
      # collects only drawable ENTITY_TYPES — adding LAYER there would put non-drawable records
      # into the list every drawing consumer iterates.
      def layer_records(pairs)
        out = []
        current = nil
        pairs.each do |(code, value)|
          if code.zero?
            out << current if current && current.first
            current = value == "LAYER" ? [ nil, nil ] : nil
          elsif current
            current[0] = value if code == 2
            current[1] = Integer(value, exception: false) if code == 62
          end
        end
        out << current if current && current.first
        out
      end

      # THE STANDARD AutoCAD COLOR INDEX ENTRIES, AND ONLY THOSE.
      #
      # 1-9 are the fixed, universally agreed ACI colours, and 250-255 the greyscale ramp. The
      # other 240 are a defined HSV lattice, but reproducing it from memory would be exactly the
      # "30 colours guessed" objection §14h raises against inventing a palette — so an index
      # outside this table returns nil and the client draws black, which claims nothing.
      #
      # 7 IS BLACK HERE, NOT WHITE. ACI 7 renders against the viewport background — white on
      # AutoCAD's traditional black canvas, black on a white one. The Measure view draws on a
      # light stage, so white would be invisible; black is the same choice every DXF viewer with
      # a light background makes, and matches this renderer's own STROKE default.
      ACI = {
        1 => "#ff0000", 2 => "#ffff00", 3 => "#00ff00", 4 => "#00ffff",
        5 => "#0000ff", 6 => "#ff00ff", 7 => "#000000", 8 => "#808080", 9 => "#c0c0c0",
        250 => "#333333", 251 => "#5b5b5b", 252 => "#848484",
        253 => "#adadad", 254 => "#d6d6d6", 255 => "#ffffff"
      }.freeze

      def aci_color(aci) = aci && ACI[aci.abs]

      # ---- SVG (the thumbnail) -----------------------------------------------------------

      def to_svg(dxf_bytes, size: 512)
        pairs = tokenize(dxf_bytes)
        colors = layer_colors(pairs)
        bbox = BBox.new
        els = []

        each_geometry(pairs) do |layer, points, closed, curve, _object_id|
          flipped = points.map { |(x, y)| flip(x, y) }
          flipped.each { |(x, y)| bbox.add(x, y) }
          els << element_svg(flipped, closed, curve, colors[layer] || STROKE)
        end

        wrap_svg(els, bbox, size)
      end

      # The exact primitive where `curve` offers one, else the flattened points. See
      # `each_geometry` on why both are available.
      def element_svg(flipped, closed, curve, stroke)
        case curve && curve[:type]
        when :circle then circle_svg(curve, stroke)
        when :arc    then arc_svg(curve, stroke)
        else              polyline_svg(flipped, closed, stroke)
        end
      end

      def circle_svg(curve, stroke)
        fx, fy = flip(curve[:cx], curve[:cy])
        %(<circle cx="#{n(fx)}" cy="#{n(fy)}" r="#{n(curve[:r])}" fill="none" ) +
          %(stroke="#{stroke}" stroke-width="0.5"/>)
      end

      def arc_svg(curve, stroke)
        r = curve[:r]
        sx = curve[:cx] + (r * Math.cos(curve[:a0] * Math::PI / 180))
        sy = curve[:cy] + (r * Math.sin(curve[:a0] * Math::PI / 180))
        ex = curve[:cx] + (r * Math.cos(curve[:a1] * Math::PI / 180))
        ey = curve[:cy] + (r * Math.sin(curve[:a1] * Math::PI / 180))
        ps = flip(sx, sy); pe = flip(ex, ey)
        large = curve[:sweep] > 180 ? 1 : 0
        # Y-flip reverses orientation, so the sweep flag flips from CCW (1) to 0.
        %(<path d="M #{n(ps[0])} #{n(ps[1])} A #{n(r)} #{n(r)} 0 #{large} 0 #{n(pe[0])} #{n(pe[1])}" ) +
          %(fill="none" stroke="#{stroke}" stroke-width="0.5"/>)
      end

      def polyline_svg(flipped, closed, stroke)
        # AN OPEN TWO-POINT CONTOUR IS A LINE, and saying so keeps this refactor's output
        # byte-identical to the per-entity version it replaced — which is the evidence that
        # routing the thumbnail through `each_geometry` changed the traversal's plumbing and not
        # its picture. It is also simply true of a 2-vertex LWPOLYLINE, which reaches this branch
        # by the same route and draws the same either way.
        if !closed && flipped.length == 2
          (x1, y1), (x2, y2) = flipped
          return %(<line x1="#{n(x1)}" y1="#{n(y1)}" x2="#{n(x2)}" y2="#{n(y2)}" ) +
                 %(stroke="#{stroke}" stroke-width="0.5"/>)
        end

        # A closed contour arrives with its first point repeated as its last (see
        # polyline_points); <polygon> closes itself, so the duplicate is dropped for drawing.
        pts = closed ? flipped[0..-2] : flipped
        tag = closed ? "polygon" : "polyline"
        attr = pts.map { |(x, y)| "#{n(x)},#{n(y)}" }.join(" ")
        %(<#{tag} points="#{attr}" fill="none" stroke="#{stroke}" stroke-width="0.5"/>)
      end

      # ---- lexing / entity records -------------------------------------------------------

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

      # Walk the pairs, slicing them into entity records keyed by their group codes. Entity types
      # this parser cannot draw are skipped, and `unreadable:` is where their NAMES survive that
      # (see `unreadable?`) — the record itself is dropped, codes and all.
      #
      # THIS WALKS EVERY SECTION, NOT THE ENTITIES SECTION. An earlier comment here claimed "we
      # only look at the ENTITIES section's records", and there is no section filter anywhere in
      # this file: a BLOCKS-section entity is collected and drawn exactly like a top-level one,
      # which is why a block body draws at its DEFINITION coordinates and again at nothing
      # (tinkerex#219 owns the fix; the prose is corrected here so the next reader is not misled
      # into thinking the behaviour is already scoped). It is also why the TABLES and OBJECTS
      # sections' records arrive on this same `0`-code stream, which `unreadable?` has to account
      # for.
      def parse_entities(pairs, unreadable: nil)
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
              else
                unreadable[value] = (unreadable[value] || 0) + 1 if unreadable && unreadable?(value)
                nil
              end
          elsif current
            current[:codes][code] << value
          end
        end
        entities << current if current
        fold_polyline_vertices(entities)
      end

      # Is a `0`-code value an entity type we met and could not draw — as opposed to something
      # that was never geometry in the first place?
      #
      # TWO POPULATIONS ARRIVE ON ONE STREAM, because `parse_entities` above has no section filter.
      # `STRUCTURAL` therefore has to cover both: the markers that open and close a section, a
      # table, a block or a vertex run; AND the RECORD types the TABLES and OBJECTS sections are
      # made of, which are not drawings of anything. Measured on the real corpus, one file carries
      # 33 `LAYER`s, another 180 `BLOCK_RECORD`s and 16 `VISUALSTYLE`s — reporting those as
      # geometry we failed to draw would be a louder lie than the silence this replaced.
      #
      # A SKIP-LIST, NOT AN ALLOWLIST, AND THE DIRECTION OF THE MISTAKE IS THE ARGUMENT. §14b
      # records the skip-list blind spot as this repo's recurring bug — but there a missed entry
      # loses DATA, silently and permanently, and here it can only add a name to a status line. An
      # allowlist of "entity types we have heard of" would restore exactly the silence this exists
      # to end: the next ELLIPSE-shaped gap would vanish without a word again, which is the whole
      # defect. Enumerated from the 129-file corpus plus the spec's table and object records; a
      # miss is noise, and noise is the side to be wrong on.
      #
      # VERTEX IS NOT HERE BECAUSE IT IS NEVER REACHED — `parse_entities` keeps it as a drawable
      # POLYLINE's own points. It would otherwise be the loudest false report in the corpus: 10,792
      # of them in one file that renders perfectly.
      STRUCTURAL = %w[
        SECTION ENDSEC EOF TABLE ENDTAB BLOCK ENDBLK SEQEND CLASS
        APPID BLOCK_RECORD DIMSTYLE LAYER LTYPE STYLE UCS VIEW VPORT
        DICTIONARY ACDBDICTIONARYWDFLT ACDBPLACEHOLDER DICTIONARYVAR XRECORD
        LAYOUT PLOTSETTINGS MLINESTYLE VISUALSTYLE SCALE MATERIAL TABLESTYLE
        CELLSTYLEMAP SORTENTSTABLE GROUP IDBUFFER FIELD FIELDLIST DATATABLE
        LAYER_INDEX SPATIAL_INDEX SPATIAL_FILTER RASTERVARIABLES WIPEOUTVARIABLES
        IMAGEDEF IMAGEDEF_REACTOR ACAD_PROXY_OBJECT SUNSTUDY VBA_PROJECT
      ].to_set.freeze

      def unreadable?(value) = !value.empty? && !STRUCTURAL.include?(value)

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
