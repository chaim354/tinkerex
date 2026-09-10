require "test_helper"

module Web
  # THE THREE VOCABULARY DECISIONS OF THE UI-COHESION SWEEP, EACH OF WHICH IS A RULE ABOUT WHAT THE
  # APP SAYS RATHER THAN ABOUT WHAT ANY ONE PAGE DOES — so each is undoable by an edit in a place
  # that looks unrelated to the rule it breaks.
  #
  #   1. ONE LABEL PER STATE. `.badge` lost `text-transform: capitalize` (a transform cannot know
  #      that `want_to_print` reads "Wanted"), so a label now comes from a hash keyed on the enum.
  #      The failure that motivated it: /models rendered the filter chip "Wanted" and the card badge
  #      "Want To Print" 200px apart, same state, one screen.
  #   2. ONE EMPTY STATE. `.projects-empty` and `.models-empty` carried `.empty`'s four declarations
  #      verbatim under new names, which css_hygiene_test.rb cannot see — it forbids REDECLARING a
  #      component selector, not copying its body. Both are gone; the views use `.empty`.
  #   3. /tools SAYS SOMETHING WHEN IT IS EMPTY, and says WHICH kind of empty. `Registry.all`
  #      returns [] both for "no source configured" and "source configured but returned nothing",
  #      and docs/invariants/addons.md names both as live states (OVH blanks ADDON_SOURCE_URL
  #      today). The only previous signal was a `Rails.logger.warn`.
  #
  # MUTATION-CHECKED (§15), each run and restored:
  #   - `print_status_label` -> `print_status.tr("_", " ")` in models/_card: "the chip and the badge
  #     must say the same word for one state" fails with badge "want to print" against chip "Wanted".
  #   - Deleting the `@addons.empty?` block from tools/home/index: "/tools says what a tool is when
  #     it has none" fails on the missing `.empty`.
  #   - Reinstating `class="empty muted"` anywhere: the inert-modifier sweep fails naming the file.
  class CohesionVocabularyTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "vocab@example.com", password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
    end

    test "the chip and the badge must say the same word for one state" do
      @user.maker_models.create!(title: "Dragon", print_status: "want_to_print")
      get models_path
      assert_response :success

      # THE FILTER CHIP AND THE CARD BADGE, ON ONE PAGE, READ OUT OF THE RENDERED HTML rather than
      # compared as constants — comparing `PRINT_STATUS_LABELS` to itself would pass with both
      # views still holding their own literals, which is the state this test exists to forbid.
      chip = css_select(".chips .chip").map { |e| e.text.strip }
      badge = css_select(".badge[class*=mstatus-want_to_print]").map { |e| e.text.strip }
      refute_empty badge, "no status badge rendered — the fixture is not reaching the card"
      label = Maker::Model::PRINT_STATUS_LABELS.fetch("want_to_print")
      assert_includes chip, label, "the filter chip does not use the one label source"
      assert_equal [ label ], badge, "the badge says something the filter chip does not"
    end

    test "every print status has a label, so the fallback is not load-bearing" do
      # `print_status_label` falls back to a humanised string rather than raising, which is right
      # for a 500-avoidance reason and wrong to rely on. This is what keeps the fallback dead code.
      missing = Maker::Model::PRINT_STATUSES - Maker::Model::PRINT_STATUS_LABELS.keys
      assert_empty missing, "these statuses have no label and would fall back: #{missing.inspect}"
    end

    test "/tools says what a tool is when it has none, and which kind of empty it is" do
      get tools_path
      assert_response :success
      assert_select ".empty", 1 do |els|
        assert_match(/add-ons/i, els.first.text, "the empty state does not say what a tool is")
      end
      # The fixture environment configures a source (ADDON_SOURCE_PATH in test), so this is the
      # "configured but returned nothing" arm. Asserting WHICH arm is what makes the branch real
      # rather than two spellings of one sentence.
      if Maker::Addons::Source.configured?
        assert_select ".empty", text: /returned nothing/
      else
        assert_select ".empty", text: /No addon source is configured/
      end
    end

    test "no view pairs .empty with the inert .muted" do
      views = Dir[Rails.root.join("app/views/**/*.erb")]
      refute_empty views, "no templates were scanned"
      offenders = views.select { |f| File.read(f).include?('class="empty muted"') }
                       .map { |f| Pathname(f).relative_path_from(Rails.root).to_s }
      assert_empty offenders,
                   "`.empty` already sets `color: var(--fg-muted)`, so `.muted` beside it does " \
                   "nothing. It was written 16 times before it was removed: #{offenders.inspect}"
    end

    test "no view spells a print status for itself" do
      # THE PER-PAGE GUARD COULD NOT SEE THIS, and that is the lesson. The chip/badge test above
      # asserts agreement on /models; `shared/_result_group` renders the same badge on /search and
      # /tags/:tag and kept its own `print_status.tr("_", " ")`. While `.badge` still carried
      # `text-transform: capitalize` the two agreed by accident; removing the transform — the very
      # change that made ONE label source necessary — turned it into "want to print". A rule about
      # EVERY view needs a guard that reads every view.
      views = Dir[Rails.root.join("app/views/**/*.erb")] + Dir[Rails.root.join("app/helpers/**/*.rb")]
      refute_empty views, "no templates were scanned"
      offenders = views.select { |f| File.read(f).match?(/print_status\.(tr|humanize|titleize|capitalize)/) }
                       .map { |f| Pathname(f).relative_path_from(Rails.root).to_s }
      assert_empty offenders,
                   "a print status must render through `print_status_label`, never a transform of " \
                   "the raw enum — `.badge` no longer capitalises, so these render lowercase: " \
                   "#{offenders.inspect}"
    end

    test "the two per-page copies of .empty stay deleted" do
      sheets = Dir[Rails.root.join("app/assets/stylesheets/**/*.css")]
      refute_empty sheets, "no stylesheets were scanned"
      body = sheets.map { |f| File.read(f) }.join("\n")
      # Selector positions only — the class names appear in components.css PROSE explaining why
      # they were deleted, and a bare `include?` would fire on that.
      %w[.projects-empty .models-empty].each do |sel|
        refute_match(/^\s*#{Regexp.escape(sel)}\s*[,{]/, body,
                     "#{sel} is back. It was a verbatim copy of `.empty`'s declarations under a " \
                     "new name, which css_hygiene_test.rb cannot see")
      end
    end
  end
end
