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
        "stl"   => Maker::Previews::Mesh,    # F3D headless PNG                  (f3d BSD-3 subprocess)
        "obj"   => Maker::Previews::Mesh,
        "step"  => Maker::Previews::Mesh,    # STEP/IGES via F3D's OCCT plugin — OCCT (LGPL) stays
        "stp"   => Maker::Previews::Mesh,    # process-isolated in the f3d subprocess.
        "iges"  => Maker::Previews::Mesh,
        "igs"   => Maker::Previews::Mesh
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
