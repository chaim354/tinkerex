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

    # create_folder goes through Maker::LibraryFolder, which on share/s3 calls the real port mkdir
    # (a real Aws::S3::Client against a fake bucket on the s3 CI leg; a shared tmpdir on share). The
    # controller logic here is backend-agnostic and the port's cross-backend mkdir is covered by
    # Maker::LibraryFolderTest, so these pin chunk — the repo's idiom for a port-touching test.
    test "create_folder makes a dir under a parent and returns its node" do
      pin_file_layer_backend("chunk")
      assert_difference -> { @user.nodes.present.where(kind: "dir").count }, 1 do
        post library_folders_path, params: { parent_node_id: @projects, name: "exports" }
      end
      assert_response :created
      created = @user.nodes.present.find_by(name: "exports", parent_node_id: @projects, kind: "dir")
      assert_equal created.node_id, json["node_id"]
      assert_equal "exports", json["name"]
      assert_equal "dir", json["kind"]
    end

    test "create_folder at the root uses a nil parent" do
      pin_file_layer_backend("chunk")
      post library_folders_path, params: { name: "Top" }
      assert_response :created
      assert @user.nodes.present.exists?(name: "Top", parent_node_id: nil, kind: "dir")
    end

    test "create_folder rejects a duplicate name in the same folder" do
      pin_file_layer_backend("chunk")
      assert_no_difference -> { @user.nodes.present.where(kind: "dir").count } do
        post library_folders_path, params: { parent_node_id: @projects, name: "v2" } # already exists
      end
      assert_response :unprocessable_entity
      assert_match(/already exists/i, json["error"])
    end

    test "create_folder rejects a blank name" do
      pin_file_layer_backend("chunk")
      post library_folders_path, params: { parent_node_id: @projects, name: "  " }
      assert_response :unprocessable_entity
      assert_match(/blank/i, json["error"])
    end

    # PINNED TO CHUNK ON PURPOSE, and that is the whole point of the case rather than the usual
    # port-touching idiom. Share and S3 each refuse a non-leaf inside their own `leaf!`, so on those
    # two legs this passes whether or not the controller checks anything — chunk is the ONE backend
    # where the door is the only guard, and it is also the main deployment. A name that reaches
    # Maker::LibraryFolder#chunk_mkdir is a live dir node with no further validation ahead of it:
    # Sync::Mutation validates the manifest and not the name, Node validates `name` for presence
    # only, and the name then flows into the changelog and out to every device's real mount.
    #
    # Mutation-checked (§15): replacing the valid_leaf_name? call with the original
    # `return ... if name.include?("/")` turns the "..", backslash and NUL rows red and leaves the
    # "a/b" row green — which is exactly how a weaker private spelling passed for its own test.
    test "create_folder rejects a name that is not a single storable path segment" do
      pin_file_layer_backend("chunk")
      [ "a/b", "a\\b", "..", ".", "nul\0byte", "x" * 300 ].each do |bad|
        assert_no_difference -> { @user.nodes.present.where(kind: "dir").count }, "created #{bad.inspect}" do
          post library_folders_path, params: { name: bad }
        end
        assert_response :unprocessable_entity, "#{bad.inspect} was not refused"
      end
    end
  end
end
