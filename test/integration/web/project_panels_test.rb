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

      patch project_panels_path(@project), params: { move: "down", panel: Maker::Project::PANELS.last }
      assert_equal Maker::Project::PANELS, @project.reload.panel_layout.order
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
