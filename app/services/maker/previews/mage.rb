module Maker
  module Previews
    # MillMage (`.mage`) → thumbnail PNG + a parsed CNC "recipe".
    #
    # `.mage` is MillMage's CNC project format (`<MillMageProject>` XML — the LowRider / MPCNC
    # toolchain). Like LightBurn it embeds its own rendered preview as a base64 PNG in a
    # `<Thumbnail Source="...">` attribute, and that is still preferred: it is the app's own
    # full-colour render, and every real file carries one.
    #
    # THE GEOMETRY DIALECT IS LIGHTBURN'S, so `Lbrn2`'s walker is reused verbatim rather than
    # copied. This file used to assert the opposite — "MillMage's toolpath model is a different,
    # larger parse than LightBurn's" — and that claim was simply wrong. Measured on a real 0.8.01
    # export (catan5-21-26-v1.mage, 62 shapes): `<XForm>` as a child element 62 times and as an
    # attribute 0, real-style `V<x> <y>c0x..` vert lists 59 and old-style 0, plus VertID/PrimID
    # instancing and L/B/LineClosed prims — the same four things `Lbrn2` was rewritten for.
    # Rendering it through that walker reproduces MillMage's own embedded thumbnail. The cost of
    # the wrong claim was that a .mage had no job size, no settings panel, and no preview at all
    # when it happened to lack a thumbnail.
    #
    # What genuinely differs is everything AROUND the geometry — `OpIndex`/`LayerIndex` instead of
    # `CutIndex`, and `<Operation>`/`<ToolDef>` instead of `<CutSetting>` — which is why the
    # recipe lives in its own `MageMetadata` rather than a branch of `LbrnMetadata`.
    module Mage
      module_function

      NoThumbnail = Class.new(StandardError)

      EXTENSIONS = %w[mage].freeze

      # STILL unconditionally true, and deliberately NOT `Svg.available?` the way Lbrn2's is. The
      # embedded-thumbnail path needs no toolchain and is the path every real file takes, so
      # gating the whole renderer on resvg would forfeit a guarantee this renderer already makes
      # — and buy nothing, since a box without resvg is exactly where the fallback cannot run.
      def available? = true

      # Which build of this renderer produced a stored artifact — see `Enqueue.revision_for`.
      #
      # PER KIND, NOT PER RENDERER, for the same reason as Lbrn2's: this renderer emits two
      # unrelated artifacts from one file and they version independently, so bumping the geometry
      # payload must not re-render every MillMage thumbnail as a side effect.
      #
      # The geometry arm DELEGATES to LbrnGeometry's number rather than declaring one of its own,
      # because it delegates the payload itself — a .mage payload is byte-for-byte whatever that
      # module builds. A second constant here would be free to drift from the code that actually
      # produces the bytes it claims to version, which is the failure this whole mechanism exists
      # to prevent.
      #
      #   1  original (thumbnail)
      #   2  multi-page files (MillMage 0.9): pages and per-page sizes in the panel, and the outline
      #      fallback draws the saved page alone — see Lbrn2.pages
      THUMBNAIL_REVISION = 2

      def payload_revision(kind)
        kind == "geometry" ? Maker::Previews::LbrnGeometry::PAYLOAD_REVISION : THUMBNAIL_REVISION
      end

      # `kind` selects the ARTIFACT, mirroring Lbrn2's branch. "geometry" is a JSON payload of
      # coordinates for the browser's Measure view — deliberately NOT an image, which is why
      # RendererContractTest still passes: that test never passes `kind`, so it exercises the
      # thumbnail path and its "must be an inline-safe raster" assertion stays true of it.
      #
      # NO `available_for?` HERE, unlike Svg/Dxf/Lbrn2, and the absence is the point: `available?`
      # is already unconditionally true for this renderer (the embedded-PNG path needs no
      # toolchain), so there is nothing for a kind-aware override to relax. The SVG FALLBACK is
      # the only part that needs resvg and it checks for itself, in `outline_thumbnail` below.
      def render(mage_bytes, size: 512, kind: "thumbnail")
        return Maker::Previews::LbrnGeometry.render(mage_bytes) if kind == "geometry"

        meta = Maker::Previews::MageMetadata.parse(mage_bytes)
        img = Maker::Previews::EmbeddedThumbnail.extract(mage_bytes) || outline_thumbnail(mage_bytes, size:)
        img.merge(metadata: meta)
      end

      # The fallback IS the SVG path, so where resvg is absent this stays the terminal
      # `NoThumbnail` it has always been, rather than raising something else the job would have
      # to classify.
      #
      # NAMED FOR WHAT IT PRODUCES (a raster of the outlines), not for what it reads. It was
      # `geometry` until `render` grew a `kind: "geometry"` arm that returns something else
      # entirely — a JSON coordinate payload — and two things called "geometry" in one file, one
      # of them a PNG, is how the wrong one gets called.
      def outline_thumbnail(mage_bytes, size:)
        raise NoThumbnail, "MillMage file has no embedded thumbnail" unless Maker::Previews::Svg.available?

        Maker::Previews::Svg.render(Maker::Previews::Lbrn2.to_svg(mage_bytes, size:), size:)
      end
    end
  end
end
