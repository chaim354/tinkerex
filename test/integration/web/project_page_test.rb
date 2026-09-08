require "test_helper"

module Web
  # The project page after PR 3 (spec §8): a stats line from what the page already loads, real
  # buttons in the head, Detach as a corner control on smaller tiles, task rows with a state mark
  # and the composer BELOW the list, a build-log composer that opens on demand, and a timeline with
  # the date in its own column. Nothing here adds a query: page_query_budget_test.rb still holds.
  class ProjectPageTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "pp-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
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

    test "the head's actions are buttons, with Archive quiet and Set as current outlined" do
      get project_path(@project)
      assert_select ".head-actions form[action=?] button.btn.outline", current_project_path, text: /set as current/i
      assert_select ".head-actions a.btn[href=?]", edit_project_path(@project), text: "Edit"
      assert_select ".head-actions form[action=?] button.btn.danger", project_path(@project), text: "Archive"
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
      assert_select ".build-log-panel details.composer form input[type='submit'][value='Add entry']"
    end

    test "a log entry puts its date in the first column and its body in the second" do
      get project_path(@project)
      assert_select ".log-timeline .log-entry > time.entry-time", count: 1
      assert_select ".log-timeline .log-entry > .entry-main .entry-body", text: /First print came out clean/
      assert_select ".log-timeline .log-entry > .entry-main .entry-head form button", text: "Delete"
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

    test "a user with no project tags sees no filter toolbar" do
      get projects_path
      assert_select ".projects-toolbar", count: 0
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

    # --- Quiet empty panels (stage 4, S4-1) -----------------------------------------------------
    #
    # A secondary panel with nothing in it is its heading and one add control, not a box saying
    # "No entries yet." over an open composer. `@project` in `setup` is populated, so these two
    # tests each build their own project rather than reading it.
    test "an empty secondary panel is quiet: its heading and one add control, no zero-count groups, no empty sentences" do
      project = @user.maker_projects.create!(name: "Blank")

      get project_path(project)

      assert_response :success
      %w[build-log tasks bom wiring releases sheets].each do |name|
        assert_select "section.panel.#{name}-panel.panel--quiet", 1, "#{name} should be quiet"
      end
      assert_select "#project-tasks .tasks-group", count: 0
      assert_select ".build-log-panel details.composer > summary", text: "Add entry"
      assert_select "#project-tasks form.task-form input[name='task[title]']"
      assert_select "p.muted", text: /No (entries|connections|releases|sheets) yet/, count: 0
    end

test "a quiet BOM panel keeps its revision badge: the hidden span is a count, and rev is not one" do
  project = @user.maker_projects.create!(name: "Rev")
  project.boms.create!(user: @user)

  get project_path(project)

  assert_select "section.bom-panel.panel--quiet .panel-head .bom-rev", text: /rev \d+/
end

    test "a populated panel is not quiet" do
      project = @user.maker_projects.create!(name: "Busy")
      project.tasks.create!(user: @user, title: "cut")
      project.build_log_entries.create!(user: @user, body: "glued", logged_at: Time.current)

      get project_path(project)

      assert_select "section.tasks-panel.panel--quiet", count: 0
      assert_select "section.build-log-panel.panel--quiet", count: 0
      assert_select "#project-tasks .tasks-group", count: 3
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
      rendered = css_select("div.project-panels > section.panel")
                 .map { |s| s["class"].split.find { |c| c.end_with?("-panel") } }

      assert_equal rendered, expected & rendered,
                   "the loop rendered #{rendered.inspect}, which is not in PANELS order"
      assert_includes rendered, "attachments-panel"
      assert_includes rendered, "build-log-panel"
      assert_includes rendered, "tasks-panel"
      assert_includes rendered, "sheets-panel"
    end

    test "a hidden panel is not rendered at all — not quiet, absent" do
      @project.update!(panels: { "hidden" => %w[tasks bom wiring] })

      get project_path(@project)

      assert_select "section.tasks-panel", count: 0
      assert_select "section.bom-panel", count: 0
      assert_select "section.wiring-panel", count: 0
      assert_select "section.build-log-panel", 1, "an unhidden panel is untouched"
      assert_select "section.attachments-panel", 1
    end

    # HIDDEN AND EMPTY ARE TWO QUESTIONS (the overview's quiet-panel contract). An empty panel that
    # is NOT hidden still renders, quiet — S4-1's state — and a hidden one is gone whether it is
    # empty or full. Both halves in one test, because it is the pair that must not collapse.
    test "hidden and quiet are different states" do
      empty = @user.maker_projects.create!(name: "Blank")

      get project_path(empty)
      assert_select "section.wiring-panel.panel--quiet", 1

      empty.update!(panels: { "hidden" => %w[wiring] })
      get project_path(empty)
      assert_select "section.wiring-panel", count: 0
    end

    test "a stored order reorders the DOM, and a preset does too" do
      @project.update!(panels: { "order" => %w[tasks build_log] })

      get project_path(@project)
      panels = css_select("div.project-panels > section.panel").map { |s| s["class"] }
      assert_operator panels.index { |c| c.include?("tasks-panel") }, :<,
                      panels.index { |c| c.include?("build-log-panel") },
                      "the stored order must move Tasks above Build log"

      @project.update!(panels: nil, kind: "electronics")
      @project.connections.create!(user: @user, from_label: "A", to_label: "B")
      get project_path(@project)
      panels = css_select("div.project-panels > section.panel").map { |s| s["class"] }
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

    # A KEY THAT IS NOT A PANEL MUST NOT REACH `render` — it would be a MissingPartial, i.e. a 500
    # on the maker's own page, and the column is JSON nothing validates on the way in.
    test "junk in the panels column renders the page rather than raising" do
      @project.update_column(:panels, { "order" => [ "attachments", "../../etc/passwd" ], "hidden" => "nope" })

      get project_path(@project)

      assert_response :success
      assert_select "section.attachments-panel", 1
    end
  end
end
