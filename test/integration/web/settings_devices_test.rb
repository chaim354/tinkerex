require "test_helper"

module Web
  # SETTINGS → DEVICES, AND AN ADMIN'S SIGN OUT ON SETTINGS → USERS (pentest H1b, tinkerex#465). Every
  # revocation is proved against the API itself: the token that was signed out must be refused by
  # /v1, not merely missing from a list.
  #
  # Runs on all three backend legs and branches on the CAPABILITY where the page does (§15): only a
  # syncable deployment says that file sync is not cut off.
  class SettingsDevicesTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @prior_idle = ENV["DEVICE_IDLE_DAYS"]
      ENV.delete("DEVICE_IDLE_DAYS")
      @user = User.create!(email: "devices-#{SecureRandom.hex(4)}@example.com", password: PASSWORD,
                           confirmed_at: Time.current)
      @laptop = Device.register!(user: @user, name: "Workshop laptop")
      @laptop.update_column(:last_seen_at, 2.hours.ago)
      @desk = Device.register!(user: @user, name: "Desk PC")
      @stranger = User.create!(email: "stranger-#{SecureRandom.hex(4)}@example.com", password: PASSWORD,
                               confirmed_at: Time.current)
      @theirs = Device.register!(user: @stranger, name: "Stranger's laptop")
    end

    teardown { @prior_idle.nil? ? ENV.delete("DEVICE_IDLE_DAYS") : ENV["DEVICE_IDLE_DAYS"] = @prior_idle }

    def api_status(device)
      get "/v1/maker/projects", headers: { "Authorization" => "Bearer #{device.plaintext_token}" }
      response.status
    end

    # ============================================================ your own devices

    test "the hub links to Devices with a count" do
      sign_in_web!(@user, password: PASSWORD)
      get settings_path
      assert_select "ul.settings-hub li", text: /Devices\s*2 desktop apps/ do
        assert_select "a.settings-name[href=?]", settings_devices_path
      end
    end

    # The expected order DISAGREES with creation order (laptop, desk, tablet), so a page that listed
    # rows as stored could not pass. A never-used device sorts by when it signed in.
    test "the page lists this account's devices, most recently used first, and nobody else's" do
      @desk.update_column(:last_seen_at, 1.hour.ago)
      travel_to(3.days.ago) { Device.register!(user: @user, name: "Old tablet") }
      sign_in_web!(@user, password: PASSWORD)
      get settings_devices_path
      assert_response :success
      names = css_select("ul.settings-list li .settings-name").map(&:text)
      assert_equal [ "Desk PC", "Workshop laptop", "Old tablet" ], names
      assert_select "li", text: /Workshop laptop.*used about 2 hours ago/m
      assert_select "li", text: /Old tablet.*never used/m
      assert_no_match(/Stranger/, response.body)
      assert_select ".badge", count: 0, text: "Expired"
    end

    # Mutation-checked: with the destroy found through Device.find instead of current_user.devices,
    # the stranger's device is signed out and the 404 below fails.
    test "Sign out ends that device's token, and an id from another account 404s" do
      sign_in_web!(@user, password: PASSWORD)
      assert_equal 200, api_status(@laptop), "precondition"

      get settings_devices_path
      assert_select "form[action=?][method=post] input[name=_method][value=delete]", settings_device_path(@laptop)
      delete settings_device_path(@laptop)
      assert_redirected_to settings_devices_path
      assert_equal "Signed out Workshop laptop. It needs your password to sign in again.", flash[:notice]
      assert_equal 401, api_status(@laptop)
      assert_equal 200, api_status(@desk), "the other device is untouched"

      delete settings_device_path(@theirs)
      assert_response :not_found
      assert_equal 200, api_status(@theirs)
    end

    test "an expired device says so and offers Remove" do
      @laptop.update_column(:last_seen_at, (Device::IDLE_DAYS_DEFAULT + 1).days.ago)
      sign_in_web!(@user, password: PASSWORD)
      get settings_devices_path
      assert_select "li", text: /Workshop laptop/ do
        assert_select ".badge", text: "Expired"
        assert_select "button", text: "Remove"
      end
      assert_select "li", text: /Desk PC/ do
        assert_select "button", text: "Sign out"
      end
      assert_select "p.muted", text: /unused for 90 days is signed out on its own/
    end

    test "with expiry off the page does not promise it" do
      ENV["DEVICE_IDLE_DAYS"] = "0"
      sign_in_web!(@user, password: PASSWORD)
      get settings_devices_path
      assert_select "p.muted", text: /signed out on its own/, count: 0
    end

    # THE KNOWN GAP, SAID WHERE IT MATTERS. Revoking here cannot reach the sync server, so a page that
    # let a chunk_remote user believe a lost laptop had stopped syncing would be lying.
    test "a syncable deployment says that file sync is not cut off, and the others say nothing" do
      sign_in_web!(@user, password: PASSWORD)
      get settings_devices_path
      if FileLayer.current.capabilities.syncable?
        assert_select "p.muted", text: /does not end that key yet, so its files keep syncing/
      else
        assert_no_match(/sync server/, response.body)
      end
    end

    test "an account with no device says so" do
      @user.devices.delete_all
      sign_in_web!(@user, password: PASSWORD)
      get settings_devices_path
      assert_select "li.empty", text: "No desktop app is signed in to this account."
    end

    test "a visitor who is not signed in is sent to sign in" do
      get settings_devices_path
      assert_redirected_to new_user_session_path
      delete settings_device_path(@laptop)
      assert_redirected_to new_user_session_path
      assert Device.exists?(@laptop.id)
    end

    # ============================================================ an admin, for another account

    test "an admin sees another account's devices and signs one out" do
      admin = User.create!(email: "admin-#{SecureRandom.hex(4)}@example.com", password: PASSWORD,
                           confirmed_at: Time.current, admin: true)
      sign_in_web!(admin, password: PASSWORD)

      get edit_settings_user_path(@user)
      assert_select "section.user-manage h2", text: "Devices"
      assert_select "form[action=?]", revoke_device_settings_user_path(@user, device_id: @laptop.id)

      delete revoke_device_settings_user_path(@user, device_id: @laptop.id)
      assert_redirected_to edit_settings_user_path(@user)
      assert_equal "Signed Workshop laptop out of #{@user.email}.", flash[:notice]
      assert_equal 401, api_status(@laptop)
      assert_equal 200, api_status(@desk)
    end

    # Mutation-checked: with revoke_device finding through Device.find, the stranger's device goes.
    test "an admin's sign-out is scoped to the account in the URL" do
      admin = User.create!(email: "admin-#{SecureRandom.hex(4)}@example.com", password: PASSWORD,
                           confirmed_at: Time.current, admin: true)
      sign_in_web!(admin, password: PASSWORD)
      delete revoke_device_settings_user_path(@user, device_id: @theirs.id)
      assert_response :not_found
      assert_equal 200, api_status(@theirs)
    end

    test "the account page with no devices says so" do
      admin = User.create!(email: "admin-#{SecureRandom.hex(4)}@example.com", password: PASSWORD,
                           confirmed_at: Time.current, admin: true)
      @user.devices.delete_all
      sign_in_web!(admin, password: PASSWORD)
      get edit_settings_user_path(@user)
      assert_select "section.user-manage p.muted", text: "No desktop app is signed in to #{@user.email}."
    end
  end
end
