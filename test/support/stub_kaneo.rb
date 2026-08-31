require "socket"
require "json"

# A localhost stand-in for Kaneo that RECORDS REQUESTS VERBATIM.
#
# It deliberately does NOT model Kaneo. It captures method, path, headers and raw body, and
# replays whatever the test told it to. §14e records why that distinction matters: FakeS3 decoded
# with CGI.unescape while the adapter encoded with CGI.escape — exact inverses — so 79 of 80 tests
# were green over silent permanent data loss on any filename containing a space. A fake that
# implements the same misunderstanding as the code under test confirms it rather than catching it.
# So: assert against `stub.requests`, never against a round-trip through this object.
#
# FIVE RULES, EACH A REAL WAY THIS BITES IN A FORKING SUITE (test_helper parallelizes by processor):
#
#   1. NEVER CONSTRUCT ONE BEFORE THE FORK. A child inherits the LISTENING SOCKET but not the
#      accept thread, so `connect` still succeeds and the request lands in the parent's backlog —
#      worker A's bin/log recorded by worker B's stub. Build it inside the test body. Never a
#      class constant, never parallelize_setup.
#   2. READ EXACTLY Content-Length BYTES, NEVER TO EOF. Net::HTTP holds the socket open awaiting a
#      response, so read-to-EOF deadlocks until the 15 s read timeout and the test then sees exit 3
#      with an empty `requests` — which reads as "bin/log sent nothing".
#   3. RESPOND WITH AN EXPLICIT Content-Length AND Connection: close.
#   4. THE ACCEPT LOOP RESCUES IOError/EBADF/ECONNRESET, AND close JOINS INSIDE A RESCUE. Closing
#      the socket while a thread blocks in accept raises there; unrescued it surfaces at `join`
#      inside an ensure and fails an otherwise-passing test, masking the real assertion.
#   5. PORT 0 binds and listens before `new` returns, so `url` is valid immediately — no
#      did-it-start race — and forked workers can never collide on a port.
class StubKaneo
  Request = Struct.new(:method, :path, :headers, :body, keyword_init: true) do
    def json = JSON.parse(body)
  end

  attr_reader :requests, :errors

  # `routes` maps "METHOD /path-fragment" to a reply, so one stub can serve a GET /labels list and a
  # POST /issues result in the same test — which the real flow needs, because an issue create must
  # first resolve label NAMES to the int64 IDs Kaneo demands. A value may be a single
  # [status, body] pair, or an ARRAY of them consumed in order (last one repeats), for flows whose
  # second call must see the effect of the first.
  # THE DEFAULT IS A KANEO TASK, NOT A FORGEJO ISSUE. `state`/`body` became `status`/`description`,
  # `status` is kebab-case (a POST carrying "Open" is refused with a 400 naming the valid set), and a
  # task carries an opaque `id` beside its citable `number` — every Kaneo path addresses the id.
  def initialize(status: 201,
                 response: { "id" => "task_stub", "number" => 42, "title" => "stub",
                             "status" => "to-do", "description" => "" },
                 routes: {})
    @requests = []
    @errors = []
    @routes = routes.transform_values { |v| v.first.is_a?(Array) ? v.dup : [ v ] }
    @server = TCPServer.new("127.0.0.1", 0)
    # A String response is sent RAW — that is how a test drives the non-JSON-2xx path, which is
    # what a proxy error page and Kaneo's own login page both look like on the wire.
    @payload = response.is_a?(String) ? response : JSON.generate(response)
    @status = status

    @thread = Thread.new do
      loop do
        socket = @server.accept
        handle(socket)
      rescue IOError, Errno::EBADF, Errno::ECONNRESET
        break
      end
    end
  end

  def url = "http://127.0.0.1:#{@server.addr[1]}"

  def shutdown
    @server.close
  rescue IOError, Errno::EBADF
    nil
  ensure
    begin
      @thread&.join(5)
    rescue IOError, Errno::EBADF, Errno::ECONNRESET
      nil
    end
  end

  private

  # HANDLE RESCUES EVERYTHING, AND THAT CLOSES TWO FAILURES AT ONCE. Measured: if `handle` raises,
  # the `ensure socket.close` fires with no response written and the client sits on its 15 s read
  # timeout, after which bin/log reports "Kaneo is unreachable - Net::ReadTimeout" - so a STUB
  # BUG presents as a transport failure, costs 15 s per affected test, and multiplies by three
  # backend legs. Separately, a non-IO exception kills the accept thread, and `Thread#join`
  # RE-RAISES it from inside the test's `ensure`, masking the assertion that actually failed.
  # Answering 500 with the diagnostic fails the client fast AND keeps the thread alive; `errors`
  # lets a test assert the stub itself stayed healthy.
  def handle(socket)
    request_line = socket.gets.to_s
    method, path, = request_line.split(" ")

    headers = {}
    while (line = socket.gets) && line != "\r\n"
      key, value = line.split(":", 2)
      headers[key.to_s.strip.downcase] = value.to_s.strip
    end

    body = headers["content-length"] ? socket.read(headers["content-length"].to_i).to_s : ""
    @requests << Request.new(method: method, path: path, headers: headers, body: body)

    status, payload = reply_for(method, path)
    respond(socket, status, payload)
  rescue StandardError => e
    @errors << e
    # `respond` CAN ITSELF RAISE Errno::EPIPE (the client already gave up and closed its end) —
    # not in the accept loop's rescue list, so unrescued here it would kill this thread and
    # RE-RAISE at `Thread#join`, inside `shutdown`'s own rescued block only by luck of which
    # exception class it happens to be. Swallow it: this is already the fallback path, telling the
    # client what broke, and a client that stopped listening does not need to be told twice.
    respond(socket, 500, JSON.generate({ "stub_error" => "#{e.class}: #{e.message}" })) rescue nil
  ensure
    socket.close rescue nil
  end

  def reply_for(method, path)
    @routes.each do |key, queued|
      verb, fragment = key.split(" ", 2)
      next unless verb == method && path.include?(fragment)

      status, body = queued.size > 1 ? queued.shift : queued.first
      return [ status, body.is_a?(String) ? body : JSON.generate(body) ]
    end

    [ @status, @payload ]
  end

  def respond(socket, status, payload)
    socket.write("HTTP/1.1 #{status}\r\nContent-Type: application/json\r\n" \
                 "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
  end
end
