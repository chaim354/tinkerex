require "test_helper"

module Web
  # STAGE 4, S4-7 (story 6.5), narrowed on 2026-09-09: the panels door's VIEW branch — the inline
  # tiles/list/browser toggle that still saves at once. The chooser and its move/visible branches
  # retired with the page editor (spec 2026-09-09-page-editor §2); the document write is tested
  # in project_layout_editor_test.rb.
  class ProjectPanelsTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "panels-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
      @project = @user.maker_projects.create!(name: "Desk Lamp")
    end

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

    # AN UNKNOWN KEY OR VALUE WRITES NOTHING, for the reason every other write on this door is
    # checked against the layout: `view` is hand-writable, and a value outside Maker::Project::VIEWS
    # would reach the partial's own branch. Neither may echo into the redirect's anchor either.
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
      # answers nothing rather than half-working. It reaches the bad-request arm now that the
      # chooser's own shapes are gone, which is the honest answer to a request no button sends.
      patch project_panels_path(@project), params: { view: "list" }
      assert_equal({ models => "list" }, @project.reload.panels["views"])
    end

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

    # --- reset ----------------------------------------------------------------------------------

    test "Reset removes the override rather than writing the preset into the row" do
      @project.update!(kind: "laser", panels: { "hidden" => [] })

      delete project_panels_path(@project)

      assert_nil @project.reload[:panels],
                 "reset must clear the column, so the project keeps following its kind"
      refute @project.panel_layout.visible?("bom"), "the laser preset is back"
    end

    # --- the owner's door -----------------------------------------------------------------------

    test "the door is another user's 404 and a signed-out visitor's redirect" do
      other = User.create!(email: "other-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      theirs = other.maker_projects.create!(name: "Theirs")

      # NOT `assert_raises`: config.action_dispatch.show_exceptions is `:rescuable` in the test
      # env, so `find_by!`'s RecordNotFound is RENDERED as 404 rather than raised out of the
      # request — cross_user_authorization_test.rb's own idiom, which asserts the response.
      patch project_panels_path(theirs), params: { view: { "attachments" => "list" } }
      assert_response :not_found
      assert_nil theirs.reload[:panels], "a non-owner's write must not touch the row"

      delete destroy_user_session_path
      patch project_panels_path(@project), params: { view: { "attachments" => "list" } }
      assert_redirected_to new_user_session_path
    end
  end
end
