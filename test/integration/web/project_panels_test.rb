require "test_helper"

module Web
  # STAGE 4, S4-7 (story 6.5): the panel chooser and the one door behind it. No JavaScript — the
  # whole surface is checkboxes, two button_to arrows and a Save, so every assertion here is on
  # markup a browser posts and on the row that comes back.
  class ProjectPanelsTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "panels-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      @project = @user.maker_projects.create!(name: "Desk Lamp")
    end

    # --- the markup -----------------------------------------------------------------------------

    # ASSERT THE RENDERED FIELD NAME (CLAUDE.md section 14d, twice-shipped). A nested-hash POST
    # below would pass whatever the form emitted, so the name the browser will actually send is
    # asserted here.
    test "the chooser names every panel, with the field names the door reads" do
      get project_path(@project)

      assert_select "details.panel-chooser#panels" do
        assert_select "li.panel-choice", Maker::Project::PANELS.size
        Maker::Project::PANELS.each do |key|
          assert_select "input[name=?][value=?]", "panels[order][]", key
        end
        assert_select "input[type=checkbox][name=?][value=?]", "panels[visible][]", "tasks"
        # `{ count: 1 }` BEFORE the message, deliberately: after the `?` substitutions are
        # consumed, a bare String is read as a TEXT comparator, never as the failure message
        # (rails-dom-testing 2.3.0, HTMLSelector#extract_equality_tests) — the same family of trap
        # CLAUDE.md section 14d records for `[attr=?]` with a Regexp.
        assert_select "input[type=hidden][name=?][value=?]", "panels[visible][]", "attachments",
                      { count: 1 }, "an always-shown panel carries a hidden field, not a checkbox"
        assert_select "input[type=checkbox][name=?][value=?]", "panels[visible][]", "attachments", count: 0
      end
    end

    # THE `form` ATTRIBUTE IS THE WHOLE MECHANISM (projects/_wiring's idiom): a <form> cannot
    # contain a button_to's own form, so the fields sit outside their form and point back at it.
    # Without this the checkboxes belong to no form and Save posts an empty body.
    test "every field points back at the empty checkbox form by id" do
      get project_path(@project)

      assert_select "form#panel-visibility[action=?]", project_panels_path(@project)
      assert_select "input[name=?][form=?]", "panels[order][]", "panel-visibility"
      assert_select "input[name=?][form=?]", "panels[visible][]", "panel-visibility"
      assert_select "input[type=submit][form=?]", "panel-visibility"
    end

    test "the chooser is closed until a write reopens it" do
      get project_path(@project)
      assert_select "details.panel-chooser[open]", count: 0

      get project_path(@project, panels: "open")
      assert_select "details.panel-chooser[open]", 1
    end

    test "the move buttons carry the panel and the direction as hidden inputs" do
      get project_path(@project)

      assert_select "form[action=?] input[name=move][value=up]", project_panels_path(@project)
      assert_select "form[action=?] input[name=panel][value=tasks]", project_panels_path(@project)
    end

    # --- the door -------------------------------------------------------------------------------

    test "Save writes the checked subset as visible and the rest as hidden" do
      patch project_panels_path(@project),
            params: { panels: { order: Maker::Project::PANELS,
                                visible: Maker::Project::PANELS - %w[tasks sheets] } }

      assert_redirected_to project_path(@project, panels: "open", anchor: "panels")
      assert_equal %w[tasks sheets], @project.reload.panels["hidden"]
      refute @project.panel_layout.visible?("tasks")
    end

    test "a move swaps two adjacent panels and leaves the rest alone" do
      patch project_panels_path(@project), params: { move: "up", panel: "tasks" }

      # PANELS is `... schematics build_log tasks bom ...`, so moving Tasks UP puts it at index 3
      # and Build log at 4 — the plan's own table had this pair the way round it is BEFORE the move.
      order = @project.reload.panels["order"]
      assert_equal %w[tasks build_log], order[3, 2]
      assert_equal Maker::Project::PANELS.sort, order.sort
    end

    # A HIDDEN PANEL KEEPS ITS SLOT. Without this, hiding then reordering then showing again would
    # send a panel to the end of the page for no reason the maker asked for.
    test "a move rewrites the full order, hidden panels included" do
      @project.update!(panels: { "hidden" => %w[wiring] })

      patch project_panels_path(@project), params: { move: "up", panel: "wiring" }

      assert_includes @project.reload.panels["order"], "wiring"
      assert_equal %w[wiring], @project.panels["hidden"], "a move must not change what is hidden"
    end

    test "a move off either end changes nothing and does not error" do
      patch project_panels_path(@project), params: { move: "up", panel: Maker::Project::PANELS.first }
      assert_response :redirect
      assert_equal Maker::Project::PANELS, @project.reload.panel_layout.order
      assert_nil @project[:panels], "a move that moved nothing must write nothing"

      patch project_panels_path(@project), params: { move: "down", panel: Maker::Project::PANELS.last }
      assert_equal Maker::Project::PANELS, @project.reload.panel_layout.order
    end

