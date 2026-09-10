require "test_helper"

# EVERY NODE AT OR BENEATH A DIRECTORY, walked by the parent edge — the set both writable adapters
# must tombstone when a folder is deleted.
#
# ONE WALK, NOT TWO, and that is the whole reason this is a service rather than a private method on
# each adapter. Share moves a directory with a single rename and S3 copies object by object; they
# have almost nothing in common EXCEPT that both must tombstone exactly the same set, and a second
# copy of this walk is a second chance to tombstone a subset. A live node left pointing at a path
# now inside `.trash` is §14b's skip-list wedge: the scan refuses to look there, so no observation
# can ever pair it, and the tombstone that follows trips the mass-deletion guard — refusing that
# scan and every scan after it, permanently.
class FileLayer::SubtreeTest < ActiveSupport::TestCase
  setup do
    @root = Pathname.new(Dir.mktmpdir("subtree-test"))
    @user = User.create!(email: "sub-#{SecureRandom.hex(4)}@example.com")
  end
  teardown { FileUtils.remove_entry(@root) if @root&.exist? }

  test "it returns the directory itself and every descendant" do
    create_node!(@user, node_id: "d1", name: "parts", kind: "dir")
    create_node!(@user, node_id: "d2", name: "stl", kind: "dir", parent_node_id: "d1")
    create_node!(@user, node_id: "f1", name: "a.stl", kind: "file", parent_node_id: "d2")
    create_node!(@user, node_id: "f2", name: "b.stl", kind: "file", parent_node_id: "d1")

    assert_equal %w[d1 d2 f1 f2].sort, FileLayer::Subtree.node_ids(@user, "d1").sort
  end

  test "it walks by parent_node_id, never by storage_path" do
    # BY PARENT, NOT BY PATH, and this fixture is the reason. `move` rewrites only the moved node's
    # OWN row, so a moved directory's descendants keep a STALE storage_path until the next scan
    # pairs them — a prefix walk would miss exactly the children most likely to be mid-reorganisation,
    # and missing one is the wedge. The parent edge is always accurate in the catalog.
    create_node!(@user, node_id: "d1", name: "parts", kind: "dir")
    leaf = create_node!(@user, node_id: "f1", name: "a.stl", kind: "file", parent_node_id: "d1")
    leaf.update_column(:storage_path, "somewhere/else/entirely/a.stl")

    assert_includes FileLayer::Subtree.node_ids(@user, "d1"), "f1"
  end

  test "a tombstoned descendant is included, so a re-delete cannot strand it" do
    # A directory can hold nodes already tombstoned by a scan. They must come along: leaving one
    # live-by-omission is the same wedge, and `undelete` needs the full set to revive.
    create_node!(@user, node_id: "d1", name: "parts", kind: "dir")
    gone = create_node!(@user, node_id: "f1", name: "old.stl", kind: "file", parent_node_id: "d1")
    gone.update!(deleted: true, storage_path: nil)

    assert_includes FileLayer::Subtree.node_ids(@user, "d1"), "f1"
  end

  test "it never leaves the user" do
    other = User.create!(email: "other-#{SecureRandom.hex(4)}@example.com")
    create_node!(@user, node_id: "d1", name: "parts", kind: "dir")
    other.nodes.create!(node_id: "x1", name: "theirs.stl", kind: "file", parent_node_id: "d1")

    assert_equal [ "d1" ], FileLayer::Subtree.node_ids(@user, "d1")
  end

  test "a cycle in the parent edge terminates instead of hanging" do
    # THE CATALOG HAS NO CONSTRAINT FORBIDDING A CYCLE, which is why LibraryTree#path_for carries a
    # guard too (docs/invariants/model-intake.md). Without the depth cap this walk never returns,
    # and a delete that hangs holds a Puma thread until it times out.
    create_node!(@user, node_id: "d1", name: "a", kind: "dir")
    create_node!(@user, node_id: "d2", name: "b", kind: "dir", parent_node_id: "d1")
    @user.nodes.find_by!(node_id: "d1").update_column(:parent_node_id, "d2")

    ids = Timeout.timeout(5) { FileLayer::Subtree.node_ids(@user, "d1") }
    assert_equal %w[d1 d2].sort, ids.sort
  end

  test "the query count is bounded by DEPTH, not by width" do
    # A directory of 200 files is still ONE query per level. A per-node walk would be 200, which on
    # a real library is the difference between a delete and a timeout.
    create_node!(@user, node_id: "d1", name: "parts", kind: "dir")
    30.times { |i| create_node!(@user, node_id: "f#{i}", name: "f#{i}.stl", kind: "file", parent_node_id: "d1") }

    queries = 0
    counter = ->(*, payload) { queries += 1 unless payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      FileLayer::Subtree.node_ids(@user, "d1")
    end
    assert_operator queries, :<=, 3, "#{queries} queries for a two-level tree — this is per-node"
  end
end
