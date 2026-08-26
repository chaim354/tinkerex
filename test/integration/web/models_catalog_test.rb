require "test_helper"

module Web
  # Task 6: deleting an AUTO model dismisses it (Maker::ModelIntake recreates any auto row whose
  # node still holds a model file, so a destroy would just come back on the next sweep -- §14f's
  # fight-the-user shape); an IMPORTED model still destroys, because nothing recreates it. And an
  # auto model with no attachments (an emptied folder) is HIDDEN on the index, not dismissed and
  # not destroyed -- the row keeps the user's title/tags and returns the moment a file does.
  class ModelsCatalogTest < ActionDispatch::IntegrationTest
    PASSWORD = "password123".freeze

    # A hermetic library for this suite: once a model has an attachment its `cover_node_id` is
    # non-nil, and `#index` then resolves it through `Maker::Previews::ThumbnailMap` ->
    # `FileLayer.current.stat_all`. Running on the ambient backend would mean a live sync server
    # on the chunk_remote CI leg (or real Aws calls on s3) for a suite that is about dismissal and
    # hiding, not which backend holds the bytes -- same reasoning and same helper as
    # models_flow_test.rb.
    setup do
      @root = use_fresh_share_library!
      @user = User.create!(email: "mc-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      sign_in_as(@user)
    end

    teardown do
      FileLayer.reset!
      FileUtils.remove_entry(@root) if @root&.exist?
    end

    # DEVIATION FROM THE PLAN: `sign_in_as` does not exist in test_helper.rb. The only method by
    # that name lives in test/system/support/web_helpers.rb -- a Capybara helper for
    # ApplicationSystemTestCase that takes an EMAIL and drives the real sign-in form. This is a
    # plain ActionDispatch::IntegrationTest; every web integration test in this suite instead
    # defines its own local sign-in that POSTs credentials directly (models_flow_test.rb,
    # models_import_test.rb, print_runs_test.rb, ...). This one takes the already-built @user,
    # matching how the plan's setup builds the user up front so every test body can attach records
    # to it, rather than an email that creates one.
    def sign_in_as(user)
      post user_session_path, params: { user: { email: user.email, password: PASSWORD } }
    end

    test "deleting an auto model dismisses it and says so" do
      model = @user.maker_models.create!(title: "Enclosure", origin: "auto", auto_node_id: "d-enc")

      delete model_path(model)

      assert_redirected_to models_path
      assert_match(/won't be re-added/i, flash[:notice])
      assert_predicate model.reload, :dismissed_at
    end

    test "deleting an imported model still destroys it" do
      model = @user.maker_models.create!(title: "Imported")

      delete model_path(model)

      assert_nil Maker::Model.find_by(id: model.id)
    end

    test "the index hides a dismissed model" do
      model = @user.maker_models.create!(title: "Gone", origin: "auto", auto_node_id: "d-x",
                                         dismissed_at: Time.current)
      # NOT empty on purpose -- a dismissed auto model with no attachments would also be caught by
      # the emptied-model filter below, confounding this test with that one (mutation-checked:
      # dropping `.catalogued` for `.all` stayed GREEN here until this attachment was added, because
      # the fixture had no file_attachments and the OTHER rule quietly did the hiding instead).
      model.file_attachments.create!(user: @user, node_id: "f-gone", role: "model")
      get models_path
      assert_response :success
      # DEVIATION FROM THE PLAN: the card partial (app/views/models/_card.html.erb) renders
      # class="project-name model-name", never "grid-name" -- ".grid-name" would match nothing, so
      # `count: 0` would pass trivially here. ".model-name" is the class already asserted on by the
      # passing tests in models_flow_test.rb (e.g. "index lists the user's models...").
      assert_select ".model-name", text: "Gone", count: 0
    end

    # AN EMPTIED AUTO MODEL IS HIDDEN, NOT DISMISSED AND NOT DESTROYED. The row survives holding
    # whatever title and tags the user gave it, and comes back when a file does. Dismissal must not
    # be reused here -- it is permanent, so a folder that refilled would stay gone.
    test "the index hides an auto model with no attachments and shows it again when files return" do
      model = @user.maker_models.create!(title: "Emptied", origin: "auto", auto_node_id: "d-e")

      get models_path
      assert_select ".model-name", text: "Emptied", count: 0

      model.file_attachments.create!(user: @user, node_id: "f-1", role: "model")

      get models_path
      assert_select ".model-name", text: "Emptied", count: 1
    end

    # THE BUTTON MUST DESCRIBE THE BRANCH IT TRIGGERS. models#destroy dismisses an auto model and
    # destroys an imported one; a single "Delete … (files are kept)" confirm describes only the
    # second, and told a user their model was being deleted when the row was about to survive.
    test "the auto model's own page offers Remove from catalog, not Delete" do
      model = @user.maker_models.create!(title: "Enclosure", origin: "auto", auto_node_id: "d-b")
      model.file_attachments.create!(user: @user, node_id: "f-2", role: "model")

      get model_path(model)

      assert_response :success
      assert_select "button", text: "Remove from catalog"
      assert_select "button", text: "Delete", count: 0
    end

    test "an imported model's page still offers Delete" do
      model = @user.maker_models.create!(title: "Imported")

      get model_path(model)

      assert_select "button", text: "Delete"
      assert_select "button", text: "Remove from catalog", count: 0
    end

    test "an imported model with no attachments still shows" do
      @user.maker_models.create!(title: "Fresh import")
      get models_path
      assert_select ".model-name", text: "Fresh import", count: 1
    end
  end
end
