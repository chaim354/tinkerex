require "test_helper"

module Web
  # THE SEAM BETWEEN THE TWO HALVES OF THE BRANCH: a model zip unpacked at a project's own folder
  # (Files::UnpacksController) must come out the other end as a card on that project's Models panel
  # (Maker::ProjectModels). Each half has its own tests; what neither can see alone is that the
  # folder the unpack makes is one the catalog reads — Maker::ModelIntake::SHELVES' `Projects/*/models`
  # — so the swept model is placed in the project by Maker::ModelProjects. The browser's part (JSZip,
  # the per-entry uploads) is test/system/topbar_zip_upload_test.rb's; here the one entry goes up
  # through the same per-file door, POST /files.
  #
  # PINNED TO A FRESH SHARE LIBRARY for files_unpack_test.rb's reason: real folders and a real
  # upload through the port, where only share writes on every leg without a stub bucket or a
  # per-email sync library.
  #
  # MUTATION-CHECKED: #destination creating `other` instead of `models` goes RED at the panel
  # assertion — `Projects/stargate/other/iris/` is under no shelf but `*`'s `Projects`, whose child
  # is the project's own (claimed) folder, so no model is made at all.
  class UnpackToModelsPanelTest < ActionDispatch::IntegrationTest
    setup do
      @root = use_fresh_share_library!
      @user = sign_in_web!(User.create!(email: "unpack-panel-#{SecureRandom.hex(4)}@example.com",
                                        password: WEB_PASSWORD, confirmed_at: Time.current))
    end

    test "a zip unpacked at a project's folder becomes a model card on its Models panel" do
      project = @user.maker_projects.create!(name: "Stargate")
      projects = FileLayer.current.mkdir(@user, parent_node_id: nil, name: "Projects")
      folder = FileLayer.current.mkdir(@user, parent_node_id: projects.node_id, name: "stargate")
      project.update_column(:folder_node_id, folder.node_id)

      post files_unpack_folder_path(format: :json),
           params: { parent_node_id: folder.node_id, name: "iris", dirs: [] }.to_json,
           headers: { "CONTENT_TYPE" => "application/json" }
      assert_response :created
      unpacked = JSON.parse(response.body).fetch("folder_node_id")
      port_upload("gate.stl", "solid gate\nendsolid gate\n", parent_node_id: unpacked)

      Maker::ModelIntake.for_user(user: @user)
      panel = Maker::ProjectModels.for(@user, project, attached_node_ids: [])

      assert_equal [ "iris" ], panel.models.map(&:title)
      assert_equal unpacked, panel.models.first.folder_node_id
      assert_empty panel.linked_ids, "in the folder, so no Detach"
    end
  end
end
