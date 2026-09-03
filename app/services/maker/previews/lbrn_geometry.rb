module Maker
  module Previews
    # LightBurn (.lbrn/.lbrn2) and MillMage (.mage) -> the Measure view's geometry payload.
    #
    # This is the SECOND artifact derived from one project file, alongside the thumbnail: same
    # file, same traversal, different shape. It exists because a measuring client needs coordinates
    # and the thumbnail is a PNG — the app's own embedded render, which has no mapping back to mm.
    #
    # ONE MODULE FOR BOTH FORMATS BECAUSE THEY SHARE A GEOMETRY DIALECT, which is the same reason
    # `Mage` renders through `Lbrn2.to_svg`. Measured on a real 0.8.01 export: `<XForm>` as a child
    # element, real-style vert lists, VertID/PrimID instancing and L/B/LineClosed prims — the same
    # four things `Lbrn2` was rewritten for. What differs is everything AROUND the geometry, and
    # for this payload that is exactly one thing: where a layer's colour comes from (see `colors_for`).
    #
    # BUILT ON `Lbrn2.each_geometry`, NEVER ON A PRIVATE WALK. That is CLAUDE.md's one-traversal
    # rule and it is not stylistic: `LbrnMetadata` once kept a second copy of this traversal and
    # independently inherited every dialect bug the parser had, so a file could render one way and
    # report a size computed from different geometry with nothing to catch it. The test asserting
    # this payload's bboxes union to `Lbrn2.job_size` is what keeps the two tied together.
    #
    # THE PAYLOAD'S SHAPE LIVES IN `Geometry`, not here — see that module. This file is the
    # LightBurn/MillMage traversal and nothing else.
    module LbrnGeometry
      module_function

      # WHICH BUILD OF *THIS FILE* PRODUCED A STORED PAYLOAD. Bump on ANY change here that alters
      # the output, whether or not the schema moves: `Maker::Previews::Enqueue` compares
      # PAYLOAD_REVISION below against `maker_previews.renderer_revision` and re-renders whatever
      # no longer matches. A CHANGE IN `Geometry` IS NOT ONE OF THESE — that file carries its own
      # term, and bumping this one for a shared change leaves .dxf and .svg stale forever.
      #
      # THIS IS THE ONE TO BUMP, and `Geometry::SCHEMA_VERSION` is the easy thing to reach for
      # instead. They answer different questions — the schema says whether the CLIENT can parse a
      # payload, this says whether the SERVER should still be serving one. Revision 2 changed every
      # coordinate while touching no key at all: a schema bump would have been wrong (shipped
      # clients read it fine), and having neither is what left four already-measured files serving
      # mangled curves after the fix deployed, until they were found and destroyed by hand.
      #
      #   1  index-stride thinning — mangled any contour mixing straight and curved edges
      #   2  error-bounded simplification against SIMPLIFY_TOLERANCE
      #   3  carries per-layer colours so the Measure view draws in LightBurn's palette
      #   4  a MillMage shape's layer reads from OpIndex, so .mage shapes stop reporting layer nil
      #   5  a bezier contour carries the `"p"` descriptor — the cubics the file itself wrote,
      #      where every curve used to reach the client as a run of short chords. NOT a shared
      #      bump, though the wire form is `Geometry.path_curve`'s: see `Geometry::SHARED_REVISION`,
      #      which spells out why an ADDITIVE helper is versioned by its callers and not by the
      #      file it lives in.
      FORMAT_REVISION = 5

      # What `Enqueue` actually reads. The shared term is added rather than remembered — see
      # `Geometry::SHARED_REVISION`. Mage delegates to THIS constant, so .mage moves with it too.
      PAYLOAD_REVISION = Geometry::SHARED_REVISION + FORMAT_REVISION

      # Returns { bytes:, content_type: } — the shape GeneratePreviewJob attaches.
      def render(bytes)
        Geometry.encode(build(Lbrn2.parse_document(bytes)))
      end

      def build(doc)
        # A rootless document means parse_document could not make sense of the bytes at all — the
        # SAME condition Lbrn2.to_svg raises ParseError for, and this artifact must match it.
        # Without this check, each_geometry's own `return if doc.root.nil?` yields nothing,
        # silently, and the method below returns the ordinary empty-payload shape — turning a
        # corrupt upload into a READY Measure view claiming "No measurable geometry in this file"
        # instead of a failed preview: a lie about the file. A document that DOES have a root but
        # genuinely contains no shapes is a DIFFERENT, honest case — it reaches that same empty
        # payload by actually walking a real (if sparse) document, and the client has a message
        # for it. Keep the two distinct; do not collapse an empty project into a parse failure.
        raise Lbrn2::ParseError, "not a LightBurn project" if doc.root.nil?

        Geometry.build(colors: colors_for(doc)) do |out|
          # `ellipse` IS ALREADY IN CLIENT SPACE and needs no conversion, unlike DxfGeometry's.
          # `Lbrn2.each_geometry` yields points with the composed affine and the Y-flip already
          # applied, and `Lbrn2.ellipse_from` derives the descriptor from those same points — so
          # adding a transform here would apply the flip twice. `Lbrn2` also suppresses the
          # descriptor for a rotated XForm (`axis_aligned?`), which is what keeps a rotated ellipse
          # a polygon rather than an upright ellipse the file does not contain.
          #
          # ONE DESCRIPTOR PER CONTOUR, AND THE `||` IS UNAMBIGUOUS RATHER THAN A PRIORITY.
          # `each_geometry` produces the two from different arms of one case — an <Ellipse> yields
          # an ellipse and no segments, a <Path> yields segments and no ellipse — so there is no
          # shape for which this chooses. It is written as a fallthrough anyway because a THIRD
          # form arriving with an ordering question would then have to answer it here, where the
          # comment is, rather than silently in whichever arm ran last.
          Lbrn2.each_geometry(doc) do |cut, points, closed, ellipse, image, object_id, segments|
            out.add(layer: cut, points:, closed:, image: !image.nil?, object_id:,
                    curve: (ellipse && Geometry.ellipse_curve(*ellipse)) ||
                           (segments && Geometry.path_curve(segments)))
          end
        end
      end

      # THE ONE PLACE THE TWO FORMATS DIVERGE, and the divergence is a refusal.
      #
      # A LightBurn layer's colour comes from the file's own `<CutSetting>` where it has one, else
      # from `LAYER_PALETTE` — a table whose values were RECOVERED from the embedded thumbnails of
      # 58 real exports, which is what makes hard-coding them defensible at all.
      #
      # MILLMAGE GETS NO COLOURS, deliberately, and reusing LightBurn's palette here would be the
      # exact mistake §14h already names in the other direction: `Lbrn2.layer_name` returns nil for
      # a file-supplied colour because printing "Blue" beside a green swatch is a label
      # contradicting the thing it labels. MillMage is a DIFFERENT APPLICATION with its own layer
      # bar; we have no measurements of it and its `<Operation>` elements carry no colour field, so
      # painting OpIndex 2 in LightBurn's red would be a claim about MillMage that nothing supports.
      # The client falls back to black, which claims nothing. Colour here is cosmetic by
      # construction — nothing measures or decides anything from it — so the cost of refusing is a
      # monochrome drawing, and the cost of guessing is a drawing that lies.
      #
      # Detected by the ROOT ELEMENT rather than the file extension, because this module is handed
      # a parsed document and the extension is three frames up. `cut_colors` walking up empty on a
      # MillMage file would reach the same answer by accident today; asking outright means a future
      # MillMage that DOES emit `<CutSetting>`-shaped elements cannot silently acquire LightBurn's
      # palette.
      def colors_for(doc)
        return nil if doc.root&.name == "MillMageProject"

        lambda do |layers|
          # `cut_colors` is resolved ONCE, not per layer: it walks every CutSetting element, so
          # calling it inside the map would re-walk them for each distinct layer in the file.
          from_file = Lbrn2.cut_colors(doc)
          layers.to_h { |cut| [ cut, from_file[cut] || Lbrn2.layer_color(cut) ] }
        end
      end
    end
  end
end
