require "test_helper"
require "support/mcp_client"

module Web
  # CONNECT AN AI ASSISTANT (spec 2026-11-04-mcp-server-design §6): the form, the once-shown token,
  # that the token opens /mcp, that the demo is refused, and that Sign out revokes it.
  class SettingsDevicesConnectTest < ActionDispatch::IntegrationTest
    include McpClient

    setup do
      @user = User.create!(email: "connect@example.com", password: WEB_PASSWORD, confirmed_at: Time.current)
      sign_in_web!(@user)
    end

    # The v1 device-login tests' idiom: Tinkerex::Demo reads the variable per call.
    def with_demo(email)
      prior = ENV.fetch("DEMO_ACCOUNT_EMAIL", nil)
      ENV["DEMO_ACCOUNT_EMAIL"] = email
      yield
    ensure
      prior.nil? ? ENV.delete("DEMO_ACCOUNT_EMAIL") : ENV["DEMO_ACCOUNT_EMAIL"] = prior
    end

    test "the Devices page offers the connect form with the field name the controller reads" do
      get settings_devices_path
      assert_response :success
      assert_select "form[action=?][data-turbo=false]", settings_devices_path do
        assert_select "input[name=?][value=?]", "device[name]", Settings::DevicesController::DEFAULT_ASSISTANT_NAME
        # NO size: text_field copies maxlength into size, and size="80" pushed this page to
        # scrollWidth 609 at 375px (design-system.md rule 11; no 375px sweep visits this page).
        assert_select "input[name=?][maxlength='80']:not([size])", "device[name]"
        assert_select "input[type=submit][value=Connect]"
      end
      assert_select "p.muted", text: /desktop apps and assistants/
    end

    test "connecting mints a device with no sync grant, shows the token once, and the token opens /mcp" do
      assert_difference -> { @user.devices.count }, 1 do
        post settings_devices_path, params: { device: { name: "Claude Code" } }
      end
      assert_response :success
      device = @user.devices.order(:id).last
      assert_equal "Claude Code", device.name
      assert_nil device.sync_device_id

      token = css_select("code.connect-secret").first.text.strip
      assert_equal device.token_digest, Device.digest(token), "the page shows the plaintext whose digest was stored"
      assert_select "[data-controller=copy][data-copy-text-value=?]", token
      command = "claude mcp add --transport http tinkerex http://www.example.com/mcp --header \"Authorization: Bearer #{token}\""
      assert_select "[data-copy-text-value=?]", command
      assert_select "pre", text: /"url": "http:\/\/www.example.com\/mcp"/
      # The sign-in's own "Signed in." is still in the flash on this, the next request (sign_in_web!
      # does not follow its redirect), so the flash is not empty; what must never be in it is the token.
      assert flash.to_h.values.none? { |message| message.to_s.include?(token) }, "the token must never pass through the flash"

      assert_equal({}, mcp_rpc(token, "ping")["result"])
    end

    # settings/devices/connected is rendered only by this POST, never by a GET template_hygiene_test's
    # sweep can issue (the composer page's situation, ProjectHubAuditTest), so its body is swept here:
    # the two delimiters, a section mark, and two phrases only its code comment contains.
    test "the connected page leaks no template comment" do
      post settings_devices_path, params: { device: { name: "Claude Code" } }
      assert_response :success
      [ "<%", "%>", "§", "THE TOKEN, ONCE", "rather than let someone try" ].each do |leak|
        assert_not_includes response.body, leak, "the connected page rendered #{leak.inspect}"
      end
    end

    test "a blank name falls back to the default" do
      post settings_devices_path, params: { device: { name: "   " } }
      assert_equal Settings::DevicesController::DEFAULT_ASSISTANT_NAME, @user.devices.order(:id).last.name
    end

    test "the demo account is refused with no row" do
      with_demo(@user.email) do
        assert_no_difference -> { Device.count } do
          post settings_devices_path, params: { device: { name: "x" } }
        end
        assert_redirected_to settings_devices_path
        assert_match(/demo/, flash[:alert])
      end
    end

    test "the connected assistant lists on the Devices page and Sign out revokes its token" do
      post settings_devices_path, params: { device: { name: "Claude Code" } }
      token = css_select("code.connect-secret").first.text.strip
      device = @user.devices.order(:id).last

      get settings_devices_path
      assert_select ".settings-list li .settings-name", text: "Claude Code"

      delete settings_device_path(device)
      assert_redirected_to settings_devices_path
      mcp_post(token, { jsonrpc: "2.0", id: 1, method: "ping" })
      assert_response :unauthorized
    end
  end
end
