require "net/http"
require "json"

module Maker
  module Addons
    # Fetches the addon index and addon assets from the configured source over HTTP. Mirrors the
    # shape of the sidecar clients (`configured?` gates availability; a `stub` seam for tests) so it
    # reads like the rest of this layer.
    #
    # The source is a dumb static host. It is NOT trusted to name its own location: `ADDON_SOURCE_URL`
    # is the host's own config, never anything a manifest supplies — a manifest-supplied URL would be
    # an SSRF primitive pointed at the internal network (spec §4.1).
    class Source
      class Error < StandardError; end

      READ_TIMEOUT = 5
      OPEN_TIMEOUT = 2

      class << self
        attr_writer :stub

        def configured? = ENV["ADDON_SOURCE_URL"].present?
        def base_url = ENV.fetch("ADDON_SOURCE_URL")
        def current = @stub || new(base_url)
        def reset! = @stub = nil
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

      # Raw bytes for one addon asset. `path` is attacker-influenced (it comes off the URL), so it is
      # REJECTED, never normalized — expand_path would turn "a/../../b" into a *valid* path and
      # silently fetch the wrong file. Same rule, same reason, as FileLayer::S3#key_for (§14a).
      def asset(key, path) = get("/#{key}/#{asset_path!(path)}")

      def asset_path!(path)
        p = path.to_s
        raise Error, "empty asset path" if p.empty?
        raise Error, "absolute asset path refused: #{p.inspect}" if p.start_with?("/")
        raise Error, "traversal refused: #{p.inspect}" if p.split("/").any? { |seg| seg == ".." || seg == "." || seg.empty? }

        p
      end

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
    end
  end
end
