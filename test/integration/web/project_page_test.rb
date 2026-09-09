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
      rendered = css_select("div.project-panels > div.panel-slot > section.panel")
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

      project.update!(panels: { "views" => { "folder:d-firmware" => "tiles" } })
      get project_path(project)
      assert_select "section.folder-panel[id='folder:d-firmware'] .attachment-tile", { minimum: 1 }
      assert Maker::Preview.exists?(user: @user, node_id: "f-case"),
             "a tile on the page must have a row the poll can resolve"
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
      assert_select "section.attachments-panel .attachment-tile", { count: 1 },
                    "only the loose file — a subfolder's files belong to its own panel"
      assert_select ".file-tree-section", 1, "only the nested old/ section is left, inside models"
    end

    # A FOLDER MOVES LIKE ANY OTHER PANEL, above the build log if the maker says so — which is the
    # first half of "a first-class member of the chooser" (spec decision 1).
    test "a stored order lifts a folder panel above the build log" do
      project = folder_panel_project!
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
  end
end