# A MOVE MUST NOT FREEZE THE KIND'S PRESET ONTO THE ROW (found in review). The first version
# wrote `layout.hidden` beside the order, which for a project with no override IS the kind's
# preset — so one reorder click on a laser project pinned BOM/Wiring/Releases/Sheets hidden,
# and switching the kind to electronics on the form changed nothing on the page.
test "a move writes the order only, so the project keeps following its kind" do
  @project.update!(kind: "laser")

  patch project_panels_path(@project), params: { move: "up", panel: "tasks" }

  refute @project.reload.panels.key?("hidden"), "a move must not copy the preset's hidden set"
  @project.update!(kind: "electronics")
  assert_equal %w[sheets], @project.panel_layout.hidden, "the new kind's preset must apply"
  get project_path(@project)
  assert_select "section.bom-panel", 1
end

test "a stored hidden override survives a move unchanged, empty included" do
  @project.update!(kind: "laser", panels: { "hidden" => [] })

  patch project_panels_path(@project), params: { move: "up", panel: "tasks" }

  assert_equal [], @project.reload.panels["hidden"], "an explicit 'hide nothing' must ride along"
end

test "a direction the buttons never send moves nothing and writes nothing" do
  patch project_panels_path(@project), params: { move: "sideways", panel: "tasks" }

  assert_response :redirect
  assert_nil @project.reload[:panels]
end

test "each move button carries its accessible name on the button itself" do
  get project_path(@project, panels: "open")

  assert_select ".panel-choice-moves button[aria-label=?]", "Move Tasks up", 1
  assert_select "form[aria-label]", count: 0
