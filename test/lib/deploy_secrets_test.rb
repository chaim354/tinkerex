require "test_helper"
require "open3"
require "tmpdir"

# Tinkerex::DeploySecrets over FIXTURE deploy configs: the one walk of the places kamal resolves a
# secret, and the one list of destinations, that bin/secrets-preflight and
# test/deploy_hygiene_test.rb both read. The hygiene test's synthetic oracle plants a name at every
# arm of the walk as a Hash; this file drives the walk the way its readers do — through kamal, off
# files on disk — and runs the real bin/secrets-preflight, the copy of the walk that gates a deploy
# and that no test ran until the two copies became one (2026-10-19, F-S25-1).
#
# NOTHING HERE TOUCHES A REAL SECRET. The fixtures' secrets files hold literals only, and the
# preflight runs with the fixture as its working directory and a PATH that cannot reach 1Password
# (see #preflight).
class DeploySecretsTest < ActiveSupport::TestCase
  PREFLIGHT = Rails.root.join("bin/secrets-preflight")

  # A minimal VALID kamal config with a secret planted at EVERY KIND OF LOCATION THE REAL CONFIG
  # RESOLVES ONE FROM — four, measured 2026-10-19 across all four destinations: root env.secret, the
  # registry password, an accessory's env.secret (where SECRET_KEY_BASE and SYNC_ADMIN_TOKEN live, an
  # arm the walk once missed, e2fafea1), and a custom TLS pair under `proxy: ssl:` (ovh's Cloudflare
  # origin certificate and key). Every one the real config uses must be here, because the preflight
  # run below is the only test of the deploy-gating reader: with three of them, a walk covering only
  # those three, pasted back into the preflight, passed this whole file (review of #423). No fixture
  # secrets file defines the accessory's secret or either TLS name, so all three must come back MISSING.
  DEPLOY = <<~YAML.freeze
    service: fixture
    image: fixture/app
    servers:
      web:
        - 10.0.0.1
    proxy:
      hosts:
        - fixture.example
      ssl:
        certificate_pem: FIXTURE_TLS_CERTIFICATE_PEM
        private_key_pem: FIXTURE_TLS_PRIVATE_KEY_PEM
    registry:
      username: fixture
      password:
        - FIXTURE_REGISTRY_PASSWORD
    builder:
      arch: amd64
    env:
      secret:
        - FIXTURE_APP_SECRET
    accessories:
      sync:
        image: fixture/sync
        host: 10.0.0.1
        env:
          secret:
            - FIXTURE_ACCESSORY_SECRET
  YAML

  # The same shape with every secret reference taken out: a registry password given as a literal
  # String is a value, not a secret (Registry#lookup reads only the Array form).
  NO_SECRETS = <<~YAML.freeze
    service: fixture
    image: fixture/app
    servers:
      web:
        - 10.0.0.1
    registry:
      username: fixture
      password: a-literal-not-a-secret
    builder:
      arch: amd64
  YAML

  # `-d solo`. env.secret is an ARRAY, which kamal REPLACES on merge, so this list is the whole of the
  # app's own; `accessories:` and `proxy:` it does not mention, so the base's are merged in unchanged.
  OVERLAY = <<~YAML.freeze
    env:
      secret:
        - FIXTURE_OVERLAY_SECRET
  YAML

  test "required walks the MERGED config on disk and finds every planted secret, under -d too" do
    with_fixture do |root|
      config = root.join("config/deploy.yml")

      assert_equal %w[FIXTURE_ACCESSORY_SECRET FIXTURE_APP_SECRET FIXTURE_REGISTRY_PASSWORD
                      FIXTURE_TLS_CERTIFICATE_PEM FIXTURE_TLS_PRIVATE_KEY_PEM],
                   Tinkerex::DeploySecrets.required(nil, config_file: config).sort
      # The overlay's env.secret REPLACED the base's (FIXTURE_APP_SECRET is gone), while the accessory's
      # secret and the TLS pair are still required: the overlay names neither block, so the base's
      # are merged in. No real overlay redeclares `accessories:` either, which is why SECRET_KEY_BASE
      # is needed by every real destination (docs/invariants/deploy-secrets.md).
      assert_equal %w[FIXTURE_ACCESSORY_SECRET FIXTURE_OVERLAY_SECRET FIXTURE_REGISTRY_PASSWORD
                      FIXTURE_TLS_CERTIFICATE_PEM FIXTURE_TLS_PRIVATE_KEY_PEM],
                   Tinkerex::DeploySecrets.required("solo", config_file: config).sort
    end
  end

  # "0 secrets, all fine" is the one wrong answer a preflight must never give: it reads as a pass.
  test "required refuses a config whose walk finds no secret at all" do
    with_fixture(deploy: NO_SECRETS) do |root|
      error = assert_raises(RuntimeError) do
        Tinkerex::DeploySecrets.required(nil, config_file: root.join("config/deploy.yml"))
      end
      assert_match(/no secret keys resolved for base/, error.message)
    end
  end

  # ONE LIST, AND IT IS THE DEPLOY FILES'. A destination with a config/deploy.<name>.yml but no entry
  # here is one `bin/secrets-preflight --all` never checks and `bin/secrets-preflight <name>` refuses;
  # an entry with no file is the `remote` that Arc D Part 2 folded away, which kamal answers with
  # "Configuration file not found". config/deploy.r2.example.yml is a reference FRAGMENT (its own
  # header: "not a complete Kamal config"), never a destination, so an `.example` overlay is excluded
  # by its name rather than by listing which files to skip.
  test "DESTINATIONS is exactly the destinations config/ holds a deploy file for" do
    assert Rails.root.join("config/deploy.yml").file?, "config/deploy.yml (the base, no -d) is missing"
    overlays = Rails.root.glob("config/deploy.*.yml").map { |path| path.basename(".yml").to_s.delete_prefix("deploy.") }
                        .reject { |name| name.end_with?(".example") }
    assert_not_empty overlays, "no config/deploy.<destination>.yml found — has the deploy config moved?"

    assert_equal [ nil, *overlays ].sort_by(&:to_s), Tinkerex::DeploySecrets::DESTINATIONS.sort_by(&:to_s),
                 "Tinkerex::DeploySecrets::DESTINATIONS must name the base (nil) and every config/deploy.<name>.yml"
  end

  test "bin/secrets-preflight blocks the deploy on the planted secrets, resolving through the shared walk" do
    with_fixture do |root|
      out, status = preflight(root)

      assert_not status.success?, out
      %w[FIXTURE_ACCESSORY_SECRET FIXTURE_TLS_CERTIFICATE_PEM FIXTURE_TLS_PRIVATE_KEY_PEM].each do |planted|
        assert_match(/^  MISSING     #{planted}\b/, out, "the preflight never collected the planted #{planted}")
      end
      assert_match(/^  ok          FIXTURE_APP_SECRET \(17 bytes\)$/, out)
      assert_match(/^FAILED: base$/, out)
      assert_not_includes out, "fixture-app-value", "the preflight printed a secret's VALUE"
    end
  end

  test "bin/secrets-preflight refuses an unknown destination, naming exactly DESTINATIONS" do
    with_fixture do |root|
      out, status = preflight(root, "nonesuch")

      assert_not status.success?, out
      known = Tinkerex::DeploySecrets::DESTINATIONS.map { |destination| destination || "base (omit)" }.join(", ")
      assert_includes out, "Unknown destination(s): nonesuch. Known: #{known}."
    end
  end

  private

  def with_fixture(deploy: DEPLOY)
    Dir.mktmpdir("deploy-secrets") do |dir|
      root = Pathname.new(dir)
      root.join("config").mkpath
      root.join(".kamal").mkpath
      root.join("config/deploy.yml").write(deploy)
      root.join("config/deploy.solo.yml").write(OVERLAY)
      root.join(".kamal/secrets-common").write("FIXTURE_REGISTRY_PASSWORD=fixture-registry-value\n")
      root.join(".kamal/secrets").write("FIXTURE_APP_SECRET=fixture-app-value\n")
      yield root
    end
  end

  # THE REAL SCRIPT, AGAINST THE FIXTURE AND NOTHING ELSE. It reads config/deploy.yml and
  # .kamal/secrets* relative to its working directory, which is the fixture, whose secrets files hold
  # literals (no `$(…)` to run). PATH is ruby's own bin directory alone, so even a preflight that
  # wandered back to the real .kamal/secrets* could not find bin/secret's bash, `op` or `cat`: every
  # `$(…)` would come back empty. Vault-free by construction, not by argument.
  def preflight(root, *args)
    env = { "PATH" => File.dirname(RbConfig.ruby), "OP_SERVICE_ACCOUNT_TOKEN" => nil }
    Open3.capture2e(env, RbConfig.ruby, PREFLIGHT.to_s, *args, chdir: root.to_s)
  end
end
