require "test_helper"

class OpenscadClientTest < ActiveSupport::TestCase
  test "configured? reflects OPENSCAD_SIDECAR_URL" do
    with_env("OPENSCAD_SIDECAR_URL" => nil) { assert_not OpenscadClient.configured? }
    with_env("OPENSCAD_SIDECAR_URL" => "http://openscad:8000") { assert OpenscadClient.configured? }
  end

  test "configured? is false for a BLANK url, not just a missing one" do
    # deploy.ovh.yml clears the sidecar URLs by setting them to "" (Task 1) — Kamal deep-merges
    # env.clear, so blanking is the only way to un-inherit. If blank read as configured, that
    # overlay would report the addon available and then fail on every call.
    with_env("OPENSCAD_SIDECAR_URL" => "") { assert_not OpenscadClient.configured? }
  end

  # --- the two 422s ------------------------------------------------------------------------------
  #
  # THE SIDECAR ANSWERS 422 FOR TWO DIFFERENT THINGS and Tools::OpenscadController must react
  # differently to each: a .scad it cannot parse bounces the user to the index, a submitted VALUE it
  # refuses to coerce (sidecar/openscad/coerce.py) hands the editor back with their own form still in
  # it. The status cannot tell them apart, so the sidecar tags the second with
  # `code: "invalid_params"` and this is the seam that reads it.
  #
  # DRIVEN OVER A REAL SOCKET, not a stubbed Net::HTTP. What is under test IS the wire handling —
  # which status, which body key, which exception class — and a double handing back a pre-built
  # response object would only assert the double's own idea of that wire (CLAUDE.md §14e, the FakeS3
  # lesson: assert the WIRE FORMAT, not the round-trip).

  test "a 422 tagged invalid_params raises InvalidParams carrying the sidecar's own sentence" do
    message = "“cols” must be a number (got “))(”)"
    with_sidecar(status: "422 Unprocessable Entity",
                 body: { error: message, code: "invalid_params" }.to_json) do |client|
      e = assert_raises(OpenscadClient::InvalidParams) do
        client.render(scad: "cube(1);", params: { "cols" => "))(" })
      end
      assert_equal message, e.message
    end
  end

  test "a 422 with NO code stays a plain Error — the two 422s must not collapse" do
    with_sidecar(status: "422 Unprocessable Entity",
                 body: { error: "Parser error: syntax error in line 3" }.to_json) do |client|
      e = assert_raises(OpenscadClient::Error) { client.render(scad: "{{{", params: {}) }
      assert_not_kind_of OpenscadClient::InvalidParams, e,
                         "a broken .scad must not be reported as the user's value being wrong"
      assert_equal "Parser error: syntax error in line 3", e.message
    end
  end

  test "InvalidParams IS an Error, so every existing rescue keeps catching it" do
    # The subclass exists so ONE caller can branch (§14a). Making it a sibling instead would leave
    # #preview and every other `rescue OpenscadClient::Error` silently uncovered — a 500 on a typo.
    assert_operator OpenscadClient::InvalidParams, :<, OpenscadClient::Error
  end

  test "a failure body that is not JSON still surfaces the body, not a bare status" do
    # gunicorn and kamal-proxy both answer HTML when they fail, and the sidecar's own message is the
    # only actionable part of any of it.
    with_sidecar(status: "500 Internal Server Error", body: "<html>worker timed out</html>",
                 content_type: "text/html") do |client|
      e = assert_raises(OpenscadClient::Error) { client.render(scad: "cube(1);", params: {}) }
      assert_match "worker timed out", e.message
    end
  end

  test "a failure body that is valid JSON but NOT an object does not blow up the client" do
    # `body["error"]` on a parsed Array is a TypeError, and it would escape as a 500 from inside the
    # code whose whole job is to describe a failure. "It parsed" is not "it is a Hash".
    with_sidecar(status: "422 Unprocessable Entity", body: "[1,2,3]") do |client|
      e = assert_raises(OpenscadClient::Error) { client.render(scad: "cube(1);", params: {}) }
      assert_equal "[1,2,3]", e.message
    end
  end

  test "a failure with an EMPTY body falls back to naming the status" do
    with_sidecar(status: "502 Bad Gateway", body: "") do |client|
      e = assert_raises(OpenscadClient::Error) { client.render(scad: "cube(1);", params: {}) }
      assert_equal "openscad sidecar 502", e.message
    end
  end

  private

  # A one-shot HTTP server on an ephemeral port. ~15 lines of TCPServer and no gem: this repo has no
  # webmock and no Object#stub (minitest 6 dropped minitest/mock — test/test_helper.rb).
  def with_sidecar(status:, body:, content_type: "application/json")
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      socket = server.accept
      # DRAIN THE REQUEST FIRST. Headers to the blank line, then Content-Length bytes — replying
      # without reading the body leaves Net::HTTP blocked writing into a full socket buffer.
      length = 0
      while (line = socket.gets) && line != "\r\n"
        length = line.split(":", 2).last.to_i if line.match?(/\AContent-Length:/i)
      end
      socket.read(length) if length.positive?
      socket.print("HTTP/1.1 #{status}\r\nContent-Type: #{content_type}\r\n" \
                   "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
      socket.close
    end
    yield OpenscadClient.new("http://127.0.0.1:#{server.addr[1]}")
  ensure
    thread&.join(5)
    server&.close
  end

  def with_env(vars)
    old = {}
    vars.each { |k, v| old[k] = ENV.key?(k) ? ENV[k] : :unset; v.nil? ? ENV.delete(k) : (ENV[k] = v) }
    yield
  ensure
    old.each { |k, v| v == :unset ? ENV.delete(k) : (ENV[k] = v) }
  end
end
