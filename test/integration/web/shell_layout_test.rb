require "test_helper"

module Web
  # The application shell (spec §5): the rail with one active section, the top bar's breadcrumb
  # slot and search field, the theme and rail-collapse cookies rendered server-side (no inline
  # script under the CSP), and the self-hosted fonts actually resolving.
  class ShellLayoutTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "shell-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
    end

    test "a signed-in page renders the rail with exactly one active section" do
      get files_path
      assert_response :success
      assert_select "body.app-shell aside.rail"
      assert_select "aside.rail a.rail-link[aria-current='page']", count: 1, text: "Library"
    end

    test "each top-level section lights its own link" do
      { root_path => "Home", projects_path => "All projects", files_models_path => "3D models",
        inventory_items_path => "Inventory", tools_path => "Tools",
        trash_index_path => "Trash" }.each do |path, label|
        get path
        assert_response :success
        assert_select "aside.rail a.rail-link[aria-current='page']", count: 1, text: label
      end
    end

    # Stage 2, S2-6: the settings hub's door in the rail foot, not the main nav -- it lights on
    # its own hub AND on its child (settings/tags), the same way "a nested controller lights its
    # family" pins Projects/Models below, but scoped to .rail-foot since Settings is a foot control,
    # not a `.rail-link` -- ShellHelper#sidebar_current's [:settings] lights this link alone.
    test "the rail foot links to Settings and lights it on the hub and its children" do
      get projects_path
      assert_select "aside.rail .rail-foot a.rail-btn.rail-settings[href=?]", settings_path

      get settings_path
      assert_select "aside.rail .rail-foot a.rail-btn.rail-settings[aria-current='page']"

      get settings_tags_path
      assert_select "aside.rail .rail-foot a.rail-btn.rail-settings[aria-current='page']"

      # NOT lit on a page the settings hub merely links TO -- Suppliers keeps lighting Inventory,
      # its own sidebar entry, not Settings.
      get suppliers_path
      assert_select "aside.rail .rail-foot a.rail-btn.rail-settings[aria-current='page']", count: 0
      assert_select "aside.rail a.rail-link[aria-current='page']", text: "Inventory"
    end

    test "the rail's first link is Home, at the root path" do
      get files_path
      assert_select "nav.rail-nav li:first-child a.rail-link[href='/']", text: "Home"
      # Library -- not Home -- is what GET /files lights; Home carries no aria-current here.
      assert_select "nav.rail-nav li:first-child a.rail-link[aria-current]", count: 0

      get root_path
      assert_response :success
      assert_select "aside.rail a.rail-link[aria-current='page']", count: 1, text: "Home"
    end

    test "a nested controller lights its family" do
      project = @user.maker_projects.create!(name: "Desk Lamp")
      get new_project_attachment_path(project)
      assert_select "aside.rail a.rail-link[aria-current='page']", count: 1, text: "Desk Lamp"
      get project_path(project)
      assert_select "aside.rail a.rail-link[aria-current='page']", count: 1, text: "Desk Lamp"
      # settings/shelves (slice 5) and settings/tags are nested controllers whose family is the
      # rail FOOT's Settings, not a place: Settings lights and no `.rail-link` does. Shelves lit
      # 3D models from 2026-09-10 until it moved back under Settings.
      [ settings_shelves_path, settings_tags_path ].each do |path|
        get path
        assert_select "aside.rail .rail-foot a.rail-btn.rail-settings[aria-current='page']", count: 1
        assert_select "aside.rail a.rail-link[aria-current='page']", count: 0
      end
    end

    test "the sign-in page has no rail and no shell class, whatever the rail cookie says" do
      delete destroy_user_session_path
      cookies[:rail] = "collapsed"
      get new_user_session_path
      assert_response :success
      assert_select "aside.rail", count: 0
      assert_select "body.app-shell", count: 0
      # The collapsed rules hide `.brand-name`, and the auth card has one (found in review).
      assert_select "body.rail--collapsed", count: 0
    end

    test "the theme comes from the cookie and defaults to light" do
      get files_path
      assert_select "html[data-theme='light']"
      assert_select "meta[name='theme-color'][content='#f4f2ed']"
      assert_select "meta[name='color-scheme'][content='light']"

      cookies[:theme] = "dark"
      get files_path
      assert_select "html[data-theme='dark']"
      assert_select "meta[name='theme-color'][content='#141512']"
      assert_select "meta[name='color-scheme'][content='dark']"

      cookies[:theme] = "system"
      get files_path
      assert_select "html[data-theme='system']"
      assert_select "meta[name='theme-color'][content='#f4f2ed']"
      assert_select "meta[name='color-scheme'][content='light dark']"

      cookies[:theme] = "purple"
      get files_path
      assert_select "html[data-theme='light']"
    end

    test "the rail collapse state comes from the cookie" do
      get files_path
      assert_select "body.rail--collapsed", count: 0
      cookies[:rail] = "collapsed"
      get files_path
      assert_select "body.rail--collapsed"
      assert_select "aside.rail [data-action='rail#toggle'][aria-expanded='false']"
    end

    test "the top bar carries the sitewide search on every page" do
      get projects_path
      assert_select "header.topbar form.topbar-search[action=?][method='get'] " \
                    "input[type='search'][name='q'][placeholder='Search everything']", search_path
      # AND IT RENDERS BLANK on a page that has its own `q` — @q means the Files search on /files,
      # the inventory search on /inventory — so echoing it would put the wrong term in a box that
      # now means "search everything" (review, S2-5).
      get files_path(q: "widget")
      assert_select "header.topbar form.topbar-search input[name='q']" do |inputs|
        assert_nil inputs.first["value"], "the top bar echoed the Files page's query"
      end
    end

    test "a page with a breadcrumb renders it in the top bar, not in main" do
      project = @user.maker_projects.create!(name: "Desk Lamp")
      get project_path(project)
      assert_select "header.topbar nav.breadcrumb a", text: "Projects"
      assert_select "main nav.breadcrumb", count: 0
      # The 3D models view (slice 5) is a Library page: its top bar carries a breadcrumb, not a title.
      get files_models_path
      assert_select "header.topbar nav.breadcrumb a[href=?]", files_path, text: "Files"
      assert_select "header.topbar nav.breadcrumb [aria-current='page']", text: "3D models"
      assert_select "main nav.breadcrumb", count: 0
    end

    # Four tabs, not every sidebar entry: Trash is reached from the sidebar alone, so its page lights
    # no tab rather than a wrong one.
    test "the phone tab bar carries four tabs and lights none on a page it does not carry" do
      get trash_index_path
      assert_select "nav.tabbar a.tabbar-link", count: 4
      assert_select "nav.tabbar a.tabbar-link[aria-current='page']", count: 0
    end

    test "the sidebar lists the eight most recently updated active projects, then All projects" do
      projects = 10.times.map { |i| @user.maker_projects.create!(name: "P#{i}") }
      projects.each_with_index { |p, i| p.update_column(:updated_at, i.days.ago) }
      @user.maker_projects.create!(name: "Shelved", status: "archived")
      get files_path
      names = css_select("aside.rail a.rail-project .rail-label").map { |e| e.text.strip }
      assert_equal %w[P0 P1 P2 P3 P4 P5 P6 P7], names
      assert_select "aside.rail a.rail-link[href=?]", projects_path, text: "All projects"
    end

    test "an older project's page lights All projects, so one link is always lit" do
      projects = 9.times.map { |i| @user.maker_projects.create!(name: "P#{i}") }
      projects.each_with_index { |p, i| p.update_column(:updated_at, i.days.ago) }
      oldest = projects.last
      get project_path(oldest)
      assert_select "aside.rail a.rail-link[aria-current='page']", count: 1, text: "All projects"
    end

    test "a pinned folder sits under Places and lights when you are in it or beneath it" do
      laser = @user.nodes.create!(node_id: "dir-laser", name: "laser", kind: "dir")
      jigs = @user.nodes.create!(node_id: "dir-jigs", name: "jigs", kind: "dir", parent_node_id: laser.node_id)
      @user.maker_pins.create!(node_id: laser.node_id)

      get files_path(folder: jigs.node_id)
      assert_select "aside.rail a.rail-pin[href=?] svg.folder-glyph", files_path(folder: laser.node_id)
      assert_select "aside.rail a.rail-link[aria-current='page']", count: 1, text: "laser"

      get files_path
      assert_select "aside.rail a.rail-link[aria-current='page']", count: 1, text: "Library"
    end

    # A pin and a pin inside it: the DEEPER one lights (design-system.md rule 8). The test above pins
    # one folder, so "the first pinned crumb" and "the deepest" agree there and cannot be told apart.
    test "with a pinned folder inside a pinned folder, the deeper one lights" do
      laser = @user.nodes.create!(node_id: "dir-laser", name: "laser", kind: "dir")
      jigs = @user.nodes.create!(node_id: "dir-jigs", name: "jigs", kind: "dir", parent_node_id: laser.node_id)
      @user.maker_pins.create!(node_id: laser.node_id)
      @user.maker_pins.create!(node_id: jigs.node_id)

      get files_path(folder: jigs.node_id)
      assert_select "aside.rail a.rail-link[aria-current='page']", count: 1, text: "jigs"
      get files_path(folder: laser.node_id)
      assert_select "aside.rail a.rail-link[aria-current='page']", count: 1, text: "laser"
    end

    # Collapsed (and below 1100px) project and pin links hide with their labels, so the lit one's
    # FAMILY link carries the visible mark there. A class, never aria-current: the markup still lights
    # exactly one link. shell_test.rb checks that the collapsed rail actually draws it.
    test "a lit pin or project marks its family link for the collapsed rail" do
      laser = @user.nodes.create!(node_id: "dir-laser", name: "laser", kind: "dir")
      @user.maker_pins.create!(node_id: laser.node_id)
      project = @user.maker_projects.create!(name: "Desk Lamp")

      get files_path(folder: laser.node_id)
      assert_select "aside.rail a.rail-family-lit", count: 1, text: "Library"
      assert_select "aside.rail a.rail-link[aria-current='page']", count: 1, text: "laser"
      get project_path(project)
      assert_select "aside.rail a.rail-family-lit", count: 1, text: "All projects"
      assert_select "aside.rail a.rail-link[aria-current='page']", count: 1, text: "Desk Lamp"

      # The family link lit in its own right is not ALSO marked, and nothing else is.
      get files_path
      assert_select "aside.rail a.rail-family-lit", count: 0
      get projects_path
      assert_select "aside.rail a.rail-family-lit", count: 0
    end

    test "a pin to a tombstoned folder is hidden and kept" do
      laser = @user.nodes.create!(node_id: "dir-laser", name: "laser", kind: "dir")
      @user.maker_pins.create!(node_id: laser.node_id)
      laser.update!(deleted: true)
      get files_path
      assert_select "aside.rail a.rail-pin", count: 0
      assert_equal 1, @user.maker_pins.count
    end

    test "Inventory joins the sidebar once there are items, or while you are in it" do
      get files_path
      assert_select "aside.rail a.rail-link[href=?]", inventory_items_path, count: 0
      get inventory_items_path
      assert_select "aside.rail a.rail-link[aria-current='page']", count: 1, text: "Inventory"
      @user.maker_inventory_items.create!(name: "M3 bolt")
      get files_path
      assert_select "aside.rail a.rail-link[href=?]", inventory_items_path, count: 1
    end

    test "the phone tab bar is Home, Library, Projects and Tools" do
      get files_path
      labels = css_select("nav.tabbar a.tabbar-link span").map { |e| e.text.strip }
      assert_equal %w[Home Library Projects Tools], labels
      assert_select "nav.tabbar a.tabbar-link[aria-current='page']", count: 1, text: "Library"
    end

    test "the stylesheet references fingerprinted, servable Plex fonts" do
      get Rails.application.assets.resolver.resolve("application.css")
      assert_response :success
      css = response.body
      %w[ibm-plex-sans ibm-plex-sans-italic ibm-plex-mono-400 ibm-plex-mono-500].each do |name|
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
