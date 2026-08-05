# Test double for Maker::Addons::Source, mirroring test/support/fake_boxes.rb. Injected via
# `Maker::Addons::Source.stub = FakeAddonSource.new(...)`; reset in teardown.
class FakeAddonSource
  attr_reader :manifests, :assets

  def initialize(manifests: [], assets: {}, cacheable: false)
    @manifests = manifests
    @assets = assets
    @cacheable = cacheable
  end

  # DEFAULTS TO FALSE so every fetch reaches this fake, which is what most tests here need — several
  # mutate `assets` between two requests and assert the change is visible. A test that is actually
  # ABOUT caching opts in with `cacheable: true`. That keeps the cache exercised where it is the
  # subject and out of the way everywhere else, rather than every unrelated test in this file
  # quietly depending on cache state.
  def cacheable? = @cacheable

  # Mirrors the real Source's refusal so a test cannot pass against a fake that is more permissive
  # than the code — a fake sharing the code's misunderstanding confirms it (§14e).
  def asset(key, path)
    Maker::Addons::Source.new("http://fake").asset_path!(path)
    @assets.fetch("#{key}/#{path}") { raise Maker::Addons::Source::Error, "missing #{key}/#{path}" }
  end
end
