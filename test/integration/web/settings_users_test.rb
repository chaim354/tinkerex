require "test_helper"

module Web
  # SETTINGS → USERS (2026-10-21; docs/superpowers/specs/2026-10-21-admin-users-design.md): an admin
  # adds accounts, and on each other account's page resets its password, makes or unmakes it an
  # admin, or deletes it.
  #
  # EVERY TEST RUNS ON ALL THREE BACKEND LEGS AND BRANCHES, NEVER SKIPS (§15). Two things differ by
  # backend and both are asked of the CAPABILITY, never of the LIBRARY_BACKEND name: whether a new
  # account's scan is queued (`scannable?`) and what the page says a new account sees (`syncable?`).
  #
  # The forms' rendered field names are asserted before the requests that post them are trusted
  # (§14d: a test that posts a Ruby hash proves nothing about a field the page names differently).
  class SettingsUsersTest < ActionDispatch::IntegrationTest
    include ActiveJob::TestHelper

    PASSWORD = "correct horse battery staple".freeze
    NEW_PASSWORD = "a brand new horse battery".freeze

    setup do
      @prior_demo = ENV["DEMO_ACCOUNT_EMAIL"]
      ENV.delete("DEMO_ACCOUNT_EMAIL")
      @admin = User.create!(email: "admin@example.com", password: PASSWORD, confirmed_at: Time.current, admin: true)
      @member = User.create!(email: "member@example.com", password: PASSWORD, confirmed_at: Time.current)
    end

    teardown { @prior_demo ? ENV["DEMO_ACCOUNT_EMAIL"] = @prior_demo : ENV.delete("DEMO_ACCOUNT_EMAIL") }

    def sign_in_as(user) = sign_in_web!(user, password: PASSWORD)

    def caps = FileLayer.current.capabilities

    # Every action, as the real forms send it, aimed at `target`.
    def every_request(target)
      [
        -> { get settings_users_path },
        -> { post settings_users_path, params: { user: { email: "x@example.com", password: NEW_PASSWORD } } },
        -> { get edit_settings_user_path(target) },
        -> { patch reset_password_settings_user_path(target), params: { user: { password: NEW_PASSWORD } } },
        -> { patch set_admin_settings_user_path(target), params: { admin: "1" } },
        -> { delete settings_user_path(target), params: { confirm_email: target.email } }
      ]
    end

    # ============================================================ who reaches it

    test "a plain account is sent back to Settings from every action, and nothing changes" do
      sign_in_as(@member)

      every_request(@admin).each do |request|
        assert_no_difference -> { User.count } do
          request.call
        end
        assert_redirected_to settings_path
        assert_equal "Only an admin can manage accounts.", flash[:alert]
      end
      assert @admin.reload.valid_password?(PASSWORD)
      assert_not @member.reload.admin?
    end

    # Its row says admin, and that is exactly the state this proves cannot reach the page.
    test "the demo account is sent back to Settings even with the admin flag set" do
      ENV["DEMO_ACCOUNT_EMAIL"] = "demo@example.com"
      demo = User.create!(email: "demo@example.com", password: PASSWORD, confirmed_at: Time.current, admin: true)
      sign_in_as(demo)

      every_request(@member).each do |request|
        request.call
        assert_redirected_to settings_path
      end
      assert User.exists?(@member.id)
      assert @member.reload.valid_password?(PASSWORD)
      assert_not @member.admin?
    end

    test "the Settings hub shows the Users row to an admin only" do
      sign_in_as(@admin)
      get settings_path
      assert_select "ul.settings-hub a.settings-name[href=?]", settings_users_path, text: "Users"
      assert_select ".settings-fact", text: "2 accounts"

      delete destroy_user_session_path
      sign_in_as(@member)
      get settings_path
      assert_select "a[href=?]", settings_users_path, count: 0
    end

    # ============================================================ the list and the add form

    test "the list links each other account to its page and the signed-in one to the Account page" do
      sign_in_as(@admin)
      get settings_users_path

      assert_response :success
      assert_select "ul.settings-list li", count: 2
      assert_select "a.settings-name[href=?]", edit_user_registration_path, text: @admin.email
      assert_select "a.settings-name[href=?]", edit_settings_user_path(@member), text: @member.email
      assert_select "a[href=?]", edit_settings_user_path(@admin), count: 0
      assert_select ".settings-fact", text: "you"
      assert_select ".settings-fact", text: "admin", count: 1
      assert_select ".settings-fact", text: "never signed in", count: 1
    end

    test "the page says what a new account will see" do
      sign_in_as(@admin)
      get settings_users_path

      if caps.syncable?
        assert_match(/a library of its own/, response.body)
      else
        assert_match(/sees the same library folder/, response.body)
      end
    end

    test "the add form names the fields the controller reads" do
      sign_in_as(@admin)
      get settings_users_path

      assert_select "form[action=?][method=post]", settings_users_path do
        assert_select "input[type=email][name=?]", "user[email]"
        # Visible text: the admin reads it out or pastes it to the person.
        assert_select "input[type=text][name=?]", "user[password]"
        assert_select "input[type=checkbox][name=?][value=?]", "user[admin]", "1"
      end
    end

    test "adding an account makes a confirmed account that signs in, sends no mail, and queues its scan where the library is scanned" do
      sign_in_as(@admin)

      assert_emails 0 do
        post settings_users_path, params: { user: { email: " New@Example.com ", password: NEW_PASSWORD, admin: "0" } }
      end

      assert_redirected_to settings_users_path
      created = User.find_by!(email: "new@example.com")
      assert created.confirmed?
      assert_not created.admin?
      scans = enqueued_jobs.select { |j| j[:job] == Library::ScanJob }.map { |j| j[:args].first["user_id"] }
      assert_equal(caps.scannable? ? [ created.id ] : [], scans)

      delete destroy_user_session_path
      sign_in_web!(created, password: NEW_PASSWORD)
    end

    test "the admin box makes the new account an admin" do
      sign_in_as(@admin)
      post settings_users_path, params: { user: { email: "second-admin@example.com", password: NEW_PASSWORD, admin: "1" } }

      assert User.find_by!(email: "second-admin@example.com").can_manage_accounts?
    end

    test "a taken address, a short password and a blank one re-render the form with the reason" do
      sign_in_as(@admin)
      cases = {
        { email: @member.email, password: NEW_PASSWORD } => /already been taken/,
        { email: "short@example.com", password: "short" } => /too short/,
        { email: "blank@example.com", password: "" } => /can't be blank/
      }

      cases.each do |fields, reason|
        assert_no_difference -> { User.count } do
          post settings_users_path, params: { user: fields }
        end
        assert_response :unprocessable_entity
        assert_select ".form-errors", text: reason
        assert_select "input[name=?][value=?]", "user[email]", fields[:email]
      end
    end

    # ============================================================ one account's page

    test "the account page names the fields its three forms send" do
      sign_in_as(@admin)
      get edit_settings_user_path(@member)

      assert_response :success
      assert_select "form[action=?]", reset_password_settings_user_path(@member) do
        assert_select "input[name=?][value=?]", "_method", "patch"
        assert_select "input[type=text][name=?]", "user[password]"
      end
      assert_select "form[action=?]", set_admin_settings_user_path(@member) do
        assert_select "input[name=?][value=?]", "admin", "1"
      end
      assert_select "form[action=?]", settings_user_path(@member) do
        assert_select "input[name=?][value=?]", "_method", "delete"
        assert_select "input[type=text][name=?]", "confirm_email"
      end
    end

    test "every action on the signed-in account goes to the Account page and changes nothing" do
      sign_in_as(@admin)

      every_request(@admin).drop(2).each do |request|
        request.call
        assert_redirected_to edit_user_registration_path
      end
      @admin.reload
      assert @admin.valid_password?(PASSWORD)
      assert @admin.admin?
    end

    test "a reset sets the new password, ends the old one, confirms and unlocks" do
      @member.update_columns(confirmed_at: nil, locked_at: Time.current, failed_attempts: 10)
      sign_in_as(@admin)

      patch reset_password_settings_user_path(@member), params: { user: { password: NEW_PASSWORD } }

      assert_redirected_to edit_settings_user_path(@member)
      @member.reload
      assert @member.valid_password?(NEW_PASSWORD)
      assert_not @member.valid_password?(PASSWORD)
      assert @member.confirmed?
      assert_not @member.access_locked?
      assert_equal 0, @member.failed_attempts

      delete destroy_user_session_path
      sign_in_web!(@member, password: NEW_PASSWORD)
    end

    # A passwordless (single sign-on) account answers password_required? false, so without the
    # controller's own check a blank reset would save as a silent no-op and report success.
    test "a reset refuses a blank or short password, for a passwordless account too" do
      sso = User.create!(email: "sso@example.com", confirmed_at: Time.current, omniauth_signup: true)
      sign_in_as(@admin)

      [ [ @member, "" ], [ @member, "short" ], [ sso, "" ] ].each do |user, password|
        patch reset_password_settings_user_path(user), params: { user: { password: } }
        assert_response :unprocessable_entity, "#{user.email} with #{password.inspect}"
        assert_select ".form-errors"
      end
      assert @member.reload.valid_password?(PASSWORD)
      assert sso.reload.encrypted_password.blank?
    end

    test "make and remove admin; the demo account cannot be made one" do
      sign_in_as(@admin)

      patch set_admin_settings_user_path(@member), params: { admin: "1" }
      assert_redirected_to edit_settings_user_path(@member)
      assert @member.reload.admin?

      patch set_admin_settings_user_path(@member), params: { admin: "0" }
      assert_not @member.reload.admin?

      ENV["DEMO_ACCOUNT_EMAIL"] = @member.email
      patch set_admin_settings_user_path(@member), params: { admin: "1" }
      assert_not @member.reload.admin?
      assert_match(/demo/, flash[:alert].to_s)
    end

    test "deleting needs the account's address typed, then removes it and what it owns" do
      project = @member.maker_projects.create!(name: "Theirs", status: "active")
      sign_in_as(@admin)

      assert_no_difference -> { User.count } do
        delete settings_user_path(@member), params: { confirm_email: "wrong@example.com" }
      end
      assert_response :unprocessable_entity
      assert_select ".form-errors", text: /Type member@example.com/

      delete settings_user_path(@member), params: { confirm_email: " MEMBER@example.com " }

      assert_redirected_to settings_users_path
      assert_not User.exists?(@member.id)
      assert_not Maker::Project.exists?(project.id)
      assert User.exists?(@admin.id)
    end
  end
end
