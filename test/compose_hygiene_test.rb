require "test_helper"
require "yaml"

# THE QUICK START PULLS AND NEEDS NOTHING SET (I, 2026-10-14). These pins hold the compose file to
# that: a `build:` creeping back makes `docker compose up` compile for minutes instead of pulling
# (with image: and build: both present, compose BUILDS when the image is not in the local cache), a
# required env_file makes a missing .env a boot error, a lost platform pin fails openscad on every
# arm64 machine, and a profile hides the Tools gallery again. YAML-parsed, never grepped, so a
# comment can neither satisfy nor trip them.
class ComposeHygieneTest < ActiveSupport::TestCase
  SERVICES = %w[web boxes openscad addons].freeze

  def compose(file) = YAML.safe_load(Rails.root.join(file).read, aliases: true)

  test "the quick start pulls four ghcr images, behind no profile, and builds nothing" do
    services = compose("docker-compose.yml").fetch("services")
    assert_equal SERVICES.sort, services.keys.sort
    services.each do |name, s|
      assert_nil s["build"], "#{name} has a build: — compose would build instead of pulling"
      assert_nil s["profiles"], "#{name} is behind a profile; the Tools gallery ships on by default"
      assert_match(%r{\A(\$\{TINKEREX_IMAGE:-)?ghcr\.io/chaim354/[a-z-]+:latest\}?\z}, s.fetch("image"), name)
    end
  end

  test "the app needs no .env, carries the Tools URLs and the thread count, and keeps its two mounts" do
    web = compose("docker-compose.yml").dig("services", "web")
    assert_equal [ { "path" => ".env", "required" => false } ], web["env_file"]
    env = web.fetch("environment")
    assert_equal "http://boxes:8000", env["BOXES_SIDECAR_URL"]
    assert_equal "http://openscad:8000", env["OPENSCAD_SIDECAR_URL"]
    assert_equal "http://addons", env["ADDON_SOURCE_URL"]
    assert_equal "${RAILS_MAX_THREADS:-16}", env["RAILS_MAX_THREADS"], "Puma's stock 3 starves once a sidecar is proxied"
    assert_equal "${PUID:-1000}", env["PUID"]
    assert_equal "${PGID:-1000}", env["PGID"]
    assert_not_includes env.keys, "LIBRARY_BACKEND", "the backend is the image's default now (Dockerfile)"
    assert_not_includes env.keys, "LIBRARY_PATH"
    assert_equal [ "tinkerex_storage:/rails/storage", "${LIBRARY_HOST_PATH:-./library}:/library" ], web["volumes"]
    assert_equal [ "${TINKEREX_PORT:-8080}:80" ], web["ports"]
  end

  test "the three Tools images are pinned to amd64 and the app image is not" do
    services = compose("docker-compose.yml").fetch("services")
    %w[boxes openscad addons].each do |name|
      assert_equal "linux/amd64", services.dig(name, "platform"),
                   "#{name} is published for amd64 only (openscad is an x86 AppImage; the other two are built " \
                   "with --platform linux/amd64, measured 2026-10-14): without the pin an arm64 pull fails"
    end
    assert_nil services.dig("web", "platform"), "the app image is multi-arch; a pin would force emulation on Apple silicon"
  end

  test "the build overlay restores a build for every service under a :local name" do
    services = compose("docker-compose.build.yml").fetch("services")
    assert_equal SERVICES.sort, services.keys.sort
    services.each do |name, s|
      assert s["build"].present?, "#{name} must build in the overlay"
      assert_match(/:local\z/, s.fetch("image"), "#{name}'s built image must not shadow the ghcr tag")
    end
  end
end
