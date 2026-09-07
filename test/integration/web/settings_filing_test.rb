require "test_helper"

module Web
  # Stage 3, S3-1: /settings/filing (Settings::FilingRulesController), the per-user extension map
  # the intake sweep obeys (Maker::ProjectFolders.folder_for, Maker::ProjectIntake). Session-authed
  # (§14d), like the Suppliers/Locations lists settings_reference_test.rb pins.
  #
  # STAGE 4, S4-2 REGROUPED THE PAGE (story 4.3): ONE CARD PER FOLDER, not one row per extension.
  # Same rows, same routes, same actions -- so every create/update/destroy test below is untouched
  # and only the index tests moved. What changed is the question the page answers: "where does
  # laser work go" used to be spread over four screens of a 124-row reference list.
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

    # STORY 4.3: "laser files go to laser/", not 130 extension rows. ONE CARD PER FOLDER, and the
    # folder list is DERIVED from ProjectFolders::ROLE_FOLDERS -- a second literal list here is the
    # drift §14d exists to stop, and it would go stale the first time a role is added (S4-2 added
    # one).
    test "the page renders one card per folder, in the seed's own order" do
      get settings_filing_rules_path

      assert_response :success
      assert_select "h1", "Filing"
      folders = css_select(".filing-card .filing-folder").map { |el| el.text.strip.chomp("/") }
      assert_equal Maker::ProjectFolders::ROLE_FOLDERS.values.uniq, folders
    end

    test "each card holds its own extensions as chips" do
      get settings_filing_rules_path

      models = css_select(".filing-card").find { |c| c.at_css(".filing-folder").text.include?("models") }
      exts = models.css(".filing-chip .mono").map { |el| el.text.strip }
      assert_includes exts, ".stl"
      assert_includes exts, ".3mf"
      assert_not_includes exts, ".svg"
    end

    # A FOLDER THE SEED NEVER NAMED STILL GETS A CARD -- otherwise a maker who typed `prints` could
    # not see or remove the rule they just made.
    test "a custom folder a user's rules name gets a card of its own" do
      Maker::FilingRules.seed!(@user)
      @user.maker_filing_rules.find_by!(ext: "stl").update!(folder: "prints")

      get settings_filing_rules_path

      folders = css_select(".filing-card .filing-folder").map { |el| el.text.strip.chomp("/") }
      assert_includes folders, "prints"
    end

    # ASSERT THE RENDERED FIELD NAMES (CLAUDE.md §14d) -- Maker::FilingRule's own param_key would
    # be "maker_filing_rule", which the controller does not read; only a real form proves scope:
    # produced what #filing_rule_params requires. The add form is per CARD now and carries its
    # folder as a HIDDEN field, so adding `.lbrn` to `laser/` is one text box rather than two.
    #
    # NO PER-CHIP MOVE CONTROL, DELIBERATELY (this plan's amendment 2): a chip carries its extension
    # and Remove, and moving an extension is Remove on one card then Add on the other. #update and
    # its route survive untouched (its own tests below drive it directly), so the control a later
    # slice adds has somewhere to post; what is asserted here is what the PAGE actually renders.
    test "the per-card add form and each chip's Remove post what the controller reads" do
      get settings_filing_rules_path

      assert_select "form.filing-add input[name=?]", "filing_rule[ext]"
      assert_select "form.filing-add input[name=?][type=hidden]", "filing_rule[folder]"

      rule = @user.maker_filing_rules.find_by!(ext: "stl")
      assert_select ".filing-chip form[action=?][method=post] input[name=?][value=delete]",
                    settings_filing_rule_path(rule), "_method"
      assert_select ".filing-chip form[action=?] select", settings_filing_rule_path(rule), count: 0
    end

    # UNLIKE Suppliers/Locations/Tags, THERE IS NO REACHABLE "NO RULES AT ALL" STATE THROUGH THIS
    # DOOR TO PIN: #index calls Maker::FilingRules.seed! before it reads a single row, so destroying
    # every rule and then visiting the page reseeds the lot right back -- every
    # Maker::FileAttachment::ROLE_BY_EXT extension PLUS Maker::FilingRules::BEYOND_ROLE_BY_EXT's two
    # KiCad keys since stage 4, S4-2, which is why no count here is spelled as ROLE_BY_EXT.size
    # alone any more.
    #
    # THE `.empty` BRANCH IS NOT DEAD ANY MORE, THOUGH, and that is the change from the flat list:
    # it is PER CARD, and `other/` reaches it on a freshly seeded user -- no extension in the
    # vocabulary carries the `other` role (`ProjectFolders::ROLE_FOLDERS` maps it, `ROLE_BY_EXT`
    # never names it), so that one card renders "Nothing files here yet." on every default page.
    # template_hygiene_test.rb's sweep therefore renders both of the partial's branches for free.

    # ============================================================ create

    test "adding a filing rule redirects back with a flash" do
      post settings_filing_rules_path, params: { filing_rule: { ext: "iges", folder: "cad" } }

      assert_redirected_to settings_filing_rules_path
      rule = @user.maker_filing_rules.find_by!(ext: "iges")
      assert_equal "cad", rule.folder
      assert_match(/iges added/i, flash[:notice])
    end

    # `tar.gz`, NOT `kicad_pcb`, SINCE STAGE 4, S4-2. This test posted `kicad_pcb` from S3-1 until
    # Maker::FilingRule::KEY_RE widened to admit an underscore and twelve characters, at which point
    # it was asserting a refusal that had become a feature. A DOT is what KEY_RE still refuses and
    # `Maker::ProjectFolders.ext_of` (everything after the LAST dot) can never produce, so `tar.gz`
    # is the same claim about the same boundary, made where the boundary actually is now.
    test "a bad extension is refused with the model's error, not a 500" do
      post settings_filing_rules_path, params: { filing_rule: { ext: "tar.gz", folder: "cad" } }

      assert_redirected_to settings_filing_rules_path
      assert_match(/ext is invalid/i, flash[:alert])
      assert_nil @user.maker_filing_rules.find_by(ext: "tar.gz")
    end

    # THE OTHER SIDE OF THE SAME WIDENING (stage 4, S4-2; story 2.8). `kicad_sch` can never be a
    # Maker::FileAttachment::ROLE_BY_EXT key -- it fails FilesController::EXT_RE -- and can now
    # carry a DESTINATION, which is the whole split KEY_RE exists for.
    #
    # BOTH KEYS ON PURPOSE. `kicad_sch` is what Task C put in the seed, and it is free at THIS door
    # because #create never seeds (#index does), so this asserts the widened validation rather than
    # the seeded row. `kicad_wks` -- a real KiCad worksheet -- is the same nine-character
    # underscored shape and one the seed will never hold, so the claim survives #create ever
    # learning to seed.
    test "a KiCad extension is a legal rule now, and files where the form says" do
      post settings_filing_rules_path, params: { filing_rule: { ext: "kicad_sch", folder: "pcb" } }

      assert_redirected_to settings_filing_rules_path
      assert_equal "pcb", @user.maker_filing_rules.find_by!(ext: "kicad_sch").folder

      post settings_filing_rules_path, params: { filing_rule: { ext: "kicad_wks", folder: "pcb" } }

      assert_equal "pcb", @user.maker_filing_rules.find_by!(ext: "kicad_wks").folder
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
