require "net/http"
require "json"

module Maker
  module Addons
    # Proxies ONE request from an addon bundle to a sidecar the addon's manifest declares. Mirrors
    # Source's `.stub=`/`current`/`reset!` seam — same shape, same reason: a test injects a fake
    # here instead of stubbing Net::HTTP globally (this repo has no `Object#stub`; minitest 6 dropped
    # minitest/mock — test/test_helper.rb:147).
    #
    # This class does NOT decide which service or URL to use — that's `Tools::AddonsController#service`
    # and `#sidecar_url_for`, which is where the manifest-vs-ENV split (spec §4.1) is enforced. By the
    # time a call reaches here, the URL is already trusted.
    class ServiceProxy
      class Error < StandardError; end

      # status: Integer HTTP status; content_type: String (may be nil if the sidecar omitted one);
      # body: String (raw bytes).
      Response = Data.define(:status, :content_type, :body)

      READ_TIMEOUT = 30
      OPEN_TIMEOUT = 5

      # Bounds a sidecar's response so a misbehaving or compromised sidecar cannot stream Rails' own
      # memory away — `service` hands the body straight to `send_data`, which buffers it whole. A
      # boxes.py SVG render is at most tens of KB; 20 MiB leaves generous headroom (a large multi-part
      # tray SVG, plus room to grow) while still being a hard, deliberate ceiling rather than "however
      # much the sidecar felt like sending." Enforced WHILE STREAMING (via `read_body`'s block form),
      # not after a full buffer — the point is to cap memory, not just refuse after the fact.
      MAX_BODY_BYTES = 20_000_000

      class << self
        attr_writer :stub

        def current = @stub || new
        def reset! = @stub = nil
      end

      # method: :get or :post. url: the sidecar's base (from ENV, already trusted by the caller).
      # path: already validated by Source.validate_asset_path! upstream — this class does not
      # re-validate it, the same division of labor Source itself has between its class-level guard
      # and its instance-level fetch. params: a Hash, sent as a query string (GET) or a JSON body
      # (POST) — JSON, not form-encoded, because the boxes sidecar's own `/generate` reads its body
      # with Flask's `request.get_json(force=True, ...)` (sidecar/boxes/app.py), which does not
      # accept a form-encoded body. Rails has already parsed whatever the addon's own fetch() sent
      # (JSON or form) into `params` by the time it reaches here, so re-emitting JSON is what makes
      # the proxy transparent to a sidecar written, like this one, as a JSON API.
      def call(method:, url:, path:, params: {})
        uri = URI.parse("#{url.to_s.chomp('/')}/#{path}")
        request = build_request(method, uri, params)

        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                        open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
          http.request(request) do |res|
            body = +""
            res.read_body do |chunk|
              body << chunk
              raise Error, "sidecar response exceeds #{MAX_BODY_BYTES} bytes" if body.bytesize > MAX_BODY_BYTES
            end
            return Response.new(status: res.code.to_i, content_type: res.content_type, body: body)
          end
        end
      rescue SystemCallError, Net::OpenTimeout, Net::ReadTimeout, SocketError, OpenSSL::SSL::SSLError => e
        raise Error, "#{path} -> #{e.class}: #{e.message}"
      end

      private

      def build_request(method, uri, params)
        case method
        when :get
          uri.query = URI.encode_www_form(params) if params.present?
          Net::HTTP::Get.new(uri)
        when :post
          req = Net::HTTP::Post.new(uri)
          req["Content-Type"] = "application/json"
          req.body = params.to_json
          req
        else
          raise Error, "unsupported method #{method.inspect}"
        end
      end
    end
  end
end
