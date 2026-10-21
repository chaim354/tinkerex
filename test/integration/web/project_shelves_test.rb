require "test_helper"

module Web
  # A SHELF ON A PROJECT PAGE (2026-10-20; spec Part 3, 3c and 3d). The folder named like a shelf
  # opens in that shelf's default view unless the maker chose one on this project, and a group's
  # folder panels sit together under one full-width heading.
  #
  # PORT-FREE: every row is a bare `nodes.create!` under `project_folder_rows!`, so this reads the
  # same on share, s3 and chunk_remote. Each folder holds one file so its panel draws its view
  # rather than the quiet "Empty folder." line.
  class ProjectShelvesTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "ps-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
      @project = @user.maker_projects.create!(name: "Rig")
      folder = project_folder_rows!(@user, @project)
      # DISK ORDER IS cnc, docs, laser. The grouped arrangement reads docs, cnc, laser, so the
      # order assertions below differ from what an ungrouped page would show.
      %w[cnc docs laser].each do |name|
        @user.nodes.create!(node_id: "d-#{name}", name:, kind: "dir", parent_node_id: folder.node_id)
        @user.nodes.create!(node_id: "f-#{name}", name: "#{name}.txt", kind: "file", parent_node_id: "d-#{name}",
                            size: 10, mtime: 1_000_000_000)
      end
      @group = @user.maker_shelf_groups.create!(name: "Fabrication", position: 0)
      @user.maker_shelves.create!(name: "laser", shelf_group: @group)
      @user.maker_shelves.create!(name: "cnc", shelf_group: @group)
      @user.maker_shelves.create!(name: "docs")
    end

    def folder_key(node_id) = Maker::ProjectKind.folder_key(node_id)

    # One grid's children, in order: a heading reads `head:<text>`, a folder panel its folder's
    # name, anything else its section's id — so the sibling order is what the assertion compares.
    def sequence(grid)
      grid.element_children.map do |child|
        if child.matches?(".shelf-group-head") then "head:#{child.text.strip}"
        elsif (section = child.at_css("section.folder-panel")) then section.at_css(".panel-head h2").text.strip
        else child.at_css("section")&.[]("id") || child.name
        end
      end
    end

    test "a group's folder panels sit under one heading" do
      get project_path(@project)

      assert_response :success
      heads = css_select(".project-panels > .shelf-group-head").map { |h| h.text.strip }
      assert_equal [ "Fabrication" ], heads
      grids = css_select(".project-panels")
      assert_equal 1, grids.size, "no tab, so the no-tabs branch's one grid"
      seq = sequence(grids.first)
      at = seq.index("head:Fabrication")
      assert_equal %w[cnc laser], seq[at + 1, 2], "the heading is immediately followed by the group's two panels"
      assert_operator seq.index("docs"), :<, at, "an ungrouped folder reads before the group"
    end

    test "no heading when no shelf is grouped" do
      @group.destroy! # nullifies: its shelves stay, ungrouped

      get project_path(@project)

      assert_select ".shelf-group-head", count: 0
      assert_select "section.folder-panel", 3, "the folder panels themselves still render"
    end

    test "a shelf's default view is the folder panel's view" do
      @user.maker_shelves.find_by!(name: "docs").update!(default_view: "list")

      get project_path(@project)

      # THE LIST VIEW IS projects/_file_rows' table; tiles is `.attachments-grid`. Both halves, so a
      # panel that drew both, or neither, cannot pass.
      assert_select "section.folder-panel[id=?]", folder_key("d-docs") do
        assert_select "table.project-files", 1
        assert_select ".attachments-grid", 0
        assert_select ".view-toggle button.toggle.active", text: "List"
      end
      assert_select "section.folder-panel[id=?] .attachments-grid", folder_key("d-laser"), 1,
                    "a shelf with no default view keeps the automatic tiles"
    end

    test "a view chosen on the project outranks the shelf's default" do
      @user.maker_shelves.find_by!(name: "docs").update!(default_view: "list")
      @project.update!(panels: { "views" => { folder_key("d-docs") => "tiles" } })

      get project_path(@project)

      assert_select "section.folder-panel[id=?] .attachments-grid", folder_key("d-docs"), 1
      assert_select "section.folder-panel[id=?] table.project-files", folder_key("d-docs"), 0
    end

    # THE TABS BRANCH DRAWS THE HEADING INSIDE THE PANE'S OWN GRID: each grid is a separate run, so
    # a group is headed where its panels are, and the top grid (docs alone) has none.
    test "a group inside a tab is headed inside that tab's grid" do
      tab = "tab:#{'a' * 12}"
      @project.update!(panels: { "order" => [ "attachments", folder_key("d-docs"), tab,
                                              folder_key("d-cnc"), folder_key("d-laser") ],
                                 "titles" => { tab => "Fab" } })

      get project_path(@project)

      assert_select ".shelf-group-head", 1
      grid = css_select(".tab-pane .project-panels").first
      assert_equal [ "head:Fabrication", "cnc", "laser" ], sequence(grid).first(3)
    end

    # THE VISITOR'S PAGE DRAWS THEM TOO, through the same projects/_panel_groups partial and the
    # OWNER's shelves (Maker::PublicProject builds its listing for the owner).
    test "the public page heads the group the same way" do
      @user.update!(handle: "ps-#{SecureRandom.hex(4)}")
      @project.update!(visibility: "public")

      get public_project_path(@user.handle, @project.slug)

      assert_response :success
      assert_equal [ "Fabrication" ], css_select(".project-panels > .shelf-group-head").map { |h| h.text.strip }
      seq = sequence(css_select(".project-panels").first)
      at = seq.index("head:Fabrication")
      assert_equal %w[cnc laser], seq[at + 1, 2]
      assert_operator seq.index("docs"), :<, at
    end
  end
end
