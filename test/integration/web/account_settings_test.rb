require "test_helper"

module Web
  # The account-settings surface: edit, update, cancel, and destroy. None of these four actions
  # was driven by any test before this file — established by instrumenting the whole suite with a
  # process_action.action_controller subscriber, not by reading.
  #
  # DESTROY IS THE ONE THAT MATTERS. It is irreversible, and measured before the fix, one request
  # carrying only a session cookie took users=1 projects=1 nodes=1 tasks=1 to zero: no password,
  # no server-side confirmation, no undo. The CASCADE is correct (24 `dependent:` associations on
  # User) — which is exactly what made the missing confirmation easy to miss.
  class AccountSettingsTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze
    NEW_PASSWORD = "a different correct horse".freeze

    setup do
      @user = User.create!(email: "owner@example.com", password: PASSWORD,
                           confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
    end

    # --- edit ------------------------------------------------------------------

    test "the settings page renders for a signed-in user" do
      get edit_user_registration_path
      assert_response :success
    end

    test "the settings page requires a session" do
      delete destroy_user_session_path
      get edit_user_registration_path
      assert_redirected_to new_user_session_path
    end

    test "cancel is reachable for a signed-in user" do
      get cancel_user_registration_path
      assert_response :redirect
    end

    # --- update ----------------------------------------------------------------

    test "changing the password requires the current one" do
      patch user_registration_path, params: { user: {
        password: NEW_PASSWORD, password_confirmation: NEW_PASSWORD, current_password: "wrong"
      } }
      assert_response :unprocessable_entity
      assert @user.reload.valid_password?(PASSWORD), "the password must not have changed"
    end

    test "changing the password with the current one works" do
      patch user_registration_path, params: { user: {
        password: NEW_PASSWORD, password_confirmation: NEW_PASSWORD, current_password: PASSWORD
      } }
      assert @user.reload.valid_password?(NEW_PASSWORD)
    end

    # --- destroy ---------------------------------------------------------------

    test "deleting the account REQUIRES the current password" do
      @user.maker_projects.create!(name: "Precious", status: "active")

      assert_no_difference [ "User.count", "Maker::Project.count" ] do
        delete user_registration_path
      end
      assert User.exists?(@user.id), "a request with no password must not delete the account"
    end

    test "a wrong password does not delete the account" do
      assert_no_difference "User.count" do
        delete user_registration_path, params: { user: { current_password: "wrong" } }
      end
      assert User.exists?(@user.id)
    end

    test "the correct password deletes the account and everything it owns" do
      # The over-correction guard: the fix must not make deletion impossible.
      project = @user.maker_projects.create!(name: "Precious", status: "active")
      @user.nodes.create!(node_id: "gone", name: "gone.stl", kind: "file", size: 1,
                          mtime: 1_700_000_000_000_000_000)
      project.tasks.create!(user: @user, title: "t")

      delete user_registration_path, params: { user: { current_password: PASSWORD } }

      assert_not User.exists?(@user.id)
      assert_equal 0, Maker::Project.where(user_id: @user.id).count
      assert_equal 0, Node.where(user_id: @user.id).count
      assert_equal 0, Maker::Task.where(user_id: @user.id).count
    end

    test "the rendered delete form carries the field the controller requires" do
      # EVERY OTHER TEST HERE POSTS PARAMS DIRECTLY, so none of them can catch a form/controller
      # field-name mismatch: rename the field in the view and the suite stays green while the
      # delete button silently stops working for every real user. Assert the wire, not the
      # round-trip.
      get edit_user_registration_path
      assert_response :success

      # SCOPED TO THE DELETE BLOCK, and that is the whole point. The first version of this test
      # scanned the WHOLE page for a name containing "current_password" — which the UPDATE form
      # also has, so it passed even with the delete field renamed. Caught by mutation-checking
      # it, not by reading it.
      assert_select "div.account-delete form" do
        # The equality hash goes BEFORE the message — assert_select reads a bare trailing String
        # as an expectation about the element's TEXT, so passing the message positionally makes
        # it assert that a hidden input contains that sentence.
        assert_select "input[name=?]", "user[current_password]", { count: 1 },
                      "the delete form must post user[current_password] — " \
                      "RegistrationsController#destroy reads params[:user][:current_password]"
        assert_select "input[name=?][value=?]", "_method", "delete", { count: 1 },
                      "this must be the DELETE form, not the update form"
      end
    end

    test "deleting an account leaves other users untouched" do
      other = User.create!(email: "bystander@example.com", password: PASSWORD,
                           confirmed_at: Time.current)
      other.maker_projects.create!(name: "Theirs", status: "active")

      delete user_registration_path, params: { user: { current_password: PASSWORD } }

      assert User.exists?(other.id)
      assert_equal 1, Maker::Project.where(user_id: other.id).count
    end
  end
end
