require "test_helper"
require "yaml"

# THE QUICK START PULLS AND NEEDS NOTHING SET (I, 2026-10-14). These pins hold the compose file to
# that: a `build:` creeping back makes `docker compose up` compile for minutes instead of pulling
# (with image: and build: both present, compose BUILDS when the image is not in the local cache), a
# required env_file makes a missing .env a boot error, a lost platform pin fails openscad on every
# arm64 machine, and a profile hides the Tools gallery again. YAML-parsed, never grepped, so a
# comment can neither satisfy nor trip them.
class ComposeHygieneTest < ActiveSupport::TestCase
  SERVICES = (%w[web addons] + Tinkerex::Sidecars.new.names).freeze

  def compose(file) = YAML.safe_load(Rails.root.join(file).read, aliases: true)

  test "the quick start pulls one ghcr image per service, behind no profile, and builds nothing" do
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
    sidecars = Tinkerex::Sidecars.new
    sidecars.names.each do |n|
      assert_equal sidecars.compose_url(n), env[sidecars.env_key(n)], "web must carry the #{n} sidecar's URL"
    end
    assert_equal "http://addons", env["ADDON_SOURCE_URL"]
    assert_equal "${RAILS_MAX_THREADS:-16}", env["RAILS_MAX_THREADS"], "Puma's stock 3 starves once a sidecar is proxied"
    assert_equal "${PUID:-}", env["PUID"], "empty when unset, so the entrypoint infers the folder's owner (J)"
    assert_equal "${PGID:-}", env["PGID"]
    assert_not_includes env.keys, "LIBRARY_BACKEND", "the backend is the image's default now (Dockerfile)"
    assert_not_includes env.keys, "LIBRARY_PATH"
    assert_equal [ "tinkerex_storage:/rails/storage", "${LIBRARY_HOST_PATH:-.}:/library" ], web["volumes"],
                 "the compose file's own folder is the library (J): '.' resolves against the file, not the shell's cwd"
    assert_equal "${LIBRARY_HOST_PATH:-}", env["LIBRARY_HOST_PATH"],
                 "passed through DISPLAY-ONLY: empty when unset, so the app can say 'the folder your docker-compose.yml is in'"
    assert_equal [ "${TINKEREX_PORT:-8080}:80" ], web["ports"]
  end

  test "every Tools image is pinned to amd64 and the app image is not" do
    services = compose("docker-compose.yml").fetch("services")
    (Tinkerex::Sidecars.new.names + %w[addons]).each do |name|
      assert_equal "linux/amd64", services.dig(name, "platform"),
                   "#{name} is published for amd64 only (openscad is an x86 AppImage; the others are built " \
                   "with --platform linux/amd64, measured 2026-10-14): without the pin an arm64 pull fails"
    end
    assert_nil services.dig("web", "platform"), "the app image is multi-arch; a pin would force emulation on Apple silicon"
  end

  # A FIRST START RUNS WHATEVER IMAGE DOCKER ALREADY HOLDS (2026-11-11). `docker compose up -d` pulls
  # only an image missing from the local cache, so a machine that tried Tinkerex before starts that
  # old build: a server made that day on a Mac holding an October :latest had no welcome tour, which
  # shipped in November. Every place a newcomer is told to start it says `--pull always`. The update
  # line and the re-runs after a settings change stay bare on purpose: they keep the image in hand.
  # The generated file's header is pinned in test/system/compose_generator_test.rb.
  FIRST_START = "docker compose up -d --pull always"
  BARE_START = /docker compose up -d(?! --pull always)/

  test "every first start a newcomer is told to run pulls the newest images" do
    regions = {
      "docker-compose.yml's start line" => Rails.root.join("docker-compose.yml").read[/^#.*pull and start.*$/],
      "README.md's quick start" => section(Rails.root.join("README.md").read, "## Quick start"),
      "docs/INSTALL.md's quick start" => section(Rails.root.join("docs/INSTALL.md").read, "## 2. Quick start"),
      "the compose page's next step" =>
        Rails.root.join("app/views/public/compose/show.html.erb").read[%r{<p class="compose-next.*?</p>}m]
    }
    regions.each do |name, text|
      assert text, "#{name} is gone: find where a newcomer is now told to start it and point this at it"
      assert_includes text, FIRST_START, name
      assert_no_match BARE_START, text, "#{name} starts whatever image Docker already holds"
    end
  end

  test "the build overlay restores a build for every service under a :local name" do
    services = compose("docker-compose.build.yml").fetch("services")
    assert_equal SERVICES.sort, services.keys.sort
    services.each do |name, s|
      assert s["build"].present?, "#{name} must build in the overlay"
      assert_match(/:local\z/, s.fetch("image"), "#{name}'s built image must not shadow the ghcr tag")
    end
    assert_equal [ "${LIBRARY_HOST_PATH:-./library}:/library" ], services.dig("web", "volumes"),
                 "in a clone '.' is the repository; the overlay puts the mount back to ./library " \
                 "(compose merges volumes by container path, so the storage volume survives)"
  end

  private

  # A markdown section: its heading line through the line before the next heading at its level or above.
  def section(doc, heading)
    level = heading[/\A#+/].size
    doc[Regexp.new("^#{Regexp.escape(heading)}$.*?(?=^[#]{1,#{level}} |\\z)", Regexp::MULTILINE)]
  end
end
