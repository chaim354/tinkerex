class AddSymlinkTargetToNodes < ActiveRecord::Migration[8.1]
  # Symlinks are metadata-only nodes (kind = 'symlink'): the link target is the node's
  # entire content — tiny inline bytes, no manifest/chunks — so it rides the control
  # plane on the node row (binary, nullable; NULL for files/dirs). Mirrors the client's
  # `fs-provider` nodes.symlink_target BLOB.
  def change
    add_column :nodes, :symlink_target, :binary, null: true
  end
end