end

    # THE DOOR WRITES ONLY KNOWN KEYS. Structural, not a validation: this is the guard that stops a
    # crafted request from putting a partial name in the column that `render` would then be handed.
    test "a crafted request cannot put an unknown key in the column" do
      patch project_panels_path(@project),
            params: { panels: { order: [ "attachments", "../../etc/passwd" ],
                                visible: [ "attachments", "nope" ] } }

      stored = @project.reload.panels
      assert_operator Maker::Project::PANELS.to_set, :superset?, stored["order"].to_set
      assert_operator Maker::Project::PANELS.to_set, :superset?, stored["hidden"].to_set
      get project_path(@project)
      assert_response :success
    end

    test "Reset removes the override rather than writing the preset into the row" do
      @project.update!(kind: "laser", panels: { "hidden" => [] })

      delete project_panels_path(@project)

      assert_nil @project.reload[:panels],
                 "reset must clear the column, so the project keeps following its kind"
      refute @project.panel_layout.visible?("bom"), "the laser preset is back"
    end

    # --- folder panels (2026-09-08; spec decisions 1 and 6) -------------------------------------

    # Two depth-one subfolders, one of them a working tree. Bare `nodes.create!` rows under
    # `project_folder_rows!` — no port write anywhere, so this reads the same on all three legs.
    def seed_folders!(project = @project)
      folder = project_folder_rows!(@user, project)
      models = @user.nodes.create!(node_id: "d-models", name: "models", kind: "dir",
                                   parent_node_id: folder.node_id)
      firmware = @user.nodes.create!(node_id: "d-firmware", name: "firmware", kind: "dir",
                                     parent_node_id: folder.node_id)
      @user.nodes.create!(node_id: "d-git", name: Library::RepoMetadata::DIR_NAME, kind: "dir",
                          parent_node_id: firmware.node_id)
      @user.nodes.create!(node_id: "f-base", name: "base.stl", kind: "file",
                          parent_node_id: models.node_id, size: 10, mtime: 1_000_000_000)
      # A FILE INSIDE THE WORKING TREE, or its panel is EMPTY and renders quiet instead of the
      # browser — the browser is what the repo assertions below are about.
      @user.nodes.create!(node_id: "f-main", name: "main.c", kind: "file",
                          parent_node_id: firmware.node_id, size: 10, mtime: 1_000_000_000)
      [ Maker::ProjectKind.folder_key("d-models"), Maker::ProjectKind.folder_key("d-firmware") ]
    end

    # THE SAME FIELD NAMES AS A FIXED PANEL, which is what makes hiding and moving a folder work
    # with no new markup at all. Asserted on the RENDERED names (CLAUDE.md section 14d), and the
    # LABEL is the folder's own name — the one thing @panel_labels adds that PANEL_LABELS cannot.
    test "the chooser lists a folder row per subfolder, with its name and the same field names" do
      models, firmware = seed_folders!

      get project_path(@project)

      assert_select "details.panel-chooser#panels" do
        assert_select "li.panel-choice", Maker::Project::PANELS.size + 2
        assert_select "input[name=?][value=?]", "panels[order][]", models
        assert_select "input[type=checkbox][name=?][value=?]", "panels[visible][]", firmware
        assert_select "label.panel-choice-name", text: /models/
        assert_select "button[aria-label=?]", "Move models up", 1
      end
      # A folder row says which kind of place it is: `repo` for a working tree, `folder` otherwise.
      assert_select "li.panel-choice:has(input[value='#{firmware}']) span.badge", text: "repo"
      assert_select "li.panel-choice:has(input[value='#{models}']) span.badge", text: "folder"
    end

    test "a folder can be hidden through the same Save the fixed panels use" do
      models, firmware = seed_folders!

      # THE FORM SENDS THE COMPLETE PICTURE — every key in `order`, the checked ones in `visible`
      # — so "hidden" is the difference. Leaving `firmware` out of `order` here would hide it too,
      # which is the door's own rule and not what this test is about.
      patch project_panels_path(@project),
            params: { panels: { order: Maker::Project::PANELS + [ models, firmware ],
                                visible: Maker::Project::PANELS + [ firmware ] } }

      assert_equal [ models ], @project.reload.panels["hidden"]
      get project_path(@project)
      assert_select "section.folder-panel[id=?]", models, count: 0
    end

    # --- the view toggle ------------------------------------------------------------------------

    test "a view toggle writes that panel's view, keeps the others, and lands on the panel" do
      models, firmware = seed_folders!

      patch project_panels_path(@project), params: { view: { models => "list" } }

      assert_redirected_to project_path(@project, anchor: models)
      assert_equal({ models => "list" }, @project.reload.panels["views"])

      get project_path(@project)
      assert_select "section.folder-panel[id=?] table.project-files td.col-name", models, text: "base.stl"
      assert_select "section.folder-panel[id=?] .repo-browser", firmware, 1

      # A SECOND TOGGLE MERGES rather than replaces: one click is about one panel.
      patch project_panels_path(@project), params: { view: { "attachments" => "list" } }
      assert_equal({ models => "list", "attachments" => "list" }, @project.reload.panels["views"])
    end

    # AN UNKNOWN KEY OR VALUE WRITES NOTHING, for the reason every other array on this door is
    # intersected: `view` is hand-writable, and a value outside Maker::Project::VIEWS would reach
    # the partial's own branch. Neither may echo into the redirect's anchor either.
    test "a view outside the vocabulary writes nothing" do
      models, = seed_folders!
      @project.update!(panels: { "views" => { models => "list" } })

      patch project_panels_path(@project), params: { view: { models => "sideways" } }
      assert_redirected_to project_path(@project)
      assert_equal({ models => "list" }, @project.reload.panels["views"])

      patch project_panels_path(@project), params: { view: { "folder:not-a-folder" => "tiles" } }
      assert_equal({ models => "list" }, @project.reload.panels["views"])

      patch project_panels_path(@project), params: { view: { "../../etc/passwd" => "tiles" } }
      assert_equal({ models => "list" }, @project.reload.panels["views"])

      # The RETIRED page-wide toggle's shape — a bare `?view=list` — is a String, not a pair, and
      # answers nothing rather than half-working.
      patch project_panels_path(@project), params: { view: "list" }
      assert_equal({ models => "list" }, @project.reload.panels["views"])
    end

    # THE THREE OTHER DOORS MUST CARRY `views` FORWARD, or the first arrow click or Save would
    # silently reset every panel's view — the same "only the question that was asked" rule the
    # hidden set already follows.
    # THE DOOR TAKES ONLY WHAT THE PANEL OFFERS, AND ONLY ONE PAIR (found in review): `browser` for
    # Files stored a state no button could show, a fixed panel with no view took one anyway, and
    # two pairs wrote the first. Each writes nothing now.
    test "a view the panel does not offer, a panel with no view, and two pairs all write nothing" do
      seed_folders!
      # A STORED VIEW FIRST, so "writes nothing" is asserted against a real hash rather than nil —
      # and so a door that merged a refused pair over an existing map would be seen doing it.
      @project.update!(panels: { "views" => { "folder:d-firmware" => "tiles" } })
      before = @project.reload.panels

      patch project_panels_path(@project), params: { view: { "attachments" => "browser" } }
      assert_equal before, @project.reload.panels, "Files offers no browser"

      patch project_panels_path(@project), params: { view: { "tasks" => "list" } }
      assert_equal before, @project.reload.panels, "Tasks has no view"

      patch project_panels_path(@project), params: { view: { "folder:d-models" => "list", "attachments" => "list" } }
      assert_equal before, @project.reload.panels, "two pairs are not one"
      assert_response :redirect
    end

    test "Save and a move keep the chosen views, and Reset clears them" do
      models, = seed_folders!
      @project.update!(panels: { "views" => { models => "list" } })

      patch project_panels_path(@project),
            params: { panels: { order: Maker::Project::PANELS + [ models ],
                                visible: Maker::Project::PANELS + [ models ] } }
      assert_equal({ models => "list" }, @project.reload.panels["views"], "Save must not drop the views")

      patch project_panels_path(@project), params: { move: "up", panel: models }
      assert_equal({ models => "list" }, @project.reload.panels["views"], "a move must not drop the views")
      assert_includes @project.panels["order"], models

      delete project_panels_path(@project)
      assert_nil @project.reload[:panels], "Reset clears the views with the rest of the arrangement"
    end

    # A FOLDER KEY MUST SURVIVE A SAVE. The door's `known` filter used to be `& PANELS`, which
    # would drop every folder key on the way in: a maker who opened the chooser once would lose
    # their folder panels' arrangement with no error anywhere.
    test "Save keeps a folder key in the stored order" do
      models, firmware = seed_folders!

      patch project_panels_path(@project),
            params: { panels: { order: [ "attachments", firmware, models ] + Maker::Project::PANELS,
                                visible: Maker::Project::PANELS + [ models, firmware ] } }

      order = @project.reload.panels["order"]
      assert_equal [ "attachments", firmware, models ], order.first(3)
      assert_empty @project.panels["hidden"]
    end

    test "the door is another user's 404 and a signed-out visitor's redirect" do
      other = User.create!(email: "other-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      theirs = other.maker_projects.create!(name: "Theirs")

      # NOT `assert_raises`: config.action_dispatch.show_exceptions is `:rescuable` in the test
      # env, so `find_by!`'s RecordNotFound is RENDERED as 404 rather than raised out of the
      # request — cross_user_authorization_test.rb's own idiom, which asserts the response.
      patch project_panels_path(theirs), params: { move: "up", panel: "tasks" }
      assert_response :not_found
      assert_nil theirs.reload[:panels], "a non-owner's move must not write the row"

      delete destroy_user_session_path
      patch project_panels_path(@project), params: { move: "up", panel: "tasks" }
      assert_redirected_to new_user_session_path
    end
  end
end
