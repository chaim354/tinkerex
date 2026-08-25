require "test_helper"

module Maker
  # The two-door move, one test class per door — the same shape as library_folder_test.rb, and for
  # the same reason: the branch IS the thing under test, so a single ambient-backend run would
  # exercise whichever door CI happened to pick and call the other one covered.
  class MoveNodeTest < ActiveSupport::TestCase
    # Share branch: port_writable → FileLayer.current.move, which renames the real file AND
    # updates the node row. Exercises the same code path s3 takes.
    class ShareBranch < MoveNodeTest
      setup do
        @root = Dir.mktmpdir("mn-share")
        FileLayer.current = FileLayer::Share.new(root: @root)
        @user = User.create!(email: "mns-#{SecureRandom.hex(4)}@example.com",
                             confirmed_at: Time.current, omniauth_signup: true)
        FileUtils.mkdir_p(File.join(@root, "desk-lamp"))
        File.binwrite(File.join(@root, "bracket.stl"), "solid\n")
        @dest = @user.nodes.create!(node_id: "dir-dest", name: "desk-lamp", kind: "dir",
                                    storage_path: "desk-lamp")
        @node = @user.nodes.create!(node_id: "f-1", name: "bracket.stl", kind: "file",
                                    storage_path: "bracket.stl", size: 6)
      end
      teardown do
        FileLayer.reset!
        FileUtils.remove_entry(@root) if @root && File.exist?(@root)
      end

      test "moves the real file through the port and keeps the node_id" do
        Maker::MoveNode.call(@user, node: @node, new_parent_node_id: "dir-dest")

        assert File.exist?(File.join(@root, "desk-lamp", "bracket.stl")),
               "the bytes must actually move on a share"
        refute File.exist?(File.join(@root, "bracket.stl"))
        @node.reload
        assert_equal "desk-lamp/bracket.stl", @node.storage_path
        assert_equal "dir-dest", @node.parent_node_id
        assert_equal "f-1", @node.node_id
      end

      # THE RETURNED OBJECT, deliberately not a reloaded one — reloading here would test the DB,
      # which the test above already does, and would stay green with port_move's reload deleted.
      # The port updates its OWN instance of the node, so without that reload `call` hands back
      # the caller's stale object and a caller rendering `node.name` after a rename shows the old
      # name on share/s3 while chunk shows the new one.
      test "returns a node carrying the port's new name, not the caller's stale copy" do
        moved = Maker::MoveNode.call(@user, node: @node, new_parent_node_id: "dir-dest",
                                     new_name: "bracket (2).stl")

        assert_equal "bracket (2).stl", moved.name
        assert_equal "desk-lamp/bracket (2).stl", moved.storage_path
        assert_equal "dir-dest", moved.parent_node_id
      end

      test "raises Collision before touching the disk when the name is taken" do
        File.binwrite(File.join(@root, "desk-lamp", "bracket.stl"), "other\n")
        @user.nodes.create!(node_id: "f-2", name: "bracket.stl", kind: "file",
                            parent_node_id: "dir-dest", storage_path: "desk-lamp/bracket.stl")

        assert_raises(Maker::MoveNode::Collision) do
          Maker::MoveNode.call(@user, node: @node, new_parent_node_id: "dir-dest")
        end
        assert_equal "other\n", File.read(File.join(@root, "desk-lamp", "bracket.stl")),
                     "the existing file must be untouched"
        assert File.exist?(File.join(@root, "bracket.stl")), "the source must be untouched"
      end
    end
  end
end
