require "test_helper"

module Web
  # EVERY SETTINGS PAGE GOES UP A LEVEL ONE WAY (UX audit A4, F8; design-system.md rule 9): the
  # Settings breadcrumb in the top bar, the page's own name last, and no parent-named ghost button
  # ("Settings", "Users") in the page head. The Account page is one of them (F1).
  #
  # Backend-neutral: none of these pages reads the port, except the library page, which renders on
  # every leg (settings/library/show says so) and is crumbed on every leg once its folder is chosen.
  class SettingsCrumbsTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @admin = User.create!(email: "crumbs-#{SecureRandom.hex(4)}@example.com", password: PASSWORD,
                            confirmed_at: Time.current, admin: true)
      @other = User.create!(email: "crumbs-other-#{SecureRandom.hex(4)}@example.com", password: PASSWORD,
                            confirmed_at: Time.current)
      sign_in_web!(@admin, password: PASSWORD)
    end

    def pages
      {
        "Shelves" => settings_shelves_path,
        "Tags" => settings_tags_path,
        "Library folder" => settings_library_path,
        "Users" => settings_users_path,
        "Devices" => settings_devices_path,
        "Account" => edit_user_registration_path,
        @other.email => edit_settings_user_path(@other)
      }
    end

    # MUTATION-CHECKED: putting the "Settings" ghost button back in one page head reddens this, naming
    # the page; the run's output is in the UX-audit T6 report.
    test "each settings page is crumbed from Settings to itself, with no ghost back button" do
      pages.each do |name, path|
        get path
        assert_response :success, path
        crumbs = css_select(".topbar nav.breadcrumb").first
        assert crumbs, "#{path} has no breadcrumb"
        assert_equal settings_path, crumbs.at_css("a")&.[]("href"), "#{path}'s crumbs do not start at Settings"
        assert_equal name, crumbs.at_css("[aria-current=page]")&.text&.strip, "#{path}'s crumbs do not end at the page"
        assert_select ".page-head a.btn.ghost", { count: 0 }, "#{path} still carries a ghost back button"
        assert_select "main h1", { count: 1, text: name }, path
      end
    end

    test "one account's page passes through Users" do
      get edit_settings_user_path(@other)
      assert_equal [ settings_path, settings_users_path ],
                   css_select(".topbar nav.breadcrumb a").map { |a| a["href"] }
    end

    test "the hub's Users row counts users" do
      get settings_path
      assert_select "ul.settings-hub li", text: /Users\s*2 users/
    end
  end
end
