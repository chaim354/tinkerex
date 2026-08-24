# frozen_string_literal: true

require "net/http"

# THE RIG FOR DRIVING THE MAKER APP AGAINST A REAL SYNC SERVER.
#
# THE SKIP IS ON THE SERVER, NEVER ON THE CLAIM. §14j records a guard that skipped on
# `defined?(Sync)` -- the very thing it asserted -- so the mutation that broke it made every test
# skip and the suite report success. Here the skip is on whether a server was CONFIGURED, which is
# a precondition, and `test_the_journey_suite_does_not_skip_when_configured` below is the
# mutation-check that the precondition is not quietly always false.
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
    assert_response :redirect
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
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") { |h| h.request(req) }
    assert res.is_a?(Net::HTTPSuccess),
           "PUT #{uri} returned #{res.code}: #{res.body.to_s[0, 200]}"
  end

  # A UNIQUE PREFIX PER RUN, because one sync library is shared by every test in this suite (see
  # the plan's scope note) and the server does not roll back with the maker DB. Per-test isolation
  # needs Arc C's provisioning endpoint; until then, disjoint names are what keeps two runs of the
  # same test from colliding at 409.
  def journey_prefix = @journey_prefix ||= "j#{SecureRandom.hex(4)}"
end
