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
  # device bootstrap. An OAuth-authenticated email is treated as already-confirmed (the
  # IdP proved ownership). After this returns, the normal flow runs: first device →
  # register; Nth device → mint a DevicePairing code (parity-roadmap §A "two layers").
  def self.from_omniauth(auth)
    provider = auth[:provider] || auth["provider"]
    uid      = auth[:uid]      || auth["uid"]
    info     = auth[:info]     || auth["info"] || {}
    email    = info[:email]    || info["email"]

    identity = UserIdentity.find_by(provider:, uid:)
    return identity.user if identity

    user = email.present? ? find_or_initialize_by(email:) : new
    user.confirmed_at ||= Time.current if email.present?
    user.password = SecureRandom.urlsafe_base64(32) if user.password_digest.blank?
    user.save!
    user.identities.create!(provider:, uid:)
    user
  end

  # Assign the next per-user changelog sequence. MUST be called inside a
  # transaction: locks the user row so concurrent commits from multiple devices
  # get distinct, ordered seqs. Portable — FOR UPDATE on Postgres; SQLite
  # serializes writes globally so correctness holds either way.
  def next_seq!
    lock!
    new_seq = head_seq + 1
    update_column(:head_seq, new_seq)
    new_seq
  end
end
