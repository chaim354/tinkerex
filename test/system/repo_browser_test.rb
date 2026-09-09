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
      find("summary", text: /bootloader/i).click
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
end
