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
      # A real share library, and fixtures that exist on disk -- see test_helper's create_node!
      # for why (§14a: a bare nodes.create! leaves a NULL storage_path, which cannot exist here).
      @root = use_fresh_share_library!
      @user = User.create!(email: "browse-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      # /Projects (dir) -> /Projects/v2 (dir) + /Projects/readme.txt (file)
      @projects = node("Projects", "dir", nil)
      @v2       = node("v2", "dir", @projects)
      @readme   = node("readme.txt", "file", @projects)
      @root_stl = node("root.stl", "file", nil)
    end

    teardown do
      FileLayer.reset!
      FileUtils.remove_entry(@root) if @root&.exist?
    end

    def node(name, kind, parent)
      id = SecureRandom.uuid
      create_node!(@user, node_id: id, name:, kind:, parent_node_id: parent)
      id
    end

    def json = JSON.parse(response.body)

    # WHAT THE FILE CHOOSER SENDS (lib/file_chooser.js): a form body with `Accept: application/json`.
    # Since the top bar's New ▸ Folder made #create_folder answer HTML too, a post that names no
    # Accept gets the integration session's browser-like default, which Rails reads as HTML — so
    # these JSON assertions have to say what the real caller says.
    CHOOSER = { "Accept" => "application/json" }.freeze

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

    # THE CHOOSER HIDES WHAT THE FILES PAGE HIDES, and until 2026-09-07 it did not — it offered
    # `.git` as a destination folder, which every write guard then refuses (Library::ReservedNames),
    # so the one thing a user could do with that row was earn a refusal. `*.ptr` stubs and dot-files
    # went the same way. Node.visible_entries is the SAME scope FilesController#index filters by, so
    # there is one definition of "clutter" and not a second one here (§14d).
    #
    # BOTH ARMS, because they are different scopes: `files=1` widens what is listed and must not
    # widen what is hidden, and the folder-only default has its own `where(kind: "dir")` on top.
    #
    # BUILD OUTPUT JOINED THE LIST IN STAGE 4, S4-2 (`Library::BuildOutput`) and lands here for
    # free, because this door asks the shared scope rather than re-listing the rules. `build/` is
    # deliberately NOT on that list, so it is the negative case here: a chooser that hid every
    # plausible clutter name would pass with only refusals asserted.
    #
    # Mutation-checked (§15): `visible_entries` -> `present` turns the `.git`/`.ptr`/`.DS_Store`
    # rows red while every other case in this file stays green.
    test "children hides the .git marker, .ptr stubs, dot-files and build-output dirs" do
      folder = node("repo", "dir", nil)
      node(Library::RepoMetadata::DIR_NAME, "dir", folder)
      node(".hidden", "dir", folder)
      node("node_modules", "dir", folder)
      node("__pycache__", "dir", folder)
      node("build", "dir", folder)
      node("src", "dir", folder)
      node("notes.ptr", "file", folder)
      node(".DS_Store", "file", folder)
      node("main.c", "file", folder)

      get library_children_path(parent: folder, files: 1)
      assert_response :success
      assert_equal %w[build src main.c], json["entries"].map { |e| e["name"] }

      get library_children_path(parent: folder)
      assert_response :success
      assert_equal %w[build src], json["entries"].map { |e| e["name"] }
    end

    test "a foreign/forged parent falls back to the root, never another user's tree" do
      other = User.create!(email: "other-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      theirs = create_node!(other, node_id: SecureRandom.uuid, name: "Secret", kind: "dir")
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
      assert_difference -> { @user.nodes.present.where(kind: "dir").count }, 1 do
        post library_folders_path, params: { parent_node_id: @projects, name: "exports" }, headers: CHOOSER
      end
      assert_response :created
      created = @user.nodes.present.find_by(name: "exports", parent_node_id: @projects, kind: "dir")
      assert_equal created.node_id, json["node_id"]
      assert_equal "exports", json["name"]
      assert_equal "dir", json["kind"]
    end

    test "create_folder at the root uses a nil parent" do
      post library_folders_path, params: { name: "Top" }, headers: CHOOSER
      assert_response :created
      assert @user.nodes.present.exists?(name: "Top", parent_node_id: nil, kind: "dir")
    end

    test "create_folder rejects a duplicate name in the same folder" do
      assert_no_difference -> { @user.nodes.present.where(kind: "dir").count } do
        post library_folders_path, params: { parent_node_id: @projects, name: "v2" }, headers: CHOOSER # already exists
      end
      assert_response :unprocessable_entity
      assert_match(/already exists/i, json["error"])
    end

    # A FILE ALREADY AT THAT NAME, WHICH THE ACTION'S OWN DUPLICATE CHECK CANNOT SEE -- it is
    # scoped `kind: "dir"`. The port refuses this on all three backends (Stage 2 gave chunk the
    # cross-kind refusal share and s3 always had), so what reaches the action is
    # FileLayer::UnsupportedOperation. Until this test existed nothing here rescued it, and the
    # modal that promises an inline 422 got a 500.
    #
    # DRIVEN THROUGH THE REAL REQUEST, not by calling the port: the gap was in the CONTROLLER, so
    # no adapter suite could ever have found it. §14a records that exact shape for TrashController,
    # which shipped an uncaught 500 while its own rescue comment already named the case.
    #
    # PINNED ON CHUNK ONLY, like every other test in this file, and that is enough HERE because the
    # rescue is backend-agnostic -- it catches a class the port raises whichever adapter is loaded,
    # and each adapter's own refusal is pinned across all three in
    # FileLayerMutationContract#test_mutation_contract_mkdir_refuses_a_cross_kind_collision. Pinning
    # the other two would need this suite to carry LIBRARY_PATH and the five LIBRARY_S3_* knobs,
    # which is what the three-leg CI exists to supply.
    test "create_folder answers 422, not 500, when a FILE already holds the name" do
      assert_no_difference -> { @user.nodes.present.where(kind: "dir").count } do
        post library_folders_path, params: { parent_node_id: @projects, name: "readme.txt" }, headers: CHOOSER
      end
      assert_response :unprocessable_entity
      assert_match(/already named/i, json["error"])
    end

    test "create_folder rejects a blank name" do
      post library_folders_path, params: { parent_node_id: @projects, name: "  " }, headers: CHOOSER
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
      [ "a/b", "a\\b", "..", ".", "nul\0byte", "x" * 300 ].each do |bad|
        assert_no_difference -> { @user.nodes.present.where(kind: "dir").count }, "created #{bad.inspect}" do
          post library_folders_path, params: { name: bad }, headers: CHOOSER
        end
        assert_response :unprocessable_entity, "#{bad.inspect} was not refused"
      end
    end

    # PINNED TO CHUNK FOR THE SAME REASON AS THE CASE ABOVE, and it is again the point rather than
    # the idiom. Share and S3 refuse these inside their own `observable!` (reached here through
    # Maker::LibraryFolder's port mkdir, surfacing as the FileLayer::NotFound this action already
    # rescues), so on those two legs the case passes whether or not the door checks anything. Chunk
    # is the one backend where the door is the only guard — `chunk_mkdir` writes the dir row itself
    # and Node validates `name` for presence only — and it is the main deployment. Probed before the
    # fix: 201 and a live dir node for every name below, including a `.trash` DIRECTORY at the
    # library root, which is the shape FileLayer::Share#observable! documents as wedging every
    # delete in the library.
    #
    # A DIR, NOT A FILE, is what makes this worth its own case: the addon-save guard covers file
    # leaves, and a folder is the other half of the same namespace.
    #
    # Mutation-checked (§15): dropping the Library::ReservedNames call from #create_folder turns
    # every row here red while the syntax case above stays green.
    test "create_folder rejects a name the library scan will never index" do
      %w[.DS_Store ._resource __MACOSX .Trashes .Spotlight-V100 .trash .maker-tmp-x].each do |bad|
        assert_no_difference -> { @user.nodes.present.where(kind: "dir").count }, "created #{bad.inspect}" do
          post library_folders_path, params: { name: bad }, headers: CHOOSER
        end
        assert_response :unprocessable_entity, "#{bad.inspect} was not refused"
      end
    end

    # The near miss, so the guard is pinned as EXACT-match on `.trash` rather than a prefix — a
    # folder called `.trashcan` is an ordinary folder the Scanner indexes.
    test "create_folder accepts a name that merely starts with a reserved prefix" do
      post library_folders_path, params: { name: ".trashcan" }, headers: CHOOSER
      assert_response :created
      assert @user.nodes.present.exists?(name: ".trashcan", kind: "dir")
    end
  end
end
