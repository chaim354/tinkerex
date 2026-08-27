require "net/http"
require "json"
require "pathname"

module Maker
  module Addons
    # Fetches the addon index and addon assets from the configured source: over HTTP
    # (`ADDON_SOURCE_URL`, Phase B's real, separate static container — and production, always) or
    # straight off local disk (`ADDON_SOURCE_PATH`, dev/test — see `Local` below for why). Mirrors
    # the shape of the sidecar clients (`configured?` gates availability; a `stub` seam for tests) so
    # it reads like the rest of this layer.
    #
    # The source is a dumb static host. It is NOT trusted to name its own location: neither env var
    # is anything a manifest supplies — a manifest-supplied URL would be an SSRF primitive pointed at
    # the internal network (spec §4.1).
    class Source
      class Error < StandardError; end

      READ_TIMEOUT = 5
      OPEN_TIMEOUT = 2

      class << self
        attr_writer :stub

        def configured? = ENV["ADDON_SOURCE_URL"].present? || ENV["ADDON_SOURCE_PATH"].present?
        def base_url = ENV.fetch("ADDON_SOURCE_URL")

        # ADDON_SOURCE_PATH wins if BOTH are set — there is no legitimate reason to set both, but
        # PATH winning is the safer failure mode: a stray ADDON_SOURCE_URL left in the environment
        # can never make a dev/test run hit the network by surprise.
        def current
          @stub || (ENV["ADDON_SOURCE_PATH"].present? ? Local.new(ENV.fetch("ADDON_SOURCE_PATH")) : new(base_url))
        end

        def reset! = @stub = nil

        # Shared by Source and Local so a path accepted by one is accepted by exactly the other —
        # one guard, not two copies that can drift. `path` is attacker-influenced (it comes off the
        # URL), so it is REJECTED, never normalized — expand_path would turn "a/../../b" into a
        # *valid* path and silently fetch the wrong file. Same rule, same reason, as
        # FileLayer::S3#key_for (§14a).
        def validate_asset_path!(path)
          p = path.to_s
          raise Error, "empty asset path" if p.empty?
          raise Error, "absolute asset path refused: #{p.inspect}" if p.start_with?("/")
          raise Error, "traversal refused: #{p.inspect}" if p.split("/").any? { |seg| seg == ".." || seg == "." || seg.empty? }

          p
        end
      end

      def initialize(base_url) = @base = base_url.to_s.chomp("/")

      # The index: an Array of manifest Hashes. Anything else is a malformed source.
      def manifests
        parsed = JSON.parse(get("/manifests.json"))
        raise Error, "manifests.json must be an array, got #{parsed.class}" unless parsed.is_a?(Array)

        parsed
      rescue JSON::ParserError => e
        raise Error, "malformed manifests.json: #{e.message}"
      end

      # Raw bytes for one addon asset.
      def asset(key, path) = get("/#{key}/#{asset_path!(path)}")

      def asset_path!(path) = self.class.validate_asset_path!(path)

      # MAY THIS SOURCE'S OUTPUT BE CACHED — THE INDEX *AND* ITS ASSETS? A predicate the source
      # ANSWERS, rather than a class check at the call site — same preference as §14b's Phase 3
      # trap, and here the two backends genuinely differ rather than coincidentally agreeing.
      #
      # THE INDEX ASKS IT TOO (`Registry#manifests`), and that is wider than this comment once
      # claimed. The cost argument below is an ASSET argument and does not reach manifests.json —
      # but `Local`'s own reason, at the bottom of this file, is about STALENESS, and that one
      # applies to the index verbatim. Honouring it for assets only left a dev author with fresh
      # bundle bytes against a manifest up to five minutes old, which is worse than uniform
      # staleness: the half that updates makes you believe the other half did.
      #
      # TRUE over HTTP, where every asset is a fresh TCP connection + GET to the accessory
      # (Net::HTTP.start per call, no keep-alive) plus a full-body buffer, repeated per module per
      # page view: the boxes bundle is 12 ES modules, and the generators bundle re-proxies a 180 KB
      # makerjs.js on every navigation. FALSE on Local, where the read is a disk hit costing nothing
      # and caching would do real harm — an addon author editing a file in dev would be served a
      # stale copy for the whole TTL and reasonably conclude reloading was broken.
      def cacheable? = true

      private

      def get(path)
        uri = URI.parse("#{@base}#{path}")
        res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                              open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
          http.get(uri.request_uri)
        end
        raise Error, "#{path} -> HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)

        res.body
      # SSLError is in this list for the HTTPS source Phase B introduces, not for today's
      # http://127.0.0.1 — without it a TLS failure escapes Source::Error, and Registry's
      # degrade-to-no-addons rescue would miss it and 500 instead.
      #
      # URI::Error is here because `URI.parse` is the FIRST thing this method does and it is not a
      # network error, so the five below never covered it. validate_asset_path! rejects `..`, `.`,
      # empty segments and a leading `/` — it does NOT reject spaces, newlines, NULs or non-ASCII,
      # all of which make URI.parse raise. The result was a 500 for any authenticated user who
      # requested `/tools/<key>/asset/a%20b.js`, and a 500 rather than the intended 404 for an
      # addon that legitimately shipped `café.js` — which reads as "my fix didn't deploy", exactly
      # the confusion the asset action's own comment is trying to avoid.
      #
      # HTTP MODE ONLY, WHICH IS WHY THE SUITE WAS GREEN OVER IT: Source::Local (dev/test) reads
      # with Pathname#read and never parses a URI, so the guard's precondition was never
      # established in test — the same shape as §14a's STORAGE_BACKEND 500.
      rescue URI::Error, SystemCallError, Net::OpenTimeout, Net::ReadTimeout, SocketError,
             OpenSSL::SSL::SSLError => e
        raise Error, "#{path} -> #{e.class}: #{e.message}"
      end

      # Local-filesystem mode, selected by ADDON_SOURCE_PATH. Exists ONLY for dev/test.
      #
      # ADDON_SOURCE_URL (HTTP) pointed back at THIS SAME Rails process — the only option available
      # before the addons repo's static container exists (Phase B) — turns every asset fetch into a
      # SYNCHRONOUS NESTED HTTP call made from inside a request this same Puma is already handling.
      # That call competes for a thread in the SAME pool the outer request's own thread is already
      # occupying while it blocks waiting on that nested call — reentrancy, not just extra load.
      #
      # Verified empirically, not theoretically: the `generators` bundle's own module graph (2
      # sequential fetches, then 4 of makerjs's bare-specifier deps fetched at once by the browser)
      # against a stock 3-4-thread dev/Capybara Puma pool made most requests stall 14-24 SECONDS, and
      # several outright 404'd — Net::HTTP's own read timeout firing before a thread ever freed up.
      # Larger addons (`boxes` has more Stimulus controllers and more vendored deps) would need it
      # even more. In real production (Phase B) ADDON_SOURCE_URL names a genuinely SEPARATE process
      # with its own pool, so this reentrancy is structurally impossible there — it is unique to a
      # same-process Phase A transitional setup, and reading public/ straight off disk sidesteps it
      # entirely rather than papering over it with a bigger thread count (which does not scale with a
      # future addon's dependency count, and still leaves an ordinary `bin/rails server` dev session
      # exposed).
      #
      # LOCAL STILL BENEFITS FROM A FEW Puma THREADS in `bin/rails server`'s DEVELOPMENT mode
      # specifically — a second, smaller effect worth naming so it isn't rediscovered as "the fix
      # didn't work." `config.enable_reloading = true` wraps every request in the dependencies
      # interlock/reloader, adding per-request overhead that the plain `threads 3, 3` in
      # `config/puma.rb` can make visible when a page fires several near-simultaneous asset
      # requests, as an addon page does. Observed directly: the stock 3-thread pool intermittently
      # 404'd `generators`' own concurrent asset fetches in a real browser against a real
      # `bin/rails server`; `RAILS_MAX_THREADS=16` made it reliable. Production (`enable_reloading =
      # false`, eager-loaded) and the test env (`enable_reloading = false`, which is what
      # test/system/addon_bundle_test.rb runs under) do not carry this overhead and are unaffected —
      # this is a `bin/rails server`-in-development tuning note, not a correctness bug in this class.
      class Local
        def initialize(root) = @root = Pathname.new(root.to_s)

        def manifests
          parsed = JSON.parse(read("manifests.json"))
          raise Error, "manifests.json must be an array, got #{parsed.class}" unless parsed.is_a?(Array)

          parsed
        rescue JSON::ParserError => e
          raise Error, "malformed manifests.json: #{e.message}"
        end

        def asset(key, path) = read("#{key}/#{Source.validate_asset_path!(path)}")

        # NEVER. This is the dev/test source: the read is free, and a cached copy would make an
        # addon author's edit invisible for the TTL — the "my fix didn't deploy" confusion the whole
        # caching design is supposed to avoid, delivered to the one person editing the file.
        def cacheable? = false

        private

        def read(relative_path)
          @root.join(relative_path).read
        rescue Errno::ENOENT, Errno::EISDIR, Errno::ENOTDIR => e
          raise Error, "#{relative_path} -> #{e.class}: #{e.message}"
        end
      end
    end
  end
end
