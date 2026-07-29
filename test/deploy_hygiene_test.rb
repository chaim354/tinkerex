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
    sidecar_url_keys = base.dig("env", "clear").to_h.keys.grep(/_SIDECAR_URL\z/)
    assert sidecar_url_keys.any?, "expected deploy.yml to define at least one *_SIDECAR_URL"

    cleared = overlay.dig("env", "clear").to_h
    sidecar_url_keys.each do |key|
      assert cleared.key?(key), "deploy.ovh.yml must explicitly clear #{key} (it deep-merges otherwise)"
      # `.to_s.blank?`, NOT `.blank?`: ActiveSupport says `false.blank? == true`, but Kamal's
      # `Utils.argumentize` special-cases a YAML `false` into the literal docker arg `KEY=false` —
      # a non-blank STRING at runtime, so `configured?` reads TRUE and the bug this test exists to
      # catch comes straight back. Not hypothetical: deploy.yml's own env.clear already uses YAML
      # booleans (SOLID_QUEUE_IN_PUMA: true), so reaching for `false` to "disable" a URL is the
      # obvious next edit.
      assert cleared[key].to_s.blank?,
             "#{key} must be blank in the OVH overlay, got #{cleared[key].inspect}"
    end
  end

  test "every GPL sidecar image carries its own licence text" do
    # CLAUDE.md §9: we build these images and push them to a registry, which is REDISTRIBUTION —
    # so the licence has to be INSIDE the image, not merely beside the Dockerfile in this repo.
    # A DIRECTORY-DRIVEN sweep, not a hard-coded pair: the point is to close the class, so a third
    # sidecar added later is covered on the day it appears rather than the day someone remembers.
    # Discovery is "has a LICENSE next to a Dockerfile" — every sidecar here is GPL by construction
    # (that is why they are sidecars invoked over HTTP instead of libraries we link).
    sidecars = ROOT.glob("sidecar/*/Dockerfile").select { |df| df.dirname.join("LICENSE").exist? }
    assert sidecars.any?, "expected at least one sidecar/<name>/Dockerfile with a LICENSE beside it"

    sidecars.each do |dockerfile|
      name = dockerfile.dirname.basename.to_s
      copies_licence = dockerfile.read.lines.any? { |l| l.start_with?("COPY") && l.include?("LICENSE") }
      assert copies_licence,
             "sidecar/#{name}/Dockerfile must COPY its LICENSE into the image — we push this image, " \
             "which is redistribution (CLAUDE.md §9). sidecar/openscad is the pattern to copy."
    end
  end
end
