require "application_system_test_case"

# THE FINDER-STYLE MILLER-COLUMNS BROWSER ON THE PROJECT PAGE (lib/file_chooser.js in `browse`
# mode), mounted by filebrowser_controller.js.
#
# IT HAS TWO HOSTS SINCE 2026-09-08 AND THIS FILE DRIVES BOTH. A DEPTH-ONE subfolder of the project
# folder is a PANEL now (projects/_folder_panel, spec decisions 1 and 3), so a repository at depth
# one opens in the browser with no <details> around it at all — its default view IS `browser`
# (Maker::ProjectKind.default_view), and the panel is on screen the moment the page is. A folder
# NESTED deeper stays the closed <details> section it has always been
# (projects/_file_tree_section), and its browser still mounts lazily on the first open. The two
# cases are one controller and they are asserted separately below, because the second is the only
# one the file ever covered and the first is where it broke.
#
# WHAT THIS FOUND, WHICH IS THE ARGUMENT FOR THE WHOLE TIER (§14d). When the folder panels landed,
# `reveal()` still read `if (this.chooser || !this.details?.open) return` — with no enclosing
# <details> that evaluates `undefined`, returns, and mounts NOTHING. The server wrote the
# `.repo-browser` div, Stimulus connected the controller, the page rendered perfectly and the panel
# was permanently empty: no error, no console warning, the request test green. Measured before the
# fix: `PANELS: ["folder:5e2c…"]`, `REPO-BROWSER present: true`, `COLUMNS: 0`.
#
# WHY THIS TIER AND NOT AN INTEGRATION TEST — the same argument file_chooser_test.rb makes for the
# modal, and it is stronger here. The server renders ONE EMPTY DIV: every column, every row and
# every href is built in the browser after a `fetch`. project_attachments_test.rb pins what the
# server writes (the values, the closed nested section, the absence of tiles) and can prove nothing
# at all about whether anything mounts.
#
# ROWS ONLY, NEVER `ensure_library_folder!` — `project_folder_rows!` writes the two dir rows and
# points `folder_node_id` at the leaf, so nothing here calls the port. Through the port this
# fixture is a real mkdir, which is a Forbidden on the s3 leg and provisions a sync-server library
# on chunk_remote; the browser reads `nodes` and fetches no bytes, so rows are the honest fixture.
class RepoBrowserTest < ApplicationSystemTestCase
  include WebHelpers

  setup do
    @user = sign_in_as("repo-browser@example.com")
    @project = @user.maker_projects.create!(name: "Lamp")
    @folder = project_folder_rows!(@user, @project)

    @firmware = dir!("firmware", @folder.node_id)
    dir!(Library::RepoMetadata::DIR_NAME, @firmware.node_id) # what makes it a repository
    @src = dir!("src", @firmware.node_id)
    file!("README.md", @firmware.node_id)
    file!("main.c", @firmware.node_id)
    file!(".DS_Store", @firmware.node_id)
    @led = file!("led.c", @src.node_id)
  end

  def dir!(name, parent) = @user.nodes.create!(node_id: SecureRandom.uuid, name:, kind: "dir", parent_node_id: parent)
  def file!(name, parent) = @user.nodes.create!(node_id: SecureRandom.uuid, name:, kind: "file", parent_node_id: parent)

  # THE PANEL, BY ITS OWN KEY. `id="folder:<uuid>"` carries a colon, which a CSS id selector reads
  # as the start of a pseudo-class — so this is an ATTRIBUTE selector, not `#folder\:…`. Naming the
  # node id rather than matching on the heading text is what keeps it the FIRMWARE panel: a second
  # folder panel is a sibling section on the same page (see the toggle test below).
  def panel_for(dir) = "section.folder-panel[id='folder:#{dir.node_id}']"

  # OPEN A NESTED SECTION BY ITS NAME, AT THE SUMMARY'S LEFT EDGE. A nested repository's summary
  # also holds its Commits and History links, and in a half-width folder panel (every plain folder
  # since 2026-11-19) the summary's middle, where a bare `click` lands, is the
  # History link: the click left the page for /repos/:id/history. The offset is from the centre.
  def open_section(name)
    summary = find("summary", text: name)
    summary.click(x: -(summary.native.size.width / 2) + 12, y: 0)
  end

  # WAIT FOR THE PAGE THE BLOCK RELOADS, BEFORE ANY QUERY TOUCHES IT. A selector both documents can
  # match (or, for `assert_no_selector`, one the OLD document still matches) is checked for
  # visibility on every candidate, and a candidate that goes stale mid-check raises Chrome's
  # UNRETRYABLE "Node with given id does not belong to the document" — repo_history_test.rb records
  # the same trap. This test died on it under load, intermittently, on `.note-popover`. A flag set on
  # the old window cannot survive the reload, so its absence is a question no swap can tear.
  def across_reload
    page.execute_script("window.__acrossReload = true")
    yield
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + Capybara.default_max_wait_time
    loop do
      reloaded = begin
        page.evaluate_script("window.__acrossReload !== true && document.readyState === 'complete'")
      rescue Selenium::WebDriver::Error::WebDriverError
        false
      end
      break if reloaded
      flunk "the page never reloaded" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.05
    end
  end

  def open_firmware
    visit project_path(@project)
    # NO CLICK, AND THAT IS THE ASSERTION. A depth-one repository's panel defaults to `browser` and
    # is not inside a <details>, so the columns are there on arrival; the file's header records what
    # the page looked like when they were not.
    assert_selector panel_for(@firmware)
  end

  test "a repository at depth one is a panel whose browser mounts on arrival" do
    open_firmware

    within(panel_for(@firmware)) do
      assert_selector ".filechooser--inline .filechooser-col", count: 1
      within(".filechooser-col") do
        assert_selector ".filechooser-row", text: "src"
        assert_selector ".filechooser-row", text: "README.md"
        assert_selector ".filechooser-row", text: "main.c"
      end
      # THE HIDDEN SET, which is LibraryBrowseController#children's `visible_entries` and not the
      # browser's own filter — the module has none. `.git` is the marker Node keeps indexed and
      # never renders; a stray `.DS_Store` is ordinary NAS clutter.
      assert_no_selector ".filechooser-row", text: ".git"
      assert_no_selector ".filechooser-row", text: ".DS_Store"

      # FOLDERS BEFORE FILES, THEN CASE-INSENSITIVE BY NAME — the endpoint's own ordering
      # (`sort_by { [dir? ? 0 : 1, name.downcase] }`), asserted on the rendered column because that
      # is the only place a change to it would show. `main.c` before `README.md` IS that rule: an
      # ASCII sort would put the capital first, which is what the downcase exists to prevent.
      names = all(".filechooser-col .filechooser-row").map { |row| row.text.sub(/\A[^\w.]+\s*/, "") }
      assert_equal %w[src main.c README.md], names

      # THE BROWSER REPLACES THE TILES, it does not sit above them (projects/_folder_panel's own
      # comment). Without this the test would pass over a panel rendering both.
      assert_no_selector ".attachments-grid .attachment-tile"
    end

    assert_no_console_errors
  end

  test "a folder descends into a second column and a file is a real link to its page" do
    open_firmware

    within(panel_for(@firmware)) do
      find(".filechooser-row", text: "src").click
      assert_selector ".filechooser--inline .filechooser-col", count: 2
      assert_selector ".filechooser-col:last-child .filechooser-row", text: "led.c"

      # A REAL `<a href>`, NOT A ROW WITH A CLICK HANDLER. Found by href rather than by clicking the
      # text, so the assertion is about the ELEMENT: a `div` that navigated on click would satisfy a
      # `click` + `assert_current_path` pair and still break middle-click, ⌘-click and the keyboard.
      link = find(".filechooser-row.is-file[href='#{file_path(@led.node_id)}']")
      assert_equal "a", link.tag_name
      # AND IT OPTS INTO fileopen (2026-10-21) like every server-rendered file link. Asserted here
      # because template_hygiene_test.rb's sweep reads server HTML and never sees a JS-built row.
      # The menu's door sits BESIDE it since 2026-11-16: the listing's own action is added to the
      # row's, never written over it, which is what keeps this click opening the file.
      assert_equal %w[click->fileopen#click contextmenu->filemenu#open], link["data-action"].split.sort
      link.click
    end
    assert_current_path file_path(@led.node_id)
  end

  test "Back pops a column" do
    open_firmware

    within(panel_for(@firmware)) do
      find(".filechooser-row", text: "src").click
      assert_selector ".filechooser--inline .filechooser-col", count: 2

      find(".filechooser--inline .filechooser-back").click
      assert_selector ".filechooser--inline .filechooser-col", count: 1
      assert_no_selector ".filechooser-row", text: "led.c"
    end
    assert_no_console_errors
  end

  # A REPOSITORY NESTED BELOW DEPTH ONE IS STILL A CLOSED SECTION, AND ITS LAZINESS IS STILL THE
  # RULE (spec decision 3). This is the case the file covered before the panels landed, kept because
  # it is the other half of `hostOpen()` — the branch that must NOT mount until a person opens it.
  # `visible: :all` on the negative assertion is load-bearing: a closed <details> hides everything
  # inside it, so the default `assert_no_selector` would pass whether or not anything was mounted —
  # a guard that cannot fail for the reason it exists (§15). Asked of the whole DOM it means what it
  # says: the columns do not exist yet.
  test "a nested repository still waits for its section to be opened" do
    tools = dir!("tools", @folder.node_id)
    nested = dir!("bootloader", tools.node_id)
    dir!(Library::RepoMetadata::DIR_NAME, nested.node_id)
    file!("boot.c", nested.node_id)

    visit project_path(@project)
    within(panel_for(tools)) do
      assert_selector ".repo-browser", visible: :all
      assert_no_selector ".filechooser--inline", visible: :all
      # CASE-INSENSITIVE, because `.attachment-group-head` is `text-transform: uppercase` and
      # Selenium reports a summary's RENDERED text — "BOOTLOADER", not "bootloader".
      open_section(/bootloader/i)
      assert_selector ".filechooser--inline .filechooser-col", count: 1
      assert_selector ".filechooser-row", text: "boot.c"
    end
    assert_no_console_errors
  end

  # A PLAIN FOLDER SWITCHED TO `browser` THROUGH THE TOGGLE (spec decision 6). The default is tiles
  # and nothing about this folder is a repository — `browser` is a view a maker may choose for any
  # folder, and `projects/_repo_browser` takes any Dir. The click is a `button_to`, i.e. a real
  # PATCH to Projects::PanelsController that writes `panels["views"]` on the project ROW; the
  # columns that follow are proof the choice both persisted and mounted, which is the pair a stored
  # fixture alone could not show.
  test "a plain folder switched to the browser mounts the columns" do
    models = dir!("models", @folder.node_id)
    file!("base.stl", models.node_id)
    file!("lid.stl", models.node_id)

    visit project_path(@project)
    within(panel_for(models)) do
      assert_selector ".attachments-grid .attachment-tile", count: 2
      assert_no_selector ".filechooser--inline"
      click_on "Browser"
    end

    within(panel_for(models)) do
      assert_selector ".filechooser--inline .filechooser-col", count: 1
      # THE ACTIVE BUTTON KEEPS THE COMPONENT'S FILL (found in review): the buttons' UA reset lives
      # in components.css on `.toggle` itself, because a reset in a `pages` sheet beats
      # `.toggle.active`'s background whatever its specificity — across cascade layers only the
      # layer order counts. Only a browser can see a computed style, so this is where it is pinned.
      active_bg = page.evaluate_script("getComputedStyle(document.querySelector('.folder-panel .view-toggle .toggle.active')).backgroundColor")
      idle_bg = page.evaluate_script("getComputedStyle(document.querySelector('.folder-panel .view-toggle .toggle:not(.active)')).backgroundColor")
      assert_not_equal idle_bg, active_bg, "the active view button must be filled, not flattened (#{active_bg} vs #{idle_bg})"
      assert_not_equal "rgba(0, 0, 0, 0)", active_bg, "the active view button must not be transparent"
      assert_selector ".filechooser-row", text: "base.stl"
      assert_selector ".filechooser-row", text: "lid.stl"
      assert_no_selector ".attachments-grid .attachment-tile"
    end

    # THE ROW, NOT THE COOKIE (the page-wide `project_view` cookie retired with the toggle). A fresh
    # visit with no params must find the same browser, or the write did not land.
    visit project_path(@project)
    within(panel_for(models)) { assert_selector ".filechooser--inline .filechooser-col", count: 1 }
    assert_equal "browser", @project.reload.panels.dig("views", "folder:#{models.node_id}")
    assert_no_console_errors
  end

  # A ROW ANSWERS A RIGHT-CLICK WITH THE FILE MENU (2026-11-16, the owner's report: "right clicking
  # doesn't work in browser mode"). The tiles and the list rows of this page have carried the menu
  # since it shipped. A browsed row is built in the browser from /library/children and carried
  # nothing, so a right-click there raised the browser's own menu: measured before the fix, the row's
  # `data-action` was `click->fileopen#click` alone and `.file-menu` never appeared.
  #
  # ONLY A BROWSER CAN SEE THIS. library_browse_test.rb proves the listing carries the payload; it
  # cannot prove a row wears it, that Stimulus binds an action on an element inserted after connect,
  # or that the menu the panel's `filemenu` controller builds from it is the one a tile gets.
  def local(href) = href.sub(%r{\Ahttps?://[^/]+}, "")

  def menu_entries = all(".file-menu [role='menuitem']").map(&:text)

  test "a file row answers a right-click with the file menu a tile gets" do
    open_firmware
    main = @user.nodes.find_by!(name: "main.c")

    within(panel_for(@firmware)) { find(".filechooser-row.is-file", text: "main.c").right_click }

    # APPENDED TO <body>, so it is asked of the page and not of the panel.
    assert_selector ".file-menu[role='menu'][aria-label='Actions for main.c']"
    assert_equal [ "Add note", "Open", "Details", "Download", "Delete" ], menu_entries
    assert_equal file_path(main.node_id), local(find(".file-menu a", text: "Open")[:href])
    assert_equal files_path(folder: @firmware.node_id, selected: main.node_id),
                 local(find(".file-menu a", text: "Details")[:href])
    assert_equal blob_file_path(main.node_id, download: 1), local(find(".file-menu a", text: "Download")[:href])

    # DELETE ASKS THE FILE'S OWN QUESTION AND IS AIMED AT THE FILE. Dismissed, not accepted: these
    # are bare rows (the header says why), and a delete through the port is a different answer on
    # each backend. The url is read off the row, which is where the controller reads it.
    question = dismiss_confirm { find(".file-menu button", text: "Delete").click }
    assert_equal "Delete main.c?", question
    row = within(panel_for(@firmware)) { find(".filechooser-row.is-file", text: "main.c") }
    assert_equal file_path(main.node_id), row["data-delete-url"]
    assert @user.nodes.present.exists?(node_id: main.node_id), "a dismissed delete deleted"
    assert_no_console_errors
  end

  # A WRITE, END TO END, through the one entry that needs no port: the note is posted to the url
  # the row carried, and the page comes back with the browser mounted again.
  test "Add note from a browsed row saves the note" do
    open_firmware
    main = @user.nodes.find_by!(name: "main.c")

    within(panel_for(@firmware)) { find(".filechooser-row.is-file", text: "main.c").right_click }
    find(".file-menu button", text: "Add note").click
    find(".note-popover textarea").set("reflash before the show")
    across_reload { find(".note-popover [data-role='save']").click }

    # THE CONTROLLER RELOADS THE PAGE ONCE THE NOTE IS IN. `across_reload` waited for the new
    # document, so these ask it and nothing else; the columns are back because the reloaded panel
    # mounted its browser again.
    assert_no_selector ".note-popover"
    within(panel_for(@firmware)) { assert_selector ".filechooser-row", text: "main.c" }
    bodies = @user.maker_notes.where(node_id: main.node_id).map { |note| note.body.to_plain_text }
    assert_equal [ "reflash before the show" ], bodies
    assert_no_console_errors
  end

  # A FOLDER'S MENU IS DELETE ALONE, as it is on the Library's own folder rows, and a plain click
  # still descends: the menu's action is added beside the row's listener, not in place of it.
  test "a folder row's menu is Delete alone, and a click still opens the folder" do
    open_firmware

    within(panel_for(@firmware)) { find(".filechooser-row", text: "src").right_click }
    assert_equal [ "Delete" ], menu_entries
    question = dismiss_confirm { find(".file-menu button", text: "Delete").click }
    assert_equal "Delete the folder src and everything in it?", question
    assert @user.nodes.present.exists?(node_id: @src.node_id), "a dismissed delete deleted"

    within(panel_for(@firmware)) do
      find(".filechooser-row", text: "src").click
      assert_selector ".filechooser--inline .filechooser-col", count: 2
      # A row in a column opened later is wired the same way: every listing carries the payload.
      find(".filechooser-row.is-file", text: "led.c").right_click
    end
    assert_selector ".file-menu[aria-label='Actions for led.c']"
    assert_equal files_path(folder: @src.node_id, selected: @led.node_id),
                 local(find(".file-menu a", text: "Details")[:href])
    assert_no_console_errors
  end

  # THE KEYBOARD'S DOOR (Shift+F10) is the panel's delegated listener, which finds a row by the
  # action it carries; Escape hands focus back to the row, which is a real link.
  test "the menu opens from the keyboard on a focused row" do
    open_firmware
    row = within(panel_for(@firmware)) { find(".filechooser-row.is-file", text: "main.c") }
    page.execute_script("arguments[0].focus()", row)

    page.send_keys([ :shift, :f10 ])
    assert_selector ".file-menu[role='menu'][aria-label='Actions for main.c']"
    assert_equal "Add note", page.evaluate_script("document.activeElement.textContent")

    page.send_keys(:escape)
    assert_no_selector ".file-menu"
    assert page.evaluate_script("document.activeElement === arguments[0]", row), "focus did not return to the row"
    assert_no_console_errors
  end

  # THE NESTED HOST TOO. A repository below depth one mounts its browser inside its parent panel's
  # section, which sits under that panel's `filemenu` controller like everything else in it.
  test "a row in a nested repository's browser answers a right-click" do
    tools = dir!("tools", @folder.node_id)
    nested = dir!("bootloader", tools.node_id)
    dir!(Library::RepoMetadata::DIR_NAME, nested.node_id)
    boot = file!("boot.c", nested.node_id)

    visit project_path(@project)
    within(panel_for(tools)) do
      open_section(/bootloader/i)
      find(".filechooser-row.is-file", text: "boot.c").right_click
    end

    assert_selector ".file-menu[aria-label='Actions for boot.c']"
    assert_equal file_path(boot.node_id), local(find(".file-menu a", text: "Open")[:href])
    assert_no_console_errors
  end

  # THE CONTROL WAS RENDERED LIVE AND INERT AT THE ROOT. `back()` opens with
  # `if (this.trail.length === 0) return`, so at the browser's top level the button was focusable,
  # styled as available, and did nothing when clicked — §14d's "looks available, is absent" shape,
  # with the added cost that here the maker can SEE the control that does nothing.
  #
  # A SYSTEM TEST BECAUSE ONLY A BROWSER KNOWS WHETHER A CONTROL IS VISIBLE. `assert_select` asks
  # about elements in a document; this is about a rendered box, and the server writes ONE EMPTY DIV
  # here — the bar, the button and the crumbs are all built by `mount()` after a fetch.
  #
  # BOTH DIRECTIONS, AND THE SECOND IS THE ONE THAT KEEPS THE FIX HONEST: hiding the control
  # unconditionally would satisfy the root assertion and delete the feature, which is the same
  # silent-no-op this test exists to close.
  test "the browser offers no Back at its root, and does below it" do
    open_firmware

    within(panel_for(@firmware)) do
      assert_selector ".filechooser-crumbs", text: @firmware.name
      assert_no_selector ".filechooser-back"

      find(".filechooser-col .filechooser-row", text: "src").click
      assert_selector ".filechooser-crumbs", text: "src"
      assert_selector ".filechooser-back"

      find(".filechooser-back").click
      assert_selector ".filechooser--inline .filechooser-col", count: 1
      assert_no_selector ".filechooser-back"
    end
    assert_no_console_errors
  end
end
