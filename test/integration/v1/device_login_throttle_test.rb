require "test_helper"

module V1
  # The throttles on the one v1 endpoint that takes HUMAN credentials, by the numbers the web
  # sign-in uses too (Tinkerex::SignInThrottle). Per source, it bounds one guess each at ten
  # thousand accounts; per account per source, ten an hour at one. Nothing locks an account any more
  # (pentest M4b): device_login_test.rb proves a stranger's misses cannot keep the owner out.
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
      # through. A second account, so the per-account limit on the first cannot stand in for the
      # per-source one -- without it this request would mint a device and answer 201.
      11.times { login(@target.email, "wrong") }
      assert_no_difference -> { Device.count } do
        login(@another.email, PASSWORD)
        assert_response :too_many_requests
      end
    end

    # The per-account limit outlives the per-source window: four minutes on, the source may enrol
    # for anyone else but may not try this account again this hour. Mutation-checked: without the
    # `per-account` rate_limit the eleventh login below mints a device.
    test "one source gets ten logins an hour at one account and no more, even with its password" do
      10.times do
        login(@target.email, "wrong")
        assert_response :unauthorized
      end
      travel 4.minutes do
        assert_no_difference -> { Device.count } do
          login(@target.email.upcase, PASSWORD)
          assert_response :too_many_requests
          assert_equal "too_many_attempts", JSON.parse(response.body)["error"]
        end
      end
    end
  end
end
