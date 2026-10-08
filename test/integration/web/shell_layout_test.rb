require "test_helper"

module Web
  # The application shell (spec §5): the rail with one active section, the current-project card
  # that keeps the switcher the topbar tests pin, the top bar's breadcrumb slot and search field,
  # the theme and rail-collapse cookies rendered server-side (no inline script under the CSP),
  # and the self-hosted fonts actually resolving.
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
      assert_select "aside.rail a.rail-link[aria-current='page']", count: 1, text: "Files"
    end

    test "each top-level section lights its own link" do
      { root_path => "Home", projects_path => "Projects", models_path => "Models",
        inventory_items_path => "Inventory", tools_path => "Tools",
        trash_index_path => "Trash" }.each do |path, label|
        get path
        assert_response :success
        assert_select "aside.rail a.rail-link[aria-current='page']", count: 1, text: label
      end
    end

    # Stage 2, S2-6: the settings hub's door in the rail foot, not the main nav -- it lights on
    # its own hub AND on its child (settings/tags), the same way "a nested controller lights its
    # family" pins Projects/Models below, but scoped to .rail-foot since Settings is not one of
    # rail_links's seven sections (the phone tab bar mirror stays at 7 -- see that test below).
    test "the rail foot links to Settings and lights it on the hub and its children" do
      get projects_path
      assert_select "aside.rail .rail-foot a.rail-btn.rail-settings[href=?]", settings_path

      get settings_path
      assert_select "aside.rail .rail-foot a.rail-btn.rail-settings[aria-current='page']"

      get settings_tags_path
      assert_select "aside.rail .rail-foot a.rail-btn.rail-settings[aria-current='page']"

      # NOT lit on a page the settings hub merely links TO -- Suppliers keeps lighting Inventory,
      # its own rail_links section, not Settings.
      get suppliers_path
      assert_select "aside.rail .rail-foot a.rail-btn.rail-settings[aria-current='page']", count: 0
      assert_select "aside.rail a.rail-link[aria-current='page']", text: "Inventory"
    end

    test "the rail's first link is Home, at the root path" do
      get files_path
      assert_select "nav.rail-nav li:first-child a.rail-link[href='/']", text: "Home"
      # Files -- not Home -- is what GET /files lights; Home carries no aria-current here.
      assert_select "nav.rail-nav li:first-child a.rail-link[aria-current]", count: 0

      get root_path
      assert_response :success
      assert_select "aside.rail a.rail-link[aria-current='page']", count: 1, text: "Home"
    end

    test "a nested controller lights its family" do
      project = @user.maker_projects.create!(name: "Desk Lamp")
      get new_project_attachment_path(project)
      assert_select "aside.rail a.rail-link[aria-current='page']", count: 1, text: "Projects"
      get shelves_path
      assert_select "aside.rail a.rail-link[aria-current='page']", count: 1, text: "Models"
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

    test "the top bar carries a second, phone-only project switcher with its own id" do
      @user.maker_projects.create!(name: "Desk Lamp")
      get files_path
      assert_select "header.topbar form.topbar-project[action=?] select[name='project_id']#topbar_project_id", current_project_path
      assert_select "select#topbar_project_id option[value='']", text: /none/i
      assert_select "select#project_id", count: 1
      assert_select "select#topbar_project_id", count: 1
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
      get models_path
      assert_select "header.topbar .topbar-title", text: "Models"
    end

    test "the current-project card keeps the switcher the topbar tests pin" do
      @user.maker_projects.create!(name: "Desk Lamp")
      get files_path
      assert_select "aside.rail .current-project select[name='project_id']"
      assert_select "aside.rail form[action=?] select[name='project_id'] option[value='']", current_project_path,
                    text: /none/i
      assert_select "aside.rail .current-project-hint", text: /land here/
    end

    test "the phone tab bar mirrors the rail" do
      get trash_index_path
      assert_select "nav.tabbar a.tabbar-link", count: 7
      assert_select "nav.tabbar a.tabbar-link[aria-current='page']", count: 1, text: "Trash"
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
