# Real human-identity auth on top of the existing account model (CLAUDE.md §8, §12 step 5;
# docs/parity-roadmap.md §A Option 1). Adds a bcrypt password digest and an email-
# confirmation token so a person must prove email ownership before signing in. The
# device-token + DevicePairing bootstrap underneath is UNCHANGED — this is the front door.
class AddAuthenticationToUsers < ActiveRecord::Migration[8.1]
  def change
    # `has_secure_password` digest. Nullable: existing rows (and OmniAuth-only users) may
    # have no password; the model requires one only on password-based signup.
    add_column :users, :password_digest, :string

    # Email confirmation (proves email ownership). `confirmed_at` is set when the user
    # clicks the link; unconfirmed users cannot sign in. The token is single-purpose and
    # only its digest is stored (same hygiene as Device/DevicePairing).
    add_column :users, :confirmed_at, :datetime
    add_column :users, :confirmation_token_digest, :string
    add_column :users, :confirmation_sent_at, :datetime
    add_index  :users, :confirmation_token_digest, unique: true

    # Password reset (Rails 8 generator pattern). Digest-at-rest + sent-at for expiry.
    add_column :users, :reset_token_digest, :string
    add_column :users, :reset_sent_at, :datetime
    add_index  :users, :reset_token_digest, unique: true
  end
end
