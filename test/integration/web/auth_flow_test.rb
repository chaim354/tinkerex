require "test_helper"

module Web
  # The real human-identity web auth (docs/parity-roadmap.md §A Option 1): sign-up →
  # email confirmation → login → logout → password reset, with the email-ownership gate
  # (unconfirmed users can't sign in). The device-token + DevicePairing bootstrap is
  # exercised separately (test/integration/v1/auth_test.rb) and is unaffected by this.
  class AuthFlowTest < ActionDispatch::IntegrationTest
    include ActiveJob::TestHelper

    PASSWORD = "correct horse battery staple".freeze

    setup { ActionMailer::Base.deliveries.clear }

    # --- sign up ----------------------------------------------------------------------
    test "sign up creates an unconfirmed account and sends a confirmation email" do
      assert_enqueued_emails 1 do
        assert_difference -> { User.count }, 1 do
          post signup_path, params: { email: "alice@example.com", password: PASSWORD,
                                      password_confirmation: PASSWORD }
        end
      end
      assert_redirected_to login_path
      user = User.find_by(email: "alice@example.com")
      assert_not user.confirmed?, "new account starts unconfirmed"
      assert user.password_digest.present?, "password is hashed"
    end

    test "sign up rejects a mismatched password confirmation" do
      assert_no_difference -> { User.count } do
        post signup_path, params: { email: "bob@example.com", password: PASSWORD,
                                    password_confirmation: "different" }
      end
      assert_response :unprocessable_entity
    end

    test "sign up rejects a blank password" do
      assert_no_difference -> { User.count } do
        post signup_path, params: { email: "blank@example.com", password: "",
                                    password_confirmation: "" }
      end
      assert_response :unprocessable_entity
    end

    test "sign up rejects a duplicate email" do
      User.create!(email: "dup@example.com", password: PASSWORD, confirmed_at: Time.current)
      assert_no_difference -> { User.count } do
        post signup_path, params: { email: "dup@example.com", password: PASSWORD,
                                    password_confirmation: PASSWORD }
      end
      assert_response :unprocessable_entity
    end

    # --- email confirmation (proves email ownership; §12 step 5) -----------------------
    test "an UNCONFIRMED user cannot sign in" do
      User.create!(email: "unconf@example.com", password: PASSWORD)
      post login_path, params: { email: "unconf@example.com", password: PASSWORD }
      assert_redirected_to login_path
      assert_match(/confirm your email/i, flash[:alert])
      # Not signed in -> the file UI still redirects to login.
      get files_path
      assert_redirected_to login_path
    end

    test "confirming the email lets the user sign in" do
      user = User.create!(email: "carol@example.com", password: PASSWORD)
      token = user.generate_confirmation_token!

      get confirm_email_path(token: token)
      assert_redirected_to login_path
      assert user.reload.confirmed?

      post login_path, params: { email: "carol@example.com", password: PASSWORD }
      assert_redirected_to files_path
      follow_redirect!
      assert_response :success
    end

    test "an invalid or expired confirmation token does not confirm" do
      user = User.create!(email: "exp@example.com", password: PASSWORD)
      user.generate_confirmation_token!
      user.update_column(:confirmation_sent_at, 3.hours.ago) # past TOKEN_TTL

      get confirm_email_path(token: "garbage")
      assert_not user.reload.confirmed?
      assert_match(/invalid or has expired/i, flash[:alert])
    end

    test "resend confirmation sends a fresh link for an unconfirmed account" do
      User.create!(email: "resend@example.com", password: PASSWORD)
      assert_enqueued_emails 1 do
        post confirmations_path, params: { email: "resend@example.com" }
      end
      assert_redirected_to login_path
    end

    test "resend confirmation does not leak whether an email exists" do
      # Unknown email -> same generic response, no email sent.
      assert_no_enqueued_emails do
        post confirmations_path, params: { email: "nobody@example.com" }
      end
      assert_redirected_to login_path
    end

    # --- login / logout ----------------------------------------------------------------
    test "login with the wrong password is rejected generically" do
      User.create!(email: "dave@example.com", password: PASSWORD, confirmed_at: Time.current)
      post login_path, params: { email: "dave@example.com", password: "wrong" }
      assert_redirected_to login_path
      assert_match(/invalid email or password/i, flash[:alert])
    end

    test "login for an unknown email gives the same generic error (no enumeration)" do
      post login_path, params: { email: "ghost@example.com", password: PASSWORD }
      assert_redirected_to login_path
      assert_match(/invalid email or password/i, flash[:alert])
    end

    test "a confirmed user logs in, accesses the file UI, then logs out" do
      User.create!(email: "erin@example.com", password: PASSWORD, confirmed_at: Time.current)
      post login_path, params: { email: "erin@example.com", password: PASSWORD }
      assert_redirected_to files_path

      get files_path
      assert_response :success

      delete logout_path
      assert_redirected_to login_path
      # Session is gone -> file UI redirects back to login.
      get files_path
      assert_redirected_to login_path
    end

    test "login creates a server-side Session row keyed by a digest" do
      User.create!(email: "frank@example.com", password: PASSWORD, confirmed_at: Time.current)
      assert_difference -> { ::Session.count }, 1 do
        post login_path, params: { email: "frank@example.com", password: PASSWORD }
      end
      assert ::Session.last.token_digest.present?
    end

    # --- password reset ----------------------------------------------------------------
    test "requesting a reset emails a link for a known account" do
      User.create!(email: "gina@example.com", password: PASSWORD, confirmed_at: Time.current)
      assert_enqueued_emails 1 do
        post passwords_path, params: { email: "gina@example.com" }
      end
      assert_redirected_to login_path
    end

    test "requesting a reset for an unknown email does not leak (no email, generic msg)" do
      assert_no_enqueued_emails do
        post passwords_path, params: { email: "nobody2@example.com" }
      end
      assert_redirected_to login_path
    end

    test "a valid reset token sets a new password and lets the user log in" do
      user = User.create!(email: "hank@example.com", password: PASSWORD, confirmed_at: Time.current)
      token = user.generate_reset_token!
      new_pw = "a brand new passphrase"

      patch password_path(token: token), params: { password: new_pw, password_confirmation: new_pw }
      assert_redirected_to login_path

      # Old password no longer works; new one does.
      post login_path, params: { email: "hank@example.com", password: PASSWORD }
      assert_match(/invalid/i, flash[:alert])
      post login_path, params: { email: "hank@example.com", password: new_pw }
      assert_redirected_to files_path
    end

    test "an expired reset token is rejected" do
      user = User.create!(email: "ivy@example.com", password: PASSWORD, confirmed_at: Time.current)
      user.generate_reset_token!
      user.update_column(:reset_sent_at, 3.hours.ago)

      patch password_path(token: "whatever"), params: { password: "x", password_confirmation: "x" }
      assert_redirected_to new_password_path
    end

    test "a reset invalidates existing sessions" do
      user = User.create!(email: "jane@example.com", password: PASSWORD, confirmed_at: Time.current)
      post login_path, params: { email: "jane@example.com", password: PASSWORD }
      assert_equal 1, user.sessions.count

      token = user.generate_reset_token!
      patch password_path(token: token), params: { password: "new one here", password_confirmation: "new one here" }
      assert_equal 0, user.sessions.count, "existing sessions are revoked on reset"
    end
  end
end
