require "test_helper"

# A device token's lifecycle (pentest H1b, tinkerex#465): idle expiry here; revocation through the
# Settings pages in test/integration/web/settings_devices_test.rb, and by a password change in
# test/integration/web/password_change_revokes_devices_test.rb.
class DeviceTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "device-#{SecureRandom.hex(4)}@example.com", confirmed_at: Time.current,
                         omniauth_signup: true)
    @prior_idle = ENV["DEVICE_IDLE_DAYS"]
    ENV.delete("DEVICE_IDLE_DAYS")
  end

  teardown { @prior_idle.nil? ? ENV.delete("DEVICE_IDLE_DAYS") : ENV["DEVICE_IDLE_DAYS"] = @prior_idle }

  def register = Device.register!(user: @user, name: "laptop")

  test "a token authenticates, and an unknown or blank one does not" do
    device = register
    assert_equal device, Device.authenticate(device.plaintext_token)
    assert_nil Device.authenticate("not-a-token")
    assert_nil Device.authenticate("")
  end

  # THE SLIDING RULE, on both sides of the line. Days, not a timestamp compared at `.to_i` (§15): the
  # two cases are a whole day apart, so a rule that ignored the clock could not pass both.
  # Mutation-checked: with `authenticate` returning the row whatever its age, the first refusal
  # below authenticates.
  test "a token unused for longer than the idle limit stops authenticating; one used inside it does not" do
    device = register
    device.update_column(:last_seen_at, (Device::IDLE_DAYS_DEFAULT + 1).days.ago)
    assert_nil Device.authenticate(device.plaintext_token), "idle past the limit"
    assert device.reload.expired?

    device.update_column(:last_seen_at, (Device::IDLE_DAYS_DEFAULT - 1).days.ago)
    assert_equal device, Device.authenticate(device.plaintext_token), "used inside the limit"
    assert_not device.reload.expired?
  end

  # A device that signed in and was never used counts from when it signed in, not from never.
  test "a device never used counts from when it signed in" do
    device = travel_to((Device::IDLE_DAYS_DEFAULT + 1).days.ago) { register }
    assert_nil device.last_seen_at
    assert_nil Device.authenticate(device.plaintext_token)

    fresh = register
    assert_equal fresh, Device.authenticate(fresh.plaintext_token)
  end

  test "DEVICE_IDLE_DAYS sets the limit, 0 keeps every device, and junk falls back to the default" do
    device = register
    device.update_column(:last_seen_at, 40.days.ago)

    ENV["DEVICE_IDLE_DAYS"] = "30"
    assert_nil Device.authenticate(device.plaintext_token), "30 days"

    ENV["DEVICE_IDLE_DAYS"] = "0"
    assert_nil Device.idle_limit
    device.update_column(:last_seen_at, 10.years.ago)
    assert_equal device, Device.authenticate(device.plaintext_token), "0 means forever, never 'expire everything'"

    %w[ninety -5 3.5].each do |junk|
      ENV["DEVICE_IDLE_DAYS"] = junk
      assert_equal Device::IDLE_DAYS_DEFAULT.days, Device.idle_limit, "#{junk.inspect} is a typo, not 'forever'"
    end
  end

  test "register! records the sync sibling's id where a grant gave one, and nothing otherwise" do
    assert_nil register.sync_device_id
    assert_equal 4242, Device.register!(user: @user, name: "desk", sync_device_id: 4242).reload.sync_device_id
  end
end
