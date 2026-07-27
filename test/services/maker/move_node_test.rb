require "test_helper"

module Maker
  # The two-door move, one test class per door — the same shape as library_folder_test.rb, and for
  # the same reason: the branch IS the thing under test, so a single ambient-backend run would
  # exercise whichever door CI happened to pick and call the other one covered.
  class MoveNodeTest < ActiveSupport::TestCase
    # Chunk branch: the sync engine owns the tree, so a move must appear in the changelog.
    class ChunkBranch < MoveNodeTest
      setup do
        pin_file_layer_backend("chunk")
        Storage::ChunkStore.reset!
        @user = User.create!(email: "mn-#{SecureRandom.hex(4)}@example.com",
                             confirmed_at: Time.current, omniauth_signup: true)
        @dest = @user.nodes.create!(node_id: "dir-dest", name: "desk-lamp", kind: "dir")
        @node = @user.nodes.create!(node_id: "f-1", name: "bracket.stl", kind: "file")
      end

      test "moves the node into the destination via the sync engine, keeping its node_id" do
        Maker::MoveNode.call(@user, node: @node, new_parent_node_id: "dir-dest")

        @node.reload
        assert_equal "dir-dest", @node.parent_node_id
        assert_equal "bracket.stl", @node.name
        assert_equal "f-1", @node.node_id, "node_id must survive a move — attachments point at it"
        assert @user.changelog_entries.exists?(op: "move", node_id: "f-1"),
               "chunk-mode move must go through the sync engine (a changelog entry)"
      end

      test "renames when new_name is given" do
        Maker::MoveNode.call(@user, node: @node, new_parent_node_id: "dir-dest",
                             new_name: "bracket (2).stl")
        assert_equal "bracket (2).stl", @node.reload.name
      end

      test "raises Collision when a live sibling already holds the name" do
        @user.nodes.create!(node_id: "f-2", name: "bracket.stl", kind: "file",
                            parent_node_id: "dir-dest")

        assert_raises(Maker::MoveNode::Collision) do
          Maker::MoveNode.call(@user, node: @node, new_parent_node_id: "dir-dest")
        end
        assert_nil @node.reload.parent_node_id, "a refused move must not have moved anything"
      end

      test "a tombstoned sibling is not a collision" do
        @user.nodes.create!(node_id: "f-2", name: "bracket.stl", kind: "file",
                            parent_node_id: "dir-dest", deleted: true)
        Maker::MoveNode.call(@user, node: @node, new_parent_node_id: "dir-dest")
        assert_equal "dir-dest", @node.reload.parent_node_id
      end

      test "moving a node onto its own current name in its own folder is not a collision" do
        @node.update!(parent_node_id: "dir-dest")
        Maker::MoveNode.call(@user, node: @node, new_parent_node_id: "dir-dest")
        assert_equal "dir-dest", @node.reload.parent_node_id
      end

      test "rejects a name that is not a leaf" do
        assert_raises(ArgumentError) do
          Maker::MoveNode.call(@user, node: @node, new_parent_node_id: "dir-dest",
                               new_name: "../escape.stl")
        end
      end

      test "available_name suggests the first free (n) variant" do
        @user.nodes.create!(node_id: "f-2", name: "bracket.stl", kind: "file",
                            parent_node_id: "dir-dest")
        assert_equal "bracket (2).stl",
                     Maker::MoveNode.available_name(@user, parent_node_id: "dir-dest",
                                                    name: "bracket.stl")

        @user.nodes.create!(node_id: "f-3", name: "bracket (2).stl", kind: "file",
                            parent_node_id: "dir-dest")
        assert_equal "bracket (3).stl",
                     Maker::MoveNode.available_name(@user, parent_node_id: "dir-dest",
                                                    name: "bracket.stl")
      end

      test "available_name returns nil when every variant is taken" do
        (2..10).each do |i|
          @user.nodes.create!(node_id: "t-#{i}", name: "bracket (#{i}).stl", kind: "file",
                              parent_node_id: "dir-dest")
        end
        @user.nodes.create!(node_id: "t-1", name: "bracket.stl", kind: "file",
                            parent_node_id: "dir-dest")
        assert_nil Maker::MoveNode.available_name(@user, parent_node_id: "dir-dest",
                                                  name: "bracket.stl")
      end
    end

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
        assert_empty @user.changelog_entries.where(op: "move"),
                     "a share library has no changelog — the port is the whole move"
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
