require "test_helper"

module Web
  # THE ACCOUNT PAGE IS A SETTINGS PAGE (UX audit F1, F2, F3).
  #
  # /users/edit rendered Devise's card inside the shell: no title (the tab read "Tinkerex"), no h1, an
  # "Update" button, a "Back" link to Recent, a save that landed on Recent, and -- the F2 defect -- a
  # refused DELETE whose error appeared at the top under the email-and-password form while the Delete
  # section the maker had just used said nothing. account_settings_test.rb owns what the four actions
  # DO; this file owns what the page says and where.
  class AccountPageTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze
    NEW_PASSWORD = "a different correct horse".freeze

    setup do
      @user = User.create!(email: "owner@example.com", password: PASSWORD, confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
    end

    test "the page is titled, crumbed and headed like its Settings siblings" do
      get edit_user_registration_path

      assert_response :success
      assert_select "title", "Account — Tinkerex"
      assert_select ".topbar nav.breadcrumb" do
        assert_select "a[href=?]", settings_path, text: "Settings"
        assert_select "[aria-current=page]", "Account"
      end
      assert_select "main h1", count: 1, text: "Account"
      assert_select ".auth-card", 0, "the page is no longer Devise's card"
      assert_select ".account-page > .panel h2", count: 3
      assert_select ".account-page .panel h2", text: "Email and password"
      assert_select ".account-page .panel h2", text: "Handle"
      assert_select ".account-page .panel h2", text: "Delete this account"
      assert_select "input[type=submit][value=?].primary", "Save changes"
      assert_select "main a[href=?]", root_path, { count: 0 }, "no foot Back link to Recent"
      assert_select ".field-hint", /Leave blank to keep your current password\./
    end

    test "saving lands back on the Account page with a notice" do
      patch user_registration_path, params: { user: { email: "renamed@example.com", current_password: PASSWORD } }

      assert_redirected_to edit_user_registration_path
      follow_redirect!
      assert_response :success
      assert_select ".flash-stack .flash-notice", /Saved your account/
    end

    test "a refused save re-renders with the error in its own panel and the typed email, no password" do
      patch user_registration_path, params: { user: { email: "typed@example.com", password: NEW_PASSWORD,
                                                      password_confirmation: NEW_PASSWORD, current_password: "wrong" } }

      assert_response :unprocessable_entity
      assert_select ".account-login .form-errors", /Current password is invalid/
      assert_select ".account-delete .form-errors", 0
      assert_select ".account-login input[name=?][value=?]", "user[email]", "typed@example.com"
      css_select("input[type=password]").each do |field|
        assert_nil field["value"], "#{field['name']} came back filled in"
      end
    end

    # F2. MUTATION-CHECKED: restoring #destroy's `resource.errors.add(:current_password, ...)` (and
    # dropping @delete_error) puts the error back under the update form and reddens this; the run's
    # output is in the UX-audit T6 report.
    test "a refused delete shows its error in the Delete section and nowhere else" do
      assert_no_difference "User.count" do
        delete user_registration_path, params: { user: { current_password: "wrong" } }
      end

      assert_response :unprocessable_entity
      assert_select "div.account-delete .form-errors[role=alert]",
                    "That is not your current password, so nothing was deleted."
      assert_select ".account-login .form-errors", 0, "the update form did not cause this error"
      assert_select ".form-errors", 1
    end

    test "a blank password and the last-admin refusal land in the Delete section too" do
      delete user_registration_path, params: { user: { current_password: "" } }
      assert_select "div.account-delete .form-errors", "Type your password to delete this account."

      @user.update!(admin: true)
      User.create!(email: "other@example.com", password: PASSWORD, confirmed_at: Time.current)
      delete user_registration_path, params: { user: { current_password: PASSWORD } }
      assert_response :unprocessable_entity
      assert_select "div.account-delete .form-errors", /only admin/
      assert_select ".account-login .form-errors", 0
    end
  end
end
