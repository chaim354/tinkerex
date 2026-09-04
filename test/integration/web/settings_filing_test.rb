require "test_helper"

module Web
  # Stage 3, S3-1: /settings/filing (Settings::FilingRulesController), the per-user extension map
  # the intake sweep obeys (Maker::ProjectFolders.folder_for, Maker::ProjectIntake). In the shape
  # settings_reference_test.rb already established for Suppliers/Locations -- a flat list, an
  # inline add, session-authed (§14d) -- plus an inline per-row edit those two don't have.
  #
  # NO BACKEND IS PINNED HERE, for the same reason settings_reference_test.rb gives: the controller
  # reads only maker_filing_rules, never `nodes` or the port, so there is nothing for
  # FileLayer.current to answer and nothing for the ambient LIBRARY_BACKEND to change.
  class SettingsFilingTest < ActionDispatch::IntegrationTest
    PASSWORD = "password123".freeze

    setup do
      @user = User.create!(email: "sf-#{SecureRandom.hex(4)}@example.com",
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
      User.create!(email: "sfo-#{SecureRandom.hex(4)}@example.com",
                  confirmed_at: Time.current, omniauth_signup: true)
    end

    # ============================================================ index

    test "the page lists the seeded rules A to Z with their folder" do
      get settings_filing_rules_path

      assert_response :success
      assert_select "h1", "Filing"
      exts = css_select(".settings-list .settings-name").map { |el| el.text.strip }
      assert_equal exts.sort, exts, "the rules are not sorted by extension"
      assert_equal Maker::FileAttachment::ROLE_BY_EXT.size, @user.maker_filing_rules.count
      assert_includes exts, ".stl"
      assert_select ".settings-list li", count: Maker::FileAttachment::ROLE_BY_EXT.size
    end

    # ASSERT THE RENDERED FIELD NAMES (CLAUDE.md §14d) -- Maker::FilingRule's own param_key would
    # be "maker_filing_rule", which the controller does not read; only a real form proves scope:
    # produced what #filing_rule_params requires.
    test "the add form and each row's edit form post field names the controller reads" do
      get settings_filing_rules_path

      assert_select "form.settings-add input[name=?]", "filing_rule[ext]"
      assert_select "form.settings-add input[name=?]", "filing_rule[folder]"

      rule = @user.maker_filing_rules.find_by!(ext: "stl")
      assert_select "li form[action=?] input[name=?]", settings_filing_rule_path(rule), "filing_rule[folder]"
      assert_select "li form[action=?][method=post] input[name=?][value=patch]",
                    settings_filing_rule_path(rule), "_method"
    end

    # UNLIKE Suppliers/Locations/Tags, THERE IS NO REACHABLE "EMPTY" STATE THROUGH THIS DOOR TO
    # PIN: #index calls Maker::FilingRules.seed! before it reads a single row, so destroying every
    # rule and then visiting the page reseeds all Maker::FileAttachment::ROLE_BY_EXT.size of them
    # right back -- the `li.empty` branch the view still carries (for symmetry with the other
    # settings lists, and in case a future caller ever constructs a genuinely ruleless user) is
    # dead on this specific path, not a gap this file failed to cover.

    # ============================================================ create

    test "adding a filing rule redirects back with a flash" do
      post settings_filing_rules_path, params: { filing_rule: { ext: "iges", folder: "cad" } }

      assert_redirected_to settings_filing_rules_path
      rule = @user.maker_filing_rules.find_by!(ext: "iges")
      assert_equal "cad", rule.folder
      assert_match(/iges added/i, flash[:notice])
    end

    test "a bad extension is refused with the model's error, not a 500" do
      post settings_filing_rules_path, params: { filing_rule: { ext: "kicad_pcb", folder: "cad" } }

      assert_redirected_to settings_filing_rules_path
      assert_match(/ext is invalid/i, flash[:alert])
      assert_nil @user.maker_filing_rules.find_by(ext: "kicad_pcb")
    end

    test "a reserved folder name is refused with the model's error, not a 500" do
      post settings_filing_rules_path, params: { filing_rule: { ext: "iges", folder: ".trash" } }

      assert_redirected_to settings_filing_rules_path
      assert_match(/folder isn't allowed/i, flash[:alert])
      assert_nil @user.maker_filing_rules.find_by(ext: "iges")
    end

    test "adding a duplicate extension is refused with the model's error" do
      Maker::FilingRules.seed!(@user)

      post settings_filing_rules_path, params: { filing_rule: { ext: "STL", folder: "prints" } }

      assert_redirected_to settings_filing_rules_path
      assert_match(/ext has already been taken/i, flash[:alert])
      assert_equal "models", @user.maker_filing_rules.find_by!(ext: "stl").folder
    end

    # ============================================================ update

    test "updating a rule's folder redirects back with a flash" do
      Maker::FilingRules.seed!(@user)
      rule = @user.maker_filing_rules.find_by!(ext: "stl")

      patch settings_filing_rule_path(rule), params: { filing_rule: { folder: "prints" } }

      assert_redirected_to settings_filing_rules_path
      assert_equal "prints", rule.reload.folder
      assert_match(/stl updated/i, flash[:notice])
    end

    test "updating a rule to a reserved folder name is refused with the model's error" do
      Maker::FilingRules.seed!(@user)
      rule = @user.maker_filing_rules.find_by!(ext: "stl")

      patch settings_filing_rule_path(rule), params: { filing_rule: { folder: ".git" } }

      assert_redirected_to settings_filing_rules_path
      assert_match(/folder isn't allowed/i, flash[:alert])
      assert_equal "models", rule.reload.folder
    end

    # MUTATION-CHECK (d), THE UPDATE HALF: swapping the scoped lookup in
    # Settings::FilingRulesController#update for a bare `Maker::FilingRule.find(params[:id])`
    # turns this from a 404 into a real update of another user's row.
    test "another user's filing rule cannot be updated" do
      theirs = other_user!.maker_filing_rules.create!(ext: "stl", folder: "models")

      patch settings_filing_rule_path(theirs), params: { filing_rule: { folder: "prints" } }

      assert_response :not_found
      assert_equal "models", theirs.reload.folder
    end

    # ============================================================ destroy

    test "removing a filing rule redirects back with a flash" do
      Maker::FilingRules.seed!(@user)
      rule = @user.maker_filing_rules.find_by!(ext: "stl")

      delete settings_filing_rule_path(rule)

      assert_redirected_to settings_filing_rules_path
      assert_match(/stl removed/i, flash[:notice])
      assert_nil Maker::FilingRule.find_by(id: rule.id)
    end

    # MUTATION-CHECK (d), THE DESTROY HALF: the identical unscoped-lookup swap in
    # Settings::FilingRulesController#destroy -- the same shape settings_reference_test.rb pins
    # for Suppliers and Locations.
    test "another user's filing rule cannot be removed" do
      theirs = other_user!.maker_filing_rules.create!(ext: "stl", folder: "models")

      delete settings_filing_rule_path(theirs)

      assert_response :not_found
      assert_predicate Maker::FilingRule.find_by(id: theirs.id), :present?
    end

    # ============================================================ Shell chrome

    test "the page links back to Settings" do
      get settings_filing_rules_path

      assert_select ".page-head a[href=?]", settings_path, text: "Settings"
    end
  end
end
