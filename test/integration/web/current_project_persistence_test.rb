require "test_helper"

module Web
  # THE CURRENT PROJECT OUTLIVES THE SESSION (slice 0, 2026-09-10).
  #
  # Found by using the app: the rail card promises "Uploads and tool output land here" and the
  # creation flash says the same, but the whole of the storage was `session[:current_project_id]`.
  # Signing out — or opening the app on the workshop tablet — silently read None, and the next
  # upload went to the library root instead of the project folder, with nothing said. The promise
  # outlived its storage.
  #
  # `users.remember_current_project` is the maker's opt-out back to the old behaviour, so both
  # halves are pinned here: the default persists, the opt-out resets, and switching between them
  # CARRIES the selection rather than dropping it.
  class CurrentProjectPersistenceTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "cpp-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      @project = @user.maker_projects.create!(name: "Shop Stool")
      sign_in!
    end

    def sign_in! = post(user_session_path, params: { user: { email: @user.email, password: PASSWORD } })
    def sign_out! = delete(destroy_user_session_path)
    def select_project!(project = @project) = patch(current_project_path, params: { project_id: project.id })

    # --- the default: it survives ------------------------------------------------------------

    test "a selected project is still current after signing out and back in" do
      select_project!
      assert_equal @project.id, current_project_id_for(@user)

      sign_out!
      sign_in!

      get root_path
      assert_response :success
      assert_equal @project.id, current_project_id_for(@user),
                   "the whole point: the pointer is on the user, not the session"
      assert_select ".current-project-name", text: "Shop Stool"
    end

    test "it is visible to a second, entirely separate session — the workshop tablet case" do
      select_project!
      # A different integration session: its own cookie jar, as a second device would have.
      tablet = open_session
      tablet.post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      tablet.get root_path
      assert_select_in tablet, ".current-project-name", "Shop Stool"
    end

    def assert_select_in(session, selector, text)
      node = Nokogiri::HTML(session.response.body).at_css(selector)
      assert node, "#{selector} not found in the second session's page"
      assert_equal text, node.text.strip
    end

    test "clearing it persists too, rather than reverting to the last remembered project" do
      select_project!
      delete current_project_path
      sign_out!
      sign_in!
      assert_nil current_project_id_for(@user)
    end

    # --- the opt-out: it resets ---------------------------------------------------------------

    test "with remembering off, the selection lives in the session and is gone after sign-out" do
      patch settings_preferences_path, params: { remember_current_project: "0" }
      select_project!
      assert_equal @project.id, current_project_id_for(@user)
      assert_nil @user.reload.current_project_id,
                 "an opted-out maker's choice must not be written to their row"

      sign_out!
      sign_in!
      assert_nil current_project_id_for(@user)
    end

    # --- switching the setting carries the selection ------------------------------------------
    #
    # A settings toggle that silently changes where the next upload lands is exactly the surprise
    # this slice exists to remove, so the switch is lossless in both directions.

    test "turning remembering OFF keeps the project selected for this session" do
      select_project!
      patch settings_preferences_path, params: { remember_current_project: "0" }
      assert_equal @project.id, current_project_id_for(@user)
    end

    test "turning remembering ON keeps the project selected, and now it persists" do
      patch settings_preferences_path, params: { remember_current_project: "0" }
      select_project!
      patch settings_preferences_path, params: { remember_current_project: "1" }

      assert_equal @project.id, @user.reload.current_project_id
      sign_out!
      sign_in!
      assert_equal @project.id, current_project_id_for(@user)
    end

    # --- the setting's own surface ------------------------------------------------------------

    test "the preference defaults to remembering for a brand-new account" do
      assert_predicate User.new, :remember_current_project
    end

    test "the settings page renders the toggle and says which way it is set" do
      get settings_path
      assert_response :success
      assert_select "form[action=?] input[name=?]", settings_preferences_path, "remember_current_project"
      assert_select ".settings-fact", text: /Kept after sign-out/

      patch settings_preferences_path, params: { remember_current_project: "0" }
      get settings_path
      assert_select ".settings-fact", text: /Resets on sign-out/
    end

    test "a malformed submit leaves remembering ON rather than silently opting the maker out" do
      patch settings_preferences_path, params: { remember_current_project: { nope: "1" } }
      assert @user.reload.remember_current_project
    end

    # --- the pointer is still user-scoped -----------------------------------------------------

    test "a stored id that stops resolving reads as no current project rather than raising" do
      # A SECOND, LIVE PROJECT, so the rail card still renders and can be asserted on: the card is
      # behind `current_project_choices.any?`, so archiving the ONLY project removes the card
      # entirely and a "shows None" assertion would pass for the wrong reason.
      @user.maker_projects.create!(name: "Bench Light")
      select_project!
      @project.update!(status: "archived")

      get root_path
      assert_response :success
      assert_select ".current-project-name", text: "None"
      assert_equal @project.id, @user.reload.current_project_id,
                   "the stored id is left alone — archiving hides it, it does not rewrite the row"
    end
  end
end
