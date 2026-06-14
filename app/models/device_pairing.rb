# A short-lived, single-use code that lets a *new* device join an existing user's
# library — issued by an already-authenticated device, redeemed by the new one. This is
# how additional devices are added securely without re-handing-out a token for any email
# (the account-takeover hole the old `register` had). Same model Syncthing/Plex use.
#
# Only the code's SHA256 digest is stored; the plaintext is shown once at issue time.
class DevicePairing < ApplicationRecord
  belongs_to :user

  CODE_TTL = 10.minutes
  # Unambiguous alphabet for hand-entry (no 0/O/1/I); ~40 bits over 8 chars.
  ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789".chars.freeze

  attr_reader :plaintext_code

  # Issue a fresh code for `user`. Returns the record; read `.plaintext_code` once.
  def self.issue!(user:, ttl: CODE_TTL)
    code = Array.new(8) { ALPHABET.sample }.join
    rec = create!(user:, code_digest: digest(code), expires_at: ttl.from_now)
    rec.instance_variable_set(:@plaintext_code, code)
    rec
  end

  # Atomically redeem a code for `user`. Returns true exactly once per code: the
  # single-use guard is an UPDATE...WHERE claimed_at IS NULL, so concurrent redeems
  # can't both win. False on unknown/expired/already-claimed.
  def self.claim!(user:, code:)
    return false if code.blank?
    rec = where(user:, code_digest: digest(code), claimed_at: nil)
          .where("expires_at > ?", Time.current).first
    return false unless rec
    where(id: rec.id, claimed_at: nil).update_all(claimed_at: Time.current) == 1
  end

  def self.digest(code)
    Digest::SHA256.hexdigest(code.to_s.strip.upcase)
  end
end
