require "test_helper"

module Maker
  class LibraryFolderTest < ActiveSupport::TestCase
    # Chunk branch: real chunk backend; folders created via Sync::Mutation (changelog entries).
    class ChunkBranch < LibraryFolderTest
      setup do
        pin_file_layer_backend("chunk")
        Storage::ChunkStore.reset!
        @user = User.create!(email: "lf-#{SecureRandom.hex(4)}@example.com",
                             confirmed_at: Time.current, omniauth_signup: true)
      end

      test "ensure_path! creates nested dirs via sync-mutation, idempotently" do
        leaf = Maker::LibraryFolder.ensure_path!(@user, [ "Projects", "desk-lamp" ])
        assert_equal "dir", leaf.kind
        assert_equal "desk-lamp", leaf.name
        root = @user.nodes.present.find_by!(name: "Projects", parent_node_id: nil, kind: "dir")
        assert_equal root.node_id, leaf.parent_node_id
        assert @user.changelog_entries.exists?(op: "mkdir", node_id: leaf.node_id),
               "chunk mkdir must go through the sync engine (a changelog entry)"

        again = Maker::LibraryFolder.ensure_path!(@user, [ "Projects", "desk-lamp" ])
        assert_equal leaf.node_id, again.node_id, "idempotent — same leaf, no duplicate"
        assert_equal 1, @user.nodes.where(name: "Projects", parent_node_id: nil, kind: "dir").count
      end

      test "create_child! makes one dir under a parent, idempotently (chunk)" do
        parent = Maker::LibraryFolder.ensure_path!(@user, [ "Projects" ])
        child  = Maker::LibraryFolder.create_child!(@user, parent_node_id: parent.node_id, name: "desk-lamp")
        assert_equal "dir", child.kind
        assert_equal "desk-lamp", child.name
        assert_equal parent.node_id, child.parent_node_id
        assert @user.changelog_entries.exists?(op: "mkdir", node_id: child.node_id),
               "chunk mkdir must go through the sync engine"
        again = Maker::LibraryFolder.create_child!(@user, parent_node_id: parent.node_id, name: "desk-lamp")
        assert_equal child.node_id, again.node_id, "idempotent — find-or-create, no duplicate"
      end
    end

    # Share branch: port_writable → FileLayer.current.mkdir (also exercises the s3 code path).
    class ShareBranch < LibraryFolderTest
      setup do
        @root = Dir.mktmpdir("lf-share")
        FileLayer.current = FileLayer::Share.new(root: @root)
        @user = User.create!(email: "lfs-#{SecureRandom.hex(4)}@example.com",
                             confirmed_at: Time.current, omniauth_signup: true)
      end
      teardown do
        FileLayer.reset!
        FileUtils.remove_entry(@root) if @root && File.exist?(@root)
      end

      test "ensure_path! walks via the port's mkdir (share)" do
        leaf = Maker::LibraryFolder.ensure_path!(@user, [ "Projects", "desk-lamp" ])
        assert_equal "Projects/desk-lamp", leaf.storage_path
        assert Dir.exist?(File.join(@root, "Projects", "desk-lamp"))

        again = Maker::LibraryFolder.ensure_path!(@user, [ "Projects", "desk-lamp" ])
        assert_equal leaf.node_id, again.node_id
      end

      test "create_child! makes one dir under a parent via the port (share)" do
        parent = Maker::LibraryFolder.ensure_path!(@user, [ "Projects" ])
        child  = Maker::LibraryFolder.create_child!(@user, parent_node_id: parent.node_id, name: "desk-lamp")
        assert_equal parent.node_id, child.parent_node_id
        assert Dir.exist?(File.join(@root, "Projects", "desk-lamp"))
      end
    end
  end
end
