class User < ApplicationRecord
  has_many :devices, dependent: :destroy
  has_many :nodes, dependent: :destroy
  # Stage 3b Phase A Task 3: the seven engine models these associations reach are now
  # `Sync::*`, so each needs an explicit class_name: — Rails derives one from the association
  # NAME (`versions` -> "Version") and that guess no longer resolves to anything. `manifest_chunks`
  # has no has_many here at all (reached by the string manifest_id everywhere), which is why
  # this list is seven, not eight.
  # UNCONDITIONAL, UNLIKE THE Sync:: ASSOCIATIONS BELOW, and the difference is which side owns the
  # class. Those name engine models that do not exist on share/s3; RemoteManifestChunk is a HOST
  # model whose table every deployment has, so there is nothing to guard.
  #
  # `dependent:` IS REQUIRED HERE, NOT DECORATION: the table carries a real foreign key to `users`,
  # so without it `user.destroy` raises ActiveRecord::InvalidForeignKey the moment a chunk_remote
  # deployment has mirrored anything. Probed rather than assumed -- and found by deleting a leftover
  # test user by hand, where the manifest rows had to be cleared first for the destroy to work.
  #
  # `:delete_all`, NOT `:destroy`: these rows have no callbacks and there is one PER CHUNK PER
  # VERSION, so a large library would instantiate thousands of objects to run nothing on each.
  has_many :remote_manifest_chunks, dependent: :delete_all

  # ARC C TASK 4: THIS USER'S OWN device token on the standalone sync server, replacing the single
  # process-wide CHUNK_REMOTE_TOKEN every chunk_remote request used to authenticate with. That env
  # var is NOT what Provisioning's admin call uses either (that's SYNC_ADMIN_TOKEN, a different,
  # deployment-wide credential -- Provisioning's own header) -- CHUNK_REMOTE_TOKEN is read nowhere in
  # this app's request-serving code any more, and (Arc D Task 2) no longer gates boot either:
  # lib/library_backend_check.rb's CHUNK_REMOTE_REQUIRED named it for a while after it stopped
  # mattering, demanding a credential nothing consumed while SYNC_ADMIN_TOKEN -- the one this
  # deployment actually cannot provision a library without -- went unchecked. That constant now
  # names SYNC_ADMIN_TOKEN instead; see its own comment for the full history. CHUNK_REMOTE_TOKEN
  # survives only as a LOCAL dev/CI credential (config/ci.rb, bin/sync-server), unrelated to this
  # column. Nil until this user's first library write; FileLayer::ChunkRemote::Provisioning fills it
  # in.
  #
  # NOT DETERMINISTIC. `encrypts` defaults to non-deterministic (a fresh random IV each write, so
  # two encryptions of the same plaintext produce different ciphertext -- verified in the commit
  # that configured encryption for this app), and deterministic encryption exists ONLY to let a
  # column be queried BY its encrypted value. Nothing here ever does `where(sync_device_token:
  # ...)` -- a device token is looked up by WHO HOLDS the row (the signed-in user), never the
  # other way around -- so deterministic buys nothing and only adds a cost: it also leaks equality
  # (two users who somehow shared a token would have byte-identical ciphertext, visible to
  # anyone with row access, without either value ever being decrypted). `deterministic: false` is
  # written out explicitly rather than left on the default, matching this app's existing rule for
  # `support_unencrypted_data` (config/initializers/active_record_encryption.rb): a default that
  # happens to already be right is exactly what a future Rails upgrade silently flips.
  encrypts :sync_device_token, deterministic: false

  # DECLARED ONLY WHEN THE ENGINE IS LOADED, and `class_name:` being a STRING is not enough to
  # make that unnecessary -- which was probed, not reasoned. A string class_name is lazy, so
  # merely loading User is fine either way; but `dependent: :destroy` constantizes on destroy, and
  # on a share/s3 box with no engine that raises `NameError: Missing model class Sync::Version`
  # from an ordinary `user.destroy`. Nothing at boot would have shown it.
  #
  # The rows these point at cannot exist on share/s3 anyway: only Sync::Commit/Restore/Conflicts
  # ever create a version, and none of them runs there. So this drops associations to tables that
  # are empty by construction, not a feature.

  # ADDING A USER-SCOPED TABLE? IT NEEDS A LINE HERE (or a parent that already has one).
  # Tenant cleanup is these hand-written `dependent:`s and nothing else — no database foreign key
  # backs them (tinkerex#152 weighed that and did not take it). What checks the set is COMPLETE is
  # test/models/tenant_cleanup_test.rb, which derives the table list from the live schema, so a new
  # user_id table fails the suite until its cleanup is decided rather than shipping unswept.
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
  # Stage 3, S3-1: the per-user extension map (Maker::FilingRules, /settings/filing). `:destroy`
  # for the same reason as the reference lists just above -- no callbacks, no dependents, nothing
  # a faster delete would need to skip.
  has_many :maker_filing_rules, class_name: "Maker::FilingRule", dependent: :destroy
  # `:destroy`, not `:delete_all`, only because there is no reason to reach for the faster one:
  # the row carries no callbacks and no dependents. What is NOT optional is that this line
  # exists at all -- without it, TenantCleanupTest fails three ways at once, and the one that
  # matters is that a user destroy leaves the FK unsatisfied. A pending edit is disposable
  # state (the commit box reconciles against git on every open), so there is nothing here worth
  # preserving past the account that owns it.
  has_many :maker_repo_edits, class_name: "Maker::RepoEdit", dependent: :destroy
  # THE ASYMMETRY BETWEEN THESE TWO LINES IS THE POINT; do not normalise either onto the other.
  # Items stay `:destroy` because Maker::InventoryItem carries `before_destroy :release_bom_lines`,
  # which must run per row (§14d). The ledger is `:delete_all` because Maker::InventoryTransaction
  # raises ReadOnlyRecord on ANY record-level destroy — so `:destroy` here blows up the whole
  # account deletion for anyone holding a posted row. It only ever "worked" because :items was
  # declared first and swept the rows away before this line instantiated them; declaration order
  # is not a safety mechanism. Pinned in test/models/maker/inventory_transaction_test.rb.
  has_many :maker_inventory_items, class_name: "Maker::InventoryItem", dependent: :destroy
  has_many :maker_inventory_transactions, class_name: "Maker::InventoryTransaction", dependent: :delete_all
  has_many :maker_previews, class_name: "Maker::Preview", dependent: :destroy
  has_many :maker_boms, class_name: "Maker::Bom", dependent: :destroy
  has_many :maker_bom_lines, class_name: "Maker::BomLine", dependent: :destroy
  has_many :maker_connections, class_name: "Maker::Connection", dependent: :destroy
  has_many :maker_releases, class_name: "Maker::Release", dependent: :destroy
  has_many :maker_release_files, class_name: "Maker::ReleaseFile", dependent: :destroy
  has_many :maker_addon_states, class_name: "Maker::AddonState", dependent: :destroy
  has_many :maker_notes, class_name: "Maker::Note", dependent: :destroy
  # Stage 4, S4-8. `:destroy` rather than `:delete_all` to match every sibling here; the model
  # carries no callbacks, so the two are equivalent in effect and the cheaper one buys nothing at
  # these row counts. TenantCleanupTest is what proves the line exists at all.
  has_many :maker_file_links, class_name: "Maker::FileLink", dependent: :destroy
  has_many :maker_sheets, class_name: "Maker::Sheet", dependent: :destroy
  has_many :maker_models, class_name: "Maker::Model", dependent: :destroy
  has_many :maker_print_runs, through: :maker_models, source: :print_runs
  has_many :maker_shelves, class_name: "Maker::Shelf", dependent: :destroy
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

  # VESTIGIAL, AND DELIBERATELY SO: nothing reads this. It existed so `from_omniauth` could save a
  # brand-new passwordless account before its UserIdentity row was persisted, but
  # `password_required?` answers that from the password itself, which covers the same case without
  # asking how the account was created — see its comment for why the account-shape reading was a
  # live auth defect. Kept because 24 test files still pass `omniauth_signup:` to `User.create!`;
  # removing the accessor is a mechanical sweep of those call sites, not a behaviour change. Not a
  # DB column.
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

  # THE HANDLE IS THE FIRST SEGMENT OF EVERY PUBLIC URL (/u/<handle>/<slug>, spec §2.2), so it is
  # lowercase, URL-safe and unique, claimed once under Settings → Account, and LOCKED while any
  # project is unlisted or public -- a rename would break every link a maker has already handed out.
  # Nullable: an account that never publishes never needs one.
  #
  # 2–32 CHARACTERS, AND THE OPTIONAL GROUP IS DELIBERATELY NOT OPTIONAL: a one-character handle
  # would match `[a-z0-9]` alone, which contradicts both the message below and the `pattern`
  # attribute the Account form renders. The three must agree or the browser accepts what the
  # server refuses.
  HANDLE_RE = /\A[a-z0-9][a-z0-9-]{0,30}[a-z0-9]\z/
  # Segments that exist at the site root or are obvious impersonation targets. `u` itself is here
  # so /u/u/... cannot be minted; the rest are the app's own top-level paths (config/routes.rb) —
  # every first segment HANDLE_RE could mint (the underscored ones, `bom_lines`, `current_project`,
  # `print_runs`…, are unmintable already). A handle only ever appears under /u/, so today this is
  # defence in depth for a future bare /<handle> route, not a live gap; S3-4's review enumerated
  # the routes file and found four missing, added below (`csp-violation-report` is hyphenated and
  # therefore mintable).
  RESERVED_HANDLES = %w[
    u explore admin administrator api v1 assets rails up files projects models tools settings
    trash search tags inventory shelves suppliers locations repos library notes attachments
    build_log_entries users login logout sign_in sign_up signin signup register account
    connections csp-violation-report sheets tasks
    tinkerex support help about root www mail
  ].freeze

  normalizes :handle, with: ->(h) { h.to_s.strip.downcase.presence }
  validates :handle, allow_nil: true, uniqueness: true,
            format: { with: HANDLE_RE, message: "is 2–32 characters of a–z, 0–9 and hyphens, starting and ending with a letter or digit" },
            exclusion: { in: RESERVED_HANDLES, message: "is reserved" }
  validate :handle_is_locked_while_published, on: :update

  def handle_locked? = maker_projects.published.exists?

  # THE ONE SPELLING OF "when did a library scan last finish" (stage 4, S4-3). The page renders it
  # into a data attribute and scanreload_controller.js compares the poll's answer to it as a
  # STRING, so the two sides must format identically or the comparison is either never equal (a
  # permanent reload loop) or always equal (a poll that never fires). One method, both callers.
  #
  # SIX DIGITS, NOT `.to_i`. §15: "a timestamp compared at .to_i is a guard that usually cannot
  # fail" — two scans inside one second would read as one, which on this poll means the page never
  # notices the second. Both Postgres and SQLite keep microseconds here.
  def library_scanned_stamp = library_scanned_at&.iso8601(6)

  # A CLAIMED HANDLE IS FROZEN WHILE ANYTHING IS PUBLISHED -- renaming or clearing it would 404
  # every /u/<handle>/<slug> already handed out. Guarded on `handle_in_database.present?` so the
  # FIRST claim is never blocked, and on :update so a fresh record never queries for projects it
  # cannot have.
  #
  # `will_save_change_to_handle?` / `handle_in_database`, NOT `handle_changed?` / `handle_was`:
  # the pair reads the same during validation but diverges after save, and the after-save reading
  # is the one that silently stops guarding anything.
  def handle_is_locked_while_published
    return unless will_save_change_to_handle? && handle_in_database.present? && handle_locked?

    errors.add(:handle, "can't change while a project is unlisted or public")
  end
  # `private :<name>`, MATCHING LINE 138 ABOVE AND NOT A BARE `private` KEYWORD: this class has no
  # private section, so opening one here would take `password_set?` and `next_seq!` (both called
  # from outside) private with it.
  private :handle_is_locked_while_published

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
  # `has_secure_password validations: false` semantic: a password is REQUIRED only when one is
  # actually being set (web password signup / reset), so passwordless accounts stay valid — the
  # OmniAuth seam's brand-new `new(email:)`, identity-backed accounts, and server-side creates
  # alike. THE ONE QUESTION IT ASKS IS ABOUT THE PASSWORD, NEVER ABOUT THE ACCOUNT SHAPE, and that
  # is the invariant: every Devise password validator — length AND confirmation — is conditioned on
  # this predicate, so an "…or the account is identity-linked" arm does not merely make the
  # password optional, it exempts a set password from being CHECKED. That arm shipped, and it
  # silently accepted a mismatched confirmation for exactly the population the OmniAuth seam
  # creates. Pinned in test/models/user_devise_model_test.rb. bcrypt never matches the empty
  # digest, so a passwordless account still cannot password-auth.
  def password_required?
    return false if encrypted_password.blank? && password.blank?
    super
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
  # The pooler constraint this describes is the SYNC SERVER's now, and so is its
  # documentation: chaim354/tinkerex-sync, docs/SYNC_SERVER.md "Connection pooler".
  # NOTHING IN THIS PROCESS TAKES THE LOCK -- next_seq! has no caller here (CLAUDE.md
  # §14e); head_seq survives because V1::DevicesController hands it to a joining device.
  def next_seq!
    lock!
    new_seq = head_seq + 1
    update_column(:head_seq, new_seq)
    new_seq
  end
end
