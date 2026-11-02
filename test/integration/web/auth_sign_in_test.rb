require "test_helper"

module Web
  # "SIGN IN", ONE SPELLING, AND EVERY DEVISE PAGE A PAGE (UX audit F3, F4, I "Headings"/"Targets").
  #
  # The card said "Log in" (heading, button, link) while the notice after it said "Signed in
  # successfully." and the rail said "Sign out"; the Remember-me checkbox's accessible name was "1";
  # the seven Devise pages had no <title> of their own and no h1; and their errors were Devise's
  # "N errors prohibited this user from being saved" list where every other form uses `.form-errors`.
  class AuthSignInTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @prior_demo = ENV["DEMO_ACCOUNT_EMAIL"]
      ENV.delete("DEMO_ACCOUNT_EMAIL")
      @user = User.create!(email: "maker@example.com", password: PASSWORD, confirmed_at: Time.current)
    end

    teardown { @prior_demo.nil? ? ENV.delete("DEMO_ACCOUNT_EMAIL") : ENV["DEMO_ACCOUNT_EMAIL"] = @prior_demo }

    # Every signed-out Devise page, with the title and the one h1 it must carry.
    def signed_out_pages
      {
        new_user_session_path => [ "Sign in — Tinkerex", "Sign in" ],
        new_user_registration_path => [ "Sign up — Tinkerex", "Sign up" ],
        new_user_password_path => [ "Forgot your password — Tinkerex", "Forgot your password?" ],
        edit_user_password_path(reset_password_token: @user.send_reset_password_instructions) =>
          [ "Choose a new password — Tinkerex", "Choose a new password" ],
        new_user_confirmation_path => [ "Resend the confirmation link — Tinkerex", "Resend the confirmation link" ]
      }
    end

    test "every signed-out Devise page has its own title and exactly one h1" do
      signed_out_pages.each do |path, (title, heading)|
        get path
        assert_response :success, path
        assert_select "title", { text: title }, path
        assert_select "h1", { count: 1, text: heading }, path
      end
    end

    test "the closed sign-up page has its own title and one h1 too" do
      ENV["REGISTRATION"] = "closed"
      get new_user_registration_path
      assert_response :forbidden
      assert_select "title", "Sign-ups are closed — Tinkerex"
      assert_select "h1", count: 1, text: "Sign-ups are closed"
    ensure
      ENV.delete("REGISTRATION")
    end

    test "the auth cards say Sign in, never Log in" do
      get new_user_session_path
      assert_select ".auth-card h1", "Sign in"
      assert_select ".auth-card input[type=submit][value=?].primary", "Sign in"

      signed_out_pages.each_key do |path|
        get path
        assert_no_match(/log ?in/i, response.body, "#{path} still says log in")
      end
      get new_user_password_path
      assert_select "ul.auth-links a[href=?]", new_user_session_path, text: "Sign in"
    end

    test "the Remember me checkbox is named by its label" do
      get new_user_session_path
      assert_select "input[type=checkbox][name=?][id=?]", "user[remember_me]", "user_remember_me"
      assert_select "label[for=?]", "user_remember_me", text: /Remember me/
    end

    test "signing in and out say so in the app's notice voice" do
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      assert_equal "Signed in.", flash[:notice]

      delete destroy_user_session_path
      assert_equal "Signed out.", flash[:notice]
    end

    test "a gated page sends a visitor to sign in with a sentence that does not offer a closed sign-up" do
      get settings_path
      assert_redirected_to new_user_session_path
      assert_equal "Sign in to continue.", flash[:alert]
    end

    # ONE ERROR STYLE (F3): the `.form-errors` box, as one sentence -- never Devise's list.
    test "a refused sign-up shows its errors in .form-errors, not Devise's list" do
      post user_registration_path, params: { user: { email: "new@example.com", password: PASSWORD,
                                                     password_confirmation: "something else" } }
      assert_response :unprocessable_entity
      assert_select ".auth-card .form-errors[role=alert]", /Password confirmation doesn't match Password\./
      assert_select "#error_explanation", 0
      assert_no_match(/prohibited this user from being saved/, response.body)
    end
  end
end
