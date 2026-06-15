# OmniAuth SEAM (docs/parity-roadmap.md §A "keep the OmniAuth seam open"). A
# UserIdentity links an external OAuth/OIDC provider account (provider + uid) to a local
# User, so a later `User.from_omniauth(auth)` can find-or-create without touching the
# password/confirmation columns or the device bootstrap. No provider is wired yet — this
# is the additive-login-method anchor (Option 3/4 plug in here later).
class CreateUserIdentities < ActiveRecord::Migration[8.1]
  def change
    create_table :user_identities do |t|
      t.references :user, null: false, foreign_key: true
      t.string :provider, null: false
      t.string :uid, null: false
      t.timestamps
    end
    add_index :user_identities, [ :provider, :uid ], unique: true
  end
end
