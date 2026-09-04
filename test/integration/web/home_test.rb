require "test_helper"

module Web
  # The Home page (stage 2, S2-1): the current project first, then what changed recently, then what
  # needs attention — every section from columns that already exist, every list bounded.
  class HomeTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "home-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
    end

    def file(name, at:)
      @user.nodes.create!(node_id: "n-#{name}", name:, kind: "file", mtime: 1_000_000_000, size: 5, updated_at: at)
    end

    test "an empty account sees every section's empty sentence and a prompt to pick a project" do
      get home_path
      assert_response :success
      assert_select ".page-head h1", text: "Home"
      assert_select ".home-hero", text: /No current project/
      assert_select ".home-section.home-projects .empty", text: /No projects yet/
      assert_select ".home-section.home-files .empty", text: /No files yet/
      assert_select ".home-section.home-prints .empty", text: /No prints logged yet/
      assert_select ".home-section.home-attention .empty", text: /Nothing needs attention/
    end

    test "the hero shows the current project's open tasks and latest entry, and its upload control" do
      project = @user.maker_projects.create!(name: "Desk Lamp", description: "A lamp.")
      project.tasks.create!(user: @user, title: "Wire the LED", status: "todo", position: 0)
      project.tasks.create!(user: @user, title: "Print the base", status: "done", position: 1)
      project.build_log_entries.create!(user: @user, entry_type: "note", logged_at: 1.day.ago, body: "<div>Shade printed.</div>")
      patch current_project_path, params: { project_id: project.id }
      get home_path
      assert_select ".home-hero h2 a[href=?]", project_path(project), text: "Desk Lamp"
      assert_select ".home-hero .project-stats", text: /1 of 2 tasks done/
      assert_select ".home-hero .hero-tasks .task-row .task-state--todo", count: 1
      assert_select ".home-hero .hero-tasks", text: /Wire the LED/
      assert_select ".home-hero .hero-tasks", text: /Print the base/, count: 0
      assert_select ".home-hero .hero-entry", text: /Shade printed/
      assert_select ".home-hero .upload-btn"
      assert_select ".home-hero input[type='hidden'][name='redirect_url'][value=?]", home_path
    end

    test "the recent rows are bounded and newest first" do
      7.times { |i| @user.maker_projects.create!(name: "Project #{i}", updated_at: i.hours.ago) }
      9.times { |i| file("part-#{i}.stl", at: i.hours.ago) }
      get home_path
      assert_select ".home-projects .tile-row .project-tile", count: HomeController::RECENT_PROJECTS
      names = css_select(".home-projects .tile-row .project-name").map(&:text)
      assert_equal "Project 0", names.first
      assert_select ".home-files .tile-row .grid-card", count: HomeController::RECENT_FILES
      assert_select ".home-files .tile-row .grid-card .grid-name", text: "part-0.stl"
      assert_select ".home-projects a[href=?]", projects_path, text: "See all"
      assert_select ".home-files a[href=?]", files_path, text: "See all"
    end

    test "recent and failed prints show with their model, and a failed one lands in attention" do
      node = file("benchy.stl", at: 1.day.ago)
      model = @user.maker_models.create!(title: "Benchy", print_status: "failed")
      model.file_attachments.create!(user: @user, node_id: node.node_id, role: "model")
      model.print_runs.create!(user: @user, printed_on: 2.days.ago.to_date, outcome: "failed", printer: "MK4")
      model.print_runs.create!(user: @user, printed_on: 3.days.ago.to_date, outcome: "success")
      get home_path
      assert_select ".home-prints .print-row", count: 2
      assert_select ".home-prints .print-row a[href=?]", model_path(model), text: "Benchy"
      assert_select ".home-attention .attention-list .attention-row", count: 1
      assert_select ".home-attention .attention-row", text: /Benchy/
      assert_select ".home-attention .attention-row", text: /failed/i
    end

    test "an archived project is neither the hero nor recent" do
      project = @user.maker_projects.create!(name: "Old Rig")
      patch current_project_path, params: { project_id: project.id }
      project.archive!
      get home_path
      assert_select ".home-hero", text: /No current project/
      assert_select ".home-projects .project-name", text: "Old Rig", count: 0
    end
  end
end
