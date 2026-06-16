require "test_helper"

# Human-identity web auth via Devise: sign-up -> confirmation email -> login (unconfirmed
# blocked) -> logout -> password reset. Uses Devise's standard paths
# (new_user_registration_path, user_session_path, etc.). The device-token + device-login
# enrollment is exercised separately (test/integration/v1/device_login_test.rb).
module Web
  class DeviseAuthFlowTest < ActionDispatch::IntegrationTest
    include ActiveJob::TestHelper

    PASSWORD = "correct horse battery staple".freeze

    setup { ActionMailer::Base.deliveries.clear }

    # --- sign up ----------------------------------------------------------------------
    test "sign up creates an unconfirmed account and sends a confirmation email" do
      # Devise delivers confirmation mail synchronously (deliver_now) in this app, so we
      # assert on actual deliveries rather than the job queue.
      assert_emails 1 do
        assert_difference -> { User.count }, 1 do
          post user_registration_path, params: { user: {
            email: "alice@example.com", password: PASSWORD, password_confirmation: PASSWORD
          } }
        end
      end
      user = User.find_by(email: "alice@example.com")
      assert_not user.confirmed?, "new account starts unconfirmed"
      assert user.encrypted_password.present?, "password is hashed"
    end

    test "sign up with a BLANK password is rejected and creates no user" do
      # password_required? is false when no password is set (so the OmniAuth seam + the
      # device-token bootstrap can create passwordless accounts) — but a HUMAN web sign-up
      # with a blank password must NOT persist an inert, can't-authenticate row. The web
      # registration boundary rejects it.
      assert_no_difference -> { User.count } do
        post user_registration_path, params: { user: {
          email: "blank@example.com", password: "", password_confirmation: ""
        } }
      end
      assert_response :unprocessable_entity
      assert_nil User.find_by(email: "blank@example.com")
    end

    test "sign up WITH a valid password still works after the blank-password guard" do
      assert_difference -> { User.count }, 1 do
        post user_registration_path, params: { user: {
          email: "valid@example.com", password: PASSWORD, password_confirmation: PASSWORD
        } }
      end
      assert User.find_by(email: "valid@example.com").encrypted_password.present?
    end

    test "the blank-password guard does NOT break programmatic passwordless creates" do
      # OmniAuth seam + v1 bootstrap rely on passwordless User.create! — these must stay valid.
      assert_difference -> { User.count }, 1 do
        User.create!(email: "omniauth@example.com", omniauth_signup: true, confirmed_at: Time.current)
      end
    end

    test "sign up rejects a mismatched password confirmation" do
      assert_no_difference -> { User.count } do
        post user_registration_path, params: { user: {
          email: "bob@example.com", password: PASSWORD, password_confirmation: "different"
        } }
      end
      assert_response :unprocessable_entity
    end

    test "sign up rejects a duplicate email" do
      User.create!(email: "dup@example.com", password: PASSWORD, confirmed_at: Time.current)
      assert_no_difference -> { User.count } do
        post user_registration_path, params: { user: {
          email: "dup@example.com", password: PASSWORD, password_confirmation: PASSWORD
        } }
      end
      assert_response :unprocessable_entity
    end

    # --- email confirmation -----------------------------------------------------------
    test "an UNCONFIRMED user cannot sign in" do
      User.create!(email: "unconf@example.com", password: PASSWORD)
      post user_session_path, params: { user: { email: "unconf@example.com", password: PASSWORD } }
      # Devise's :confirmable failure is a Warden redirect back to sign-in (observed 302),
      # not a 422 render (which is what a bad-credentials sign-in returns). Either way the
      # user is NOT signed in.
      assert_redirected_to new_user_session_path
      # Not signed in -> the file UI redirects to login.
      get files_path
      assert_redirected_to new_user_session_path
    end

    test "confirming the email lets the user sign in" do
      raw = nil
      perform_enqueued_jobs do
        post user_registration_path, params: { user: {
          email: "carol@example.com", password: PASSWORD, password_confirmation: PASSWORD
        } }
      end
      mail = ActionMailer::Base.deliveries.last
      raw = mail.body.encoded[/confirmation_token=([^"'&\s]+)/, 1]
      assert raw.present?, "confirmation link carries a raw token"

      get user_confirmation_path(confirmation_token: raw)
      assert User.find_by(email: "carol@example.com").confirmed?

      post user_session_path, params: { user: { email: "carol@example.com", password: PASSWORD } }
      assert_redirected_to files_path
    end

    # --- login / logout ---------------------------------------------------------------
    test "login with the wrong password is rejected" do
      User.create!(email: "dave@example.com", password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: "dave@example.com", password: "wrong" } }
      assert_response :unprocessable_entity
    end

    test "a confirmed user logs in, accesses the file UI, then logs out" do
      User.create!(email: "erin@example.com", password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: "erin@example.com", password: PASSWORD } }
      assert_redirected_to files_path

      get files_path
      assert_response :success

      delete destroy_user_session_path
      get files_path
      assert_redirected_to new_user_session_path
    end

    # --- password reset ---------------------------------------------------------------
    test "requesting a reset emails a link for a known account" do
      User.create!(email: "gina@example.com", password: PASSWORD, confirmed_at: Time.current)
      assert_emails 1 do
        post user_password_path, params: { user: { email: "gina@example.com" } }
      end
    end

    test "a valid reset token sets a new password and lets the user log in" do
      User.create!(email: "hank@example.com", password: PASSWORD, confirmed_at: Time.current)
      raw = nil
      perform_enqueued_jobs do
        post user_password_path, params: { user: { email: "hank@example.com" } }
      end
      mail = ActionMailer::Base.deliveries.last
      raw = mail.body.encoded[/reset_password_token=([^"'&\s]+)/, 1]
      assert raw.present?

      new_pw = "a brand new passphrase"
      put user_password_path, params: { user: {
        reset_password_token: raw, password: new_pw, password_confirmation: new_pw
      } }
      # Devise signs the user in on a successful reset; sign out so we can test credentials.
      delete destroy_user_session_path

      # Old password no longer works; new one does.
      post user_session_path, params: { user: { email: "hank@example.com", password: PASSWORD } }
      assert_response :unprocessable_entity
      post user_session_path, params: { user: { email: "hank@example.com", password: new_pw } }
      assert_redirected_to files_path
    end
  end
end
