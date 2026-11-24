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

    # --- the switch, in place -------------------------------------------------------------------
    #
    # A PANEL'S VIEW SWITCHES WITHOUT REDRAWING THE PAGE (2026-11-16, the owner's report: "there
    # shouldn't be a whole page reload to switch one panel's mode"). The door still writes and
    # redirects, as every write on this page does. What changed is where it redirects a toggle that
    # says `in_place`: to the page, naming the panel, and the page answers a browser that takes
    # Turbo Streams with that panel alone. Turbo follows the redirect with the form's own Accept
    # header, so the stream reaches the page that pressed the button and replaces one section.
    #
    # THESE PIN THE WIRE. Whether a browser then leaves the rest of the page alone is
    # test/system/panel_view_switch_test.rb's to say.
    #
    # WHAT TURBO SENDS when it follows a form's redirect: the stream type first, then HTML.
    TURBO = { "Accept" => "text/vnd.turbo-stream.html, text/html, application/xhtml+xml" }.freeze

    def streams = css_select("turbo-stream").map { |s| [ s["action"], s["target"] ] }

    def streamed(target)
      Nokogiri::HTML5.fragment(css_select("turbo-stream[target='#{target}'] template").first.inner_html)
    end

    # A FOLDER PANEL IS REPLACED BY ITS TURBO FRAME (2026-11-24, click-through panels): the partial
    # renders the frame around the section, so a stream that targeted the section would nest a frame
    # in a frame. The Files panel has no frame and keeps its section's id. The frame's id is the key
    # with its colon replaced (ProjectsHelper#panel_frame_id says why), spelled out here so the test
    # pins the wire rather than calling the helper it checks.
    def frame(key) = "frame-#{key.tr(':', '-')}"

    test "the page's own toggles ask for the switch in place, and the editor's do not" do
      seed_folders!

      get project_path(@project)
      forms = css_select(".panel-head .view-toggle form")
      assert_equal 8, forms.size, "Files offers two views and each of the two folders three"
      forms.each do |form|
        assert_equal [ "1" ], form.css("input[name='in_place']").map { |input| input["value"] }, form.to_s.first(160)
      end

      # THE EDITOR'S COPY OF THE SAME BUTTONS KEEPS ITS OLD ANSWER: a stream would replace a panel
      # inside the editor while the draft beside it still held the view it had.
      get edit_layout_project_path(@project)
      assert_response :success
      assert_equal 8, css_select(".panel-head .view-toggle form").size
      assert_select ".view-toggle input[name='in_place']", 0
    end

    test "asked in place, the door sends the browser back for that panel" do
      models, = seed_folders!

      patch project_panels_path(@project), params: { view: { models => "list" }, in_place: "1" }
      assert_redirected_to project_path(@project, panel: models, anchor: models)
      assert_equal "list", @project.reload.panels.dig("views", models)

      patch project_panels_path(@project), params: { view: { "attachments" => "list" }, in_place: "1" }
      assert_redirected_to project_path(@project, panel: "attachments", anchor: "attachments")

      # A REFUSED PAIR NAMES NO PANEL, in place or not: the key is what could have named one.
      patch project_panels_path(@project), params: { view: { models => "sideways" }, in_place: "1" }
      assert_redirected_to project_path(@project)
      patch project_panels_path(@project), params: { view: { "../../etc/passwd" => "tiles" }, in_place: "1" }
      assert_redirected_to project_path(@project)
    end

    # THE FILES PANEL'S "RECENTLY CHANGED" ROW LEAVES OUT A BROWSED FOLDER'S FILES
    # (ProjectsController#dirs_without_tiles), so a folder going into or out of the browser changes
    # a second panel. The door says so, and only then: a switch between tiles and list changes
    # nothing outside its own panel.
    test "a folder switched into or out of the browser asks for the Files panel too" do
      models, firmware = seed_folders!

      patch project_panels_path(@project), params: { view: { models => "browser" }, in_place: "1" }
      assert_redirected_to project_path(@project, panel: models, files: "1", anchor: models)

      patch project_panels_path(@project), params: { view: { models => "list" }, in_place: "1" }
      assert_redirected_to project_path(@project, panel: models, files: "1", anchor: models)

      patch project_panels_path(@project), params: { view: { models => "tiles" }, in_place: "1" }
      assert_redirected_to project_path(@project, panel: models, anchor: models)

      # THE VIEW IT HAD IS THE LAYOUT'S ANSWER, NOT THE STORED ONE: a repository with nothing stored
      # opens in the browser (Maker::ProjectKind.default_view), so its first switch leaves it.
      assert_nil @project.reload.panels.dig("views", firmware)
      patch project_panels_path(@project), params: { view: { firmware => "tiles" }, in_place: "1" }
      assert_redirected_to project_path(@project, panel: firmware, files: "1", anchor: firmware)

      patch project_panels_path(@project), params: { view: { firmware => "tiles" }, in_place: "1" }
      assert_redirected_to project_path(@project, panel: firmware, anchor: firmware)
    end

    test "asked as a stream, the page answers with that panel alone and marks its pressed button for focus" do
      models, = seed_folders!
      @project.update!(panels: { "views" => { models => "list" } })

      get project_path(@project, panel: models), headers: TURBO
      assert_response :success
      assert_equal "text/vnd.turbo-stream.html", response.media_type
      assert_equal [ [ "replace", frame(models) ] ], streams

      panel = streamed(frame(models))
      assert_equal 1, panel.css("turbo-frame[id='#{frame(models)}'][target='_top'] > section.folder-panel[id='#{models}']").size,
                   "the stream must carry the frame it replaces, with the panel's section inside it"
      assert_equal [ "base.stl" ], panel.css("table.project-files td.col-name").map { |cell| cell.text.strip }
      pressed = panel.css(".view-toggle button[aria-pressed='true']")
      assert_equal [ "List" ], pressed.map { |button| button.text.strip }
      assert pressed.first.key?("autofocus"), "the pressed button must take the focus the old one held"
      assert_equal 1, panel.css("[autofocus]").size
      # It still asks in place, or the second press would redraw the page.
      assert_equal 3, panel.css(".view-toggle input[name='in_place']").size
    end

    test "with files=1 the stream carries the Files panel after the panel that was switched" do
      models, = seed_folders!
      @project.update!(panels: { "views" => { models => "browser" } })

      get project_path(@project, panel: models, files: "1"), headers: TURBO
      assert_response :success
      assert_equal [ [ "replace", frame(models) ], [ "replace", "attachments" ] ], streams
      assert_equal 1, streamed(frame(models)).css(".repo-browser").size
      files = streamed("attachments")
      assert_equal 1, files.css("section.attachments-panel#attachments").size
      # ONE FOCUS, and it is the pressed button's: Turbo focuses the first it finds in the streams.
      assert_empty files.css("[autofocus]")
      assert_equal 1, streamed(frame(models)).css("[autofocus]").size

      # The Files panel's own switch never names itself twice.
      get project_path(@project, panel: "attachments", files: "1"), headers: TURBO
      assert_equal [ [ "replace", "attachments" ] ], streams
    end

    # THE SAME ADDRESS IS THE PAGE TO A BROWSER THAT TAKES NO STREAMS: a form posted with no
    # JavaScript follows the door's redirect here, and lands on the panel's anchor as it always did.
    test "asked as html, the address is the whole page" do
      models, = seed_folders!

      get project_path(@project, panel: models)
      assert_response :success
      assert_equal "text/html", response.media_type
      assert_select "turbo-stream", 0
      assert_select "div.project-panels > div.panel-slot > section.panel", minimum: 3
      assert_select "section.folder-panel[id=?]", models, 1
    end

    # A STREAM IS ANSWERED ONLY FOR A PANEL THAT HAS A VIEW TO SWITCH. Turbo sends the stream Accept
    # on EVERY form's redirect, so a key this page cannot switch must get the page: a stream naming
    # nothing would leave the browser on a page that silently did not change.
    test "a key with no view to switch, or none this project has, gets the page" do
      models, firmware = seed_folders!
      @project.tasks.create!(user: @user, title: "Print base")
      # A PANEL THE MAKER HID is not on the page to be replaced, and its files were not loaded.
      @project.update!(panels: { "hidden" => [ firmware ] })

      [ "tasks", firmware, "folder:not-a-folder", "../../etc/passwd", "" ].each do |key|
        get project_path(@project, panel: key), headers: TURBO
        assert_response :success, key
        assert_equal "text/html", response.media_type, key
        assert_select "turbo-stream", 0
      end

      get project_path(@project), headers: TURBO
      assert_equal "text/html", response.media_type, "a redirect to the plain page is still the page"
      get project_path(@project, panel: [ models ]), headers: TURBO
      assert_equal "text/html", response.media_type, "a key that is not a String names nothing"

      # AND THE EDITOR'S OWN `panel` IS UNTOUCHED: it answers one bare body, never a stream, and
      # marks no button for focus, which in the editor would pull the keyboard out of the strip.
      get layout_panel_project_path(@project, panel: models, view: "list"), headers: TURBO
      assert_response :success
      assert_select "turbo-stream", 0
      assert_select "section.folder-panel[id=?] table.project-files", models, 1
      assert_select "[autofocus]", 0
    end

    # A PAGE LOAD MARKS NOTHING FOR FOCUS: `autofocus` in a page pulls the keyboard, and the window,
    # to a view button on every visit.
    test "the page itself marks no view button for focus" do
      seed_folders!

      get project_path(@project)
      assert_select "[autofocus]", 0
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
