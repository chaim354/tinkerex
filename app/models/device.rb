class Device < ApplicationRecord
  belongs_to :user

  validates :name, presence: true
  validates :token_digest, presence: true, uniqueness: true

  # THE LIFECYCLE (pentest H1b, tinkerex#465; docs/superpowers/plans/2026-10-22-device-token-lifecycle.md).
  # A token used to live until its row was deleted, and nothing deleted one. Now three things end it:
  #   - REVOCATION deletes the row: Settings → Devices for your own, Settings → Users for an admin.
  #     A revoked token has no use, so there is no `revoked_at` to filter on and nothing to reap.
  #   - A PASSWORD CHANGE revokes every device the account has (User#revoke_devices_after_password_change).
  #   - IDLE EXPIRY: a token unused for `DEVICE_IDLE_DAYS` (default 90) stops authenticating. The row
  #     stays so the Devices page can say what happened, and the user removes it there.
  #
  # The clock is `last_seen_at`, which V1::Authentication stamps on EVERY authenticated request (an
  # unthrottled update_column), so it is exact and the rule needs no slack. A device never used
  # since it signed in counts from `created_at`.
  #
  # WHAT IDLE EXPIRY CANNOT TOUCH IS FILE SYNC. On chunk_remote the desktop app syncs against the
  # sync server with the grant's own token, and it calls this app only when the user opens a maker
  # view (tinkerex-client at 399ccdb). So a device that does nothing but sync idles out HERE while
  # its sync carries on, and the next maker view it opens gets a 401. That client handles a 401
  # badly today (no re-prompt); the follow-up is recorded in the plan above.
  IDLE_DAYS_DEFAULT = 90

  # `0` keeps every token forever, the same convention as LIBRARY_TRASH_DAYS: `0.days.ago` is NOW,
  # so the obvious reading would expire every device at once. Read per call, so a test that flips
  # the variable sees it on the next call. A value that is not a whole number of days is a typo and
  # falls back to the default, never to "forever" (which would turn expiry off silently).
  def self.idle_limit
    days = Integer(ENV.fetch("DEVICE_IDLE_DAYS", IDLE_DAYS_DEFAULT.to_s), exception: false)
    days = IDLE_DAYS_DEFAULT if days.nil? || days.negative?
    days.zero? ? nil : days.days
  end

  # The plaintext token is returned exactly once, at registration; only its digest
  # is stored.
  attr_reader :plaintext_token

  # `sync_device_id` is the sync server's id for this device's sibling (SyncGrant's `device_id`),
  # NULL wherever no grant was brokered. Recorded so that revoking here can reach the sync server
  # once that server has a door for it; until then it is written and not read.
  def self.register!(user:, name: "device", sync_device_id: nil)
    token = SecureRandom.urlsafe_base64(32)
    device = create!(user:, name:, token_digest: digest(token), sync_device_id:)
    device.instance_variable_set(:@plaintext_token, token)
    device
  end

  # nil for an unknown token AND for an expired one: a 401 either way, and the caller never stamps
  # an expired device (V1::Authentication touches only what this returns), so a refused request
  # cannot restart the clock it was refused by.
  def self.authenticate(token)
    return nil if token.blank?

    device = find_by(token_digest: digest(token))
    device unless device&.expired?
  end

  def self.digest(token)
    Digest::SHA256.hexdigest(token)
  end

  def last_active_at = last_seen_at || created_at

  def expired?(limit = self.class.idle_limit)
    limit.present? && last_active_at < limit.ago
  end

  def touch_seen!
    update_column(:last_seen_at, Time.current)
  end
end
