require "test_helper"

module Web
  # The application shell (Shop manual spec §7 and §11.2, slice 3; design-system.md rules 7 to 9):
  # the strip with its four places and at most one lit, the left column a page supplies or its
  # section's default, the caps path at the head of main, the phone tab bar, the theme cookie
  # rendered server-side (no inline script under the CSP), and the self-hosted fonts resolving.
  #
  # THE ONE-LIT-PLACE GUARD (spec §10) is "every page lights at most one place and at most one
  # column row", walked over every kind of signed-in page below. MUTATION-CHECKED (2026-11-19):
  #   1. `place_aria` answering "page" for every place: "/files lights 4 places".
  #   2. `row_aria` comparing only the key's first element (so every folder row lights on a folder):
  #      "/files?folder=d-laser lights 2 column rows".
  #   3. The tab bar lighting from its own rule (the 3D models view lighting nothing there):
  #      "/files/models: the tab bar lights [] where the strip lights [\"Library\"]".
  #   4. `home-recent` dropped from Home's section id: "/ links #home-recent, which the page does not carry".
  class ShellLayoutTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze
    PLACES = %w[Library Projects Tools Inventory].freeze

    setup do
      @user = User.create!(email: "shell-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
    end

    def lit_places = css_select("header.strip nav.strip-places a.strip-place[aria-current='page']").map { |a| a.text.strip }
    def lit_tabs = css_select("nav.tabbar a.tabbar-link[aria-current='page']").map { |a| a.text.strip }
    def lit_rows = css_select("aside.column .column-row[aria-current]").map { |a| a.css(".column-row-name").text.strip }
    def column_rows = css_select("aside.column .column-row .column-row-name").map { |e| e.text.strip }

    test "every signed-in page carries the strip with all four places, in order" do
      get root_path
      assert_response :success
      assert_select "body.app-shell header.strip"
      assert_equal PLACES, css_select("header.strip nav.strip-places[aria-label='Main'] a.strip-place").map { |a| a.text.strip }
      assert_equal [ files_path, projects_path, tools_path, inventory_items_path ],
                   css_select("header.strip a.strip-place").map { |a| a["href"] }
      # The wordmark is Home's door, and it lights nothing.
      assert_select "header.strip a.brand[href='/'][aria-label='Tinkerex home'] .brand-name", text: "Tinkerex"
      assert_select "header.strip a.brand[aria-current]", count: 0
      assert_select "aside.rail", count: 0
      assert_select "header.topbar", count: 0
    end

    # PROPOSAL 2: Home, Search, Settings and Help light no place; the 3D models view and Trash are
    # Library pages and light Library (this reversed rule 8's old exception); a project's pages and
    # Suppliers light the place they serve.
    test "each section lights its own place, or none" do
      project = @user.maker_projects.create!(name: "Desk Lamp")
      { root_path => [], files_path => %w[Library], files_models_path => %w[Library],
        trash_index_path => %w[Library], projects_path => %w[Projects], project_path(project) => %w[Projects],
        new_project_attachment_path(project) => %w[Projects], inventory_items_path => %w[Inventory],
        suppliers_path => %w[Inventory], locations_path => %w[Inventory], tools_path => %w[Tools],
        settings_path => [], settings_tags_path => [], edit_user_registration_path => [], help_path => [],
        search_path => [], search_path(q: "lamp") => [] }.each do |path, places|
        get path
        assert_response :success
        assert_equal places, lit_places, "#{path} lights #{lit_places.inspect}"
      end
    end

    # THE GUARD (spec §10, "one lit place"): every page, at most one place and at most one column row;
    # the phone tab bar lights exactly what the strip does; and every in-page link in the column
    # names an element the page carries, so a section that leaves a page cannot leave its link.
    test "no page lights two places or two column rows, and the tab bar agrees with the strip" do
      laser = @user.nodes.create!(node_id: "d-laser", name: "laser", kind: "dir", mtime: 1, size: 0)
      @user.nodes.create!(node_id: "d-jigs", name: "jigs", kind: "dir", parent_node_id: "d-laser", mtime: 1, size: 0)
      @user.nodes.create!(node_id: "n-plate", name: "plate.dxf", kind: "file", parent_node_id: "d-jigs",
                          mtime: 1_000_000_000, size: 10, content_hash: "h-plate", current_version_id: "v-plate")
      @user.maker_pins.create!(node_id: laser.node_id)
      @user.tool_pins.pin!(Maker::ToolPins::CALCULATOR)
      project = @user.maker_projects.create!(name: "Desk Lamp", kind: "electronics")
      model = @user.maker_models.create!(title: "Wall Bracket")
      bin = @user.maker_locations.create!(name: "Bin C2")
      shop = @user.maker_suppliers.create!(name: "Parts house")
      item = @user.maker_inventory_items.create!(name: "M3 bolt", location: bin, supplier: shop, min_quantity: 5)

      pages = [
        root_path, files_path, files_path(folder: "d-laser"), files_path(folder: "d-jigs"), file_path("n-plate"),
        files_path(q: "plate"), files_models_path, model_path(model), trash_index_path,
        projects_path, projects_path(archived: 1), projects_path(kind: "electronics"), project_path(project),
        new_project_attachment_path(project), new_project_path,
        inventory_items_path, inventory_items_path(low: 1), inventory_items_path(location: bin.id),
        inventory_items_path(supplier: shop.id), inventory_item_path(item), suppliers_path, locations_path,
        tools_path, settings_path, settings_tags_path, settings_shelves_path, settings_library_path,
        settings_devices_path, edit_user_registration_path, help_path, search_path, search_path(q: "plate")
      ]
      pages.each do |path|
        get path
        assert_response :success, "#{path} did not render"
        assert_operator lit_places.size, :<=, 1, "#{path} lights #{lit_places.size} places: #{lit_places.inspect}"
        assert_operator lit_rows.size, :<=, 1, "#{path} lights #{lit_rows.size} column rows: #{lit_rows.inspect}"
        assert_equal lit_places, lit_tabs, "#{path}: the tab bar lights #{lit_tabs.inspect} where the strip lights #{lit_places.inspect}"
        css_select("aside.column a.column-row[href^='#']").each do |a|
          id = a["href"].delete_prefix("#")
          assert_select "##{id}", { minimum: 1 }, "#{path} links #{a["href"]}, which the page does not carry"
        end
      end
    end

    # THE LIBRARY'S COLUMN: the root, the chain down to the folder on screen, its subfolders (hidden
    # ones excepted, as the Library lists them), then 3D models and Trash. The folder on screen is
    # the one lit row; on a file's page that is the file's folder.
    test "the Library column lists the folder chain and its subfolders, and lights the folder on screen" do
      @user.nodes.create!(node_id: "d-laser", name: "laser", kind: "dir", mtime: 1, size: 0)
      @user.nodes.create!(node_id: "d-cnc", name: "cnc", kind: "dir", mtime: 1, size: 0)
      @user.nodes.create!(node_id: "d-jigs", name: "jigs", kind: "dir", parent_node_id: "d-laser", mtime: 1, size: 0)
      @user.nodes.create!(node_id: "d-dot", name: ".cache", kind: "dir", parent_node_id: "d-laser", mtime: 1, size: 0)
      @user.nodes.create!(node_id: "n-plate", name: "plate.dxf", kind: "file", parent_node_id: "d-laser",
                          mtime: 1_000_000_000, size: 10, content_hash: "h-plate", current_version_id: "v-plate")

      get files_path
      assert_equal [ "Library", "cnc", "laser", "3D models", "Trash" ], column_rows
      assert_equal [ "Library" ], lit_rows
      assert_select "aside.column a.column-row[href=?][aria-current='page']", files_path

      get files_path(folder: "d-laser")
      assert_equal [ "Library", "laser", "jigs", "3D models", "Trash" ], column_rows
      assert_equal [ "laser" ], lit_rows
      assert_select "aside.column a.column-row[href=?]", files_path(folder: "d-jigs") do |rows|
        assert_equal "--depth: 2", rows.first["style"]
      end

      get file_path("n-plate")
      assert_equal [ "laser" ], lit_rows

      get files_models_path
      assert_equal [ "3D models" ], lit_rows
      get trash_index_path
      assert_equal [ "Trash" ], lit_rows
    end

    test "the Library column caps a folder's subfolders and opens the folder past the cap" do
      (ShellHelper::COLUMN_FOLDERS + 1).times do |i|
        @user.nodes.create!(node_id: "d-#{i}", name: format("f%03d", i), kind: "dir", mtime: 1, size: 0)
      end
      get files_path
      assert_select "aside.column a.column-row[href^=?]", "#{files_path}?folder=d-", count: ShellHelper::COLUMN_FOLDERS
      assert_select "aside.column a.column-row.column-row--more[href=?]", files_path, text: "All folders here"
    end

    # THE PROJECTS COLUMN IN ITS TWO SHAPES (spec §7): the index's filters on the index, the projects
    # everywhere else.
    test "the Projects column carries the index's filters on the index and lights the one applied" do
      @user.maker_projects.create!(name: "Desk Lamp", kind: "electronics")
      @user.maker_projects.create!(name: "Shelved", status: "archived")

      get projects_path
      assert_equal [ "All", "Archived", "Electronics & firmware" ], column_rows
      assert_equal [ "All" ], lit_rows
      get projects_path(archived: 1)
      assert_equal [ "Archived" ], lit_rows
      get projects_path(kind: "electronics")
      assert_equal [ "Electronics & firmware" ], lit_rows
      assert_select "aside.column a.column-row[href=?]", projects_path(kind: "electronics")
    end

    test "elsewhere the Projects column lists the eight most recently updated live projects" do
      projects = 10.times.map { |i| @user.maker_projects.create!(name: "P#{i}") }
      projects.each_with_index { |p, i| p.update_column(:updated_at, i.days.ago) }
      @user.maker_projects.create!(name: "Shelved", status: "archived")

      get project_path(projects.first)
      assert_equal %w[P0 P1 P2 P3 P4 P5 P6 P7] + [ "All projects", "New project" ], column_rows
      assert_equal %w[P0], lit_rows
      # Older than the eight: All projects lights, so the column still says where you are.
      get project_path(projects.last)
      assert_equal [ "All projects" ], lit_rows
      get new_project_path
      assert_equal [ "New project" ], lit_rows
    end

    test "the Inventory column carries the items, places and suppliers, and lights the view on screen" do
      bin = @user.maker_locations.create!(name: "Bin C2")
      shop = @user.maker_suppliers.create!(name: "Parts house")
      item = @user.maker_inventory_items.create!(name: "M3 bolt", location: bin, supplier: shop)

      get inventory_items_path
      assert_equal [ "All items", "Low or out", "Bin C2", "All places", "Parts house", "All suppliers" ], column_rows
      assert_equal [ "All items" ], lit_rows
      { inventory_items_path(low: 1) => "Low or out", inventory_items_path(location: bin.id) => "Bin C2",
        inventory_items_path(supplier: shop.id) => "Parts house", locations_path => "All places",
        suppliers_path => "All suppliers" }.each do |path, row|
        get path
        assert_equal [ row ], lit_rows, path
      end
      get inventory_item_path(item)
      assert_equal [], lit_rows
    end

    # HOME'S COLUMN: the page's sections, then Pinned — the pinned folders and tools that used to sit
    # on the rail of every page. A pin to a tombstoned folder is hidden and kept, so restoring the
    # folder restores the pin (Maker::Pin).
    test "Home's column links the page's sections, then the pinned folders and tools" do
      laser = @user.nodes.create!(node_id: "d-laser", name: "laser", kind: "dir", mtime: 1, size: 0)
      gone = @user.nodes.create!(node_id: "d-gone", name: "gone", kind: "dir", mtime: 1, size: 0)
      @user.maker_pins.create!(node_id: laser.node_id)
      @user.maker_pins.create!(node_id: gone.node_id)
      gone.update!(deleted: true)
      @user.tool_pins.pin!(Maker::ToolPins::CALCULATOR)
      @user.maker_projects.create!(name: "Desk Lamp")

      get root_path
      assert_equal [ "Getting started", "Active projects", "laser", "Calculator" ], column_rows
      assert_equal [ "#home-getting-started", "#home-projects" ],
                   css_select("aside.column a.column-row[href^='#']").map { |a| a["href"] }
      assert_select "aside.column a.column-row[href=?] .column-row-note", files_path(folder: "d-laser"), text: "folder"
      assert_equal [], lit_rows
      assert_equal 2, @user.maker_pins.count
    end

    test "the Settings column lists the settings pages and lights the one on screen" do
      { settings_path => "Settings", settings_tags_path => "Tags", settings_shelves_path => "Shelves",
        edit_user_registration_path => "Account", settings_devices_path => "Devices" }.each do |path, row|
        get path
        assert_response :success
        assert_equal [ row ], lit_rows, path
      end
      # Users is for an account that can manage accounts, as its own page's gate asks.
      assert_not_includes column_rows, "Users"
      @user.update!(admin: true)
      get settings_path
      assert_includes column_rows, "Users"
    end

    # A SECTION WITH NO DEFAULT COLUMN (Search) GETS NONE: main takes the width, and the strip offers
    # no Contents button to open what is not there.
    test "a page with a column offers Contents to open it, and a page without one does not" do
      get files_path
      assert_select "body .shell-body.shell-body--column > aside.column#column[aria-label='Contents']"
      assert_select "header.strip button.strip-contents[aria-controls='column'][aria-expanded='false'][data-action='shell#toggleColumn']"
      get search_path
      assert_select "aside.column", count: 0
      assert_select ".shell-body--column", count: 0
      assert_select "header.strip .strip-contents", count: 0
    end

    test "the sign-in page has no shell, whatever the old rail cookie says" do
      delete destroy_user_session_path
      cookies[:rail] = "collapsed"
      get new_user_session_path
      assert_response :success
      assert_select "header.strip", count: 0
      assert_select "aside.column", count: 0
      assert_select "body.app-shell", count: 0
      assert_select "body[data-controller]", count: 0
    end

    # THE RAIL COOKIE RETIRED WITH THE RAIL (spec §11.2): nothing reads it, so no value reaches the body.
    test "the old rail cookie changes nothing" do
      %w[collapsed expanded].each do |value|
        cookies[:rail] = value
        get files_path
        assert_select "body[class='app-shell'][data-controller='shell']"
      end
    end

    test "the theme comes from the cookie and defaults to light" do
      get files_path
      assert_select "html[data-theme='light']"
      assert_select "meta[name='theme-color'][content='#ffffff']"
      assert_select "meta[name='color-scheme'][content='light']"

      cookies[:theme] = "dark"
      get files_path
      assert_select "html[data-theme='dark']"
      assert_select "meta[name='theme-color'][content='#141512']"
      assert_select "meta[name='color-scheme'][content='dark']"

      cookies[:theme] = "system"
      get files_path
      assert_select "html[data-theme='system']"
      assert_select "meta[name='theme-color'][content='#ffffff']"
      assert_select "meta[name='color-scheme'][content='light dark']"

      cookies[:theme] = "purple"
      get files_path
      assert_select "html[data-theme='light']"
    end

    test "the strip carries the sitewide search on every page, with its slash" do
      get projects_path
      assert_select "header.strip form.strip-search[action=?][method='get'] " \
                    "input[type='search'][name='q'][placeholder='Search everything'][data-shell-target='search']", search_path
      assert_select "header.strip form.strip-search kbd.strip-kbd", text: "/"
      assert_select "header.strip a.strip-search-link[href=?][aria-label='Search']", search_path
      # AND IT RENDERS BLANK on a page that has its own `q` — @q means the Files search on /files,
      # the inventory search on /inventory — so echoing it would put the wrong term in a box that
      # means "search everything" (review, S2-5).
      get files_path(q: "widget")
      assert_select "header.strip form.strip-search input[name='q']" do |inputs|
        assert_nil inputs.first["value"], "the strip echoed the Files page's query"
      end
    end

    # THE CRUMBS LEFT THE TOP BAR FOR THE PAGE HEAD (rule 9): the caps path at the top of main, the
    # page's breadcrumb when it supplies one and its title otherwise. The crumb root of a Library page
    # reads Library.
    test "the caps path at the head of main is the page's breadcrumb, or its title" do
      project = @user.maker_projects.create!(name: "Desk Lamp")
      get project_path(project)
      assert_select "main#main > .page-path nav.breadcrumb a", text: "Projects"
      assert_select "header.strip nav.breadcrumb", count: 0
      get files_models_path
      assert_select "main > .page-path nav.breadcrumb a[href=?]", files_path, text: "Library"
      assert_select "main > .page-path nav.breadcrumb [aria-current='page']", text: "3D models"
      get projects_path
      assert_select "main > .page-path .page-path-title", text: "Projects"
      assert_select "main > .page-path nav", count: 0
    end

    test "the phone tab bar is the four places, lit as the strip lights them" do
      get files_path
      assert_equal PLACES, css_select("nav.tabbar[aria-label='Main'] a.tabbar-link span").map { |e| e.text.strip }
      assert_equal %w[Library], lit_tabs
      assert_select "nav.tabbar details", count: 0
      get root_path
      assert_equal [], lit_tabs
    end

    test "the stylesheet references fingerprinted, servable self-hosted fonts" do
      get Rails.application.assets.resolver.resolve("application.css")
      assert_response :success
      css = response.body
      # Material Symbols is KiCanvas's icon font, same-origin since bin/build-kicanvas stopped it
      # calling Google (kicanvas_test.rb asserts the viewer page then raises no CSP violation).
      %w[libre-franklin libre-franklin-italic courier-prime-400 courier-prime-700
         material-symbols-outlined].each do |name|
        font = css[%r{/assets/#{name}-[0-9a-f]{8,}\.woff2}]
        assert font, "application.css does not reference a fingerprinted #{name}.woff2"
        get font
        assert_response :success
        assert_equal "font/woff2", response.media_type
        assert response.body.start_with?("wOF2"), "#{font} is not a woff2 file"
      end
    end
  end
end
