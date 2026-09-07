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
        "step"  => Maker::Previews::Mesh,    # STEP/IGES/BREP via F3D's OCCT plugin — OCCT (LGPL)
        "stp"   => Maker::Previews::Mesh,    # stays process-isolated in the f3d subprocess.
        "iges"  => Maker::Previews::Mesh,
        "igs"   => Maker::Previews::Mesh,
        "brep"  => Maker::Previews::Mesh,
        # THE MESH FORMATS THE BROWSER VIEWER GAINED ON 2026-09-06, given the SERVER thumbnail that
        # is its poster and its grid cell. Every one was read off `f3d --list-readers` on the
        # shipped 3.5.0 rather than assumed: gltf/glb/ply/wrl/3ds are native readers, off/dae/fbx
        # come from the assimp plugin, brep from occt.
        #
        # THE VIEWER'S LIST IS LONGER THAN THIS ONE, DELIBERATELY. `Maker::FileAttachment::
        # VIEWABLE_3D_EXTS` also holds `3dm`, `amf` and `fcstd`, which F3D 3.5.0 lists NO reader
        # for — they open in the browser and show the "Generating preview…"/no-thumbnail path in
        # the grid, which is the honest answer. Registering them here would create a row and a job
        # for a render that can only ever fail. `3mf` is absent for the opposite reason: it already
        # has a BETTER renderer (ThreeMf pulls the slicer's own embedded thumbnail).
        "gltf"  => Maker::Previews::Mesh,
        "glb"   => Maker::Previews::Mesh,
        "ply"   => Maker::Previews::Mesh,
        "off"   => Maker::Previews::Mesh,
        "dae"   => Maker::Previews::Mesh,
        "wrl"   => Maker::Previews::Mesh,
        "3ds"   => Maker::Previews::Mesh,
        "fbx"   => Maker::Previews::Mesh,
        # Common document/image types → grid thumbnails. (Images already preview inline in the detail
        # view; this gives the GRID a uniform raster too.)
        "png"   => Maker::Previews::ImageThumb, # raster images → downscaled PNG (libvips / ruby-vips, MIT)
        "jpg"   => Maker::Previews::ImageThumb,
        "jpeg"  => Maker::Previews::ImageThumb,
        "gif"   => Maker::Previews::ImageThumb,
        "webp"  => Maker::Previews::ImageThumb,
        "bmp"   => Maker::Previews::ImageThumb,
        "pdf"   => Maker::Previews::Pdf,       # page 1 → PNG via pdfium (BSD-3 binary; CLAUDE.md §9)
        # An Illustrator file, when Illustrator wrote it as a PDF — the renderer decides by reading
        # the first five bytes and answers the job's terminal `unsupported` when they are not
        # `%PDF-` (stage 4, S4-2). This is the SECOND renderer whose claim a read can retract, the
        # first being GerberZip; both are registered by NAME and refuse by CONTENT.
        "ai"    => Maker::Previews::Pdf,
        # GERBER: tracespace under node (tools/gerber-svg), the SAME pinned bundle the browser's
        # viewer runs, so the tile and the viewer are one picture. DERIVED FROM THE `pcb` ROLE and
        # never listed twice — Gerber::EXTENSIONS is `ROLE_BY_EXT`'s pcb keys minus `gbrjob`, whose
        # picture would need the siblings a renderer handed one file's bytes can never reach.
        **Maker::Previews::Gerber::EXTENSIONS.index_with { Maker::Previews::Gerber },
        # A ZIPPED EXPORT IS A BOARD (files-preview.md) and this is one of the TWO renderers whose
        # claim is decided by CONTENT rather than name — `.ai` above is the other, and it read as
        # "the one" until stage 4, S4-2 added it. A Gerber zip renders its top side, and any other
        # zip terminates `unsupported` after one bounded read. Every zip therefore gets a preview
        # row, which is the stated price of a thumbnail on the artefact a fab house is handed.
        "zip"   => Maker::Previews::GerberZip
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

      # Resolve from a filename or node path.
      #
      # EXTENSION FIRST, THEN THE EXTENSIONLESS-TEXT BASENAMES. `File.extname("LICENSE")` is `""`
      # and so is `File.extname(".gitignore")`, so an extension lookup can NEVER reach those files
      # — they resolved to nil, which `Enqueue.call` reads as "no renderer, do not create a row",
      # and a row that never exists is what left a poll cell spinning with nothing to resolve it.
      # `Maker::FileAttachment::TEXT_BASENAMES` is the one place that set is written down; this
      # asks it rather than carrying a second copy.
      #
      # `self.for` IS DELIBERATELY NOT GIVEN THE SAME FALLBACK. It takes a raw EXTENSION — callers
      # pass `"stl"`, and `preview_kind` passes the extension it already split off — so teaching it
      # to also accept `"LICENSE"` would make one method answer two questions, and a caller holding
      # a genuine extension could match a basename by coincidence. The filename door is the one
      # that holds a filename.
      def for_filename(filename)
        self.for(File.extname(filename.to_s)) || text_by_basename(filename)
      end

      def text_by_basename(filename)
        return nil unless Maker::FileAttachment::TEXT_BASENAMES.include?(File.basename(filename.to_s).downcase)

        Maker::Previews::TextThumb
      end
    end
  end
end
