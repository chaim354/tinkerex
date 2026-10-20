require "test_helper"

module Web
  # THE HANDLE CLAIM (stage 3, S3-4): its form on the Account page and Settings::HandlesController.
  # The form assertions read the RENDERED field names (§14d) -- a `form_with url:` with no `scope:`
  # has a blank object_name and would emit `handle`, which `params.require(:user)` rejects with a
  # hard 400, and a params-hash POST cannot see that because it bypasses the form entirely.
  class SettingsHandleTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "handle-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
    end

    # --- the rendered form ---------------------------------------------------------------------

    test "the Account page renders the handle form with the name the controller requires" do
      get edit_user_registration_path
      assert_response :success

      assert_select "form[action=?][method=?]", settings_handle_path, "post"
      assert_select "input[name=?]", "user[handle]"
      assert_select "section.handle-panel input[name=?]", "user[handle]"
    end

    test "the submit button says Claim with no handle and Change with one" do
      get edit_user_registration_path
      assert_select "section.handle-panel input[type=submit][value=?]", "Claim handle"

      @user.update!(handle: "chaim")
      get edit_user_registration_path
      assert_select "section.handle-panel input[type=submit][value=?]", "Change handle"
    end

    test "a locked handle renders the field disabled with no submit button" do
      @user.update!(handle: "chaim")
      @user.maker_projects.create!(name: "Desk Lamp", visibility: "public")

      get edit_user_registration_path
      assert_select "section.handle-panel input[name=?][disabled]", "user[handle]"
      assert_select "section.handle-panel input[type=submit]", 0
      assert_select "section.handle-panel", /Locked while a project/
    end

    # --- the claim -----------------------------------------------------------------------------

    test "claiming a handle normalizes it and says so" do
      patch settings_handle_path, params: { user: { handle: "Chaim" } }

      assert_redirected_to edit_user_registration_path
      assert_equal "chaim", @user.reload.handle
      assert_equal "Your handle is @chaim.", flash[:notice]
    end

    test "an invalid handle is refused with the reason in the alert" do
      patch settings_handle_path, params: { user: { handle: "a" } }

      assert_redirected_to edit_user_registration_path
      assert_nil @user.reload.handle
      assert_includes flash[:alert], "2–32 characters"
    end

    test "a reserved handle is refused" do
      patch settings_handle_path, params: { user: { handle: "explore" } }

      assert_nil @user.reload.handle
      assert_includes flash[:alert], "reserved"
    end

    test "another account's handle is refused" do
      User.create!(email: "taken-#{SecureRandom.hex(4)}@example.com", handle: "chaim")

      patch settings_handle_path, params: { user: { handle: "chaim" } }

      assert_nil @user.reload.handle
      assert_includes flash[:alert], "has already been taken"
    end

    test "an empty field clears an unlocked handle" do
      @user.update!(handle: "chaim")

      patch settings_handle_path, params: { user: { handle: "" } }

      assert_nil @user.reload.handle
    end

    test "the lock refuses a change while a project is published" do
      @user.update!(handle: "chaim")
      @user.maker_projects.create!(name: "Desk Lamp", visibility: "public")

      patch settings_handle_path, params: { user: { handle: "other" } }

      assert_equal "chaim", @user.reload.handle
      assert_includes flash[:alert], "can't change"
    end

    test "the claim needs a session" do
      delete destroy_user_session_path
      patch settings_handle_path, params: { user: { handle: "chaim" } }
      assert_redirected_to new_user_session_path
    end
  end
end
