module Maker
  module Previews
    # The renderer seam: maps a file extension → a renderer object (bytes in → asset out).
    #
    # A renderer is any object responding to:
    #   - available? → Boolean   (is the underlying toolchain present on this box?)
    #   - render(bytes, size:) → { bytes:, content_type:, width:, height: }
    #
    # Phase 1 registers ONLY the SVG renderer (no native dep). Future formats register the
    # exact same way behind their own `available?` capability check — see the TODO block.
    module Registry
      module_function

      # Formats with a renderer OF THEIR OWN. Text files are not listed here — they are derived
      # below and this hash is merged OVER them, so an explicit entry always wins.
      FORMAT_RENDERERS = {
        "svg"   => Maker::Previews::Svg,
        "lbrn2" => Maker::Previews::Lbrn2,   # LightBurn XML → SVG → reuse Svg   (Nokogiri, MIT)
        "lbrn"  => Maker::Previews::Lbrn2,
        "dxf"   => Maker::Previews::Dxf,     # DXF entities → SVG → reuse Svg    (pure Ruby)
        "3mf"   => Maker::Previews::ThreeMf, # extract embedded thumbnail.png    (rubyzip, BSD-2)
        "mage"  => Maker::Previews::Mage,     # MillMage XML → embedded <Thumbnail> base64 PNG
        "stl"   => Maker::Previews::Stl,     # pure-CPU euc rasterizer (no GL/Mesa) — stl-thumbnailer
        "obj"   => Maker::Previews::Mesh,    # F3D headless PNG                  (f3d BSD-3 subprocess)
        "step"  => Maker::Previews::Mesh,    # STEP/IGES via F3D's OCCT plugin — OCCT (LGPL) stays
        "stp"   => Maker::Previews::Mesh,    # process-isolated in the f3d subprocess.
        "iges"  => Maker::Previews::Mesh,
        "igs"   => Maker::Previews::Mesh,
        # Common document/image types → grid thumbnails. (Images already preview inline in the detail
        # view; this gives the GRID a uniform raster too.)
        "png"   => Maker::Previews::ImageThumb, # raster images → downscaled PNG (libvips / ruby-vips, MIT)
        "jpg"   => Maker::Previews::ImageThumb,
        "jpeg"  => Maker::Previews::ImageThumb,
        "gif"   => Maker::Previews::ImageThumb,
        "webp"  => Maker::Previews::ImageThumb,
        "bmp"   => Maker::Previews::ImageThumb,
        "pdf"   => Maker::Previews::Pdf        # page 1 → PNG via pdfium (BSD-3 binary; CLAUDE.md §9)
      }.freeze

      # ext (frozen string) => renderer module/object.
      #
      # TEXT FILES ARE DERIVED, NOT LISTED, AND THAT IS THE WHOLE FIX HERE. This hash carried four
      # hand-written TextThumb entries (txt md markdown json) while `FilesController#preview_kind`
      # had already been collapsed onto the one vocabulary and answered `:text` for 37 extensions.
      # The other 33 — `.rb`, `.py`, `.gcode`, `.yml`, `.csv`, `.scad`, every `.c` and `.h` — got
      # the source viewer on the detail page and NO GRID THUMBNAIL AT ALL, because `Enqueue.call`
      # returns nil for a name no renderer claims. Two tables, one question, and the drift was
      # invisible because each table looked right on its own.
      #
      # THE MERGE DIRECTION IS LOAD-BEARING: FORMAT_RENDERERS goes on TOP, so a text extension that
      # ever gains a renderer of its own keeps it. There is no collision today (checked), and
      # `renderer_contract_test.rb` is what keeps it that way — it asserts every renderer's own
      # EXTENSIONS resolve back through `.for`, so a shadowed TextThumb claim goes RED rather than
      # sitting in TEXT_EXTENSIONS reading as coverage it does not have.
      #
      # ORDER AGAINST `preview_kind` IS NOT AFFECTED. Its `:text` branch returns BEFORE `:thumbnail`,
      # so registering these changes the GRID and never the detail page — the same "the thumbnail is
      # a poster, not a replacement" relationship `:model3d` already has with `stl`/`3mf`/`obj`.
      RENDERERS = Maker::Previews::TextThumb::EXTENSIONS
                    .index_with { Maker::Previews::TextThumb }
                    .merge(FORMAT_RENDERERS)
                    .freeze

      # Resolve by raw extension (case-insensitive, leading dot tolerated). nil if none.
      def for(ext)
        return nil if ext.nil?
        RENDERERS[ext.to_s.downcase.delete_prefix(".")]
      end

      # Resolve from a filename or node path (uses its extension).
      def for_filename(filename)
        self.for(File.extname(filename.to_s))
      end
    end
  end
end
