class AddShareColumnsToNodes < ActiveRecord::Migration[8.1]
  # Share/S3-backed libraries index files that live in the user's own storage, so a node needs
  # to know where its bytes are (storage_path, relative to the configured root) and what they
  # are (content_hash, which doubles as the content_token — those backends keep no history).
  # `size` also lives on the node: in chunk mode it lives on `versions`, which share mode has
  # none of.
  #
  # Chunk mode leaves all three NULL and is unaffected.
  def change
    add_column :nodes, :size, :bigint
    add_column :nodes, :content_hash, :string
    add_column :nodes, :storage_path, :string

    # Reserved for move-detection lookups once the reconciler queries by hash rather than
    # loading the full node set (it pairs a vanished path with a new one by content_hash +
    # size — what lets a rename keep its node_id and its attachments). Not unique: two
    # identical files at different paths legitimately share a hash.
    add_index :nodes, [ :user_id, :content_hash ]

    # One row per (user, path) among LIVE nodes only. Partial because a tombstone RETAINS its
    # storage_path: a deleted-then-restored file (Finder delete + restore from backup, or a
    # move out of the tree and back) would otherwise collide with its own tombstone and raise
    # RecordNotUnique — killing the scan for the entire library, not just that file.
    #
    # The invariant is "one LIVE node per path", so the index says exactly that rather than
    # relying on every present and future tombstone site (2b's trash adds more) to remember to
    # release the path. Chunk mode's NULL storage_paths are unaffected: NULLs are distinct in a
    # unique index on both SQLite and Postgres.
    add_index :nodes, [ :user_id, :storage_path ], unique: true, where: "deleted = false"
  end
end
