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
        doc = Nokogiri::XML(bytes) { |c| c.recover }
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
        doc.xpath("//CutSetting").filter_map do |cs|
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

      # Job size = the shapes' bounding box in mm. Reuses Lbrn2's transform + BBox; extracts each
      # shape's raw points here (small, and keeps Lbrn2's tested SVG path untouched).
      def job_size(doc)
        bbox = Lbrn2::BBox.new
        doc.xpath("//Shape").each do |shape|
          xform = Lbrn2.parse_xform(shape["XForm"])
          points_for(shape).each do |(x, y)|
            px, py = Lbrn2.apply(xform, x, y)
            bbox.add(px, py)
          end
        end
        w, h = bbox.dimensions
        w && { "width" => w.round(1), "height" => h.round(1) }
      end

      def points_for(shape)
        case shape["Type"]
        when "Rect"
          w = Lbrn2.num(shape["W"]); h = Lbrn2.num(shape["H"])
          return [] if w.nil? || h.nil?

          [ [ -w / 2, -h / 2 ], [ w / 2, -h / 2 ], [ w / 2, h / 2 ], [ -w / 2, h / 2 ] ]
        when "Ellipse"
          rx = Lbrn2.num(shape["Rx"]); ry = Lbrn2.num(shape["Ry"])
          return [] if rx.nil? || ry.nil?

          # Sample the perimeter (not just two axis corners) so the bbox is correct even when the
          # XForm rotates the ellipse. 32 is divisible by 4, so an unrotated ellipse's axis extents
          # are still hit exactly (the fixture's circle stays 40x20).
          (0...32).map { |i| t = i * (Math::PI / 16); [ rx * Math.cos(t), ry * Math.sin(t) ] }
        when "Line", "Path"
          Lbrn2.vertices(shape)
        else
          []
        end
      end
    end
  end
end
