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

# EVERY DEMO SEED FILE REACHES THE IMAGE. Tinkerex::DemoReset writes db/seeds/demo from inside the
# container, so a seed file the build context drops is one the reset silently never writes: the
# macOS " 2" duplicate sweep in .dockerignore dropped the catan project's real `laser/game box
# 2.lbrn2` from the first image that shipped it (2026-10-16, tinkerex#384). This applies the file the
# way the builder does: rules in order, a `!` rule re-including, the last match winning, and a rule
# that matches a parent directory excluding everything beneath it. OS clutter is left out because
# the reset skips it anyway (Library::OsClutter).
  def dockerignore_rules
    @dockerignore_rules ||= ROOT.join(".dockerignore").read.lines.map(&:strip).reject { |l| l.empty? || l.start_with?("#") }.map do |line|
      negate = line.start_with?("!")
      [ negate, line.delete_prefix("!").delete_prefix("/").delete_suffix("/") ]
    end
  end

  # Whether the image build drops `rel`, a path relative to the repository root.
  def dockerignored?(rel)
    flags = File::FNM_PATHNAME | File::FNM_DOTMATCH
    parts = rel.split("/")
    prefixes = parts.each_index.map { |i| parts[0..i].join("/") }
    dockerignore_rules.reduce(false) { |out, (negate, pat)| prefixes.any? { |pre| File.fnmatch?(pat, pre, flags) } ? !negate : out }
  end

  test "every demo seed file survives .dockerignore" do
    files = Dir.glob("db/seeds/demo/**/*", File::FNM_DOTMATCH, base: ROOT)
               .select { |rel| ROOT.join(rel).file? }
               .reject { |rel| Library::OsClutter.clutter_segment?(File.basename(rel)) }
    assert_operator files.size, :>, 50, "found too few seed files; did db/seeds/demo move?"

    dropped = files.select { |rel| dockerignored?(rel) }
    assert_empty dropped, ".dockerignore drops these demo seed files from the image: #{dropped.inspect}"
  end

  # THE COMPOSE GENERATOR READS docker-compose.yml AT RENDER TIME (Tinkerex::ComposeTemplate,
  # 2026-10-21), so the image must carry it -- and every test runs from a checkout, where the file is
  # always there, so nothing else would notice the image losing it: /install/compose would answer 500
  # on every deployment behind a green suite. Only the base file is re-included; the build and sync
  # overlays describe a clone's setup and stay out. Mutation-checked: deleting the `!` line goes red.
  test "the image carries docker-compose.yml for the compose generator, and only that compose file" do
    refute dockerignored?("docker-compose.yml"), "add `!/docker-compose.yml` to .dockerignore after `/docker-compose*.yml`"
    assert_equal Tinkerex::ComposeTemplate::SOURCE, ROOT.join("docker-compose.yml")
    %w[docker-compose.build.yml docker-compose.chunk_remote.yml].each do |overlay|
      assert dockerignored?(overlay), "#{overlay} reached the image; only the base compose file is the generator's"
    end
  end

  # The four Unraid destinations and the backend name each one's hostnames are built from. "remote"
  # (Arc D Task 2, LIBRARY_BACKEND=chunk_remote) joined chunk/share/s3 here the same way s3 once
  # joined chunk/share — same host, own container, own proxy hostnames. OVH is absent here because
  # it is not an Unraid destination: it carries its OWN `proxy:` block (the public names and the
  # Cloudflare origin certificate), pinned by "the internet-facing destination routes its public
  # names" below. Until 2026-10-12 it declared none and INHERITED the base's chunk.tinkerex.*
  # names, which is why www.tinkerex.com answered 525 at Cloudflare's edge.
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

  # The one internet-facing destination. Cloudflare (orange cloud, Full strict) terminates the
  # visitor's TLS and opens a SECOND TLS connection to the origin, which succeeds only if
  # kamal-proxy serves a certificate for that SNI — and Cloudflare intercepts the HTTP-01
  # challenge, so kamal-proxy's own ACME can never mint one. The Cloudflare ORIGIN certificate
  # (op://tinkerex/tinkerex-origin) is the only cert that works there, and it reaches the proxy
  # through `proxy.ssl.certificate_pem` / `private_key_pem`, which name SECRETS (resolved from
  # .kamal/secrets.ovh — the secrets test below requires both to be defined there).
  PUBLIC_HOSTS = %w[tinkerex.com www.tinkerex.com].freeze

  test "the internet-facing destination routes its public names with a custom certificate, never a LAN name" do
    # Until 2026-10-12 the OVH overlay declared no `proxy:` block and INHERITED the base's
    # chunk.tinkerex.{local,home} — kamal-proxy then routed only those names, so www.tinkerex.com
    # answered 525 at Cloudflare's edge and a redeploy would have taken the apex down too.
    # (docs/AUDIT-2026-10-12-readiness.md §0.)
    require "kamal"
    ovh = Kamal::Configuration.create_from(
      config_file: ROOT.join("config/deploy.yml"), destination: "ovh"
    ).proxy
    assert_equal PUBLIC_HOSTS.sort, ovh.hosts.sort,
                 "deploy.ovh.yml must carry its own `proxy: hosts:` list (kamal REPLACES arrays " \
                 "on merge, so an overlay list wins; without one it inherits the LAN names)"
    assert ovh.ssl?, "the public host must terminate TLS at kamal-proxy (Cloudflare Full strict)"
    assert ovh.custom_ssl_certificate?,
           "Cloudflare intercepts ACME, so `ssl: true` alone never gets a certificate — name the " \
           "origin cert and key via ssl.certificate_pem / ssl.private_key_pem"

    # With `ssl:` set, kamal-proxy drops the incoming X-Forwarded-* headers unless told to forward
    # them (kamal 2.12 docs/proxy.yml:79-81). Cloudflare puts the visitor there; without this the
    # app sees only the edge node and every per-IP throttle keys on Cloudflare
    # (config/initializers/trusted_proxies.rb). Read off deploy_options so what kamal-proxy is
    # actually told is what is asserted, not a YAML key.
    assert_equal true, ovh.deploy_options[:"forward-headers"],
                 "deploy.ovh.yml must set `proxy: forward_headers: true` beside `ssl:` -- the TLS " \
                 "terminator otherwise discards Cloudflare's X-Forwarded-For and the app sees the edge node"

    lan = UNRAID_DESTINATIONS.keys.flat_map { |destination| proxy_hosts(destination) }
    assert_empty ovh.hosts & lan, "an internet-facing destination must not route a LAN-only name"
  end

  test "every destination names the host its mail links are built from, and kamal-proxy routes that name" do
    # config/environments/production.rb builds confirmation and reset links from APP_HOST and
    # falls back to a loud `.invalid` placeholder. Until 2026-10-12 NO destination set it, so the
    # one link a new maker must click pointed nowhere on every box. Read off the MERGED config so
    # an overlay that forgets it inherits the base's answer rather than passing on a nil — and
    # require the name to be one the destination's proxy actually routes, so a link that is
    # emitted can be followed.
    require "kamal"
    LIBRARY_DESTINATIONS.each do |destination|
      config = Kamal::Configuration.create_from(
        config_file: ROOT.join("config/deploy.yml"), destination: destination
      )
      host = at(config.raw_config, "env", "clear").to_h["APP_HOST"].to_s
      assert host.present?, "#{destination || 'base'}: env.clear must set APP_HOST"
      assert_includes config.proxy.hosts, host,
                      "#{destination || 'base'}: APP_HOST=#{host} is not a name kamal-proxy routes " \
                      "for that destination (#{config.proxy.hosts.inspect}) — a mail link to it 404s"
    end
  end

  test "the sync accessory's device door registers BOTH names, publishes no port, and collides with no destination" do
    # Until 2026-10-07 the sync accessory declared no `port:` and no `proxy:` -- internal-only, so no
    # desktop client could reach production at all (chaim354/tinkerex-sync
    # docs/superpowers/plans/2026-10-07-rust-cutover.md §0.3.2). The door is kamal-proxy, which routes
    # on the Host header, so it inherits the destinations' two-names rule above for the same two
    # reasons -- `.local` is what /etc/hosts clients reach, `.home` is what a phone over Tailscale
    # reaches, and dropping either strands that population. A `port:` would publish 3000 on the box
    # and bypass the proxy's Host routing: the proxy is the one door. Read off the MERGED config like
    # proxy_hosts, so what kamal will register is what is asserted.
    require "kamal"
    sync = Kamal::Configuration.create_from(
      config_file: ROOT.join("config/deploy.yml"), destination: nil
    ).accessory("sync")

    assert sync.running_proxy?, "the sync accessory must carry a proxy: block -- its device door"
    assert_equal %w[sync.tinkerex.local sync.tinkerex.home].sort, sync.proxy.hosts.sort,
                 "the door must register exactly sync.tinkerex.local AND sync.tinkerex.home"
    refute sync.proxy.ssl?, "plain HTTP on the LAN, like every Unraid destination"
    assert_nil sync.port, "no port: -- kamal-proxy is the only door, and it routes on Host"

    # One box, one kamal-proxy: a name registered by two services is silently won by the last deploy.
    UNRAID_DESTINATIONS.each_key do |destination|
      shared = proxy_hosts(destination) & sync.proxy.hosts
      assert_empty shared,
                   "#{destination || 'base'} and the sync accessory both register #{shared.inspect}"
    end
  end

  # THE ADDRESS EVERY DEVICE IS HANDED AT SIGN-IN (D1, 2026-10-13). The maker app answers a desktop
  # login with a sync grant whose URL is SYNC_PUBLIC_URL, so on the base -- the chunk_remote
  # destination -- it must be the door above, derived from the merged config rather than restated:
  # a name kamal-proxy routes to the sync accessory; the `.home` one, which resolves on the LAN and
  # over the tailnet with no /etc/hosts line (`.local` resolves only where one was added by hand --
  # APP_HOST's argument in deploy.yml); and the scheme that door serves. Never CHUNK_REMOTE_URL's
  # http://tinkerex-sync:3000, a name only the kamal network resolves, and no device is on it: the
  # two addresses differ on purpose.
  #
  # THE SCHEME FOLLOWS THE DOOR, AND THE DOOR IS PLAIN HTTP -- `ssl: false` above, and nothing in
  # front of it holds a certificate for the name: measured 2026-10-13, http://sync.tinkerex.home/up
  # answered 200 and https:// failed the TLS handshake ("unrecognized name"). An https URL here would
  # hand every desktop app a door that refuses it while this whole file stayed green. If a front
  # proxy ever terminates TLS for the name, change this assertion together with that measurement.
  #
  # NOT ASSERTED ON share AND s3: kamal deep-merges env.clear, so they inherit this value exactly as
  # they inherit CHUNK_REMOTE_URL, and on a backend that is not syncable nothing reads it.
  test "the base destination hands devices the sync accessory's own door, never the app's internal alias" do
    require "kamal"
    config = Kamal::Configuration.create_from(config_file: ROOT.join("config/deploy.yml"), destination: nil)
    clear = at(config.raw_config, "env", "clear").to_h
    assert_equal "chunk_remote", clear["LIBRARY_BACKEND"].to_s,
                 "the base is the chunk_remote destination -- raw_config shape changed?"

    door = config.accessory("sync").proxy
    home = door.hosts.find { |host| host.end_with?(".home") }
    assert home, "the sync accessory's door registers no .home name: #{door.hosts.inspect}"

    assert_equal "#{door.ssl? ? 'https' : 'http'}://#{home}", clear["SYNC_PUBLIC_URL"].to_s,
                 "SYNC_PUBLIC_URL is what every signing-in device syncs against, so it must be the " \
                 "sync accessory's door as devices reach it -- not CHUNK_REMOTE_URL " \
                 "(#{clear['CHUNK_REMOTE_URL'].inspect}), a name only the kamal network resolves"
  end

  # THE ACCESSORY'S OWN ENV, READ OFF EVERY DESTINATION'S MERGED CONFIG (LIBRARY_DESTINATIONS names
  # all four): `accessories:` is never overlaid, so the base block is what each of them boots.
  # SYNC_SCHEDULER (D3, 2026-10-14) turns on the binary's in-process maintenance, which is OFF unless
  # set -- losing the line is a scheduler that silently never runs, and nothing else would notice.
  # CABLE_ADAPTER and RAILS_LOG_TO_STDOUT were the Ruby image's, and Phase 6 (2026-10-14) retired it,
  # so they are pinned ABSENT: the binary reads neither, and a knob nothing reads is one a reader
  # trusts to do something (CABLE_ADAPTER's own comment once argued that a second container would
  # need Redis). deploy.yml's comment names what booting the retired image again would need. The
  # SYNC_SCHEDULER presence check is also what keeps the absence ones from passing over an empty hash.
  test "the sync accessory runs its scheduler and carries none of the retired Ruby image's knobs, on every destination" do
    require "kamal"
    LIBRARY_DESTINATIONS.each do |destination|
      clear = Kamal::Configuration.create_from(
        config_file: ROOT.join("config/deploy.yml"), destination: destination
      ).accessory("sync").env.clear
      label = destination || "base"

      assert_equal "true", clear["SYNC_SCHEDULER"].to_s, "#{label}: the sync accessory's scheduler is off"
      %w[CABLE_ADAPTER RAILS_LOG_TO_STDOUT].each do |key|
        assert_not clear.key?(key),
                   "#{label}: #{key} is back in the sync accessory's env -- only the Ruby image read it, " \
                   "and Phase 6 retired that image"
      end
    end
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
    expected_keys = Tinkerex::Sidecars.new.names.map { |n| Maker::Addons::Services.env_key_for(n) } +
                    %w[ADDON_SOURCE_URL CHUNK_REMOTE_URL]
    assert_equal expected_keys.sort, host_only_url_keys.sort,
                 "expected one <NAME>_SIDECAR_URL per sidecar/<name>/, plus ADDON_SOURCE_URL and " \
                 "CHUNK_REMOTE_URL, in deploy.yml"

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

  test "no committed destination opens the unverified test-signup seam" do
    # POST /v1/test/users mints CONFIRMED accounts with no email check (V1::TestUsersController),
    # answers `user_id` for an existing address with no password, and has no throttle. On a
    # share/s3 deployment every account is indexed the SAME library, so an open seam hands a
    # stranger read/write/delete on the owner's files. deploy.yml set it for the LAN-only Unraid
    # box for a year, kamal DEEP-MERGES env.clear, and the one internet-facing overlay inherited it
    # for two months. Since 2026-10-12 NO committed destination sets it: the seam is a deliberate,
    # temporary opt-in for a harness run (`kamal env push` after exporting it, or a local
    # `ENABLE_TEST_SIGNUP=1 bin/rails server`), never a standing property of a box — which is
    # also what makes this fail-safe: a new destination is closed until someone opens it on purpose.
    #
    # Read off the MERGED config (deep-merge reflected, not re-implemented), and `.to_s.blank?`
    # rather than `.blank?`: the gate is ENV.present?, and kamal renders a YAML `false` as the
    # string "false", which is present -- so `false` would read closed here and run open.
    require "kamal"
    LIBRARY_DESTINATIONS.each do |destination|
      clear = at(Kamal::Configuration.create_from(
        config_file: ROOT.join("config/deploy.yml"), destination: destination
      ).raw_config, "env", "clear").to_h
      # Non-vacuity: an absent key is CLOSED (nil.to_s is blank), so a raw_config shape change that
      # made every lookup nil would pass the real assertion over nothing.
      assert clear.key?("LIBRARY_BACKEND"),
             "#{destination || 'base'}: merged env.clear has no LIBRARY_BACKEND -- raw_config shape changed?"
      assert clear["ENABLE_TEST_SIGNUP"].to_s.blank?,
             "#{destination || 'base'} resolves ENABLE_TEST_SIGNUP=#{clear['ENABLE_TEST_SIGNUP'].inspect}: " \
             "the unverified POST /v1/test/users signup would be open to anyone who can reach that host"
    end
  end

  test "no committed destination opens registration on a single-library backend" do
    # Tinkerex::Registration refuses REGISTRATION=open at boot on share and s3 (every account
    # indexes the same library). This pins the same rule one step earlier, on the MERGED deploy
    # config, so the refusal is never first discovered as a crash loop on the box.
    require "kamal"
    LIBRARY_DESTINATIONS.each do |destination|
      clear = at(Kamal::Configuration.create_from(
        config_file: ROOT.join("config/deploy.yml"), destination: destination
      ).raw_config, "env", "clear").to_h
      assert clear.key?("LIBRARY_BACKEND"), "#{destination || 'base'}: raw_config shape changed?"
      next unless %w[share s3].include?(clear["LIBRARY_BACKEND"].to_s)

      assert_not_equal "open", clear["REGISTRATION"].to_s,
                       "#{destination || 'base'} runs LIBRARY_BACKEND=#{clear['LIBRARY_BACKEND']} and sets " \
                       "REGISTRATION=open: every account there indexes the same library"
    end
  end

  # THE PUBLIC DEMO IS OVH'S AND NO OTHER DESTINATION'S (H, 2026-10-14). DEMO_ACCOUNT_EMAIL turns on
  # the one-click sign-in AND the nightly reset, which deletes every file the demo account's library
  # holds and re-seeds it from db/seeds/demo. On share and s3 that library is EVERY account's (the
  # test above), so on an Unraid share or s3 destination the reset would replace, every night, the
  # library the author's own accounts work in. The base is chunk_remote, where each account has its
  # own library, so there the absence is the design's choice rather than a data-loss guard: the
  # Unraid boxes keep their console demo account (docs/DEPLOY.md §5).
  #
  # WHICH WAY AN OVERLAY-ONLY KEY INHERITS, MEASURED rather than assumed (2026-10-14, kamal 2.12.0,
  # probe keys planted in a scratch copy of the four files): `-d <dest>` deep-merges deploy.yml with
  # deploy.<dest>.yml and nothing else, so a key in deploy.ovh.yml alone reaches ovh ONLY -- base,
  # share and s3 do not carry the key at all -- while a key in deploy.yml reaches all four. ABSENCE
  # is therefore the true state, and it is what is asserted: blank would also be off, but the key
  # appearing here at all means it went into deploy.yml, which hands it to every destination at
  # once, or into that destination's own overlay.
  test "the public demo is set on OVH and on no other destination" do
    require "kamal"
    clears = LIBRARY_DESTINATIONS.to_h { |destination|
      [ destination, at(Kamal::Configuration.create_from(
        config_file: ROOT.join("config/deploy.yml"), destination: destination
      ).raw_config, "env", "clear").to_h ]
    }

    assert_equal "demo@tinkerex.com", clears.fetch("ovh")["DEMO_ACCOUNT_EMAIL"].to_s,
                 "ovh is the public demo on tinkerex.com: deploy.ovh.yml's env.clear must name its " \
                 "shared account, or the sign-in page offers no demo and the nightly reset does nothing"

    clears.except("ovh").each do |destination, clear|
      label = destination || "base"
      assert clear.key?("LIBRARY_BACKEND"), "#{label}: raw_config shape changed?"
      refute clear.key?("DEMO_ACCOUNT_EMAIL"),
             "#{label} resolves DEMO_ACCOUNT_EMAIL=#{clear['DEMO_ACCOUNT_EMAIL'].inspect}: the demo is " \
             "OVH's alone, and its nightly reset replaces the demo account's whole library -- on share " \
             "and s3, every account's. Keep the key in deploy.ovh.yml and nowhere else."
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

  test "the one sidecar build script bakes the source revision into the image, both ways" do
    # WHAT THIS COVERS, AND — the more important half — WHAT IT CANNOT.
    # It reads the build script and the sidecar Dockerfiles as TEXT and asserts only that the script
    # passes an `org.opencontainers.image.revision` label and a SIDECAR_REVISION build arg carrying
    # one computed value, and that every Dockerfile writes that arg to /revision.
    # Nothing in `bin/ci` builds or pushes a Docker image, so this test does NOT and CANNOT show
    # that the pushed image carries the label, or that the accessory running on the box carries one.
    # Read it as "the script still asks for provenance", never as "provenance is present".
    #
    # WHY THE LABEL AT ALL: the script pushes `:latest` and config/deploy.yml pulls `:latest`, so
    # before this there was nothing on the box that could name the build it was running — and for
    # sidecar/openscad that matters twice over, because assert-capabilities.sh runs ONLY inside its
    # own Dockerfile (`bin/ci` never executes it), making those assertions the image's only gate.
    # A git-SHA TAG does not close it: the OCI distribution API has no digest->tag reverse lookup,
    # and `kamal accessory details` is `docker ps`, which prints `:latest` rather than a digest. The
    # label answers from the container itself. An extra `-t <sha>` is fine beside it and is NOT
    # asserted here — it is inventory, not the mechanism. /revision is the same answer readable
    # through `kamal accessory exec`, where the label needs `docker inspect` on the host.
    #
    # COMMENT LINES ARE DROPPED BEFORE MATCHING: the script's header explains these flags at length,
    # and a comment that spelled one out would satisfy the regex with the real line deleted.
    #
    # DIRECTORY-DRIVEN over the Dockerfiles, never a hard-coded pair, for the reason the licence test
    # above records: a third sidecar is covered the day it appears, not the day someone remembers.
    code = ->(path) { path.read.lines.reject { |l| l.lstrip.start_with?("#") }.join }

    script = ROOT.join("bin/build-sidecar")
    assert script.exist?, "bin/build-sidecar is the one sidecar build script"
    assert_empty ROOT.glob("bin/build-*-sidecar").map { |p| p.basename.to_s },
                 "per-sidecar build scripts are retired — bin/build-sidecar <name> builds any of them"

    body = code.(script)
    label = body[/--label\s+"?org\.opencontainers\.image\.revision=([^"'\s]*)/, 1]
    assert label,
           "bin/build-sidecar must pass --label org.opencontainers.image.revision=… to docker buildx " \
           "build. Without it a running accessory cannot name the build it came from: the script " \
           "pushes :latest and config/deploy.yml pulls :latest, and no tag scheme can recover it " \
           "(no digest->tag reverse lookup; `kamal accessory details` is docker ps)."
    # A LITERAL VALUE WOULD SATISFY THE LINE ABOVE AND MEAN NOTHING — a pasted SHA goes stale on
    # the next commit, silently, and a stale provenance label is worse than none because it is
    # believed. Requiring a shell expansion is the narrowest way to say "computed at build time".
    assert_includes label, "$",
                    "the revision label must be computed from the tree at build time " \
                    "(a shell expansion), not a literal — got #{label.inspect}."
    arg = body[/--build-arg\s+"?SIDECAR_REVISION=([^"'\s]*)/, 1]
    assert arg, "bin/build-sidecar must pass --build-arg SIDECAR_REVISION=… (read back as /revision)"
    assert_equal label, arg, "the label and /revision must carry ONE value"
    assert_match %r{ghcr\.io/chaim354/\$\{?NAME\}?-sidecar}, body,
                 "the pushed image name must be Tinkerex::Sidecars#image's convention"

    # EVERY sidecar writes /revision from that build arg — directory-driven, like the licence test.
    dockerfiles = ROOT.glob("sidecar/*/Dockerfile")
    assert dockerfiles.any?, "expected at least one sidecar/<name>/Dockerfile"
    dockerfiles.each do |df|
      text = code.(df)
      where = df.relative_path_from(ROOT)
      assert_match(/^ARG SIDECAR_REVISION\b/, text, "#{where} must declare ARG SIDECAR_REVISION")
      assert_match(%r{\$SIDECAR_REVISION"?\s*>\s*/revision}, text, "#{where} must write $SIDECAR_REVISION to /revision")
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

  # THE FILES KAMAL READS FOR A DESTINATION, ASKED OF KAMAL — the question bin/secrets-preflight asks
  # of the Kamal::Secrets it resolves through. Kamal::Secrets#secrets_files is public and vault-free:
  # it builds `<path>-common` and `<path>` or `<path>.<destination>`, keeps the ones that exist, and
  # parses nothing. This was a hand-written { destination => filename } map, a re-implementation of
  # that rule and a second list of destinations beside the preflight's (F-S25-1).
  def secrets_files(destination)
    require "kamal"
    Kamal::Secrets.new(destination: destination, secrets_path: ROOT.join(".kamal/secrets").to_s)
                  .secrets_files.map { |path| Pathname.new(path) }
  end

  # Key/value pairs a secrets file DEFINES, parsed without executing anything.
  def secret_definitions(path)
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
  # the same reason Tinkerex::DeploySecrets.required does — so array-replacement semantics are
  # reflected here rather than re-implemented.
  def proxy_hosts(destination)
    require "kamal"
    Kamal::Configuration.create_from(
      config_file: ROOT.join("config/deploy.yml"), destination: destination
    ).proxy.hosts
  end

  # The walk's own reader of raw_config, shared rather than copied: STRING keys, and why a
  # symbol-keyed one asserts nothing, are in Tinkerex::DeploySecrets.at.
  def at(node, *path) = Tinkerex::DeploySecrets.at(node, *path)

  # THE ORACLE FOR THE ONE WALK. Which names kamal resolves for a destination is
  # Tinkerex::DeploySecrets.names, read by bin/secrets-preflight before every deploy and by the
  # tests below — until 2026-10-19 (F-S25-1) this file and the preflight each held a copy, and only
  # this file's was ever run by a test. Widen the walk and this test in the same commit.
  test "the shared walk covers every site kamal reads a secret from" do
    # The real config exercises four of the eleven arms planted below — root and accessory
    # env.secret, the root registry, and ovh's root proxy TLS pair (measured 2026-10-19) — and the
    # other seven are empty in it, so only a synthetic config can show they are reached at all. (The
    # preflight's own fixture run, in test/lib/deploy_secrets_test.rb, plants those four.) Set
    # EQUALITY, not inclusion — the two decoys below are half of what this pins, and an
    # over-collecting version fails LOUD but it still fails: every name it invents is reported
    # MISSING and blocks the deploy.
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
    ], Tinkerex::DeploySecrets.names(raw).sort,
                 "Tinkerex::DeploySecrets.names is the one walk bin/secrets-preflight and this file " \
                 "read for the names kamal will resolve. A site dropped from it is a credential that " \
                 "deploys UNCHECKED — the failure the preflight exists to make impossible. Note what " \
                 "is deliberately absent: CONTAINER_VAR (an alias names the env var, the secret is " \
                 "after the colon) and a-literal-not-a-secret (only the Array form of a registry " \
                 "username/password is a secret reference)."
  end

  test "every secret a destination declares is defined in a file that destination actually reads" do
    LIBRARY_DESTINATIONS.each do |destination|
      files = secrets_files(destination)
      available = files.flat_map { |file| secret_definitions(file).keys }

      Tinkerex::DeploySecrets.required(destination, config_file: ROOT.join("config/deploy.yml")).each do |key|
        assert_includes available, key,
                        "#{destination || 'base'} declares #{key} in its deploy config but no " \
                        "secrets file it reads defines it. Kamal reads ONLY " \
                        "#{files.map { |file| file.relative_path_from(ROOT).to_s }} for this " \
                        "destination — in particular `.kamal/secrets` is NOT read when -d is passed."
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
    universal = LIBRARY_DESTINATIONS.map { |destination|
      Tinkerex::DeploySecrets.required(destination, config_file: ROOT.join("config/deploy.yml"))
    }.reduce(:&)

    secret_definitions(ROOT.join(".kamal/secrets-common")).each_key do |key|
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
    files = LIBRARY_DESTINATIONS.flat_map { |destination| secrets_files(destination) }.uniq
    assert_includes files, ROOT.join(".kamal/secrets-common"),
                    "kamal names no .kamal/secrets-common for any destination, so this scan would skip " \
                    "the one file every destination reads — has the secrets path moved?"

    files.each do |file|
      secret_definitions(file).each do |key, value|
        assert_match(/\A\$[({A-Z_]/, value,
                     "#{key} in #{file.relative_path_from(ROOT)} looks like a literal value. Secrets files are " \
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

  # EVERY DESTINATION KAMAL CAN DEPLOY, for every guard in this file — the one list
  # bin/secrets-preflight also reads, which test/lib/deploy_secrets_test.rb holds equal to the
  # config/deploy.<name>.yml files present. Reused rather than restated: it used to live in this file
  # AND the preflight, two things to forget when a destination is added or folded away (as `remote`
  # was). The set is asserted explicitly below so trimming it cannot retire this guard.
  LIBRARY_DESTINATIONS = Tinkerex::DeploySecrets::DESTINATIONS

  # The knobs each backend cannot boot without. The chunk_remote and s3 lists are the PRODUCTION
  # constants, not copies, so a knob added to lib/library_backend_check.rb is enforced here on the
  # same commit. `share` has no such constant (check_share! takes the path as a plain argument), so
  # LIBRARY_PATH is spelled out — the one line here that can drift, and also the whole of what
  # check_share! can be asked statically: its real work is a File.exist? plus a write probe ON THE
  # BOX, which no test in this process can perform.
  #
  # THE KEYS ALSO SERVE AS THE SET OF BACKENDS FileLayer.build ACCEPTS — the same set as
  # LibraryBackendCheck::NAMES, which postdates this table. Deliberate: a destination resolving to
  # anything else — unset, a typo, or the retired `chunk`, which the boot and build both REFUSE
  # rather than alias (§14a) — must fail HERE rather than depend on whatever it happens to inherit.
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
  # reason Tinkerex::DeploySecrets.required does — array replacement and hash deep-merge are
  # reflected rather than re-implemented. A knob counts as CARRIED if env.clear holds a non-blank
  # value for it OR env.secret names it: kamal injects the latter at deploy from the destination's
  # own secrets file, and the sibling guard above ("every secret a destination declares is defined
  # in a file that destination actually reads") is what proves that file defines it. The two
  # compose; neither alone would catch a knob that is declared secret but never defined.
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
                   "env.clear, or in env.secret WITH a matching line in a file kamal reads for it " \
                   "(#{secrets_files(destination).map { |file| file.relative_path_from(ROOT).to_s }.join(' or ')}) " \
                   "— its own, unless every destination needs the key (§14g)."
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
