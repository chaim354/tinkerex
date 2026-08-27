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

  # An identity-linked account is passwordless, so `password_required?` is false for it — but
  # "no password is REQUIRED" must never mean "a password being SET escapes validation". Devise's
  # length/confirmation validators are all conditioned on `password_required?`, so a guard that
  # returned false for identity-linked accounts silently accepted a mismatched confirmation on
  # the one account shape the OmniAuth seam creates.
  test "an identity-linked account still validates the password confirmation" do
    user = User.create!(email: "linked@example.com", confirmed_at: Time.current)
    user.identities.create!(provider: "openid_connect", uid: "conf-1")
    # Reload: the transient `omniauth_signup` accessor must be nil, or this exercises the flag
    # rather than the identity, and the precondition below keeps a silently-failing setup from
    # turning the test into a restatement of the ordinary password-account case.
    user = User.find(user.id)
    assert user.identities.exists?
    user.password              = PASSWORD
    user.password_confirmation = "not the same at all"
    assert_not user.valid?, "a mismatched confirmation must be rejected for identity-linked accounts too"
    assert_includes user.errors.attribute_names, :password_confirmation
  end

  test "next_seq! still works (sync hot path untouched)" do
    user = User.create!(email: "seq@example.com", password: PASSWORD, confirmed_at: Time.current)
    assert_equal 1, user.next_seq!
    assert_equal 2, user.next_seq!
  end
end
