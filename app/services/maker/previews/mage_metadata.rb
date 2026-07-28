require "nokogiri"

module Maker
  module Previews
    # MillMage (`.mage`) XML -> a structured "recipe" Hash for the file page's CNC panel:
    # per-operation tool/feeds/speeds/depths + job size, machine, counts.
    #
    # The sibling of `LbrnMetadata`, and deliberately a SEPARATE module rather than a branch
    # inside it: the two formats share a geometry dialect but nothing else. LightBurn has layers
    # with speed/power/passes; MillMage has operations with an endmill, feed and plunge rates, a
    # spindle speed, and a pass/final depth. Merging them would mean a Hash where half the keys
    # are always nil and a view that has to guess which half it is holding.
    #
    # Best-effort and NON-throwing, same contract as LbrnMetadata: returns nil for a non-MillMage
    # or malformed document and omits any field it cannot read, so it can never turn a renderable
    # file into a failed preview.
    module MageMetadata
      module_function

      # Nokogiri returns strings; keep keys as strings so the Hash round-trips a JSON column.
      def parse(bytes)
        doc = Lbrn2.parse_document(bytes)
        root = doc.root
        return nil if root.nil? || root.name != "MillMageProject"

        {
          "app_version"     => root["AppVersion"],
          "format_version"  => root["FormatVersion"],
          "machine"         => root["DeviceName"].presence,
          "material_height" => Lbrn2.num(root["MaterialHeight"]),
          "job"             => Lbrn2.job_size(doc),
          "shape_count"     => doc.xpath("//Shape").length,
          "operations"      => operations(doc).presence
        }.compact.presence
      rescue StandardError
        nil
      end

      def operations(doc)
        doc.xpath("//Operation").map do |op|
          tool = op.at_xpath("./ToolDef")
          {
            "type"          => op["type"].presence,
            "name"          => val(op, "name") || op["type"].presence,
            "tool"          => tool && val(tool, "name"),
            "tool_type"     => tool && val(tool, "type"),
            "tool_diameter" => num(effective(op, tool, "diameter")),
            "flutes"        => (f = num(effective(op, tool, "fluteCount"))) && f.to_i,
            "feed_rate"     => num(effective(op, tool, "feedRate")),
            "plunge_rate"   => num(effective(op, tool, "plungeRate")),
            "spindle_speed" => num(effective(op, tool, "spindleSpeed")),
            "pass_depth"    => num(effective(op, tool, "passDepth")),
            "step_over"     => num(effective(op, tool, "stepOver")),
            # Operation-only: how deep the job actually goes. No LightBurn analogue, and with
            # pass_depth it is what says how many passes this operation takes.
            "final_depth"   => num(val(op, "finalDepth"))
          }.compact
        end
      end

      # THE OPERATION WINS, the ToolDef is only the fallback — and the difference is not cosmetic.
      # A ToolDef is a reusable library entry carrying the tool's defaults; the Operation carries
      # what THIS job will actually run. MillMage writes both, and they disagree in real files
      # (observed: tool feedRate 14.8000001907348633 vs operation 14.8). Read the ToolDef first
      # and the panel confidently shows a number the machine is not going to use.
      def effective(op, tool, key)
        val(op, key) || (tool && val(tool, key))
      end

      # A value stored either as an attribute or as a child (<key Value=".."/> or <key>text).
      # `at_xpath(key)` is the CHILD axis, so an Operation lookup cannot accidentally reach into
      # its own <ToolDef> — which is what makes `effective` above a real precedence rule.
      def val(node, key)
        node[key].presence || node.at_xpath(key)&.[]("Value").presence || node.at_xpath(key)&.text.presence
      end

      # Rounded, unlike Lbrn2's. MillMage writes tool values at full float precision — a 1/8"
      # endmill is stored as `3.1749999523162842` and a 60% stepover as `0.6000000238418579` —
      # so an unrounded value puts sixteen digits of binary noise in the panel and in the JSON
      # column. 3dp keeps every real distinction (0.001 mm is far below any mill's resolution).
      def num(str) = (v = Lbrn2.num(str)) && v.round(3)
    end
  end
end
