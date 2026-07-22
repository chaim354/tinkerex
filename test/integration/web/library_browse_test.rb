require "test_helper"

module Web
  # Session-authed JSON data source for the reusable folder/file chooser.
  #
  # DELIBERATELY NOT PINNED TO A BACKEND for the READ path (like folder_nav_test.rb): #children
  # reads `nodes.parent_node_id`, which all three backends populate identically, so seeding bare
  # nodes and running on the ambient LIBRARY_BACKEND proves it is backend-neutral. The create-folder
  # tests pin chunk (they touch the port; the port's cross-backend mkdir is covered by
  # Maker::LibraryFolderTest). Must stay green on `bin/rails test`, `LIBRARY_BACKEND=share`, and
  # `LIBRARY_BACKEND=s3`.
  class LibraryBrowseTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      Storage::ChunkStore.reset!
      @user = User.create!(email: "browse-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      # /Projects (dir) -> /Projects/v2 (dir) + /Projects/readme.txt (file)
      @projects = node("Projects", "dir", nil)
      @v2       = node("v2", "dir", @projects)
      @readme   = node("readme.txt", "file", @projects)
      @root_stl = node("root.stl", "file", nil)
    end

    def node(name, kind, parent)
      id = SecureRandom.uuid
      @user.nodes.create!(node_id: id, name:, kind:, parent_node_id: parent)
      id
    end

    def json = JSON.parse(response.body)

    test "children of the root lists root dirs only by default (no files)" do
      get library_children_path
      assert_response :success
      names = json["entries"].map { |e| e["name"] }
      assert_includes names, "Projects"
      assert_not_includes names, "root.stl", "files are omitted unless files=1"
      assert_nil json["parent"]
      assert_empty json["crumbs"]
    end

    test "children with files=1 includes files" do
      get library_children_path(files: 1)
      assert_response :success
      names = json["entries"].map { |e| e["name"] }
      assert_includes names, "Projects"
      assert_includes names, "root.stl"
    end

    test "children of a subfolder returns its children + a breadcrumb" do
      get library_children_path(parent: @projects, files: 1)
      assert_response :success
      assert_equal @projects, json["parent"]
      assert_equal %w[Projects], json["crumbs"].map { |c| c["name"] }
      names = json["entries"].map { |e| e["name"] }
      assert_includes names, "v2"
      assert_includes names, "readme.txt"
    end

    test "entries are dirs-first then name" do
      get library_children_path(parent: @projects, files: 1)
      kinds = json["entries"].map { |e| e["kind"] }
      assert_equal kinds.sort_by { |k| k == "dir" ? 0 : 1 }, kinds, "all dirs precede all files"
    end

    test "a foreign/forged parent falls back to the root, never another user's tree" do
      other = User.create!(email: "other-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      theirs = other.nodes.create!(node_id: SecureRandom.uuid, name: "Secret", kind: "dir")
      get library_children_path(parent: theirs.node_id)
      assert_response :success
      assert_nil json["parent"], "foreign parent resolved to root"
      assert_not_includes json["entries"].map { |e| e["name"] }, "Secret"
    end

    test "requires authentication" do
      delete destroy_user_session_path
      get library_children_path
      assert_redirected_to new_user_session_path
    end
  end
end
