# TRASH MEMBERSHIP BECOMES A RECORDED FACT (F-S02-1, slice T2 of the 2026-10-19 simplification audit).
#
# `nodes.trash_root_node_id` names the trash ENTRY a tombstone went into: its own node_id when it was
# the thing deleted, its folder's when it travelled inside one, NULL on a live row and on a SCAN
# tombstone (removed outside the app, path kept). `delete` writes it and `undelete` reads it back, so
# a folder restore revives exactly the rows that folder's delete moved — where it used to revive
# every walked row whose rebuilt path existed, which brought a file deleted on its own back over its
# replacement's bytes, or collided with the replacement and 500ed once the purge had taken the
# earlier entry. A `nodes.node_id`, not an integer id: the `*_node_id` convention every bare-string
# reference into `nodes` follows (SchemaMap::EDGES draws it). It records MEMBERSHIP, not existence —
# after the purge the members still name a gone entry, and their restore says so.
#
# THE INDEX IS THE SCHEMA'S EXISTING PARTIAL SHAPE, tenant-first: a live row carries NULL and pays
# nothing on insert, and `undelete`'s `(user_id, trash_root_node_id)` lookup is the one it serves.
#
# THE BACKFILL, for every row in the trash shape the adapters wrote before this column (`deleted`,
# `storage_path` NULL): the topmost ancestor, by the parent edge, that went into the trash IN THE SAME
# DELETE. One cascade stamps every row it moves with one `updated_at` (an `update_all` with a single
# `Time.current`, the only statement either adapter has ever written a trash row with), so a row whose
# stamp differs from its folder's was deleted on its own, before the folder, and roots its own entry.
# The walk climbs through SCAN tombstones too (path kept, `deleted`): a file restored into a folder the
# scan had tombstoned travels with the folder above it. It stops at a live row, at a missing parent, at
# a cycle, and at MAX_DEPTH — `parent_node_id` carries no constraint against a cycle (FileLayer::Subtree
# argues the same cap).
#
# WHAT THE STAMP CANNOT TELL: the cascade before 2026-10-19 re-stamped every tombstone already inside
# the folder, so an older separate delete reads as a member there. One case of that is corrected here
# because it 500s: two same-named members of one folder, which is the ordinary replace — delete
# `x.stl`, upload a corrected one, delete the folder. A live path is unique, so at most one of them was
# live when the folder went; the newest is taken as the member and the others as their own entries.
# The rest stays filed under the folder: its restore cannot bring such a row back (its bytes are in its
# own entry) and re-roots it instead (FileLayer::TrashMembership.release!), so it is restored on its own.
#
# chunk_remote IS SKIPPED: its trash is the sync server's, and every row in its mirror has a NULL path,
# so the trash shape means nothing there. Read from LIBRARY_BACKEND, which every Kamal destination sets.
#
# SELF-CONTAINED, never `Node` or FileLayer::Subtree: this runs against whatever the app looks like
# months from now (the rederive migrations' rule). `down` drops the index before the column, because
# SQLite rebuilds the table to drop a column and would carry a partial index naming it.
class AddTrashRootNodeIdToNodes < ActiveRecord::Migration[8.1]
  INDEX = "index_nodes_on_user_id_and_trash_root_node_id".freeze
  MAX_DEPTH = 64
  BATCH = 500

  class MigrationNode < ActiveRecord::Base
    self.table_name = "nodes"
  end

  def up
    add_column :nodes, :trash_root_node_id, :string
    add_index :nodes, [ :user_id, :trash_root_node_id ], where: "trash_root_node_id IS NOT NULL", name: INDEX
    return say("chunk_remote: its trash is the sync server's, nothing to backfill") if chunk_remote?

    MigrationNode.reset_column_information
    recorded = MigrationNode.where(deleted: true, storage_path: nil).distinct.pluck(:user_id)
                            .sum { |user_id| backfill(user_id) }
    say "recorded the trash entry of #{recorded} tombstone#{"s" unless recorded == 1}"
  end

  def down
    remove_index :nodes, name: INDEX
    remove_column :nodes, :trash_root_node_id
  end

  private

  def chunk_remote? = ENV["LIBRARY_BACKEND"] == "chunk_remote"

  def backfill(user_id)
    # node_id => [parent_node_id, name, trash?, updated_at, created_at, id], every DELETED row: the
    # trash rows to file, and the scan tombstones the walk climbs through.
    rows = MigrationNode.where(user_id:, deleted: true)
                        .pluck(:node_id, :parent_node_id, :name, :storage_path, :updated_at, :created_at, :id)
                        .to_h { |id, parent, name, path, updated, created, pk| [ id, [ parent, name, path.nil?, updated, created, pk ] ] }
    trash = rows.select { |_, row| row[2] }.keys
    roots = trash.index_with { |id| root_of(id, rows, Set.new) }
    own = replaced(roots, rows)
    roots = trash.index_with { |id| root_of(id, rows, own) } if own.any?

    roots.group_by(&:last).each do |root, pairs|
      pairs.map(&:first).each_slice(BATCH) do |ids|
        MigrationNode.where(user_id:, node_id: ids).update_all(trash_root_node_id: root)
      end
    end
    roots.size
  end

  # The topmost trash row above `id` that shares its stamp, walking through scan tombstones. A row in
  # `own` is a boundary: it roots its own entry, so nothing beneath it is filed above it.
  def root_of(id, rows, own)
    stamp = rows.fetch(id)[3]
    root = current = id
    seen = Set[id]
    MAX_DEPTH.times do
      break if own.include?(current)

      parent = rows.fetch(current)[0]
      break if parent.nil? || !rows.key?(parent) || seen.include?(parent)

      seen << parent
      current = parent
      _, _, trash, updated = rows.fetch(current)
      root = current if trash && updated == stamp
    end
    root
  end

  # Same-named members of one entry under one parent: all but the newest were deleted on their own.
  def replaced(roots, rows)
    roots.reject { |id, root| id == root }
         .group_by { |id, root| [ root, rows.fetch(id)[0], rows.fetch(id)[1] ] }
         .values.select { |group| group.size > 1 }
         .flat_map { |group| group.map(&:first).sort_by { |id| rows.fetch(id).values_at(4, 5) }[0...-1] }
         .to_set
  end
end
