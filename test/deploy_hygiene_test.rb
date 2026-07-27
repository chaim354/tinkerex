require "test_helper"

# Guards two deployment invariants that no other test can see, because both live in files the Rails
# process never loads. Both were real, shipped bugs (spec §8.1).
class DeployHygieneTest < ActiveSupport::TestCase
  ROOT = Rails.root

  test "the GPL sidecar tree is excluded from the permissive Rails image" do
    # Dockerfile:47 is `COPY . .`, so anything not ignored is baked into the app image. CLAUDE.md §9:
    # no copyleft in our shipped artifacts. sidecar/boxes is GPL-3.0 and sidecar/openscad is GPL-2.0.
    ignore = ROOT.join(".dockerignore").read.lines.map(&:strip)
    assert_includes ignore, "/sidecar/",
                    "add `/sidecar/` to .dockerignore — `COPY . .` ships the GPL sidecars otherwise"
  end

  test "the OVH overlay clears every sidecar URL it cannot reach" do
    # Kamal DEEP-MERGES env.clear (a hash), so the overlay inherits deploy.yml's sidecar hostnames.
    # Those resolve only on the Unraid host, where the accessories actually run. Inheriting one makes
    # `configured?` true and every call fail — worse than the addon showing as unavailable.
    base    = YAML.load_file(ROOT.join("config/deploy.yml"),     aliases: true)
    overlay = YAML.load_file(ROOT.join("config/deploy.ovh.yml"), aliases: true)
    base_urls = base.dig("env", "clear").to_h.keys.grep(/_SIDECAR_URL\z/)
    assert base_urls.any?, "expected deploy.yml to define at least one *_SIDECAR_URL"

    cleared = overlay.dig("env", "clear").to_h
    base_urls.each do |key|
      assert cleared.key?(key), "deploy.ovh.yml must explicitly clear #{key} (it deep-merges otherwise)"
      assert cleared[key].blank?, "#{key} must be blank in the OVH overlay, got #{cleared[key].inspect}"
    end
  end
end
