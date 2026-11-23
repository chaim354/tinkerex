module Maker
  module Material
    # ONE MATERIAL ESTIMATE, BUILT FROM ONE REQUEST (2026-11-22; spec
    # docs/superpowers/specs/2026-11-22-material-estimate-design.md). The server keeps no state: the
    # parts list rides in the form as hidden fields and every request rebuilds the estimate from it.
    # Those fields are user-supplied, so every number is re-read and bounded HERE; a forged value can
    # only change its forger's own estimate, and the limits keep it from tying up the server.
    class Estimate
      MAX_PARTS = 200
      MAX_QTY = 500
      MAX_PLACEMENTS = 2_000
      MAX_SIDE_MM = 10_000.0
      MAX_GAP_MM = 100.0
      UNITS = { "mm" => 1.0, "in" => Maker::Previews::Dimensions::MM_PER_INCH }.freeze

      # The stock as typed, in `unit`; the *_mm readers are what the packer is handed.
      Stock = Data.define(:width, :height, :gap, :unit, :rotate) do
        def scale = UNITS.fetch(unit)
        def width_mm = width && width * scale
        def height_mm = height && height * scale
        def gap_mm = gap * scale
        def area_mm2 = width_mm * height_mm
      end

      DEFAULT_STOCK = Stock.new(width: 300.0, height: 300.0, gap: 2.0, unit: "mm", rotate: true)

      attr_reader :parts, :stock, :notes

      # `parts` is the form's indexed Hash ({"0" => {"name" => …}, …}) or nil; `stock` its stock
      # fields. A stock field the form did not send at all (a first visit) takes the default; one it
      # sent blank or unreadable is an error the page names.
      def self.from_params(parts:, stock:)
        new(parts: parse_parts(parts), stock: parse_stock(stock))
      end

      # Anything but a Hash where a Hash is expected (a forged `stock=x`, `parts[0][]=x`) is read as
      # not sent: `to_h` on a String or an Array of scalars raises instead.
      def self.parse_stock(raw)
        raw = raw.is_a?(Hash) ? raw.to_h.stringify_keys : {}
        Stock.new(width: field(raw, "sheet_width", DEFAULT_STOCK.width),
                  height: field(raw, "sheet_height", DEFAULT_STOCK.height),
                  gap: raw.key?("gap") ? (number(raw["gap"]) || 0.0) : DEFAULT_STOCK.gap,
                  unit: UNITS.key?(raw["unit"].to_s) ? raw["unit"].to_s : DEFAULT_STOCK.unit,
                  rotate: raw.key?("rotate") ? raw["rotate"].to_s == "1" : DEFAULT_STOCK.rotate)
      end

      def self.parse_parts(raw)
        rows = raw.is_a?(Hash) ? raw.sort_by { |key, _| key.to_s.to_i }.map(&:last) : Array(raw)
        rows.first(MAX_PARTS).filter_map { |row| part_from(row.to_h.stringify_keys) if row.is_a?(Hash) }
      end

      def self.part_from(row)
        name = row["name"].to_s.strip.first(255).presence || "Untitled"
        node_id = row["node_id"].to_s.strip.first(64).presence
        reason = row["reason"].to_s.strip.first(200).presence
        return Part.refused(name:, node_id:, reason:) if reason

        width = number(row["width"])
        height = number(row["height"])
        return Part.refused(name:, node_id:, reason: "size could not be read") unless readable_size?(width, height)

        qty = (Integer(row["qty"].to_s.strip, 10, exception: false) || 1).clamp(1, MAX_QTY)
        Part.measured(name:, node_id:, page: row["page"].to_s.strip.first(255).presence, width:, height:, qty:)
      end

      def self.readable_size?(width, height)
        width && height && !width.negative? && !height.negative? && (width.positive? || height.positive?) &&
          width <= MAX_SIDE_MM && height <= MAX_SIDE_MM
      end

      def self.field(raw, key, default) = raw.key?(key) ? number(raw[key]) : default

      def self.number(value)
        f = Float(value.to_s.strip, exception: false)
        f if f&.finite?
      end

      def initialize(parts:, stock:, notes: [])
        @parts = parts
        @stock = stock
        @notes = notes
      end

      def adding(more, notes: [])
        kept = more.first([ MAX_PARTS - parts.size, 0 ].max)
        extra = more.size - kept.size
        overflow = extra.positive? ? [ "Left out #{extra} #{'part'.pluralize(extra)}: the list holds at most #{MAX_PARTS}." ] : []
        Estimate.new(parts: parts + kept, stock:, notes: self.notes + notes + overflow)
      end

      def without(index)
        return self unless index.is_a?(Integer) && index.between?(0, parts.size - 1)

        Estimate.new(parts: parts.reject.with_index { |_, i| i == index }, stock:, notes:)
      end

      def with_note(note) = Estimate.new(parts:, stock:, notes: notes + [ note ])

      def measured_parts = parts.select(&:measured?)

      def copies = measured_parts.sum(&:qty)

      def total_area_mm2 = measured_parts.sum(&:area)

      def errors
        @errors ||= [].tap do |list|
          if stock.width.nil? || stock.height.nil?
            list << "Enter the sheet's width and height."
          elsif ![ stock.width_mm, stock.height_mm ].all? { |side| side.between?(1.0, MAX_SIDE_MM) }
            list << "Each side of the sheet must be between 1 and #{delimited(MAX_SIDE_MM.to_i)} mm."
          end
          list << "The gap must be between 0 and #{MAX_GAP_MM.to_i} mm." unless stock.gap_mm.between?(0.0, MAX_GAP_MM)
          list << "Too many copies to lay out: #{delimited(copies)}. The limit is #{delimited(MAX_PLACEMENTS)}." if copies > MAX_PLACEMENTS
        end
      end

      def pack
        return nil if errors.any? || measured_parts.empty?

        @pack ||= SheetPack.call(measured_parts.flat_map { |part| Array.new(part.qty, part) },
                                 sheet_width: stock.width_mm, sheet_height: stock.height_mm,
                                 gap: stock.gap_mm, rotate: stock.rotate)
      end

      def sheets = pack&.sheets || []

      # Each part too big for the sheet once, with how many of its copies were refused.
      def unplaced = (pack&.unplaced || []).tally.to_a

      def utilization
        return nil if sheets.empty?

        placed = sheets.sum { |sheet| sheet.sum { |pl| pl.width * pl.height } }
        placed / (sheets.size * stock.area_mm2)
      end

      private

      def delimited(n) = ActiveSupport::NumberHelper.number_to_delimited(n)
    end
  end
end
