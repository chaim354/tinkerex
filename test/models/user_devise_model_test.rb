require "test_helper"

# The User model under Devise: password auth via encrypted_password, confirmable, and the
# CRITICAL passwordless path — OmniAuth-only accounts (no password) must stay VALID even
# though :validatable normally requires a password.
class UserDeviseModelTest < ActiveSupport::TestCase
  PASSWORD = "correct horse battery staple".freeze

  test "valid_password? authenticates against encrypted_password" do
    user = User.create!(email: "a@example.com", password: PASSWORD, confirmed_at: Time.current)
    assert user.valid_password?(PASSWORD)
    assert_not user.valid_password?("nope")
  end

  test "email is normalized (downcased + stripped)" do
    user = User.create!(email: "  MixedCase@Example.COM ", password: PASSWORD, confirmed_at: Time.current)
    assert_equal "mixedcase@example.com", user.email
  end

  test "a password account requires a password (validatable)" do
    user = User.new(email: "needspw@example.com", password: "short")
    assert_not user.valid?, "a too-short password is rejected"
    assert_includes user.errors.attribute_names, :password
  end

  test "an OMNIAUTH-only account is valid with no password (password_required? = false)" do
    user = User.new(email: "oauth@example.com")
    user.identities.build(provider: "openid_connect", uid: "x-1")
    assert user.valid?, "omniauth identity present -> password not required"
    assert user.save
    assert user.encrypted_password.blank? || user.encrypted_password == "",
           "no usable password is set for an omniauth-only account"
  end

  test "next_seq! still works (sync hot path untouched)" do
    user = User.create!(email: "seq@example.com", password: PASSWORD, confirmed_at: Time.current)
    assert_equal 1, user.next_seq!
    assert_equal 2, user.next_seq!
  end
end
