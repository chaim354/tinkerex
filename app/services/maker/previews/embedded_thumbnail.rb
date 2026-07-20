require "base64"

module Maker
  module Previews
    # Extracts a raster thumbnail that some XML maker formats embed as a base64-encoded PNG in a
    # `<Thumbnail Source="...">` attribute. LightBurn (`.lbrn2`) and MillMage (`.mage`) both do this
    # — the value is the APP'S OWN rendered preview (full colour, fills, layers, bitmaps), so it
    # beats any geometry re-render we could do from the source. Same idea as the 3MF embedded
    # thumbnail, different container (an XML attribute rather than a zip entry).
    #
    # Returns { bytes:, content_type: "image/png", width:, height: } or nil when there is no usable
    # embedded PNG. Pure Ruby — no toolchain, so a renderer using this is `available?` without resvg.
    module EmbeddedThumbnail
      module_function

      # The base64 alphabet has no `"`, so `[^"]+` safely captures the whole Source value. The tag
      # sits near the top of the file, but a scan of the whole (sub-MB) document is cheap.
      SOURCE = /<\s*Thumbnail\b[^>]*\bSource\s*=\s*"([^"]+)"/i
      PNG_MAGIC = "\x89PNG\r\n\x1A\n".b.freeze

      def extract(xml_bytes)
        text = xml_bytes.b.dup.force_encoding("UTF-8").scrub
        m = SOURCE.match(text)
        return nil if m.nil?

        png = Base64.decode64(m[1]).b
        return nil unless png[0, 8] == PNG_MAGIC

        w, h = png[16, 8].unpack("N2") # PNG IHDR width/height (BE u32), immediately after the sig
        { bytes: png, content_type: "image/png", width: w, height: h }
      end
    end
  end
end
