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

      # ext (frozen string) => renderer module/object.
      RENDERERS = {
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
        "pdf"   => Maker::Previews::Pdf       # page 1 → PNG via pdfium (BSD-3 binary; CLAUDE.md §9)
      }.freeze

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
