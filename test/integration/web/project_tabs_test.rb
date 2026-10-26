require "test_helper"

module Web
  # TABS, SERVER HALF (2026-09-09; spec §5, §6): what both pages render around the groups, what Save
  # writes, what it refuses, and that a project without tabs is byte-for-byte today's page. The
  # browser's half is test/system/page_tabs_test.rb.
  class ProjectTabsTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze
    TAB_A = "3f9a1b2c4d5e".freeze
    TAB_B = "a0c4d8e2f611".freeze

    setup do
      @user = User.create!(email: "tabs-#{SecureRandom.hex(4)}@example.com", password: PASSWORD, confirmed_at: Time.current,
                           handle: "tabs#{SecureRandom.hex(3)}")
      sign_in_web!(@user, password: PASSWORD)
      @project = @user.maker_projects.create!(name: "Desk Lamp", description: "A lamp.", visibility: "public")
      @folder = project_folder_rows!(@user, @project)
      @project.tasks.create!(user: @user, title: "Print the shade")
    end

    def tk(hex) = Maker::ProjectKind.tab_key(hex)

    def tabbed!
      @project.update!(panels: { "order" => [ "attachments", "photos", tk(TAB_A), "build_log", "tasks", tk(TAB_B), "bom", "publish" ],
                                 "titles" => { tk(TAB_A) => "Build", tk(TAB_B) => "Parts" } })
    end

    # A ROW IN EACH TAB'S PANELS (slice 6): an empty Build log or BOM is absent from the maker's page
    # now, and a tab holding nothing that renders drops out (the next test). Seeded so both tabs are
    # on the page to be asserted.
    def rows_in_both_tabs!
      @project.build_log_entries.create!(user: @user, body: "Glued the base.", logged_at: Time.current)
      @project.boms.create!(user: @user).lines.create!(user: @user, part_name: "M3 screw", quantity: 4, unit: "each")
    end

    test "the maker's page renders the top group, a tab bar, one pane per tab and Publish below" do
      tabbed!
      rows_in_both_tabs!
      get project_path(@project)
      assert_response :success

      assert_select "div.project-panels > div.panel-slot > section.attachments-panel", 1
      assert_select "div.tabs[data-controller=tabs]" do
        assert_select "nav.tab-bar[role=tablist] a.tab-link[role=tab]", 2
        assert_select "a.tab-link[href='#tab-build'][aria-controls='tab-build'][aria-selected=true]", text: "Build"
        assert_select "a.tab-link[href='#tab-parts'][aria-selected=false][tabindex='-1']", text: "Parts"
        # THE CONTROLLER'S HOOKS ARE PART OF THE CONTRACT (§14d): a target or action that goes
        # missing is a silent no-op, so both are pinned here as well as driven in the browser suite.
        assert_select "a.tab-link[tabindex='0'][data-tabs-target=tab][data-action='click->tabs#select keydown->tabs#key']", 1
        assert_select "section.tab-pane[data-tabs-target=pane]", 2
        assert_select "section.tab-pane#tab-build[role=tabpanel][aria-labelledby='tablink-build']" do
          assert_select "h2.tab-heading", text: "Build"
          assert_select "div.project-panels[data-controller=masonry] > div.panel-slot > section.build-log-panel", 1
          assert_select "section.tasks-panel", 1
        end
        assert_select "section.tab-pane#tab-parts section.bom-panel", 1
      end
      # NOTHING BELOW THE TABS ON THE MAKER'S PAGE SINCE 2026-10-26: Publish sat in its own grid
      # there (spec decision 3) until it became the edit area's Publishing tab, and the maker's page
      # passes no tail, so the foot is gone rather than an empty grid.
      assert_select "section#publish, section.publish-panel", 0
      assert_select "div.tabs ~ div.project-panels", 0
    end

    # A TAB WHOSE PANELS ARE ALL EMPTY ON-DEMAND PANELS DROPS OUT CLEANLY (slice 6): its keys are
    # never yielded, so _panel_groups renders no pane for it and no link in the bar — the same rule
    # that already keeps a visitor's empty tab out. "+ Add panel" still offers the panel, and
    # ?add= brings the tab back with it for that visit.
    test "a tab holding only empty on-demand panels has no pane and no bar link until ?add= opens one" do
      tabbed!
      # MODELS IS NAMED IN THE TOP GROUP (2026-10-21). It always renders ("No models yet." beside
      # Add model), and a stored order that does not name a panel puts it in the preset tail — the
      # LAST tab, Parts here, which would then never be empty. Named, Parts holds only on-demand
      # panels again, which is this test's premise.
      @project.update!(panels: @project.panels.merge("order" => [ "attachments", "photos", "models", tk(TAB_A),
                                                                  "build_log", "tasks", tk(TAB_B), "bom", "publish" ]))
      @project.build_log_entries.create!(user: @user, body: "Glued the base.", logged_at: Time.current)

      get project_path(@project)
      assert_select "nav.tab-bar a.tab-link", 1
      assert_select "a.tab-link[href='#tab-parts']", 0
      assert_select "section.tab-pane#tab-parts", 0
      assert_select "section.tab-pane", 1
      assert_select ".add-panel a.menu-item[href=?]", project_path(@project, add: "bom", anchor: "project-bom"),
                    text: "Bill of materials"

      get project_path(@project, add: "bom")
      assert_select "nav.tab-bar a.tab-link", 2
      assert_select "section.tab-pane#tab-parts section.bom-panel.panel--quiet#project-bom", 1
    end

    test "a project without tabs renders today's markup: one grid, every visible panel" do
      get project_path(@project)
      assert_select "div.tabs", 0
      assert_select "div.project-panels[data-controller=masonry]", 1
      assert_select "section#publish, section.publish-panel", 0
      assert_select "div.project-panels > div.panel-slot > section.attachments-panel", 1
    end

    test "the visitor's page renders the same shape, keeps a tab whose panels render nothing out of the bar, and puts repository cards beside Publish's grid" do
      tabbed!
      # `tasks` has no public face; a tab holding only Tasks must not appear for a visitor.
      @project.update!(panels: @project.panels.merge("order" => [ "attachments", "photos", tk(TAB_A), "tasks", tk(TAB_B), "build_log", "publish" ]))
      @project.build_log_entries.create!(user: @user, body: "Glued the base.", logged_at: Time.current)
      delete destroy_user_session_path

      get public_project_path(@user.handle, @project.slug)
      assert_response :success
      assert_select "nav.tab-bar a.tab-link", 1
      assert_select "a.tab-link[href='#tab-parts']", text: "Parts"
      assert_select "section.tab-pane#tab-build", 0
      assert_select "section.tab-pane#tab-parts section.build-log-panel", 1
      assert_select "div.tabs ~ div.project-panels", { count: 0 }, "no empty trailing grid when there is nothing to put in it"
    end

    # THE OTHER HALF OF THE FOOT (spec §6): a repository card is not a panel of the layout, so it has
    # no key and no group — it rides the caller's `tail` into the grid below the panes, where it is
    # on view whichever tab is open. Rows alone make a working tree here; the card's own facts are
    # unavailable without a real checkout, which is beside the point of where it lands.
    test "the visitor's repository cards ride below the panes when the page has tabs" do
      firmware = @user.nodes.create!(node_id: SecureRandom.uuid, name: "firmware", kind: "dir",
                                     parent_node_id: @folder.node_id, mtime: 1, size: 0)
      @user.nodes.create!(node_id: SecureRandom.uuid, name: ".git", kind: "dir",
                          parent_node_id: firmware.node_id, mtime: 1, size: 0)
      @project.build_log_entries.create!(user: @user, body: "Glued the base.", logged_at: Time.current)
      @project.update!(panels: { "order" => [ "attachments", tk(TAB_A), "build_log", "publish" ],
                                 "titles" => { tk(TAB_A) => "Build" } })
      delete destroy_user_session_path

      get public_project_path(@user.handle, @project.slug)
      assert_response :success
      assert_select "section.tab-pane#tab-build .repo-card", 0, "a card is not inside a pane"
      assert_select "div.tabs + div.project-panels .repo-card", 1
    end

    test "the visitor's page without tabs is today's markup" do
      delete destroy_user_session_path
      get public_project_path(@user.handle, @project.slug)
      assert_select "div.tabs", 0
      assert_select "div.project-panels[data-controller=masonry]", 1
    end

    test "the editor renders a separator slot per tab with its name, Add tab, the cap, and the tab template" do
      tabbed!
      get edit_layout_project_path(@project)
      assert_select "div.layout-editor[data-layout-editor-tab-cap-value=?]", Maker::ProjectKind::TAB_CAP.to_s, 1
      assert_select "div.project-panels.layout-editing > div.panel-slot.panel-slot--tab[data-key=?][data-kind=tab][data-name=Build]", tk(TAB_A) do
        assert_select "span.panel-strip-handle", 1
        assert_select "input.tab-name[value=Build][maxlength=?]", Maker::ProjectKind::TAB_NAME_MAX.to_s
        assert_select "button[data-action='layout-editor#deleteTab']", text: "Delete"
      end
      assert_select "button[data-action='layout-editor#addTab']:not([disabled])", text: "Add tab"
      assert_select "template[data-layout-editor-target=blockTemplate][data-kind=tab]", 1
      assert_match(/tab:new-__N__/, response.body)
      # THE ORDER OF SLOTS IS THE ORDER, separators included.
      keys = css_select("div.project-panels.layout-editing > div.panel-slot").map { |s| s["data-key"] }
      assert_equal [ "attachments", "photos", tk(TAB_A), "build_log", "tasks", tk(TAB_B), "bom" ],
                   keys.first(7)
      refute_includes keys, "publish"
    end

    test "Add tab is disabled at the cap" do
      eight = (1..8).map { |i| tk(format("%012x", i)) }
      @project.update!(panels: { "order" => [ "attachments", *eight, "photos", "publish" ], "titles" => eight.to_h { |k| [ k, k.last(4) ] } })
      get edit_layout_project_path(@project)
      assert_select "button[data-action='layout-editor#addTab'][disabled]", 1
    end

    # THE DRAFT NAMES EVERY SLOT THE EDITOR HOLDS, which is what the browser posts: an entry the
    # document does not name keeps its place and is appended after the ones that are named, so a
    # partial draft would pin the leftovers' order rather than the arrangement under test.
    test "Save rekeys a new tab in order and titles, keeps the name, and a deleted tab is gone" do
      tabbed!
      draft = { layout: 1, panels: [
        { key: "attachments", hidden: false, width: "full", view: "tiles" },
        { key: "photos", hidden: false, width: "full" },
        { key: "tab:new-1", kind: "tab", name: "  Notes  " },
        { key: "build_log", hidden: false, width: "half" },
        { key: tk(TAB_B), kind: "tab", name: "Parts" },
        { key: "bom", hidden: false, width: "half" },
        { key: "tasks", hidden: false, width: "half" },
        # The Models panel (2026-10-21) is a slot the editor holds, so the draft names it too.
        { key: "models", hidden: false, width: "half" },
        { key: "schematics", hidden: false, width: "full" },
        { key: "wiring", hidden: false, width: "full" },
        { key: "releases", hidden: false, width: "half" },
        { key: "sheets", hidden: false, width: "half" },
        # The Calculations panel (2026-10-21) is a slot the editor holds too.
        { key: "calculations", hidden: false, width: "half" },
        { key: "publish", hidden: false, width: "half" } ] }
      patch project_panels_path(@project), params: { layout: draft.to_json }
      assert_redirected_to project_path(@project)

      panels = @project.reload.panels
      minted = panels["order"][2]
      assert_match(/\Atab:[0-9a-f]{12}\z/, minted)
      assert_equal "Notes", panels["titles"][minted]
      assert_equal [ "attachments", "photos", minted, "build_log", tk(TAB_B), "bom", "tasks", "models",
                     "schematics", "wiring", "releases", "sheets", "calculations" ], panels["order"]
      refute_includes panels["order"], tk(TAB_A), "a tab absent from the posted draft is removed"
      refute panels["titles"].key?(tk(TAB_A))
      refute panels["widths"].key?(minted)
      refute panels["hidden"].include?(minted)
    end

    test "Save refuses a blank name, a duplicate name and a tab key the layout does not know, writing nothing" do
      tabbed!
      before = @project.panels
      blank = { layout: 1, panels: [ { key: "tab:new-1", kind: "tab", name: " " }, { key: "publish", hidden: false, width: "half" } ] }
      patch project_panels_path(@project), params: { layout: blank.to_json }
      assert_redirected_to edit_layout_project_path(@project)
      assert_match(/a tab needs a name/, flash[:alert])

      dup = { layout: 1, panels: [ { key: tk(TAB_A), kind: "tab", name: "build" }, { key: "tab:new-1", kind: "tab", name: "BUILD" }, { key: "publish", hidden: false, width: "half" } ] }
      patch project_panels_path(@project), params: { layout: dup.to_json }
      assert_match(/Two tabs are named/, flash[:alert])

      ghost = { layout: 1, panels: [ { key: tk("ffffffffffff"), kind: "tab", name: "Ghost" }, { key: "publish", hidden: false, width: "half" } ] }
      patch project_panels_path(@project), params: { layout: ghost.to_json }
      assert_match(/unknown tab/, flash[:alert])
      assert_equal before, @project.reload.panels
    end

    test "Reset removes tabs with the rest of the arrangement, and says so" do
      tabbed!
      get edit_layout_project_path(@project)
      assert_match(/intros and tabs all go back/, response.body)
      delete project_panels_path(@project)
      assert_nil @project.reload.panels
      get project_path(@project)
      assert_select "div.tabs", 0
    end

    # FOUND IN REVIEW: the head was keyed on the top group's KEYS where the foot is keyed on what
    # rendered, so a visitor whose top group held only Tasks got an empty band above the bar.
    test "an empty top group renders no grid above the bar, on the maker's page and on a visitor's whose top has no public face" do
      @project.update!(panels: { "order" => [ tk(TAB_A), "attachments", "publish" ], "titles" => { tk(TAB_A) => "Build" } })
      get project_path(@project)
      assert_select "div.tabs", 1
      assert_select "div.project-panels + div.tabs", 0, "no grid, empty or not, above the bar"
      assert_select "div.project-panels", 1, "the pane's grid alone: the maker's page has no foot since Publish left it"

      @project.update!(panels: { "order" => [ "tasks", tk(TAB_A), "build_log", "publish" ], "titles" => { tk(TAB_A) => "Build" } })
      @project.build_log_entries.create!(user: @user, body: "Glued the base.", logged_at: Time.current)
      delete destroy_user_session_path
      get public_project_path(@user.handle, @project.slug)
      assert_select "section.tab-pane#tab-build section.build-log-panel", 1
      assert_select "div.project-panels + div.tabs", 0, "Tasks has no public face, so the top group renders no grid"
    end

    test "a tab's name is text on the page, never markup" do
      @project.update!(panels: { "order" => [ "attachments", tk(TAB_A), "tasks", "publish" ], "titles" => { tk(TAB_A) => "<b>Build</b>" } })
      get project_path(@project)
      assert_select "a.tab-link", text: "<b>Build</b>"
      assert_select "a.tab-link b", 0
      assert_select "h2.tab-heading b", 0
    end

    test "a tab whose name yields no slug, or collides, is addressed by its key" do
      @project.update!(panels: { "order" => [ "attachments", tk(TAB_A), "build_log", tk(TAB_B), "tasks", "publish" ],
                                 "titles" => { tk(TAB_A) => "Build!", tk(TAB_B) => "build?" } })
      # A row, so tab A's Build log renders and its pane is on the page (slice 6).
      @project.build_log_entries.create!(user: @user, body: "Glued the base.", logged_at: Time.current)
      get project_path(@project)
      assert_select "section.tab-pane#tab-#{TAB_A}", 1
      assert_select "section.tab-pane#tab-#{TAB_B}", 1
      assert_select "a.tab-link[href='#tab-#{TAB_A}'][id='tablink-#{TAB_A}']", 1
    end
  end
end
