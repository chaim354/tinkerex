require "application_system_test_case"
require "support/kicad_fixture"

# The shell's behaviour only a browser can see (spec §12): the rail's collapse surviving a Turbo
# navigation and a reload, the theme button cycling and persisting, a notice toast leaving on its
# own while an alert waits to be dismissed, Cmd/Ctrl-K reaching the search field, and — the guard
# for the bug that started this rework — no page scrolling sideways at phone width.
class ShellTest < ApplicationSystemTestCase
  include KicadFixture

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

      [ root_path, files_path(view: "list"), files_path(view: "grid"), project_path(project),
        file_path(long.node_id), file_path(kicad.node_id), tools_path, models_path, trash_index_path,
        inventory_items_path, inventory_item_path(item), suppliers_path, locations_path,
        project_bom_path(project),
        # STAGE 2, S2-5: the search results page (several groups populated -- see the tag_list:
        # above) and a tag page, the two new surfaces this arc adds to the shell.
        search_path(q: "lamp"), tag_path("lamp"),
        # STAGE 2, S2-6: the settings hub and its tags list -- the same tag_list: above gives the
        # list a real row to render instead of the empty state.
        settings_path, settings_tags_path ].each do |path|
        visit path
        # `nav.tabbar` is display:none above 719px, so finding it VISIBLE is the proof that the
        # phone rules are running at all — without it a viewport that never narrowed would satisfy
        # the overflow assertion for entirely the wrong reason. It is what caught the 500px floor.
        assert_selector "nav.tabbar", visible: true
        assert_selector "form.topbar-project select", visible: true
        assert_no_selector "aside.rail .current-project select"
        no_sideways_scroll.call(path)
      end

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
      assert_no_console_errors
    ensure
      page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    end
  end
end
