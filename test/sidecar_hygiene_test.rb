require "test_helper"

# EVERY SIDECAR HAS EVERY TOUCHPOINT, AND NO CONFIG NAMES A SIDECAR THAT IS NOT THERE.
# Tinkerex::Sidecars is the definition; this asserts it of the real tree, so a hand-added sidecar
# that skips one of the eight edits fails bin/ci with the exact snippet to add.
class SidecarHygieneTest < ActiveSupport::TestCase
  test "every sidecar is complete and nothing is stray" do
    sidecars = Tinkerex::Sidecars.new
    assert_not_empty sidecars.names, "no sidecar/*/Dockerfile — this guard would pass over nothing (§14e)"
    problems = sidecars.problems
    assert problems.empty?, problems.map { |p| p.touchpoint? ? "#{p.message}; add:\n#{p.snippet}" : "#{p.message}; fix: #{p.snippet}" }.join("\n")
  end
end
