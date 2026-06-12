class CreateFileLocks < ActiveRecord::Migration[8.1]
  def change
    create_table :file_locks do |t|
      t.integer :user_id, null: false
      t.string :node_id, null: false
      t.bigint :device_id, null: false   # the holder
      t.datetime :expires_at, null: false # TTL: a disconnected/crashed holder's lock auto-frees
      t.timestamps
    end
    add_index :file_locks, [ :user_id, :node_id ], unique: true
    add_index :file_locks, [ :user_id, :expires_at ]
  end
end
