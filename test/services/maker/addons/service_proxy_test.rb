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

      test "an unreachable host raises Error, not a bare Net::HTTP exception" do
        assert_raises(ServiceProxy::Error) do
          ServiceProxy.new.call(method: :get, url: "http://127.0.0.1:1", path: "x")
        end
      end

      private

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
