require "test_helper"

module Tools
  # Drives the REAL BoxesClient (no stub) against a live boxes sidecar. Skips cleanly when
  # BOXES_SIDECAR_URL is unset — the same "skips with no server" pattern the sync-engine integration
  # suite uses. Run it against the Task-4 container:
  #   docker run -d --name bsc -p 18000:8000 boxes-sidecar-check
  #   BOXES_SIDECAR_URL=http://localhost:18000 bin/rails test test/integration/tools/boxes_live_test.rb
  class BoxesLiveTest < ActiveSupport::TestCase
    setup do
      skip "set BOXES_SIDECAR_URL to run against a live boxes sidecar" if ENV["BOXES_SIDECAR_URL"].blank?
      BoxesClient.reset!
    end

    test "lists generators from the live sidecar" do
      gens = BoxesClient.current.generators
      assert gens.any?, "expected a non-empty generator list"
      assert gens.any? { |g| g.key == "ABox" }, "expected the ABox generator"
      abox = gens.find { |g| g.key == "ABox" }
      assert abox.params.any? { |p| p["name"] == "x" }, "ABox should expose an x param"
    end

    test "generates SVG from the live sidecar" do
      svg = BoxesClient.current.generate(generator: "ABox", params: { x: 80, y: 40, h: 30 })
      assert(svg.start_with?("<?xml") || svg.include?("<svg"), "expected SVG bytes")
    end
  end
end
