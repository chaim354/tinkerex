require "test_helper"

module Maker
  class LibraryTreeTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "tree-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
      # BACKEND-NEUTRAL FIXTURES ON PURPOSE. This class reads `nodes` and never touches the port,
      # so a bare create! is a complete fixture here -- unlike project_intake_test.rb, which moves
      # real files and therefore needs a real share library (§14a's NULL storage_path trap).
      dir("d-models", "3D Models", nil)
      dir("d-enc", "Enclosure", "d-models")
      dir("d-parts", "parts", "d-enc")
    end

    def dir(node_id, name, parent)
      @user.nodes.create!(node_id:, name:, kind: "dir", parent_node_id: parent, mtime: 1, size: 0)
    end

    test "the root is the empty path" do
      assert_equal "", Maker::LibraryTree.new(@user).path_for(nil)
    end

    test "a nested dir resolves to its slash-joined path" do
      tree = Maker::LibraryTree.new(@user)
      assert_equal "3D Models", tree.path_for("d-models")
      assert_equal "3D Models/Enclosure", tree.path_for("d-enc")
      assert_equal "3D Models/Enclosure/parts", tree.path_for("d-parts")
    end

    test "ancestors run nearest-first and end at the root" do
      assert_equal [ "d-parts", "d-enc", "d-models", nil ],
                   Maker::LibraryTree.new(@user).ancestors_of("d-parts")
    end

    test "an unknown or tombstoned dir resolves to nil rather than raising" do
      dir("d-dead", "Dead", nil).update!(deleted: true)
      tree = Maker::LibraryTree.new(@user)
      assert_nil tree.path_for("d-dead")
      assert_nil tree.path_for("nope")
    end

    # A CYCLE IS UNREPRESENTABLE ON A MOUNT BUT REACHABLE IN A ROW SET, and an unguarded walk
    # hangs the sweep rather than failing it. FilesController#folder_crumbs guards the same way.
    test "a parent cycle terminates instead of hanging" do
      @user.nodes.find_by!(node_id: "d-models").update!(parent_node_id: "d-parts")
      assert_nil Maker::LibraryTree.new(@user).path_for("d-enc")
    end

    # ancestors_of HAS THE SAME GUARD AND A WORSE FAILURE WITHOUT IT. path_for's unguarded
    # mutation yields a quietly wrong string (`:broken.name` is "broken" in Ruby 3+, so the
    # sentinel reads as an ordinary path segment); ancestors_of's raises NoMethodError on
    # `entry.node_id`. Maker::ModelIntake calls this for EVERY file in the library, so a broken
    # chain is a normal Tuesday, not an exotic input.
    test "ancestors of an unresolvable chain are nil, not a raise" do
      dir("d-dead2", "Dead", nil).update!(deleted: true)
      tree = Maker::LibraryTree.new(@user)
      assert_nil tree.ancestors_of("d-dead2")
      assert_nil tree.ancestors_of("nope")
    end

    # A TWO-NODE CYCLE IS THE SHAPE THE MIRROR CAN ACTUALLY PRODUCE — two dirs each claiming the
    # other as parent, which no mount can represent and any row set can. The three-node case above
    # is the same guard with a longer loop.
    test "a two-node parent cycle terminates instead of hanging" do
      dir("d-a", "alpha", "d-b")
      dir("d-b", "bravo", "d-a")
      tree = Maker::LibraryTree.new(@user)
      assert_nil tree.path_for("d-a")
      assert_nil tree.path_for("d-b")
    end

    # --- the memo ---------------------------------------------------------------
    #
    # `path_for` caches, and A CACHE IS WHERE THE `:broken` SENTINEL COMES BACK. The rule the memo
    # must obey is "resolve the whole chain, THEN write": a per-hop write caches a PARTIAL prefix,
    # which is a wrong path rather than a nil — the quiet failure docs/invariants/model-intake.md
    # names, in a new place. These two tests are the ones that fail when it is written per hop.

    test "one walk memoizes every ancestor with its OWN path, not the leaf's" do
      tree = Maker::LibraryTree.new(@user)
      assert_equal "3D Models/Enclosure/parts", tree.path_for("d-parts")
      assert_equal "3D Models/Enclosure", tree.path_for("d-enc")
      assert_equal "3D Models", tree.path_for("d-models")
      assert_equal "", tree.path_for(nil)
      # and asking twice answers the same, which is the only thing a cache may change
      assert_equal "3D Models/Enclosure/parts", tree.path_for("d-parts")
    end

    test "a broken chain leaves no ancestor readable back as a path" do
      dir("d-dead3", "Dead", nil).update!(deleted: true)
      dir("d-mid", "Mid", "d-dead3")
      dir("d-leaf", "Leaf", "d-mid")
      tree = Maker::LibraryTree.new(@user)
      assert_nil tree.path_for("d-leaf")
      # THE PREFIX THE WALK BUILT ON THE WAY UP MUST NOT HAVE BEEN KEPT: "Mid" is a path to a
      # folder whose parent no longer exists, so it names a top-level folder that is not there.
      assert_nil tree.path_for("d-mid")
      assert_nil tree.path_for("d-leaf")
    end

    test "a cycle leaves no member readable back as a path" do
      dir("c-a", "alpha", "c-b")
      dir("c-b", "bravo", "c-a")
      tree = Maker::LibraryTree.new(@user)
      assert_nil tree.path_for("c-a")
      assert_nil tree.path_for("c-b")
      assert_nil tree.path_for("c-a")
    end

    # THE SET Tools::LibraryFolders BUILDS ITS PICKER FROM. It is the index's own keys, which is
    # what makes a second `where(kind: "dir")` pluck beside it redundant rather than merely similar.
    test "dir_ids is every live dir the user owns" do
      dir("d-dead4", "Dead", nil).update!(deleted: true)
      assert_equal %w[d-enc d-models d-parts], Maker::LibraryTree.new(@user).dir_ids.sort
    end

    # THE INDEX Maker::ProjectFolderListing WALKS. A file child and a tombstoned dir child must
    # both be absent -- the walk this feeds only ever enters LIVE dirs.
    test "children_of a dir returns its live dir children only -- a tombstoned or file child is absent" do
      dir("d-enc-dead", "Dead", "d-models").update!(deleted: true)
      @user.nodes.create!(node_id: "f-readme", name: "readme.txt", kind: "file",
                          parent_node_id: "d-models", mtime: 1, size: 1)
      tree = Maker::LibraryTree.new(@user)
      assert_equal [ "d-enc" ], tree.children_of("d-models").map(&:node_id)
    end

    test "children_of an unknown id is empty, not a raise" do
      assert_equal [], Maker::LibraryTree.new(@user).children_of("nope")
    end

    # THE MEMO IS THE POINT, same argument as path_for's -- a per-level `where(parent_node_id:)`
    # is exactly the per-file query this class exists to avoid.
    test "children_of asked twice issues no second query" do
      tree = Maker::LibraryTree.new(@user)
      first = tree.children_of("d-models").map(&:node_id)
      after = count_queries { assert_equal first, tree.children_of("d-models").map(&:node_id) }
      assert_equal 0, after
    end

    test "the index costs one query regardless of how many dirs there are" do
      before = count_queries { Maker::LibraryTree.new(@user) }
      12.times { |i| dir("bulk-#{i}", "bulk#{i}", nil) }
      after = count_queries { Maker::LibraryTree.new(@user) }
      assert_equal before, after
    end

    def count_queries(&block)
      n = 0
      counter = ->(*, payload) { n += 1 unless payload[:name].in?(%w[SCHEMA TRANSACTION]) }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
      n
    end
  end
end
