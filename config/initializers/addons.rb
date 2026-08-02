# The host's own three addons register here. Inside `to_prepare`, NOT at initializer top level: app
# constants are not autoloadable while initializers run — §14a records the share boot guard raising
# `uninitialized constant Library` for exactly this and taking the boot down while every test stayed
# green (the test env skipped it). `to_prepare` runs after autoloading is set up, and again on each
# dev reload, which is why Registry#register overwrites by key rather than appending.
#
# An addon GEM does not appear here; it registers from its own engine. This file is the host's
# three only.
Rails.application.config.to_prepare do
  Maker::Addons::Registry.register(
    key: "boxes", title: "Box Generator", icon: "📦",
    description: "Parametric laser-cut / CNC boxes",
    available: -> { Tools::BoxesClient.configured? },
    path: ->(r) { r.tools_boxes_path }
  )

  Maker::Addons::Registry.register(
    key: "generators", title: "Generators", icon: "✏️",
    description: "Parametric 2D drawings → SVG (laser & CNC)",
    available: -> { true }, # client-only (Maker.js in the browser); always available
    path: ->(r) { r.tools_generators_path }
  )

  Maker::Addons::Registry.register(
    key: "openscad", title: "OpenSCAD", icon: "🧊",
    description: "Parametric .scad + params → 3MF",
    available: -> { Tools::OpenscadClient.configured? },
    path: ->(r) { r.tools_openscad_path }
  )
end
