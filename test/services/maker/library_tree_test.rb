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
