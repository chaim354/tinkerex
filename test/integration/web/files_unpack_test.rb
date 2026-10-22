require "test_helper"

module Web
  # THE FOLDERS-ONLY HALF OF A MODEL ZIP UNPACKED BY THE TOP BAR (Files::UnpacksController). The
  # browser half — JSZip, the per-file uploads — is test/system/topbar_zip_upload_test.rb's. PINNED
  # TO A FRESH SHARE LIBRARY: these make real folders through the port, which on the s3 leg is a
  # Forbidden from the stub bucket and on chunk_remote a per-email library provisioning; what is
  # under test is where the folders go and what is refused, not which backend holds them
  # (Maker::LibraryFolder is the one backend-neutral door and has its own tests).
  class FilesUnpackTest < ActionDispatch::IntegrationTest
    include ActiveJob::TestHelper

    setup do
      @root = use_fresh_share_library!
      @user = sign_in_web!(User.create!(email: "unpack-#{SecureRandom.hex(4)}@example.com",
                                        password: WEB_PASSWORD, confirmed_at: Time.current))
    end

    def unpack(**body)
      post files_unpack_folder_path(format: :json), params: body.to_json,
                                                    headers: { "CONTENT_TYPE" => "application/json" }
      JSON.parse(response.body)
    end

    def mkdir(name, parent = nil)
      FileLayer.current.mkdir(@user, parent_node_id: parent&.node_id, name:)
    end

    def node(id) = @user.nodes.find_by!(node_id: id)

    test "a folder gets a new folder named after the zip, with every requested subfolder" do
      cad = mkdir("cad")
      body = unpack(parent_node_id: cad.node_id, name: "dragon", dirs: [ "parts/tail", "docs" ])

      assert_response :created
      folder = node(body["folder_node_id"])
      assert_equal [ "dragon", cad.node_id ], [ folder.name, folder.parent_node_id ]
      assert_equal files_path(folder: folder.node_id), body["folder_url"]
      tail = node(body.dig("folder_map", "parts/tail"))
      assert_equal "tail", tail.name
      assert_equal [ "parts", folder.node_id ], [ node(tail.parent_node_id).name, node(tail.parent_node_id).parent_node_id ]
      assert_equal folder.node_id, node(body.dig("folder_map", "docs")).parent_node_id
      assert_equal body["folder_node_id"], body.dig("folder_map", "")
      assert @root.join("cad", "dragon", "parts", "tail").directory?, "the folders are real on the share"
    end

    test "at a project's own folder the zip unpacks into models/, the shelf the catalog reads" do
      project = @user.maker_projects.create!(name: "Stargate")
      folder = mkdir("stargate", mkdir("Projects"))
      project.update_column(:folder_node_id, folder.node_id)

      body = unpack(parent_node_id: folder.node_id, name: "iris", dirs: [])

      assert_response :created
      made = node(body["folder_node_id"])
      assert_equal "iris", made.name
      assert_equal [ "models", folder.node_id ], [ node(made.parent_node_id).name, node(made.parent_node_id).parent_node_id ]
    end

    # THE SHELF, NOT THE FILING RULE: a maker who files `stl` into `prints/` still gets the unpacked
    # folder in `models/`, because Maker::ModelIntake::SHELVES names `Projects/*/models` and nothing
    # else under a project — a folder in `prints/` would never become a model. Mutation-checked:
    # #destination through Maker::ProjectFolders.folder_for(current_user, "model.stl") goes RED here
    # with "prints".
    test "at a project's own folder the unpack lands in models/ whatever the filing rule for stl says" do
      Maker::FilingRules.seed!(@user)
      @user.maker_filing_rules.find_by!(ext: "stl").update!(folder: "prints")
      assert_equal "prints", Maker::ProjectFolders.folder_for(@user, "gate.stl")
      project = @user.maker_projects.create!(name: "Iris")
      folder = mkdir("iris", mkdir("Projects"))
      project.update_column(:folder_node_id, folder.node_id)

      body = unpack(parent_node_id: folder.node_id, name: "gate", dirs: [])

      assert_response :created
      dest = node(node(body["folder_node_id"]).parent_node_id)
      assert_equal [ "models", folder.node_id ], [ dest.name, dest.parent_node_id ]
    end

    test "a project's subfolder is used as it is" do
      project = @user.maker_projects.create!(name: "Lamp")
      folder = mkdir("lamp", mkdir("Projects"))
      project.update_column(:folder_node_id, folder.node_id)
      parts = mkdir("parts", folder)

      body = unpack(parent_node_id: parts.node_id, name: "shade", dirs: [])

      assert_equal parts.node_id, node(body["folder_node_id"]).parent_node_id
    end

    test "a taken name gets the next free number, case-folded, files counting too" do
      cad = mkdir("cad")
      mkdir("Dragon", cad)
      # A FILE, materialised on disk under cad/ by create_node! (it reads @root).
      create_node!(@user, node_id: "n-dragon-2", name: "dragon 2", kind: "file", parent_node_id: cad.node_id,
                          mtime: 1, size: 1)

      body = unpack(parent_node_id: cad.node_id, name: "dragon", dirs: [])

      assert_response :created
      assert_equal "dragon 3", node(body["folder_node_id"]).name
    end

    test "the library root is a destination" do
      body = unpack(name: "benchy", dirs: [])

      assert_response :created
      assert_nil node(body["folder_node_id"]).parent_node_id
    end

    test "an invalid or reserved folder name is refused and makes nothing" do
      assert_no_difference -> { @user.nodes.count } do
        unpack(name: "..", dirs: [])
        assert_response :unprocessable_entity
        unpack(name: ".trash", dirs: [])
        assert_response :unprocessable_entity
        unpack(name: [ "a" ], dirs: [])
        assert_response :unprocessable_entity
      end
    end

    test "a numbered name pushed past the byte limit is refused and makes nothing" do
      long = "d" * 254
      mkdir(long)

      assert_no_difference -> { @user.nodes.count } do
        unpack(name: long, dirs: [])
      end
      assert_response :unprocessable_entity
    end

    test "a subfolder with a bad segment is left out, so its files fall back to the root" do
      body = unpack(name: "kit", dirs: [ "ok", "../escape", ".hidden/x" ])

      assert_response :created
      assert_equal [ "", "ok" ], body["folder_map"].keys.sort
    end

    # NO LEADING DOT, so only the per-segment leaf_ok? stands between these and a mkdir:
    # `__MACOSX` is reserved (Library::OsClutter), `a\b` fails valid_leaf_name?.
    test "a subfolder segment that is reserved or invalid is left out, with nothing made for it" do
      body = unpack(name: "kit", dirs: [ "ok", "__MACOSX/x", "a\\b/c" ])

      assert_response :created
      assert_equal [ "", "ok" ], body["folder_map"].keys.sort
      assert_equal [ "ok" ], @user.nodes.present.where(parent_node_id: body["folder_node_id"]).pluck(:name)
      assert_equal [ "ok" ], @root.join("kit").children.map { |c| c.basename.to_s }
    end

    test "another user's folder is a 404 and makes nothing" do
      other = User.create!(email: "unpack-other-#{SecureRandom.hex(4)}@example.com",
                           password: WEB_PASSWORD, confirmed_at: Time.current)
      theirs = FileLayer.current.mkdir(other, parent_node_id: nil, name: "theirs")

      assert_no_difference -> { @user.nodes.count } do
        unpack(parent_node_id: theirs.node_id, name: "x", dirs: [])
      end
      assert_response :not_found
    end

    test "finish nudges the model catalog for this user" do
      cad = mkdir("cad")

      assert_enqueued_with(job: Maker::ModelIntakeJob, args: [ { user_id: @user.id } ]) do
        post files_unpacked_path(format: :json), params: { folder_node_id: cad.node_id }.to_json,
                                                 headers: { "CONTENT_TYPE" => "application/json" }
      end
      assert_response :accepted
    end

    test "finish on a folder that is not this user's is a 404 and enqueues nothing" do
      other = User.create!(email: "unpack-other-#{SecureRandom.hex(4)}@example.com",
                           password: WEB_PASSWORD, confirmed_at: Time.current)
      theirs = FileLayer.current.mkdir(other, parent_node_id: nil, name: "theirs")

      assert_no_enqueued_jobs(only: Maker::ModelIntakeJob) do
        post files_unpacked_path(format: :json), params: { folder_node_id: theirs.node_id }.to_json,
                                                 headers: { "CONTENT_TYPE" => "application/json" }
      end
      assert_response :not_found
    end
  end
end
