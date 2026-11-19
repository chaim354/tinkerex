require "test_helper"

module Web
  # THE ONBOARDING WIZARD (2026-11-09; docs/superpowers/specs/2026-11-09-onboarding-wizard-design.md):
  # five steps a person whose account was just made walks once, on a files track or a 3D-models
  # track. Every test runs on all three backend legs. A test that MAKES a folder pins a fresh share
  # library (project-intake.md: rows alone hide a broken minting branch); a test that only READS one
  # uses port-free rows (project_folder_rows!).
  class WelcomeTest < ActionDispatch::IntegrationTest
    include ActiveJob::TestHelper

    PASSWORD = "correct horse battery staple".freeze

    setup do
      @prior_demo = ENV["DEMO_ACCOUNT_EMAIL"]
      ENV.delete("DEMO_ACCOUNT_EMAIL")
      @user = User.create!(email: "welcome-#{SecureRandom.hex(4)}@example.com", password: PASSWORD,
                           confirmed_at: Time.current, onboarding_pending: true)
      sign_in_web!(@user, password: PASSWORD)
    end

    teardown { @prior_demo ? ENV["DEMO_ACCOUNT_EMAIL"] = @prior_demo : ENV.delete("DEMO_ACCOUNT_EMAIL") }

    def project_with_rows(name = "Lamp")
      project = @user.maker_projects.create!(name:)
      [ project, project_folder_rows!(@user, project) ]
    end

    def dir_row(name, parent)
      @user.nodes.create!(node_id: SecureRandom.uuid, name:, kind: "dir", parent_node_id: parent.node_id, mtime: 1, size: 0)
    end

    def file_row(name, parent)
      @user.nodes.create!(node_id: SecureRandom.uuid, name:, kind: "file", parent_node_id: parent.node_id, mtime: 1, size: 5)
    end

    # ---------------------------------------------------------------- when it opens

    test "a pending account is sent from Recent to the wizard" do
      get root_path
      assert_redirected_to welcome_path
      follow_redirect!
      assert_select ".page-head h1", "What will you mostly use Tinkerex for?"
      assert_select "a.welcome-choice[href=?]", welcome_tour_path(track: "files")
      assert_select "a.welcome-choice[href=?]", welcome_tour_path(track: "models")
    end

    test "an account that is not pending stays on Recent, and can still open the wizard" do
      @user.update_column(:onboarding_pending, false)
      get root_path
      assert_response :success
      assert_select ".page-head h1", "Recent"
      get welcome_path
      assert_response :success
    end

    test "the demo account is never sent to the wizard" do
      ENV["DEMO_ACCOUNT_EMAIL"] = @user.email
      get root_path
      assert_response :success
      assert_select ".page-head h1", "Recent"
    end

    test "Skip clears the pending state and goes to Recent" do
      post welcome_skip_path
      assert_redirected_to root_path
      assert_not @user.reload.onboarding_pending?
      follow_redirect!
      assert_response :success
    end

    test "Recent's getting-started panel and Help both link to the tour" do
      @user.update_column(:onboarding_pending, false)
      get root_path
      assert_select ".getting-started a[href=?]", welcome_path
      get help_path
      assert_select ".page-head a[href=?]", welcome_path, text: "Take the tour"
    end

    test "the wizard's pages light Recent in the rail" do
      get welcome_path
      assert_select ".rail-link[title=Recent][aria-current=page]"
    end

    # ---------------------------------------------------------------- tour

    test "an unknown track is a 404" do
      get "/welcome/printing/tour"
      assert_response :not_found
    end

    test "each track's tour shows its own cards and leads to its project step" do
      get welcome_tour_path(track: "models")
      assert_select ".welcome-card h2", text: "A 3D viewer that speaks millimetres"
      assert_select ".welcome-card h2", text: "Cut files, measured", count: 0
      assert_select "a.btn.primary[href=?]", welcome_project_path(track: "models")

      get welcome_tour_path(track: "files")
      assert_select ".welcome-card h2", text: "Cut files, measured"
      assert_select ".welcome-card h2", text: "A 3D viewer that speaks millimetres", count: 0
      assert_select "a.btn.primary[href=?]", welcome_project_path(track: "files")
    end

    # ---------------------------------------------------------------- project

    test "the files track asks for a kind, offering every one but 3D printing" do
      get welcome_project_path(track: "files")
      assert_select "form[action=?]", welcome_project_path(track: "files") do
        assert_select "input[name=?]", "project[name]"
        assert_select "textarea[name=?]", "project[description]"
        assert_select "select[name=?] option", "project[kind]", count: Maker::Project::KINDS.size - 1
        assert_select "select[name=?] option[value=print]", "project[kind]", count: 0
      end
    end

    test "the 3D track states its kind and asks for none" do
      get welcome_project_path(track: "models")
      assert_select "select[name=?]", "project[kind]", count: 0
      assert_select ".welcome-kind", text: /3D printing project/
    end

    test "creating a project clears the pending state, makes its folder, and goes to Files" do
      @root = use_fresh_share_library!
      post welcome_project_path(track: "files"),
           params: { project: { name: "Desk Lamp", description: "A lamp.", kind: "laser" } }

      project = @user.maker_projects.find_by!(name: "Desk Lamp")
      assert_redirected_to welcome_files_path(track: "files", project: project.slug)
      assert_equal "laser", project.kind
      assert_not @user.reload.onboarding_pending?
      assert @root.join("Projects", project.slug).directory?
      assert_equal "Created Desk Lamp. Its folder is Projects/desk-lamp.", flash[:notice]
    end

    test "the 3D track saves kind print whatever the form sends" do
      @root = use_fresh_share_library!
      post welcome_project_path(track: "models"), params: { project: { name: "Bracket", kind: "laser" } }
      assert_equal "print", @user.maker_projects.find_by!(name: "Bracket").kind
    end

    test "a blank name re-renders the step with its error and keeps the account pending" do
      assert_no_difference -> { @user.maker_projects.count } do
        post welcome_project_path(track: "files"), params: { project: { name: "" } }
      end
      assert_response :unprocessable_entity
      assert_select ".form-errors"
      assert @user.reload.onboarding_pending?
    end

    # ---------------------------------------------------------------- files and done

    test "files and done are 404 for another user's project or a missing one" do
      other = User.create!(email: "other-#{SecureRandom.hex(4)}@example.com", password: PASSWORD, confirmed_at: Time.current)
      theirs = other.maker_projects.create!(name: "Theirs")
      get welcome_files_path(track: "files", project: theirs.slug)
      assert_response :not_found
      get welcome_done_path(track: "files", project: theirs.slug)
      assert_response :not_found
      get welcome_files_path(track: "files", project: "no-such-project")
      assert_response :not_found
    end

    test "the Files step aims the top bar's Upload at the project folder and makes it the accent" do
      project, = project_with_rows
      get welcome_files_path(track: "models", project: project.slug)
      assert_response :success
      assert_select "header.topbar .topbar-upload-caption", text: "Saves to Projects/lamp"
      assert_select "header.topbar .upload-btn.primary", count: 1
      assert_select ".welcome-files code", text: "models/"
      assert_select "a[href=?]", welcome_done_path(track: "models", project: project.slug), text: "I'll add files later"
    end

    # TWO WIRE SHAPES BEHIND ONE UPLOAD (§14a: port_writable? picks the door). Branched on the
    # capability, never skipped, so all three legs run it: share and s3 render the form's hidden
    # flag, chunk_remote the uploader's redirect value.
    test "the Files step points the top bar's Upload back at Done" do
      project, folder = project_with_rows
      get welcome_files_path(track: "models", project: project.slug)
      done = welcome_done_path(track: "models", project: project.slug)
      if FileLayer.current.capabilities.port_writable?
        assert_select "header.topbar form.uploader" do
          assert_select "input[type=hidden][name=return_to][value=?]", "welcome_models"
          assert_select "input[type=hidden][name=parent_node_id][value=?]", folder.node_id
        end
      else
        assert_select "header.topbar [data-controller=uploader][data-uploader-redirect-url-value=?]", done
        assert_select "header.topbar [data-controller=uploader][data-uploader-parent-node-id-value=?]", folder.node_id
      end
      # Every other page renders neither: Recent, with the account no longer pending so it stays there.
      @user.update_column(:onboarding_pending, false)
      get root_path
      assert_select "input[name=return_to]", count: 0
      assert_select "[data-uploader-redirect-url-value]", count: 0
    end

    test "the files track's Files step names the shelves from the user's own filing rules" do
      project, = project_with_rows
      get welcome_files_path(track: "files", project: project.slug)
      shelves = Maker::FilingRules.for(@user)
      assert_select ".welcome-files code", text: "#{shelves.fetch('svg', Maker::ProjectFolders::OTHER)}/"
      assert_select ".welcome-files code", text: "#{shelves.fetch('lbrn2', Maker::ProjectFolders::OTHER)}/"
    end

    test "with the project's folder gone, the Files step says so and aims Upload nowhere" do
      project, folder = project_with_rows
      folder.update_column(:deleted, true)
      get welcome_files_path(track: "files", project: project.slug)
      assert_select ".welcome-folder-pending"
      assert_select "header.topbar .topbar-upload-caption", text: /Saves to/, count: 0
    end

    test "Done lists what landed by folder, and the 3D track starts the model catalog" do
      project, folder = project_with_rows
      stl = file_row("bracket.stl", dir_row("models", folder))
      readme = file_row("README.md", folder)
      [ stl, readme ].each { |n| project.file_attachments.create!(user: @user, node_id: n.node_id) }

      assert_enqueued_with(job: Maker::ModelIntakeJob, args: [ { user_id: @user.id } ]) do
        get welcome_done_path(track: "models", project: project.slug)
      end
      assert_select ".page-head h1", "Lamp is ready"
      assert_select ".welcome-landed h3", text: "Project folder"
      assert_select ".welcome-landed h3", text: "models/"
      assert_select ".welcome-landed .grid-name", text: "bracket.stl"
      assert_select "a.btn.primary[href=?]", project_path(project), text: "Open Lamp"
      assert_select "a[href=?]", files_models_path, text: "Go to 3D models"
    end

    test "the files track's Done starts no catalog run and links to the project's folder" do
      project, folder = project_with_rows
      assert_no_enqueued_jobs(only: Maker::ModelIntakeJob) do
        get welcome_done_path(track: "files", project: project.slug)
      end
      assert_select ".welcome-empty", text: %r{Projects/lamp}
      assert_select "a[href=?]", files_path(folder: folder.node_id), text: "Go to Library"
    end
  end
end
