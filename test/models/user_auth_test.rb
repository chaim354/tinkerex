require "test_helper"

# Unit-level coverage of the human-identity helpers on User: password digest, confirmation
# / reset token lifecycle, and the OmniAuth seam (User.from_omniauth). The device bootstrap
# is intentionally untouched here.
class UserAuthTest < ActiveSupport::TestCase
  PASSWORD = "correct horse battery staple".freeze

  test "has_secure_password authenticates" do
    user = User.create!(email: "a@example.com", password: PASSWORD)
    assert user.authenticate(PASSWORD)
    assert_not user.authenticate("nope")
  end

  test "email is normalized (downcased + stripped)" do
    user = User.create!(email: "  MixedCase@Example.COM ", password: PASSWORD)
    assert_equal "mixedcase@example.com", user.email
  end

  test "confirmation token is single-use, digest-stored, and expiring" do
    user = User.create!(email: "b@example.com", password: PASSWORD)
    raw = user.generate_confirmation_token!
    assert_not_equal raw, user.confirmation_token_digest, "stores a digest, not the raw token"

    assert_equal user, User.find_by_confirmation_token(raw)
    user.confirm!
    assert user.confirmed?
    assert_nil user.reload.confirmation_token_digest, "token cleared after confirm"
    assert_nil User.find_by_confirmation_token(raw), "token no longer valid after confirm"
  end

  test "an expired confirmation token is not found" do
    user = User.create!(email: "c@example.com", password: PASSWORD)
    raw = user.generate_confirmation_token!
    user.update_column(:confirmation_sent_at, (User::TOKEN_TTL + 1.minute).ago)
    assert_nil User.find_by_confirmation_token(raw)
  end

  test "reset token lifecycle mirrors confirmation" do
    user = User.create!(email: "d@example.com", password: PASSWORD)
    raw = user.generate_reset_token!
    assert_equal user, User.find_by_reset_token(raw)
    user.clear_reset_token!
    assert_nil User.find_by_reset_token(raw)
  end

  # --- OmniAuth seam ----------------------------------------------------------------
  test "from_omniauth creates a confirmed user + identity for a new provider account" do
    auth = { provider: "oidc", uid: "abc-123", info: { email: "oauth@example.com" } }
    user = nil
    assert_difference [ -> { User.count }, -> { UserIdentity.count } ], 1 do
      user = User.from_omniauth(auth)
    end
    assert_equal "oauth@example.com", user.email
    assert user.confirmed?, "an IdP-verified email is treated as confirmed"
    assert user.password_digest.present?, "a random password is set so the row is valid"
    assert_equal user, UserIdentity.find_by(provider: "oidc", uid: "abc-123").user
  end

  test "from_omniauth returns the same user for a repeat login" do
    auth = { provider: "oidc", uid: "uid-9", info: { email: "repeat@example.com" } }
    first = User.from_omniauth(auth)
    assert_no_difference [ -> { User.count }, -> { UserIdentity.count } ] do
      assert_equal first, User.from_omniauth(auth)
    end
  end

  test "from_omniauth REFUSES to take over an existing password account by email" do
    # Account-takeover guard: a credentialed human account must not be silently merged into
    # an OAuth login just because the IdP asserts the same email address.
    existing = User.create!(email: "link@example.com", password: PASSWORD, confirmed_at: Time.current)
    auth = { provider: "oidc", uid: "uid-link",
             info: { email: "link@example.com", email_verified: true } }
    assert_no_difference [ -> { User.count }, -> { UserIdentity.count } ] do
      assert_raises(User::AccountLinkRefused) { User.from_omniauth(auth) }
    end
    assert_not existing.reload.identities.exists?(provider: "oidc", uid: "uid-link")
  end

  test "from_omniauth REFUSES to take over an existing account when email is unverified" do
    # Even a passwordless account is not auto-linked unless the IdP says the email is verified
    # (an unverified claim could be attacker-controlled).
    User.create!(email: "unverified@example.com", confirmed_at: Time.current)
    auth = { provider: "oidc", uid: "uid-unv", info: { email: "unverified@example.com" } }
    assert_raises(User::AccountLinkRefused) { User.from_omniauth(auth) }
  end

  test "from_omniauth links to an existing PASSWORDLESS account when email is verified" do
    # A prior OAuth-only (no local password) account with this email is safe to attach a new
    # identity to: there is no credential to hijack.
    existing = User.create!(email: "oauthonly@example.com", confirmed_at: Time.current)
    assert existing.password_digest.blank?
    auth = { provider: "oidc", uid: "uid-ok",
             info: { email: "oauthonly@example.com", email_verified: true } }
    assert_no_difference -> { User.count } do
      assert_equal existing, User.from_omniauth(auth)
    end
    assert existing.identities.exists?(provider: "oidc", uid: "uid-ok")
  end

  test "from_omniauth reads email_verified from extra.raw_info too" do
    User.create!(email: "rawinfo@example.com") # passwordless, confirmed_at nil
    auth = { provider: "oidc", uid: "uid-raw",
             info: { email: "rawinfo@example.com" },
             extra: { raw_info: { email_verified: true } } }
    assert_nothing_raised { User.from_omniauth(auth) }
  end
end
