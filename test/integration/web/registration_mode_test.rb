require "test_helper"

module Web
  # Registration closed (the production default): the FIRST account is the owner — created
  # confirmed, signed in, no mail — and the page closes behind it. Drives the real requests and
  # follows the redirects, because that is where the earlier sign-up defect lived (§14e).
  class RegistrationModeTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      ENV["REGISTRATION"] = "closed"
      User.delete_all
    end

    teardown { ENV.delete("REGISTRATION") }

    def sign_up(email)
      post user_registration_path, params: { user: { email:, password: PASSWORD, password_confirmation: PASSWORD } }
    end

    test "on an empty server the sign-up page says the first account becomes the owner" do
      get new_user_registration_path
      assert_response :success
      assert_select "form[action=?]", user_registration_path
      assert_match(/first account/i, response.body)
      assert_match(/owner/i, response.body)
    end

    test "the first account is confirmed without mail, signed in, and closes sign-up behind it" do
      assert_emails 0 do
        sign_up("owner@example.com")
      end
      owner = User.find_by!(email: "owner@example.com")
      assert owner.confirmed?, "the owner needs no confirmation mail"
      follow_redirect!
      assert_response :success, "signed in and landed on a real page, not bounced to the sign-in page"

      delete destroy_user_session_path
      get new_user_registration_path
      assert_response :forbidden
      assert_match(/closed/i, response.body)
      get new_user_session_path
      assert_select "a[href=?]", new_user_registration_path, count: 0, text: "Sign up"
    end

    test "a second sign-up on a closed server creates nothing" do
      User.create!(email: "owner@example.com", password: PASSWORD, confirmed_at: Time.current)
      assert_no_difference -> { User.count } do
        sign_up("stranger@example.com")
        assert_response :forbidden
      end
    end

    test "with registration open the usual confirmable flow is untouched" do
      ENV["REGISTRATION"] = "open"
      User.create!(email: "owner@example.com", password: PASSWORD, confirmed_at: Time.current)
      assert_emails 1 do
        sign_up("second@example.com")
      end
      assert_not User.find_by!(email: "second@example.com").confirmed?
    end
  end
end
