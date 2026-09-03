module Maker
  module Previews
    # DXF (`.dxf`) → SVG → PNG, and → the Measure view's geometry payload.
    #
    # DXF (AutoCAD interchange) is a tagged "group code / value" ASCII format: pairs of lines
    # where an integer group code is followed by its value. DWG (the binary sibling) has no
    # permissive parser (LibreDWG is GPL) and is intentionally NOT handled here. We ship a
    # minimal, dependency-free in-Ruby parser for the common 2D entities a maker's laser/CNC
    # source carries — LINE, LWPOLYLINE/POLYLINE, CIRCLE, ARC, SPLINE, plus BLOCK bodies placed by
    # their INSERTs — and emit an SVG, then delegate to the existing `Svg` renderer (SVG is itself
    # browser-renderable, no rasterizer needed). A type NOT on that list is REPORTED rather than
    # dropped; `flatten` and `Geometry.build`'s `unreadable:` are where that is argued.
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
      #   2  SPLINE drawn, POLYLINE bulges drawn as arcs, BLOCK bodies placed at their INSERTs
      #      instead of at their definition coordinates, and a full-turn ARC drawn as a circle
      #      rather than as an `A` command SVG omits (tinkerex#216, #219, #215). FOUR CHANGES, ONE
      #      BUMP: a revision names a BUILD of this renderer, not a reason, and re-rendering the
      #      library once covers all four.
      THUMBNAIL_REVISION = 2

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
      # with points in DXF MODEL SPACE: native drawing units, Y-UP. For an entity the drawing holds
      # directly those are exactly the numbers the file records; for one inside a BLOCK they are
      # its definition coordinates carried through the INSERT's affine, which is the only place
      # this traversal transforms anything. Neither the Y-flip (SVG is Y-down) nor the unit scale is applied here, because the
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
      # `unreadable:` IS AN OPTIONAL TALLY THE CALLER OWNS — a `{ "ELLIPSE" => 2 }` hash this walk
      # fills in with what it met and could not draw, so the payload can say so instead of dropping
      # it without a word (see `Geometry.build`). IT HAS TWO FILLERS AND THEY ARE NOT
      # INTERCHANGEABLE: `parse_document` counts a type this parser does not handle AT ALL, and
      # `tally_refusal` counts a type it DOES handle meeting an instance it cannot read — the second
      # exists precisely because the first stops firing for a type the moment that type becomes
      # drawable. Handed IN rather than returned because
      # `Geometry.build` binds its own `unreadable:` before the traversal block runs; the caller
      # gives both the same object. The THUMBNAIL leg passes none — a picture has nowhere to put a
      # tally — and that is not a second traversal: which entities DRAW is identical either way,
      # this is one extra fact one consumer asks for.
      #
      # A BLOCK IS PLACED BY ITS INSERTS AND DRAWN NOWHERE ELSE, which is a REMOVAL as much as an
      # addition — see `parse_document`. So the walk is recursive: an INSERT expands its block's
      # entities under a composed affine instead of yielding a contour of its own.
      def each_geometry(pairs, unreadable: nil, &block)
        entities, blocks = parse_document(pairs, unreadable:)
        state = { off: layers_off(pairs), blocks:, unreadable:, counter: 0 }

        emit_entities(entities, IDENTITY, state, [].freeze, &block)
      end

      # ONE LEVEL OF THE WALK: a list of entity records under one accumulated transform.
      #
      # `state` CARRIES THE OBJECT-ID COUNTER BECAUSE THE RECURSION MUST SHARE IT. Ids count DRAWN
      # contours in document order, and a block placed twice yields two independently selectable
      # shapes — the client groups and selects by that id, so a per-level counter would hand both
      # copies the same one and clicking the left one would highlight the right.
      def emit_entities(entities, xf, state, stack, &block)
        entities.each do |entity|
          layer = entity[:codes][8].first
          # A DXF layer can be switched OFF, recorded as a NEGATIVE colour on its table entry.
          # Honoured rather than ignored for the same reason `Lbrn2.hidden_cuts` is: a hidden
          # layer is construction geometry the author chose not to cut, and drawing it puts lines
          # in the picture that are not in the job — and, worse here, folds them into the measured
          # extent so the reported size describes something the machine will never make.
          #
          # AN INSERT ON AN OFF LAYER TAKES ITS WHOLE BLOCK WITH IT, which is what this check
          # placed BEFORE the INSERT branch buys: the block reference is the entity the drawing
          # holds, so hiding it hides the placement rather than each contour inside it.
          next if layer && state[:off].include?(layer)

          if entity[:type] == "INSERT"
            emit_insert(entity, xf, state, stack, &block)
            next
          end

          points, closed, curve = flatten(entity)
          if points.nil? || points.length < 2
            tally_refusal(entity, state[:unreadable])
            next
          end

          tally_lwpolyline_bulge(entity, state[:unreadable])

          state[:counter] += 1
          block.call(layer, apply_affine(points, xf), closed, transform_curve(curve, xf), state[:counter])
        end
      end

      # ---- blocks and inserts --------------------------------------------------------------

      # AN INSERT PLACES A BLOCK'S ENTITIES UNDER A COMPOSED AFFINE — the entity type this parser
      # ignored for years while drawing the block bodies themselves (see `parse_document`).
      #
      # EVERY PATH THAT DECLINES TO PLACE A BLOCK TALLIES, AND THAT IS THE WHOLE REASON THIS METHOD
      # HAS FOUR NAMED REFUSALS RATHER THAN A `return`. Stage 1's backstop is TYPE-based:
      # `parse_document` counts a `0`-code name that is NOT in `ENTITY_TYPES`, which is how INSERT
      # was reported (177 in `cards.dxf` alone) while it was undrawable. Adding it to that list —
      # the change that makes blocks place at all — SILENCES that path for INSERT completely, so a
      # refused insert would vanish exactly as before, with the status line now stating that
      # nothing was skipped. `tally_refusal` cannot cover it either: an INSERT never reaches
      # `flatten`, because it yields many contours rather than one.
      #
      # DISTINCT NAMES, NOT A BARE `INSERT`. "The file names a block it does not define",
      # "the nesting is deeper than we will follow" and "this block contains itself" are three
      # different claims about a drawing and must not add up into one number — the same argument
      # `SPLINE(malformed)` and `LWPOLYLINE(bulge)` make. `INSERT(unknown-block)` is the likely
      # real one: a file saved without its dependencies, or a BLOCKS section this parser declined
      # to read (`parse_document` requires the section LABEL).
      UNKNOWN_BLOCK = "INSERT(unknown-block)".freeze
      CYCLIC_BLOCK = "INSERT(cyclic)".freeze
      TOO_DEEP_BLOCK = "INSERT(too-deep)".freeze
      TOO_MANY_CELLS = "INSERT(too-many)".freeze

      # HOW FAR A CHAIN OF NESTED INSERTS IS FOLLOWED, AND IT IS NOT THE CYCLE GUARD. The stack
      # below already refuses a block that contains itself, so this bounds the OTHER explosion: a
      # block inserting two children, each inserting two more, doubles the drawn geometry per level
      # out of a file that grows only linearly. Real nesting is shallow — `cards.dxf`, the deepest
      # file in the corpus, reaches four — so 16 is far outside anything a drawing does.
      MAX_INSERT_DEPTH = 16

      # A MINSERT'S ROW x COLUMN COUNTS COME FROM THE FILE AND ARE THE ONE PLACE A TINY INPUT CAN
      # DEMAND UNBOUNDED OUTPUT — `70`/`71` are integers, so a malformed pair asks for billions of
      # copies of a block from twelve bytes. Same sentence as the cycle guard, different words: a
      # renderer reading user files must not be hangable by one of them. Zero real occurrences in
      # 129 files, so the ceiling is set where an honest drawing could plausibly reach (a 100 x 100
      # perforation grid) rather than where the corpus sits.
      MAX_INSERT_CELLS = 10_000

      # `stack` IS THE RECURSION PATH — THE CHAIN OF BLOCKS CURRENTLY BEING EXPANDED — AND NOT A
      # GLOBAL VISITED SET, WHICH IS THE OBVIOUS SPELLING AND IS A DATA-LOSS BUG. A block placed
      # twice is ordinary (that is what a block IS), so a set accumulated across the whole walk
      # draws the FIRST placement and silently drops every other one — the same disappearance this
      # arc exists to end, delivered by the guard meant to prevent a hang. A path answers the
      # question actually being asked, "does this block contain itself", and it is per-branch: the
      # `stack + [name]` below is a new array, so a sibling INSERT of the same block still expands.
      # 168 of `cards.dxf`'s 177 INSERTs are nested and its blocks are shared, so the wrong answer
      # here loses most of a real drawing.
      def emit_insert(entity, outer, state, stack, &block)
        c = entity[:codes]
        name = c[2].first
        body = name && state[:blocks][name]

        return tally_insert(state, UNKNOWN_BLOCK) if body.nil?
        return tally_insert(state, CYCLIC_BLOCK) if stack.include?(name)
        return tally_insert(state, TOO_DEEP_BLOCK) if stack.length >= MAX_INSERT_DEPTH

        cols = array_count(c[70])
        rows = array_count(c[71])
        return tally_insert(state, TOO_MANY_CELLS) if cols * rows > MAX_INSERT_CELLS

        inner_stack = stack + [ name ]
        rows.times do |row|
          cols.times do |col|
            xf = compose(outer, insert_affine(c, body[:base], col, row))
            emit_entities(body[:entities], xf, state, inner_stack, &block)
          end
        end
      end

      def tally_insert(state, key)
        unreadable = state[:unreadable]
        unreadable[key] = (unreadable[key] || 0) + 1 if unreadable
        nil
      end

      # A MINSERT COUNT, DEFAULTING TO ONE. `70`/`71` are absent on an ordinary INSERT, and a count
      # of 0 is what some exporters write for "not an array" — both mean a single placement, so
      # neither may be read as "draw nothing".
      def array_count(list)
        n = f1(list)
        n.nil? || n < 1 ? 1 : n.to_i
      end

      # ONE ARRAY CELL'S AFFINE, AS [a, b, c, d, e, f] meaning x' = ax + by + e, y' = cx + dy + f.
      #
      # SCALE, THEN ROTATE, THEN TRANSLATE — the order the format specifies and the order that
      # shows: (10, 5) scaled by (2, 3) and turned a quarter turn is (-15, 20), where rotating
      # first gives (-10, 30). A plausible drawing either way, which is why the fixture pins it.
      #
      # THE BLOCK'S BASE POINT IS SUBTRACTED FIRST, because it is the block's ORIGIN and not an
      # offset to add: the entity coordinates a block records are relative to it. Folded into the
      # translation (`t − L·base`) rather than applied as a separate step so one affine describes
      # the whole placement and composes with its parent's by multiplication. Every one of
      # `cards.dxf`'s 180 blocks has a base of (0, 0), so the corpus is no evidence at all here.
      #
      # A NEGATIVE SCALE IS A MIRROR AND IS PASSED THROUGH AS ITS SIGN. Reading `|sx|` draws the
      # block at the right size on the wrong side of the insertion point, with a bbox of the
      # identical WIDTH — the same invisible sign loss `bulge_arc` records one entity type along.
      #
      # THE ARRAY STEP RIDES THE ROTATED AXES. `44`/`45` are spacings along the block's own X and
      # Y, which the rotation turns with it, so the grid stays square to the copies rather than to
      # the drawing.
      def insert_affine(codes, base, col, row)
        sx = insert_scale(codes[41])
        sy = insert_scale(codes[42])
        rot = (f1(codes[50]) || 0.0) * Math::PI / 180
        cos = Math.cos(rot)
        sin = Math.sin(rot)

        a = cos * sx
        b = -sin * sy
        c = sin * sx
        d = cos * sy

        dx = col * (f1(codes[44]) || 0.0)
        dy = row * (f1(codes[45]) || 0.0)
        tx = (f1(codes[10]) || 0.0) + (cos * dx) - (sin * dy)
        ty = (f1(codes[20]) || 0.0) + (sin * dx) + (cos * dy)

        bx, by = base
        [ a, b, c, d, tx - (a * bx) - (b * by), ty - (c * bx) - (d * by) ]
      end

      # AN ABSENT SCALE IS 1, THE FORMAT'S OWN DEFAULT — most INSERTs carry no 41/42/43 at all
      # (none of `cards.dxf`'s 177 do). A scale the file DOES state is honoured verbatim, zero
      # included: substituting 1 for a stated 0 would draw a full-size copy the file never asked
      # for, which is a louder wrong answer than the degenerate one it wrote.
      def insert_scale(list)
        s = f1(list)
        s.nil? ? 1.0 : s
      end

      # THE TRANSFORM A TOP-LEVEL ENTITY CARRIES, AND IT IS COMPARED BY IDENTITY, NOT BY VALUE.
      # `apply_affine` and `compose` short-circuit on `equal?(IDENTITY)`, so an entity outside any
      # block reaches the caller with the very Float objects `flatten` produced — no multiply by
      # 1.0, no add of 0.0, and therefore no chance of a `-0.0` or a rounding step appearing in a
      # payload that no block was involved in. A file with no BLOCKS section renders byte-identical
      # to what it did before inserts existed, which is what the two fixture digests assert.
      IDENTITY = [ 1.0, 0.0, 0.0, 1.0, 0.0, 0.0 ].freeze

      def apply_affine(points, xf)
        return points if xf.equal?(IDENTITY)

        a, b, c, d, e, f = xf
        points.map { |(x, y)| [ (a * x) + (b * y) + e, (c * x) + (d * y) + f ] }
      end

      # OUTER ∘ INNER — the parent's placement applied to the child's, which is the composition a
      # nested INSERT needs and the one a naive "add the translations" gets wrong the moment the
      # parent rotates. 168 of `cards.dxf`'s 177 INSERTs are nested.
      def compose(outer, inner)
        return inner if outer.equal?(IDENTITY)

        oa, ob, oc, od, oe, of = outer
        ia, ib, ic, id, ie, if_ = inner
        [ (oa * ia) + (ob * ic), (oa * ib) + (ob * id),
          (oc * ia) + (od * ic), (oc * ib) + (od * id),
          (oa * ie) + (ob * if_) + oe, (oc * ie) + (od * if_) + of ]
      end

      # A PLACED CURVE DESCRIPTOR — TRANSFORMED WHEN IT SURVIVES THE TRANSFORM, DROPPED WHEN IT
      # DOES NOT, AND NEVER LEFT IN THE BLOCK'S OWN COORDINATES.
      #
      # `curve` is a RICHER RENDERING OF THE SAME POINTS (see `each_geometry`), so it has to move
      # with them or it describes a different shape from the bbox beside it — and the THUMBNAIL
      # draws the descriptor INSTEAD of the points, so a stale one is a wrong picture rather than a
      # coarse one.
      #
      # ONLY A SIMILARITY KEEPS A CIRCLE A CIRCLE. Under a non-uniform scale it is an ellipse whose
      # axes are turned by the rotation, and the wire's `e` form carries rx and ry with NO rotation
      # term — there is no honest descriptor to emit, so none is. Dropping is always safe: the
      # flattened points still carry the true shape, `b`/`d`/the job box are computed from them,
      # and the thumbnail falls back to a polyline.
      #
      # A MIRROR REVERSES AN ARC'S DIRECTION, WHICH IS WHY THE ENDPOINTS SWAP. DXF arcs always
      # sweep counter-clockwise from a0 to a1; a negative determinant flips that, so the placed
      # arc's counter-clockwise run starts where the original ENDED. Leaving a0 alone draws the
      # complementary arc — same endpoints, the wrong side, and `arc_svg` writes it as-is.
      # `sweep` is carried across unchanged rather than recomputed, because a similarity preserves
      # it exactly and recomputing would turn `arc_points`' deliberate 360 back into 0.
      SIMILARITY_EPSILON = 1e-9

      def transform_curve(curve, xf)
        return nil if curve.nil?
        return curve if xf.equal?(IDENTITY)

        a, b, c, d = xf
        scale = Math.sqrt((a * a) + (c * c))
        return nil unless scale.positive?

        tol = SIMILARITY_EPSILON * scale * scale
        return nil unless ((b * b) + (d * d) - (scale * scale)).abs <= tol
        return nil unless ((a * b) + (c * d)).abs <= tol

        placed = curve.merge(cx: (a * curve[:cx]) + (b * curve[:cy]) + xf[4],
                             cy: (c * curve[:cx]) + (d * curve[:cy]) + xf[5],
                             r: curve[:r] * scale)
        return placed if curve[:type] == :circle

        a0 = placed_angle(curve[:a0], xf)
        a1 = placed_angle(curve[:a1], xf)
        a0, a1 = a1, a0 if ((a * d) - (b * c)).negative?
        placed.merge(a0:, a1:)
      end

      # Where the transform sends the direction the angle names — read back off the IMAGE of the
      # unit vector rather than added to the rotation, so one expression covers a rotation, a
      # mirror and both at once instead of a case per sign.
      def placed_angle(degrees, xf)
        a, b, c, d = xf
        t = degrees * Math::PI / 180
        vx = Math.cos(t)
        vy = Math.sin(t)
        (Math.atan2((c * vx) + (d * vy), (a * vx) + (b * vy)) * 180 / Math::PI) % 360
      end

      # A DRAWABLE TYPE THIS PARSER MET AND REFUSED, COUNTED SEPARATELY FROM ONE IT CANNOT DRAW AT
      # ALL — and that separation is the whole reason this method exists rather than reusing
      # `parse_document`'s tally.
      #
      # THAT TALLY IS TYPE-BASED AND STOPS FIRING THE MOMENT A TYPE BECOMES DRAWABLE.
      # `parse_document` counts a `0`-code name that is NOT in `ENTITY_TYPES`, so while SPLINE sat
      # outside that list every spline was reported. Adding SPLINE to it — which is what makes
      # 18,906 of them draw — silences that path for splines completely, including the ones
      # `flatten` refuses: they would vanish exactly as before, with the status line now stating
      # that nothing was skipped, which is worse than the silence it replaced. The same trap waits
      # for every future type promoted into `ENTITY_TYPES`.
      #
      # A DISTINCT NAME, NEVER THE BARE TYPE. "We cannot read this type at all" and "we read this
      # one and it was broken" are different claims about a file and must not add up into one
      # number — the same argument `LWPOLYLINE(bulge)` above makes from the other direction.
      #
      # ONLY THE TYPES LISTED, AND THE OMISSIONS ARE DELIBERATE. A LINE with one endpoint, a
      # CIRCLE of radius 0, a POLYLINE with a single vertex: those refusals lose an entity with NO
      # EXTENT, so the drawing and the bbox are complete without them and a report would be pure
      # noise on files that render perfectly. A refused SPLINE loses a real curve out of both, which
      # is the whole difference. Measured over the five real files kept for this work — 8.7 MB of
      # `cards.dxf` included — the parser refuses ZERO non-spline entities, so listing them would
      # add a name to the wire that no file has ever earned.
      REFUSAL_TALLIED = %w[SPLINE].to_set.freeze
      REFUSAL_SUFFIX = "(malformed)".freeze

      def tally_refusal(entity, unreadable)
        return unless unreadable && REFUSAL_TALLIED.include?(entity[:type])

        key = entity[:type] + REFUSAL_SUFFIX
        unreadable[key] = (unreadable[key] || 0) + 1
      end

      # AN LWPOLYLINE'S BULGES ARE COUNTED, NOT DRAWN — the honest half of a feature this parser
      # implements for `POLYLINE` only. See `bulge_arc` for why the two halves of one DXF concept
      # are not equally reachable; what belongs HERE is that the shortfall must be SAID.
      #
      # AND IT HAS TO BE SAID EXPLICITLY, BECAUSE THE TYPE-BASED TALLY CANNOT SEE IT.
      # `parse_document` counts a `0`-code name that is not in `ENTITY_TYPES`, and `LWPOLYLINE` has
      # always been in it — so a bulged LWPOLYLINE reaches `add` like any other contour, chorded,
      # with the status line stating no shortfall at all. That is the same trap the SPLINE work is
      # warned about from the other direction (a type joining `ENTITY_TYPES` stops being tallied);
      # here the type never left it. A DISTINCT NAME, never a bare `LWPOLYLINE`: "we cannot read
      # this type" and "we read this one and part of it came out straight" are different claims and
      # must not add up into one number.
      #
      # ONE PER ENTITY, NOT ONE PER BULGE, so the count means the same thing as every other entry
      # in the tally: contours we did not fully read. Placed AFTER the flatten guard so it claims
      # only about shapes that actually drew, and after the off-layer skip so a hidden construction
      # layer is neither drawn, measured, nor complained about.
      #
      # THE TYPE CHECK IS NOT A TIDINESS: CODE 42 IS NOT "BULGE", IT IS "THE 42nd THING THIS RECORD
      # TYPE DECLARES". Measured on the corpus, `cards.dxf` carries 3,308 SPLINE `42`s (a
      # control-point tolerance) plus `42`s on VPORT, STYLE and VISUALSTYLE records — so a tally
      # that looked for the CODE rather than for an LWPOLYLINE's code would report 3,308 unreadable
      # things about a file containing no bulge at all.
      LWPOLYLINE_BULGE = "LWPOLYLINE(bulge)".freeze

      def tally_lwpolyline_bulge(entity, unreadable)
        return unless unreadable && entity[:type] == "LWPOLYLINE" && entity[:codes].key?(42)
        # A ZERO 42 IS THE ORDINARY CASE — exporters write one on every straight vertex, so a check
        # on the code's PRESENCE would report most of the corpus as partly unreadable.
        return unless entity[:codes][42].any? { |v| f = Float(v, exception: false); f && !f.zero? }

        unreadable[LWPOLYLINE_BULGE] = (unreadable[LWPOLYLINE_BULGE] || 0) + 1
      end

      # An entity → [points (model space, Y-up), closed?, curve_or_nil]. nil when undrawable.
      #
      # THIS IS THE `case` WITH NO `else`, AND IT IS WHY THIS ARC EXISTS. A missing arm returns nil
      # for a whole entity type, and until `unreadable:` there was nothing anywhere to say so: 18,906
      # SPLINEs across 29 of 129 real files were dropped with no error, no log and no status, and a
      # dropped entity never reaches `Collector#add`, so it is absent from the BBOX as well as the
      # picture — the reported job size describing a subset of the file (tinkerex#216).
      #
      # SO A NEW ARM HERE IS TWO EDITS, NOT ONE. The type must join `ENTITY_TYPES`, which is what
      # SILENCES `parse_document`'s type-based tally for it — see `tally_refusal` for why an instance
      # this method then refuses has to be counted under its own name instead.
      def flatten(entity)
        case entity[:type]
        when "LINE"                   then line_points(entity)
        when "CIRCLE"                 then circle_points(entity)
        when "ARC"                    then arc_points(entity)
        when "LWPOLYLINE", "POLYLINE" then polyline_points(entity)
        when "SPLINE"                 then spline_points(entity)
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
      # carries its verts as following VERTEX entities, reclaimed by fold_polyline_vertices —
      # which is also where a BULGE survives, as an optional third element per vertex.
      #
      # NO CURVE DESCRIPTOR, EVEN NOW THAT A BULGED SEGMENT IS AN EXACT ARC. `g` is PER CONTOUR
      # (see `each_geometry`) and a polyline is ONE contour carrying MANY segments, so there is no
      # slot for the several arcs a real bulged outline holds — a slot outline is two lines and two
      # semicircles in a single entity. Emitting the descriptor for one of them would claim the
      # WHOLE contour is that arc, which is worse than claiming nothing. A per-segment descriptor
      # is a wire-format change and belongs to tinkerex#217, not here.
      def polyline_points(entity)
        c = entity[:codes]
        raw =
          if entity[:verts]&.any?
            entity[:verts].map do |(x, y, bulge)|
              [ Float(x, exception: false), Float(y, exception: false),
                bulge && Float(bulge, exception: false) ]
            end
          else
            xs = c[10].map { |v| Float(v, exception: false) }
            ys = c[20].map { |v| Float(v, exception: false) }
            xs.zip(ys)
          end
        pts = raw.reject { |(x, y)| x.nil? || y.nil? }
        return nil if pts.length < 2

        closed = (c[70].first.to_i & 1) == 1
        [ expand_bulges(pts, closed), closed, nil ]
      end

      # Vertices (each optionally carrying a bulge) -> the flattened contour.
      #
      # A CLOSED polyline REPEATS ITS FIRST POINT AS ITS LAST, matching what `Lbrn2` yields for
      # a Rect/Ellipse. `Geometry.simplify` always keeps the first and last point, so a closed
      # contour still closes after thinning — and the client draws a <polygon>, which closes
      # itself, so the duplicate is invisible there. Omitting it would leave the payload's
      # closed contours a point short of their own outline.
      #
      # THE CLOSING SEGMENT IS A SEGMENT LIKE ANY OTHER AND CAN CARRY A BULGE — a bulge on the LAST
      # vertex of a closed polyline describes last→first, which a walk over consecutive pairs never
      # visits. A slot (two straight sides, two semicircular ends) is the commonest bulged contour
      # in a laser DXF and one of its two ends is exactly that segment, so missing it leaves a
      # D-shape: entirely plausible on screen, and half the height it should be.
      #
      # THE "already closed" TEST COMPARES COORDINATES ONLY. Some exporters repeat the first vertex
      # explicitly, and that repeat carries its own bulge — so `first != last` over whole vertex
      # records would answer "not closed yet" for two vertices at the same point and append a
      # zero-length closing segment.
      def expand_bulges(pts, closed)
        segments = pts.each_cons(2).to_a
        segments << [ pts.last, pts.first ] if closed && pts.first[0, 2] != pts.last[0, 2]

        out = [ pts.first[0, 2] ]
        segments.each { |(from, to)| out.concat(bulge_arc(from, to) || [ to[0, 2] ]) }
        out
      end

      # ONE BULGED SEGMENT -> its arc's points, EXCLUDING the start (the caller already holds it).
      # nil when the segment is straight, which is the caller's signal to keep the chord.
      #
      # A BULGE IS AN ARC SEGMENT RECORDED ON A VERTEX, AND READING ONLY THE COORDINATES DRAWS ITS
      # CHORD — a wrong picture whose bbox is also too SMALL, since an arc bulging outward reaches
      # past the chord it replaces. That is the half that makes it a measurement bug rather than a
      # cosmetic one: the job size describes a subset of the part. 3,869 non-zero bulges across 26
      # of 129 real files, 580 of them negative in one file alone (tinkerex#216).
      #
      # ONLY `POLYLINE` REACHES HERE, AND THE ASYMMETRY IS THE PARSER'S SHAPE. A `VERTEX` is its
      # own entity record with its own codes hash, so `codes[42]` is unambiguously THAT vertex's
      # bulge. An LWPOLYLINE holds its vertices as repeated 10/20 codes inline and its bulges as an
      # OPTIONAL 42 per vertex — and `parse_document` groups an entity's values BY CODE, so the
      # interleaving that says which 42 belongs to which vertex is gone before anything can read
      # it. Pairing them needs a positional parser, and all 3,869 real bulges are on POLYLINE, so
      # the LWPOLYLINE half is REPORTED instead (`tally_lwpolyline_bulge`) rather than guessed at.
      #
      # THE MATHS. `b = tan(Δθ/4)` with Δθ the SIGNED included angle, positive counter-clockwise —
      # so Δθ = 4·atan(b), which is why |Δθ| < 2π can never be reached. For a chord of length c the
      # SIGNED radius is c / (2·sin(Δθ/2)); keeping the sign is what lets one expression place the
      # centre on either side of the chord instead of a case per quadrant. The centre sits on the
      # perpendicular bisector, r·cos(Δθ/2) from the midpoint along the chord direction turned a
      # quarter turn counter-clockwise. The geometric radius is |r| and the polar start angle is
      # read back off the centre, because a negative r means the parametrisation's angle is the
      # geometric one plus π.
      #
      # THE SIGN IS LOAD-BEARING AND LOSING IT IS INVISIBLE: `|b|` draws an arc of the right radius
      # spanning the right chord on the WRONG SIDE of it, with a bbox of the identical SIZE. Only a
      # negative-bulge test that asserts WHERE the box sits can see it.
      #
      # `arc_samples` DOES THE FLATTENING, so the segment count is bounded by RELATIVE sagitta —
      # the traversal deliberately does not know the file's scale, which is that helper's own
      # documented reason for existing. Its floor of 8 samples costs a few points on a shallow
      # bulge; `Geometry.simplify` removes them again, and a floor is the wrong place to save.
      #
      # THE ONE REFUSAL IS AN ARC WHOSE RADIUS DWARFS ITS CHORD, AND IT COVERS BOTH DEGENERATE ENDS
      # AT ONCE. r = c / (2·sin(Δθ/2)), so |r|/c blows up as Δθ approaches EITHER 0 or a full turn:
      # a bulge of 1e-20 (a rounding artefact) and one of 1e20 (malformed) both put the centre
      # astronomically far from the chord, where the points come out of catastrophic cancellation
      # and one bad vertex takes the whole file's job box with it. Drawing the chord is what this
      # renderer did for both cases yesterday, so the fallback cannot be a regression. The
      # threshold is far outside anything real: the corpus's SHALLOWEST bulge, 2.6e-06 (a sweep of
      # 0.0006°), has |r|/c ≈ 1e5 and is still drawn as an arc.
      MAX_BULGE_RADIUS_RATIO = 500_000.0

      def bulge_arc(from, to)
        bulge = from[2]
        return nil if bulge.nil? || bulge.zero?

        x0, y0 = from
        x1, y1 = to
        dx = x1 - x0
        dy = y1 - y0
        chord = Math.hypot(dx, dy)
        return nil if chord.zero?

        theta = 4 * Math.atan(bulge)
        half = theta / 2.0
        # SIGNED. A sin of exactly zero divides to Infinity rather than raising, and Infinity fails
        # the ratio test below like any other over-large radius — so there is one refusal, not two.
        r = chord / (2 * Math.sin(half))
        return nil if r.abs > chord * MAX_BULGE_RADIUS_RATIO

        offset = r * Math.cos(half) / chord
        cx = ((x0 + x1) / 2.0) - (offset * dy)
        cy = ((y0 + y1) / 2.0) + (offset * dx)

        radius = r.abs
        a0 = Math.atan2(y0 - cy, x0 - cx)
        n = arc_samples(radius, theta.abs)
        (1..n).map do |i|
          t = a0 + (i * theta / n)
          [ cx + (radius * Math.cos(t)), cy + (radius * Math.sin(t)) ]
        end
      end

      # ---- splines -----------------------------------------------------------------------

      # A SPLINE -> its flattened contour, evaluated with de Boor over the file's own knot vector.
      # nil when the record cannot be read as a curve, which `each_geometry` REPORTS through
      # `tally_refusal` rather than dropping — see there for why that cannot be left to
      # `parse_document`'s type-based tally.
      #
      # WHAT THE REAL CORPUS ACTUALLY CONTAINS, because this is built for it and not for the spec's
      # full generality. Across the 29 of 129 files carrying splines (18,906 of them): degree (71)
      # is 3 EVERYWHERE and the fit-point count (74) is 0 EVERYWHERE, so every one is
      # control-point based and NO fit-point interpolation is needed — a SPLINE that gives fit
      # points and no control points is refused here rather than guessed at. Flag 70 takes
      # 0/8/11/24/27: bit 0 (closed) and bit 1 (periodic) are both present in quantity, 551 of
      # `cards.dxf`'s 3,308, which is why the evaluation is general de Boor over the knots rather
      # than the "interior multiplicity equals the degree, therefore a chain of Béziers" shortcut
      # the knot vectors otherwise invite.
      #
      # NO CURVE DESCRIPTOR, FOR `polyline_points`' REASON. `g` is PER CONTOUR and a spline is one
      # contour spanning many polynomial pieces, so there is no slot for it; and the wire has no
      # spline form to put there anyway. A measuring client reads the flattened points and is
      # correct.
      def spline_points(entity)
        c = entity[:codes]
        degree = c[71].first.to_i
        cps = c[10].zip(c[20]).map { |(x, y)| [ Float(x, exception: false), Float(y, exception: false) ] }
        knots = c[40].map { |v| Float(v, exception: false) }
        return nil if degree < 1 || cps.length < degree + 1
        return nil if cps.any? { |(x, y)| x.nil? || y.nil? }
        # n + p + 1 knots for n+1 control points of degree p — the format's own arithmetic, and
        # the one check that catches a truncated or padded knot run before the span search reads
        # off the end of it.
        return nil if knots.length != cps.length + degree + 1 || knots.any?(&:nil?)
        # THE SPAN SEARCH AND THE DOMAIN BOTH ASSUME A NON-DECREASING KNOT VECTOR. A file that
        # breaks that is malformed, and evaluating it anyway yields a scribble whose bbox takes
        # the whole file's job box with it.
        return nil unless knots.each_cons(2).all? { |(a, b)| b >= a }
        # The valid domain is [U[p], U[n+1]] — outside it the basis functions do not sum to 1 and
        # the curve is an extrapolation, not the drawing.
        return nil unless knots[cps.length] > knots[degree]

        hcp = homogeneous(cps, c[41])
        pts = flatten_spline(hcp, knots, degree)
        return nil if pts.length < 2

        # Flag bit 0 is CLOSED. Repeating the first point as the last is what `polyline_points`
        # does and for the same reason: `Geometry.simplify` always keeps both ends, so a closed
        # outline stays closed after thinning.
        closed = (c[70].first.to_i & 1) == 1
        pts << pts.first.dup if closed && pts.first != pts.last
        [ pts, closed, nil ]
      end

      # CONTROL POINTS AS (w·x, w·y, w), AND THE EVALUATION IS HOMOGENEOUS WHETHER OR NOT THE FILE
      # SAYS IT IS RATIONAL. Measured on the corpus: code 41 appears in two of the spline-carrying
      # families and EVERY weight in all of them is exactly 1.0, while flag bit 2 (rational) is
      # never set anywhere — which is the state the format's own convention describes. But the
      # homogeneous path is correct for both cases and costs one lerp and one divide, so reading
      # the FLAG to decide whether to read the WEIGHTS would be a branch that exists only to be
      # wrong on the first file that disagrees with today's corpus.
      #
      # A WEIGHT RUN THAT DOES NOT MATCH THE CONTROL POINTS ONE FOR ONE IS IGNORED, NOT REFUSED.
      # There is no correct reading of a half-length weight array, and the unweighted curve through
      # the same control polygon is a real curve rather than a scribble — losing the contour
      # entirely would be the larger error. Zero occurrences in the corpus. A non-positive weight
      # goes the same way: it puts a pole on the curve, which is not a drawing.
      def homogeneous(cps, raw_weights)
        weights = raw_weights.map { |v| Float(v, exception: false) }
        usable = weights.length == cps.length && weights.all? { |w| w && w.positive? }

        cps.each_with_index.map do |(x, y), i|
          w = usable ? weights[i] : 1.0
          [ x * w, y * w, w ]
        end
      end

      # THE WHOLE CURVE, SPAN BY SPAN. Only knot intervals of NON-ZERO width are curve; a repeated
      # knot is a continuity statement, not a piece to sample, and dividing by its zero width is
      # how a naive walk produces NaN coordinates that then poison the job box.
      #
      # THE SPAN INDEX COMES FROM THE ITERATION, WHICH IS THE SEARCH DONE ONCE INSTEAD OF PER
      # SAMPLE — and it is load-bearing, not bookkeeping: de Boor at parameter u is only the curve
      # when it is handed the span CONTAINING u. Given the wrong span it silently extrapolates that
      # span's polynomial, which draws a plausible curve of entirely the wrong shape and an equally
      # wrong bbox. `dxf_geometry_test.rb` pins it with a two-span fixture whose second half would
      # extrapolate to x = −40.
      #
      # THE RIGHT-HAND ENDPOINT IS EVALUATED WITH THE SPAN THAT ENDS THERE, deliberately: u =
      # U[k+1] is outside the half-open [U[k], U[k+1]) a search would return, but the piece is
      # continuous up to it and the alternative — the NEXT span — is the domain's end, where there
      # is no next.
      def flatten_spline(hcp, knots, degree)
        pts = []
        degree.upto(hcp.length - 1) do |span|
          lo = knots[span]
          hi = knots[span + 1]
          next if hi <= lo

          pts << de_boor(lo, span, degree, hcp, knots) if pts.empty?
          subdivide_span(pts, de_boor(hi, span, degree, hcp, knots), lo, hi, 0, span, degree, hcp, knots)
        end
        pts
      end

      # HOW FINELY A SPAN IS FLATTENED, AS A RELATIVE CRITERION — the midpoint's distance from the
      # chord, over the path length through it. RELATIVE for `arc_samples`' own documented reason:
      # this traversal deliberately does not know the file's scale, so an absolute millimetre
      # tolerance cannot be expressed here at all.
      #
      # 0.01 IS THE SAME FLATNESS `arc_samples` ALREADY CHOOSES, arrived at from the other end. For
      # a segment turning through θ the midpoint deviation over the chord is about θ/8, so a
      # ratio of 0.01 emits segments turning ~4.6°, where `arc_samples`' SAGITTA_RATIO of 0.001
      # against the RADIUS gives ~5.0°. A DXF is routinely both circles and splines; the two must
      # not disagree about how round a curve is.
      #
      # AND IT IS THE KNOB THAT DECIDES THE PAYLOAD, WHICH ON THE WORST REAL FILE DOES NOT FIT.
      # `cards.dxf` is 8.7 MB, 3,308 splines over 19,454 knot spans, and its measure payload goes
      # 563 KB -> 3,366 KB (render 0.53 s -> 1.61 s). The design's budget was 1,536 KB, and the
      # FLOOR — every span reduced to the straight chord between its own endpoints, which is not a
      # curve at all — measures 1,497 KB, so the budget leaves room for 0.3 extra points per span
      # and cannot be reached by thinning. Coarsening does not rescue it either: 0.02 gives
      # 2,272 KB and 0.05 gives 1,620 KB, both still over, while the median deviation from the true
      # curve goes 0.011 mm -> 0.042 mm -> 0.111 mm. 0.011 mm is `Geometry::SIMPLIFY_TOLERANCE`
      # almost exactly — the accuracy the payload is thinned to anyway — so the ratio is set by
      # what the rest of the pipeline already promises, and the overrun is REPORTED rather than
      # paid for in accuracy nothing else in the file gives up.
      #
      # DEPTH IS BOUNDED, AND THE FLOOR MATTERS AS MUCH AS THE CEILING. The floor of one forces
      # every span to be split at least once before the flatness test is trusted: a single cubic
      # piece can be an S whose midpoint sits exactly on its own chord, which reads as perfectly
      # flat and would collapse the curve to a straight line. The ceiling is the budget — 3,308
      # splines in one real file, one family holding 514 spans in a SINGLE spline, so an
      # unbounded or fixed-high sample count is what blows the payload. Hitting it is not a
      # refusal and is not reported: the curve still draws, slightly coarser, exactly as
      # MAX_ARC_SAMPLES clamps an arc.
      SPLINE_FLATNESS_RATIO = 0.01
      MIN_SPLINE_DEPTH = 1
      MAX_SPLINE_DEPTH = 6

      # Appends the points of [lo, hi] AFTER its start, which the caller already holds, and ending
      # at `p_hi`. Recursive rather than an explicit stack — unlike `Geometry.simplify`, which
      # recurses once per KEPT POINT and so runs to a contour's length; here the depth is
      # MAX_SPLINE_DEPTH and nothing else.
      def subdivide_span(pts, p_hi, lo, hi, depth, span, degree, hcp, knots)
        p_lo = pts.last
        mid = (lo + hi) / 2.0
        p_mid = de_boor(mid, span, degree, hcp, knots)

        if depth >= MAX_SPLINE_DEPTH || (depth >= MIN_SPLINE_DEPTH && flat_enough?(p_lo, p_mid, p_hi))
          pts << p_hi
        else
          subdivide_span(pts, p_mid, lo, mid, depth + 1, span, degree, hcp, knots)
          subdivide_span(pts, p_hi, mid, hi, depth + 1, span, degree, hcp, knots)
        end
      end

      # Is the chord a·b a good enough stand-in for the curve through m?
      #
      # MEASURED AGAINST THE PATH LENGTH THROUGH m, NOT AGAINST THE CHORD, and that is the
      # difference between a criterion and a trap. On a shallow arc the two are the same number.
      # On a HAIRPIN — where the curve leaves and returns to nearly the same point — the chord is
      # near zero, so a chord-relative test divides a real deviation by nothing and calls the loop
      # flat; the path length is the loop's own size and correctly refuses.
      def flat_enough?(a, m, b)
        (ax, ay), (mx, my), (bx, by) = a, m, b
        len = Math.hypot(mx - ax, my - ay) + Math.hypot(bx - mx, by - my)
        return true if len.zero?

        chord = Math.hypot(bx - ax, by - ay)
        # Perpendicular distance from m to the chord, via the cross product — and when the chord
        # is degenerate, m's own distance from the shared endpoint, which is the loop's height.
        deviation = chord.zero? ? Math.hypot(mx - ax, my - ay)
                                : (((mx - ax) * (by - ay)) - ((my - ay) * (bx - ax))).abs / chord
        deviation <= SPLINE_FLATNESS_RATIO * len
      end

      # DE BOOR, ON THE SPAN THE CALLER SELECTED, in homogeneous coordinates.
      #
      #   d[j] = P[j + span - p]                                        for j = 0..p
      #   for r in 1..p, for j in p.downto(r):
      #     a = (u - U[j+span-p]) / (U[j+1+span-r] - U[j+span-p])
      #     d[j] = (1-a)·d[j-1] + a·d[j]
      #
      # A ZERO DENOMINATOR IS A REPEATED KNOT, NOT AN ERROR — the corresponding d[j] carries no
      # weight at this parameter, so `a = 0` selects d[j-1] and the recurrence is unaffected. It is
      # reachable on any clamped vector, which every real spline here has.
      #
      # THE HOMOGENEOUS DIVIDE HAPPENS ONCE, AT THE END. Dividing per level would be both slower
      # and wrong: the whole point of the (w·x, w·y, w) form is that the recurrence is LINEAR in
      # it, which projected coordinates are not.
      def de_boor(u, span, degree, hcp, knots)
        dx = Array.new(degree + 1)
        dy = Array.new(degree + 1)
        dw = Array.new(degree + 1)
        (0..degree).each do |j|
          x, y, w = hcp[j + span - degree]
          dx[j] = x
          dy[j] = y
          dw[j] = w
        end

        (1..degree).each do |r|
          degree.downto(r) do |j|
            lo = knots[j + span - degree]
            den = knots[j + 1 + span - r] - lo
            a = den.zero? ? 0.0 : (u - lo) / den
            b = 1.0 - a
            dx[j] = (b * dx[j - 1]) + (a * dx[j])
            dy[j] = (b * dy[j - 1]) + (a * dy[j])
            dw[j] = (b * dw[j - 1]) + (a * dw[j])
          end
        end

        w = dw[degree]
        w.zero? ? [ dx[degree], dy[degree] ] : [ dx[degree] / w, dy[degree] / w ]
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
      # Walks the pairs directly rather than going through `parse_document`, which by design
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

      # A FULL TURN IS DRAWN AS A CIRCLE, WHICH IS THE SAME BRANCH `DxfGeometry.curve_to_client_space`
      # ALREADY TAKES AND FOR THE SAME REASON — tinkerex#215. `arc_points` resolves a0 == a1 to a
      # sweep of 360 ("the whole circle, not a zero-length arc"), so the start and end points below
      # are computed from ONE angle and come out IDENTICAL; SVG's rule for an elliptical arc whose
      # endpoints coincide is to omit the segment ENTIRELY. The `A` command was therefore not a
      # coarse drawing of the circle, it was no drawing at all: `<path d="M 130 0 A 10 10 0 1 0
      # 130 0"/>` in a thumbnail with the shape simply missing, no error and nothing logged.
      #
      # `>=`, NOT `==`. `transform_curve` carries `sweep` across a block placement unchanged rather
      # than recomputing it, so this must read the same threshold the payload does or a full-turn
      # arc inside an INSERT would draw one way in the picture and another in the measurement.
      def arc_svg(curve, stroke)
        return circle_svg(curve, stroke) if curve[:sweep] >= 360

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
      #
      # AND THAT PAIRING IS WHY YOU MUST NEVER LINE-GREP A DXF TO MEASURE ONE. `grep -E "^SPLINE$"`
      # cannot match a CRLF file and counted 243 splines across the live library where this walk
      # counts 18,906 — an undercount of 78×, which nearly had the SPLINE work scoped as speculative
      # (tinkerex#216). A value line is half a record; count by walking the pairs.
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

      # Walk the pairs, slicing them into entity records keyed by their group codes, and return
      # `[top_level_entities, blocks]` — `blocks` being `name => { base:, entities: }`. Entity
      # types this parser cannot draw are skipped, and `unreadable:` is where their NAMES survive
      # that (see `unreadable?`) — the record itself is dropped, codes and all.
      #
      # THIS WALKS EVERY SECTION AND NOW KNOWS WHICH ONE IT IS IN, AND THAT IS THE HALF OF
      # tinkerex#219 THAT REMOVES BEHAVIOUR RATHER THAN ADDING IT. `tokenize` returns every
      # code/value pair in the file with no section filter at all, so until this method tracked
      # sections a BLOCKS-section entity was collected and yielded as a TOP-LEVEL shape at its
      # DEFINITION coordinates — while the INSERT that places it was not in `ENTITY_TYPES` and was
      # dropped. The net effect was never MISSING geometry: it was geometry in the WRONG PLACE,
      # drawn once however many times the file places it. On `cards.dxf` that was the entire
      # picture — all 8,148 contours live in blocks and its ENTITIES section holds nothing but
      # nine INSERTs. **A test asserting only "the inserted copy appears" passes while the ghost
      # still draws**, which is why the fixture asserts the shape COUNT.
      #
      # THE ONE INSERT-CARRYING FILE KEPT FOR THIS WORK PROVES ONLY THE REMOVAL HALF, and saying so
      # is the difference between evidence and a green run. All 177 of `cards.dxf`'s INSERTs sit at
      # (0, 0) with no scale and no rotation — measured — so its 8,148 contours land on the very
      # same coordinates the ghosts did: same job box, same shapes, a different ORDER (they now
      # arrive through the expansion tree) and 177 fewer entries in the unreadable tally. The
      # placement arithmetic is pinned synthetically in `dxf_geometry_test.rb` because no file here
      # exercises it, and 23 of the corpus's other 24 INSERT files are not in this scratch set.
      #
      # A BLOCK IS COLLECTED ONLY INSIDE A LABELLED `BLOCKS` SECTION, AND THE DIRECTION OF THAT
      # CAUTION IS THE ARGUMENT. Keying on the `BLOCK`/`ENDBLK` markers ALONE would be enough for
      # every real file, but a stray or malformed `BLOCK` in the ENTITIES section would then
      # swallow the rest of the drawing into a definition nobody inserts — §14b's skip-list blind
      # spot, silent and total. Requiring the section label fails the other way: an unlabelled
      # BLOCKS section keeps drawing ghosts, which is exactly what this code did yesterday, and the
      # INSERTs naming those blocks are reported as `INSERT(unknown-block)` rather than dropped. A
      # regression is bounded by the status quo; a data loss is not.
      #
      # THE TABLES AND OBJECTS SECTIONS' RECORDS STILL ARRIVE ON THIS SAME `0`-CODE STREAM, which
      # is what `unreadable?` has to account for — the section tracking exists to place BLOCK
      # bodies, not to filter the walk down to ENTITIES.
      BLOCKS_SECTION = "BLOCKS".freeze

      def parse_document(pairs, unreadable: nil)
        top = []
        blocks = {}
        section = nil
        block = nil    # the block record currently being DEFINED, or nil outside BLOCK/ENDBLK
        pending = nil  # the structural record still absorbing codes: :section or :block
        current = nil  # the drawable entity record still absorbing codes

        pairs.each do |(code, value)|
          if code.zero? # a "0" code starts a new entity (or section marker)
            (block ? block[:entities] : top) << current if current
            current = nil
            pending = nil

            case value
            when "SECTION"
              section = nil
              pending = :section
            when "ENDSEC"
              section = nil
              block = nil
            when "BLOCK"
              block = nil
              pending = :block if section == BLOCKS_SECTION
            when "ENDBLK"
              block = nil
            else
              # VERTEX is captured too (not drawn itself) so old-style POLYLINE can reclaim its
              # points — see fold_polyline_vertices.
              current =
                if ENTITY_TYPES.include?(value) || value == "VERTEX"
                  { type: value, codes: Hash.new { |h, k| h[k] = [] } }
                else
                  unreadable[value] = (unreadable[value] || 0) + 1 if unreadable && unreadable?(value)
                  nil
                end
            end
          elsif pending == :section
            section = value if code == 2
          elsif pending == :block
            # A BLOCK header's `2` is its name and its `10`/`20` its base point. The name arrives
            # before the base point in every dialect, so the record exists by the time one is read;
            # a header with no `2` at all defines nothing and its body falls through to `top`,
            # which is the pre-fix behaviour rather than a silent loss.
            case code
            when 2  then block ||= (blocks[value] ||= { base: [ 0.0, 0.0 ], entities: [] })
            when 10 then block[:base][0] = Float(value, exception: false) || 0.0 if block
            when 20 then block[:base][1] = Float(value, exception: false) || 0.0 if block
            end
          elsif current
            current[:codes][code] << value
          end
        end
        (block ? block[:entities] : top) << current if current

        [ fold_polyline_vertices(top),
          blocks.transform_values { |b| b.merge(entities: fold_polyline_vertices(b[:entities])) } ]
      end

      # THE ENTITIES A DRAWING PLACES DIRECTLY, without the block definitions — `parse_document`'s
      # first half, kept as its own door because that is the whole question `dxf_test.rb` asks and
      # a caller wanting one list should not have to know a second exists.
      def parse_entities(pairs, unreadable: nil) = parse_document(pairs, unreadable:).first

      # Is a `0`-code value an entity type we met and could not draw — as opposed to something
      # that was never geometry in the first place?
      #
      # TWO POPULATIONS ARRIVE ON ONE STREAM, because `parse_document` above tracks sections only
      # far enough to place BLOCK bodies — it narrows the walk to none of them, so every section's
      # records still reach this predicate. `STRUCTURAL` therefore has to cover both: the markers that open and close a section, a
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
      # VERTEX IS NOT HERE BECAUSE IT IS NEVER REACHED — `parse_document` keeps it as a drawable
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
      #
      # A VERTEX'S OWN `42` — ITS BULGE — RIDES ALONG AS AN OPTIONAL THIRD ELEMENT, and that is
      # precisely the property making POLYLINE bulges cheap and LWPOLYLINE bulges unreachable: a
      # VERTEX is a RECORD, so its codes hash answers "this vertex's bulge" with no interleaving to
      # reconstruct (see `bulge_arc`). Kept as the raw group-code string, exactly as x and y are,
      # so `polyline_points` stays the one place that turns a value into a number.
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
            poly[:verts] << [ x, y, e[:codes][42].first ] if x && y
          else
            poly = nil
            out << e
          end
        end
        out
      end

      # THE TYPES `parse_document` KEEPS THE CODES OF. INSERT is the odd one: it draws nothing of
      # its own and never reaches `flatten` — it is here because a record whose codes are dropped
      # cannot be expanded, and `emit_entities` branches on it before the flatten path. Its arrival
      # is also what silences the type-based tally for it, which is why `emit_insert` names every
      # refusal explicitly.
      ENTITY_TYPES = %w[LINE LWPOLYLINE POLYLINE CIRCLE ARC SPLINE INSERT].freeze

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
