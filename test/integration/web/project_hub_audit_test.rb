require "test_helper"

module Web
  # THE PROJECT HUB AFTER THE 2026-11-01 UX AUDIT (docs/superpowers/audits/2026-11-01-ux-ui-audit.md,
  # section C), one test per finding that a rendered page can show. Each guard that FORBIDS
  # something was watched to fail by breaking the code it guards (§15); the mutation and its red
  # output are recorded at the test.
  #
  # A FRESH SHARE LIBRARY PER TEST, pinned before any fixture: the README tests write real bytes
  # and the port reads them back, which only a share holds in this process on every CI leg.
  class ProjectHubAuditTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @root = use_fresh_share_library!
      @user = User.create!(email: "hub-#{SecureRandom.hex(4)}@example.com", password: PASSWORD,
                           confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
    end

    teardown { FileLayer.reset! }

    def laser_project!(**attrs)
      @user.maker_projects.create!(name: "Catan", kind: "laser", **attrs)
    end

    def seed_hidden_rows!(project)
      bom = project.boms.create!(user: @user)
      3.times { |i| bom.lines.create!(user: @user, part_name: "part #{i}", quantity: 1, unit: "each", position: i) }
      project.releases.create!(user: @user, version: "v1.0", published_at: Time.current)
      project.sheets.create!(user: @user, name: "Cut list", position: 0, data: Maker::Sheet.blank_data)
    end

    # --- C1: what the preset hides is findable --------------------------------------------------

    # MUTATION-CHECKED: `<% if hidden_rows.any? %>` -> `<% if false %>` in projects/show reddens
    # this at its first assertion: `Expected at least 1 element matching "p.project-also", found 0.`
    test "a laser project names the BOM, the release and the sheet its preset hides, with a way to each" do
      project = laser_project!
      project_folder_rows!(@user, project)
      seed_hidden_rows!(project)
      sheet = project.sheets.first

      get project_path(project)
      assert_response :success

      assert_select "p.project-also", text: /Also in this project:/ do
        assert_select "a[href=?]", project_bom_path(project), text: "Bill of materials (3 lines)"
        assert_select "a[href=?]", edit_layout_project_path(project, anchor: "project-releases"), text: "1 release"
        assert_select "a[href=?]", sheet_path(sheet), text: "1 sheet"
        assert_select "a", 3
      end
      # The panels themselves stay hidden: this is a way to them, not a second copy of them.
      assert_select "section.bom-panel", 0
      assert_select "section.releases-panel", 0
    end

    # THE STATS LINE COUNTS ONLY WHAT THE PAGE SHOWS (C1/C7): "1 sheet" over a page with no Sheets
    # panel, and "0 of 0 tasks done · 0 log entries" over a page with neither panel. MUTATION-CHECKED:
    # replacing the `panel_on_page?` guard around the sheets span with `true` reddens it: `the sheet
    # is in a hidden panel. Expected /sheet/ to not match "0 files 1 sheet".`
    test "the stats line counts the panels on the page, not the hidden or absent ones" do
      project = laser_project!
      project_folder_rows!(@user, project)
      seed_hidden_rows!(project)

      get project_path(project)

      stats = css_select("p.project-stats").text.squish
      assert_match(/0 files/, stats)
      assert_no_match(/sheet/, stats, "the sheet is in a hidden panel")
      assert_no_match(/task/, stats, "Tasks is absent while empty")
      assert_no_match(/log entr/, stats, "the build log is absent while empty")

      project.tasks.create!(user: @user, title: "Cut the box", status: "done")
      get project_path(project)
      assert_match(/1 of 1 task done/, css_select("p.project-stats").text.squish)
    end

    # A PANEL THE MAKER HID IS THEIR CHOICE, MADE IN THE LAYOUT EDITOR (Maker::ProjectKind
    # .preset_hidden): it is not re-announced, and hiding it keeps costing no query
    # (page_query_budget_test.rb). MUTATION-CHECKED: deleting preset_hidden's `return [] if …`, so
    # it ignores the stored `hidden`, reddens this with `Expected exactly 0 elements matching
    # "p.project-also", found 1.`
    test "a panel the maker hid is not listed, and neither is an empty preset-hidden one" do
      # A LASER project whose maker saved a layout hiding the BOM themselves: the same panel the
      # preset would hide, but answered, so the line is quiet.
      mine = @user.maker_projects.create!(name: "Mine", kind: "laser", panels: { "hidden" => %w[bom] })
      project_folder_rows!(@user, mine)
      mine.boms.create!(user: @user).lines.create!(user: @user, part_name: "x", quantity: 1, unit: "each", position: 0)

      get project_path(mine)
      assert_select "p.project-also", 0

      empty = @user.maker_projects.create!(name: "Empty Laser", kind: "laser")
      project_folder_rows!(@user, empty)
      get project_path(empty)
      assert_select "p.project-also", 0
    end

    test "the layout editor shows no Also line: it draws every panel itself" do
      project = laser_project!
      project_folder_rows!(@user, project)
      seed_hidden_rows!(project)

      get edit_layout_project_path(project)
      assert_response :success
      assert_select "p.project-also", 0
    end

    # --- C2: README pictures load their bytes ---------------------------------------------------

    # MUTATION-CHECKED: making ProjectsHelper#maker_image_link return nil for every id reddens this
    # with `Expected at least 1 element matching ".readme-panel .markdown img[src=\"/files/<id>/blob\"]`,
    # found 0.`
    test "a README picture loads from the blob route, and its link still opens the file page" do
      project = @user.maker_projects.create!(name: "Desk Lamp")
      project.ensure_library_folder!(@user)
      dir = @root.join("Projects", project.slug)
      FileUtils.mkdir_p(dir.join("docs"))
      FileUtils.mkdir_p(dir.join("models"))
      File.write(dir.join("docs", "plate.svg"), "<svg xmlns='http://www.w3.org/2000/svg'/>")
      File.write(dir.join("models", "base.stl"), "solid base\nendsolid base\n")
      File.write(dir.join("README.md"), "# Lamp\n\n![plate](docs/plate.svg)\n\n[base](models/base.stl)\n")
      Library::ScanJob.new.perform(user_id: @user.id)
      plate = @user.nodes.present.find_by!(name: "plate.svg")
      base = @user.nodes.present.find_by!(name: "base.stl")

      get project_path(project)
      assert_response :success

      assert_select ".readme-panel .markdown img[src=?]", blob_file_path(plate.node_id)
      assert_select ".readme-panel .markdown img[src=?]", file_path(plate.node_id), 0
      assert_select ".readme-panel .markdown a[href=?]", file_path(base.node_id), text: "base"
    end

    # A text block resolves through the same two arms (ProjectsHelper#project_markdown).
    test "a text block's picture loads from the blob route too" do
      project = @user.maker_projects.create!(name: "Desk Lamp")
      folder = project_folder_rows!(@user, project)
      docs = @user.nodes.create!(node_id: SecureRandom.uuid, name: "docs", kind: "dir", parent_node_id: folder.node_id, mtime: 1, size: 0)
      plate = @user.nodes.create!(node_id: SecureRandom.uuid, name: "plate.svg", kind: "file", parent_node_id: docs.node_id, mtime: 1, size: 3)
      project.blocks.create!(user: @user, kind: "text", body: "![plate](docs/plate.svg)")

      get project_path(project)
      assert_select ".block-panel .markdown img[src=?]", blob_file_path(plate.node_id)
    end

    # --- C3: Loose says why a file stays ---------------------------------------------------------

    # MUTATION-CHECKED: making Maker::LooseFilingNotes.for answer {} reddens this at the note:
    # `Expected at least 1 element matching ".attachments-panel .attachment-group .attachment-tile
    # .tile-note", found 0.` — and the caption it replaced comes back promising the next scan for a
    # file that can never be filed.
    test "a loose file whose destination is taken says so on its row, and the caption promises nothing for it" do
      project = @user.maker_projects.create!(name: "Catan")
      folder = project_folder_rows!(@user, project)
      design = @user.nodes.create!(node_id: SecureRandom.uuid, name: Maker::ProjectFolders.folder_for(@user, "x.svg"),
                                   kind: "dir", parent_node_id: folder.node_id, mtime: 1, size: 0)
      @user.nodes.create!(node_id: SecureRandom.uuid, name: "harbor.svg", kind: "file", parent_node_id: design.node_id, mtime: 1, size: 3)
      @user.nodes.create!(node_id: SecureRandom.uuid, name: "harbor.svg", kind: "file", parent_node_id: folder.node_id, mtime: 1, size: 3)

      get project_path(project)

      assert_select ".attachments-panel .attachment-group .attachment-tile .tile-note",
                    text: "#{design.name}/harbor.svg already exists — rename one to file it."
      assert_select ".attachments-panel p.loose-note", 0
      assert_no_match(/sweep/i, css_select(".attachments-panel").text)

      # LIST SAYS THE SAME THING ABOUT THE SAME FILE.
      project.update!(panels: { "views" => { "attachments" => "list" } })
      get project_path(project)
      assert_select ".attachments-panel table.project-files .row-note", text: /already exists — rename one to file it/
    end

    test "a project told not to file says so under Loose instead of promising a scan" do
      project = @user.maker_projects.create!(name: "Quiet", autofile: false)
      folder = project_folder_rows!(@user, project)
      @user.nodes.create!(node_id: SecureRandom.uuid, name: "cut.svg", kind: "file", parent_node_id: folder.node_id, mtime: 1, size: 3)

      get project_path(project)
      assert_select "p.loose-note", text: "Automatic filing is off, so loose files stay where they are."
      assert_select "p.loose-note", text: /next scan/, count: 0
    end

    # --- C8: List keeps a Linked file's controls; build-log photos open ----------------------------

    # MUTATION-CHECKED: deleting the `<% if actions %>` cell from projects/_file_rows reddens this
    # with `Expected at least 1 element matching "table.project-files td.col-actions
    # form[action=\"/attachments/1\"][data-turbo-confirm=…] button.linkbtn.danger.small", found 0.`
    test "a Linked file in List view keeps Detach and Move into project" do
      project = @user.maker_projects.create!(name: "Lamp", panels: { "views" => { "attachments" => "list" } })
      project_folder_rows!(@user, project)
      elsewhere = @user.nodes.create!(node_id: SecureRandom.uuid, name: "bolt.stl", kind: "file", mtime: 1, size: 3)
      att = project.file_attachments.create!(user: @user, node_id: elsewhere.node_id, role: "model")

      get project_path(project)

      assert_select "table.project-files td.col-actions form[action=?][data-turbo-confirm=?] button.linkbtn.danger.small",
                    attachment_path(att), "Detach bolt.stl from Lamp? The file stays in your library.", text: "Detach"
      assert_select "table.project-files td.col-actions form[action=?] button", relocate_project_attachments_path(project),
                    text: "Move into project"
    end

    test "Detach names what it detached" do
      project = @user.maker_projects.create!(name: "Lamp")
      elsewhere = @user.nodes.create!(node_id: SecureRandom.uuid, name: "bolt.stl", kind: "file", mtime: 1, size: 3)
      att = project.file_attachments.create!(user: @user, node_id: elsewhere.node_id, role: "model")

      delete attachment_path(att)
      assert_equal "Detached bolt.stl from Lamp.", flash[:notice]
    end

    test "a build-log photo is a named link to its file" do
      project = @user.maker_projects.create!(name: "Lamp")
      project_folder_rows!(@user, project)
      photo = @user.nodes.create!(node_id: SecureRandom.uuid, name: "glue-up.jpg", kind: "file", mtime: 1, size: 3)
      entry = project.build_log_entries.create!(user: @user, body: "Glued the base.")
      entry.file_attachments.create!(user: @user, node_id: photo.node_id, role: "image")

      get project_path(project)
      assert_select ".log-entry a.entry-photo.file-cell[href=?][aria-label=?]", file_path(photo.node_id), "glue-up.jpg"
      assert_select ".log-entry span.entry-photo", 0
      assert_select ".log-entry form[data-turbo-confirm=?]", "Delete the entry “Glued the base.”?"
    end

    # --- C9: the two pickers ------------------------------------------------------------------

    # MUTATION-CHECKED, twice: forcing Maker::AttachPicker's `moves` to false reddens the first
    # button assertion (`Expected: "Attach and move into Lamp"  Actual: "Attach"`), and dropping its
    # `!elsewhere.include?` term reddens the claimed row (`another project claims it. Expected:
    # "Attach"  Actual: "Attach and move into Lamp"`).
    test "the attach picker shows each file's folder and says when Attach moves it" do
      project = @user.maker_projects.create!(name: "Lamp")
      folder = project_folder_rows!(@user, project)
      parts = @user.nodes.create!(node_id: SecureRandom.uuid, name: "parts", kind: "dir", mtime: 1, size: 0)
      loose = @user.nodes.create!(node_id: SecureRandom.uuid, name: "tetra.stl", kind: "file", parent_node_id: parts.node_id, mtime: 1, size: 3)
      inside = @user.nodes.create!(node_id: SecureRandom.uuid, name: "tetra.stl", kind: "file", parent_node_id: folder.node_id, mtime: 1, size: 3)
      other = @user.maker_projects.create!(name: "Other")
      claimed = @user.nodes.create!(node_id: SecureRandom.uuid, name: "claimed.stl", kind: "file", parent_node_id: parts.node_id, mtime: 1, size: 3)
      other.file_attachments.create!(user: @user, node_id: claimed.node_id, role: "model")

      get new_project_attachment_path(project)
      assert_response :success

      assert_select ".breadcrumb a[href=?]", project_path(project)
      assert_select "a", text: /Back to project/, count: 0
      assert_select "label.picker-label[for=picker-q]", text: "Search your library by name"
      rows = css_select(".picker-result").to_h { |r| [ r.at_css("form")["action"] + r.at_css("input[name=node_id]")["value"], r ] }
      key = ->(node) { project_attachments_path(project) + node.node_id }
      assert_equal "parts", rows.fetch(key.(loose)).at_css(".picker-folder").text.strip
      assert_equal "Attach and move into Lamp", rows.fetch(key.(loose)).at_css("button").text.strip
      assert_equal "Attach", rows.fetch(key.(inside)).at_css("button").text.strip, "already in the folder"
      assert_equal "Attach", rows.fetch(key.(claimed)).at_css("button").text.strip, "another project claims it"
      assert rows.fetch(key.(loose)).at_css(".picker-thumb[data-thumbs-target=cell]"), "no thumbnail cell"
    end

    test "the model picker shows each model's formats and folder, under crumbs" do
      project = @user.maker_projects.create!(name: "Lamp")
      shelf = @user.nodes.create!(node_id: SecureRandom.uuid, name: "prints", kind: "dir", mtime: 1, size: 0)
      mesh = @user.nodes.create!(node_id: SecureRandom.uuid, name: "tetra.stl", kind: "file", parent_node_id: shelf.node_id, mtime: 1, size: 3)
      model = @user.maker_models.create!(title: "tetra")
      model.file_attachments.create!(user: @user, node_id: mesh.node_id, role: "model")

      get new_project_model_path(project)
      assert_response :success
      assert_select ".breadcrumb a[href=?]", project_path(project)
      assert_select "label.picker-label[for=picker-q]"
      assert_select ".picker-result .picker-folder", text: /STL.*prints/
    end

    # --- C10 / §I: state and names a screen reader can read ---------------------------------------

    # MUTATION-CHECKED: dropping `"aria-pressed":` from projects/_attachments' toggle reddens this
    # with `Expected exactly 1 element matching ".attachments-panel .view-toggle
    # button[aria-pressed=true]", found 0.`
    test "the view toggles expose aria-pressed, and Schematics has a panel head" do
      project = @user.maker_projects.create!(name: "Lamp")
      folder = project_folder_rows!(@user, project)
      @user.nodes.create!(node_id: SecureRandom.uuid, name: "board.kicad_pcb", kind: "file", parent_node_id: folder.node_id, mtime: 1, size: 3)

      get project_path(project)
      assert_select ".attachments-panel .view-toggle button[aria-pressed=true]", { count: 1, text: "Tiles" }
      assert_select ".attachments-panel .view-toggle button[aria-pressed=false]", { count: 1, text: "List" }
      assert_select ".schematics-panel > .panel-head > h2", text: "Schematics"
    end

    test "sort by status follows the lifecycle, and the tag row's All reads All tags" do
      { "Zed" => "planning", "Yak" => "done", "Xen" => "active", "Wok" => "paused" }
        .each { |name, status| @user.maker_projects.create!(name:, status:, tag_list: "box") }

      get projects_path(sort: "status")
      names = css_select(".project-tile .project-name").map { |e| e.text.strip }
      assert_equal %w[Zed Xen Wok Yak], names, "planning, active, paused, done"
      assert_select ".chips a.chip", text: "All tags"
      assert_select ".chips a.chip", text: "All", count: 0
    end

    test "the sheets composer has a labelled field and names its submit; a rename says so" do
      project = @user.maker_projects.create!(name: "Lamp")
      get project_path(project, add: "sheets")
      assert_select ".sheets-panel .panel-head > details.composer.sheet-add > summary", text: "Add…"
      assert_select ".sheets-panel details.composer label.field input[name=?]", "sheet[name]"
      assert_select ".sheets-panel details.composer input[type=submit][value=?]", "Add sheet"
      assert_select ".sheets-panel input[placeholder]", 0

      post project_sheets_path(project), params: { sheet: { name: "Cut list" } }
      sheet = project.sheets.last
      assert_equal "Added the sheet “Cut list”.", flash[:notice]
      patch sheet_path(sheet), params: { sheet: { name: "Cuts" } }
      assert_equal "Renamed the sheet to “Cuts”.", flash[:notice]
      delete sheet_path(sheet)
      assert_equal "Deleted the sheet “Cuts”.", flash[:notice]
    end

    # THE REFUSAL PAGE IS SWEPT HERE, because template_hygiene_test.rb sweeps GETs and only a
    # refused POST renders projects/composer_page (Projects::ComposerRefusal, the no-JS answer). Its
    # body must carry neither ERB delimiter nor a section mark, the checks that test makes of every
    # page — one refusal per composer that can land there.
    test "a refused composer page leaks no template comment" do
      project = @user.maker_projects.create!(name: "Lamp")
      project_folder_rows!(@user, project)
      refusals = {
        "wiring" => -> { post project_connections_path(project), params: { connection: { from_label: "A", to_label: "" } } },
        "bom" => -> { post project_bom_lines_path(project), params: { bom_line: { target_kind: "text", part_name: "", quantity: "1", unit: "each" } } },
        "releases" => -> { post project_releases_path(project), params: { release: { version: "" } } },
        "readme" => -> { patch project_readme_path(project), params: { content: "  " } }
      }
      refusals.each do |name, refuse|
        refuse.call
        assert_response :unprocessable_entity, "#{name} did not refuse"
        assert_select ".composer-page details.composer[open]", 1
        %w[<% %> §14 §15].each do |leak|
          assert_not_includes response.body, leak, "the #{name} refusal page rendered #{leak.inspect}"
        end
      end
    end

    # THE COMPOSERS SPEND NO ACCENT (C4): the hub's one is the top bar's Upload. Read across every
    # composer an ?add= can open, so a seventh composer with a `primary` submit goes red here.
    # MUTATION-CHECKED: `primary` back on the BOM's "Add line" reddens it: `?add=bom's composer
    # spends the accent. Expected: 0  Actual: 1`.
    test "no panel composer carries the accent" do
      project = @user.maker_projects.create!(name: "Lamp")
      ProjectsController::ON_DEMAND.each do |key|
        get project_path(project, add: key)
        assert_select "details.composer .primary", 0, "?add=#{key}'s composer spends the accent"
      end
    end
  end
end
