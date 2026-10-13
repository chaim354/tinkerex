require "test_helper"

module V1
  # Per-IP throttle on the one v1 endpoint that takes HUMAN credentials. Lockable (10 misses, one
  # hour) bounds guesses at ONE account; this bounds one guess each at ten thousand accounts, and
  # it stops anyone who knows an address from locking that account over and over — the lock also
  # blocks web sign-in. Mirrors users/sessions_controller.rb's numbers so the two doors agree.
  #
  # THE COUNTER LIVES IN ActionController::API's cache_store — NOT Base's: each controller base
  # class builds its own MemoryStore from config.action_controller.cache_store (test_helper.rb
  # explains) — AND IS SHARED ACROSS TESTS (every integration request comes from 127.0.0.1), so
  # setup clears it.
  class DeviceLoginThrottleTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      ActionController::API.cache_store.clear
      @target  = User.create!(email: "api-target@example.com",  password: PASSWORD, confirmed_at: Time.current)
      @another = User.create!(email: "api-another@example.com", password: PASSWORD, confirmed_at: Time.current)
    end

    def login(email, password)
      post "/v1/devices/login", params: { email:, password:, device_name: "laptop" }, as: :json
      response
    end

    test "attempts past the per-IP limit are refused with 429, not 401" do
      10.times do
        login(@target.email, "wrong")
        assert_response :unauthorized, "attempts under the limit get the normal answer"
      end
      login(@target.email, "wrong")
      assert_response :too_many_requests
      assert_equal "too_many_attempts", JSON.parse(response.body)["error"]
    end

    test "a throttled IP cannot enrol even with the CORRECT password of an UNLOCKED account" do
      # Gates the ACTION, not just failures: the correct guess on attempt 12 must not be let
      # through. A second account, so lockable's own 401 on the first cannot stand in for the
      # throttle's 429 — without the throttle this request would mint a device and answer 201.
      11.times { login(@target.email, "wrong") }
      assert_no_difference -> { Device.count } do
        login(@another.email, PASSWORD)
        assert_response :too_many_requests
      end
    end
  end
end
