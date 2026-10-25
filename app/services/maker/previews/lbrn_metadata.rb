require "nokogiri"
require "set"

module Maker
  module Previews
    # LightBurn (.lbrn/.lbrn2) XML -> a structured "recipe" Hash for the file page's Laser
    # Settings panel: per-layer speed/power/passes/mode/colour + job size, machine, text, counts.
    #
    # Best-effort and NON-throwing: parse returns nil for a non-LightBurn or malformed document,
    # and omits any field it can't read, so it can never turn a renderable file into a failed
    # preview. Reuses Lbrn2's colour/geometry helpers (DRY) rather than re-deriving them.
    module LbrnMetadata
      module_function

      # Nokogiri returns strings; keep keys as strings so the Hash round-trips a JSON column.
      def parse(bytes)
        doc = Lbrn2.parse_document(bytes)
        root = doc.root
        return nil if root.nil? || root.name != "LightBurnProject"

        used = doc.xpath("//Shape").filter_map { |s| s["CutIndex"] }.to_set
        job, pages = Lbrn2.page_metadata(doc)

        {
          "app_version"     => root["AppVersion"],
          "format_version"  => root["FormatVersion"],
          "machine"         => device_name(root),
          "material_height" => Lbrn2.num(root["MaterialHeight"]),
          "job"             => job,
          "pages"           => pages,
          "shape_count"     => Lbrn2.shape_count(doc),
          "text"            => text_strings(doc).presence,
          "layers"          => layers(doc, used).presence
        }.compact.presence
      rescue StandardError
        nil
      end

      def layers(doc, used)
        Lbrn2.cut_settings(doc).filter_map do |cs|
          idx = val(cs, "index")
          next if idx.nil? || !used.include?(idx.to_s)

          {
            "index"     => idx.to_s,
            "name"      => val(cs, "name"),
            # The file's own colour if it has one, else LightBurn's built-in palette for this
            # index — which is the ordinary case, since no real export writes <color> at all.
            # Without the fallback the panel's swatch was invisible on every real file.
            "color"     => (c = val(cs, "color")).present? ? Lbrn2.normalize_color(c) : Lbrn2.layer_color(idx),
            # The colour's name, for a panel that would otherwise label every layer "C01". Carried
            # SEPARATELY from "name" rather than substituted into it, because the two answer
            # different questions and only the view knows which it wants — the raw file name still
            # has to be available to anything that cares what LightBurn actually wrote.
            #
            # ONLY WHEN THE COLOUR CAME FROM THE PALETTE. A file may override a layer's colour, and
            # `Lbrn2.layer_name` names the PALETTE entry for that index — so on a file that recolours
            # C01 to green, naming it anyway would print "Blue" beside a green swatch: a label
            # contradicting the very thing it labels. No name is better than a wrong one; the view
            # falls back to the index.
            "color_name" => (c.present? ? nil : Lbrn2.layer_name(idx)),
            "mode"      => mode(cs["type"]),
            "speed"     => Lbrn2.num(val(cs, "speed")),
            "power_max" => Lbrn2.num(val(cs, "maxPower")),
            "power_min" => Lbrn2.num(val(cs, "minPower")),
            # AN ABSENT `numPasses` MEANS ONE PASS, NOT "UNKNOWN" — LightBurn writes only values
            # that differ from its defaults. Measured over the 58 real exports: 135 CutSetting
            # blocks, and just 5 carry the field, every one of them saying 4. Everything else runs
            # a single pass and says nothing about it.
            #
            # Reporting nil rendered an EMPTY Passes cell on almost every layer of every real file,
            # which reads as "we could not parse this" for a number the file states perfectly
            # clearly by omission. Note `.compact` below, which is why nil vanished silently rather
            # than showing up as an obvious hole: the key was dropped from the hash entirely.
            #
            # Deliberately NOT extended to the other sometimes-absent fields. `minPower` (6 of 135)
            # has no such flat default — it tracks maxPower unless a layer uses power ramping — and
            # the panel already handles its absence correctly by showing one power figure instead
            # of two. Guessing a value there would invent data; here it recovers a stated one.
            "passes"    => (p = Lbrn2.num(val(cs, "numPasses"))) ? p.to_i : 1
          }.compact
        end.sort_by { |l| l["index"].to_i }
      end

      # LightBurn 'Scan' is labelled 'Fill' in the UI; 'Cut'/'Image' pass through. Unknown -> nil.
      def mode(type)
        case type
        when "Cut"   then "Cut"
        when "Scan"  then "Fill"
        when "Image" then "Image"
        else type.presence
        end
      end

      # A value stored either as an attribute (cs["speed"]) or a child (<speed Value="..">/<speed>text).
      # Mirrors Lbrn2#cut_colors so both real-export forms parse.
      def val(node, key)
        node[key].presence || node.at_xpath(key)&.[]("Value").presence || node.at_xpath(key)&.text.presence
      end

      def device_name(root)
        root["DeviceName"] ||
          root.at_xpath(".//DeviceName")&.[]("Value") ||
          root.at_xpath(".//DeviceName")&.text.presence
      end

      def text_strings(doc)
        doc.xpath("//Shape[@Type='Text']").filter_map do |s|
          (s["Str"] || s.at_xpath("Str")&.[]("Value") || s.at_xpath("Str")&.text).to_s.strip.presence
        end
      end

      # Job size = the shapes' bounding box in mm, measured by the SAME walk that draws the
      # thumbnail (`Lbrn2.page_metadata`, over `each_geometry`) rather than a private second copy.
      # The copy this replaced is exactly why the two could disagree: it re-derived per-shape
      # points and so inherited every dialect bug independently — a file could render one way and
      # report a size computed from different geometry, with nothing to catch it. On a multi-page
      # file it is the SAVED page's size, the page the thumbnail beside the panel pictures.
    end
  end
end
