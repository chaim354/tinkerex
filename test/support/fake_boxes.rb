# In-memory stand-in for the boxes sidecar, injected via BoxesClient.stub in tests. Mirrors the
# BoxesClient API shape (generators -> [Generator], generate -> SVG bytes) so the whole Boxes addon
# is exercisable without the Python sidecar (which is Plan B).
class FakeBoxes
  def generators
    [ BoxesClient::Generator.new(
        key: "ABox", title: "Simple box", group: "Boxes",
        params: [ { "name" => "x", "type" => "float", "default" => 100, "help" => "width (mm)" },
                  { "name" => "y", "type" => "float", "default" => 50, "help" => "depth (mm)" } ]),
      BoxesClient::Generator.new(
        key: "TypeTray", title: "Divider tray", group: "Trays",
        params: [ { "name" => "x", "type" => "float", "default" => 100, "help" => "width (mm)" } ]) ]
  end

  def generate(generator:, params:)
    %(<svg xmlns="http://www.w3.org/2000/svg" width="100" height="50"><rect width="100" height="50" fill="none" stroke="#000"/></svg>)
  end
end
