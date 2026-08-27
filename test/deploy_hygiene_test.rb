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

  # The four Unraid destinations and the backend name each one's hostnames are built from. "remote"
  # (Arc D Task 2, LIBRARY_BACKEND=chunk_remote) joined chunk/share/s3 here the same way s3 once
  # joined chunk/share — same host, own container, own proxy hostnames. OVH is absent on purpose: it
  # sets no `proxy` block, so it INHERITS the base's (verified pre-existing — it read
  # ["chunk.tinkerex.local"] before .home was added and ["chunk.tinkerex.local",
  # "chunk.tinkerex.home"] after). That inheritance looks wrong for an internet-facing host with
  # FORCE_SSL=1, but it is a separate question from this guard and predates it.
  # THREE AGAIN, AND THE BASE ONE IS THE CHUNK-FAMILY DESTINATION. `remote` was a fourth entry
  # (Arc D Part 1, LIBRARY_BACKEND=chunk_remote beside embedded chunk); Part 2 retired embedded
  # chunk and folded remote into the base, so the base's hostnames are still `chunk.tinkerex.*` --
  # it IS the chunk backend, now remote-backed -- and there is no separate `remote` config file to
  # read. Kamal raises rather than returning nil for a missing destination file, which is how this
  # surfaced: four errors naming config/deploy.remote.yml.
  UNRAID_DESTINATIONS = { nil => "chunk", "share" => "share", "s3" => "s3" }.freeze

  test "every Unraid destination registers BOTH a .local and a .home hostname" do
    # kamal-proxy routes on the Host header, so a name that is not in this list is a 404 — including
    # a name a front proxy (nginx/NPM) forwards, since it passes the original Host through.
    #
    # WHY TWO NAMES, and why neither may be dropped:
    #   .local  — what every existing client already reaches these by, via /etc/hosts. Removing it
    #             breaks all of them at once.
    #   .home   — the one a phone can reach. `.local` is reserved for mDNS (RFC 6762): macOS and iOS
    #             resolve it through Bonjour and NEVER consult the configured resolver, so a DNS
    #             rewrite for a `.local` name (AdGuard, or anything else) is silently ignored on
    #             exactly the devices that cannot edit /etc/hosts. Drop .home and remote access dies
    #             on every phone while every LAN client stays green — invisible from a desktop.
    #
    # Asserted off the MERGED kamal config, not by re-reading the YAML: `hosts` is an ARRAY, and
    # kamal's deep_merge REPLACES arrays rather than unioning them (unlike env.clear, a hash). That
    # replacement is the reason three destinations do not collide into one another's names, so it is
    # the merged result that has to be right, not the file.
    UNRAID_DESTINATIONS.each do |destination, backend|
      hosts = proxy_hosts(destination)

      assert_equal [ "#{backend}.tinkerex.local", "#{backend}.tinkerex.home" ].sort, hosts.sort,
                   "#{destination || 'base'} must register exactly #{backend}.tinkerex.local AND " \
                   "#{backend}.tinkerex.home. Note `proxy: host:` (singular) can only express one " \
                   "name — use `proxy: hosts:` (plural, a list)."
    end
  end

  test "no two Unraid destinations claim the same hostname" do
    # One box, one kamal-proxy, three containers. Kamal does not detect a duplicate host: the last
    # deploy silently wins the name and the losing backend becomes unreachable under it, which reads
    # as "the deploy worked but I'm looking at the wrong library" rather than as an error.
    all = UNRAID_DESTINATIONS.keys.flat_map { |destination| proxy_hosts(destination) }

    # `tally`, NOT `all - all.uniq`: Array#- removes EVERY occurrence of a matched element, so that
    # expression is always [] and the message names nothing. The assertion still fires correctly
    # either way, which is exactly why this went unnoticed until the guard was mutation-checked.
    duplicates = all.tally.select { |_, count| count > 1 }.keys

    assert_empty duplicates,
                 "two destinations registered the same proxy hostname: #{duplicates.inspect} — " \
                 "one box, one kamal-proxy, so the last deploy silently wins the name"
  end

  test "the OVH overlay clears every Unraid-host-only service URL it cannot reach" do
    # Kamal DEEP-MERGES env.clear (a hash), so the overlay inherits deploy.yml's accessory hostnames.
    # Those resolve only on the Unraid host, where the accessories actually run. Inheriting one makes
    # `configured?` true and every call fail — worse than the addon showing as unavailable.
    base    = YAML.load_file(ROOT.join("config/deploy.yml"),     aliases: true)
    overlay = YAML.load_file(ROOT.join("config/deploy.ovh.yml"), aliases: true)
    # Every env var naming a service that runs as an accessory on the UNRAID host. `_SIDECAR_URL` was
    # the original pattern; ADDON_SOURCE_URL joined it in Phase B and does NOT match that suffix, so
    # it was silently unguarded until this line was widened (CLAUDE.md §14c records exactly that).
    # CHUNK_REMOTE_URL joined it the same way in Arc D Task 2 — also doesn't match `_SIDECAR_URL`, so
    # the pattern was widened again, in the same commit that added the key, rather than trusting a
    # future editor to remember. Any future accessory URL must be added here — the failure mode is
    # identical for all of them: OVH deep-merges the Unraid hostname, the service reports configured,
    # and every call fails.
    host_only_url_keys = base.dig("env", "clear").to_h.keys
      .grep(/_SIDECAR_URL\z|\AADDON_SOURCE_URL\z|\ACHUNK_REMOTE_URL\z/)
    assert_equal 4, host_only_url_keys.size,
                 "expected BOXES_SIDECAR_URL, OPENSCAD_SIDECAR_URL, ADDON_SOURCE_URL and " \
                 "CHUNK_REMOTE_URL in deploy.yml"

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

  test "every sidecar build script bakes the source revision into the image" do
    # WHAT THIS COVERS, AND — the more important half — WHAT IT CANNOT.
    # It reads the build scripts as TEXT and asserts only that each one passes an
    # `org.opencontainers.image.revision` label whose value is computed rather than written down.
    # Nothing in `bin/ci` builds or pushes a Docker image, so this test does NOT and CANNOT show
    # that the pushed image carries the label, or that the accessory running on the box carries one.
    # Read it as "the scripts still ask for provenance", never as "provenance is present".
    #
    # WHY THE LABEL AT ALL: both scripts push `:latest` and config/deploy.yml pulls `:latest`, so
    # before this there was nothing on the box that could name the build it was running — and for
    # sidecar/openscad that matters twice over, because assert-capabilities.sh runs ONLY inside its
    # own Dockerfile (`bin/ci` never executes it), making those assertions the image's only gate.
    # A git-SHA TAG does not close it: the OCI distribution API has no digest->tag reverse lookup,
    # and `kamal accessory details` is `docker ps`, which prints `:latest` rather than a digest. The
    # label answers from the container itself. An extra `-t <sha>` is fine beside it and is NOT
    # asserted here — it is inventory, not the mechanism.
    #
    # DIRECTORY-DRIVEN, never a hard-coded pair, for the reason the licence test above records: a
    # third sidecar's build script is covered the day it appears, not the day someone remembers.
    scripts = ROOT.glob("bin/build-*-sidecar")
    assert scripts.any?, "expected at least one bin/build-<name>-sidecar"

    scripts.each do |script|
      where = script.relative_path_from(ROOT)
      label = script.read[/--label\s+"?org\.opencontainers\.image\.revision=([^"'\s]*)/, 1]

      assert label,
             "#{where} must pass --label org.opencontainers.image.revision=… to docker buildx " \
             "build. Without it a running accessory cannot name the build it came from: both " \
             "scripts push :latest and config/deploy.yml pulls :latest, and no tag scheme can " \
             "recover it (no digest->tag reverse lookup; `kamal accessory details` is docker ps)."
      # A LITERAL VALUE WOULD SATISFY THE LINE ABOVE AND MEAN NOTHING — a pasted SHA goes stale on
      # the next commit, silently, and a stale provenance label is worse than none because it is
      # believed. Requiring a shell expansion is the narrowest way to say "computed at build time".
      assert_includes label, "$",
                      "#{where}'s revision label must be computed from the tree at build time " \
                      "(a shell expansion), not a literal — got #{label.inspect}."
    end
  end

  # ── third-party catalogs bundled INSIDE a sidecar image ───────────────────────────────────────
  #
  # WHY THIS IS HERE, AND WHY IT IS NOT A SECOND COPY OF sidecar/openscad/tests/test_catalog.py.
  # `bin/ci` has EIGHT gates (setup, style, scan, test, test-share, test-s3, system, test-app) and
  # NONE of
  # them runs pytest — nothing in config/ci.rb or .github/workflows does. So the Python guards on
  # this data are real, thorough and mutation-checked, and they DO NOT RUN in the gate that decides
  # whether a branch ships; they run by hand, inside the image. Until openscad migrated, the only
  # licence guard `bin/ci` actually executed was
  # `test/controllers/tools/openscad_controller_test.rb`'s "index shows each bundled generator's
  # licence on its OWN tile" — and that died with the controller. This is its replacement, and it is
  # the FIRST RUNNING COPY rather than a duplicate.
  #
  # IT DELIBERATELY GUARDS THE DATA, NOT THE RENDERING. The retired assertion checked that a licence
  # string reached a tile in a Rails view; there is no such view any more — the OpenSCAD UI is a
  # bundle in chaim354/tinkerex-addons, and a guard on its markup has to live there (CLAUDE.md
  # §14c). What can be guarded here is stronger anyway, because it sits UPSTREAM of every renderer:
  # if a catalogued .scad carries no licence, no bundle anywhere can display one, and a display test
  # would faithfully render an empty string and stay green.
  #
  # AND THIS REPO IS THE REDISTRIBUTOR. These .scad files are baked into the GPL sidecar image we
  # build and push to a registry — the same act the licence test above exists for. The obligation is
  # ours at the moment that image is built, which is here.
  #
  # DIRECTORY-DRIVEN, for the reason the test above spells out: a second sidecar that ever bundles
  # third-party sources is covered the day it appears, not the day someone remembers.
  CATALOG_GLOB = "sidecar/*/catalog/catalog.json".freeze

  # Spec §2: PERMISSIVE ONLY. Tinkerex is sold AND this image is redistributed to self-hosters, so
  # both "commercial use" and "redistribution" have to be permitted — which NonCommercial,
  # ShareAlike and the GPL family each break.
  #
  # THE NEEDLES ARE LOWERCASE BECAUSE THE HAYSTACK IS LOWERCASED, and that is a bug fix carried
  # across from the Python guard rather than a style choice. That list was originally written
  # ("-NC", "-SA", …) and compared against `.lower()`ed text, so `"-NC" in "cc-by-nc-sa-4.0"` was
  # false and THE TWO TERMS THE CATALOG EXISTS TO EXCLUDE COULD NEVER MATCH. Reproducing that
  # mistake here would be free, so the self-test below exists to make it impossible.
  FORBIDDEN_LICENCE_TERMS = %w[-nc noncommercial -sa sharealike gpl agpl lgpl].freeze

  def forbidden_licence?(licence)
    low = licence.to_s.downcase
    FORBIDDEN_LICENCE_TERMS.any? { |term| low.include?(term) }
  end

  def catalogs
    ROOT.glob(CATALOG_GLOB).map { |path| [ path, JSON.parse(path.read) ] }
  end

  test "every bundled third-party generator records a permissive licence and attribution" do
    found = catalogs
    # NOT A VACUOUS PASS. A sweep that discovers nothing reports success, which is exactly the
    # failure shape the sidecar-licence test above records ("a discovery filter silently skipped the
    # worse case"). If the catalog is ever moved or renamed, this line is what says so.
    refute_empty found, "expected at least one #{CATALOG_GLOB} — has the catalog moved?"

    found.each do |path, entries|
      where = path.relative_path_from(ROOT)
      refute_empty entries, "#{where} is empty"
      entries.each do |entry|
        key = entry["key"].to_s
        # ALL THREE, because they answer different questions and only together do they let any
        # downstream renderer state the terms: WHAT the licence is, WHO to credit, and WHICH commit
        # the bytes came from.
        assert entry["license"].present?,     "#{where}: #{key} has no licence"
        assert entry["attribution"].present?, "#{where}: #{key} has no attribution"
        assert entry["source_ref"].present?,  "#{where}: #{key} has no pinned upstream commit"
        refute forbidden_licence?(entry["license"]),
               "#{where}: #{key} declares #{entry['license'].inspect}, which spec §2 forbids in a " \
               "redistributed commercial image (CLAUDE.md §9)"
      end
    end
  end

  # THE GUARD IS ONLY WORTH HAVING IF IT CAN GO RED, and the Python original could not (see
  # FORBIDDEN_LICENCE_TERMS). These are real spellings, not invented ones: CC-BY-NC-SA-4.0 is what
  # the REJECTED `universal_stand` declares in its own header while its repo LICENSE file says MIT
  # — sidecar/openscad/catalog/NOTICE tells that story at length — and it is the single string this
  # check most needs to reject.
  test "the forbidden-licence matcher rejects what it names and admits what spec §2 allows" do
    %w[CC-BY-NC-SA-4.0 CC-BY-NC-4.0 CC-BY-SA-4.0 GPL-2.0 GPL-3.0 AGPL-3.0 LGPL-2.1
       NonCommercial ShareAlike].each do |bad|
      assert forbidden_licence?(bad), "the matcher failed to reject #{bad}"
    end
    # …and the permissive set must SURVIVE it, or the check merely blocks everything and the
    # assertion above proves nothing about where the line actually is.
    %w[MIT Apache-2.0 BSD-3-Clause BSD-2-Clause CC0-1.0 CC-BY-4.0 Unlicense].each do |ok|
      refute forbidden_licence?(ok), "the matcher wrongly rejected #{ok}"
    end
  end

  test "no bundled source file is redistributed without a catalog record and a NOTICE credit" do
    catalogs.each do |path, entries|
      dir = path.dirname
      where = path.relative_path_from(ROOT)
      listed = entries.map { |e| e["file"].to_s }.to_set

      # BOTH DIRECTIONS. The catalog naming a file that is not there is a broken build; a file that
      # IS there and is not in the catalog is the worse case and is invisible from the other side —
      # it ships inside the image with no licence record anywhere.
      listed.each { |file| assert dir.join(file).exist?, "#{where}: #{file} is listed but missing" }
      on_disk = dir.glob("*.scad").map { |f| f.basename.to_s }.to_set
      assert_equal listed, on_disk,
                   "#{where}: unlisted .scad file(s) #{(on_disk - listed).to_a.inspect} would be " \
                   "redistributed with no licence record at all"

      # The NOTICE is the human-readable half of the same obligation, and it has to name the exact
      # commit — "some version of this file" is not a provenance record.
      notice = dir.join("NOTICE")
      assert notice.exist?, "#{where.dirname}/NOTICE is missing"
      text = notice.read
      entries.each do |entry|
        assert_includes text, entry["file"].to_s,
                        "#{entry['file']} is bundled but not credited in NOTICE"
        assert_includes text, entry["source_ref"].to_s,
                        "#{entry['file']}'s pinned commit is not recorded in NOTICE"
      end
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

  # The hostnames kamal-proxy will actually route for a destination, read off the MERGED config for
  # the same reason required_secret_keys does — so array-replacement semantics are reflected here
  # rather than re-implemented.
  def proxy_hosts(destination)
    require "kamal"
    Kamal::Configuration.create_from(
      config_file: ROOT.join("config/deploy.yml"), destination: destination
    ).proxy.hosts
  end

  # Straight from the MERGED deploy config, so the ANSWER cannot drift from what kamal will look
  # up. env.secret is an array and kamal REPLACES arrays on merge (it unions hashes only) —
  # reading the merged config means that replacement is reflected rather than re-implemented here.
  def required_secret_keys(destination)
    require "kamal"
    config = Kamal::Configuration.create_from(
      config_file: ROOT.join("config/deploy.yml"), destination: destination
    )
    keys = secret_key_names(config.raw_config)
    raise "no secret keys resolved for #{destination || 'base'} — raw_config shape changed?" if keys.empty?

    keys
  end

  # STRING keys throughout, and that is not interchangeable with symbols: raw_config is an
  # ActiveSupport::InheritableOptions whose `dig(:env, :secret)` returns nil while
  # `dig("env", "secret")` returns the list (the nesting below it is plain string-keyed Hashes). A
  # symbol-keyed version returns [] for every destination, which makes the tests below pass while
  # asserting NOTHING — caught only because minitest reported "Test is missing assertions".
  def at(node, *path)
    path.reduce(node) { |value, key| value.is_a?(Hash) ? value[key] : nil }
  end

  # EVERY PLACE KAMAL 2.12.0 RESOLVES A SECRET. The LIST OF SITES is hand-maintained — that is the
  # part that drifted, while both this method and bin/secrets-preflight's twin claimed it could
  # not: they collected `env.secret + registry.password`, two of NINE. Latent on today's config,
  # but a `builder: secrets:` block or an accessory `env.secret` walks straight past both guards.
  # `secret_key_names covers every site kamal reads` below plants a name at each arm; widen that
  # test and bin/secrets-preflight in the same commit as this method.
  #
  # Reads the config only — no secret is resolved. Verified by fencing Dotenv.parse and
  # Kamal::Secrets#[]/#key?/#to_h to raise and building all four destinations: the fence never
  # trips, which is what keeps every test in this file STATIC and vault-free.
  def secret_key_names(raw)
    roles       = at(raw, "servers").is_a?(Hash)     ? at(raw, "servers").values     : []
    accessories = at(raw, "accessories").is_a?(Hash) ? at(raw, "accessories").values : []

    # env.secret — root (env.rb:35), per env tag (configuration.rb:286), per role (role.rb:20),
    # per accessory (accessory.rb:126). An entry may be `VAR:SECRET`; kamal looks up the part AFTER
    # the colon (Env#extract_alias) — the first half names the container's env var, not a key.
    envs = [ at(raw, "env"), *at(raw, "env", "tags").to_h.values,
             *roles.map { |role| at(role, "env") }, *accessories.map { |acc| at(acc, "env") } ]
    keys = envs.flat_map { |env| Array(at(env, "secret")) }.map { |key| key.to_s.split(":", 2).last }

    # registry password AND username — root (registry.rb:35) and per accessory (accessory.rb:141).
    # ONLY the Array form is a secret reference (Registry#lookup); a bare String is the literal
    # value, which `username: chaim354` in deploy.yml is. Collecting that would demand a secret
    # named "chaim354" and block every deploy.
    registries = [ at(raw, "registry"), *accessories.map { |acc| at(acc, "registry") } ]
    keys += registries.flat_map { |reg| [ at(reg, "password"), at(reg, "username") ] }
                      .grep(Array).map(&:first)

    # Custom proxy TLS material — root and per role (proxy.rb:41,47), per accessory
    # (accessory.rb:135). A role's `proxy:` specialization can be `true`/`false`, not a hash.
    proxies = [ at(raw, "proxy"), *roles.map { |role| at(role, "proxy") },
                *accessories.map { |acc| at(acc, "proxy") } ]
    keys += proxies.flat_map { |p| [ at(p, "ssl", "certificate_pem"), at(p, "ssl", "private_key_pem") ] }

    # builder.secrets (builder.rb:73) — the raw key LIST, never `config.builder.secrets`, which
    # eagerly resolves each one through `config.secrets[key]` and would make this file need a vault.
    keys += Array(at(raw, "builder", "secrets"))

    # ssh.key_data (ssh.rb:43-44). Kamal treats an entry the secrets do not define as an INLINE
    # literal key, so that deprecated spelling is reported MISSING rather than skipped — loud beats
    # an empty key reaching an ssh handshake, and kamal 3 removes the inline form outright.
    keys += Array(at(raw, "ssh", "key_data"))

    keys.compact.uniq
  end

  test "secret_key_names covers every site kamal reads a secret from" do
    # The real config exercises three arms; the other six are empty in it, so only a synthetic
    # config can show they are reached at all. Set EQUALITY, not inclusion — the two decoys below
    # are half of what this pins, and an over-collecting version fails LOUD but it still fails:
    # every name it invents is reported MISSING and blocks the deploy.
    raw = {
      "env" => { "secret" => [ "ROOT_ENV", "CONTAINER_VAR:ALIASED_ENV" ],
                 "tags" => { "beta" => { "secret" => [ "TAG_ENV" ] } } },
      "servers" => {
        "web" => [ "10.0.0.1" ],                          # a bare host list, not a hash
        "job" => { "env" => { "secret" => [ "ROLE_ENV" ] },
                   "proxy" => { "ssl" => { "certificate_pem" => "ROLE_CERT",
                                           "private_key_pem" => "ROLE_KEY" } } },
        "cron" => { "proxy" => true }                     # a specialization that is not a hash
      },
      "registry" => { "username" => [ "ROOT_REGISTRY_USERNAME" ],
                      "password" => [ "ROOT_REGISTRY_PASSWORD" ] },
      "proxy" => { "ssl" => { "certificate_pem" => "ROOT_CERT", "private_key_pem" => "ROOT_KEY" } },
      "builder" => { "secrets" => [ "BUILDER_SECRET" ] },
      "ssh" => { "key_data" => [ "SSH_KEY_DATA" ] },
      "accessories" => {
        "sidecar" => { "env" => { "secret" => [ "ACCESSORY_ENV" ] },
                       "registry" => { "username" => "a-literal-not-a-secret",
                                       "password" => [ "ACCESSORY_REGISTRY_PASSWORD" ] },
                       "proxy" => { "ssl" => { "certificate_pem" => "ACCESSORY_CERT",
                                               "private_key_pem" => "ACCESSORY_KEY" } } },
        "bare" => { "image" => "nginx" }                  # no env, no registry, no proxy
      }
    }

    assert_equal %w[
      ACCESSORY_CERT ACCESSORY_ENV ACCESSORY_KEY ACCESSORY_REGISTRY_PASSWORD ALIASED_ENV
      BUILDER_SECRET ROLE_CERT ROLE_ENV ROLE_KEY ROOT_CERT ROOT_ENV ROOT_KEY
      ROOT_REGISTRY_PASSWORD ROOT_REGISTRY_USERNAME SSH_KEY_DATA TAG_ENV
    ], secret_key_names(raw).sort,
                 "bin/secrets-preflight and this file each walk the deploy config for the names " \
                 "kamal will resolve. A site dropped from either is a credential that deploys " \
                 "UNCHECKED — the failure the preflight exists to make impossible. Note what is " \
                 "deliberately absent: CONTAINER_VAR (an alias names the env var, the secret is " \
                 "after the colon) and a-literal-not-a-secret (only the Array form of a registry " \
                 "username/password is a secret reference)."
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

  # ── LIBRARY_BACKEND vs the knobs each backend cannot boot without ──────────────────────────────
  # THE CLASS OF BUG THIS CLOSES: a destination's MERGED config resolves a LIBRARY_BACKEND whose
  # required knobs that config does not carry. `kamal deploy -d <dest>` then builds and pushes an
  # image whose container refuses to start on LibraryBackendCheck — a failure that costs a full
  # build to discover and is invisible from the tree, because every file involved looks locally
  # reasonable and only the MERGE is wrong. Nothing checked it until now, which is how the ovh
  # overlay came to inherit chunk_remote (Arc D Part 2 made the base the chunk-family destination)
  # with CHUNK_REMOTE_URL deliberately blanked and — through env.secret's array REPLACEMENT, a
  # second mechanism entirely — no SYNC_ADMIN_TOKEN either.
  #
  # STATIC AND VAULT-FREE like the .kamal tests above: it reads the merged config and resolves
  # nothing, so it passes on a bare runner with no 1Password.

  # THE SAME FOUR DESTINATIONS AS SECRETS_FILES, reused rather than restated — a third list of
  # destinations in this file is a third thing to forget when one is added or folded away (as
  # `remote` was). The set is asserted explicitly below so trimming it cannot retire this guard.
  LIBRARY_DESTINATIONS = SECRETS_FILES.keys.freeze

  # The knobs each backend cannot boot without. The chunk_remote and s3 lists are the PRODUCTION
  # constants, not copies, so a knob added to lib/library_backend_check.rb is enforced here on the
  # same commit. `share` has no such constant (check_share! takes the path as a plain argument), so
  # LIBRARY_PATH is spelled out — the one line here that can drift, and also the whole of what
  # check_share! can be asked statically: its real work is a File.exist? plus a write probe ON THE
  # BOX, which no test in this process can perform.
  #
  # THE KEYS ALSO SERVE AS THE SET OF BACKENDS FileLayer.build ACCEPTS (its `case`, which has no
  # constant to reuse). Deliberate: a destination resolving to anything else — unset, a typo, or
  # the retired `chunk`, which build now REFUSES rather than aliases (§14a) — must fail HERE rather
  # than depend on whatever it happens to inherit. Note check!'s own no-arg default is still
  # "chunk", so an unset value is not self-correcting.
  LIBRARY_BACKEND_REQUIRED = {
    "chunk_remote" => LibraryBackendCheck::CHUNK_REMOTE_REQUIRED,
    "s3"           => LibraryBackendCheck::S3_REQUIRED,
    "share"        => %w[LIBRARY_PATH]
  }.freeze

  # ⚠️ AN EXPLICIT, NAMED EXEMPTION — NOT A SKIP, AND NOT PERMANENT. EMPTY IS THE HEALTHY STATE.
  # `ovh` was the one entry: it declared no LIBRARY_BACKEND of its own, silently inherited the
  # base's chunk_remote, and could not satisfy it — a destination that could not boot at all. That
  # was a PRODUCT DECISION nobody could take from the tree, so it was recorded here rather than by
  # dropping ovh from LIBRARY_DESTINATIONS, which would have retired the guard for that destination
  # silently — the §14e failure this whole file keeps re-learning. Resolved 2026-08-26: ovh declares
  # LIBRARY_BACKEND=s3 against R2, and the entry came out.
  #
  # THE MECHANISM STAYS FOR THE NEXT ONE, AND IT EXPIRED CORRECTLY FOR THIS ONE. The second loop
  # below asserts every exemption is still NEEDED, so the moment a listed destination starts
  # satisfying its backend the test goes RED naming it — observed, not assumed: with ovh fixed and
  # still listed, it failed with "ovh is exempted ... but now satisfies LIBRARY_BACKEND=s3 — DELETE
  # IT FROM THAT LIST". An exemption that cannot expire is how a guard quietly stops covering the
  # thing it was written for.
  UNDECIDED_LIBRARY_BACKEND = [].freeze

  # What would stop this destination's container booting, read off the MERGED config for the same
  # reason required_secret_keys does — array replacement and hash deep-merge are reflected rather
  # than re-implemented. A knob counts as CARRIED if env.clear holds a non-blank value for it OR
  # env.secret names it: kamal injects the latter at deploy from the destination's own secrets file,
  # and the sibling guard above ("every secret a destination declares is defined in a file that
  # destination actually reads") is what proves that file defines it. The two compose; neither
  # alone would catch a knob that is declared secret but never defined.
  def library_backend_shortfall(destination)
    require "kamal"
    raw = Kamal::Configuration.create_from(
      config_file: ROOT.join("config/deploy.yml"), destination: destination
    ).raw_config
    clear   = at(raw, "env", "clear").to_h
    secrets = Array(at(raw, "env", "secret")).map { |key| key.to_s.split(":", 2).last }
    backend = clear["LIBRARY_BACKEND"].to_s

    unless LIBRARY_BACKEND_REQUIRED.key?(backend)
      return { backend: backend,
               problems: [ "its LIBRARY_BACKEND is #{backend.presence.inspect}, which " \
                           "FileLayer.build refuses — expected one of " \
                           "#{LIBRARY_BACKEND_REQUIRED.keys.sort.join(', ')}" ] }
    end

    # blank?, not key? — "" is the same operator error as unset, and it is exactly what the OVH
    # overlay's deliberate CHUNK_REMOTE_URL blanking produces. check_chunk_remote!/check_s3! both
    # reject on `.present?` for the same reason; matching them is what keeps this guard's answer
    # equal to the one the container will give.
    missing = LIBRARY_BACKEND_REQUIRED.fetch(backend)
      .reject { |knob| clear[knob].to_s.present? || secrets.include?(knob) }
    return { backend: backend, problems: [] } if missing.empty?

    # ONE sentence for the whole missing set, not one per knob — check_s3! names all of them in a
    # single message for the same reason: a report that reveals one missing knob at a time makes
    # the operator do N passes to learn N facts already in hand.
    { backend: backend,
      problems: [ "it resolves LIBRARY_BACKEND=#{backend} but carries no value for " \
                  "#{missing.join(', ')}" ] }
  end

  test "every destination carries the knobs its resolved LIBRARY_BACKEND requires" do
    shortfalls = LIBRARY_DESTINATIONS.to_h { |destination| [ destination, library_backend_shortfall(destination) ] }

    # NON-VACUITY, both halves (§14e: a guard whose subject is a list is retired by emptying the
    # list, and assert_empty over nothing passes perfectly). The explicit set pins against someone
    # "fixing" a red destination by deleting it from LIBRARY_DESTINATIONS instead of from
    # UNDECIDED_LIBRARY_BACKEND; the second assertion catches a raw_config shape change that made
    # every lookup nil, which would otherwise report four clean destinations.
    assert_equal [ nil, "ovh", "s3", "share" ], shortfalls.keys.sort_by(&:to_s),
                 "this guard must cover every destination kamal can deploy"
    assert shortfalls.each_value.any? { |result| result[:backend].present? },
           "no destination resolved a LIBRARY_BACKEND at all — raw_config shape changed?"

    shortfalls.each do |destination, result|
      next if UNDECIDED_LIBRARY_BACKEND.include?(destination)

      assert_empty result[:problems],
                   "#{destination || 'base'} would not boot — #{result[:problems].join('; ')}. " \
                   "LibraryBackendCheck refuses that at start, so " \
                   "`kamal deploy#{" -d #{destination}" if destination}` would build and push an " \
                   "image whose container never comes up. Put each knob in that destination's " \
                   "env.clear, or in env.secret WITH a matching .kamal/#{SECRETS_FILES[destination]} line."
    end

    UNDECIDED_LIBRARY_BACKEND.each do |destination|
      result = shortfalls.fetch(destination)

      refute_empty result[:problems],
                   "#{destination} is exempted by UNDECIDED_LIBRARY_BACKEND but now satisfies " \
                   "LIBRARY_BACKEND=#{result[:backend]} — DELETE IT FROM THAT LIST. The exemption " \
                   "only records an open product decision (see config/deploy.ovh.yml's " \
                   "CHUNK_REMOTE_URL comment); left behind once the decision is made, it silently " \
                   "stops guarding the destination it was written for."
    end
  end
end
