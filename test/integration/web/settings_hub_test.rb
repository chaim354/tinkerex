require "test_helper"

module Web
  # Stage 2, S2-6: the settings hub (SettingsController#show) and its one child list
  # (Settings::TagsController), in the shape settings_reference_test.rb already established for
  # Suppliers/Locations -- a flat list, session-authed (§14d). The hub's Filing row (stage 3,
  # S3-1) is a seventh plain count; Settings::FilingRulesController itself is covered by
  # settings_filing_test.rb, not here.
  #
  # NO BACKEND IS PINNED HERE, for the same reason settings_reference_test.rb and shelves_test.rb
  # give: SettingsController#show counts
  # maker_shelves/maker_suppliers/maker_locations/maker_filing_rules/maker_tags, and
  # Settings::TagsController reads maker_tags/maker_taggings -- neither controller reads `nodes`
  # or calls the port at all, so there is nothing for FileLayer.current to answer and nothing for
  # the ambient LIBRARY_BACKEND to change.
  class SettingsHubTest < ActionDispatch::IntegrationTest
    PASSWORD = "password123".freeze

    setup do
      @user = User.create!(email: "sh-hub-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      sign_in_as(@user)
    end

    # DEVIATION FROM THE PLAN, the same one settings_reference_test.rb and shelves_test.rb record:
    # `sign_in_as` is not defined in test_helper.rb (the only method by that name is a Capybara
    # system-test helper that drives the real form). This plain ActionDispatch::IntegrationTest
    # defines its own, taking the already-built @user the test bodies attach rows to.
    def sign_in_as(user)
      post user_session_path, params: { user: { email: user.email, password: PASSWORD } }
    end

    def other_user!
      User.create!(email: "sh-o-#{SecureRandom.hex(4)}@example.com",
                  confirmed_at: Time.current, omniauth_signup: true)
    end

    # ============================================================ The hub

    test "the hub lists eight rows with facts and links" do
      @user.maker_shelves.create!(path: "Models")
      @user.maker_shelves.create!(path: "Enclosures")
      @user.maker_suppliers.create!(name: "Acme Bolts")
      @user.maker_suppliers.create!(name: "Bolts Co")
      @user.maker_suppliers.create!(name: "Zerex Supply")
      @user.maker_locations.create!(name: "Cabinet B")
      @user.maker_locations.create!(name: "Drawer B1")
      @user.maker_filing_rules.create!(ext: "stl", folder: "models")
      %w[laser firmware enclosure wiring].each { |name| @user.maker_tags.create!(name:) }

      get settings_path

      assert_response :success
      assert_select "ul.settings-list.settings-hub li", count: 8
      names = css_select("ul.settings-list.settings-hub li .settings-name").map { |el| el.text.strip }
      assert_equal [ "Shelves", "Suppliers", "Locations", "Filing", "Tags", "Account", "Theme",
                     "Current project" ], names
      assert_select "a.settings-name[href=?]", shelves_path
      assert_select "a.settings-name[href=?]", suppliers_path
      assert_select "a.settings-name[href=?]", locations_path
      assert_select "a.settings-name[href=?]", settings_filing_rules_path
      assert_select "a.settings-name[href=?]", settings_tags_path
      assert_select "a.settings-name[href=?]", edit_user_registration_path
      assert_select ".settings-fact", text: "2 shelves"
      assert_select ".settings-fact", text: "3 suppliers"
      assert_select ".settings-fact", text: "2 locations"
      assert_select ".settings-fact", text: "1 rule"
      assert_select ".settings-fact", text: "4 tags"
      assert_select ".settings-fact", text: @user.email
      # cookies[:theme] is unset -- ShellHelper#ui_theme's default, "light".
      assert_select ".settings-fact", text: /light/
      # The current-project preference (slice 0). It is a FORM, not a link, so it has no
      # `a.settings-name` — the row is named by a span and asserted through its control.
      assert_select "form[action=?] input[type=checkbox][name=?]",
                    settings_preferences_path, "remember_current_project"
      assert_select ".settings-fact", text: /Kept after sign-out/
    end

    test "the theme row is a three-way choice" do
      get settings_path

      assert_response :success
      assert_select ".settings-hub .theme-choice[data-controller='theme'][role='group']" do
        assert_select "button[data-action='theme#choose'][data-theme-theme-param='dark']"
        assert_select "button[data-action='theme#choose'][data-theme-theme-param='light']"
        assert_select "button[data-action='theme#choose'][data-theme-theme-param='system']"
      end
      assert_select ".theme-choice button[data-theme-theme-param='light'][aria-pressed='true']"
      assert_select ".theme-choice button[data-theme-theme-param='dark'][aria-pressed='false']"
      assert_select ".theme-choice button[data-theme-theme-param='system'][aria-pressed='false']"

      cookies[:theme] = "dark"
      get settings_path

      assert_select ".theme-choice button[data-theme-theme-param='dark'][aria-pressed='true']"
      assert_select ".theme-choice button[data-theme-theme-param='light'][aria-pressed='false']"
    end

    test "requires a session" do
      delete destroy_user_session_path

      get settings_path

      assert_redirected_to new_user_session_path
    end

    # ============================================================ The tags list

    test "the tags list shows every tag A to Z with how many things wear it, and a Remove" do
      laser = @user.maker_tags.create!(name: "laser")
      @user.maker_tags.create!(name: "firmware")
      project = @user.maker_projects.create!(name: "Desk Lamp")
      model = @user.maker_models.create!(title: "Bracket", slug: "bracket")
      Maker::Tagging.create!(user: @user, tag: laser, taggable: project)
      Maker::Tagging.create!(user: @user, tag: laser, taggable: model)

      get settings_tags_path

      assert_response :success
      assert_select "ul.settings-list li", count: 2
      names = css_select("ul.settings-list li .settings-name").map { |el| el.text.strip }
      assert_equal [ "firmware", "laser" ], names
      assert_select "a.settings-name[href=?]", tag_path("laser")
      assert_select "a.settings-name[href=?]", tag_path("firmware")
      assert_select ".settings-fact", text: "2 things"
      assert_select ".settings-fact", text: "unused"
      assert_select "li form[action=?] button", settings_tag_path(laser), text: "Remove"
    end

    test "removing a tag drops it and its taggings but leaves what wore it untouched" do
      laser = @user.maker_tags.create!(name: "laser")
      project = @user.maker_projects.create!(name: "Desk Lamp")
      model = @user.maker_models.create!(title: "Bracket", slug: "bracket")
      Maker::Tagging.create!(user: @user, tag: laser, taggable: project)
      Maker::Tagging.create!(user: @user, tag: laser, taggable: model)
      item = @user.maker_inventory_items.create!(name: "Laser lens")
      Maker::Tagging.create!(user: @user, tag: laser, taggable: item)

      delete settings_tag_path(laser)

      assert_redirected_to settings_tags_path
      assert_match(/removed/i, flash[:notice])
      assert_nil Maker::Tag.find_by(id: laser.id)
      assert_equal 0, Maker::Tagging.where(tag_id: laser.id).count
      assert Maker::Project.exists?(project.id)
      assert Maker::Model.exists?(model.id)
      assert Maker::InventoryItem.exists?(item.id)
    end

    # MUTATION-CHECK (a): swapping the scoped lookup in Settings::TagsController#destroy for a
    # bare `Maker::Tag.find(params[:id])` turns this from a 404 into a real delete of another
    # user's row -- the same shape settings_reference_test.rb pins for Suppliers and Locations.
    test "another user's tag cannot be removed" do
      theirs = other_user!.maker_tags.create!(name: "not-yours")

      delete settings_tag_path(theirs)

      assert_response :not_found
      assert_predicate Maker::Tag.find_by(id: theirs.id), :present?
    end

    test "an empty tags list still renders" do
      get settings_tags_path

      assert_response :success
      assert_select "li.empty"
    end
  end
end
