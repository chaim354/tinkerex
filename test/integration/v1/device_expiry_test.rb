require "test_helper"

module V1
  # IDLE EXPIRY AT THE API ITSELF (pentest H1b, tinkerex#465; the rule's edges are in
  # test/models/device_test.rb). Two things only a request can show: an expired token is refused
  # with the same 401 an unknown one gets, and the refusal does not stamp last_seen_at. If it did,
  # the request that was refused would restart the clock that refused it, and a second try would
  # succeed.
  class DeviceExpiryTest < ActionDispatch::IntegrationTest
    setup do
      @prior_idle = ENV["DEVICE_IDLE_DAYS"]
      ENV.delete("DEVICE_IDLE_DAYS")
      @device = Device.register!(user: User.create!(email: "idle-#{SecureRandom.hex(4)}@example.com",
                                                    confirmed_at: Time.current, omniauth_signup: true),
                                 name: "laptop")
    end

    teardown { @prior_idle.nil? ? ENV.delete("DEVICE_IDLE_DAYS") : ENV["DEVICE_IDLE_DAYS"] = @prior_idle }

    def call_api
      get "/v1/maker/projects", headers: { "Authorization" => "Bearer #{@device.plaintext_token}" }
      response
    end

    test "a token in use slides: every request restarts the clock" do
      @device.update_column(:last_seen_at, (Device::IDLE_DAYS_DEFAULT - 1).days.ago)
      assert_response :success, call_api.status
      assert_in_delta Time.current, @device.reload.last_seen_at, 5.seconds
    end

    # Mutation-checked: with Device.authenticate returning an expired row, both requests answer 200.
    test "an expired token is refused, and refusing it does not restart its clock" do
      stale = (Device::IDLE_DAYS_DEFAULT + 1).days.ago
      @device.update_column(:last_seen_at, stale)

      2.times do
        call_api
        assert_response :unauthorized
        assert_equal({ "error" => "unauthorized" }, JSON.parse(response.body))
      end
      assert_in_delta stale, @device.reload.last_seen_at, 1.second
    end
  end
end
