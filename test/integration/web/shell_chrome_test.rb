require "test_helper"

module Web
  # THE SHELL'S SMALLER PROMISES, AS MARKUP (Shop manual slice 3; UX audit A1, A6, A7, F1). The
  # browser halves are the shell_*_test.rb system tests; this pins what the server renders: the
  # account button's menu (which took over the phone's More sheet and the rail's foot), the Account
  # page as a Settings page, the search hint and its keys, Add's one menu, and the app icon and
  # manifest agreeing with the page.
  #
  # MUTATION-CHECKED (2026-11-19; each reverted, and the file re-run green after):
  #   1. `search_shortcut` answering "⌘K" whatever the user agent: the Windows arm red.
  #   2. Dropping `users/registrations` from ShellHelper::SECTIONS' settings entry: the Account test
  #      red, no Settings column and no row lit.
  #   3. `"theme_color": "#fcfbf8"` back in the manifest: the manifest test red.
  class ShellChromeTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze
    MAC = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36".freeze
    WINDOWS = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36".freeze

    setup do
      @user = User.create!(email: "chrome-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
    end

    # THE ACCOUNT BUTTON'S MENU holds what the rail's foot and the phone's More sheet held: Settings,
    # Account and Help (each keeps its page), the theme choice, and Sign out — at every width, so a
    # phone has its way to all of them. It lights nothing: Settings and Help light no place, and on
    # their pages the column lights the row.
    test "the account button opens Settings, Account, Help, the theme and Sign out" do
      get root_path
      assert_select "header.strip details.menu.strip-account[data-controller='menu'] > summary.strip-account-btn[aria-label=?]",
                    "Account: settings, theme, help, sign out", text: @user.email[0].upcase
      links = css_select("header.strip .strip-account a.menu-item").map { |a| [ a.text.strip, a["href"] ] }
      assert_equal [ [ "Settings", settings_path ], [ "Account", edit_user_registration_path ], [ "Help", help_path ] ], links
      assert_select "header.strip .strip-account .theme-choice[data-controller='theme'] button[data-action='theme#choose']", count: 3
      assert_select "header.strip .strip-account form[action=?] button", destroy_user_session_path, text: "Sign out"
      assert_select "header.strip .strip-account p.strip-account-email", text: @user.email
      get settings_path
      assert_select "header.strip .strip-account [aria-current]", count: 0
    end

    # THE ACCOUNT PAGE IS A SETTINGS PAGE (UX audit F1): it gets the Settings column and lights its
    # own row there, and like every Settings page it lights no place.
    test "the Account page is a Settings page" do
      get edit_user_registration_path
      assert_response :success
      assert_select "aside.column .column-row[aria-current='page']", count: 1, text: "Account"
      assert_select "header.strip a.strip-place[aria-current]", count: 0
    end

    # `/` IS THE HINT, AND THE TITLE NAMES THE CHORD THIS PLATFORM USES (spec §11.5; UX audit A7).
    # aria-keyshortcuts names all three, platform-neutrally.
    test "the search box shows its slash and names the chord this platform uses" do
      { MAC => "⌘K", WINDOWS => "Ctrl+K" }.each do |agent, chord|
        get root_path, headers: { "User-Agent" => agent }
        assert_select "header.strip .strip-search kbd.strip-kbd", text: "/"
        assert_select "header.strip .strip-search input[name='q'][title=?]", "Search everything (/ or #{chord})"
        assert_select "header.strip .strip-search input[name='q'][aria-keyshortcuts=?]", ShellHelper::SEARCH_KEYS
      end
      assert_equal "/ Control+K Meta+K", ShellHelper::SEARCH_KEYS
    end

    # ONE ADD (spec §7): what Upload and New ▾ held, in one outlined menu. Its "Upload…" forwards to the
    # hidden Upload BUTTON beside it (rule 9), and the strip spends no accent.
    test "the strip has one Add, holding Upload, New folder, Text file, Project, the tools and Inventory item" do
      get root_path
      assert_select "header.strip details.menu.strip-add-menu > summary.btn.strip-add-btn[aria-label='Add']", count: 1
      assert_select "header.strip .strip-add-menu > summary.primary", count: 0
      assert_select "header.strip .strip-add-menu button.menu-item[data-controller='upload-forward'][data-action='upload-forward#open']",
                    text: "Upload…"
      assert_select "header.strip .strip-add-menu form[action=?] label", library_folders_path, text: "New folder"
      assert_equal [ "Text file", "Project", "Inventory item" ],
                   css_select("header.strip .strip-add-menu a.menu-item").map { |a| a.text.strip }
      assert_select "header.strip .strip-add-menu turbo-frame#new-menu-tools[loading='lazy']"
      assert_select "header.strip .upload-btn.primary", count: 0
      assert_select "header.strip details", count: 2
    end

    # THE APP ICON IS TINKEREX'S, NOT THE RAILS SCAFFOLD'S RED CIRCLE, and the manifest's theme colour
    # is the page's own (`theme-color` meta for the default, light, theme).
    test "the app icon and the manifest agree with the page" do
      svg = Rails.public_path.join("icon.svg").read
      assert_no_match(/circle|fill="red"/, svg)
      assert_includes svg, 'fill="#0f1113"'
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
