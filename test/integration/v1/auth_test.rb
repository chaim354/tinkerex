require "test_helper"

module V1
  # The auth boundary: registration must NOT hand out a token for an existing email
  # (account takeover), and additional devices join only via a single-use, expiring
  # pairing code issued by an already-authenticated device.
  class AuthTest < ActionDispatch::IntegrationTest
    setup { Storage::ChunkStore.reset! }

    def post_json(path, body, token: nil)
      hdrs = token ? { "Authorization" => "Bearer #{token}" } : {}
      post path, params: body, as: :json, headers: hdrs
      response
    end

    test "register creates a new account + first device token" do
      r = post_json("/v1/auth/register", { email: "new@example.com", device_name: "laptop" })
      assert_response :created
      body = JSON.parse(r.body)
      assert body["device_token"].present?
      assert_equal 1, User.where(email: "new@example.com").count
    end

    test "register REFUSES an existing email (no account takeover)" do
      User.create!(email: "taken@example.com")
      assert_no_difference -> { Device.count } do
        r = post_json("/v1/auth/register", { email: "taken@example.com", device_name: "evil" })
        assert_response :conflict
        assert_equal "account_exists", JSON.parse(r.body)["error"]
        assert_nil JSON.parse(r.body)["device_token"], "must not leak a token for a known email"
      end
    end

    test "pairing: an authed device issues a code, a new device redeems it" do
      owner = JSON.parse(post_json("/v1/auth/register", { email: "owner@example.com" }).body)
      assert_response :created

      # Issue a pairing code (requires the owner's token).
      issued = JSON.parse(post_json("/v1/devices/pairing", {}, token: owner["device_token"]).body)
      assert_response :created
      assert issued["code"].present?

      # Redeem it from a new, unauthenticated device.
      paired = JSON.parse(post_json("/v1/auth/pair", { email: "owner@example.com", code: issued["code"] }).body)
      assert_response :created
      new_token = paired["device_token"]
      assert new_token.present?
      assert_not_equal owner["device_token"], new_token, "a distinct device token"

      # The paired token actually works against the owner's library.
      get "/v1/tree", params: { after_id: 0 }, headers: { "Authorization" => "Bearer #{new_token}" }
      assert_response :success
    end

    test "issuing a pairing code requires authentication" do
      post_json("/v1/devices/pairing", {})
      assert_response :unauthorized
    end

    test "a wrong code is rejected" do
      post_json("/v1/auth/register", { email: "owner2@example.com" })
      r = post_json("/v1/auth/pair", { email: "owner2@example.com", code: "WRONGXXX" })
      assert_response :unauthorized
      assert_equal "invalid_pairing", JSON.parse(r.body)["error"]
    end

    test "an expired code is rejected" do
      user = User.create!(email: "owner3@example.com")
      p = DevicePairing.issue!(user:)
      code = p.plaintext_code
      p.update_column(:expires_at, 1.minute.ago)
      assert_no_difference -> { Device.count } do
        post_json("/v1/auth/pair", { email: "owner3@example.com", code: })
        assert_response :unauthorized
      end
    end

    test "a code is single-use" do
      user = User.create!(email: "owner4@example.com")
      code = DevicePairing.issue!(user:).plaintext_code
      post_json("/v1/auth/pair", { email: "owner4@example.com", code: })
      assert_response :created
      # Second redemption of the same code fails.
      post_json("/v1/auth/pair", { email: "owner4@example.com", code: })
      assert_response :unauthorized
    end

    test "pairing an unknown email gives the same generic error (no enumeration)" do
      r = post_json("/v1/auth/pair", { email: "nobody@example.com", code: "ABCDEFGH" })
      assert_response :unauthorized
      assert_equal "invalid_pairing", JSON.parse(r.body)["error"]
    end

    test "a code only works for its own user's library" do
      a = User.create!(email: "a-owner@example.com")
      User.create!(email: "b-owner@example.com")
      code = DevicePairing.issue!(user: a).plaintext_code
      # B's email + A's code → rejected (the code is scoped to A).
      post_json("/v1/auth/pair", { email: "b-owner@example.com", code: })
      assert_response :unauthorized
    end
  end
end
