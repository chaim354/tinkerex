class CreateShareLinks < ActiveRecord::Migration[8.1]
  def change
    create_table :share_links do |t|
      # The creator/owner of the file. The shared bytes live in this user's existing
      # keyspace (chunks/<user_id>/<hash>) — a redeemed link mints presigned GETs against
      # the OWNER's keyspace, scoped to exactly this version's manifest chunks. No
      # cross-user re-keying, no tenancy change (see docs/plan-sharing.md "shallow slice").
      t.references :user, null: false, foreign_key: true

      # The immutable target: a single version of a single node. A link is a read-only
      # capability over one snapshot, so revoking/expiring it cuts access on the next mint.
      t.string :node_id,     null: false
      t.string :version_id,  null: false
      t.string :manifest_id, null: false

      # SHA256 of the raw, single-use-in-the-URL capability token. Only the digest is stored.
      t.string :token_digest, null: false

      t.datetime :expires_at  # nil = never expires
      t.datetime :revoked_at  # nil = live

      t.timestamps
    end

    add_index :share_links, :token_digest, unique: true
    add_index :share_links, %i[user_id version_id]
  end
end
