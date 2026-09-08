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
      get root_path
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
      # THE HERO'S FILE COUNT IS THE FOLDER'S (Maker::ProjectFolderListing#total, the same thing
      # projects#show's own stats line reads) — one file placed straight in the project's folder.
      folder = project_folder_rows!(@user, project)
      @user.nodes.create!(node_id: "n-hero-file", name: "bracket.stl", kind: "file",
                          parent_node_id: folder.node_id, mtime: 1_000_000_000, size: 5)
      patch current_project_path, params: { project_id: project.id }
      get root_path
      assert_select ".home-hero h2 a[href=?]", project_path(project), text: "Desk Lamp"
      assert_select ".home-hero .project-stats", text: /1 file\b/
      assert_select ".home-hero .project-stats", text: /1 of 2 tasks done/
      assert_select ".home-hero .hero-tasks .task-row .task-state--todo", count: 1
      assert_select ".home-hero .hero-tasks", text: /Wire the LED/
      assert_select ".home-hero .hero-tasks", text: /Print the base/, count: 0
      assert_select ".home-hero .hero-entry", text: /Shade printed/
      assert_select ".home-hero .upload-btn"
      # One redirect, two wire shapes (projects/_upload_control): the share/s3 multipart form carries
      # it as a hidden field, the chunk_remote presigned flow as the uploader controller's value —
      # so this assertion branches on the backend the leg runs under, as files_toolbar_test does.
      if FileLayer.current.capabilities.port_writable?
        assert_select ".home-hero input[type='hidden'][name='redirect_url'][value=?]", root_path
      else
        assert_select ".home-hero [data-uploader-redirect-url-value=?]", root_path
      end
    end

    # THE COUNT IS THE FOLDER'S, NOT maker_file_attachments'. An attachment to a node OUTSIDE the
    # project's folder (the Linked case) must not inflate the hero the way it no longer inflates
    # the project page's own stats line — HomeController#index and ProjectsController#show read
    # the identical Maker::ProjectFolderListing#total.
    test "an attachment to a node outside the folder does not count toward the hero's files" do
      project = @user.maker_projects.create!(name: "Desk Lamp")
      @user.nodes.create!(node_id: "n-root", name: "loose.stl", kind: "file",
                          mtime: 1_000_000_000, size: 5)
      project.file_attachments.create!(user: @user, node_id: "n-root", role: "model")
      patch current_project_path, params: { project_id: project.id }
      get root_path
      assert_select ".home-hero .project-stats", text: /0 files/
    end

    test "the recent rows are bounded and newest first" do
      7.times { |i| @user.maker_projects.create!(name: "Project #{i}", updated_at: i.hours.ago) }
      9.times { |i| file("part-#{i}.stl", at: i.hours.ago) }
      get root_path
      assert_select ".home-projects .tile-row .project-tile", count: HomeController::RECENT_PROJECTS
      names = css_select(".home-projects .tile-row .project-name").map(&:text)
      assert_equal "Project 0", names.first
      assert_select ".home-files .tile-row .grid-card", count: HomeController::RECENT_FILES
      assert_select ".home-files .tile-row .grid-card .grid-name", text: "part-0.stl"
      assert_select ".home-projects a[href=?]", projects_path, text: "See all"
      assert_select ".home-files a[href=?]", files_path, text: "See all"
    end

    # The same partial, so Home gets discovery's feedback for free — and this is what Home gets
    # from S4-6 instead of an adopt door (there is no folder on this page to adopt).
    test "Home badges an auto-created project the owner has not opened" do
      project = @user.maker_projects.create!(name: "Tray")
      project.update_columns(discovered_at: 1.hour.ago)

      get root_path

      assert_select ".home-projects .project-tile .badge.project-new", text: "New"
    end

    test "recent and failed prints show with their model, and a failed one lands in attention" do
      node = file("benchy.stl", at: 1.day.ago)
      model = @user.maker_models.create!(title: "Benchy", print_status: "failed")
      model.file_attachments.create!(user: @user, node_id: node.node_id, role: "model")
      model.print_runs.create!(user: @user, printed_on: 2.days.ago.to_date, outcome: "failed", printer: "MK4")
      model.print_runs.create!(user: @user, printed_on: 3.days.ago.to_date, outcome: "success")
      get root_path
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
      get root_path
      assert_select ".home-hero", text: /No current project/
      assert_select ".home-projects .project-name", text: "Old Rig", count: 0
    end

    # Stage 2, S2-3: a second attention source alongside failed prints.
    test "low-stock items land in attention, and a well-stocked item does not" do
      low = @user.maker_inventory_items.create!(name: "M3×8 screw", unit: "each", min_quantity: 50)
      Maker::InventoryTransaction.apply!(item: low, user: @user, delta: 12, reason: "initial")
      # THE NEGATIVE CASE IS WHAT PINS THE `low_stock` SCOPE — without it, `@low_stock` is just
      # "the first ATTENTION_STOCK items by name", so a plain read never notices the filter is gone.
      ok = @user.maker_inventory_items.create!(name: "Aardvark bracket", unit: "each", min_quantity: 5)
      Maker::InventoryTransaction.apply!(item: ok, user: @user, delta: 100, reason: "initial")
      get root_path
      assert_select ".home-attention .attention-row.attention-row--warn",
                    text: /M3×8 screw: 12 each left, minimum 50/
      assert_select ".home-attention .attention-row a.btn[href=?]", inventory_item_path(low), text: "Restock"
      assert_select ".home-attention .attention-row", text: /Aardvark bracket/, count: 0
    end

    # THE SCOPE IS `<=`, so an item exactly at its own minimum counts as low — not only one below it.
    test "an item at exactly its minimum counts as low stock" do
      item = @user.maker_inventory_items.create!(name: "At minimum", unit: "each", min_quantity: 50)
      Maker::InventoryTransaction.apply!(item:, user: @user, delta: 50, reason: "initial")
      get root_path
      assert_select ".home-attention .attention-row.attention-row--warn", text: /At minimum/
    end

    test "low stock in attention is bounded at HomeController::ATTENTION_STOCK" do
      (HomeController::ATTENTION_STOCK + 2).times do |i|
        item = @user.maker_inventory_items.create!(name: "Low #{i}", unit: "each", min_quantity: 10)
        Maker::InventoryTransaction.apply!(item:, user: @user, delta: 1, reason: "initial")
      end
      get root_path
      assert_select ".home-attention .attention-row.attention-row--warn", count: HomeController::ATTENTION_STOCK
    end
  end
end
