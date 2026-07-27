require "test_helper"

module Tools
  # Drives the REAL OpenscadClient (no stub) against a live sidecar. Skips cleanly when
  # OPENSCAD_SIDECAR_URL is unset — the same "skips with no server" pattern the sync-engine
  # integration suite and boxes_live_test.rb use. Run it against the Task 2 container:
  #   docker run -d --name oscad-live -p 18000:8000 openscad-sidecar
  #   OPENSCAD_SIDECAR_URL=http://localhost:18000 bin/rails test test/integration/tools/openscad_live_test.rb
  #   docker rm -f oscad-live
  #
  # `5 skips` is the failure mode to watch for here, not a pass: it means the env var never reached
  # the test and NOTHING was verified.
  class OpenscadLiveTest < ActiveSupport::TestCase
    # The bundled catalog as SHIPPED (catalog/catalog.json), not as the plan first imagined it:
    # vase_box and universal_stand were dropped on licensing grounds (catalog/NOTICE).
    BUNDLED = %w[hex_cell_holder washer probe_plate].freeze

    setup do
      skip "set OPENSCAD_SIDECAR_URL to run against a live openscad sidecar" if ENV["OPENSCAD_SIDECAR_URL"].blank?
      OpenscadClient.reset!
    end

    test "lists the bundled catalog with licences and derived params" do
      gens = OpenscadClient.current.generators
      assert gens.any?, "expected a non-empty catalog"
      assert_equal BUNDLED.sort, gens.map(&:key).sort,
                   "the live catalog drifted from catalog/catalog.json"
      gens.each do |g|
        # Every bundled generator must name its licence — the catalog is redistributed inside a
        # commercial image, so an unlicensed entry is the one thing that must never ship (spec §2).
        assert g.license.present?, "#{g.key} carries no licence"
        assert g.attribution.present?, "#{g.key} carries no attribution"
        # A generator whose schema will not derive is SKIPPED by /generators rather than 500ing the
        # list, so an entry that reached us with no params derived nothing at all.
        assert g.params.any?, "#{g.key} derived no parameters"
        assert g.param_groups.any?, "#{g.key} derived no parameter groups"
      end
    end

    test "serves the raw source for a bundled key, which is what keeps one render path" do
      src = OpenscadClient.current.source("probe_plate")
      assert src.include?("="), "expected .scad source text"
      # Rails re-tags the body UTF-8 because it goes straight back out as JSON in #render's body;
      # an ASCII-8BIT string there warns today and raises under json 3.0.
      assert_equal Encoding::UTF_8, src.encoding
      # Round-trips through the ONE render path exactly as a bring-your-own file's bytes would.
      assert_equal "PK", OpenscadClient.current.render(scad: src, params: {})[0, 2]
    end

    test "derives a Customizer schema from arbitrary source" do
      src = "/* [G] */\n// how many\ncols = 4;\nwall = 1.5;\ncube([cols, wall, 1]);\n"
      schema = OpenscadClient.current.params_for(src)
      names = schema["params"].map { |p| p["name"] }
      assert_includes names, "cols"
      assert_includes names, "wall"
      cols = schema["params"].find { |p| p["name"] == "cols" }
      assert_equal "int", cols["type"], "4.0 with an integral step means 4 (schema.py trap 2)"
      assert_equal "how many", cols["help"]
      assert_equal [ "G" ], schema["param_groups"].map { |g| g["title"] }
    end

    test "renders real 3MF bytes that the preview pipeline can actually read" do
      src = "cols = 3;\ncube([cols, 2, 1]);\n"
      bytes = OpenscadClient.current.render(scad: src, params: { "cols" => 5 })
      assert_equal "PK", bytes[0, 2], "expected a zip/OPC container"
      # END-TO-END: the thumbnail is the user-visible payoff (spec §6.1 verified by reading the
      # source that a mesh fallback exists — 3MF from OpenSCAD carries no embedded thumbnail; this
      # proves it works on OUR bytes). mesh_to_stl is pure Ruby; the full Stl.render shells out to
      # stl-thumbnailer, which is not on every box, so the assertion stops here on purpose.
      stl = Maker::Previews::ThreeMf.mesh_to_stl(bytes)
      assert stl.to_s.bytesize.positive?,
             "ThreeMf could not read a mesh out of the sidecar's 3MF — thumbnails would be blank"
      # A binary STL is an 80-byte header + a uint32 LE facet count; a header with no facets would
      # still be "positive bytes" and still thumbnail blank.
      assert stl.byteslice(80, 4).unpack1("V").positive?, "the STL carries no facets"
    end

    test "a repeat render of identical params is a cache hit" do
      src = "cols = 7;\ncube([cols, 1, 1]);\n"
      a = OpenscadClient.current.render(scad: src, params: {})
      t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      b = OpenscadClient.current.render(scad: src, params: {})
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t
      assert_equal a, b, "a cache hit must return identical bytes"
      assert elapsed < 1.0, "expected a cache hit to be fast, took #{elapsed.round(2)}s"
    end

    test "a broken .scad raises a client Error carrying OpenSCAD's own complaint" do
      e = assert_raises(OpenscadClient::Error) do
        OpenscadClient.current.render(scad: "this is not scad {{{", params: {})
      end
      assert e.message.present?
      # The sidecar's own {"error": …} is what names the actionable complaint; a bare
      # "openscad sidecar 422" would mean the detail never made it through.
      refute_match(/\Aopenscad sidecar \d+\z/, e.message, "lost the sidecar's error detail")
    end
  end
end
