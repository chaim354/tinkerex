require "test_helper"

module Web
  # EVERY PRINT-STATUS WORD COMES FROM Maker::Model::PRINT_STATUS_LABELS, AND THE DEFAULT WEARS NO
  # BADGE (UX audit 2026-11-01, E2). The edit form built its own options (`tr("_", " ").capitalize`)
  # and said "Want to print" while the filter chip said "Wanted"; and the schema default is
  # want_to_print, so every model the sweep found wore a badge saying so. Now the chip, the form and
  # the badge read one hash, and the badge shows only a status somebody, or a logged print, set.
  # cohesion_vocabulary_test.rb pins the chip against the badge; this pins the form too.
  #
  # MUTATION-CHECKED (§15): models/edit's options put back to `s.tr("_", " ").capitalize` reddens
  # "the edit form's options are the labels"; `unless @model.default_print_status?` removed from
  # models/show reddens "the default status wears no badge". Outputs in this task's report.
  class ModelsStatusLabelsTest < ActionDispatch::IntegrationTest
    setup do
      @root = use_fresh_share_library!
      @user = User.create!(email: "msl-#{SecureRandom.hex(4)}@example.com",
                           password: WEB_PASSWORD, confirmed_at: Time.current)
      sign_in_web!(@user)
    end

    teardown do
      FileLayer.reset!
      FileUtils.remove_entry(@root) if @root&.exist?
    end

    # THE HASH IS SWAPPED FOR WORDS NO VIEW COULD SPELL ON ITS OWN, because the real labels are now
    # exactly what the old `tr("_", " ").capitalize` produced ("Want to print", "Printed", "Failed"):
    # compared against the real hash, a form building its own words again would pass. With these, it
    # cannot.
    def with_labels(labels)
      original = Maker::Model::PRINT_STATUS_LABELS
      Maker::Model.send(:remove_const, :PRINT_STATUS_LABELS)
      Maker::Model.const_set(:PRINT_STATUS_LABELS, labels.freeze)
      yield
    ensure
      Maker::Model.send(:remove_const, :PRINT_STATUS_LABELS)
      Maker::Model.const_set(:PRINT_STATUS_LABELS, original)
    end

    test "the edit form's options are the labels the chips use" do
      model = @user.maker_models.create!(title: "Dragon")
      labels = { "want_to_print" => "On the list", "printed" => "Off the bed", "failed" => "Spaghetti" }
      with_labels(labels) do
        get files_models_path
        chips = css_select(".models-toolbar .chips .chip").map { |c| c.text.strip } - [ "All" ]

        get edit_model_path(model)
        assert_response :success
        options = css_select("select[name='model[print_status]'] option").map { |o| [ o["value"], o.text ] }
        assert_equal labels.to_a, options, "the edit form spells the statuses itself"
        assert_equal chips, options.map(&:last), "the chips and the form name the statuses differently"
      end
      assert_equal "Want to print", Maker::Model.print_status_label("want_to_print")
    end

    test "the default status wears no badge, and a set one wears its label" do
      wanted = @user.maker_models.create!(title: "Dragon")
      get model_path(wanted)
      assert_response :success
      assert_select ".page-head .badge[class*=mstatus-]", 0

      printed = @user.maker_models.create!(title: "Benchy", print_status: "printed")
      get model_path(printed)
      assert_select ".page-head .badge.mstatus-printed", text: Maker::Model::PRINT_STATUS_LABELS.fetch("printed")
    end
  end
end
