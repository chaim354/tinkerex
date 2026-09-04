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
      { projects_path => "Projects", models_path => "Models", tools_path => "Tools",
        trash_index_path => "Trash" }.each do |path, label|
        get path
        assert_response :success
        assert_select "aside.rail a.rail-link[aria-current='page']", count: 1, text: label
      end
    end

    test "a nested controller lights its family" do
      project = @user.maker_projects.create!(name: "Desk Lamp")
      get new_project_attachment_path(project)
      assert_select "aside.rail a.rail-link[aria-current='page']", count: 1, text: "Projects"
      get shelves_path
      assert_select "aside.rail a.rail-link[aria-current='page']", count: 1, text: "Models"
    end

    test "the sign-in page has no rail and no shell class" do
      delete destroy_user_session_path
      get new_user_session_path
      assert_response :success
      assert_select "aside.rail", count: 0
      assert_select "body.app-shell", count: 0
    end

    test "the theme comes from the cookie and defaults to dark" do
      get files_path
      assert_select "html[data-theme='dark']"
      assert_select "meta[name='theme-color'][content='#15181d']"
      assert_select "meta[name='color-scheme'][content='dark']"

      cookies[:theme] = "light"
      get files_path
      assert_select "html[data-theme='light']"
      assert_select "meta[name='theme-color'][content='#f4f5f7']"
      assert_select "meta[name='color-scheme'][content='light']"

      cookies[:theme] = "system"
      get files_path
      assert_select "html[data-theme='system']"
      assert_select "meta[name='color-scheme'][content='light dark']"

      cookies[:theme] = "purple"
      get files_path
      assert_select "html[data-theme='dark']"
    end

    test "the rail collapse state comes from the cookie" do
      get files_path
      assert_select "body.rail--collapsed", count: 0
      cookies[:rail] = "collapsed"
      get files_path
      assert_select "body.rail--collapsed"
      assert_select "aside.rail [data-action='rail#toggle'][aria-expanded='false']"
    end

    test "the top bar carries the library search on every page" do
      get projects_path
      assert_select "header.topbar form.topbar-search[action=?][method='get'] input[type='search'][name='q']", files_path
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
      assert_select "nav.tabbar a.tabbar-link", count: 5
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
