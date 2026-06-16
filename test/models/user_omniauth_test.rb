require "test_helper"

# The OmniAuth seam (User.from_omniauth) + its anti-takeover guard, preserved across the
# Devise migration.
class UserOmniauthTest < ActiveSupport::TestCase
  PASSWORD = "correct horse battery staple".freeze

  test "from_omniauth creates a confirmed user + identity for a new provider account" do
    auth = { provider: "openid_connect", uid: "abc-123", info: { email: "oauth@example.com" } }
    user = nil
    assert_difference [ -> { User.count }, -> { UserIdentity.count } ], 1 do
      user = User.from_omniauth(auth)
    end
    assert_equal "oauth@example.com", user.email
    assert user.confirmed?, "an IdP-verified email is treated as confirmed"
    assert_equal user, UserIdentity.find_by(provider: "openid_connect", uid: "abc-123").user
  end

  test "from_omniauth returns the same user for a repeat login" do
    auth = { provider: "openid_connect", uid: "uid-9", info: { email: "repeat@example.com" } }
    first = User.from_omniauth(auth)
    assert_no_difference [ -> { User.count }, -> { UserIdentity.count } ] do
      assert_equal first, User.from_omniauth(auth)
    end
  end

  test "from_omniauth REFUSES to take over an existing PASSWORD account by email" do
    User.create!(email: "link@example.com", password: PASSWORD, confirmed_at: Time.current)
    auth = { provider: "openid_connect", uid: "uid-link",
             info: { email: "link@example.com", email_verified: true } }
    assert_no_difference [ -> { User.count }, -> { UserIdentity.count } ] do
      assert_raises(User::AccountLinkRefused) { User.from_omniauth(auth) }
    end
  end

  test "from_omniauth REFUSES to take over an existing account when email is unverified" do
    User.create!(email: "unverified@example.com", confirmed_at: Time.current, omniauth_signup: true)
    auth = { provider: "openid_connect", uid: "uid-unv", info: { email: "unverified@example.com" } }
    assert_raises(User::AccountLinkRefused) { User.from_omniauth(auth) }
  end

  test "from_omniauth links to an existing PASSWORDLESS account when email is verified" do
    existing = User.create!(email: "oauthonly@example.com", confirmed_at: Time.current, omniauth_signup: true)
    assert_not existing.password_set?
    auth = { provider: "openid_connect", uid: "uid-ok",
             info: { email: "oauthonly@example.com", email_verified: true } }
    assert_no_difference -> { User.count } do
      assert_equal existing, User.from_omniauth(auth)
    end
    assert existing.identities.exists?(provider: "openid_connect", uid: "uid-ok")
  end

  test "from_omniauth reads email_verified from extra.raw_info too" do
    User.create!(email: "rawinfo@example.com", confirmed_at: Time.current, omniauth_signup: true)
    auth = { provider: "openid_connect", uid: "uid-raw",
             info: { email: "rawinfo@example.com" },
             extra: { raw_info: { email_verified: true } } }
    assert_nothing_raised { User.from_omniauth(auth) }
  end
end
