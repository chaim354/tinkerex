# Test double for Maker::Addons::Source, mirroring test/support/fake_boxes.rb. Injected via
# `Maker::Addons::Source.stub = FakeAddonSource.new(...)`; reset in teardown.
class FakeAddonSource
  attr_reader :manifests, :assets

  def initialize(manifests: [], assets: {})
    @manifests = manifests
    @assets = assets
  end

  # Mirrors the real Source's refusal so a test cannot pass against a fake that is more permissive
  # than the code — a fake sharing the code's misunderstanding confirms it (§14e).
  def asset(key, path)
    Maker::Addons::Source.new("http://fake").asset_path!(path)
    @assets.fetch("#{key}/#{path}") { raise Maker::Addons::Source::Error, "missing #{key}/#{path}" }
  end
end
