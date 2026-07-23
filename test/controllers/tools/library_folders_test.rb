require "test_helper"

module Tools
  # Exercises the extracted concern through a tiny host that includes it, so the behavior is pinned
  # independently of any one addon. Uses the same "scope to the user's own live dirs" contract the
  # boxes folder tests already rely on.
  class LibraryFoldersTest < ActiveSupport::TestCase
    class Host
      include Tools::LibraryFolders
      attr_reader :current_user, :params
      def initialize(user, params) = (@current_user, @params = user, ActionController::Parameters.new(params))
    end

    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "lf@example.com", password: PASSWORD, confirmed_at: Time.current)
    end

    test "folder_options lists the library root first, then the user's folders by path" do
      @user.nodes.create!(node_id: SecureRandom.uuid, name: "Projects", kind: "dir")
      opts = Host.new(@user, {}).send(:folder_options)
      assert_equal ["/ (library root)", ""], opts.first
      assert opts.any? { |label, _| label == "/Projects" }
    end

    test "chosen_parent_node_id returns nil for a blank param (root)" do
      assert_nil Host.new(@user, {}).send(:chosen_parent_node_id)
    end

    test "chosen_parent_node_id returns the node_id of the user's own live folder" do
      dir = @user.nodes.create!(node_id: SecureRandom.uuid, name: "CNC", kind: "dir")
      host = Host.new(@user, { parent_node_id: dir.node_id })
      assert_equal dir.node_id, host.send(:chosen_parent_node_id)
    end

    test "chosen_parent_node_id ignores a folder that is not the user's own (falls back to root)" do
      other = User.create!(email: "lf-other@example.com", password: PASSWORD, confirmed_at: Time.current)
      foreign = other.nodes.create!(node_id: SecureRandom.uuid, name: "theirs", kind: "dir")
      host = Host.new(@user, { parent_node_id: foreign.node_id })
      assert_nil host.send(:chosen_parent_node_id)
    end
  end
end
