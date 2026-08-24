# frozen_string_literal: true

require "net/http"

# THE RIG FOR DRIVING THE MAKER APP AGAINST A REAL SYNC SERVER.
#
# THE SKIP IS ON THE SERVER, NEVER ON THE CLAIM. §14j records a guard that skipped on
# `defined?(Sync)` -- the very thing it asserted -- so the mutation that broke it made every test
# skip and the suite report success. Here the skip is on whether a server was CONFIGURED, which is
# a precondition, and the "does not skip when a server is configured" test in
# test/integration/chunk_remote_journey_test.rb is the mutation-check for that precondition -- but
# ONLY because it does NOT call `skip_unless_remote_server` below. An earlier version of that test
# called this method via `setup { skip_unless_remote_server }`, shared with every other test in the
# class, which meant breaking THIS method to always skip took the canary down with it: every test
# skipped, including the one meant to notice, and the suite reported success having asserted
# nothing -- §14j's failure rebuilt one level up, inside the very test written to catch it. The
# canary now duplicates this method's CONDITION inline instead of calling it, so a mutation to this
# method's body cannot reach the canary at all. If you are reading this because you are about to
# have the canary call `skip_unless_remote_server` for the sake of not repeating the condition:
# don't -- that call IS the blind spot. Named by its DESCRIPTION, not Rails' mangled method name --
# `test "..."` turns a string into `test_<description, spaces to underscores>`, and a hand-typed
# guess at that mangling is a second spelling that can silently drift from the real one.
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
  #
  # THE DEFAULT EMAIL IS PER-TEST-UNIQUE, NOT A FIXED "journey@example.com" -- ARC C changed what
  # sharing one email across every test in this file would mean. Before Arc C every request
  # authenticated as the one bootstrap CHUNK_REMOTE_TOKEN device regardless of which maker user was
  # signed in, so which email `sign_in` used never mattered to the SYNC SERVER at all. Now each
  # user's first library write lazily provisions its OWN remote library
  # (FileLayer::ChunkRemote::Provisioning), and the maker test DB rolls back after every test
  # method while the SYNC SERVER's does not (journey_prefix's own comment) -- so a fixed email
  # would provision successfully on the FIRST test in a run and then 409 `email_taken` on every
  # test after it, because the local `sync_device_token` that call produced was rolled back with
  # everything else while the remote User it created was not. `journey_prefix` was already
  # memoized per test instance for exactly this kind of collision (see its own comment); reusing it
  # here gives every test its own remote library instead of merely disjoint node names within a
  # shared one, which is what that comment already anticipated this arc would let it do.
  def sign_in(email = "#{journey_prefix}@example.com")
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
  # otherwise assume the prefix is stable across the tests in this file and build on that.
  #
  # DOUBLE DUTY SINCE ARC C: this used to exist only to keep NODE NAMES disjoint within one shared
  # sync library -- every test in this file provisioned the SAME bootstrap device's library, so
  # without a unique prefix a `#{...}-bracket.stl` from one run would collide with an identically
  # named one from the last. `sign_in`'s own comment explains why that sharing is gone: each test
  # now provisions its OWN remote library, keyed by an email built from THIS prefix. Node-name
  # collisions across DIFFERENT tests are therefore no longer reachable at all (each test's nodes
  # live in an entirely separate remote user's tree) -- but a prefix unique to each run is still
  # worth keeping for the same reason it always was: the sync server's own DB does not roll back
  # with the maker DB (journey tests reuse ONE long-lived server across many local runs), so a
  # fixed name would still collide with a PREVIOUS run's own leftover nodes within this run's own
  # (now-private) library.
  def journey_prefix = @journey_prefix ||= "j#{SecureRandom.hex(4)}"
end
