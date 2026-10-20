require "test_helper"

module Web
  # The project page after PR 3 (spec §8): a stats line from what the page already loads, real
  # buttons in the head, Detach as a corner control on smaller tiles, task rows with a state mark
  # and the composer BELOW the list, a build-log composer that opens on demand, and a timeline with
  # the date in its own column. Nothing here adds a query: page_query_budget_test.rb still holds.
  class ProjectPageTest < ActionDispatch::IntegrationTest
    # A PAGE RENDER ENQUEUES (Maker::Previews::ThumbnailMap backfills), and the cases under "What this
    # render paints" read those jobs. Recorded, never run: the :test adapter is what `enqueued_jobs` reads.
    include ActiveJob::TestHelper

    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "pp-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
      @project = @user.maker_projects.create!(name: "Desk Lamp", description: "An articulated lamp.")
      # BOTH FILES LIVE IN THE PROJECT'S FOLDER, not at the library root: the stats line's file
      # count is now Maker::ProjectFolderListing#total (the folder), not maker_file_attachments —
      # an attachment to a node outside the folder is the Linked case, set up separately below so
      # it does not inflate this count.
      folder = project_folder_rows!(@user, @project)
      %w[base.stl shade.3mf].each_with_index do |name, i|
        @user.nodes.create!(node_id: "n-#{i}", name:, kind: "file", parent_node_id: folder.node_id,
                            mtime: 1_000_000_000, size: 10)
        @project.file_attachments.create!(user: @user, node_id: "n-#{i}", role: "model")
      end
      # THE LINKED CASE: attached to this project, but the node lives elsewhere in the library. It
      # is what "1 linked" below is about, and it is also the ONE attachment tile on this page that
      # carries Detach — a plain folder file has nothing to detach (the folder IS its relation).
      @user.nodes.create!(node_id: "n-linked", name: "spare.stl", kind: "file",
                          mtime: 1_000_000_000, size: 10)
      @linked_attachment = @project.file_attachments.create!(user: @user, node_id: "n-linked",
                                                              role: "model")
      @project.tasks.create!(user: @user, title: "Print the base", status: "done", position: 0)
      @project.tasks.create!(user: @user, title: "Wire the LED", status: "todo", position: 1)
      @project.tasks.create!(user: @user, title: "Design the clip", status: "todo", position: 2)
      @project.build_log_entries.create!(user: @user, entry_type: "note", logged_at: 2.days.ago,
                                        body: "<div>First print came out clean.</div>")
      @project.sheets.create!(user: @user, name: "Bill of materials")
    end

    test "the head shows a stats line built from what the page already loaded" do
      get project_path(@project)
      assert_response :success
      assert_select ".project-head .page-title h1", text: "Desk Lamp"
      assert_select ".project-stats", text: /2 files/
      assert_select ".project-stats", text: /1 linked/
      assert_select ".project-stats", text: /1 of 3 tasks done/
      assert_select ".project-stats", text: /1 log entry\b/
      assert_select ".project-stats", text: /1 sheet\b/
    end

    test "the head's actions are buttons, with Archive in the ⋯ menu" do
      get project_path(@project)
      assert_select ".head-actions a.btn[href=?]", edit_project_path(@project), text: "Edit"
      assert_select ".head-actions details.project-menu form[action=?] button.menu-item.danger",
                    project_path(@project), text: "Archive"
      assert_select ".head-actions > form", 0, "no act is a head button any more: they live in the menu"
    end

    # THE HUB'S HEAD (structural redesign §6, slice 6): the cover and the name in one head, a PROJECT
    # eyebrow ABOVE the h1 and never inside it (projects_flow_test.rb pins the h1's exact text), and a
    # ⋯ menu opening on Publish settings. `.page-head` keeps its two slots; template_hygiene_test.rb
    # is the guard for that, this is the guard for what the first slot holds.
    test "the head carries the cover, the PROJECT eyebrow outside the h1, and a ⋯ menu" do
      folder = Maker::ProjectFolderListing.new(@user, @project).folder_id
      @user.nodes.create!(node_id: "n-cover", name: "lamp.png", kind: "file", parent_node_id: folder,
                          size: 1, mtime: 1_000_000_000)
      @project.update!(cover_node_id: "n-cover")

      get project_path(@project)

      assert_select ".page-head.project-head > *", 2
      assert_select ".project-head .page-title" do
        assert_select "> .project-hero img.project-hero-img[src=?]", blob_file_path("n-cover")
        assert_select ".eyebrow", text: "Project"
        assert_select "h1", text: "Desk Lamp"
        assert_select "h1 .eyebrow", 0
      end
      eyebrow, h1 = css_select(".project-head .eyebrow, .project-head h1")
      assert_equal %w[span h1], [ eyebrow&.name, h1&.name ], "the eyebrow comes before the name"
      assert_select ".project-hero", 1, "the cover moved into the head; it is not drawn twice"
      assert_select ".head-actions details.project-menu[data-controller=?]", "menu" do
        assert_select "summary.btn.icon[aria-label=?]", "More actions"
        assert_select ".menu-list > .menu-item:first-child[href=?]", "#publish", text: "Publish settings"
      end
    end

    # THE FILES PANEL'S "RECENTLY CHANGED" ROW (structural redesign §6, slice 6). NINE files in nested
    # folders, so the cap (8) is straddled and the row reaches past the folder's root. THREE ORDERS
    # DISAGREE ON PURPOSE — creation (r1…r9), name (also r1…r9) and recency — so a row ordered by
    # name, by id or oldest-first cannot read the same sequence. A file outside the folder is the
    # newest of all and must not appear: "under the project folder" is the scope.
    test "the Files panel shows the 8 newest files under the folder, newest first, each opening the Library" do
      project = @user.maker_projects.create!(name: "Recent Rig")
      folder = project_folder_rows!(@user, project)
      models = @user.nodes.create!(node_id: "d-r-models", name: "models", kind: "dir", parent_node_id: folder.node_id)
      old = @user.nodes.create!(node_id: "d-r-old", name: "old", kind: "dir", parent_node_id: models.node_id)
      laser = @user.nodes.create!(node_id: "d-r-laser", name: "laser", kind: "dir", parent_node_id: folder.node_id)
      parents = { 1 => folder, 2 => models, 3 => old, 4 => laser, 5 => old, 6 => models, 7 => folder, 8 => laser, 9 => old }
      hours_ago = { 5 => 1, 9 => 2, 1 => 3, 7 => 4, 3 => 5, 8 => 6, 2 => 7, 6 => 8, 4 => 9 }
      (1..9).each do |i|
        node = @user.nodes.create!(node_id: "r#{i}", name: "r#{i}.stl", kind: "file", parent_node_id: parents[i].node_id,
                                   size: 1, mtime: 1_000_000_000)
        node.update_columns(updated_at: hours_ago[i].hours.ago)
      end
      @user.nodes.create!(node_id: "r-outside", name: "r0.stl", kind: "file", size: 1, mtime: 1_000_000_000)

      get project_path(project)

      tiles = css_select("section.attachments-panel .recent-files .attachment-tile")
      assert_equal %w[r5 r9 r1 r7 r3 r8 r2 r6], tiles.map { |t| t.at_css(".grid-name").text.delete_suffix(".stl") }
      assert_select "section.attachments-panel .recent-files .recent-files-head", text: "Recently changed"
      assert_select "section.attachments-panel .recent-files .attachment-tile a[href=?]", file_path("r5")
      assert_select "section.attachments-panel .recent-files .attachment-tile a[href=?]", file_path("r1")
      assert_select ".recent-files .grid-name", { text: "r0.stl", count: 0 }, "a file outside the folder is not recent here"
      assert_select "section.attachments-panel .panel-head a.panel-path[href=?][title=?]",
                    files_path(folder: folder.node_id), "#{Maker::ProjectFolders::ROOT}/#{project.slug}", text: "Open folder →"
    end

    # WHAT THE PAGE KEEPS CLOSED, THE ROW DOES NOT OPEN. A LightBurn rescue copy is folded into the
    # closed Backups group, and LightBurn rewrites it on every save — the newest file in a laser
    # project, every time. A panel the maker hid takes its files off the page; a repository the page
    # browses draws no tiles. All three are newer here than the one file that should show.
    test "the recent row leaves out backups, a hidden panel's files and a browsed repository's" do
      project = folder_panel_project!
      @user.nodes.find_by!(node_id: "f-loose").update_columns(updated_at: 1.day.ago)
      folder = Maker::ProjectFolderListing.new(@user, project).folder_id
      @user.nodes.create!(node_id: "f-bak", name: "sign_backup.lbrn2", kind: "file", parent_node_id: folder,
                          size: 1, mtime: 1_000_000_000)
      project.update!(panels: { "hidden" => [ folder_key("d-models") ] })
      (Maker::ProjectFolderListing.new(@user, project).node_ids - %w[f-loose]).each do |id|
        @user.nodes.find_by!(node_id: id).update_columns(updated_at: 1.minute.ago)
      end
      @user.nodes.find_by!(node_id: "f-main").update_columns(updated_at: 1.minute.ago)

      get project_path(project)

      assert_equal %w[sketch.txt], css_select(".recent-files .grid-name").map(&:text)
    end

    # THE ROW SKIPS WHAT THE PAGE DRAWS NO TILE FOR, AND IT ASKS EACH PANEL'S VIEW, NOT "IS IT A REPOSITORY"
    # (slice 6 review): a plain folder switched to browser view draws no tiles, and a repository nested
    # inside a tiles-view repository panel is a closed browser section. Both leaked into the row while the
    # rule keyed on `repo?`.
    test "the recent row follows each panel's view: a browsed plain folder and a nested repository stay out" do
      project = folder_panel_project!
      nested = @user.nodes.create!(node_id: "d-lib", name: "lib", kind: "dir", parent_node_id: "d-firmware")
      @user.nodes.create!(node_id: "d-lib-git", name: Library::RepoMetadata::DIR_NAME, kind: "dir",
                          parent_node_id: nested.node_id)
      @user.nodes.create!(node_id: "f-lib", name: "lib.c", kind: "file", parent_node_id: nested.node_id,
                          size: 10, mtime: 1_000_000_000)
      project.update!(panels: { "views" => { folder_key("d-firmware") => "tiles", folder_key("d-models") => "browser" } })
      @user.nodes.where(kind: "file").update_all(updated_at: 1.minute.ago)

      get project_path(project)

      names = css_select(".recent-files .grid-name").map(&:text)
      assert_includes names, "main.c", "a tiles-view repository's own files are tiles, so they are recent"
      assert_includes names, "sketch.txt"
      refute_includes names, "lib.c", "a repository nested in a tiles-view panel is a closed browser section"
      refute_includes names, "base.stl", "a plain folder in browser view draws no tiles"
    end

    # DETACH IS THE LINKED ROW'S CONTROL, ONLY. base.stl/shade.3mf are plain folder files now (no
    # tile-meta corner at all — folder_files_do_not_get_detach in project_attachments_test.rb pins
    # that directly); @linked_attachment is the one tile this page renders with a Detach button.
    test "attachment tiles carry Detach as a corner control that keeps its text" do
      get project_path(@project)
      assert_select ".attachments-panel .attachment-tile .tile-meta form[action=?] button.tile-detach",
                    attachment_path(@linked_attachment), text: "Detach"
    end

    test "task rows carry a state mark and the composer sits below the list" do
      get project_path(@project)
      assert_select "#project-tasks .tasks-group.status-done .task-row .task-state.task-state--done", count: 1
      assert_select "#project-tasks .tasks-group.status-todo .task-row .task-state.task-state--todo", count: 2
      children = css_select("#project-tasks > *").map { |el| el["class"].to_s }
      last_group = children.rindex { |c| c.include?("tasks-group") }
      form = children.index { |c| c.include?("task-form") }
      assert form && last_group && form > last_group, "the task form must come after the task groups, got #{children.inspect}"
      assert_select "#project-tasks form.task-form input[type='text'][name='task[title]']"
    end

    test "the build-log composer is a closed details holding the same form" do
      get project_path(@project)
      assert_select ".build-log-panel details.composer:not([open]) > summary", text: "Add entry"
      assert_select ".build-log-panel details.composer form[action=?] lexxy-editor[attachments='false']",
                    project_build_log_entries_path(@project)
      # "Save entry" ON THE SUBMIT, "Add entry" ON THE SUMMARY — they both read "Add entry" until
      # 2026-09-10, two controls 150px apart in one panel naming different actions (§1A.8). Asserted
      # as a PAIR here, because the defect was only visible as one.
      assert_select ".build-log-panel details.composer form input[type='submit'][value='Save entry']"
    end

    test "a log entry puts its date in the first column and its body in the second" do
      get project_path(@project)
      assert_select ".log-timeline .log-entry > time.entry-time", count: 1
      assert_select ".log-timeline .log-entry > .entry-main .entry-body", text: /First print came out clean/
      # THE ENTRY'S ACTIONS ARE BEHIND A MENU SINCE 2026-09-10 (UI-cohesion slice 5): three controls
      # per entry meant eighteen in a six-entry panel. The head still holds them, one level in.
      assert_select ".log-timeline .log-entry > .entry-main .entry-head details.menu > summary", count: 1
      assert_select ".log-timeline .log-entry .entry-head .menu-list form button", text: "Delete entry"
      # ALL THREE ARE IN IT, not just the one that used to be up here — a menu that swallowed an
      # action would be the "control that quietly stopped existing" this sweep keeps finding.
      assert_select ".log-timeline .log-entry .entry-head .menu-list a", text: "Add existing photo"
      assert_select ".log-timeline .log-entry .entry-head .menu-list .upload-btn", count: 1
    end

    # --- tags (stage 2, S2-5) ----------------------------------------------------------------

    test "an untagged project shows no chip row" do
      get project_path(@project)
      assert_select ".tag-chips", 0
    end

    test "tag chips render on the project page and link to the tag page" do
      tagged = @user.maker_projects.create!(name: "Tagged Lamp", tag_list: "laser, firmware")
      get project_path(tagged)
      assert_select ".tag-chips a.tag-chip[href=?]", tag_path("firmware"), text: "firmware"
      assert_select ".tag-chips a.tag-chip[href=?]", tag_path("laser"), text: "laser"
    end

    test "the form carries a tag_list field" do
      get edit_project_path(@project)
      assert_select "input[name='project[tag_list]']"
    end

    test "update with tag_list writes two tags and the page renders their chips" do
      patch project_path(@project), params: { project: { name: @project.name, tag_list: "laser, firmware" } }
      assert_redirected_to project_path(@project)
      assert_equal %w[firmware laser], @project.reload.tag_list.split(", ").sort

      get project_path(@project)
      assert_select ".tag-chips a.tag-chip", 2
    end

    # THE NEGATIVE WEARS A DIFFERENT TAG, not none: an untagged row is excluded by the inner join
    # alone, so only a differently-tagged sibling proves the scope matches the NAME (review, S2-5).
    test "the index shows tag filter chips and ?tag= narrows, excluding a project wearing another tag" do
      tagged = @user.maker_projects.create!(name: "Laser Sign", tag_list: "laser")
      untagged = @user.maker_projects.create!(name: "Firmware Board", tag_list: "firmware")

      get projects_path
      assert_select ".projects-toolbar a.filter.chip", text: "laser"

      get projects_path(tag: "laser")
      assert_select "a.project-card[href=?]", project_path(tagged)
      assert_select "a.project-card[href=?]", project_path(untagged), false
    end

    test "a user with no project tags sees no filter chips" do
      # THE SUBJECT IS THE FILTER ROW, NOT THE TOOLBAR — and the two stopped being the same thing
      # in UI-cohesion slice 4. The toolbar now also carries the item count and the sort, which a
      # project list has whether or not it has tags to filter by (Projects was the one list page
      # with neither). What must still not render for a tagless user is a chip row offering to
      # filter by nothing, so that is what this asserts.
      get projects_path
      assert_select ".projects-toolbar a.filter.chip", count: 0
    end

    # Ground rules for this task: ProjectsController#index also gained a `?q=` filter (one line,
    # the Files LOWER(name) LIKE ... ESCAPE idiom) so SearchController's "See all" link into
    # projects_path(q:) narrows -- Task B's own search_test.rb exercises that link end to end;
    # this is the controller-level check that the filter itself works in isolation.
    test "?q= narrows the index by name" do
      matched = @user.maker_projects.create!(name: "Desk Lamp Mk2")
      other = @user.maker_projects.create!(name: "Bare Shelf")

      get projects_path(q: "lamp")
      assert_select "a.project-card[href=?]", project_path(matched)
      assert_select "a.project-card[href=?]", project_path(other), false
    end

    # --- On-demand panels (structural redesign §6, slice 6) ---------------------------------------
    #
    # AN EMPTY Build log, Tasks, BOM, Wiring, Releases or Sheets IS ABSENT FROM THE NORMAL PAGE — not
    # quiet — and "+ Add panel" opens one for this visit with ?add=<key>, where it renders quiet (S4-1's
    # heading and one add control) with its composer. Decided in ProjectsController#show alone
    # (design-system.md rule 14). `@project` in `setup` is populated, so these build their own.
    ADD_MENU = { "build_log" => [ "Build log", "project-build-log" ], "tasks" => [ "Tasks", "project-tasks" ],
                 "bom" => [ "Bill of materials", "project-bom" ], "wiring" => [ "Wiring", "project-wiring" ],
                 "releases" => [ "Releases", "project-releases" ], "sheets" => [ "Sheets", "project-sheets" ] }.freeze

    def add_menu_links
      css_select(".head-actions details.add-panel .menu-list a.menu-item").map { |a| [ a.text.strip, a["href"] ] }
    end

    test "a fresh project shows Files and Publish, and offers the empty panels to add" do
      fresh = @user.maker_projects.create!(name: "Blank")

      get project_path(fresh)

      assert_response :success
      %w[build-log tasks bom wiring releases sheets].each do |name|
        assert_select "section.#{name}-panel", count: 0
      end
      assert_select "section.attachments-panel"
      assert_select "section.publish-panel#publish"
      assert_select ".head-actions details.add-panel .menu-list a.menu-item[href=?]",
                    project_path(fresh, add: "tasks", anchor: "project-tasks"), text: "Tasks"
      # EVERY ABSENT PANEL, IN ON_DEMAND ORDER, EACH TO ITS OWN ?add= AND ITS OWN ANCHOR — the whole
      # list rather than one link, so a key the menu drops or an anchor it misspells is a failure here.
      assert_equal(ADD_MENU.map { |key, (label, anchor)| [ label, project_path(fresh, add: key, anchor:) ] },
                   add_menu_links)
      # Between Customise page and the ⋯ menu, inside .head-actions: the head stays two slots.
      actions = css_select(".page-head > .head-actions > *").map { |el| el["class"].to_s }
      assert_operator actions.index { |c| c.include?("customise-link") }, :<, actions.index { |c| c.include?("add-panel") }
      assert_operator actions.index { |c| c.include?("add-panel") }, :<, actions.index { |c| c.include?("project-menu") }
    end

    test "?add= opens one empty panel, quiet, with its composer, and nothing else" do
      fresh = @user.maker_projects.create!(name: "Blank")

      get project_path(fresh, add: "tasks")

      assert_select "section.tasks-panel.panel--quiet form.task-form"
      # THE TURBO TARGET IS ON THE PAGE, so the first add's stream replace has something to land on.
      assert_select "#project-tasks", count: 1
      assert_select "#project-tasks .tasks-group", count: 0
      assert_select "section.build-log-panel", count: 0
      # The open panel leaves the menu; the other five stay in it.
      assert_select ".add-panel a.menu-item", text: "Tasks", count: 0
      assert_equal 5, add_menu_links.size
    end

    # EACH LINK'S ANCHOR IS THE ID OF THE PANEL IT OPENS (ProjectsHelper::PANEL_ANCHORS), and each
    # opened panel is S4-1's quiet panel: its heading and one add control, no zero-count group, no
    # empty sentence. One request per key, because ?add= opens exactly one.
    test "every add link lands on the quiet panel it opens" do
      fresh = @user.maker_projects.create!(name: "Blank")

      ADD_MENU.each do |key, (_label, anchor)|
        get project_path(fresh, add: key)
        assert_select "section.panel.panel--quiet[id=?]", anchor, 1, "?add=#{key} must render ##{anchor}, quiet"
        assert_select "p.muted", text: /No (entries|connections|releases|sheets) yet/, count: 0
      end
      get project_path(fresh, add: "build_log")
      assert_select ".build-log-panel details.composer > summary", text: "Add entry"
    end

    test "a panel with a row stays without ?add=, and drops out of the add menu" do
      fresh = @user.maker_projects.create!(name: "Blank")
      fresh.tasks.create!(user: @user, title: "Cut the base")

      get project_path(fresh)

      assert_select "section.tasks-panel"
      assert_select ".add-panel a.menu-item", text: "Tasks", count: 0
      assert_select ".add-panel a.menu-item", text: "Build log", count: 1
    end

    test "a panel the maker hid stays hidden even with ?add=, and is not offered" do
      fresh = @user.maker_projects.create!(name: "Blank")
      fresh.update!(panels: { "hidden" => %w[tasks] })

      get project_path(fresh, add: "tasks")

      assert_select "section.tasks-panel", count: 0
      assert_select ".add-panel a.menu-item", text: "Tasks", count: 0
      assert_select ".add-panel a.menu-item", text: "Build log", count: 1
    end

    test "?add= with an unknown key is ignored" do
      fresh = @user.maker_projects.create!(name: "Blank")

      get project_path(fresh, add: "publish")
      assert_response :success
      assert_equal 6, add_menu_links.size, "a key that is not on demand opens nothing and closes nothing"
      get "#{project_path(fresh)}?add[]=tasks"
      assert_response :success
      assert_select "section.tasks-panel", count: 0
      get "#{project_path(fresh)}?add[tasks]=1"
      assert_response :success
      assert_select "section.tasks-panel", count: 0
    end

    # NOTHING PERSISTS: the column ?add= might have written is the one Maker::LayoutDocument's Save
    # owns, and a panel opened and left empty is gone on the next visit.
    test "?add= writes nothing, and the panel is gone again on the next visit" do
      fresh = @user.maker_projects.create!(name: "Blank")

      get project_path(fresh, add: "wiring")
      assert_select "section.wiring-panel", 1
      assert_nil fresh.reload[:panels]

      get project_path(fresh)
      assert_select "section.wiring-panel", count: 0
    end

    # THE EDITOR SHOWS EVERY PANEL (@editing skips all of this), so an empty panel can still be
    # arranged, and the editor offers no "+ Add panel": there is nothing absent to add there.
    test "the editor still shows every empty panel and offers no add menu" do
      fresh = @user.maker_projects.create!(name: "Blank")

      get edit_layout_project_path(fresh)

      %w[build-log tasks bom wiring releases sheets].each do |name|
        assert_select "div.panel-slot[data-hidden=false] section.#{name}-panel.panel--quiet", 1, "#{name} in the editor"
      end
      assert_select "details.add-panel", count: 0
    end

    test "a quiet BOM panel keeps its revision badge: the hidden span is a count, and rev is not one" do
      project = @user.maker_projects.create!(name: "Rev")
      project.boms.create!(user: @user)

      get project_path(project, add: "bom")

      assert_select "section.bom-panel.panel--quiet .panel-head .bom-rev", text: /rev \d+/
    end

    test "a populated panel is not quiet" do
      project = @user.maker_projects.create!(name: "Busy")
      project.tasks.create!(user: @user, title: "cut")
      project.build_log_entries.create!(user: @user, body: "glued", logged_at: Time.current)

      get project_path(project)

      assert_select "section.tasks-panel.panel--quiet", count: 0
      assert_select "section.build-log-panel.panel--quiet", count: 0
      # ONE GROUP, NOT THREE, SINCE 2026-09-10. The fixture creates a single todo, and an empty
      # group is suppressed now — `DOING (0)` and `DONE (0)` beneath one real task is the same
      # "(0) is not information" argument the panel-level quiet rule already makes, one level down.
      # What this test is about is that a POPULATED panel is not quiet, and that still holds.
      assert_select "#project-tasks .tasks-group", count: 1
      assert_select "#project-tasks .tasks-group.status-todo", count: 1
    end

    # THE HERO (stage 4, S4-1): the cover on the project's OWN page. `cover_node_id` is a raw
    # column nothing validates (Maker::Project's own comment), so the third case is the one that
    # matters — a tombstoned or never-live cover must render NOTHING rather than a poll cell that
    # spins for ever, the model page's `_hero_poster` rule restated here.
    test "the hero shows an image cover inline, a model cover as a thumbnail cell, and nothing for a dead or absent cover" do
      project = @user.maker_projects.create!(name: "Hero")
      folder = project_folder_rows!(@user, project)
      @user.nodes.create!(node_id: "cover-png", name: "lid.png", kind: "file", parent_node_id: folder.node_id,
                          size: 1, mtime: 1_700_000_000_000_000_000)
      @user.nodes.create!(node_id: "cover-stl", name: "part.stl", kind: "file", parent_node_id: folder.node_id,
                          size: 1, mtime: 1_700_000_000_000_000_000)

      project.update!(cover_node_id: "cover-png")
      get project_path(project)
      assert_select ".project-hero img.project-hero-img[src=?]", blob_file_path("cover-png")
      assert_select ".project-hero a[href=?]", file_path("cover-png")

      project.update!(cover_node_id: "cover-stl")
      get project_path(project)
      assert_select ".project-hero .project-hero-thumb[data-node-id=?]", "cover-stl"
      assert_select ".project-hero img.project-hero-img", count: 0

      project.update!(cover_node_id: "gone")
      get project_path(project)
      assert_select ".project-hero", count: 0
    end

    # AN IMAGE BY ROLE THAT NO BROWSER SHOWS INLINE (tinkerex#285): a `.heic` cover takes the
    # THUMBNAIL branch, never the raw bytes — the role-keyed check it replaces rendered a broken
    # picture. Red when the hero asks the role again.
    test "a HEIC cover is a thumbnail cell, never inline bytes" do
      project = @user.maker_projects.create!(name: "Phone")
      folder = project_folder_rows!(@user, project)
      @user.nodes.create!(node_id: "cover-heic", name: "IMG_0001.heic", kind: "file",
                          parent_node_id: folder.node_id, size: 1, mtime: 1_700_000_000_000_000_000)
      project.update!(cover_node_id: "cover-heic")

      get project_path(project)

      assert_select ".project-hero .project-hero-thumb[data-node-id=?]", "cover-heic"
      assert_select ".project-hero img.project-hero-img", { count: 0 },
                    "a .heic must not be embedded as raw bytes"
    end

    # PHOTOS (stage 4, S4-1): the public page's gallery, on the maker's own page, over the ONE
    # definition (Maker::ProjectPhotos) both pages read. `p-a` is BOTH a folder image and an entry
    # photo and must be counted once; `p-z` lives outside the folder, which is where the upload
    # door normally puts an entry photo.
    test "the photos panel shows folder images and entry photos once each, and is absent with none" do
      project = @user.maker_projects.create!(name: "Shots")
      get project_path(project)
      assert_select "section.photos-panel", count: 0

      folder = project_folder_rows!(@user, project)
      @user.nodes.create!(node_id: "p-b", name: "b.png", kind: "file", parent_node_id: folder.node_id, size: 1, mtime: 1_700_000_000_000_000_000)
      @user.nodes.create!(node_id: "p-a", name: "a.jpg", kind: "file", parent_node_id: folder.node_id, size: 1, mtime: 1_700_000_000_000_000_000)
      @user.nodes.create!(node_id: "p-z", name: "z.png", kind: "file", size: 1, mtime: 1_700_000_000_000_000_000)
      entry = project.build_log_entries.create!(user: @user, body: "glued", logged_at: Time.current)
      entry.file_attachments.create!(user: @user, node_id: "p-z", role: "image")
      entry.file_attachments.create!(user: @user, node_id: "p-a", role: "image")

      get project_path(project)
      assert_select "section.photos-panel .photo-cell", count: 3
      assert_select "section.photos-panel .photo-cell[href=?]", file_path("p-z")
      assert_select "section.photos-panel .panel-head .mono", text: "3 photos"
    end

    # STAGE 4, S4-7 (story 6.5): the panel list is data, and `other` — the column default — is
    # exactly the page this project had before the column existed.
    # THE LOOP RENDERS WHAT THE HARD-CODED LIST RENDERED, IN THE SAME ORDER. Asserted as a
    # SUBSEQUENCE of the canonical list rather than as an equal array: which panels this fixture
    # reaches depends on what it seeds (no image, so no Photos; no KiCad, so no Schematics), and a
    # test that had to enumerate that would go red whenever an unrelated fixture line changed.
    # What must hold is that nothing is out of order and nothing unknown appears.
    test "an other project renders its panels in the canonical order" do
      get project_path(@project)

      assert_response :success
      expected = Maker::Project::PANELS.map { |k| "#{k.tr("_", "-")}-panel" }
      rendered = css_select("div.project-panels > div.panel-slot > section.panel")
                 .map { |s| s["class"].split.find { |c| c.end_with?("-panel") } }

      assert_equal rendered, expected & rendered,
                   "the loop rendered #{rendered.inspect}, which is not in PANELS order"
      assert_includes rendered, "attachments-panel"
      assert_includes rendered, "build-log-panel"
      assert_includes rendered, "tasks-panel"
      assert_includes rendered, "sheets-panel"
    end

    # ALL THREE HIDDEN PANELS HOLD A ROW, so each would render if the layout let it (slice 6): an
    # empty BOM or Wiring is absent on its own now, and a count of 0 would pass over nothing.
    test "a hidden panel is not rendered at all — not quiet, absent" do
      @project.boms.create!(user: @user).lines.create!(user: @user, part_name: "M3 screw", quantity: 4, unit: "each")
      @project.connections.create!(user: @user, from_label: "Driver", to_label: "Motor")
      get project_path(@project)
      assert_select "section.bom-panel", 1, "the populated arm, so the assertions below are a CHANGE"
      assert_select "section.wiring-panel", 1
      @project.update!(panels: { "hidden" => %w[tasks bom wiring] })

      get project_path(@project)

      assert_select "section.tasks-panel", count: 0
      assert_select "section.bom-panel", count: 0
      assert_select "section.wiring-panel", count: 0
      assert_select "section.build-log-panel", 1, "an unhidden panel is untouched"
      assert_select "section.attachments-panel", 1
    end

    # HIDDEN AND EMPTY ARE TWO QUESTIONS (the overview's quiet-panel contract; slice 6). An empty
    # panel that is NOT hidden is absent from the normal page but OFFERED by "+ Add panel", and
    # ?add= opens it quiet — S4-1's state. A hidden one is neither offered nor opened, empty or
    # full. Both halves in one test, because it is the pair that must not collapse.
    test "hidden and empty are different states" do
      empty = @user.maker_projects.create!(name: "Blank")

      get project_path(empty)
      assert_select ".add-panel a.menu-item", text: "Wiring", count: 1
      get project_path(empty, add: "wiring")
      assert_select "section.wiring-panel.panel--quiet", 1

      empty.update!(panels: { "hidden" => %w[wiring] })
      get project_path(empty, add: "wiring")
      assert_select "section.wiring-panel", count: 0
      assert_select ".add-panel a.menu-item", text: "Wiring", count: 0
    end

    test "a stored order reorders the DOM, and a preset does too" do
      @project.update!(panels: { "order" => %w[tasks build_log] })

      get project_path(@project)
      panels = css_select("div.project-panels > div.panel-slot > section.panel").map { |s| s["class"] }
      assert_operator panels.index { |c| c.include?("tasks-panel") }, :<,
                      panels.index { |c| c.include?("build-log-panel") },
                      "the stored order must move Tasks above Build log"

      @project.update!(panels: nil, kind: "electronics")
      @project.connections.create!(user: @user, from_label: "A", to_label: "B")
      get project_path(@project)
      panels = css_select("div.project-panels > div.panel-slot > section.panel").map { |s| s["class"] }
      assert_operator panels.index { |c| c.include?("wiring-panel") }, :<,
                      panels.index { |c| c.include?("build-log-panel") },
                      "electronics lifts Wiring above the build log (story 6.2)"
    end

    # THE THREE PANELS NOBODY MAY HIDE (Maker::ProjectKind::ALWAYS). Driven through a real request
    # rather than asserted on the constant, because the thing that must hold is what the PAGE does
    # with a column someone wrote by hand.
    test "Files stays on the page however hard the column tries to hide it" do
      @project.update!(panels: { "hidden" => Maker::Project::PANELS })

      get project_path(@project)

      assert_select "section.attachments-panel", 1
    end

    # --- Folder panels (2026-09-08; spec decisions 1, 3, 4, 6) ----------------------------------
    #
    # THREE SHAPES, ONE FIXTURE: a plain subfolder holding a NESTED one, a working tree (a `.git`
    # marker child), and an empty folder. Every row is a bare `nodes.create!` under
    # `project_folder_rows!` — no `ensure_library_folder!`, no port write — so this reads the same
    # on share, s3 and chunk_remote.
    def folder_panel_project!
      project = @user.maker_projects.create!(name: "Rig")
      folder = project_folder_rows!(@user, project)
      dir = lambda { |id, name, parent| @user.nodes.create!(node_id: id, name:, kind: "dir", parent_node_id: parent) }
      models = dir.call("d-models", "models", folder.node_id)
      firmware = dir.call("d-firmware", "firmware", folder.node_id)
      dir.call("d-notes", "notes", folder.node_id)
      old = dir.call("d-old", "old", models.node_id)
      # THE MARKER IS WHAT MAKES IT A WORKING TREE (Library::RepoMetadata) — and it is a dot-dir, so
      # the walk skips the entry itself and only the flag survives.
      dir.call("d-git", Library::RepoMetadata::DIR_NAME, firmware.node_id)
      # `f-loose` SITS AT THE FOLDER'S OWN ROOT, and it is load-bearing rather than decoration: the
      # Files panel renders its groups only when it HAS one, so without a loose file the panel is a
      # heading and the "Files renders no subfolder section" assertion below passes over an empty
      # element (found by mutation-checking — putting the section render back stayed green).
      { "f-base" => [ "base.stl", models ], "f-shade" => [ "shade.stl", models ],
        "f-mk1" => [ "mk1.stl", old ], "f-main" => [ "main.c", firmware ],
        "f-loose" => [ "sketch.txt", folder ] }.each do |node_id, (name, parent)|
        @user.nodes.create!(node_id:, name:, kind: "file", parent_node_id: parent.node_id,
                            size: 10, mtime: 1_000_000_000)
      end
      project
    end

    def folder_key(node_id) = Maker::ProjectKind.folder_key(node_id)

    def panel_ids = css_select("div.project-panels > div.panel-slot > section.panel").map { |s| s["id"].to_s }

    def panel_classes = css_select("div.project-panels > div.panel-slot > section.panel").map { |s| s["class"].to_s }

    # THE HEADLINE: a panel per DEPTH-ONE subfolder, immediately after Files, in disk order — the
    # placement Maker::ProjectKind's after-Files rule exists for, driven through a real request.
    test "each depth-one subfolder is its own panel, after Files, in disk order, named and counted" do
      get project_path(folder_panel_project!)

      assert_response :success
      files_at = panel_classes.index { |c| c.include?("attachments-panel") }
      folders = panel_ids.select { |id| id.start_with?("folder:") }
      assert_equal %w[folder:d-firmware folder:d-models folder:d-notes], folders
      assert_equal files_at + 1, panel_ids.index("folder:d-firmware"), "folder panels start right after Files"

      assert_select "section.folder-panel[id=?]", folder_key("d-models") do
        assert_select ".panel-head h2", text: "models"
        # THE WHOLE SUBTREE: two of its own plus old/mk1.stl. A direct-child count would read
        # "2 files" over a panel that renders three.
        assert_select ".panel-head .mono.muted", text: "3 files"
        assert_select ".panel-head a.panel-path[href=?]", files_path(folder: "d-models")
      end
      assert_select "section.folder-panel[id=?] .panel-head .mono.muted", folder_key("d-firmware"), text: "1 file"
    end

    # THE DEFAULT VIEW IS WHAT THE PANEL IS (Maker::ProjectKind.default_view): a working tree opens
    # in the Finder browser, everything else in tiles. Both halves in one test, because the pair is
    # what "defaults reproduce today's page" means.
    # A REPOSITORY PANEL OFF THE BROWSER RENDERS TILES, SO ITS FILES MUST REACH THE THUMBNAIL MAP
    # (found in review): the map's repo exclusion predates folder panels, and a tile it never
    # backfilled spins for 41 polls and then reads "Preview not supported" over a file that renders
    # fine. The default browser view keeps the exclusion — a repository's files must not cost a
    # render job each from a page that shows none of them.
    test "a repository panel switched to tiles gets its thumbnails backfilled; in the browser it does not" do
      project = folder_panel_project!
      # BOTH CONTENT COLUMNS, or the map has no token to key a row on and skips the node in every
      # view — which would make both halves of this test pass for nothing (§14a: content_token is
      # content_hash on share/s3 and current_version_id on chunk_remote).
      @user.nodes.create!(node_id: "f-case", name: "case.stl", kind: "file", parent_node_id: "d-firmware",
                          size: 10, mtime: 1_000_000_000, content_hash: "h-case", current_version_id: "v-case")

      get project_path(project)
      assert_not Maker::Preview.exists?(user: @user, node_id: "f-case"),
                 "the browser view shows no tile for it, so nothing is enqueued"

      # THE RECENT ROW ASKS THE SAME QUESTION (slice 6): case.stl is the newest file in the folder,
      # and it is in the row exactly when the repository draws tiles.
      assert_select ".recent-files .grid-name", { text: "case.stl", count: 0 }, "a browsed repository draws no recent tile"

      project.update!(panels: { "views" => { "folder:d-firmware" => "tiles" } })
      get project_path(project)
      assert_select "section.folder-panel[id='folder:d-firmware'] .attachment-tile", { minimum: 1 }
      assert_select ".recent-files .grid-name", { text: "case.stl", count: 1 }, "a repository in tiles is a folder like any other"
      assert Maker::Preview.exists?(user: @user, node_id: "f-case"),
             "a tile on the page must have a row the poll can resolve"
    end

    # --- What this render paints is what it backfills (F-S15-1, 2026-10-19) ---------------------
    #
    # ONE ANSWER, TWO READERS. `ThumbnailMap.for` does not merely look: it BACKFILLS, a preview row
    # and a render job for every id it is handed that has none. So the page's union must hold the
    # ids some surface on THIS render paints, no more and no fewer. The recent row and the union used
    # to answer "which subfolders draw no file cells" separately, the union keyed on `repo?`, and the
    # two disagreed in four reachable cases. Three of them spent render jobs on tiles nobody drew
    # (a hidden panel, a browsed plain folder, a repository nested in a tiles-view one). The fourth
    # never backfilled an image the Photos panel paints, which is permanent on chunk_remote, where
    # nothing but a backfill creates a row.
    #
    # EVERY CASE CARRIES A CONTROL THAT DOES BACKFILL, or a page whose thumbnail path stopped running
    # altogether would pass each refutation for nothing.

    # A FILE THE THUMBNAIL PATH WILL REALLY ACT ON: a name a renderer claims, and BOTH content
    # columns (content_hash is share's and s3's token, current_version_id chunk_remote's; §14a).
    # Without a token the map skips the node whatever the page paints.
    def previewable!(node_id, name, parent)
      @user.nodes.create!(node_id:, name:, kind: "file", parent_node_id: parent, size: 10,
                          mtime: 1_000_000_000, content_hash: "h-#{node_id}", current_version_id: "v-#{node_id}")
      node_id
    end

    def preview_row(node_id) = @user.maker_previews.find_by(node_id:, kind: "thumbnail")

    # THE ROW AND ITS JOB. A backfill is `Enqueue.call`, which saves the pending row and enqueues its
    # render together; asking for the job as well makes "it gets a thumbnail job" the assertion
    # rather than an inference from the row.
    def enqueued_for?(row)
      !row.nil? && enqueued_jobs.any? { |j| j[:job] == Maker::GeneratePreviewJob && j[:args].first == row.id }
    end

    # CASES (a) AND (b). The images are the second control and the reason the folder is not simply
    # dropped from the union whole: the Photos panel (always shown, Maker::ProjectKind::ALWAYS)
    # paints every image in the folder at any depth, a hidden panel's and a browsed one's included.
    test "a hidden or browsed folder panel backfills no tile it does not draw, and still backfills its photos" do
      project = folder_panel_project!
      loose = previewable!("f-lamp", "lamp.stl", project.folder_node_id)
      hidden = previewable!("f-bracket", "bracket.stl", "d-models")
      hidden_photo = previewable!("f-bench", "bench.jpg", "d-models")
      browsed = previewable!("f-clip", "clip.stl", "d-notes")
      browsed_photo = previewable!("f-desk", "desk.jpg", "d-notes")
      project.update!(panels: { "hidden" => [ folder_key("d-models") ],
                                "views" => { folder_key("d-notes") => "browser" } })

      get project_path(project)

      assert_response :success
      # WHAT THIS RENDER DRAWS, read off the page, so the job assertions below are about it.
      assert_select ".attachment-tile .grid-name", { text: "bracket.stl", count: 0 }
      assert_select "section.folder-panel[id=?] .repo-browser", folder_key("d-notes"), 1
      assert_select ".attachment-tile .grid-name", { text: "clip.stl", count: 0 }
      assert_select ".photos-panel .photo-cell[title=?]", "bench.jpg"
      assert_select ".photos-panel .photo-cell[title=?]", "desk.jpg"

      assert enqueued_for?(preview_row(loose)), "control: a loose tile must still backfill"
      assert_nil preview_row(hidden), "a hidden folder panel is absent from the page, so its files cost no render job"
      assert_nil preview_row(browsed), "a plain folder in the browser view draws no tiles, so its files cost no render job"
      assert enqueued_for?(preview_row(hidden_photo)), "the Photos panel paints a hidden panel's image, so it backfills"
      assert enqueued_for?(preview_row(browsed_photo)), "the Photos panel paints a browsed folder's image, so it backfills"
    end

    # CASE (c). The tiles-view panel draws its OWN files as tiles, but a repository nested inside it is
    # a closed browser section (projects/_file_tree_section). The union used to take the outer panel's
    # whole subtree, so the nested repository's files were backfilled for no tile at all.
    test "a repository nested in a tiles-view repository panel backfills nothing; the panel's own tiles do" do
      project = folder_panel_project!
      own = previewable!("f-case", "case.stl", "d-firmware")
      @user.nodes.create!(node_id: "d-lib", name: "lib", kind: "dir", parent_node_id: "d-firmware")
      @user.nodes.create!(node_id: "d-lib-git", name: Library::RepoMetadata::DIR_NAME, kind: "dir",
                          parent_node_id: "d-lib")
      nested = previewable!("f-gear", "gear.stl", "d-lib")
      project.update!(panels: { "views" => { folder_key("d-firmware") => "tiles" } })

      get project_path(project)

      assert_response :success
      assert_select "section.folder-panel[id=?] .attachment-tile .grid-name", folder_key("d-firmware"), text: "case.stl"
      assert_select ".attachment-tile .grid-name", { text: "gear.stl", count: 0 }
      assert_select ".file-tree-section .repo-browser[data-filebrowser-root-value=?]", "d-lib"

      assert enqueued_for?(preview_row(own)), "control: the tiles-view panel's own tile backfills"
      assert_nil preview_row(nested), "a repository nested in a tiles-view panel is a closed browser section with no tiles"
    end

    # CASE (d), THE ONE THAT NEVER HEALED. A repository opens in the browser by default, so its files
    # draw no tiles, but the Photos panel still paints its images. The union subtracted every file
    # beneath a repository and gave Photos no term of its own, so the image's cell spun its polls and
    # ended as a badge. The repository's other file is the negative control: Photos paints images,
    # and only images, so the photo term must not bring the rest of the repository back in.
    test "an image inside a browsed repository gets a thumbnail job, because the Photos panel paints it" do
      project = folder_panel_project!
      board = previewable!("f-board", "board.jpg", "d-firmware")
      other = previewable!("f-case", "case.stl", "d-firmware")

      get project_path(project)

      assert_response :success
      assert_select "section.folder-panel[id=?] .repo-browser", folder_key("d-firmware"), 1
      assert_select ".attachment-tile .grid-name", { text: "board.jpg", count: 0 }
      assert_select ".photos-panel .photo-cell[title=?]", "board.jpg"

      assert enqueued_for?(preview_row(board)),
             "the Photos panel paints this image, so the page must backfill it: nothing else will on chunk_remote"
      assert_nil preview_row(other), "the repository's non-image file is drawn nowhere, so it costs no render job"
    end

    # THE EDITOR PAINTS A HIDDEN PANEL: the loop there is `order`, and a hidden folder panel renders
    # ghosted WITH its tiles (projects/_panel_slot). So on that render its files are tiles like any
    # other, and they backfill and appear on the recent row. That is the "on this render" reading of
    # #dirs_without_tiles, and the RECENT-ROW half is the owner's call (F-S15-1): the alternative is
    # dropping `!@editing &&` from that method, which also takes the ghost's tiles out of the union.
    test "in the editor a hidden folder panel is drawn ghosted with its tiles, so they backfill and are recent" do
      project = folder_panel_project!
      bracket = previewable!("f-bracket", "bracket.stl", "d-models")
      project.update!(panels: { "hidden" => [ folder_key("d-models") ] })

      get edit_layout_project_path(project)

      assert_response :success
      assert_select "div.panel-slot.panel-slot--hidden[data-key=?] .attachment-tile .grid-name",
                    folder_key("d-models"), text: "bracket.stl"
      assert enqueued_for?(preview_row(bracket)), "a ghosted tile is drawn on this render, so it needs a row the poll can resolve"
      assert_includes css_select(".recent-files .grid-name").map(&:text), "bracket.stl",
                      "on the editor's render the hidden panel draws its tiles, so its files are recent there too"
    end

    test "the Files panel carries the anchor its own view toggle redirects to" do
      project = folder_panel_project!
      get project_path(project)
      assert_select "section.attachments-panel#attachments", count: 1
      assert_select "section.attachments-panel .view-toggle form[action=?]", project_panels_path(project)
    end

    test "a repo folder opens in the browser and a plain one in tiles" do
      get project_path(folder_panel_project!)

      assert_select "section.folder-panel[id=?]", folder_key("d-firmware") do
        assert_select ".repo-browser[data-controller=?]", "filebrowser"
        assert_select ".repo-browser[data-filebrowser-root-value=?]", "d-firmware"
        assert_select ".attachments-grid", count: 0
      end
      # `> div > .attachments-grid >` IS THE PANEL'S OWN GRID. The nested old/ section renders its
      # own grid inside this panel, so an unanchored `.attachment-tile` count here answers 3 and
      # would pass just as happily if the panel drew the whole subtree flat.
      assert_select "section.folder-panel[id=?] > div > .attachments-grid > .attachment-tile",
                    folder_key("d-models"), 2
      assert_select "section.folder-panel[id=?] .repo-browser", folder_key("d-models"), count: 0
    end

    # QUIET, NOT OMITTED (S4-1's rule): the maker put this folder in the layout and it is a real
    # folder on disk. Omitting an empty panel is the VISITOR's page's answer, not this one's.
    test "an empty folder panel is quiet: its heading and one sentence" do
      get project_path(folder_panel_project!)

      assert_select "section.folder-panel.panel--quiet[id=?]", folder_key("d-notes") do
        assert_select ".panel-head h2", text: "notes"
        assert_select "p.muted", text: "Empty folder."
        assert_select ".attachments-grid", count: 0
      end
      assert_select "section.folder-panel.panel--quiet[id=?]", folder_key("d-models"), count: 0
    end

    # DEPTH ONE IS THE WHOLE RULE (spec decision 3). `models/old` renders INSIDE the models panel
    # as the nested section it has always been, and its key reaches neither the page nor the layout.
    test "a nested folder is a section inside its parent's panel, never a panel" do
      project = folder_panel_project!

      get project_path(project)

      assert_select "section.folder-panel[id=?]", folder_key("d-old"), count: 0
      assert_select "section.folder-panel[id=?]", folder_key("d-models") do
        assert_select ".file-tree-section details summary", text: /old \(1\)/
        assert_select ".file-tree-section .attachment-tile .grid-name", text: "mk1.stl"
      end
      refute_includes project.reload.panel_layout(folders: [ [ "d-models", false ] ]).order, folder_key("d-old")
    end

    # THE FILES PANEL IS THE FOLDER'S ROOT NOW (spec decision 4). The `file_tree_section` collection
    # render is gone from it; leaving it in would draw every folder twice, once as a section and
    # once as a panel.
    test "the Files panel keeps the root and renders no subfolder section" do
      get project_path(folder_panel_project!)

      assert_select "section.attachments-panel .attachment-group-head", text: /Loose \(1\)/
      assert_select "section.attachments-panel .attachment-tile .grid-name", text: "sketch.txt"
      assert_select "section.attachments-panel .file-tree-section", count: 0
      # THE GROUPS' TILES, NOT THE RECENT ROW'S: Recently changed reaches into every subfolder by
      # design (slice 6), so what this pins is that no GROUP below it draws a subfolder.
      assert_select "section.attachments-panel .attachment-group .attachment-tile", { count: 1 },
                    "only the loose file — a subfolder's files belong to its own panel"
      assert_select ".file-tree-section", 1, "only the nested old/ section is left, inside models"
    end

    # A FOLDER MOVES LIKE ANY OTHER PANEL, above the build log if the maker says so — which is the
    # first half of "a first-class member of the chooser" (spec decision 1).
    test "a stored order lifts a folder panel above the build log" do
      project = folder_panel_project!
      # A ROW, so the build log is on the page to be ordered against (slice 6: empty, it is absent).
      project.build_log_entries.create!(user: @user, body: "glued", logged_at: Time.current)
      project.update!(panels: { "order" => [ "attachments", folder_key("d-firmware"), "build_log" ] })

      get project_path(project)

      classes = panel_classes
      assert_operator panel_ids.index("folder:d-firmware"), :<,
                      classes.index { |c| c.include?("build-log-panel") },
                      "the stored order must lift firmware above the build log"
      # The two folders the stored order does not name are still there, after Files.
      assert_includes panel_ids, "folder:d-models"
    end

    test "a hidden folder panel is absent, and only that one" do
      project = folder_panel_project!
      project.update!(panels: { "hidden" => [ folder_key("d-models") ] })

      get project_path(project)

      assert_select "section.folder-panel[id=?]", folder_key("d-models"), count: 0
      assert_select "section.folder-panel[id=?]", folder_key("d-firmware"), 1
      assert_select "section.folder-panel[id=?]", folder_key("d-notes"), 1
      assert_select ".attachment-tile .grid-name", { text: "base.stl", count: 0 },
                    "a hidden folder's files leave the page with it"
    end

    # THE VIEW IS PER PANEL, which is the whole point (spec decision 6): one panel switched to list
    # must not switch the others, and the repo next door keeps its browser.
    test "a stored view renders list rows in that panel and nowhere else" do
      project = folder_panel_project!
      project.update!(panels: { "views" => { folder_key("d-models") => "list" } })

      get project_path(project)

      assert_select "section.folder-panel[id=?]", folder_key("d-models") do
        assert_select "table.table.project-files td.col-name", text: "base.stl"
        assert_select ".attachments-grid", count: 0
      end
      # WHICH PANELS HOLD A TABLE, not how many tables there are: the nested old/ section inherits
      # this panel's view and draws a second one, so a count would pin the nesting rather than the
      # thing under test.
      listed = css_select("div.project-panels > div.panel-slot > section.panel").select { |s| s.css("table.project-files").any? }
      assert_equal [ folder_key("d-models") ], listed.map { |s| s["id"] }, "only the models panel is a list"
      assert_select "section.folder-panel[id=?] .repo-browser", folder_key("d-firmware"), 1
    end

    # THE TOGGLE IS A WRITE, so it is a form per button rather than a link, and the params are what
    # Projects::PanelsController reads. ASSERT THE RENDERED FIELD NAME (CLAUDE.md section 14d) —
    # a controller test posting a nested hash would pass whatever the markup emitted.
    test "each folder panel head carries a three-way view toggle posting view[<key>]" do
      get project_path(folder_panel_project!)

      assert_select "section.folder-panel[id=?]", folder_key("d-models") do
        assert_select ".view-toggle form[action=?]", project_panels_path(@user.maker_projects.find_by(name: "Rig")), 3
        Maker::Project::VIEWS.each do |value|
          assert_select "input[type=hidden][name=?][value=?]", "view[folder:d-models]", value
        end
        assert_select ".view-toggle button.toggle.active", text: "Tiles"
      end
      # The Files panel gets its own two-button toggle, under its own key.
      assert_select "section.attachments-panel input[type=hidden][name=?][value=?]", "view[attachments]", "list"
      assert_select "section.attachments-panel input[name=?][value=?]", "view[attachments]", "browser", count: 0
    end

    # THE LAYOUT IS TOTAL ABOUT VIEWS TOO. `views` is a JSON sub-hash nothing validates on the way
    # in, and a value outside Maker::Project::VIEWS would reach the partial's branch.
    test "junk in the views map renders the page in the defaults" do
      project = folder_panel_project!
      project.update_column(:panels, { "views" => { "folder:gone" => "list", folder_key("d-models") => "nonsense",
                                                    "attachments" => 5 } })

      get project_path(project)

      assert_response :success
      assert_select "section.folder-panel[id=?] > div > .attachments-grid > .attachment-tile",
                    folder_key("d-models"), 2
      assert_select "div.project-panels table.project-files", count: 0
    end

    # A KEY THAT IS NOT A PANEL MUST NOT REACH `render` — it would be a MissingPartial, i.e. a 500
    # on the maker's own page, and the column is JSON nothing validates on the way in.
    test "junk in the panels column renders the page rather than raising" do
      @project.update_column(:panels, { "order" => [ "attachments", "../../etc/passwd" ], "hidden" => "nope" })

      get project_path(@project)

      assert_response :success
      assert_select "section.attachments-panel", 1
    end

    # --- titles and intros (2026-09-09, the page editor; spec §3) -----------------------------
    #
    # `folder_panel_project!` RATHER THAN `@project`: the setup's project has no subfolder at all,
    # and half of what these two assert is that a FOLDER panel takes a title from the layout the
    # same way a fixed one does — the case that needs the caller-supplied default (the folder's own
    # name), which is the whole reason ProjectKind::Layout#title_for takes one.

    test "a custom title replaces the heading and an intro renders under it, on fixed and folder panels" do
      project = folder_panel_project!
      # A ROW, so the Tasks panel is on the page to carry its title (slice 6: empty, it is absent).
      project.tasks.create!(user: @user, title: "Cut the base")
      models_key = folder_key("d-models")
      project.update!(panels: { "titles" => { "tasks" => "To do", models_key => "Prints" },
                                "intros" => { models_key => "Sliced for 0.2 mm." } })

      get project_path(project)

      assert_select "section.tasks-panel h2", text: "To do"
      # KEYED BY THE PANEL'S OWN ID: the fixture holds three folder panels, and an un-keyed match
      # would pass with the title on the wrong one (found in review).
      assert_select "section.folder-panel[id=?] h2", models_key, text: "Prints"
      assert_select "section.folder-panel[id=?] p.panel-intro", models_key, text: "Sliced for 0.2 mm."
      assert_select "section.tasks-panel p.panel-intro", count: 0
      # THE PATH LINE IS UNTOUCHED BY A RETITLE: a folder panel says WHERE it is as well as what it
      # is called, and a maker who renames the panel has not renamed the folder.
      assert_select "section.folder-panel a.panel-path", text: /models/, minimum: 1
    end

    test "a title is escaped, never markup" do
      @project.update!(panels: { "titles" => { "tasks" => "<b>x</b>" } })

      get project_path(@project)

      assert_select "section.tasks-panel h2 b", count: 0
      assert_select "section.tasks-panel h2", text: "<b>x</b>"
    end

    # THE TURBO-STREAM REPLACE RE-RENDERS projects/_tasks WITH NO PAGE BEHIND IT (found here, not in
    # the plan): Projects::TasksController#render_tasks sets @project/@tasks and nothing else, so
    # @panel_layout is nil in that render and a partial reading it alone would either raise or
    # quietly hand the heading back its default label — the maker adds a task and watches "To do"
    # turn into "Tasks". Driven through the real door rather than reasoned about.
    test "the tasks panel keeps the maker's title when a task add replaces it over turbo_stream" do
      @project.update!(panels: { "titles" => { "tasks" => "To do" } })

      post project_tasks_path(@project), params: { task: { title: "Print the base" } }, as: :turbo_stream

      assert_response :success
      assert_match(/<h2>To do<\/h2>/, response.body)
    end

    # ONE PANEL-HEAD SHAPE ACROSS THE PROJECT PAGE (UI-cohesion slice 5). §2.10 measured FOUR:
    # Files (title + path + toggle + three links + a button), Tasks (title alone), Publish (title +
    # a right-aligned link) and Build log (title, then its button on the NEXT LINE). Two of them
    # carried a bare `<h2>` with no `.panel-head` at all, so the component's alignment and gap
    # applied to half the page.
    #
    # ASSERTED ON THE RENDERED PAGE, and on the RELATIONSHIP rather than a count: what makes a head
    # a head is that the title lives inside one. A grep for `.panel-head` in the templates would
    # pass on a panel that renders none, which is exactly what two of these did.
    # BOM, Wiring and Releases are empty on `@project`, so each is opened with ?add= (slice 6) — one
    # request apiece, the panels of all four pages swept together.
    test "every panel on the project page wraps its title in a panel head" do
      @project.build_log_entries.create!(user: @user, body: "glued", logged_at: Time.current)
      @project.tasks.create!(user: @user, title: "cut")
      panels = [ nil, "bom", "wiring", "releases" ].flat_map do |add|
        get project_path(@project, add:)
        assert_response :success
        css_select("main section.panel")
      end
      refute_empty panels, "no panels rendered — the sweep is not reaching the page"
      %w[build-log tasks bom wiring releases sheets].each do |name|
        assert panels.any? { |p| p["class"].to_s.split.include?("#{name}-panel") }, "the sweep never reached #{name}"
      end
      bare = panels.filter_map do |panel|
        h2 = panel.at_css("h2")
        next if h2.nil?
        next if h2.ancestors.any? { |a| a["class"].to_s.split.include?("panel-head") }
        panel["class"]
      end
      assert_empty bare, "these panels put their title outside a .panel-head: #{bare.inspect}"
    end
  end
end
