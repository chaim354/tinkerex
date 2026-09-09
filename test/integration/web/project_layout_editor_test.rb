require "test_helper"

module Web
  # THE PAGE EDITOR'S SERVER HALF (2026-09-09; spec §5): the edit page, its three doors and the
  # document write. What the BROWSER does with them — dragging, the drawer, Save — is
  # test/system/page_editor_test.rb; everything here is markup the server writes and the row that
  # comes back.
  class ProjectLayoutEditorTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "editor-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      @project = @user.maker_projects.create!(name: "Desk Lamp")
      @folder = project_folder_rows!(@user, @project)
      @models = dir!("models", @folder.node_id)
      file!("base.stl", @models.node_id)
    end

    def dir!(name, parent) = @user.nodes.create!(node_id: SecureRandom.uuid, name:, kind: "dir", parent_node_id: parent, mtime: 1, size: 0)
    def file!(name, parent) = @user.nodes.create!(node_id: SecureRandom.uuid, name:, kind: "file", parent_node_id: parent, mtime: 1, size: 3)
    def models_key = Maker::ProjectKind.folder_key(@models.node_id)
    def order = @project.panel_layout(folders: [ [ @models.node_id, false ] ]).order

    # --- the edit page ---------------------------------------------------------------------------

    test "the edit page is the project page with the chrome on, one slot per panel, hidden ones included" do
      # BOM, WIRING AND RELEASES ARE HIDDEN TOO, DELIBERATELY: ProjectsController#show SKIPS their
      # loads when they are hidden (page_query_budget_test.rb pins that), so edit mode renders those
      # three partials over @bom = nil and two empty arrays. That is the ghost the loop over `order`
      # promises, and it is the one arm of it a page that hides nothing cannot reach.
      @project.update!(panels: { "hidden" => %w[tasks bom wiring releases] })

      get edit_layout_project_path(@project)

      assert_response :success
      assert_select "div.layout-editor[data-controller=layout-editor]" do
        assert_select "[data-layout-editor-yaml-url-value=?]", yaml_project_layout_path(@project)
        assert_select "[data-layout-editor-parse-url-value=?]", parse_project_layout_path(@project)
        assert_select "[data-layout-editor-panel-url-value=?]", layout_panel_project_path(@project)
        assert_select "div.layout-bar form.layout-save[action=?] input[name=layout]", project_panels_path(@project)
        assert_select "div.project-panels.layout-editing div.panel-slot", order.size
        assert_select "div.panel-slot[data-key=tasks].panel-slot--hidden[data-hidden=true]", 1
        assert_select "div.panel-slot[data-key=publish].panel-slot--pinned", 1
        assert_select "div.panel-slot[data-key=?][data-width=full]", models_key, 1
        assert_select "div.panel-slot[data-key=tasks][data-width=half]", 1
        assert_select "aside.layout-drawer[hidden] textarea[data-layout-editor-target=yaml]", 1
        # THE DRAFT IS READ OFF THESE TARGETS (layout_editor_controller.js): drop one and Save posts
        # an empty document. Pinned here because the markup is this task's output.
        #
        # SCOPED TO THE GRID SINCE CONTENT BLOCKS (2026-09-09): projects/_block_templates renders one
        # complete slot per kind inside a `<template>`, and a template's contents are INERT in a
        # browser (Stimulus sees no target in one) but ordinary elements to Nokogiri — so an
        # unscoped count here reads 3 too many and would have to be written as a sum that says
        # nothing. The grid is what the draft is read off in any case.
        assert_select "div.project-panels div.panel-slot[data-layout-editor-target=slot]", order.size
        assert_select "form.layout-save input[name=layout][data-layout-editor-target=draft]", 1
        assert_select "div.panel-slot[data-key=tasks][data-view]", { count: 0 }, "a panel with no views carries no data-view at all"
        assert_select "div.panel-slot[data-key=attachments][data-view=tiles]", 1
      end
      # THE PAGE INTRO IS EDIT MODE'S ONLY ADDITION ABOVE THE GRID (2026-09-09, content blocks).
      assert_select "div.page-intro[data-layout-editor-target=page]", 1
      assert_select "section.tasks-panel", 1, "a hidden panel is rendered, ghosted, in edit mode"
      assert_select "section.bom-panel", 1, "and one whose data the controller skipped renders too"
      assert_select "section.wiring-panel", 1
      assert_select "section.releases-panel", 1
    end

    test "the strip offers what the panel offers: a view switch for Files and folders only, no eye on always-shown" do
      get edit_layout_project_path(@project)

      assert_select "div.panel-slot[data-key=attachments] .panel-strip" do
        assert_select "button[data-action='layout-editor#view'][data-view=tiles]", 1
        assert_select "button[data-action='layout-editor#view'][data-view=list]", 1
        assert_select "button[data-action='layout-editor#view'][data-view=browser]", count: 0
        assert_select "button[data-action='layout-editor#toggleHidden']", count: 0
        assert_select ".panel-strip-always", 1
      end
      assert_select "div.panel-slot[data-key=?] .panel-strip button[data-view=browser]", models_key, 1
      assert_select "div.panel-slot[data-key=tasks] .panel-strip" do
        assert_select "button[data-action='layout-editor#view']", count: 0
        assert_select "button[data-action='layout-editor#toggleHidden']", 1
        assert_select "button[data-action='layout-editor#width'][data-width=half].active", 1
        assert_select "details.panel-strip-edit input[maxlength=?]", Maker::ProjectKind::TITLE_MAX.to_s
      end
      assert_select "div.panel-slot[data-key=publish] .panel-strip button[data-action='layout-editor#up']", count: 0
      # NO HANDLE ON PUBLISH (spec decision 11): nothing to grab, so the controller's filter is the
      # second lock rather than the only one.
      assert_select "div.panel-slot[data-key=publish] .panel-strip-handle", count: 0
      assert_select "div.panel-slot[data-key=tasks] .panel-strip-handle", 1
    end

    test "a panel that renders nothing gets a placeholder in edit mode and no slot on the page" do
      get edit_layout_project_path(@project)
      assert_select "div.panel-slot[data-key=photos] section.panel--placeholder h2", text: "Photos"

      @project.update!(panels: { "titles" => { "photos" => "Gallery" } })
      get edit_layout_project_path(@project)
      assert_select "div.panel-slot[data-key=photos] section.panel--placeholder h2", text: "Gallery",
                    count: 1

      get project_path(@project)
      assert_select "div.panel-slot[data-key=photos]", count: 0
      assert_select "section.photos-panel", count: 0
      # AND THE SLOT ITSELF IS ABSENT, not merely unlabelled. The two assertions above cannot see
      # that: the normal page renders no `data-key` at all, so `[data-key=photos]` is count 0
      # whatever the slot does, and an empty slot still occupies a grid cell. Counting slots
      # against slots that hold a panel is the assertion with weight — mutation-checked by turning
      # `_panel_slot`'s `elsif body.present?` into a bare `else`, which this and nothing else caught.
      slots = css_select("div.project-panels > div.panel-slot")
      assert_equal slots.size, css_select("div.project-panels > div.panel-slot > section.panel").size,
                   "a panel that renders nothing must render no slot"
      assert_operator slots.size, :>, 0, "and the count is not vacuously zero"
    end

    test "the normal page wraps every visible panel in a slot with its width, and carries no chrome" do
      get project_path(@project)

      assert_select "div.project-panels > div.panel-slot.panel--full > section.attachments-panel", 1
      assert_select "div.project-panels > div.panel-slot.panel--half > section.tasks-panel", 1
      assert_select "div.project-panels > div.panel-slot.panel--full > section.folder-panel", 1

      # A STORED WIDTH, THE OPPOSITE OF EACH DEFAULT, so `default_width` alone cannot pass this
      # (found in review: every width above is a default).
      @project.update!(panels: { "widths" => { "tasks" => "full", "attachments" => "half" } })
      get project_path(@project)
      assert_select "div.project-panels > div.panel-slot.panel--full > section.tasks-panel", 1
      assert_select "div.project-panels > div.panel-slot.panel--half > section.attachments-panel", 1
      assert_select ".panel-strip", count: 0
      assert_select ".layout-bar", count: 0
      assert_select "details.panel-chooser", count: 0
      assert_select "#panel-visibility", count: 0
      # NOR THE PAGE INTRO, NOR THE TEMPLATES (2026-09-09, content blocks): the description and the
      # cover render as the page's own prose here, not as a card with a picker in it.
      assert_select "div.page-intro", count: 0
      assert_select "template[data-layout-editor-target=blockTemplate]", count: 0
      assert_select "a.customise-link[href=?]", edit_layout_project_path(@project), text: "Customise page"
    end

    # THE FLAG IS THE ROUTE'S, NOT THE QUERY STRING'S (found in review): the chrome must come only
    # from the two `layout` routes' defaults.
    test "the plain project URL ignores ?editing=1" do
      get project_path(@project, editing: "1")

      assert_response :success
      assert_select ".layout-bar", count: 0
      assert_select ".panel-strip", count: 0
    end

    test "the edit page and the doors are the owner's alone" do
      other = User.create!(email: "other-#{SecureRandom.hex(4)}@example.com", password: PASSWORD, confirmed_at: Time.current)
      theirs = other.maker_projects.create!(name: "Theirs")

      get edit_layout_project_path(theirs)
      assert_response :not_found
      post yaml_project_layout_path(theirs), params: { draft: "{}" }
      assert_response :not_found
      post parse_project_layout_path(theirs), params: { yaml: "layout: 1\npanels: []\n" }
      assert_response :not_found
      get layout_panel_project_path(theirs, panel: "attachments", view: "list")
      assert_response :not_found
    end

    # --- one panel's body ---------------------------------------------------------------------------

    test "layout/panel renders one panel's body for a view the draft chose, and nothing else" do
      get layout_panel_project_path(@project, panel: models_key, view: "list")

      assert_response :success
      assert_select "section.folder-panel", 1
      assert_includes response.body, "base.stl", "the folder's file is listed"
      assert_select ".layout-bar", count: 0
      assert_select ".panel-strip", count: 0
      # `{ count: 0 }` BRACED BEFORE THE MESSAGE: a bare `count: 0, "…"` parses as one hash literal
      # whose second key has no value — a SyntaxError, not a failing assertion.
      assert_select "div.panel-slot", { count: 0 }, "the body alone, never the slot around it"
      assert_select "div.attachments-grid", { count: 0 }, "the list view, not the tiles the row is saved with"
    end

    test "layout/panel refuses a view the panel does not offer and a key that is not a panel" do
      get layout_panel_project_path(@project, panel: "attachments", view: "browser")
      assert_response :not_found
      get layout_panel_project_path(@project, panel: "tasks", view: "list")
      assert_response :not_found
      get layout_panel_project_path(@project, panel: "folder:nope", view: "list")
      assert_response :not_found
    end

    # --- the drawer's two conversions -------------------------------------------------------------

    test "yaml answers text/plain YAML for the posted draft, and the current layout for a broken one" do
      draft = { layout: 1, panels: [ { key: "tasks", hidden: true, width: "full" } ] }
      post yaml_project_layout_path(@project), params: { draft: draft.to_json }

      assert_response :success
      assert_equal "text/plain", response.media_type
      assert_includes response.body, "# Desk Lamp, page layout."
      assert_includes response.body, "- panel: tasks\n  width: full\n  hidden: true\n"
      assert_includes response.body, "- folder: models\n"

      post yaml_project_layout_path(@project), params: { draft: "not json" }
      assert_response :success
      assert_includes response.body, "- panel: attachments\n  width: full\n  view: tiles\n"
    end

    test "parse answers the draft with notes and errors as JSON, 200 either way" do
      post parse_project_layout_path(@project), params: { yaml: "layout: 1\npanels:\n  - folder: models\n    view: list\n  - folder: enclosure\n" }, as: :json

      assert_response :success
      body = response.parsed_body
      assert_equal [], body["errors"]
      assert_equal [ "This project has no folder named “enclosure”; that entry was skipped." ], body["notes"]
      assert_equal "list", body["draft"]["panels"].find { |e| e["key"] == models_key }["view"]

      post parse_project_layout_path(@project), params: { yaml: "layout: 1\npanels:\n  - panel: tsaks\n" }, as: :json
      assert_response :success
      assert_match(/unknown panel/, response.parsed_body["errors"].first)
    end

    test "parse merges into the draft the browser sends, so an unsaved change survives Apply" do
      draft = { layout: 1, panels: [ { key: "tasks", hidden: true, width: "full" } ] }
      post parse_project_layout_path(@project),
           params: { yaml: "layout: 1\npanels:\n  - panel: bom\n    hidden: true\n", draft: draft.to_json }, as: :json

      assert_response :success
      panels = response.parsed_body["draft"]["panels"]
      assert panels.find { |e| e["key"] == "tasks" }["hidden"], "the browser's unsaved hide survives"
      assert panels.find { |e| e["key"] == "bom" }["hidden"]
    end

    # --- Save --------------------------------------------------------------------------------------

    test "Save writes the whole document as six maps and lands on the page" do
      draft = { layout: 1, panels: [
        { key: models_key, hidden: false, width: "half", view: "list", title: "Prints", intro: "Sliced." },
        { key: "tasks", hidden: true, width: "full" },
        { key: "attachments", hidden: false, width: "full", view: "tiles" }
      ] }

      patch project_panels_path(@project), params: { layout: draft.to_json }

      assert_redirected_to project_path(@project)
      assert_equal "Page layout saved.", flash[:notice]
      panels = @project.reload.panels
      assert_equal [ models_key, "tasks", "attachments" ], panels["order"].first(3)
      assert_equal %w[tasks], panels["hidden"]
      assert_equal "list", panels["views"][models_key]
      assert_equal "half", panels["widths"][models_key]
      assert_equal "full", panels["widths"]["tasks"]
      assert_equal({ models_key => "Prints" }, panels["titles"])
      assert_equal({ models_key => "Sliced." }, panels["intros"])
      assert_equal "publish", panels["order"].last
    end

    test "Save drops a folder key that left the vocabulary, with a notice, and refuses a bad document" do
      draft = { layout: 1, panels: [ { key: "folder:gone", hidden: false, width: "full" }, { key: "tasks", hidden: true, width: "half" } ] }
      patch project_panels_path(@project), params: { layout: draft.to_json }

      assert_redirected_to project_path(@project)
      assert_match(/changed on disk/, flash[:notice])
      assert_equal %w[tasks], @project.reload.panels["hidden"]

      patch project_panels_path(@project), params: { layout: { layout: 1, panels: [ { key: "../etc" } ] }.to_json }
      assert_redirected_to edit_layout_project_path(@project)
      assert_match(/not saved/, flash[:alert])
      assert_equal %w[tasks], @project.reload.panels["hidden"], "a refused document writes nothing"

      patch project_panels_path(@project), params: { layout: "not json" }
      assert_redirected_to edit_layout_project_path(@project)
    end

    test "a bare PATCH with neither a view nor a document is a 400, and Reset clears every map" do
      patch project_panels_path(@project)
      assert_response :bad_request

      @project.update!(panels: { "hidden" => %w[tasks], "widths" => { "tasks" => "full" }, "titles" => { "tasks" => "X" } })
      delete project_panels_path(@project)
      assert_redirected_to project_path(@project)
      assert_nil @project.reload[:panels]
    end
  end
end
