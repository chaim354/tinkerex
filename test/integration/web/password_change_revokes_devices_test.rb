require "test_helper"

module Web
  # A NEW PASSWORD SIGNS OUT EVERY DESKTOP DEVICE, AT EVERY DOOR THAT SETS ONE (pentest H1b,
  # tinkerex#465). The rule is one callback on the column (User#revoke_devices_after_password_change),
  # and this file drives the doors themselves: the emailed reset, the Account page and an admin's
  # reset. The fourth door, `bin/rails tinkerex:password`, is driven in
  # test/tasks/tinkerex_tasks_test.rb, where the rake tasks are loaded. Each door proves the old
  # token is refused by the API itself, not just that a row went.
  #
  # Mutation-checked: without the `after_update` every revocation test below fails, and the two
  # control tests (a refused change, an email-only change) stay green.
  class PasswordChangeRevokesDevicesTest < ActionDispatch::IntegrationTest
    OLD = "old password, long enough".freeze
    NEW = "new password, long enough".freeze

    setup do
      @user = User.create!(email: "revoke-#{SecureRandom.hex(4)}@example.com", password: OLD,
                           confirmed_at: Time.current)
      @token = Device.register!(user: @user, name: "laptop").plaintext_token
      @bystander = User.create!(email: "bystander-#{SecureRandom.hex(4)}@example.com", password: OLD,
                                confirmed_at: Time.current)
      @bystander_token = Device.register!(user: @bystander, name: "theirs").plaintext_token
    end

    def api_status(token)
      get "/v1/maker/projects", headers: { "Authorization" => "Bearer #{token}" }
      response.status
    end

    def assert_signed_out_everywhere
      assert_equal 0, @user.devices.count, "the account's device rows are gone"
      assert_equal 401, api_status(@token), "and its old token is refused by the API"
      assert_equal 200, api_status(@bystander_token), "another account's device is untouched"
    end

    test "precondition: both tokens open the API" do
      assert_equal 200, api_status(@token)
      assert_equal 200, api_status(@bystander_token)
    end

    test "the emailed reset signs out every device" do
      raw, digest = Devise.token_generator.generate(User, :reset_password_token)
      @user.update_columns(reset_password_token: digest, reset_password_sent_at: Time.current)

      put user_password_path, params: { user: { reset_password_token: raw, password: NEW,
                                                password_confirmation: NEW } }
      assert @user.reload.valid_password?(NEW), "precondition: the reset took"
      assert_signed_out_everywhere
    end

    test "a new password on the Account page signs out every device" do
      sign_in_web!(@user, password: OLD)
      put user_registration_path, params: { user: { password: NEW, password_confirmation: NEW,
                                                    current_password: OLD } }
      assert @user.reload.valid_password?(NEW), "precondition: the change took"
      assert_signed_out_everywhere
    end

    test "an admin's reset signs out every device of that account" do
      admin = User.create!(email: "admin-#{SecureRandom.hex(4)}@example.com", password: OLD,
                           confirmed_at: Time.current, admin: true)
      admin_token = Device.register!(user: admin, name: "admin laptop").plaintext_token
      sign_in_web!(admin, password: OLD)

      patch reset_password_settings_user_path(@user), params: { user: { password: NEW } }
      assert @user.reload.valid_password?(NEW), "precondition: the reset took"
      assert_signed_out_everywhere
      assert_equal 200, api_status(admin_token), "the admin's own devices are not the account's"
    end

    # THE CONTROLS. A refused change must revoke nothing, because the callback runs inside the save
    # that was refused. And an Account-page save that leaves the password alone is not a password
    # change.
    test "a refused password change signs nothing out" do
      sign_in_web!(@user, password: OLD)
      put user_registration_path, params: { user: { password: NEW, password_confirmation: NEW,
                                                    current_password: "not my password" } }
      assert @user.reload.valid_password?(OLD), "precondition: the change was refused"
      assert_equal 200, api_status(@token)
    end

    test "an Account-page save that leaves the password blank signs nothing out" do
      sign_in_web!(@user, password: OLD)
      put user_registration_path, params: { user: { email: @user.email, password: "",
                                                    password_confirmation: "", current_password: OLD } }
      assert_equal 200, api_status(@token)
    end
  end
end
