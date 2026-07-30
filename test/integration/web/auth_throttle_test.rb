require "test_helper"

module Web
  # Per-IP throttles on the four unauthenticated auth entry points.
  #
  # WHAT THIS ADDS OVER DEVISE :lockable, WHICH IS ALREADY ON: lockable bounds guesses against
  # ONE account (10 attempts, then an hour). It does nothing about spraying one attempt each
  # across many accounts, nothing about password-reset and confirmation-resend each sending a
  # real email per POST, and nothing about the flip side of lockable — anyone who knows an
  # address can lock that account for an hour, repeatedly. Per-IP limiting is what makes lockable
  # a safeguard rather than a weapon.
  #
  # THE COUNTER LIVES IN config.action_controller.cache_store AND IS SHARED ACROSS TESTS,
  # because `by:` defaults to request.remote_ip and every integration test comes from 127.0.0.1.
  # Clear it in setup or the second test in the file starts already throttled.
  class AuthThrottleTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      ActionController::Base.cache_store.clear
      @user = User.create!(email: "throttled@example.com", password: PASSWORD,
                           confirmed_at: Time.current)
    end

    test "the store backing rate limits is real, not a null store" do
      # Guards the config change in the Solid Cache commit. With a NullStore, increment returns
      # nil and every throttle in this file becomes a no-op that no other assertion here would
      # notice — the tests would fail, but for a reason that reads like a missing throttle.
      assert_not_kind_of ActiveSupport::Cache::NullStore, ActionController::Base.cache_store
    end

    test "login attempts past the limit are refused" do
      10.times do
        post user_session_path, params: { user: { email: @user.email, password: "wrong" } }
        assert_response :unprocessable_entity, "attempts under the limit get the normal answer"
      end

      post user_session_path, params: { user: { email: @user.email, password: "wrong" } }
      assert_redirected_to new_user_session_path
      assert_match(/too many/i, flash[:alert].to_s)
    end

    test "a throttled IP cannot log in even with the CORRECT password" do
      # The throttle must gate the endpoint, not just failures — otherwise an attacker who
      # guesses correctly on attempt 11 is let straight through.
      11.times do
        post user_session_path, params: { user: { email: @user.email, password: "wrong" } }
      end
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      assert_redirected_to new_user_session_path

      get files_path
      assert_redirected_to new_user_session_path, "must not be signed in"
    end

    test "password-reset requests past the limit send no further mail" do
      5.times do
        post user_password_path, params: { user: { email: @user.email } }
      end
      assert_no_emails do
        post user_password_path, params: { user: { email: @user.email } }
      end
      assert_match(/too many/i, flash[:alert].to_s)
    end

    test "confirmation resends past the limit send no further mail" do
      unconfirmed = User.create!(email: "pending@example.com", password: PASSWORD)
      5.times do
        post user_confirmation_path, params: { user: { email: unconfirmed.email } }
      end
      assert_no_emails do
        post user_confirmation_path, params: { user: { email: unconfirmed.email } }
      end
    end

    test "signups past the limit create no further accounts" do
      5.times do |i|
        post user_registration_path, params: { user: {
          email: "new#{i}@example.com", password: PASSWORD, password_confirmation: PASSWORD
        } }
      end
      assert_no_difference "User.count" do
        post user_registration_path, params: { user: {
          email: "blocked@example.com", password: PASSWORD, password_confirmation: PASSWORD
        } }
      end
    end
  end
end
