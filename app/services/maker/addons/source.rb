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
      rescue SystemCallError, Net::OpenTimeout, Net::ReadTimeout, SocketError,
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
