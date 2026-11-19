require "test_helper"

module Web
  # THE SHELL'S SMALLER PROMISES, AS MARKUP (UX audit A1, A2, A6, A7, F1). The browser halves are the
  # shell_*_test.rb system tests; this pins what the server renders: the phone's More tab and what it
  # carries, the Account page lighting Settings, the search hint per platform, the theme and collapse
  # buttons named for what they do, and the app icon and manifest agreeing with the page.
  #
  # MUTATION-CHECKED (2026-11-02; each reverted, and the file re-run green after):
  #   1. `search_shortcut` answering "⌘K" whatever the user agent: the Windows arm red.
  #   2. Dropping `users/registrations` from ShellHelper::SECTIONS' settings entry: the Account test
  #      red, nothing lit in the rail.
  #   3. Dropping the title from the rail's Collapse button: the foot test red.
  #   4. `"theme_color": "#fcfbf8"` back in the manifest: the manifest test red.
  #   5. The pre-A2 family marks back (the Library link's `rail-family-lit: sidebar_family_lit?(:library)`
  #      and the helper's `pin: :library, project: :all_projects`): the family test red, Library
  #      marked for a pin whose monogram already carries the mark.
  class ShellChromeTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze
    MAC = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36".freeze
    WINDOWS = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36".freeze

    setup do
      @user = User.create!(email: "chrome-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
    end

    test "the phone tab bar's fifth tab, More, carries every rail place the four tabs do not" do
      @user.maker_inventory_items.create!(name: "M3 bolt")
      get root_path
      assert_select "nav.tabbar a.tabbar-link", count: 4
      assert_select "nav.tabbar details.menu.tabbar-more[data-controller='menu'] > summary.tabbar-link", text: "More"
      links = css_select("nav.tabbar .tabbar-sheet a.menu-item").map { |a| [ a.text.strip, a["href"] ] }
      assert_equal [ [ "Inventory", inventory_items_path ], [ "Trash", trash_index_path ], [ "Settings", settings_path ],
                     [ "Account", edit_user_registration_path ], [ "Help", help_path ] ], links
      assert_select "nav.tabbar .tabbar-sheet .theme-choice[data-controller='theme'] button[data-action='theme#choose']", count: 3
      assert_select "nav.tabbar .tabbar-sheet form[action=?] button", destroy_user_session_path, text: "Sign out"
      assert_select "nav.tabbar .tabbar-sheet [aria-current]", count: 0
    end

    # The rail's own rule: Inventory appears once there are items, or while you are in it.
    test "More offers Inventory only when the rail does" do
      get root_path
      assert_select "nav.tabbar .tabbar-sheet a[href=?]", inventory_items_path, count: 0
      assert_select "aside.rail a[href=?]", inventory_items_path, count: 0
      get inventory_items_path
      assert_select "nav.tabbar .tabbar-sheet a[href=?][aria-current='page']", inventory_items_path, count: 1
    end

    # THE ACCOUNT PAGE IS A SETTINGS PAGE (UX audit F1): it lights Settings in the rail and in More,
    # exactly one link each, the way the hub and its children do.
    test "the Account page lights Settings" do
      get edit_user_registration_path
      assert_response :success
      assert_select "aside.rail [aria-current='page']", count: 1
      assert_select "aside.rail a.rail-settings[aria-current='page']", count: 1
      assert_select "nav.tabbar .tabbar-sheet a[aria-current='page']", count: 1, text: "Settings"
    end

    test "the search hint names the shortcut this platform uses" do
      { MAC => "⌘K", WINDOWS => "Ctrl+K" }.each do |agent, hint|
        get root_path, headers: { "User-Agent" => agent }
        assert_select "header.topbar .topbar-search kbd.topbar-kbd", text: hint
        assert_select "header.topbar .topbar-search input[name='q'][aria-keyshortcuts=?]", ShellHelper::SEARCH_KEYS
      end
    end

    # EVERY RAIL-FOOT CONTROL HAS A TITLE BESIDE ITS aria-label (UX audit A7), because the icon rail
    # hides each one's words; Theme and Collapse had only the label. Theme names what a click does
    # (A6) and Collapse names the way the rail will move.
    test "the rail foot's Theme and Collapse are named for what they do, for a pointer too" do
      get root_path
      assert_select "aside.rail .rail-foot .rail-theme[title='Switch to dark'][aria-label='Switch to dark']", text: "Switch to dark"
      assert_select "aside.rail .rail-foot .rail-theme[data-theme-actions-value=?]", ShellHelper::THEME_ACTIONS.to_json
      assert_select "aside.rail .rail-foot .rail-collapse[title='Collapse navigation'][aria-label='Collapse navigation'][aria-expanded='true']"
      cookies[:theme] = "dark"
      cookies[:rail] = "collapsed"
      get root_path
      assert_select "aside.rail .rail-foot .rail-theme[title='Use system theme']", text: "Use system theme"
      assert_select "aside.rail .rail-foot .rail-collapse[title='Expand navigation'][aria-expanded='false']"
      cookies[:theme] = "system"
      get root_path
      assert_select "aside.rail .rail-foot .rail-theme[title='Switch to light']"
    end

    # THE `rail` COOKIE'S THIRD STATE (UX audit A2): `expanded` puts its class on the body, so the
    # ≤1099px track rule exempts it; junk is the width default, like an absent cookie.
    test "the rail cookie's expanded state reaches the body, and junk is ignored" do
      { "expanded" => [ 1, 0 ], "collapsed" => [ 0, 1 ], "sideways" => [ 0, 0 ] }.each do |value, (expanded, collapsed)|
        cookies[:rail] = value
        get root_path
        assert_select "body.app-shell.rail--expanded", count: expanded
        assert_select "body.app-shell.rail--collapsed", count: collapsed
      end
    end

    # A PROJECT AND A PINNED FOLDER CARRY A MONOGRAM FOR THE ICON RAIL, drawn from an attribute so the
    # link's text stays exactly the name; so their family links no longer stand in for them. A pinned
    # ADDON still hides there, and Tools still does (tool_pins_test.rb).
    test "projects and pins carry a monogram and mark no family link" do
      laser = @user.nodes.create!(node_id: "dir-laser", name: "laser", kind: "dir")
      @user.maker_pins.create!(node_id: laser.node_id)
      project = @user.maker_projects.create!(name: "desk lamp")

      get files_path(folder: laser.node_id)
      assert_select "aside.rail a.rail-pin[aria-current='page'] span.rail-monogram[aria-hidden='true'][data-monogram='L']"
      assert_select "aside.rail a.rail-pin[aria-current='page']", text: "laser"
      assert_select "aside.rail .rail-family-lit", count: 0
      get project_path(project)
      assert_select "aside.rail a.rail-project[aria-current='page'] span.rail-monogram[data-monogram='D']"
      assert_select "aside.rail a.rail-project[aria-current='page']", text: "desk lamp"
      assert_select "aside.rail .rail-family-lit", count: 0
    end

    # THE APP ICON IS TINKEREX'S, NOT THE RAILS SCAFFOLD'S RED CIRCLE, and the manifest's theme colour
    # is the page's own (`theme-color` meta for the default, light, theme).
    test "the app icon and the manifest agree with the page" do
      svg = Rails.public_path.join("icon.svg").read
      assert_no_match(/circle|fill="red"/, svg)
      assert_includes svg, 'fill="#1b1c19"'
      png = Rails.public_path.join("icon.png").binread
      assert_equal [ 512, 512 ], png[16, 8].unpack("NN"), "icon.png is not the 512px icon the manifest names"

      manifest = JSON.parse(Rails.root.join("app/views/pwa/manifest.json.erb").read)
      get root_path
      meta = css_select("meta[name='theme-color']").first["content"]
      assert_equal meta, manifest["theme_color"]
      assert_equal meta, manifest["background_color"]
    end
  end
end
