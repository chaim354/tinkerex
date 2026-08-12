require "test_helper"
require "socket"

module Maker
  module Addons
    # Drives the REAL Net::HTTP path — test/controllers/tools/addons_controller_test.rb only ever
    # exercises FakeServiceProxy, so nothing there proves `call` actually builds a correct request or
    # enforces its own size cap. A minimal hand-rolled TCP responder stands in for a sidecar: no
    # webrick in this Ruby (not a bundled default gem here), and a real socket is what proves the WIRE
    # format, not a round-trip through another layer that could share this code's own misunderstanding
    # (§14e "a fake that shares the bug hides it").
    class ServiceProxyTest < ActiveSupport::TestCase
      teardown { ServiceProxy.reset! }

      test "current returns a plain instance when unstubbed, and the stub when set" do
        assert_instance_of ServiceProxy, ServiceProxy.current
        fake = Object.new
        ServiceProxy.stub = fake
        assert_same fake, ServiceProxy.current
        ServiceProxy.reset!
        assert_instance_of ServiceProxy, ServiceProxy.current
      end

      test "a GET sends params as a query string and returns status/content_type/body" do
        received = serve_once(body: "hello-svg", content_type: "image/svg+xml") do |base_url|
          res = ServiceProxy.new.call(method: :get, url: base_url, path: "render", params: { "a" => "1" })
          assert_equal 200, res.status
          assert_equal "image/svg+xml", res.content_type
          assert_equal "hello-svg", res.body
        end
        assert_equal "GET", received[:method]
        assert_equal "/render?a=1", received[:path]
      end

      test "a POST sends params as a JSON body, not form-encoded" do
        # boxes.py's own /generate reads `request.get_json(force=True, ...)` — a form-encoded body
        # would not parse. See the comment on ServiceProxy#build_request.
        received = serve_once(body: "svg-out", content_type: "image/svg+xml") do |base_url|
          res = ServiceProxy.new.call(method: :post, url: base_url, path: "generate",
                                       params: { "generator" => "ABox", "params" => { "x" => 100 } })
          assert_equal 200, res.status
          assert_equal "svg-out", res.body
        end
        assert_equal "POST", received[:method]
        assert_equal "application/json", received[:headers]["content-type"]
        assert_equal({ "generator" => "ABox", "params" => { "x" => 100 } }, JSON.parse(received[:body]))
      end

      test "a non-2xx status is still returned as a Response, not raised" do
        # The controller decides what a 422/404 from the sidecar means (it becomes a 404 to the
        # browser, per the three-refusals rule) — ServiceProxy's job is only to relay, not to judge.
        serve_once(status: 422, body: '{"error":"bad param"}', content_type: "application/json") do |base_url|
          res = ServiceProxy.new.call(method: :post, url: base_url, path: "generate", params: {})
          assert_equal 422, res.status
          assert_equal '{"error":"bad param"}', res.body
        end
      end

      test "a response over the size cap raises Error instead of buffering it whole" do
        prior_cap = ServiceProxy::MAX_BODY_BYTES
        ServiceProxy.send(:remove_const, :MAX_BODY_BYTES)
        ServiceProxy.const_set(:MAX_BODY_BYTES, 10)
        serve_once(body: "x" * 11) do |base_url|
          assert_raises(ServiceProxy::Error) do
            ServiceProxy.new.call(method: :get, url: base_url, path: "big")
          end
        end
      ensure
        ServiceProxy.send(:remove_const, :MAX_BODY_BYTES)
        ServiceProxy.const_set(:MAX_BODY_BYTES, prior_cap)
      end

      # Same gap, same fix, as Source#get's: URI.parse is the first statement in #call and is not a
      # network error, so a path carrying a space or non-ASCII byte raised straight out of
      # Tools::AddonsController#service as a 500 for any authenticated user. No listener needed —
      # the raise happens before any socket is opened.
      test "a path URI.parse cannot handle raises Error, not a bare URI::InvalidURIError" do
        [ "a b", "café", "a\nb" ].each do |bad|
          assert_raises(ServiceProxy::Error, "expected #{bad.inspect} to be a routine refusal") do
            ServiceProxy.new.call(method: :get, url: "http://sidecar.test", path: bad)
          end
        end
      end

      test "an unreachable host raises Error, not a bare Net::HTTP exception" do
        assert_raises(ServiceProxy::Error) do
          ServiceProxy.new.call(method: :get, url: "http://127.0.0.1:1", path: "x")
        end
      end

      # ---- per-service read timeouts -----------------------------------------------------------

      test "read_timeout_for keeps today's default for a manifest that asks for nothing" do
        # `nil` is the overwhelmingly common case — no published manifest declares the key — so this
        # is the arm that must not regress. The three malformed shapes are Registry's job to filter,
        # but this method is public and takes whatever it is handed, so it refuses them too rather
        # than trusting a single upstream caller to stay correct.
        [ nil, "90", 0, -5, 12.5 ].each do |requested|
          assert_equal ServiceProxy::READ_TIMEOUT, ServiceProxy.read_timeout_for(requested),
                       "#{requested.inspect} must fall back to the default"
        end
      end

      test "read_timeout_for honours a positive integer under the cap, in both directions" do
        # BOTH directions matter: a manifest may legitimately ask for LESS than the default (a fast
        # sidecar should not be able to hold a thread for 30 s), so this is not a floor.
        assert_equal 90, ServiceProxy.read_timeout_for(90)
        assert_equal 5, ServiceProxy.read_timeout_for(5)
      end

      # A REQUEST ABOVE THE CAP GETS THE CAP, NOT AN ERROR. The manifest is remote and versioned
      # independently of this host (§14c), so refusing it would take a working addon down on a
      # deploy that merely lowered the ceiling.
      test "read_timeout_for caps a manifest that asks for more than the host allows" do
        assert_equal ServiceProxy::MAX_TIMEOUT_DEFAULT, ServiceProxy.read_timeout_for(9_999)
      end

      test "ADDON_SERVICE_MAX_TIMEOUT moves the cap" do
        with_env("ADDON_SERVICE_MAX_TIMEOUT" => "45") do
          assert_equal 45, ServiceProxy.read_timeout_for(9_999)
          assert_equal 30, ServiceProxy.read_timeout_for(30), "under the lowered cap, unchanged"
        end
      end

      # `.to_i` ANSWERS 0 FOR "abc", WHICH WOULD CLAMP EVERY SERVICE TO AN INSTANT TIMEOUT — one
      # typo in a deploy env taking every sidecar in the deployment down. The fallback direction is
      # "works", not "fails".
      test "a malformed or non-positive ADDON_SERVICE_MAX_TIMEOUT falls back to the default cap" do
        [ "abc", "", "0", "-10", "12.5" ].each do |bad|
          with_env("ADDON_SERVICE_MAX_TIMEOUT" => bad) do
            assert_equal ServiceProxy::MAX_TIMEOUT_DEFAULT, ServiceProxy.read_timeout_for(9_999),
                         "#{bad.inspect} must not become the cap"
          end
        end
      end

      # THE ARGUMENT ACTUALLY REACHES Net::HTTP, PROVED BY BEHAVIOUR RATHER THAN BY INTROSPECTION.
      # Asserting that `call` passes `read_timeout:` along would be asserting the line exists;
      # this drives a responder that never answers and shows the call gives up on the SHORT
      # timeout it was handed, not on the 30 s default it would otherwise have used. The test would
      # take 30 s to fail if the argument were dropped, which is itself the signal.
      test "a per-call read_timeout is what the socket actually uses" do
        server = TCPServer.new("127.0.0.1", 0)
        port = server.addr[1]
        # Accepts the connection and then never writes a response — a sidecar mid-render.
        # 10 s, well clear of both the 1 s under test and the 5 s assertion below, so the mutation
        # check (hard-code READ_TIMEOUT back into #call) fails on the assertion rather than on the
        # responder happening to hang up first.
        thread = Thread.new do
          client = server.accept
          sleep 10
          client.close
        rescue IOError, Errno::EBADF
          # killed at teardown, or the server closed under us — the test already got its answer
        end

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        assert_raises(ServiceProxy::Error) do
          ServiceProxy.new.call(method: :get, url: "http://127.0.0.1:#{port}", path: "slow",
                                read_timeout: 1)
        end
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

        assert_operator elapsed, :<, 5, "gave up later than the 1 s read_timeout it was handed"
      ensure
        server&.close
        thread&.kill
      end

      private

      def with_env(pairs)
        prior = pairs.keys.index_with { |key| ENV[key] }
        pairs.each { |key, value| ENV[key] = value }
        yield
      ensure
        prior.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
      end

      # Accepts exactly one HTTP/1.1 request on an ephemeral local port, answers it with the given
      # canned response, and returns what it received (method/path/headers/body) so the caller can
      # assert on the WIRE format `call` actually sent — not on this repo's own idea of what it sent.
      def serve_once(status: 200, body: "", content_type: "text/plain")
        server = TCPServer.new("127.0.0.1", 0)
        port = server.addr[1]
        received = {}
        thread = Thread.new do
          client = server.accept
          request_line = client.gets
          received[:method], received[:path], = request_line.to_s.split(" ")
          headers = {}
          while (line = client.gets) && line != "\r\n"
            key, value = line.split(":", 2)
            headers[key.strip.downcase] = value.to_s.strip if key
          end
          received[:headers] = headers
          content_length = headers["content-length"].to_i
          received[:body] = content_length.positive? ? client.read(content_length) : ""

          client.write "HTTP/1.1 #{status} status\r\n"
          client.write "Content-Type: #{content_type}\r\n"
          client.write "Content-Length: #{body.bytesize}\r\n"
          client.write "Connection: close\r\n\r\n"
          client.write body
          client.close
        rescue IOError, Errno::EBADF
          # server closed under us at teardown — fine, the test already got what it needed
        end

        yield "http://127.0.0.1:#{port}"
        thread.join(5)
        received
      ensure
        server&.close
      end
    end
  end
end
