module Maker
  module Addons
    # ext-registry pattern (mirrors Maker::Previews::Registry). Adding an addon = one entry here +
    # a Tools:: controller. `available?` lets an addon grey out when unconfigured (e.g. Boxes when
    # BOXES_SIDECAR_URL is unset), the same graceful degradation the preview renderers use.
    Addon = Data.define(:key, :title, :icon, :description, :available) do
      def available? = available.call
    end

    module Registry
      module_function

      REGISTRY = {
        "boxes" => Addon.new(
          key: "boxes", title: "Box Generator", icon: "📦",
          description: "Parametric laser-cut / CNC boxes",
          available: -> { BoxesClient.configured? }
        ),
        "generators" => Addon.new(
          key: "generators", title: "Generators", icon: "✏️",
          description: "Parametric 2D drawings → SVG (laser & CNC)",
          available: -> { true } # client-only (Maker.js in the browser); always available
        ),
        "openscad" => Addon.new(
          key: "openscad", title: "OpenSCAD", icon: "🧊",
          description: "Parametric .scad + params → 3MF",
          available: -> { OpenscadClient.configured? }
        )
      }.freeze

      def all = REGISTRY.values
      def find(key) = REGISTRY[key.to_s]
    end
  end
end
