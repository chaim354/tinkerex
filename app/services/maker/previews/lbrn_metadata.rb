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

        {
          "app_version"     => root["AppVersion"],
          "format_version"  => root["FormatVersion"],
          "machine"         => device_name(root),
          "material_height" => Lbrn2.num(root["MaterialHeight"]),
          "job"             => job_size(doc),
          "shape_count"     => doc.xpath("//Shape").length,
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
            "color"     => (c = val(cs, "color")) && Lbrn2.normalize_color(c),
            "mode"      => mode(cs["type"]),
            "speed"     => Lbrn2.num(val(cs, "speed")),
            "power_max" => Lbrn2.num(val(cs, "maxPower")),
            "power_min" => Lbrn2.num(val(cs, "minPower")),
            "passes"    => (p = Lbrn2.num(val(cs, "numPasses"))) && p.to_i
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

      # Job size = the shapes' bounding box in mm.
      #
      # Runs THE SAME traversal the thumbnail does (`Lbrn2.each_geometry`) rather than a private
      # second copy. The copy this replaced is exactly why the two could disagree: it re-derived
      # per-shape points and so inherited every dialect bug independently — a file could render
      # one way and report a size computed from different geometry, with nothing to catch it.
      def job_size(doc)
        bbox = Lbrn2::BBox.new
        Lbrn2.each_geometry(doc) { |_cut, points, _closed, _ellipse| points.each { |(x, y)| bbox.add(x, y) } }
        w, h = bbox.dimensions
        w && { "width" => w.round(1), "height" => h.round(1) }
      end
    end
  end
end
