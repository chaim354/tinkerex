# A server-side browser session (Rails 8 authentication-generator pattern). The signed
# cookie holds an opaque high-entropy token; we store only its SHA256 digest, so a leaked
# DB row can't be replayed (same hygiene as Device/DevicePairing — CLAUDE.md §8). Logout
# deletes the row; "sign out everywhere" deletes all of a user's sessions.
class Session < ApplicationRecord
  belongs_to :user

  attr_reader :plaintext_token

  def self.start!(user:, user_agent: nil, ip_address: nil)
    token = SecureRandom.urlsafe_base64(32)
    session = create!(user:, token_digest: digest(token), user_agent:, ip_address:)
    session.instance_variable_set(:@plaintext_token, token)
    session
  end

  def self.authenticate(token)
    return nil if token.blank?
    find_by(token_digest: digest(token))
  end

  def self.digest(token) = Digest::SHA256.hexdigest(token.to_s)
end
