require "test_helper"

module Web
  class ProjectsFlowTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    # Maker data is backend-neutral, but the detail/list views READ file metadata + capabilities
    # through FileLayer.current. Pin a real backend so a `LIBRARY_BACKEND=share` CI leg (which has
    # no LIBRARY_PATH) doesn't fail these on backend construction — they aren't share tests.
    setup do
      pin_file_layer_backend("chunk")
      Storage::ChunkStore.reset!
    end

    def sign_in(email = "maker@example.com")
      user = User.find_by(email:) ||
             User.create!(email:, password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email:, password: PASSWORD } }
      user
    end

    test "requires login" do
      get projects_path
      assert_redirected_to new_user_session_path
    end

    test "index lists the user's projects grouped by status, empty state otherwise" do
      user = sign_in
      get projects_path
      assert_response :success
      assert_select "h1", "Projects"
      assert_select ".projects-empty"

      user.maker_projects.create!(name: "Desk Lamp", status: "active")
      user.maker_projects.create!(name: "Old Rig", status: "archived")
      get projects_path
      assert_select ".project-card .project-name", text: "Desk Lamp"
      # Archived projects are not in the default (non-archived) listing.
      assert_select ".project-card .project-name", text: "Old Rig", count: 0
    end

    test "index shows only the current user's projects" do
      sign_in("a@example.com").maker_projects.create!(name: "Mine")
      other = User.create!(email: "b@example.com", password: PASSWORD, confirmed_at: Time.current)
      other.maker_projects.create!(name: "Theirs")
      get projects_path
      assert_select ".project-name", text: "Mine"
      assert_select ".project-name", text: "Theirs", count: 0
    end

    # --- create ----------------------------------------------------------------

    test "create a project with valid params" do
      sign_in
      get new_project_path
      assert_response :success
      assert_select "form"

      assert_difference "Maker::Project.count", 1 do
        post projects_path, params: { project: { name: "Smart Lamp", status: "active", description: "RGB" } }
      end
      project = Maker::Project.order(:created_at).last
      assert_redirected_to project_path(project)
      assert_equal "smart-lamp", project.slug
      follow_redirect!
      assert_select "h1", text: /Smart Lamp/
    end

    test "the new-project form submits params under the key the controller requires" do
      # Regression: form_with model: @project on a NAMESPACED model (Maker::Project) scopes fields
      # to `maker_project[...]`, but ProjectsController#create does params.require(:project). The
      # rendered form and the controller must agree, or every create/edit through the UI fails.
      # (The other create test POSTs `project:` directly, so it never exercised the real form.)
      sign_in
      get new_project_path
      assert_response :success
      assert_select "form input[name=?]", "project[name]"
      assert_select "form select[name=?]", "project[status]"
      assert_select "form input[name=?]", "maker_project[name]", count: 0
    end

    test "creating through the actual rendered form params succeeds" do
      sign_in
      # Mirror what the browser sends: exactly the fields the form renders, by name.
      assert_difference "Maker::Project.count", 1 do
        post projects_path, params: { "project" => { "name" => "Via Form", "status" => "planning", "description" => "" } }
      end
    end

    test "create with a blank name re-renders the form with an error" do
      sign_in
      assert_no_difference "Maker::Project.count" do
        post projects_path, params: { project: { name: "" } }
      end
      assert_response :unprocessable_entity
      assert_select "form"
    end

    # --- detail + lifecycle ----------------------------------------------------

    test "show renders the project header, status, and description" do
      user = sign_in
      project = user.maker_projects.create!(name: "Desk Lamp", status: "active",
                                            description: "A nice lamp")
      get project_path(project)
      assert_response :success
      assert_select "h1", text: /Desk Lamp/
      assert_select ".project-status", text: /active/i
      assert_select ".project-description", text: /A nice lamp/
    end

    test "show 404s for another user's project" do
      sign_in("a@example.com")
      other = User.create!(email: "b@example.com", password: PASSWORD, confirmed_at: Time.current)
      p = other.maker_projects.create!(name: "Theirs")
      get project_path(p)   # slug-based path; a's scope has no such slug
      assert_response :not_found
    end

    test "edit + update changes fields" do
      user = sign_in
      project = user.maker_projects.create!(name: "Old", status: "planning")
      get edit_project_path(project)
      assert_response :success
      patch project_path(project), params: { project: { name: "New", status: "paused" } }
      project.reload
      assert_equal "New", project.name
      assert_equal "paused", project.status
      assert_redirected_to project_path(project)
    end

    test "destroy archives (soft) rather than deleting" do
      user = sign_in
      project = user.maker_projects.create!(name: "Done Build", status: "active")
      assert_no_difference "Maker::Project.count" do
        delete project_path(project)
      end
      assert_equal "archived", project.reload.status
      assert_redirected_to projects_path
    end

    # --- cover thumbnails ------------------------------------------------------

    test "cover_node_id prefers image, then model, then first attachment, else nil" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      assert_nil project.cover_node_id

      project.file_attachments.create!(user:, node_id: "m1", role: "model", position: 0)
      project.file_attachments.create!(user:, node_id: "i1", role: "image", position: 1)
      assert_equal "i1", project.reload.cover_node_id, "an image cover wins over a model"

      project.file_attachments.destroy_all
      project.file_attachments.create!(user:, node_id: "src", role: "source_archive", position: 0)
      project.file_attachments.create!(user:, node_id: "m2", role: "model", position: 1)
      assert_equal "m2", project.reload.cover_node_id, "a model wins over a non-image/non-model"
    end

    test "a project card shows a cover cell when it has an attachment" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp", status: "active")
      user.nodes.create!(node_id: "c1", name: "cover.png", kind: "file")
      project.file_attachments.create!(user:, node_id: "c1", role: "image")

      get projects_path
      assert_select ".project-card .file-cell[data-node-id=?]", "c1"
    end
  end
end
