# frozen_string_literal: true

require "test_helper"
require "socket"

module FileLayer
  class ChunkRemote
    # DRIVEN AGAINST A REAL HTTP SERVER, NOT A STUBBED Net::HTTP.
    #
    # This class exists to turn wire conditions into FileLayer's error vocabulary, so stubbing the
    # wire would leave it asserting its own intent. A WEBrick server on a loopback port costs
    # milliseconds and makes the statuses, the bodies and the connection failures real -- the same
    # reason §14e gives for FakeS3: a fake that shares the code's assumptions confirms them.
    class TransportTest < ActiveSupport::TestCase
      # A HAND-ROLLED TCPServer RATHER THAN WEBrick, WHICH LEFT STDLIB IN RUBY 3.0. Adding a gem to
      # get a test server would put a dependency in the Gemfile for one file (§9 keeps them few);
      # thirty lines of socket handling keeps the property that matters -- real sockets, real status
      # lines, real connection refusals -- which is the entire reason this suite does not stub
      # Net::HTTP.
      setup do
        @responses = {}
        @seen = nil
        @server = TCPServer.new("127.0.0.1", 0)
        @port = @server.addr[1]
        @thread = Thread.new do
          loop do
            socket = begin
              @server.accept
            rescue IOError, Errno::EBADF
              break
            end
            handle(socket)
          end
        end
      end

      teardown do
        @server&.close
        @thread&.kill
      end

      def handle(socket)
        request_line = socket.gets.to_s
        verb, path = request_line.split(" ")
        headers = {}
        while (line = socket.gets) && line != "\r\n"
          k, v = line.split(": ", 2)
          headers[k.to_s.downcase] = v.to_s.strip
        end
        body = headers["content-length"] ? socket.read(headers["content-length"].to_i) : nil
        route, query = path.to_s.split("?", 2)
        @seen = { auth: headers["authorization"], body:, path: route, query:, verb: }

        canned = @responses[route] || { status: 404, body: { error: "not_found" }.to_json }
        sleep canned[:delay] if canned[:delay]
        payload = canned[:body].to_s
        socket.write("HTTP/1.1 #{canned[:status]} X\r\n" \
                     "Content-Type: #{canned[:content_type] || "application/json"}\r\n" \
                     "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
      rescue StandardError
        # A client that hung up mid-request (the read-timeout test does exactly that) must not take
        # the accept loop down with it.
      ensure
        socket.close rescue nil
      end

      def transport(**over) = Transport.new(base_url: "http://127.0.0.1:#{@port}", token: "tok", **over)
      def canned(path, status:, body: "", content_type: nil, delay: nil) = @responses[path] = { status:, body:, content_type:, delay: }

      test "a 2xx JSON body comes back parsed" do
        canned "/v1/tree", status: 200, body: { "nodes" => [ { "node_id" => "n1" } ] }.to_json
        assert_equal({ "nodes" => [ { "node_id" => "n1" } ] }, transport.get("/v1/tree"))
      end

      test "the device token rides as a Bearer header on every verb" do
        canned "/v1/nodes", status: 200, body: "{}"
        transport.post("/v1/nodes", { name: "x" })
        assert_equal "Bearer tok", @seen[:auth]
        assert_equal({ "name" => "x" }, JSON.parse(@seen[:body]))
      end

      test "query params are encoded onto a GET" do
        canned "/v1/changes", status: 200, body: "{}"
        transport.get("/v1/changes", { since: 42 })
        assert_equal "since=42", @seen[:query]
      end

      # ── the error mapping, which is the whole point of the class ──────────────────────────────
      test "404 is TERMINAL -- NotFound, so a caller renders 404" do
        canned "/v1/nodes/gone", status: 404, body: { error: "not_found" }.to_json
        assert_raises(FileLayer::NotFound) { transport.get("/v1/nodes/gone") }
      end

      test "409 and 422 are UnsupportedOperation -- they never succeed on retry" do
        canned "/v1/a", status: 409, body: { error: "name_taken" }.to_json
        canned "/v1/b", status: 422, body: { error: "would_create_cycle" }.to_json
        assert_raises(FileLayer::UnsupportedOperation) { transport.get("/v1/a") }
        assert_raises(FileLayer::UnsupportedOperation) { transport.get("/v1/b") }
      end

      test "501 is UnsupportedOperation -- the server gated the verb" do
        canned "/v1/tree", status: 501, body: { error: "syncable_unavailable" }.to_json
        assert_raises(FileLayer::UnsupportedOperation) { transport.get("/v1/tree") }
      end

      test "5xx is RETRYABLE -- FetchError, never NotFound" do
        canned "/v1/tree", status: 503, body: { error: "upstream" }.to_json
        assert_raises(FileLayer::FetchError) { transport.get("/v1/tree") }
      end

      test "a rejected device token is RETRYABLE, not a claim the file is gone" do
        # §14a's share lesson one wire further out: an expired or rotated token is an operator
        # condition. Answering NotFound would render 404 and tell a user their library vanished.
        canned "/v1/tree", status: 401, body: { error: "unauthorized" }.to_json
        assert_raises(FileLayer::FetchError) { transport.get("/v1/tree") }
        canned "/v1/tree", status: 403, body: { error: "forbidden" }.to_json
        assert_raises(FileLayer::FetchError) { transport.get("/v1/tree") }
      end

      test "an unreachable server is FetchError, not an unmapped Errno reaching the controller" do
        dead = Transport.new(base_url: "http://127.0.0.1:1", token: "tok", open_timeout: 0.2)
        assert_raises(FileLayer::FetchError) { dead.get("/v1/tree") }
      end

      test "a read timeout is FetchError" do
        canned "/v1/slow", status: 200, body: "{}", delay: 0.5
        assert_raises(FileLayer::FetchError) { transport(read_timeout: 0.1).get("/v1/slow") }
      end

      test "a non-JSON error body does not replace the status with a parser error" do
        # A proxy's own HTML 502 page. The status is already known; the body only enriches the
        # message, so a parse failure must not become the failure.
        canned "/v1/tree", status: 502, body: "<html>Bad Gateway</html>", content_type: "text/html"
        assert_raises(FileLayer::FetchError) { transport.get("/v1/tree") }
      end

      test "an empty 2xx body is an empty hash, not a parser error" do
        canned "/v1/nodes/x", status: 204, body: ""
        assert_equal({}, transport.delete("/v1/nodes/x"))
      end
    end
  end
end
