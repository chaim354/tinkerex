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

  test "the OVH overlay clears every Unraid-host-only service URL it cannot reach" do
    # Kamal DEEP-MERGES env.clear (a hash), so the overlay inherits deploy.yml's accessory hostnames.
    # Those resolve only on the Unraid host, where the accessories actually run. Inheriting one makes
    # `configured?` true and every call fail — worse than the addon showing as unavailable.
    base    = YAML.load_file(ROOT.join("config/deploy.yml"),     aliases: true)
    overlay = YAML.load_file(ROOT.join("config/deploy.ovh.yml"), aliases: true)
    # Every env var naming a service that runs as an accessory on the UNRAID host. `_SIDECAR_URL` was
    # the original pattern; ADDON_SOURCE_URL joined it in Phase B and does NOT match that suffix, so
    # it was silently unguarded until this line was widened. Any future accessory URL must be added
    # here — the failure mode is identical for all of them: OVH deep-merges the Unraid hostname, the
    # service reports configured, and every call fails.
    host_only_url_keys = base.dig("env", "clear").to_h.keys.grep(/_SIDECAR_URL\z|\AADDON_SOURCE_URL\z/)
    assert_equal 3, host_only_url_keys.size,
                 "expected BOXES_SIDECAR_URL, OPENSCAD_SIDECAR_URL and ADDON_SOURCE_URL in deploy.yml"

    cleared = overlay.dig("env", "clear").to_h
    host_only_url_keys.each do |key|
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
    # Discovery is every sidecar/*/Dockerfile, full stop — every sidecar here is GPL by construction
    # (that is why they are sidecars invoked over HTTP instead of libraries we link). Earlier this
    # filtered discovery down to "has a LICENSE beside it", which conflates "this licence needs
    # copying into the image" with "this licence was ever committed at all", and silently skipped
    # exactly the worse case: a future sidecar whose author never added a LICENSE file passed with
    # an unchanged assertion count, because the missing file is what the filter used to exclude it.
    sidecars = ROOT.glob("sidecar/*/Dockerfile")
    assert sidecars.any?, "expected at least one sidecar/<name>/Dockerfile"

    # A missing LICENSE is checked BEFORE, and separately from, the per-Dockerfile COPY check below
    # — the two failures mean different things and want different fixes. A Dockerfile with no COPY
    # line still has the licence text SOMEWHERE in the repo, one line away from being fixed; a
    # sidecar with no LICENSE file at all has never had the licence checked in, is being built and
    # pushed under GPL with no licence to point to anywhere, and there is nothing yet for the COPY
    # check below to even ask about. That is the more serious §9 lapse, and it is the one a
    # presence-filtered discovery step would hide from itself.
    missing_licence = sidecars.reject { |df| df.dirname.join("LICENSE").exist? }
    assert missing_licence.empty?,
           "sidecar Dockerfile(s) with no sibling LICENSE file: " \
           "#{missing_licence.map { |df| df.dirname.basename }.join(', ')} — a GPL sidecar's " \
           "licence text must be committed to the repo before the image is ever built and pushed " \
           "(CLAUDE.md §9)."

    sidecars.each do |dockerfile|
      name = dockerfile.dirname.basename.to_s
      copies_licence = dockerfile.read.lines.any? { |l| l.start_with?("COPY") && l.include?("LICENSE") }
      assert copies_licence,
             "sidecar/#{name}/Dockerfile must COPY its LICENSE into the image — we push this image, " \
             "which is redistribution (CLAUDE.md §9). sidecar/openscad is the pattern to copy."
    end
  end

  # ── .kamal/secrets* ────────────────────────────────────────────────────────────────────────
  # Kamal reads [secrets-common, secrets.<destination>] and NEVER executes these files in the
  # Rails process, so nothing else in the suite can see a mistake in them. All three tests below
  # are STATIC — they read the files as text and never run a `$(…)`, so they need no unlocked
  # vault and pass on a runner with no 1Password at all.

  # nil is the base destination (`kamal deploy` with no -d), whose file is plain `.kamal/secrets`.
  SECRETS_FILES = { nil => "secrets", "s3" => "secrets.s3", "share" => "secrets.share",
                    "ovh" => "secrets.ovh" }.freeze

  # Key/value pairs a secrets file DEFINES, parsed without executing anything.
  def secret_definitions(name)
    path = ROOT.join(".kamal", name)
    return {} unless path.exist?

    path.read.lines.filter_map { |line|
      stripped = line.strip
      next if stripped.empty? || stripped.start_with?("#")

      key, separator, value = stripped.partition("=")
      next if separator.empty? || !key.match?(/\A[A-Z_][A-Z0-9_]*\z/)

      [ key, value ]
    }.to_h
  end

  # Straight from the MERGED deploy config, so this cannot drift from what kamal will look up.
  # env.secret is an array and kamal REPLACES arrays on merge (it unions hashes only) — reading
  # the merged config means that replacement is reflected rather than re-implemented here.
  def required_secret_keys(destination)
    require "kamal"
    config = Kamal::Configuration.create_from(
      config_file: ROOT.join("config/deploy.yml"), destination: destination
    )
    raw = config.raw_config
    # STRING keys, and that is not interchangeable with symbols here: raw_config is an
    # ActiveSupport::InheritableOptions whose `dig(:env, :secret)` returns nil while
    # `dig("env", "secret")` returns the list. A symbol-keyed version of this method returns [] for
    # every destination, which makes both tests below pass while asserting NOTHING — caught only
    # because minitest reported "Test is missing assertions" on the first one.
    keys = Array(raw.dig("env", "secret")) + Array(raw.dig("registry", "password"))
    raise "no secret keys resolved for #{destination || 'base'} — raw_config shape changed?" if keys.empty?

    keys.uniq
  end

  test "every secret a destination declares is defined in a file that destination actually reads" do
    SECRETS_FILES.each do |destination, filename|
      available = secret_definitions("secrets-common").keys | secret_definitions(filename).keys

      required_secret_keys(destination).each do |key|
        assert_includes available, key,
                        "#{destination || 'base'} declares #{key} in its deploy config but no " \
                        "secrets file it reads defines it. Kamal reads ONLY " \
                        "[.kamal/secrets-common, .kamal/#{filename}] for this destination — in " \
                        "particular `.kamal/secrets` is NOT read when -d is passed."
      end
    end
  end

  test "secrets-common defines only keys that EVERY destination needs" do
    # Not tidiness — a correctness rule. Kamal expands secrets with ::Dotenv.parse, and
    # Kamal::Secrets::Dotenv::InlineCommandSubstitution runs every `$(…)` in a parsed file
    # EAGERLY rather than lazily per key fetched. secrets-common is read by every destination, so
    # a destination-specific credential parked here makes `kamal deploy -d share` shell out for a
    # credential a share container never holds — a pointless vault hit that can prompt, hang, or
    # fail for something the deploy does not even use. Put it in the destination's own file.
    universal = SECRETS_FILES.keys.map { |d| required_secret_keys(d) }.reduce(:&)

    secret_definitions("secrets-common").each_key do |key|
      assert_includes universal, key,
                      "#{key} is defined in .kamal/secrets-common but is not required by every " \
                      "destination (#{universal.sort.join(', ')} are). Move it to the .kamal/" \
                      "secrets.<destination> file(s) that need it — every destination parses and " \
                      "EXECUTES everything in secrets-common."
    end
  end

  test "no .kamal secrets file contains a literal credential" do
    # These files are committed, so "safe for git" has to be enforced rather than asserted in a
    # comment at the top of each one. Every value must be a shell expansion — `$(bin/secret …)`,
    # `$(cat …)` or `$VAR` — which is exactly the property that keeps the credential itself out of
    # the repo while the reference to it stays readable.
    ([ "secrets-common" ] + SECRETS_FILES.values).each do |filename|
      secret_definitions(filename).each do |key, value|
        assert_match(/\A\$[({A-Z_]/, value,
                     "#{key} in .kamal/#{filename} looks like a literal value. Secrets files are " \
                     "committed to git — use $(bin/secret #{key} 'op://Vault/Item/field') so the " \
                     "reference is tracked and the credential is not.")
      end
    end
  end
end
