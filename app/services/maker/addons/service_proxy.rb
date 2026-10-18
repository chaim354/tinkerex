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

      # The read timeout a service gets when its manifest asks for nothing — today's behaviour, and
      # the answer for every published manifest, since `service_timeouts` is new.
      READ_TIMEOUT = 30
      OPEN_TIMEOUT = 5

      # THE HOST'S CEILING ON WHAT A MANIFEST MAY ASK FOR. A manifest is fetched from a source this
      # process does not control (§14c), so "how long may you hold one of my threads" cannot be the
      # bundle author's decision to make unilaterally — but 30 s is genuinely too short for one real
      # sidecar (the OpenSCAD one caps its OWN render at 60 s — `sidecar/openscad/render.py`'s
      # `TIMEOUT_S`, default 60 — so the proxy gave up before the sidecar had finished), which is
      # what this key exists to unblock. Recorded as `docs/AUDIT-2026-08-03.md` §2.3 "Sidecar-proxy
      # read timeout (30 s) is below the OpenSCAD sidecar's own render cap (60 s)" — NAMED rather
      # than left as a bare "§2.3", because that document has TWO sections numbered 2.3 and the
      # other one is the Content-Type allowlist.
      #
      # WHAT 120 COSTS UNDER LOAD, STATED PLAINLY BECAUSE IT IS THE WHOLE ARGUMENT FOR HAVING A CAP.
      # This proxy is SYNCHRONOUS: `#service` holds its Puma thread for the entire sidecar round
      # trip. Production runs `RAILS_MAX_THREADS: 16` on one worker (config/deploy.yml), so sixteen
      # concurrent renders sitting at the cap occupy EVERY thread for two minutes and queue
      # everything else behind them — the addon page itself, the library, the health check. The cap
      # is therefore a bound on worst-case head-of-line blocking, not a performance knob: raising it
      # raises how long one user's slow render can stall the whole box. The real fix for a genuinely
      # long render is an async job — which spec §13 lists as explicitly NOT RESERVED (no capability
      # name yet; `jobs:*` when a consumer exists), so there is nothing to feature-detect and a
      # bigger number here is not a substitute for it.
      MAX_TIMEOUT_DEFAULT = 120

      class << self
        attr_writer :stub

        def current = @stub || new
        def reset! = @stub = nil

        # The operator's ceiling. Read per call rather than memoized in a constant: it costs an ENV
        # lookup, and a constant would freeze whatever the value was at the first request of the
        # process — including in a test that sets it.
        #
        # `Integer(…, exception: false)` rather than `.to_i`, which answers 0 for "abc" and would
        # clamp EVERY service to an instant timeout on one typo in a deploy env. A missing,
        # unparseable or non-positive value falls back to the default, which fails toward "works".
        def max_read_timeout
          parsed = Integer(ENV["ADDON_SERVICE_MAX_TIMEOUT"].to_s, exception: false)
          parsed&.positive? ? parsed : MAX_TIMEOUT_DEFAULT
        end

        # -> the read timeout to actually use, given whatever the manifest asked for (nil if it
        # asked for nothing). A REQUEST ABOVE THE CAP GETS THE CAP, NOT AN ERROR: the manifest is
        # remote and versioned independently of this host, so refusing it would take a working
        # addon down on a deploy that merely lowered the ceiling — the Registry's own "degrade,
        # never raise" rule, applied one layer along.
        def read_timeout_for(requested)
          return READ_TIMEOUT unless requested.is_a?(Integer) && requested.positive?

          [ requested, max_read_timeout ].min
        end
      end

      # Bounds a sidecar's response so a misbehaving or compromised sidecar cannot stream Rails' own
      # memory away — `service` hands the body straight to `send_data`, which buffers it whole. A
      # boxes.py SVG render is at most tens of KB; 20 MiB leaves generous headroom (a large multi-part
      # tray SVG, plus room to grow) while still being a hard, deliberate ceiling rather than "however
      # much the sidecar felt like sending." Enforced WHILE STREAMING (via `read_body`'s block form),
      # not after a full buffer — the point is to cap memory, not just refuse after the fact.
      MAX_BODY_BYTES = 20_000_000

      # method: :get or :post. url: the sidecar's base (from ENV, already trusted by the caller).
      # path: already validated by Source.validate_asset_path! upstream — this class does not
      # re-validate it, the same division of labor Source itself has between its class-level guard
      # and its instance-level fetch. params: a Hash, sent as a query string (GET) or a JSON body
      # (POST) — JSON, not form-encoded, because the boxes sidecar's own `/generate` reads its body
      # with Flask's `request.get_json(force=True, ...)` (sidecar/boxes/app.py), which does not
      # accept a form-encoded body. Rails has already parsed whatever the addon's own fetch() sent
      # (JSON or form) into `params` by the time it reaches here, so re-emitting JSON is what makes
      # the proxy transparent to a sidecar written, like this one, as a JSON API.
      #
      # SINCE THE SDK'S `service.post` SENDS JSON TOO, THE TWO ENDS NOW AGREE — but this class must
      # keep re-emitting rather than forwarding the raw body, because a GET's params arrive as a
      # query string and both shapes have to leave here the same way.
      #
      # read_timeout: seconds, ALREADY RESOLVED AND CAPPED by the caller via `.read_timeout_for`.
      # Defaulted here as well so every other caller — and every test — keeps today's 30 s without
      # needing to know the manifest key exists. ONLY the read timeout is per-service: OPEN_TIMEOUT
      # asks "is anything listening", which a slow render does not make slower, and a sidecar that
      # cannot be connected to within 5 s is down however long its renders take.
      def call(method:, url:, path:, params: {}, read_timeout: READ_TIMEOUT)
        uri = URI.parse("#{url.to_s.chomp('/')}/#{path}")
        request = build_request(method, uri, params)

        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                        open_timeout: OPEN_TIMEOUT, read_timeout: read_timeout) do |http|
          http.request(request) do |res|
            body = +""
            res.read_body do |chunk|
              body << chunk
              raise Error, "sidecar response exceeds #{MAX_BODY_BYTES} bytes" if body.bytesize > MAX_BODY_BYTES
            end
            return Response.new(status: res.code.to_i, content_type: res.content_type, body: body)
          end
        end
      # URI::Error for the same reason Source#get rescues it: `URI.parse` is the first statement
      # here and is not a network error, so a path that survives validate_asset_path! (which
      # rejects traversal and NULs but not spaces, newlines or non-ASCII) raised straight out of the
      # action as a 500. -> Error, which the controller already maps to 404.
      rescue URI::Error, SystemCallError, Net::OpenTimeout, Net::ReadTimeout, SocketError,
             OpenSSL::SSL::SSLError => e
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
