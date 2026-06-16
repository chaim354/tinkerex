require "test_helper"

module V1
  # Device enrollment by login (the Dropbox model). Valid creds of a CONFIRMED account ->
  # a device token; wrong password / unknown email / unconfirmed / locked -> 401. Replaces
  # the pairing-code flow. The v1 sync endpoints keep using the returned device token.
  class DeviceLoginTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze
    setup { Storage::ChunkStore.reset! }

    def login(email:, password:, device_name: "laptop")
      post "/v1/devices/login",
           params: { email:, password:, device_name: }, as: :json
      response
    end

    test "valid credentials of a confirmed account return a device token" do
      User.create!(email: "dev@example.com", password: PASSWORD, confirmed_at: Time.current)
      assert_difference -> { Device.count }, 1 do
        r = login(email: "dev@example.com", password: PASSWORD)
        assert_response :created
        body = JSON.parse(r.body)
        assert body["device_token"].present?
        assert body["user_id"].present?
      end
    end

    test "the returned token works against the owner's library" do
      User.create!(email: "dev2@example.com", password: PASSWORD, confirmed_at: Time.current)
      token = JSON.parse(login(email: "dev2@example.com", password: PASSWORD).body)["device_token"]
      get "/v1/tree", params: { after_id: 0 }, headers: { "Authorization" => "Bearer #{token}" }
      assert_response :success
    end

    test "a wrong password is rejected with 401 and mints no device" do
      User.create!(email: "dev3@example.com", password: PASSWORD, confirmed_at: Time.current)
      assert_no_difference -> { Device.count } do
        r = login(email: "dev3@example.com", password: "wrong")
        assert_response :unauthorized
        assert_nil JSON.parse(r.body)["device_token"]
      end
    end

    test "an unknown email is rejected with the same generic 401 (no enumeration)" do
      r = login(email: "nobody@example.com", password: PASSWORD)
      assert_response :unauthorized
      assert_equal "invalid_credentials", JSON.parse(r.body)["error"]
    end

    test "an UNCONFIRMED account cannot enroll a device" do
      User.create!(email: "unconf@example.com", password: PASSWORD) # confirmed_at nil
      assert_no_difference -> { Device.count } do
        r = login(email: "unconf@example.com", password: PASSWORD)
        assert_response :unauthorized
        assert_equal "invalid_credentials", JSON.parse(r.body)["error"]
      end
    end

    test "the account LOCKS after too many failed attempts (lockable)" do
      User.create!(email: "lock@example.com", password: PASSWORD, confirmed_at: Time.current)
      # Devise maximum_attempts = 10 (config/initializers/devise.rb).
      11.times { login(email: "lock@example.com", password: "wrong") }
      assert User.find_by(email: "lock@example.com").access_locked?,
             "account is locked after exceeding maximum_attempts"
      # Even the CORRECT password is now refused while locked.
      assert_no_difference -> { Device.count } do
        r = login(email: "lock@example.com", password: PASSWORD)
        assert_response :unauthorized
      end
    end
  end
end
