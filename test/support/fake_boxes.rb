# In-memory stand-in for the boxes sidecar, injected via BoxesClient.stub in tests. Mirrors the
# BoxesClient API shape (generators -> [Generator with param_groups], generate -> SVG bytes) so the
# whole Boxes addon is exercisable without the Python sidecar (which is Plan B).
class FakeBoxes
  # Exactly the shape TrayLayoutFile emits for sx="50*3" sy="50*2": a size marker per column, then a
  # wall row / compartment row per row. Column alignment is load-bearing — boxes.py reads the walls
  # off character positions — which is why this param needs a <textarea>, not an <input type="text">
  # (whose value sanitization silently strips the newlines).
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

  def generators
    [ BoxesClient::Generator.new(
        key: "ABox", title: "Simple box", group: "Box",
        param_groups: [
          { "title" => "ABox Settings", "advanced" => false, "params" => [
              { "name" => "x", "type" => "float", "default" => 100, "help" => "width (mm)" },
              { "name" => "y", "type" => "float", "default" => 50,
                "help" => "depth (mm) [🛈](https://florianfesti.github.io/boxes/html/usermanual.html#y)" } ] },
          { "title" => "Settings for Finger Joints", "advanced" => true, "params" => [
              { "name" => "FingerJoint_style", "type" => "enum", "default" => "rectangular",
                "choices" => %w[rectangular springs barbs snap], "help" => "style of the fingers" } ] } ]),
      BoxesClient::Generator.new(
        key: "TypeTray", title: "Divider tray", group: "Tray",
        param_groups: [
          { "title" => "TypeTray Settings", "advanced" => false, "params" => [
              { "name" => "x", "type" => "float", "default" => 100, "help" => "width (mm)" } ] } ]),
      # A TrayLayout-shaped generator: sx/sy sizes plus a MULTILINE `layout` — ASCII art that boxes.py
      # parses the compartments back out of. The real sidecar seeds that default (via boxes.py's own
      # TrayLayoutFile) precisely because the raw upstream default is "\n", which does not render.
      BoxesClient::Generator.new(
        key: "TrayLayout", title: "Generate a typetray from a layout file", group: "Tray",
        param_groups: [
          { "title" => "TrayLayout Settings", "advanced" => false, "params" => [
              { "name" => "sx", "type" => "str", "default" => "50*3", "help" => "sections in x" },
              { "name" => "sy", "type" => "str", "default" => "50*2", "help" => "sections in y" },
              { "name" => "layout", "type" => "str", "multiline" => true, "default" => TRAY_LAYOUT,
                "help" => "Set **sx** and **sy** before editing this!" } ] } ]) ]
  end

  # The params of the last generate call, so a test can assert what actually reached the client —
  # e.g. that a browser's real form submission carried a layout's newlines rather than one flat line.
  attr_reader :last_generate

  def generate(generator:, params:)
    @last_generate = { generator: generator, params: params }
    %(<svg xmlns="http://www.w3.org/2000/svg" width="100" height="50"><rect width="100" height="50" fill="none" stroke="#000"/></svg>)
  end

  # ABox has a bundled sample photo; TypeTray (like most generators) has none -> nil (tile falls back).
  def sample(key)
    key == "ABox" ? "\xFF\xD8\xFF\xE0JFIFdata".b : nil
  end
end
