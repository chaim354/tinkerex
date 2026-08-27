require "test_helper"

module V1
  # §6 IN THE FORM OF A CHECK RATHER THAN PROSE: this app implements the CLIENT half of the sync
  # protocol and serves NONE of it. Since Arc D Part 2 the engine is not in this process, so a
  # desktop client syncs against the standalone sync server (chaim354/tinkerex-sync) and every one
  # of the endpoints below is simply not routed here.
  #
  # WHY 404 AND NOT 501: a route that does not exist is the honest answer for a deployment whose
  # engine is not in the process at all (§14a's gate answers 501 for a capability this app HAS but
  # this backend cannot serve — a different claim). A driven request, not `recognize_path`: §15
  # records that as the wrong instrument for a routing question in this file.
  #
  # THE LAST ASSERTION IS WHAT KEEPS THIS FROM BEING VACUOUS. Ten 404s would also be produced by an
  # app with no /v1 namespace at all, so the suite would stay green over a deleted API. Pinning
  # that POST /v1/devices/login is NOT a 404 makes absence the claim and presence the instrument.
  class SyncSurfaceAbsentTest < ActionDispatch::IntegrationTest
    # Verb + path exactly as docs/sync-protocol.md spells them, so a route re-added under the
    # protocol's own name is caught rather than a near-miss spelling.
    ABSENT = [
      [ :post,   "/v1/commit" ],
      [ :post,   "/v1/commit/abc/finalize" ],
      [ :get,    "/v1/changes" ],
      [ :get,    "/v1/tree" ],
      [ :post,   "/v1/nodes" ],
      [ :get,    "/v1/conflicts" ],
      [ :get,    "/v1/locks" ],
      [ :post,   "/v1/trash/x/restore" ],
      [ :get,    "/v1/chunks/download" ],
      [ :post,   "/v1/share_links" ]
    ].freeze

    test "no sync-protocol endpoint is routed by this app" do
      ABSENT.each do |verb, path|
        process(verb, path, as: :json)
        assert_equal 404, response.status,
                     "#{verb.to_s.upcase} #{path} is routed here — this app serves the CLIENT half " \
                     "of the sync protocol only (§6); a device syncs against chaim354/tinkerex-sync."
      end
    end

    test "the app's own v1 API is still routed, so the absences above mean something" do
      post "/v1/devices/login", params: {}, as: :json
      assert_not_equal 404, response.status,
                       "POST /v1/devices/login is gone — this app has no v1 API left, and the " \
                       "404s asserted above prove nothing (§14e: a guard that scans nothing passes)."
    end
  end
end
