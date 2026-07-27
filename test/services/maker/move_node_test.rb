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

      # The next four pin the guards on the door that has none of its own. Share gets these free
      # from FileLayer::Share (live_node! / parent_dir_rel!); chunk assigns the columns and would
      # succeed at every one of them — and then BROADCAST it, which is the actual damage: a
      # changelog `move` tells every synced device to reparent the file under a node it has never
      # heard of. So each asserts the changelog stayed empty, not merely that it raised.
      test "refuses a destination parent that does not exist" do
        assert_raises(FileLayer::NotFound) do
          Maker::MoveNode.call(@user, node: @node, new_parent_node_id: "no-such-dir")
        end
        assert_nil @node.reload.parent_node_id
        assert_empty @user.changelog_entries.where(op: "move"),
                     "a refused move must not tell every device to reparent under a missing node"
      end

      test "refuses a destination parent that is a file" do
        @user.nodes.create!(node_id: "f-not-a-dir", name: "notes.txt", kind: "file")

        assert_raises(FileLayer::NotFound) do
          Maker::MoveNode.call(@user, node: @node, new_parent_node_id: "f-not-a-dir")
        end
        assert_nil @node.reload.parent_node_id
        assert_empty @user.changelog_entries.where(op: "move")
      end

      test "refuses to move a tombstoned node" do
        @node.update!(deleted: true)

        assert_raises(FileLayer::NotFound) do
          Maker::MoveNode.call(@user, node: @node, new_parent_node_id: "dir-dest")
        end
        assert_nil @node.reload.parent_node_id
        assert_empty @user.changelog_entries.where(op: "move")
      end

      test "refuses a node belonging to another user" do
        other = User.create!(email: "mno-#{SecureRandom.hex(4)}@example.com",
                             confirmed_at: Time.current, omniauth_signup: true)
        theirs = other.nodes.create!(node_id: "f-theirs", name: "secret.stl", kind: "file")

        assert_raises(FileLayer::NotFound) do
          Maker::MoveNode.call(@user, node: theirs, new_parent_node_id: "dir-dest")
        end
        assert_nil theirs.reload.parent_node_id, "another user's node must not be mutated"
        assert_empty @user.changelog_entries.where(op: "move"),
                     "and the caller's changelog must not describe it"
        assert_empty other.changelog_entries, "the owner's devices would never hear of it anyway"
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

      # BOTH SIDES OF THE BOUNDARY, in one test, with nothing created past it. The earlier fixture
      # filled 2..10 — one variant further than the loop can reach — so widening the range by one
      # left every test green and the real limit unpinned.
      test "available_name runs out at HIGHEST_SUFFIX" do
        @user.nodes.create!(node_id: "t-1", name: "bracket.stl", kind: "file",
                            parent_node_id: "dir-dest")
        (2..Maker::MoveNode::HIGHEST_SUFFIX - 1).each do |i|
          @user.nodes.create!(node_id: "t-#{i}", name: "bracket (#{i}).stl", kind: "file",
                              parent_node_id: "dir-dest")
        end
        assert_equal "bracket (9).stl",
                     Maker::MoveNode.available_name(@user, parent_node_id: "dir-dest",
                                                    name: "bracket.stl"),
                     "the highest suffix must actually be offered"

        @user.nodes.create!(node_id: "t-9", name: "bracket (9).stl", kind: "file",
                            parent_node_id: "dir-dest")
        assert_nil Maker::MoveNode.available_name(@user, parent_node_id: "dir-dest",
                                                  name: "bracket.stl"),
                   "and nothing past it may be offered"
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
