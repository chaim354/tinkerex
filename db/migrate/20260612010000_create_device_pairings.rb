class CreateDevicePairings < ActiveRecord::Migration[8.1]
  def change
    create_table :device_pairings do |t|
      t.integer :user_id, null: false
      t.string :code_digest, null: false   # SHA256 of the human-entered code (never stored plaintext)
      t.datetime :expires_at, null: false
      t.datetime :claimed_at               # single-use: set when redeemed
      t.timestamps
    end
    add_index :device_pairings, [:user_id, :code_digest], unique: true
    add_index :device_pairings, [:user_id, :expires_at]
  end
end
