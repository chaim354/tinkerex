require "application_system_test_case"

# A REPOSITORY'S SECTION ON THE PROJECT PAGE: closed on arrival, and opening it mounts the
# Finder-style Miller-columns browser (lib/file_chooser.js in `browse` mode) inside it.
#
# WHY THIS TIER AND NOT AN INTEGRATION TEST — the same argument file_chooser_test.rb makes for the
# modal, and it is stronger here. The server renders ONE EMPTY DIV: every column, every row and
# every href is built in the browser after a `fetch`, and the mount is triggered by a `toggle`
# event on an ancestor `<details>` that a Ruby test cannot fire. project_attachments_test.rb pins
# what the server writes (the values, the closed section, the absence of tiles) and can prove
# nothing at all about whether opening the section does anything — which is exactly the failure
# shape §14d records for a `data-controller` that resolves to nothing: a silent no-op, no console
# warning, the page perfectly healthy and the feature simply absent.
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
    folder = project_folder_rows!(@user, @project)

    @firmware = dir!("firmware", folder.node_id)
    dir!(Library::RepoMetadata::DIR_NAME, @firmware.node_id) # what makes it a repository
    @src = dir!("src", @firmware.node_id)
    file!("README.md", @firmware.node_id)
    file!("main.c", @firmware.node_id)
    file!(".DS_Store", @firmware.node_id)
    @led = file!("led.c", @src.node_id)
  end

  def dir!(name, parent) = @user.nodes.create!(node_id: SecureRandom.uuid, name:, kind: "dir", parent_node_id: parent)
  def file!(name, parent) = @user.nodes.create!(node_id: SecureRandom.uuid, name:, kind: "file", parent_node_id: parent)

  def open_firmware
    visit project_path(@project)
    # NOTHING IS MOUNTED UNTIL THE SECTION IS OPENED, and that is the point of the laziness: the
    # controller connects on page load, so a browser that mounted in `connect` regardless of the
    # details' state would already have fetched a column here.
    #
    # `visible: :all` ON BOTH, AND IT IS LOAD-BEARING ON THE SECOND. A closed `<details>` hides
    # everything inside it, so the DEFAULT `assert_no_selector ".filechooser--inline"` passes here
    # whether or not anything was mounted — a guard that cannot fail for the reason it exists
    # (§15). Asked of the whole DOM, it means what it says: the columns do not exist yet.
    assert_selector ".repo-browser", visible: :all
    assert_no_selector ".filechooser--inline", visible: :all
    # CASE-INSENSITIVE, because `.attachment-group-head` is `text-transform: uppercase` and
    # Selenium reports a summary's RENDERED text — "FIRMWARE", not "firmware". The integration
    # test's `assert_select` reads the source instead, which is why the two spell this differently.
    find("summary", text: /firmware/i).click
  end

  test "opening a repository section mounts one column, hiding what the Files page hides" do
    open_firmware

    assert_selector ".filechooser--inline .filechooser-col", count: 1
    within(".filechooser-col") do
      assert_selector ".filechooser-row", text: "src"
      assert_selector ".filechooser-row", text: "README.md"
      assert_selector ".filechooser-row", text: "main.c"
    end
    # THE HIDDEN SET, which is LibraryBrowseController#children's `visible_entries` and not the
    # browser's own filter — the module has none. `.git` is the marker Node keeps indexed and never
    # renders; a stray `.DS_Store` is ordinary NAS clutter.
    assert_no_selector ".filechooser-row", text: ".git"
    assert_no_selector ".filechooser-row", text: ".DS_Store"

    # FOLDERS BEFORE FILES, THEN CASE-INSENSITIVE BY NAME — the endpoint's own ordering
    # (`sort_by { [dir? ? 0 : 1, name.downcase] }`), asserted on the rendered column because that
    # is the only place a change to it would show. `main.c` before `README.md` IS that rule: an
    # ASCII sort would put the capital first, which is what the downcase exists to prevent.
    names = all(".filechooser-col .filechooser-row").map { |row| row.text.sub(/\A[^\w.]+\s*/, "") }
    assert_equal %w[src main.c README.md], names

    assert_no_console_errors
  end

  test "a folder descends into a second column and a file is a real link to its page" do
    open_firmware

    find(".filechooser-row", text: "src").click
    assert_selector ".filechooser--inline .filechooser-col", count: 2
    assert_selector ".filechooser-col:last-child .filechooser-row", text: "led.c"

    # A REAL `<a href>`, NOT A ROW WITH A CLICK HANDLER. Found by href rather than by clicking the
    # text, so the assertion is about the ELEMENT: a `div` that navigated on click would satisfy a
    # `click` + `assert_current_path` pair and still break middle-click, ⌘-click and the keyboard.
    link = find(".filechooser-row.is-file[href='#{file_path(@led.node_id)}']")
    assert_equal "a", link.tag_name
    link.click
    assert_current_path file_path(@led.node_id)
  end

  test "Back pops a column" do
    open_firmware

    find(".filechooser-row", text: "src").click
    assert_selector ".filechooser--inline .filechooser-col", count: 2

    find(".filechooser--inline .filechooser-back").click
    assert_selector ".filechooser--inline .filechooser-col", count: 1
    assert_no_selector ".filechooser-row", text: "led.c"
    assert_no_console_errors
  end
end
