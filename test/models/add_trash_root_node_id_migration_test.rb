require "test_helper"
require Dir[Rails.root.join("db/migrate/*_add_trash_root_node_id_to_nodes.rb")].first

# Drives the migration's `up` over rows written in the shapes the adapters wrote BEFORE the column,
# rather than trusting the backfill by reading it. `down` then `up`, for the reason
# create_maker_addon_state_revisions_migration_test.rb gives: this database is already migrated, so a
# bare `up` would fail on `add_column` before reaching the backfill.
#
# EVERY EXPECTED ROOT DIFFERS FROM THE DEFAULT (§15's default-equals-expected trap): a backfill that
# never ran leaves NULL, which is right for only four of the sixteen rows, and every way of getting
# the walk wrong lands a row on a different root — the parent instead of the topmost ancestor (a2,
# b2: depth two), one root for everything (two folders, b and c, each of their own), a separate
# delete filed under its folder (aold), a member stranded beneath a scan tombstone (cx), and the
# older of two same-named rows taken as the member (ax_old).
#
# THE TIMES ARE DAYS APART, never compared at `.to_i` (§15): one cascade statement stamps every row
# it moves with ONE `updated_at`, which is the evidence the backfill reads, and a backfill that
# re-stamped what it read would move the trash's "Deleted" dates by days rather than by nothing.
class AddTrashRootNodeIdMigrationTest < ActiveSupport::TestCase
  EXPECTED = {
    "p" => nil, "l" => nil, "s" => nil, "cs" => nil,
    "d" => "d",
    "a" => "a", "a1" => "a", "a2" => "a", "ax_new" => "a",
    "aold" => "aold", "ax_old" => "ax_old",
    "b" => "b", "b1" => "b", "b2" => "b",
    "c" => "c", "cx" => "c"
  }.freeze

  setup do
    @user = User.create!(email: "trash-root-#{SecureRandom.hex(4)}@example.com")
    @migration = AddTrashRootNodeIdToNodes.new
    ActiveRecord::Migration.suppress_messages { @migration.down }
    Node.reset_column_information
    seed_pre_column_library!
  end

  # AND ONCE MORE AFTER THE TEST, BEFORE THE FIXTURE ROLLBACK, for the reason #439's migration tests
  # found: `up` re-adds the column at the END of `nodes`, where db/schema.rb's load put it in the
  # middle, and a statement prepared in between keeps the column names it first reported. Probed: with
  # this line gone, a later share_test read `trash_root_node_id` as "1" (the shifted `user_id`) on
  # seeds 1, 3 and 4 of 1-8; `reset_column_information` clears the connection's statement cache.
  teardown { Node.reset_column_information }

  test "every trash tombstone records the entry its own delete made, and nothing else records one" do
    stamped = @user.nodes.pluck(:node_id, :updated_at).to_h

    migrate_up(backend: "share")

    assert_equal EXPECTED, roots
    assert_equal stamped, @user.nodes.reload.pluck(:node_id, :updated_at).to_h,
                 "the backfill moved a trash row's Deleted date"
  end

  test "s3 is backfilled the same way: both writable adapters wrote the same shapes" do
    migrate_up(backend: "s3")

    assert_equal EXPECTED, roots
  end

  # ITS TRASH IS THE SYNC SERVER'S, and every chunk_remote row has a NULL storage_path, so the trash
  # shape means nothing in its mirror: a deleted row there is merely deleted.
  test "a chunk_remote deployment records no entry at all" do
    migrate_up(backend: "chunk_remote")

    assert_equal EXPECTED.transform_values { nil }, roots
  end

  # The schema's existing partial shape, tenant-first: a live row carries NULL and pays nothing.
  test "the index is tenant-first and partial on the rows that record an entry" do
    migrate_up(backend: "share")

    index = ActiveRecord::Base.connection.indexes(:nodes).find { |i| i.name == AddTrashRootNodeIdToNodes::INDEX }
    assert index, "no index named #{AddTrashRootNodeIdToNodes::INDEX}"
    assert_equal %w[user_id trash_root_node_id], index.columns
    assert_equal "trash_root_node_id IS NOT NULL", index.where
  end

  private

  # A library as the adapters left it before the column, every shape the backfill must tell apart:
  #
  #   P/ (live)  l.stl (live)  s.stl (removed in Finder: deleted, path kept)  d.stl (deleted on its own)
  #     a/ (a folder delete) ─ a1/ ─ a2.stl                 the cascade's members, two levels down
  #                          └ aold.stl                     deleted on its own, days before a/
  #        x.stl ×2                                         the pre-2026-10-19 cascade re-stamped the
  #                                                         older, separately deleted one with a/'s time
  #   b/ ─ b1/ ─ b2.stl                                     a second folder delete, its own entry
  #   c/ ─ sub/ (a scan tombstone, path kept) ─ cx.stl     a file restored into sub before c/ went
  def seed_pre_column_library!
    t_old, t_a, t_b, t_c, t_d = [ 12, 8, 7, 6, 5 ].map { |n| n.days.ago }
    row!("p", "P", kind: "dir", path: "P", deleted: false, at: t_old)
    row!("l", "l.stl", parent: "p", path: "P/l.stl", deleted: false, at: t_old)
    row!("s", "s.stl", parent: "p", path: "P/s.stl", at: t_old)
    row!("d", "d.stl", parent: "p", at: t_d)
    row!("a", "a", kind: "dir", parent: "p", at: t_a)
    row!("a1", "a1", kind: "dir", parent: "a", at: t_a)
    row!("a2", "a2.stl", parent: "a1", at: t_a)
    row!("aold", "aold.stl", parent: "a1", at: t_old)
    row!("ax_old", "x.stl", parent: "a", at: t_a, created: t_old - 1.day)
    row!("ax_new", "x.stl", parent: "a", at: t_a, created: t_old + 1.day)
    row!("b", "b", kind: "dir", at: t_b)
    row!("b1", "b1", kind: "dir", parent: "b", at: t_b)
    row!("b2", "b2.stl", parent: "b1", at: t_b)
    row!("c", "c", kind: "dir", at: t_c)
    row!("cs", "sub", kind: "dir", parent: "c", path: "c/sub", at: t_old)
    row!("cx", "cx.stl", parent: "cs", at: t_c)
  end

  # `deleted: true` with no path is the TRASH shape; with a path, the SCAN shape. `created:` apart
  # from `at:` is a row the cascade re-stamped after it was made.
  def row!(node_id, name, at:, kind: "file", parent: nil, path: nil, deleted: true, created: at)
    node = travel_to(created) do
      @user.nodes.create!(node_id:, name:, kind:, parent_node_id: parent, storage_path: path, deleted:)
    end
    node.update_columns(updated_at: at)
  end

  def migrate_up(backend:)
    was = ENV["LIBRARY_BACKEND"]
    ENV["LIBRARY_BACKEND"] = backend
    ActiveRecord::Migration.suppress_messages { @migration.up }
  ensure
    ENV["LIBRARY_BACKEND"] = was
    Node.reset_column_information
  end

  def roots = @user.nodes.reload.pluck(:node_id, :trash_root_node_id).to_h
end
