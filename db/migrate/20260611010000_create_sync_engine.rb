# Sync-engine schema. Adapter-agnostic (runs on SQLite and PostgreSQL): only
# standard column types, standard indexes, and bigint counters. Stable cross-device
# identities are string UUIDs (node_id/version_id/manifest_id/commit_id); internal
# PKs are the default bigint. See docs/sync-protocol.md.
class CreateSyncEngine < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      t.string  :email, null: false
      t.bigint  :head_seq, null: false, default: 0  # per-user changelog cursor
      t.timestamps
    end
    add_index :users, :email, unique: true

    create_table :devices do |t|
      t.references :user, null: false, foreign_key: true
      t.string :name, null: false, default: "device"
      t.string :token_digest, null: false
      t.datetime :last_seen_at
      t.timestamps
    end
    add_index :devices, :token_digest, unique: true

    # The file tree. parent_node_id references another node's node_id (NULL = root).
    create_table :nodes do |t|
      t.references :user, null: false, foreign_key: true
      t.string  :node_id, null: false                 # stable cross-device uuid
      t.string  :parent_node_id                        # NULL = root
      t.string  :name, null: false
      t.string  :kind, null: false                     # 'file' | 'dir'
      t.string  :current_version_id                    # files only
      t.boolean :deleted, null: false, default: false  # tombstone
      t.bigint  :updated_seq, null: false, default: 0  # changelog seq of last change
      t.timestamps
    end
    add_index :nodes, %i[user_id node_id], unique: true
    add_index :nodes, %i[user_id parent_node_id]
    add_index :nodes, %i[user_id updated_seq]

    # Immutable version history. A version = a node pointing at a manifest.
    create_table :versions do |t|
      t.references :user, null: false, foreign_key: true
      t.string  :version_id, null: false
      t.string  :node_id, null: false
      t.string  :manifest_id, null: false
      t.bigint  :size, null: false, default: 0
      t.bigint  :device_id
      t.string  :parent_version_id
      t.datetime :created_at, null: false
    end
    add_index :versions, %i[user_id version_id], unique: true
    add_index :versions, %i[user_id node_id id]

    # A manifest is the set of its chunk rows (no separate manifests table needed).
    # manifest_id = SHA-256 of the ordered chunk-hash list (matches the client).
    create_table :manifest_chunks do |t|
      t.references :user, null: false, foreign_key: true
      t.string :manifest_id, null: false
      t.integer :seq, null: false
      t.string :chunk_hash, null: false
      t.bigint :offset, null: false
      t.bigint :length, null: false
    end
    add_index :manifest_chunks, %i[user_id manifest_id seq], unique: true

    # Content-addressed chunks, scoped per user, refcounted for GC.
    create_table :chunks do |t|
      t.references :user, null: false, foreign_key: true
      t.string  :chunk_hash, null: false
      t.bigint  :size, null: false, default: 0
      t.integer :refcount, null: false, default: 0
      t.timestamps
    end
    add_index :chunks, %i[user_id chunk_hash], unique: true
    add_index :chunks, %i[user_id refcount]

    # The ordered per-user changelog. Pull = entries where seq > cursor.
    create_table :changelog_entries do |t|
      t.references :user, null: false, foreign_key: true
      t.bigint  :seq, null: false
      t.string  :node_id, null: false
      t.string  :op, null: false                # 'put' | 'mkdir' | 'delete' | 'move'
      t.string  :version_id
      t.datetime :created_at, null: false
    end
    add_index :changelog_entries, %i[user_id seq], unique: true

    # Two-phase commit state between begin and finalize.
    create_table :pending_commits do |t|
      t.references :user, null: false, foreign_key: true
      t.bigint :device_id
      t.string :commit_id, null: false
      t.string :node_id, null: false
      t.string :parent_node_id
      t.string :name, null: false
      t.string :base_version_id
      t.string :manifest_id, null: false
      t.bigint :size, null: false, default: 0
      t.text   :manifest_json, null: false      # the chunk list, to finalize without resend
      t.timestamps
    end
    add_index :pending_commits, %i[user_id commit_id], unique: true
  end
end
