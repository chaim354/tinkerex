class User < ApplicationRecord
  has_many :devices, dependent: :destroy
  has_many :nodes, dependent: :destroy
  has_many :versions, dependent: :destroy
  has_many :chunks, dependent: :destroy
  has_many :changelog_entries, dependent: :destroy
  has_many :pending_commits, dependent: :destroy
  has_many :device_pairings, dependent: :destroy
  has_many :conflicts, dependent: :destroy
  has_many :file_locks, dependent: :destroy
  has_many :maker_items, class_name: "Maker::Item", dependent: :destroy
  has_many :maker_tags, class_name: "Maker::Tag", dependent: :destroy
  has_many :maker_taggings, class_name: "Maker::Tagging", dependent: :destroy
  has_many :sessions, dependent: :destroy
  has_many :identities, class_name: "UserIdentity", dependent: :destroy

  # Real human-identity auth (docs/parity-roadmap.md §A Option 1). bcrypt password digest.
  # `validations: false` so OmniAuth-only users (no password) and the existing v1 device
  # bootstrap (which creates accounts with no password) stay valid; the sign-up path
  # requires a password explicitly. The email bootstrap that ISSUES device tokens (v1
  # AuthController + DevicePairing) is unchanged — this layer sits *in front of* it
  # (parity-roadmap §A "two layers").
  has_secure_password validations: false

  TOKEN_TTL = 2.hours
  MIN_PASSWORD_LENGTH = 8

  normalizes :email, with: ->(e) { e.to_s.strip.downcase }
  validates :email, presence: true, uniqueness: true,
                    format: { with: URI::MailTo::EMAIL_REGEXP, allow_blank: true }

  # Validate the password ONLY when one is being set (i.e. password-based signup or reset).
  # OmniAuth-only users and the v1 device bootstrap create rows with no password — those
  # stay valid (that's why has_secure_password's built-in validations are disabled above).
  validates :password, length: { minimum: MIN_PASSWORD_LENGTH }, if: -> { password.present? }
  validate :password_confirmation_matches, if: -> { password.present? }

  def password_confirmation_matches
    return if password_confirmation.nil? # confirmation not supplied -> not enforced
    errors.add(:password_confirmation, "doesn't match Password") if password != password_confirmation
  end

  scope :confirmed, -> { where.not(confirmed_at: nil) }

  def confirmed? = confirmed_at.present?

  # --- Email confirmation (proves email ownership; §12 step 5) ----------------------
  # Issue a single-use confirmation token; only its digest is stored. Returns the
  # plaintext to embed in the mailer link.
  def generate_confirmation_token!
    raw = self.class.generate_raw_token
    update!(confirmation_token_digest: self.class.digest_token(raw),
            confirmation_sent_at: Time.current)
    raw
  end

  # Find a user by a raw confirmation token if it hasn't expired. The token is
  # high-entropy, so a direct digest lookup is sufficient.
  def self.find_by_confirmation_token(raw)
    return nil if raw.blank?
    user = find_by(confirmation_token_digest: digest_token(raw))
    return nil unless user&.confirmation_sent_at
    return nil if user.confirmation_sent_at < TOKEN_TTL.ago
    user
  end

  def confirm!
    update!(confirmed_at: Time.current, confirmation_token_digest: nil, confirmation_sent_at: nil)
  end

  # --- Password reset (Rails 8 generator pattern) -----------------------------------
  def generate_reset_token!
    raw = self.class.generate_raw_token
    update!(reset_token_digest: self.class.digest_token(raw), reset_sent_at: Time.current)
    raw
  end

  def self.find_by_reset_token(raw)
    return nil if raw.blank?
    user = find_by(reset_token_digest: digest_token(raw))
    return nil unless user&.reset_sent_at
    return nil if user.reset_sent_at < TOKEN_TTL.ago
    user
  end

  def clear_reset_token!
    update!(reset_token_digest: nil, reset_sent_at: nil)
  end

  def self.generate_raw_token = SecureRandom.urlsafe_base64(32)
  def self.digest_token(raw) = Digest::SHA256.hexdigest(raw.to_s)

  # --- OmniAuth seam (docs/parity-roadmap.md §A) ------------------------------------
  # find-or-create a User from an OmniAuth auth hash. NOT wired to any provider yet — this
  # is the documented hook so a later OIDC/SSO strategy plugs in WITHOUT touching the
  # device bootstrap. After this returns, the normal flow runs: first device → register;
  # Nth device → mint a DevicePairing code (parity-roadmap §A "two layers").
  #
  # SECURITY — auto-linking by email is account-takeover-prone, so it is gated:
  #   * A returning identity (provider+uid we've seen) always maps to its user (safe).
  #   * We only auto-link an *email* to an existing account when (a) the IdP asserts the
  #     email is verified AND (b) that account has NO local password (so we never silently
  #     merge an OAuth login into a credentialed human account — a malicious/misconfigured
  #     IdP asserting a victim's address must not hijack their password login).
  #   * Otherwise we create a fresh account for this identity (unique email permitting).
  # `email_verified` is the standard OIDC claim; absent it, we do NOT trust the address for
  # linking (a brand-new account is still created so login works, but it can't take over an
  # existing one).
  def self.from_omniauth(auth)
    provider = auth[:provider] || auth["provider"]
    uid      = auth[:uid]      || auth["uid"]
    info     = auth[:info]     || auth["info"] || {}
    email    = info[:email]    || info["email"]
    verified = omniauth_email_verified?(auth, info)

    identity = UserIdentity.find_by(provider:, uid:)
    return identity.user if identity

    existing = email.present? ? find_by(email:) : nil
    user =
      if existing && verified && existing.password_digest.blank?
        # Safe to link: provider-verified email, and no local password to hijack.
        existing
      elsif existing
        # An account already owns this email and we won't silently take it over (an
        # unverified-email claim, or a credentialed human account). Refuse rather than
        # attach — the caller surfaces a generic SSO failure.
        raise AccountLinkRefused, "email already linked to an account"
      else
        # No collision: a brand-new account, so trusting the provider email is safe (there
        # is nothing to take over). Mark confirmed since the IdP delivered it.
        new(email:)
      end

    user.confirmed_at ||= Time.current if user.email.present?
    user.password = SecureRandom.urlsafe_base64(32) if user.password_digest.blank?
    user.save!
    user.identities.create!(provider:, uid:)
    user
  end

  # Raised when an OAuth login would otherwise silently merge into a pre-existing account.
  class AccountLinkRefused < StandardError; end

  # Read the IdP's email-verification signal. Standard OIDC exposes `email_verified`;
  # different strategies surface it under `extra.raw_info` or `info`. Treat only an
  # explicit truthy claim as verified.
  def self.omniauth_email_verified?(auth, info)
    raw = (auth[:extra] || auth["extra"] || {})
    raw = (raw[:raw_info] || raw["raw_info"] || raw)
    claim = info[:email_verified] || info["email_verified"] ||
            raw[:email_verified] || raw["email_verified"]
    claim == true || claim.to_s == "true"
  end

  # Assign the next per-user changelog sequence. MUST be called inside a transaction, and
  # MUST be the FIRST write in it (before any node/version/changelog insert): locks the user
  # row so concurrent commits from multiple devices get distinct, ordered seqs. Portable —
  # `SELECT … FOR UPDATE` on Postgres; a harmless reload on SQLite (which serializes writes
  # globally anyway). Correct and fast on both.
  #
  # LOCK ORDERING (Postgres): the node/version/changelog/chunk rows written later in a commit
  # all FK-reference `users`, and a Postgres FK insert takes a `FOR KEY SHARE` lock on the
  # parent users row. If a commit inserted those FIRST and called next_seq! second, two
  # concurrent commits for the same user would each hold KEY SHARE and both want FOR UPDATE →
  # a lock-upgrade DEADLOCK (observed live under a concurrent-commit load test). Taking the
  # strong FOR UPDATE here, up front, makes a user's commits serialize cleanly with no
  # deadlock. All callers (Sync::Commit, Mutation, Restore, Conflicts) lock first.
  #
  # Pooler note: because the FOR UPDATE lock must span the read+write of head_seq, the
  # transaction's statements must run on ONE backend connection — i.e. a connection pooler in
  # front of Postgres MUST be in SESSION or TRANSACTION mode, never STATEMENT mode. See
  # docs/SYNC_SERVER.md "Connection pooler".
  def next_seq!
    lock!
    new_seq = head_seq + 1
    update_column(:head_seq, new_seq)
    new_seq
  end
end
