require "application_system_test_case"
require "support/kicad_fixture"
require "support/gerber_fixture"

# The shell's behaviour only a browser can see (spec §12): the rail's collapse surviving a Turbo
# navigation and a reload, the theme button cycling and persisting, a notice toast leaving on its
# own while an alert waits to be dismissed, Cmd/Ctrl-K reaching the search field, and — the guard
# for the bug that started this rework — no page scrolling sideways at phone width.
class ShellTest < ApplicationSystemTestCase
  include KicadFixture
  include GerberFixture

  setup do
    @root = use_fresh_share_library!
    @user = sign_in_as("shell@example.com")
  end

  teardown do
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  test "collapsing the rail survives a navigation and a reload" do
    visit files_path
    assert_selector "aside.rail"
    assert_no_selector "body.rail--collapsed"

    find("aside.rail [data-action='rail#toggle']").click
    assert_selector "body.rail--collapsed"

    find("aside.rail a.rail-link[title='Projects']").click
    assert_current_path projects_path
    assert_selector "body.rail--collapsed"

    visit projects_path
    assert_selector "body.rail--collapsed"

    find("aside.rail [data-action='rail#toggle']").click
    assert_no_selector "body.rail--collapsed"
    assert_no_console_errors
  end

  test "the theme button cycles dark, light, system and persists" do
    visit files_path
    theme = -> { page.evaluate_script("document.documentElement.dataset.theme") }
    assert_equal "dark", theme.call

    find("aside.rail [data-action='theme#cycle']").click
    assert_equal "light", theme.call
    visit files_path
    assert_equal "light", theme.call
    assert_selector "aside.rail [data-action='theme#cycle']", text: "Theme: light"

    find("aside.rail [data-action='theme#cycle']").click
    assert_equal "system", theme.call
    find("aside.rail [data-action='theme#cycle']").click
    assert_equal "dark", theme.call
    visit files_path
    assert_equal "dark", theme.call
    assert_no_console_errors
  end

  test "a notice toast leaves on its own and an alert waits to be dismissed" do
    # sign_in_as landed on /files carrying Devise's "Signed in successfully." notice.
    assert_selector ".flash-stack .flash-notice", text: "Signed in successfully."
    assert_no_selector ".flash-stack .flash-notice", wait: 9

    # THE `assert_current_path` IS NOT DECORATION, for the reason `sign_in_as` gives about the
    # other direction: `.click` returns before the sign-out round trip lands, so the `visit` below
    # can race it, arrive still authenticated, render /files with no alert at all, and fail on the
    # next line looking like a broken toast. Seen for real — this file went green, then red on the
    # same code with a different seed. Waiting for the sign-in page makes the sign-out a fact.
    find("aside.rail button", text: "Sign out").click
    assert_current_path new_user_session_path
    visit files_path
    assert_selector ".flash-stack .flash-alert", text: /sign in/i
    sleep 7
    assert_selector ".flash-stack .flash-alert", text: /sign in/i
    find(".flash-stack .flash-alert .flash-close").click
    assert_no_selector ".flash-stack .flash-alert"
  end

  # Stage 2, S2-5: the field this focuses now posts to SearchController (sitewide), not
  # FilesController -- rail_controller.js's selector (`.topbar-search input[type=search]`) and
  # this field's `name` did not change, so the shortcut itself did not need to.
  test "command-K focuses the top bar's search field" do
    visit projects_path
    find("body").send_keys([ :control, "k" ])
    assert_equal "q", page.evaluate_script("document.activeElement.name")
    assert_no_console_errors
  end

  # MUTATION-CHECKED (§15), AND THE MUTATION THAT WORKS IS NOT THE ONE YOU WOULD REACH FOR.
  # Dropping `pages/files.css`'s column-drop media queries — BOTH of them, so the list keeps Name,
  # Type, Folder, Size and Modified at 375px — leaves this GREEN: the table's min-content is about
  # 181px, well inside the 351px the phone container offers, because `.file-name` carries
  # `overflow-wrap: anywhere` and `.row-actions` wraps. Lengthening the name does not change that
  # either (tried at 235 characters: scrollWidth stayed 375). Those rules buy READABILITY at
  # 480-719px, not overflow safety, and this guard is honest about not covering them.
  # What DOES redden it is the regression it exists for — the shell failing to collapse: making
  # `@media (max-width: 719px)`'s `body.app-shell` keep `var(--rail-width)` and deleting
  # `.rail { display: none }` gives "/files?view=list scrolls sideways at 375px (scrollWidth 393)".
  test "no page scrolls sideways at phone width" do
    # `tag_list:` (stage 2, S2-5, Maker::Taggable) so the sweep below has a real tag page to visit
    # (tag_path("lamp")) and the search results page (search_path(q: "lamp")) has more than the
    # empty-prompt state to render — this project matches by name AND by tag.
    project = @user.maker_projects.create!(name: "Desk Lamp", description: "A lamp." * 20, tag_list: "lamp")
    # STAGE 3, S3-4: THE SAME PROJECT, PUBLISHED, so the three public pages below are the phone
    # rendering of THIS fixture rather than three empty states. The handle is set first because a
    # project cannot leave `private` without one (Maker::Project's own validation).
    #
    # THE FOLDER GETS ITS STORAGE PATH AND A REAL DIRECTORY, which `project_folder_rows!` alone does
    # not give it (rows only, deliberately -- it must not mkdir through the port). The KiCad file
    # below is written into it for real, so the catalog and the disk have to agree about where the
    # folder is or the public page would link at a path the port cannot read.
    @user.update!(handle: "sweep")
    project.update!(visibility: "public")
    folder = project_folder_rows!(@user, project)
    @user.nodes.find_by!(node_id: folder.parent_node_id).update!(storage_path: Maker::ProjectFolders::ROOT)
    folder.update!(storage_path: File.join(Maker::ProjectFolders::ROOT, project.slug))
    @root.join(folder.storage_path).mkpath
    # THE INVENTORY PAGES (S2-3) with every column populated and a long name, so the table drops
    # and the settings rows are exercised at 375px, not an empty state.
    supplier = @user.maker_suppliers.create!(name: "McMaster-Carr Supply Company", url: "https://www.mcmaster.com")
    parent = @user.maker_locations.create!(name: "Cabinet B")
    location = @user.maker_locations.create!(name: "Drawer B1, second from the top", parent:)
    item = @user.maker_inventory_items.create!(name: "M3×8 socket-head cap screw, stainless, box of 100",
                                               part_number: "91290A113", category: "Fasteners", min_quantity: 50,
                                               unit_cost: 0.04, location:, supplier:)
    Maker::InventoryTransaction.apply!(item:, user: @user, delta: 12, reason: "initial", note: "stocktake")
    # STAGE 2, S2-4: one BOM line so the panel's table (and its composer) render at 375px rather
    # than the empty state -- reuses `item`/`supplier` above, the same argument the inventory
    # fixtures two lines up make for exercising a populated row rather than an empty page.
    bom = project.boms.create!(user: @user)
    bom.lines.create!(user: @user, inventory_item: item, supplier:, quantity: 2, unit: "each")
    # STAGE 3, S3-3: one connection, the BOM argument again -- an EMPTY panel renders no table, so
    # without a row the sweep never reached the wiring table, its per-row forms or the 375px
    # rendering of five input cells. MEASURED, NOT ASSUMED: the two `.wiring` column drops (Note at
    # 719px, Wire at 479px) are NOT what keeps this row inside the viewport -- deleting both left
    # this sweep green, because Chrome shrinks a 100%-width input to its cell. They are a
    # readability choice, and this seed pins the render path, not the breakpoints.
    project.connections.create!(user: @user, from_label: "Driver board",
                                to_label: "Stepper motor, second from the top",
                                wire: "22 AWG twisted pair", note: "route away from the mains lead",
                                position: 0)
    long = create_node!(@user, node_id: SecureRandom.uuid, kind: "file",
                        name: "a-very-long-file-name-that-would-push-the-table-out-of-the-viewport-v3-final.stl")
    # STAGE 3, S3-2: the :kicanvas branch is new markup (KiCanvas's own toolbar included) that no
    # other page in this sweep exercises. REAL bytes, not test_helper's create_node! placeholder —
    # KiCanvas fetches this file for real in a live Chrome, and garbage input failing to parse
    # would log its own console error, indistinguishable at the final assert_no_console_errors
    # from an actual overflow regression. See test/support/kicad_fixture.rb.
    # PARENTED UNDER THE PROJECT FOLDER (S3-4), which the private file page above does not care
    # about but the public page does twice over: it is what puts the file in the project's listing
    # (Maker::PublicProject#kicad_rows) AND what makes it deliverable at all (`permits?` answers by
    # ancestry), so the public Schematics panel mounts a KiCanvas that fetches the public named URL
    # for real -- a 404 there would surface at the final assert_no_console_errors.
    kicad = write_kicad_schematic!(name: "shell-sweep.kicad_sch", parent_node_id: folder.node_id)
    # STAGE 4, S4-1: A REAL IMAGE IN THE FOLDER, ATTACHED, so the project page renders its two new
    # layouts at 375px -- the hero (an <img> at width 100%; the derived cover is the project's only
    # image-role attachment) and the Photos panel's grid -- rather than the no-cover / no-photos
    # branches the sweep otherwise exercises (found by S4-1's review: both layouts were laid out
    # at phone width nowhere). REAL BYTES (test/fixtures/files/sample.png), the KiCanvas argument
    # above: Chrome fetches the blob URL for real, and a 404 or an unreadable file would land in
    # assert_no_console_errors as a resource error that has nothing to do with layout. The public
    # page below gets the same photo through `permits?`' ancestry, so its gallery is exercised too.
    png = Rails.root.join("test/fixtures/files/sample.png").binread
    photo_rel = File.join(folder.storage_path, "lid.png")
    @root.join(photo_rel).binwrite(png)
    photo = @user.nodes.create!(node_id: SecureRandom.uuid, name: "lid.png", kind: "file",
                                parent_node_id: folder.node_id, size: png.bytesize, storage_path: photo_rel,
                                mtime: 1_000_000_000, content_hash: Digest::SHA256.hexdigest(png))
    project.file_attachments.create!(user: @user, node_id: photo.node_id, role: "image", position: 0)
    # THE GERBER FILE PAGE, at 375px. Its stackup is an <svg> the browser is told to render at
    # width: 100% — the one element on these pages whose natural size is its PHYSICAL size (a board
    # is millimetres wide), so it is the one most likely to push the page sideways if
    # gerber_controller.js's attribute override or pages/preview.css's stage rules regress. REAL
    # BYTES for the KiCanvas argument directly above: tracespace fetches these for real in a live
    # Chrome, and a parse failure would log its own console error, indistinguishable at the final
    # assert_no_console_errors from an actual overflow regression. The viewer is LAZY, so the loop
    # below launches it on that page before measuring — a poster cannot overflow, and a sweep that
    # never clicked would be measuring nothing. (The project page lists these as ordinary rows since
    # 2026-09-06; there is no panel there to render them.)
    pcb_dir = gerber_dir!(name: "pcb", parent_node_id: folder.node_id)
    gerbers = write_gerber_set!(stem: "shell-sweep", parent_node_id: pcb_dir.node_id)
    # 2026-09-07: A REPOSITORY IN THE PROJECT FOLDER, so the project page carries the inline
    # Miller-columns browser (projects/_repo_browser) and this sweep measures it at 375px. It is
    # the one element on that page whose width is decided in JS after a fetch, and components.css's
    # narrow rule (`.filechooser-col { flex-basis: 100% }` plus hiding all but the last column) is
    # what keeps a three-deep trail from being 600px of columns on a phone. ROWS ONLY — the browser
    # reads `nodes` and fetches no bytes, so nothing here needs the port.
    repo_dir = @user.nodes.create!(node_id: SecureRandom.uuid, name: "firmware", kind: "dir",
                                   parent_node_id: folder.node_id)
    @user.nodes.create!(node_id: SecureRandom.uuid, name: Library::RepoMetadata::DIR_NAME,
                        kind: "dir", parent_node_id: repo_dir.node_id)
    @user.nodes.create!(node_id: SecureRandom.uuid, name: "main.c", kind: "file",
                        parent_node_id: repo_dir.node_id)
    # STAGE 3, S3-5: ONE RELEASE WITH A LONG VERSION AND THREE FILES, so the summary's flex row has
    # something to wrap and the release table has rows to drop columns from at 375px -- the BOM and
    # wiring argument again, an EMPTY panel renders no <details> and no table at all. All three file
    # states are present (current, changed, gone) because each renders a different cell, and the
    # widest of them is the one that would push the row out of the viewport.
    #
    # ROWS, NOT Maker::ReleaseSnapshot: what this sweep needs is markup at a width, and the snapshot
    # would additionally have to agree with whatever the folder happens to hold.
    release = project.releases.create!(user: @user, version: "v2.0.0-release-candidate.4",
                                       git_tag: "v2.0.0-release-candidate.4", git_oid: "0" * 40,
                                       published_at: Time.current,
                                       notes: "<div>Reworked the frame and the driver mount.</div>")
    release.files.create!(user: @user, node_id: kicad.node_id, name: kicad.name,
                          path: kicad.name, size: 4096,
                          content_token: FileLayer.current.stat(@user, node_id: kicad.node_id).content_token)
    # LIVE BUT MOVED ON (it sits at the library root, so the PUBLIC page additionally refuses it a
    # link) -- the "changed" badge and the no-link cell in one row.
    release.files.create!(user: @user, node_id: long.node_id, name: long.name, path: long.name,
                          size: 1_048_576, content_token: "t-stale")
    release.files.create!(user: @user, node_id: "shell-sweep-gone", size: 2048,
                          name: "a-very-long-file-name-that-would-push-the-table-out-of-the-viewport-v3-final.stl",
                          path: "models/a-very-long-file-name-that-would-push-the-table-out-of-the-viewport-v3-final.stl",
                          content_token: "t-gone")
    # ENOUGH FILES FOR THE HOME ROW TO OVERFLOW TOO, mutation-checked same as home_test.rb's own
    # dedicated scroll-containment test (see test/system/README.md) — without these, root_path's
    # single `long` tile never fills `.home-files .tile-row` wide enough to overflow its own box,
    # so dropping `.tile-row`'s `overflow-x: auto` in app/assets/stylesheets/pages/home.css read
    # GREEN here on the first attempt, for having nothing to contain rather than containing it
    # correctly — measured, not assumed: adding these 8 nodes is what turned that false green into
    #   / scrolls sideways at 375px (scrollWidth 1312)
    # which is the failure this loop's own final assertion below is written to catch. Reverted
    # immediately after. RECENT_FILES caps display at 8; 8 more (9 total with `long`) mirrors
    # home_test.rb's margin.
    8.times { |i| create_node!(@user, node_id: SecureRandom.uuid, kind: "file", name: "shell-sweep-#{i}.stl") }

    # ROOT_PATH RENDERS THE HOME HERO IN ITS FULL SHAPE ONLY WITH A CURRENT PROJECT SET, so pick
    # one through the rail's own <select> BEFORE narrowing the viewport below — at 375px the rail
    # itself is `display: none` (`assert_no_selector "aside.rail .current-project select"` in the
    # loop below), and the topbar's own project select is a separate, narrower affordance this test
    # has no need to drive. `visit root_path` first because sign_in_as's post-login DOM predates
    # this project — the rail's <select> was rendered before `project` existed.
    visit root_path
    select project.name, from: "project_id"
    assert_selector ".home-hero h2", text: project.name

    # THE VIEWPORT IS SET THROUGH CDP, NOT `manage.window.resize_to`, AND THE DIFFERENCE IS THE
    # WHOLE GUARD. Headless Chrome refuses to make a window narrower than 500px: asking for
    # 375x812 through the WebDriver window API and then measuring gave `innerWidth=500` on every
    # page (measured 2026-09-03) — so the guard read green while testing a width no phone has, and
    # `pages/files.css`'s `@media (max-width: 479px)` column drops never ran once. A guard that
    # cannot reach the width it names is the "green suite over something that never worked" shape
    # §15 is about. `Emulation.setDeviceMetricsOverride` sets the LAYOUT viewport and honours 375,
    # and `execute_cdp` is already this suite's house tool (the browser-cache clear in
    # application_system_test_case.rb uses it). Cleared in the ensure because Selenium reuses one
    # Chrome for the whole file.
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
                                    width: 375, height: 812, deviceScaleFactor: 1, mobile: false)
    begin
      # THE OVERFLOW ASSERTION IS THE SWEEP; the per-page selectors around it are how each half
      # proves the phone rules ran at all. Shared as a lambda rather than duplicated, so the two
      # loops below cannot drift about what "scrolls sideways" means.
      no_sideways_scroll = lambda do |path|
        assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth"),
               "#{path} scrolls sideways at 375px (scrollWidth #{page.evaluate_script('document.documentElement.scrollWidth')})"
      end

      # THE GERBER LEG IS GATED ON A PATH MATCH, so it can go silently unrun — a renamed helper or a
      # dropped fixture would leave the sweep measuring the file page's POSTER, which has no viewer
      # on it to overflow, and nothing here would say so. The flag is what makes the branch's
      # absence a failure rather than a quieter test (§15).
      launched_gerber = false
      # THE SAME GATE-ON-A-PATH ARGUMENT AS THE GERBER LEG ABOVE, and the same answer: opening the
      # repo section is what mounts the browser at all (it is closed by default and mounts lazily),
      # so a renamed summary would leave this sweep measuring an EMPTY div and nothing would say so.
      opened_repo = false
      # THE SAME GATE-ON-A-PATH ARGUMENT AS THE TWO ABOVE, twice more. The preview is reached only
      # by its own path match, and the README editor is a <details> that mounts CodeMirror only when
      # OPENED — an unopened one measures a closed summary and says nothing about the editor's width
      # at 375px. Renaming either would leave both branches silently unrun.
      previewed = false
      opened_readme = false
      [ root_path, files_path(view: "list"), files_path(view: "grid"), project_path(project),
        # STAGE 4, S4-4: the owner's preview, which is the one page in this sweep that renders the
        # PUBLIC page's partials inside the SIGNED-IN shell. Both halves are already swept
        # separately — the public page in the second loop below, the app shell everywhere in this
        # one — and neither says what happens when they are laid out on top of each other at 375px.
        preview_project_path(project),
        file_path(long.node_id), file_path(kicad.node_id), file_path(gerbers[:gtl].node_id), tools_path, models_path, trash_index_path,
        inventory_items_path, inventory_item_path(item), suppliers_path, locations_path,
        project_bom_path(project),
        # STAGE 2, S2-5: the search results page (several groups populated -- see the tag_list:
        # above) and a tag page, the two new surfaces this arc adds to the shell.
        search_path(q: "lamp"), tag_path("lamp"),
        # STAGE 2, S2-6: the settings hub and its tags list -- the same tag_list: above gives the
        # list a real row to render instead of the empty state.
        settings_path, settings_tags_path ].each do |path|
        visit path
        if path == file_path(gerbers[:gtl].node_id)
          click_button "View layer"
          assert_selector ".gerber-viewer[data-gerber-state='ready']"
          launched_gerber = true
        end
        if path == preview_project_path(project)
          # THE BANNER IS THIS PAGE'S POSITIVE MARKER, the same argument the public loop below makes
          # for naming one per path: `visit` does not fail on a redirect, and the preview redirects
          # to the project page when the maker has no handle — which would leave this branch
          # measuring the project page a second time and reporting nothing.
          assert_selector ".preview-banner"
          previewed = true
        end
        if path == project_path(project)
          # `/firmware/i` because `.attachment-group-head` is `text-transform: uppercase` and
          # Selenium reports RENDERED text (repo_browser_test.rb records the same).
          find("summary", text: /firmware/i).click
          assert_selector ".filechooser--inline .filechooser-col", count: 1
          opened_repo = true
          # STAGE 4, S4-1: the hero and the Photos panel are ON this page, or the overflow check above
          # measured the no-cover and no-photos branches and said nothing about the two new layouts.
          assert_selector ".project-hero img.project-hero-img"
          assert_selector "section.photos-panel .photo-cell", minimum: 1
          # STAGE 4, S4-4: THE PUBLISH PANEL AND THE README EDITOR, both new to this page and both
          # invisible to the overflow check until they are actually here and actually open. The
          # editor mounts CodeMirror on toggle, so a closed <details> measures a summary button and
          # nothing else — and opening it is what caught the real defect this branch shipped with:
          # a 140-character README line made `.attachments-panel` 1192px wide at 375px, fixed by
          # `.project-panels > .panel { min-width: 0 }` in pages/projects.css. This folder holds no
          # README, so the editor opens on the TEMPLATE with no fetch, which is what makes the
          # `.cm-editor` wait deterministic here.
          #
          # THE PANEL ASSERTION IS PRESENCE, NOT WIDTH, AND THE DISTINCTION IS MEASURED. Its public
          # URL is the page's one unbreakable token, so `overflow-wrap: anywhere` on
          # `.publish-url .mono` looks like something this sweep covers — it does NOT. Under Capybara
          # the URL is `http://127.0.0.1:<port>/u/sweep/desk-lamp`: 40 characters, 288px inside the
          # 306px row, so flipping that rule to `normal` leaves this test GREEN (run, 2026-09-07).
          # A deployment host and a real handle are what make it wrap; proving the rule here would
          # need a fixture whose handle and slug are that long, and this comment is the record that
          # it does not have one rather than a claim that it does.
          assert_selector "section.publish-panel#publish"
          find(".readme-editor summary").click
          assert_selector ".readme-editor .cm-editor"
          opened_readme = true
        end
        # `nav.tabbar` is display:none above 719px, so finding it VISIBLE is the proof that the
        # phone rules are running at all — without it a viewport that never narrowed would satisfy
        # the overflow assertion for entirely the wrong reason. It is what caught the 500px floor.
        assert_selector "nav.tabbar", visible: true
        assert_selector "form.topbar-project select", visible: true
        assert_no_selector "aside.rail .current-project select"
        no_sideways_scroll.call(path)
      end
      assert launched_gerber, "the sweep never launched the Gerber viewer, so its overflow check measured a poster"
      assert opened_repo, "the sweep never opened the repository section, so its overflow check measured an empty mount point"
      assert previewed, "the sweep never visited the preview, so its overflow check measured nothing"
      assert opened_readme, "the sweep never opened the README editor, so its overflow check measured a closed summary"

      # STAGE 3, S3-4: THE PUBLIC PAGES, IN THEIR OWN LOOP BECAUSE THEIR SHELL IS THE OTHER ONE.
      # The three assertions above are the SIGNED-IN shell's, and this session IS signed in — so
      # reusing them here would fail for the right reason and read as an overflow bug. A public page
      # renders the VISITOR's shell whatever the session says (`shell_signed_in?` asks
      # `public_surface?` first), and asserting the absence of both chrome elements is what proves
      # that took effect in a real browser rather than only in an integration test's markup.
      # MUTATION-CHECKED, AND THE ANSWER IS THE SAME ONE THIS TEST'S HEADER GIVES FOR files.css:
      # deleting BOTH `.public-files` column drops from pages/public.css (Size at 719px, the
      # thumbnail at 479px) leaves this GREEN — the public file table's min-content fits the 351px
      # the phone container offers, so those two rules buy READABILITY, not overflow safety, and
      # this sweep does not cover them. What it does cover is the shell: the two `assert_no_selector`
      # lines below are the visitor-shell proof, and they go red the moment a public page renders
      # the signed-in chrome.
      #
      # EACH ONE ALSO NAMES A MARKER OF ITS OWN CONTENT, and that is not decoration: `visit` does
      # not fail on a 404, and a 404 renders no tabbar and no rail and does not scroll sideways --
      # so without a positive assertion a broken route would satisfy all three checks below and this
      # loop would be green over three error pages. The project page's marker is the KiCanvas stage
      # reaching `ready`, which is the strongest of the three: it proves the controller mounted and
      # started fetching the PUBLIC named URL, so `assert_no_console_errors` at the end is covering
      # a real fetch rather than a div nothing ever asked for.
      { public_project_path(@user.handle, project.slug) => ".kicanvas-stage[data-kicanvas-state='ready']",
        public_user_path(@user.handle) => "main.public-main .project-card-grid",
        public_explore_path => "main.public-main .project-card-grid" }.each do |path, marker|
        visit path
        assert_selector marker
        assert_no_selector "nav.tabbar"
        assert_no_selector "aside.rail"
        no_sideways_scroll.call(path)
      end
      # KICANVAS_PLACEHOLDER_FETCH: the Schematics preview's `controls="basic"` embed makes Chrome
      # fetch `<page dir>/$$:0:$$` once before KiCanvas substitutes its icon sprite href — Linux
      # Chrome logs that aborted 404 at SEVERE, macOS Chrome does not (web_helpers.rb says why).
      # Exactly that message and nothing else; a genuine 404 on any of these pages still fails.
      assert_no_console_errors ignoring: [ KICANVAS_PLACEHOLDER_FETCH ]
    ensure
      page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    end
  end
end
