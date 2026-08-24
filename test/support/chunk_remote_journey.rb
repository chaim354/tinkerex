# frozen_string_literal: true

require "net/http"

# THE RIG FOR DRIVING THE MAKER APP AGAINST A REAL SYNC SERVER.
#
# THE SKIP IS ON THE SERVER, NEVER ON THE CLAIM. §14j records a guard that skipped on
# `defined?(Sync)` -- the very thing it asserted -- so the mutation that broke it made every test
# skip and the suite report success. Here the skip is on whether a server was CONFIGURED, which is
# a precondition, and the "does not skip when a server is configured" test in
# test/integration/chunk_remote_journey_test.rb is the mutation-check that the precondition is
# not quietly always false. Named by its DESCRIPTION, not Rails' mangled method name -- `test
# "..."` turns a string into `test_<description, spaces to underscores>`, and a hand-typed guess
# at that mangling is a second spelling that can silently drift from the real one.
module ChunkRemoteJourney
  PASSWORD = "correct horse battery staple"

  def self.configured? = ENV["CHUNK_REMOTE_URL"].present? && ENV["CHUNK_REMOTE_TOKEN"].present?

  def skip_unless_remote_server
    return if ChunkRemoteJourney.configured? && ENV["LIBRARY_BACKEND"] == "chunk_remote"

    skip "needs LIBRARY_BACKEND=chunk_remote plus CHUNK_REMOTE_URL/CHUNK_REMOTE_TOKEN " \
         "(bin/sync-server prepare && bin/sync-server start)"
  end

  # Real password auth against the maker app -- the web UI is session-authed, never the v1 token
  # (§14d), so a journey that skipped this would exercise a door no user goes through.
  def sign_in(email = "journey@example.com")
    user = User.find_by(email:) ||
           User.create!(email:, password: PASSWORD, confirmed_at: Time.current)
    post user_session_path, params: { user: { email:, password: PASSWORD } }
    # NOT `assert_response :redirect` -- a FAILED sign-in redirects too (Devise's own
    # FailureApp#redirect, and this app's per-IP rate-limit hook in Users::SessionsController,
    # both `redirect_to`), so a bare 3xx cannot tell success from failure and every request this
    # helper's caller makes afterward would silently run unauthenticated while this reported fine.
    # `files_path` is the real destination -- ApplicationController#after_sign_in_path_for.
    assert_redirected_to files_path
    user
  end

  # THE UPLOAD, AND THE ONE PLACE THIS DIFFERS STRUCTURALLY FROM Web::FilesFlowTest.
  #
  # That suite does `put url, params: bytes` -- an INTEGRATION-SESSION request, which works only
  # because embedded chunk presigns a RELATIVE path back into the same app. chunk_remote's
  # put_urls are ABSOLUTE and point at the sync server, which the integration session cannot
  # reach. Net::HTTP is not a stylistic choice here; it is the only thing that can perform this
  # request, and using the session instead would silently upload nothing and still assert 200.
  def upload_through_ui(name, bytes, parent_node_id: nil)
    hash = Digest::SHA256.hexdigest(bytes)
    manifest = [ { hash:, offset: 0, length: bytes.bytesize } ]

    post begin_upload_files_path,
         params: { name:, size: bytes.bytesize, manifest:, parent_node_id: }, as: :json
    assert_response :success, "begin_upload failed: #{response.body}"
    begun = JSON.parse(response.body)

    # CONTENT-ADDRESSED, SO A REPEAT OF FIXED BYTES GOES DARK HERE. journey_prefix (below)
    # randomizes the NAME, never the BYTES -- the sync server dedupes chunks by content hash, so
    # a second upload of identical bytes gets back an EMPTY put_urls (the store already has that
    # chunk), and this loop is a correct no-op. finalize_upload's verify: true still passes,
    # because the bytes genuinely are there -- from a PREVIOUS run. This method's own headline
    # claim, that Net::HTTP is the only thing that can perform this request, silently stops being
    # exercised while the suite stays green. A caller that wants to exercise the wire must vary
    # its CONTENT, not just the filename.
    (begun["put_urls"] || {}).each_value { |url| put_bytes_to_storage(url, bytes) }

    post finalize_upload_files_path, params: { commit_id: begun["commit_id"] }, as: :json
    assert_response :success, "finalize_upload failed: #{response.body}"
    begun["node_id"]
  end

  def put_bytes_to_storage(url, bytes)
    uri = URI.parse(url)
    req = Net::HTTP::Put.new(uri)
    req["Content-Type"] = "application/octet-stream"
    req.body = bytes
    # TIMEOUTS AND THE RESCUE LIST MATCH FileLayer::ChunkRemote::Transport, which talks to this
    # same server for the same reason: Ruby's stdlib default (60s) would turn an unstarted or
    # hung sync server into a slow, unexplained hang here instead of a fast, readable failure.
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                           open_timeout: FileLayer::ChunkRemote::Transport::OPEN_TIMEOUT,
                           read_timeout: FileLayer::ChunkRemote::Transport::READ_TIMEOUT) do |h|
      h.request(req)
    end
    assert res.is_a?(Net::HTTPSuccess),
           "PUT #{uri} returned #{res.code}: #{res.body.to_s[0, 200]}"
  rescue Timeout::Error, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ECONNRESET,
         SocketError, OpenSSL::SSL::SSLError, IOError => e
    flunk "PUT #{uri} could not reach the sync server (#{e.class}): #{e.message} -- " \
          "is it running? (bin/sync-server start)"
  end

  # A PREFIX UNIQUE TO EACH TEST, NOT EACH RUN. Minitest instantiates a fresh test instance per
  # test METHOD, so `@journey_prefix ||=` memoizes once per test rather than once per suite
  # execution -- a stronger property, but worth stating precisely: a future reader could
  # otherwise assume the prefix is stable across the tests in this file and build on that. It
  # matters because one sync library is shared by every test in this suite (see the plan's scope
  # note) and the server does not roll back with the maker DB. Real per-test isolation on the
  # SERVER's own state needs Arc C's provisioning endpoint; until then, disjoint names are what
  # keeps two runs of the same test from colliding at 409.
  def journey_prefix = @journey_prefix ||= "j#{SecureRandom.hex(4)}"
end
