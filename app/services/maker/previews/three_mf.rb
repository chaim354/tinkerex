require "zip"

module Maker
  module Previews
    # 3MF (`.3mf`) → thumbnail PNG.
    #
    # A 3MF file is an OPC/zip container. The spec lets it embed a 2D thumbnail (PNG/JPEG),
    # and most slicer-exported files (PrusaSlicer/Bambu/Cura) already carry one — so the
    # cheapest, render-free preview is to EXTRACT the embedded PNG. We look for it in the
    # common slicer location (`Metadata/thumbnail.png`) and, failing that, resolve the OPC
    # thumbnail relationship / scan for any PNG under `Metadata/` or `3D/`.
    #
    # Pure-Ruby (rubyzip, BSD-2 — CLAUDE.md §9). No external binary, so `available?` is always
    # true. When no embedded thumbnail exists we raise NoThumbnail (a real render via F3D is the
    # later fallback, Mesh); the job turns that into status `failed`.
    #
    # See docs/research-format-processing.md §2.
    module ThreeMf
      module_function

      NoThumbnail = Class.new(StandardError)

      EXTENSIONS = %w[3mf].freeze

      # Slicer convention first, then anything PNG-ish under the metadata/asset dirs.
      PREFERRED_PATHS = %w[Metadata/thumbnail.png Metadata/thumbnail.jpg].freeze

      # Pure-Ruby zip read → no native toolchain to gate on.
      def available? = true

      # Returns { bytes:, content_type:, width:, height: }. The embedded image is returned
      # verbatim (already a web-renderable PNG/JPEG); width/height come from the PNG/JPEG header
      # when cheaply parseable, else nil. Raises NoThumbnail if the container has no thumbnail.
      def render(threemf_bytes, size: 512)
        path, bytes = extract_thumbnail(threemf_bytes)
        if bytes
          content_type = path.end_with?(".jpg", ".jpeg") ? "image/jpeg" : "image/png"
          w, h = png_dimensions(bytes)
          return { bytes: bytes.b, content_type:, width: w, height: h }
        end

        # No embedded slicer thumbnail (most CAD-exported 3MFs — Shapr3D, Onshape, Fusion — have
        # none). Render the MESH itself, GL-free, by converting it to a binary STL and reusing the
        # deployed STL thumbnailer. Raises NoThumbnail only when there is neither a thumbnail nor a
        # readable mesh.
        stl = mesh_to_stl(threemf_bytes)
        raise NoThumbnail, "3MF has no embedded thumbnail and no readable mesh" if stl.nil?

        Maker::Previews::Stl.render(stl, size:)
      end

      # → [path, bytes] of the chosen embedded thumbnail, or [nil, nil].
      def extract_thumbnail(threemf_bytes)
        Zip::File.open_buffer(StringIO.new(threemf_bytes.b)) do |zip|
          entry = pick_entry(zip)
          return [ nil, nil ] if entry.nil?
          return [ entry.name, entry.get_input_stream.read ]
        end
      rescue Zip::Error => e
        raise NoThumbnail, "3MF is not a readable zip: #{e.message}"
      end

      # Prefer the slicer-standard path; then the OPC-declared thumbnail relationship target;
      # then any PNG/JPEG under Metadata/ or 3D/ (case-insensitive on the extension).
      def pick_entry(zip)
        names = zip.entries.map(&:name)

        PREFERRED_PATHS.each do |p|
          hit = names.find { |n| n.casecmp?(p) }
          return zip.find_entry(hit) if hit
        end

        rel_target = thumbnail_from_rels(zip)
        return zip.find_entry(rel_target) if rel_target && names.include?(rel_target)

        fallback = names.find do |n|
          n =~ %r{\A(Metadata|3D)/.*\.(png|jpe?g)\z}i
        end
        fallback ? zip.find_entry(fallback) : nil
      end

      # OPC relationships declare the package thumbnail via a Thumbnail relationship type in
      # `_rels/.rels`. Resolve its Target (root-relative) so we honor spec-correct placement,
      # not just the slicer convention. Best-effort; nil on any parse miss.
      def thumbnail_from_rels(zip)
        rels = zip.find_entry("_rels/.rels")
        return nil if rels.nil?

        doc = Nokogiri::XML(rels.get_input_stream.read)
        doc.remove_namespaces!
        node = doc.xpath("//Relationship").find do |r|
          r["Type"].to_s.downcase.end_with?("thumbnail")
        end
        return nil if node.nil?

        target = node["Target"].to_s
        target.delete_prefix("/")
      rescue StandardError
        nil
      end

      # --- Mesh fallback: 3MF geometry -> binary STL -> the GL-free STL thumbnailer -----------
      #
      # A 3MF is an OPC/zip whose `3D/*.model` is XML carrying <vertices>/<triangles>. We deref the
      # triangle indices into vertex coordinates and write a binary STL, then hand it to the same
      # `stl-thumbnailer` the STL renderer uses — no GPU/OpenGL, no F3D. Multiple meshes are all
      # emitted (indices are dereferenced per-mesh, so concatenation is safe); build-item transforms
      # are ignored — good enough for a single-object thumbnail, which is the common case.

      # -> binary STL bytes, or nil when there is no usable mesh.
      def mesh_to_stl(threemf_bytes)
        facets = []
        Zip::File.open_buffer(StringIO.new(threemf_bytes.b)) do |zip|
          zip.entries.select { |e| e.name =~ /\.model\z/i }.each do |entry|
            collect_facets(entry.get_input_stream.read, facets)
          end
        end
        return nil if facets.empty?

        build_binary_stl(facets)
      rescue Zip::Error
        nil
      end

      def collect_facets(model_xml, facets)
        doc = Nokogiri::XML(model_xml)
        doc.remove_namespaces!
        doc.xpath("//mesh").each do |mesh|
          verts = mesh.xpath("./vertices/vertex").map { |v| [ v["x"].to_f, v["y"].to_f, v["z"].to_f ] }
          mesh.xpath("./triangles/triangle").each do |t|
            a = verts[t["v1"].to_i]; b = verts[t["v2"].to_i]; c = verts[t["v3"].to_i]
            facets << [ a, b, c ] if a && b && c
          end
        end
      end

      # Binary STL: 80-byte header, uint32 LE triangle count, then per triangle a normal + 3
      # vertices (12 LE float32) + a uint16 attribute-byte-count.
      def build_binary_stl(facets)
        io = StringIO.new.tap(&:binmode)
        io.write("\x00".b * 80)
        io.write([ facets.size ].pack("V"))
        facets.each do |(a, b, c)|
          io.write((triangle_normal(a, b, c) + a + b + c).pack("e12"))
          io.write([ 0 ].pack("v"))
        end
        io.string
      end

      def triangle_normal(a, b, c)
        ux, uy, uz = b[0] - a[0], b[1] - a[1], b[2] - a[2]
        vx, vy, vz = c[0] - a[0], c[1] - a[1], c[2] - a[2]
        nx = (uy * vz) - (uz * vy)
        ny = (uz * vx) - (ux * vz)
        nz = (ux * vy) - (uy * vx)
        len = Math.sqrt((nx * nx) + (ny * ny) + (nz * nz))
        len.zero? ? [ 0.0, 0.0, 0.0 ] : [ nx / len, ny / len, nz / len ]
      end

      # Cheap PNG/JPEG header sniff for natural dimensions; nil when not a PNG IHDR.
      def png_dimensions(bytes)
        head = bytes.b
        return [ nil, nil ] unless head[0, 8] == "\x89PNG\r\n\x1A\n".b

        # IHDR is the first chunk: 8-byte sig, 4-byte length, "IHDR", then width/height (BE u32).
        w, h = head[16, 8].unpack("N2")
        [ w, h ]
      rescue StandardError
        [ nil, nil ]
      end
    end
  end
end
