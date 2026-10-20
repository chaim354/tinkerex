require "test_helper"

module Web
  # Recent, the app's front door at `/` (structural redesign §7, slice 6; the Home page until then):
  # the files you changed lately, your active projects, and what needs attention — the last two only
  # when they hold anything. Every section from columns that already exist, every list bounded.
  class HomeTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "home-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
    end

    def file(name, at:, parent: nil)
      @user.nodes.create!(node_id: "n-#{name}", name:, kind: "file", mtime: 1_000_000_000, size: 5,
                          updated_at: at, parent_node_id: parent)
    end

    # ONE EMPTY STATE, AND IT POINTS AT THE TOP BAR. Since F onboarding (2026-10-13) it is the
    # getting-started panel, in place of a Recently changed panel with nothing in it; what it says
    # per backend is where_files_come_from_test.rb's. Active projects and Needs attention are absent
    # rather than empty, and the panel does not grow an upload control of its own — a second one
    # would duplicate the top bar's input id and spend the accent twice.
    test "an empty account sees one empty state, pointing at the top bar's Upload" do
      get root_path
      assert_response :success
      assert_select ".page-head h1", text: "Recent"
      # The head is the heading alone: New ▾ in the top bar already has Project.
      assert_select ".page-head > *", count: 1
      assert_select "main a[href=?]", new_project_path, count: 0
      assert_select ".home-section.getting-started .file-sources", text: /Upload, in the top bar/
      assert_select ".home-section", count: 1
      assert_select ".home-files", count: 0
      assert_select ".home-projects", count: 0
      assert_select ".home-attention", count: 0
      assert_select ".home-prints", count: 0
      assert_select "main .uploader", count: 0
      assert_select "#topbar_upload_file", count: 1
    end

    # THE LITERAL 16 IS THE SPEC'S NUMBER (§7), asserted as a literal on purpose: `count:
    # HomeController::RECENT_FILES` would follow the constant wherever it went and could never fail.
    # Seventeen files so the cap is reached with one to spare, and the spare is the OLDEST, so a
    # wrong order would show as well as a wrong limit.
    test "the recent lists are bounded and newest first" do
      7.times { |i| @user.maker_projects.create!(name: "Project #{i}", updated_at: i.hours.ago) }
      17.times { |i| file("part-#{i}.stl", at: i.hours.ago) }
      get root_path
      assert_select ".home-projects .recent-grid .project-tile", count: HomeController::RECENT_PROJECTS
      names = css_select(".home-projects .recent-grid .project-name").map(&:text)
      assert_equal "Project 0", names.first
      assert_select ".home-files .recent-grid .grid-card", count: 16
      assert_equal "part-0.stl", css_select(".home-files .recent-grid .grid-card .grid-name").first.text
      assert_select ".home-files .grid-name", text: "part-16.stl", count: 0
      assert_select ".home-projects .panel-head a[href=?]", projects_path, text: "All projects"
      assert_select ".home-files .panel-head a[href=?]", files_path, text: "Library"
    end

    # A TILE OPENS ITS FOLDER IN THE LIBRARY WITH THE FILE SELECTED (§7), where the inspector says
    # what it is and its Open reaches the file page — never the file page directly. A root file has
    # no folder, and the link says so by carrying `selected` alone. A link, never a selection item:
    # this page has no selection controller to answer one.
    test "a tile opens its folder in the Library with the file selected" do
      @user.nodes.create!(node_id: "d-jigs", name: "jigs", kind: "dir", mtime: 1, size: 0)
      nested = file("plate.dxf", at: 1.hour.ago, parent: "d-jigs")
      root = file("notes.txt", at: 2.hours.ago)
      get root_path
      assert_select ".home-files .recent-grid a.grid-card[href=?]",
                    files_path(folder: "d-jigs", selected: nested.node_id), text: /plate\.dxf/
      assert_select ".home-files .recent-grid a.grid-card[href=?]", files_path(selected: root.node_id), text: /notes\.txt/
      assert_select ".home-files a[href=?]", file_path(nested.node_id), count: 0
      assert_select ".home-files [data-selection-target]", count: 0
    end

    # The same partial, so Recent gets discovery's feedback for free — and this is what it gets from
    # S4-6 instead of an adopt door (there is no folder on this page to adopt).
    test "Recent badges an auto-created project the owner has not opened" do
      project = @user.maker_projects.create!(name: "Tray")
      project.update_columns(discovered_at: 1.hour.ago)

      get root_path

      assert_select ".home-projects .project-tile .badge.project-new", text: "New"
    end

    # Recent has no prints section (slice 6); a failed print is the one kind that still reaches it,
    # through Needs attention. The successful run beside it is what proves the section is gone rather
    # than merely filtered: it would have been a row there.
    test "a failed print lands in attention with its model, and no prints section renders" do
      node = file("benchy.stl", at: 1.day.ago)
      model = @user.maker_models.create!(title: "Benchy", print_status: "failed")
      model.file_attachments.create!(user: @user, node_id: node.node_id, role: "model")
      model.print_runs.create!(user: @user, printed_on: 2.days.ago.to_date, outcome: "failed", printer: "MK4")
      model.print_runs.create!(user: @user, printed_on: 3.days.ago.to_date, outcome: "success")
      get root_path
      assert_select ".home-prints", count: 0
      assert_select ".home-attention .attention-list .attention-row", count: 1
      assert_select ".home-attention .attention-row", text: /Benchy/
      assert_select ".home-attention .attention-row", text: /failed/i
      assert_select ".home-attention .attention-row a.btn[href=?]", model_path(model), text: "Log a print"
    end

    # The live project is what makes this assertion able to fail: with the archived one alone, the
    # section is absent and "Old Rig is not in it" would hold over nothing.
    test "an archived project is not recent" do
      @user.maker_projects.create!(name: "Live Rig")
      project = @user.maker_projects.create!(name: "Old Rig")
      project.archive!
      get root_path
      assert_select ".home-projects .project-name", text: "Live Rig"
      assert_select ".home-projects .project-name", text: "Old Rig", count: 0
    end

    # "Active projects" leaves a finished one out, as it does an archived one (slice 6 review).
    test "a done project is not an active project" do
      @user.maker_projects.create!(name: "Live Rig")
      @user.maker_projects.create!(name: "Built Rig", status: "done")
      get root_path
      assert_select ".home-projects .project-name", text: "Live Rig"
      assert_select ".home-projects .project-name", text: "Built Rig", count: 0
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
