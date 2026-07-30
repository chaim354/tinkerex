# In-memory stand-in for the OpenSCAD sidecar, injected via OpenscadClient.stub in tests. Mirrors
# the OpenscadClient API shape so the whole addon is exercisable without the Python sidecar.
#
# The param shapes below are the NORMALIZED output of sidecar/openscad/schema.py, whose own tests
# use OpenSCAD's real --export-format=param output as fixtures. Keeping this fake downstream of that
# is deliberate: a fake invented independently of the real wire format is how a fake ends up
# confirming the code's misunderstanding instead of catching it. Every param therefore carries ALL
# TEN keys schema.py always emits — name/type/default/help/group/choices/choice_labels/min/max/step,
# nil where absent — and each param's "group" equals its enclosing group's title, because that title
# is literally what schema.py groups by. Verified against a running sidecar (`GET /generators`), not
# reasoned from the source.
class FakeOpenscad
  HEX = {
    "key" => "hex_plate", "title" => "Hex grid plate",
    "description" => "A honeycomb plate", "license" => "MIT",
    "attribution" => "Example Author", "source_url" => "https://example.invalid/hex",
    "param_groups" => [
      { "title" => "Grid", "advanced" => false, "params" => [
          # A number always carries a step in the real dump (observed: every float/int in the
          # bundled catalog has one; only bool/str/enum come back with step nil).
          { "name" => "cols", "type" => "int", "default" => 4, "help" => "number of columns",
            "group" => "Grid", "choices" => nil, "choice_labels" => nil,
            "min" => nil, "max" => nil, "step" => 1 },
          { "name" => "wall", "type" => "float", "default" => 1.6, "help" => "",
            "group" => "Grid", "choices" => nil, "choice_labels" => nil,
            "min" => nil, "max" => nil, "step" => 1 },
          # bool / str / vector are here so the field partial's branches for them are actually
          # REACHED by fake-backed tests. The real catalog exercises all three (10 bools and 5 strs
          # across the bundled generators), so a fake covering only int/float/enum would leave three
          # rendering branches with no test touching them — green, and untested, which is the shape
          # of bug this fake exists to avoid.
          { "name" => "rounded", "type" => "bool", "default" => true, "help" => "round the corners",
            "group" => "Grid", "choices" => nil, "choice_labels" => nil,
            "min" => nil, "max" => nil, "step" => nil },
          { "name" => "label", "type" => "str", "default" => "demo", "help" => "engraved text",
            "group" => "Grid", "choices" => nil, "choice_labels" => nil,
            "min" => nil, "max" => nil, "step" => nil },
          # schema.py renders a vector default as comma-separated text for a plain input; the
          # sidecar re-brackets it into [a,b,c] on the way back.
          { "name" => "span", "type" => "vector", "default" => "10,20,30", "help" => "",
            "group" => "Grid", "choices" => nil, "choice_labels" => nil,
            "min" => nil, "max" => nil, "step" => nil } ] },
      # "advanced" is schema.py's own convention: title.strip().downcase in advanced/tuning/expert.
      { "title" => "Advanced", "advanced" => true, "params" => [
          # An enum keeps values and labels apart — OpenSCAD's `// [1:solid,2:hollow]` gives a
          # NUMERIC value a human label, and posting the label back would be a type error.
          { "name" => "mode", "type" => "enum", "default" => 1, "help" => "render mode",
            "group" => "Advanced", "choices" => [ 1, 2 ], "choice_labels" => %w[solid hollow],
            "min" => nil, "max" => nil, "step" => nil } ] }
    ]
  }.freeze

  TRAY = {
    "key" => "divider_tray", "title" => "Divider tray",
    "description" => "A compartment tray", "license" => "BSD-3-Clause",
    "attribution" => "Other Author", "source_url" => "https://example.invalid/tray",
    "param_groups" => [
      { "title" => "Tray", "advanced" => false, "params" => [
          { "name" => "x", "type" => "float", "default" => 100, "help" => "width (mm)",
            "group" => "Tray", "choices" => nil, "choice_labels" => nil,
            "min" => nil, "max" => nil, "step" => 1 } ] }
    ]
  }.freeze

  def generators
    [ HEX, TRAY ].map do |g|
      OpenscadClient::Generator.new(
        key: g["key"], title: g["title"], description: g["description"], license: g["license"],
        attribution: g["attribution"], source_url: g["source_url"],
        params: g["param_groups"].flat_map { |grp| grp["params"] },
        param_groups: g["param_groups"]
      )
    end
  end

  # The sidecar answers an unknown key with a 404 whose body is {"error": "unknown generator"}, and
  # the client unwraps that into exactly this message.
  def source(key)
    raise OpenscadClient::Error, "unknown generator" unless [ "hex_plate", "divider_tray" ].include?(key)

    "/* [Grid] */\n// number of columns\ncols = 4;\nwall = 1.6;\ncube([cols, wall, 1]);\n"
  end

  # Any source with a top-level assignment yields that one param — enough for the BYO flow's form.
  def params_for(_scad)
    { "params" => HEX["param_groups"].flat_map { |g| g["params"] },
      "param_groups" => HEX["param_groups"] }
  end

  # REAL zip magic: a 3MF is an OPC/zip container, and Maker::Previews::ThreeMf opens it as one. A
  # plain "fake bytes" string would make every preview path fail for a reason no production run has.
  def render(scad:, params:, format: "3mf")
    @rendered = { scad:, params:, format: }
    FakeOpenscad.minimal_3mf
  end

  attr_reader :rendered

  # A genuinely valid, minimal 3MF: a zip containing one 3D/3dmodel.model with a single triangle, so
  # Maker::Previews::ThreeMf's mesh fallback can actually parse it.
  def self.minimal_3mf
    require "zip"
    buf = Zip::OutputStream.write_buffer(StringIO.new("".b)) do |z|
      z.put_next_entry("3D/3dmodel.model")
      z.write(<<~XML)
        <?xml version="1.0" encoding="UTF-8"?>
        <model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
          <resources><object id="1" type="model"><mesh>
            <vertices>
              <vertex x="0" y="0" z="0"/><vertex x="10" y="0" z="0"/><vertex x="0" y="10" z="0"/>
            </vertices>
            <triangles><triangle v1="0" v2="1" v3="2"/></triangles>
          </mesh></object></resources>
          <build><item objectid="1"/></build>
        </model>
      XML
    end
    buf.string
  end
end
