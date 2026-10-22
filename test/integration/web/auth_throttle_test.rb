require "test_helper"

module Web
  # Per-source throttles on the four unauthenticated auth entry points, and the per-account one on
  # sign-in.
  #
  # NO ACCOUNT LOCKS ANY MORE (pentest M4b, tinkerex#466). Devise :lockable's failed-attempts lock
  # let anyone who knew an address lock its owner out for an hour, from one IP, again and again; the
  # per-IP limit beside it did not stop that, because ten attempts fit in one window. Sign-in is now
  # bounded by Tinkerex::SignInThrottle -- per source, and per account per source -- and the test
  # that matters most here is the one where a stranger fails from one address and the owner still
  # signs in from another.
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

    def sign_in_from(ip, email:, password:)
      post user_session_path, params: { user: { email:, password: } }, env: { "REMOTE_ADDR" => ip }
    end

    # THE FINDING ITSELF. Eleven wrong passwords from one source used to lock the account, and the
    # owner, signing in from home, was refused for an hour. Mutation-checked: with
    # `config.lock_strategy = :failed_attempts` restored, the owner's sign-in below is refused.
    test "wrong passwords from one source never keep the owner out from another" do
      11.times { sign_in_from("198.51.100.66", email: @user.email, password: "wrong") }
      assert_redirected_to new_user_session_path, "precondition: the stranger's source is throttled"

      sign_in_from("203.0.113.10", email: @user.email, password: PASSWORD)
      assert_redirected_to root_path, "the owner signs in from their own source"
      assert_not @user.reload.access_locked?
      get files_path
      assert_response :success
    end

    # THE PER-ACCOUNT LIMIT, ON ITS OWN. Its budget outlives the per-source window: four minutes on,
    # the source may try any other account, but not this one again for the rest of the hour.
    # Mutation-checked: without the `per-account` rate_limit the eleventh attempt below is
    # answered as a plain wrong password.
    test "one source gets ten attempts an hour at one account, and the limit stops nobody else" do
      other = User.create!(email: "bystander@example.com", password: PASSWORD, confirmed_at: Time.current)
      10.times do
        sign_in_from("198.51.100.66", email: @user.email, password: "wrong")
        assert_response :unprocessable_entity
      end

      travel 4.minutes do
        sign_in_from("198.51.100.66", email: @user.email.upcase, password: PASSWORD)
        assert_redirected_to new_user_session_path, "the eleventh attempt at this account, even correct"
        assert_match(/too many/i, flash[:alert].to_s)

        sign_in_from("198.51.100.66", email: other.email, password: PASSWORD)
        assert_redirected_to root_path, "another account from the same source is unaffected"
      end
    end

    # The per-account key reads `user[email]` before Devise does. A hand-made POST whose `user` is a
    # string must get Devise's own refusal, not a 500 from inside the throttle. Mutation-checked:
    # with `params.dig(:user, :email)` in the key, this raised.
    test "a sign-in whose user param is not a hash is refused, not crashed on" do
      post user_session_path, params: { user: "x" }
      assert_response :unprocessable_entity
    end

    # An IPv6 host owns its whole /64, so a per-address budget would bound nothing.
    test "addresses in one IPv6 /64 share one source budget" do
      10.times { |i| sign_in_from("2001:db8:7:7::#{i + 1}", email: "nobody#{i}@example.com", password: "wrong") }
      sign_in_from("2001:db8:7:7::ffff", email: @user.email, password: PASSWORD)
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
