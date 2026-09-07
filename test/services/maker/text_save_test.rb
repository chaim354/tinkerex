require "test_helper"
require "support/git_repo_fixture"

module Maker
  # THE ONE TEXT SAVE (stage 4, S4-4). FilesController#update (a file inside a working tree) and
  # Projects::ReadmesController#update (the project's README, anywhere) are the same operation seen
  # twice — stale-check, write through the port keeping the node, record a pending git edit — and a
  # second copy of it is where the 409 or the `replace:` quietly goes missing on one of the two.
  #
  # OWNS A SHARE LIBRARY: this writes real bytes through the port, so it pins share rather than
  # hitting the s3 stub bucket and the sync server's provisioning on the other two legs.
  class TextSaveTest < ActiveSupport::TestCase
    include GitRepoFixture

    setup do
      @library = use_fresh_share_library!
      @user = User.create!(email: "textsave-#{SecureRandom.hex(4)}@example.com",
                           password: "correct horse battery staple", confirmed_at: Time.current)
      @folder = Maker::LibraryFolder.ensure_path!(@user, [ "Docs" ])
    end

    def write!(name, body)
      Maker::Addons::LibraryOutput.write_bytes!(@user, parent_node_id: @folder.node_id, name:, bytes: body)
      Library::ScanJob.new.perform(user_id: @user.id)
      @user.nodes.present.find_by!(parent_node_id: @folder.node_id, name:)
    end

    def token_for(node) = FileLayer.current.stat(@user, node_id: node.node_id)&.content_token

    test "an existing file is rewritten IN PLACE, keeping its node_id, and the new token comes back" do
      node = write!("README.md", "# Old\n")
      before = node.node_id

      result = Maker::TextSave.call(user: @user, node:, parent_node_id: @folder.node_id,
                                    name: node.name, body: "# New\n", base_token: token_for(node))

      assert result.ok, result.error
      assert_equal before, result.node_id, "a replace must REUSE the node (§14a) — every attachment is keyed on it"
      assert_equal "# New\n", FileLayer.current.read(@user, node_id: before)
      assert_equal token_for(node), result.content_token
    end

    test "a stale base_token is a conflict and writes nothing" do
      node = write!("README.md", "# Old\n")

      result = Maker::TextSave.call(user: @user, node:, parent_node_id: @folder.node_id,
                                    name: node.name, body: "# New\n", base_token: "stale")

      refute result.ok
      assert_equal :conflict, result.status
      assert_equal "# Old\n", FileLayer.current.read(@user, node_id: node.node_id)
    end

    test "no node creates the file at the folder root" do
      result = Maker::TextSave.call(user: @user, node: nil, parent_node_id: @folder.node_id,
                                    name: "README.md", body: "# Fresh\n", base_token: nil)

      assert result.ok, result.error
      assert_equal "# Fresh\n", FileLayer.current.read(@user, node_id: result.node_id)
    end

    test "a create whose name is already taken is refused by the port, not silently clobbered" do
      write!("README.md", "# Old\n")

      assert_raises(FileLayer::UnsupportedOperation) do
        Maker::TextSave.call(user: @user, node: nil, parent_node_id: @folder.node_id,
                             name: "README.md", body: "# New\n", base_token: nil)
      end
    end

    test "a repo root records a pending edit; no repo root records none" do
      node = write!("README.md", "# Old\n")

      Maker::TextSave.call(user: @user, node:, parent_node_id: @folder.node_id, name: node.name,
                           body: "# A\n", base_token: token_for(node))
      assert_equal 0, Maker::RepoEdit.where(user: @user).count

      Maker::TextSave.call(user: @user, node:, parent_node_id: @folder.node_id, name: node.name,
                           body: "# B\n", base_token: token_for(node), repo_root_node_id: @folder.node_id)
      assert_equal [ node.node_id ], Maker::RepoEdit.where(user: @user).pluck(:node_id)
    end
  end
end
