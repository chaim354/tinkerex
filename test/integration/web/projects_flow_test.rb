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

    test "index lists live projects in one flat list, empty state otherwise" do
      user = sign_in
      get projects_path
      assert_response :success
      assert_select "h1", "Projects"
      assert_select ".projects-empty"

      user.maker_projects.create!(name: "Desk Lamp", status: "active")
      user.maker_projects.create!(name: "Bench Jig", status: "paused")
      user.maker_projects.create!(name: "Old Rig", status: "archived")
      get projects_path

      # One grid, no per-status sections.
      assert_select ".projects-grid", count: 1
      # A non-archived status is no longer a heading and no longer a badge.
      assert_select ".project-card .badge", count: 0
      assert_select ".project-card .project-name", text: "Desk Lamp"
      assert_select ".project-card .project-name", text: "Bench Jig"
      # Archived projects stay out of the default listing.
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
      assert_select "form input[name=?]", "maker_project[name]", count: 0
    end

    test "creating through the actual rendered form params succeeds" do
      sign_in
      # Mirror what the browser sends: exactly the fields the form renders, by name.
      assert_difference "Maker::Project.count", 1 do
        post projects_path, params: { "project" => { "name" => "Via Form", "status" => "planning", "description" => "" } }
      end
    end

    test "creating a project ensures a Projects/<slug> library folder and stores its node_id" do
      user = sign_in
      post projects_path, params: { project: { name: "Desk Lamp", status: "planning" } }
      project = user.maker_projects.order(:created_at).last
      assert project.folder_node_id.present?, "the project's folder node_id must be stored"
      folder = user.nodes.present.find_by!(node_id: project.folder_node_id)
      assert_equal "dir", folder.kind
      assert_equal "desk-lamp", folder.name
      assert_equal "Projects", user.nodes.find_by!(node_id: folder.parent_node_id).name
    end

    test "project create still succeeds if the library backend can't make the folder" do
      user = sign_in
      broken = Object.new
      def broken.capabilities = Object.new.tap { |c| def c.port_writable? = true }
      def broken.mkdir(*) = raise(FileLayer::FetchError, "down")
      FileLayer.current = broken
      assert_difference "Maker::Project.count", 1 do
        post projects_path, params: { project: { name: "Lamp", status: "planning" } }
      end
      assert_nil user.maker_projects.order(:created_at).last.folder_node_id
    ensure
      FileLayer.reset!
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

    test "show renders the project header and description" do
      user = sign_in
      project = user.maker_projects.create!(name: "Desk Lamp", status: "active",
                                            description: "A nice lamp")
      get project_path(project)
      assert_response :success
      assert_select "h1", text: /Desk Lamp/
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

    # --- archived view + unarchive ----------------------------------------------

    test "the archived view lists archived projects and links back" do
      user = sign_in
      user.maker_projects.create!(name: "Desk Lamp", status: "active")
      user.maker_projects.create!(name: "Old Rig", status: "archived")

      get projects_path(archived: 1)
      assert_response :success
      assert_select "h1", "Archived projects"
      assert_select ".project-card .project-name", text: "Old Rig"
      assert_select ".project-card .project-name", text: "Desk Lamp", count: 0
    end

    # The Unarchive button must live INSIDE its own card's container, never as a bare sibling of
    # the card. `.projects-grid` is `display: grid`, and every DIRECT child of a grid container
    # becomes its own independent grid item — a bare sibling button is a SECOND grid item per
    # archived project, so auto-placement has no idea it belongs with the card next to it. With
    # 2+ archived projects the button can visually land next to a different project entirely
    # (most visibly once the grid wraps a row). Text-content assertions like the ones above can't
    # see this; only checking the actual container structure can.
    test "each archived card owns its own unarchive button" do
      user = sign_in
      old_rig = user.maker_projects.create!(name: "Old Rig", status: "archived")
      older_rig = user.maker_projects.create!(name: "Older Rig", status: "archived")

      get projects_path(archived: 1)

      # One grid item per project, each a `.project-tile` — never a bare card or a bare button
      # sitting loose as its own grid item.
      tiles = css_select(".projects-grid > .project-tile")
      assert_equal 2, tiles.size, "expected one .project-tile per archived project"
      assert_select ".projects-grid > form", count: 0
      assert_select ".projects-grid > a.project-card", count: 0

      [ old_rig, older_rig ].each do |project|
        tile = tiles.find { |t| t.at_css(".project-name")&.text&.strip == project.name }
        assert tile, "no .project-tile found for #{project.name}"
        # Scoped to THIS tile: the unarchive form for THIS project must be nested inside the same
        # container as its own card, not merely present somewhere on the page.
        assert_select tile, "form[action=?] button", unarchive_project_path(project), text: "Unarchive"
      end
    end

    test "the default index links to the archived view when there are archived projects" do
      user = sign_in
      user.maker_projects.create!(name: "Old Rig", status: "archived")
      get projects_path
      assert_select ".archived-note a", text: "1 archived project"

      user.maker_projects.create!(name: "Older Rig", status: "archived")
      get projects_path
      assert_select ".archived-note a", text: "2 archived projects"
    end

    # Step 0(b): with nothing archived there is nothing to say, so the note must not render at all.
    test "the archived note is absent when nothing is archived" do
      user = sign_in
      user.maker_projects.create!(name: "Desk Lamp", status: "active")
      get projects_path
      assert_select ".archived-note", count: 0
    end

    # Step 0(a): `.present?` would have made "0" truthy and served the ARCHIVED view here.
    test "archived=0 shows the live list, not the archive" do
      user = sign_in
      user.maker_projects.create!(name: "Desk Lamp", status: "active")
      user.maker_projects.create!(name: "Old Rig", status: "archived")

      get projects_path(archived: 0)
      assert_select "h1", "Projects"
      assert_select ".project-card .project-name", text: "Desk Lamp"
      assert_select ".project-card .project-name", text: "Old Rig", count: 0
    end

    test "unarchive returns a project to the live list" do
      user = sign_in
      project = user.maker_projects.create!(name: "Old Rig", status: "archived",
                                            archived_at: Time.current)

      patch unarchive_project_path(project)
      assert_redirected_to projects_path

      project.reload
      assert_equal "active", project.status
      assert_nil project.archived_at

      get projects_path
      assert_select ".project-card .project-name", text: "Old Rig"
    end

    # `config.action_dispatch.show_exceptions = :rescuable` in the test env, so a RecordNotFound
    # from the current_user scoping arrives as a 404 RESPONSE rather than a raised exception —
    # which is why every cross-user test in this suite asserts the status, not an exception.
    test "unarchive cannot reach another user's project" do
      sign_in("a@example.com")
      other = User.create!(email: "b@example.com", password: PASSWORD, confirmed_at: Time.current)
      theirs = other.maker_projects.create!(name: "Theirs", status: "archived")

      patch unarchive_project_path(theirs)
      assert_response :not_found
      assert_equal "archived", theirs.reload.status
    end

    # --- status badge/select removal --------------------------------------------

    test "the detail page shows no status badge for a live project" do
      user = sign_in
      project = user.maker_projects.create!(name: "Desk Lamp", status: "paused")
      get project_path(project)
      assert_response :success
      assert_select "h1", "Desk Lamp"
      assert_select ".badge.status-archived", count: 0
    end

    test "the detail page badges an archived project" do
      user = sign_in
      project = user.maker_projects.create!(name: "Old Rig", status: "archived")
      get project_path(project)
      assert_select ".badge.status-archived", text: "Archived"
    end

    test "the project form offers no status select" do
      sign_in
      get new_project_path
      assert_response :success
      assert_select "select[name=?]", "project[status]", count: 0
    end
  end
end
