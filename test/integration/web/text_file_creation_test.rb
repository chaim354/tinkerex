require "test_helper"

module Web
  # MAKING A TEXT FILE WHERE YOU ARE STANDING (2026-09-10, the Files-page affordances plan, Task 4).
  # A door of its own rather than a parameter on FilesController#create: that action's job is bytes
  # off a multipart form, and a create-that-takes-no-bytes riding it would need a third arm with its
  # own refusals.
  #
  # A FRESH SHARE LIBRARY PER TEST, PINNED BEFORE ANY FIXTURE RUNS, for the reason
  # readme_edit_test.rb records at its own setup: these tests write real bytes through the port, and
  # on the ambient s3 and chunk_remote legs the folder mkdir hits the stub bucket and the sync
  # server's provisioning. Pinning share is what makes the three legs report identical counts.
  class TextFileCreationTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @root = use_fresh_share_library!
      @user = User.create!(email: "txt@example.com", password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
    end

    teardown { FileLayer.reset!; FileUtils.remove_entry(@root) if @root&.exist? }

    test "it creates an empty file and lands on its page" do
      post files_text_files_path, params: { name: "bench-notes.txt" }
      node = @user.nodes.present.find_by(name: "bench-notes.txt")
      refute_nil node, "no node was created"
      assert_redirected_to file_path(node.node_id)
    end

    test "a reserved name is refused, and nothing is written" do
      # BOTH GUARDS, because a name-minting door asks two questions (§14b): `valid_leaf_name?` for
      # syntax and `ReservedNames.reserved?` for the library's own namespace. The upload door
      # shipped with NEITHER and was the weakest door in the app.
      before = @user.nodes.count
      post files_text_files_path, params: { name: ".trash" }
      assert_response :unprocessable_entity
      assert_equal before, @user.nodes.count, "a refused name still wrote a row"
    end

    test "a traversing name is refused" do
      before = @user.nodes.count
      post files_text_files_path, params: { name: "../escape.txt" }
      assert_response :unprocessable_entity
      assert_equal before, @user.nodes.count
    end
  end
end
