# Drop the hand-rolled auth columns now that Devise owns confirmation/reset/password.
# encrypted_password (Devise) was backfilled from password_digest in 000002. confirmed_at
# and confirmation_sent_at are RETAINED (Devise :confirmable uses them).
class DropLegacyUserAuthColumns < ActiveRecord::Migration[8.1]
  def up
    remove_index :users, :confirmation_token_digest, if_exists: true
    remove_index :users, :reset_token_digest, if_exists: true
    remove_column :users, :password_digest, :string
    remove_column :users, :confirmation_token_digest, :string
    remove_column :users, :reset_token_digest, :string
    remove_column :users, :reset_sent_at, :datetime
  end

  def down
    add_column :users, :password_digest, :string
    add_column :users, :confirmation_token_digest, :string
    add_column :users, :reset_token_digest, :string
    add_column :users, :reset_sent_at, :datetime
    add_index :users, :confirmation_token_digest, unique: true
    add_index :users, :reset_token_digest, unique: true
  end
end
