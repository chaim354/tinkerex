class User < ApplicationRecord
  has_many :devices, dependent: :destroy
  has_many :nodes, dependent: :destroy
  has_many :versions, dependent: :destroy
  has_many :chunks, dependent: :destroy
  has_many :changelog_entries, dependent: :destroy
  has_many :pending_commits, dependent: :destroy
  has_many :conflicts, dependent: :destroy
  has_many :file_locks, dependent: :destroy
  has_many :share_links, dependent: :destroy
  has_many :maker_items, class_name: "Maker::Item", dependent: :destroy
  has_many :maker_tags, class_name: "Maker::Tag", dependent: :destroy
  has_many :maker_taggings, class_name: "Maker::Tagging", dependent: :destroy
  has_many :maker_file_attachments, class_name: "Maker::FileAttachment", dependent: :destroy
  has_many :maker_collections, class_name: "Maker::Collection", dependent: :destroy
  has_many :maker_tasks, class_name: "Maker::Task", dependent: :destroy
  has_many :maker_projects, class_name: "Maker::Project", dependent: :destroy
  has_many :maker_build_log_entries, class_name: "Maker::BuildLogEntry", dependent: :destroy
  has_many :maker_locations, class_name: "Maker::Location", dependent: :destroy
  has_many :maker_suppliers, class_name: "Maker::Supplier", dependent: :destroy
  has_many :maker_inventory_items, class_name: "Maker::InventoryItem", dependent: :destroy
  has_many :maker_inventory_transactions, class_name: "Maker::InventoryTransaction", dependent: :destroy
  has_many :maker_previews, class_name: "Maker::Preview", dependent: :destroy
  has_many :maker_boms, class_name: "Maker::Bom", dependent: :destroy
  has_many :maker_bom_lines, class_name: "Maker::BomLine", dependent: :destroy
  has_many :maker_addon_states, class_name: "Maker::AddonState", dependent: :destroy
  has_many :maker_notes, class_name: "Maker::Note", dependent: :destroy
  has_many :maker_sheets, class_name: "Maker::Sheet", dependent: :destroy
  has_many :maker_models, class_name: "Maker::Model", dependent: :destroy
  has_many :maker_print_runs, through: :maker_models, source: :print_runs
  has_many :identities, class_name: "UserIdentity", dependent: :destroy

  # Human-identity auth via Devise (CLAUDE.md §8; replaces the hand-rolled password +
  # confirmation/reset token flow). The v1 device-token + device-login enrollment is a
  # SEPARATE layer (Device model, Authentication concern) and is untouched.
  #   :confirmable  — email-ownership gate (unconfirmed accounts can't sign in / enroll).
  #   :lockable     — brute-force mitigation (also protects device-login).
  #   :trackable    — sign-in counters/timestamps.
  #   :timeoutable  — idle WEB sessions expire (device tokens are unaffected).
  #   :omniauthable — preserves the OAuth/OIDC seam (UserIdentity + from_omniauth).
  devise :database_authenticatable, :registerable, :recoverable, :rememberable,
         :validatable, :confirmable, :lockable, :trackable, :timeoutable,
         :omniauthable, omniauth_providers: %i[openid_connect]

  # Set transiently by from_omniauth (and the v1 bootstrap) so a passwordless account
  # validates on first save before its UserIdentity row is persisted. Not a DB column.
  attr_accessor :omniauth_signup

  # Passwordless accounts are created by trusted server-side flows (the OmniAuth seam and the
  # legacy device-token bootstrap), never by a human web signup. They have no password to
  # confirm via the email flow, so suppress Devise's confirmation-instructions email for them
  # (web signups always carry a password, so they still get confirmation mail). This also
  # avoids invoking the Devise mailer — which needs a routed Devise mapping — from plain unit
  # tests that create bootstrap users.
  before_create :skip_passwordless_confirmation_notification

  def skip_passwordless_confirmation_notification
    skip_confirmation_notification! if respond_to?(:skip_confirmation_notification!) &&
                                       encrypted_password.blank? && password.blank?
  end
  private :skip_passwordless_confirmation_notification

  normalizes :email, with: ->(e) { e.to_s.strip.downcase }

  # --- OmniAuth seam (docs/parity-roadmap.md §A) ------------------------------------
  # find-or-create a User from an OmniAuth auth hash.
  #
  # SECURITY — auto-linking by email is account-takeover-prone, so it is gated:
  #   * A returning identity (provider+uid we've seen) always maps to its user (safe).
  #   * We only auto-link an *email* to an existing account when (a) the IdP asserts the
  #     email is verified AND (b) that account has NO local password (so we never silently
  #     merge an OAuth login into a credentialed human account — a malicious/misconfigured
  #     IdP asserting a victim's address must not hijack their password login).
  #   * Otherwise we create a fresh account for this identity (unique email permitting).
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
      if existing && verified && !existing.password_set?
        # Safe to link: provider-verified email, and no local password to hijack.
        existing
      elsif existing
        # An account already owns this email and we won't silently take it over (an
        # unverified-email claim, or a credentialed human account). Refuse rather than
        # attach — the caller surfaces a generic SSO failure.
        raise AccountLinkRefused, "email already linked to an account"
      else
        # No collision: a brand-new account, so trusting the provider email is safe.
        new(email:)
      end

    # IdP delivered the email -> treat as confirmed (skip Devise's confirmation email).
    user.skip_confirmation! if user.respond_to?(:skip_confirmation!) && user.confirmed_at.nil?
    user.confirmed_at ||= Time.current if user.email.present?
    user.omniauth_signup = true
    user.save!
    user.identities.find_or_create_by!(provider:, uid:)
    user
  end

  # Raised when an OAuth login would otherwise silently merge into a pre-existing account.
  class AccountLinkRefused < StandardError; end

  # True when the account has a usable bcrypt password (NOT an OmniAuth-only account).
  # Devise stores `""` (the column default) for passwordless accounts; bcrypt never
  # matches an empty digest, so a blank/"" encrypted_password means "no password".
  def password_set?
    encrypted_password.present?
  end

  # Devise :validatable requires a password by default. We preserve the prior model's
  # `has_secure_password validations: false` semantic: a password is REQUIRED only when one
  # is actually being set (web password signup / reset). Passwordless accounts stay valid —
  # OmniAuth-only accounts (UserIdentity present) and the server-side device-token bootstrap
  # (omniauth_signup flag). Devise still validates length + confirmation whenever a password
  # IS provided (so web signup with a mismatched/short password is still rejected), and
  # bcrypt never matches the empty digest, so a passwordless account cannot password-auth.
  def password_required?
    return false if omniauth_signup || omniauth_identity?
    return false if encrypted_password.blank? && password.blank?
    super
  end

  # An account backed by at least one external identity (built or persisted). Checks the
  # in-memory association too so `User.new` + `identities.build` validates without a save.
  def omniauth_identity?
    identities.any? { |i| i.persisted? || i.new_record? }
  end

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

  # ENGINE STATE ON THE HOST'S OWN ROW. head_seq and next_seq! belong to the sync engine — they
  # serialize changelog sequence assignment and mean nothing on share/s3. They stay here through
  # Stage 3a and move with the engine's migration in 3b; relocating the column now would be a
  # migration this repo would immediately have to undo. (The boot guard that protects this lock,
  # lib/postgres_pooler_check.rb, is already engine-conditional as of 3a — see Sync.engine_present?.)
  #
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
