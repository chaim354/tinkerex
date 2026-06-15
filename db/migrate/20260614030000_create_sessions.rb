# The Rails 8 authentication-generator Session model: a server-side session row keyed by
# a signed cookie. Each browser login is a Session record; logout / "sign out everywhere"
# just deletes rows. We store its SHA256 digest (not the raw id) so a leaked DB row can't
# be replayed — same digest-at-rest hygiene as Device tokens (CLAUDE.md §8).
class CreateSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :sessions do |t|
      t.references :user, null: false, foreign_key: true
      t.string :token_digest, null: false
      t.string :user_agent
      t.string :ip_address
      t.timestamps
    end
    add_index :sessions, :token_digest, unique: true
  end
end
