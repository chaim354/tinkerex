require_relative "fake_service_proxy"

# In-memory stand-in for the boxes sidecar, injected at the Maker::Addons::ServiceProxy seam — the
# door the bundle now reaches its sidecar through (${ctx.serviceUrl}boxes/<path>, proxied by
# Tools::AddonsController#service) — rather than the deleted BoxesClient/FakeBoxes pairing this
# repo used pre-migration (test/support/fake_boxes.rb no longer exists; its Ruby-object-shaped
# double made no sense once the bundle moved to plain fetch() calls).
#
# The FOUR generators and their exact param shapes are carried over byte-for-byte from FakeBoxes —
# same key/title/group/param_groups, same TRAY_LAYOUT and FRONT_PANEL_LAYOUT ASCII art — so every
# assertion the old system tests made about section grouping, folding, and tray-layout parsing
# still exercises the identical fixture data, just reached through the bundle instead of a
# server-rendered form.
class FakeBoxesSidecar
  BASE_URL = "http://boxes-sidecar.test".freeze

  TRAY_LAYOUT = <<~ART
     ,> 50.0mm
     | ,> 50.0mm
     | | ,> 50.0mm
    +-+-+-+
    | | | | 50.0mm
    +-+-+-+
    | | | | 50.0mm
    +-+-+-+
  ART

  FRONT_PANEL_LAYOUT = <<~DSL
    outline 100 100
    rect 50 60 80 30 3 True False
    circle 10 45 3.5
  DSL

  GENERATORS = [
    { "key" => "ABox", "title" => "Simple box", "group" => "Box",
      "param_groups" => [
        { "title" => "ABox Settings", "advanced" => false, "params" => [
          { "name" => "x", "type" => "float", "default" => 100, "help" => "width (mm)" },
          { "name" => "y", "type" => "float", "default" => 50,
            "help" => "depth (mm) [🛈](https://florianfesti.github.io/boxes/html/usermanual.html#y)" }
        ] },
        { "title" => "Settings for Finger Joints", "advanced" => true, "params" => [
          { "name" => "FingerJoint_style", "type" => "enum", "default" => "rectangular",
            "choices" => %w[rectangular springs barbs snap], "help" => "style of the fingers" }
        ] }
      ] },
    # sx/sy WITHOUT a `layout` — the real TypeTray's shape (upstream: "allows only continuous
    # walls") and the case the top view has to build a grid for by itself.
    { "key" => "TypeTray", "title" => "Divider tray", "group" => "Tray",
      "param_groups" => [
        { "title" => "TypeTray Settings", "advanced" => false, "params" => [
          { "name" => "x", "type" => "float", "default" => 100, "help" => "width (mm)" },
          { "name" => "sx", "type" => "str", "default" => "50*3", "help" => "sections in x" },
          { "name" => "sy", "type" => "str", "default" => "50*2", "help" => "sections in y" },
          { "name" => "thickness", "type" => "float", "default" => 3.0,
            "help" => "thickness of the material (in mm)" }
        ] }
      ] },
    # A TrayLayout-shaped generator: sx/sy sizes plus a MULTILINE `layout` — ASCII art that
    # boxes.py parses the compartments back out of.
    { "key" => "TrayLayout", "title" => "Generate a typetray from a layout file", "group" => "Tray",
      "param_groups" => [
        { "title" => "TrayLayout Settings", "advanced" => false, "params" => [
          { "name" => "sx", "type" => "str", "default" => "50*3", "help" => "sections in x" },
          { "name" => "sy", "type" => "str", "default" => "50*2", "help" => "sections in y" },
          { "name" => "layout", "type" => "str", "multiline" => true, "default" => TRAY_LAYOUT,
            "help" => "Set **sx** and **sy** before editing this!" },
          { "name" => "thickness", "type" => "float", "default" => 3.0,
            "help" => "thickness of the material (in mm)" }
        ] }
      ] },
    # FrontPanel's `layout` is a DIFFERENT DSL (outline/rect/circle/text) — nothing to do with the
    # tray grid above. It is multiline too, so it renders as the same <textarea>, but the top view
    # must NOT draw anything for it (see tray_top_view_test.rb).
    { "key" => "FrontPanel", "title" => "Front panel with holes", "group" => "Holes",
      "param_groups" => [
        { "title" => "FrontPanel Settings", "advanced" => false, "params" => [
          { "name" => "layout", "type" => "str", "multiline" => true,
            "default" => FRONT_PANEL_LAYOUT, "help" => "the panel's elements" }
        ] }
      ] }
  ].freeze

  DEFAULT_SVG = %(<svg xmlns="http://www.w3.org/2000/svg" width="100" height="50">) +
                %(<rect width="100" height="50" fill="none" stroke="#000"/></svg>)

  # ABox has a bundled sample photo; the other three (like most real generators) have none, so the
  # gallery's <img> 404s for them on purpose and the bundle's own onerror handler hides the tile —
  # see SAMPLE_404 in the test files that assert_no_console_errors around it.
  SAMPLE_JPEG = "\xFF\xD8\xFF\xE0JFIFdata".b

  # Wires ENV["BOXES_SIDECAR_URL"] (the addon's manifest declares services: ["boxes"], so
  # Tools::AddonsController#sidecar_url_for derives exactly this env var name) and installs a
  # FakeServiceProxy answering the three endpoints the bundle calls: GET generators, POST generate,
  # GET sample/:key. Returns the FakeServiceProxy so a test can inspect `.calls` afterward — e.g. to
  # read what a save actually sent, mirroring the deleted FakeBoxes#last_generate.
  def self.install!(generate_svg: DEFAULT_SVG)
    ENV["BOXES_SIDECAR_URL"] = BASE_URL
    proxy = FakeServiceProxy.new
    proxy.ok("#{BASE_URL}/generators", body: GENERATORS.to_json, content_type: "application/json")
    proxy.ok("#{BASE_URL}/generate", body: generate_svg, content_type: "image/svg+xml")
    proxy.ok("#{BASE_URL}/sample/ABox", body: SAMPLE_JPEG, content_type: "image/jpeg")
    Maker::Addons::ServiceProxy.stub = proxy
    proxy
  end

  def self.uninstall!
    ENV.delete("BOXES_SIDECAR_URL")
    Maker::Addons::ServiceProxy.reset!
  end
end
