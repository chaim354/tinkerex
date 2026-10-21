require "test_helper"

module Web
  # The model catalog after PR 3 (spec §8): a Files-style toolbar on the index with the status
  # filters as chips, a card with no status badge (2026-10-20), button actions on the model page, a print
  # composer that opens on demand, and a drop-zone import field. (The shelves page's buttons moved
  # to shelves_test.rb in slice 5, with the page, to Settings.)
  #
  # The index is the Library's 3D models view at /files/models since slice 5; the model page is
  # asserted over a FOLDERLESS model, the kind that keeps it (a folder model redirects to its strip —
  # models_redirects_test.rb).
  class ModelsPagesTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "mp-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
      @user.nodes.create!(node_id: "n-benchy", name: "benchy.stl", kind: "file", mtime: 1_000_000_000, size: 10)
      @model = @user.maker_models.create!(title: "Benchy", print_status: "printed")
      @model.file_attachments.create!(user: @user, node_id: "n-benchy", role: "model")
    end

    test "the index carries a toolbar with the search, the status chips, the tag and sort selects" do
      get files_models_path
      assert_response :success
      assert_select "form.toolbar.models-toolbar input[type='search'][name='q']"
      assert_select "form.toolbar.models-toolbar a.filter.chip.active", text: "All"
      assert_select "form.toolbar.models-toolbar a.filter.chip", text: "Printed"
      assert_select "form.toolbar.models-toolbar select[name='sort']"
      assert_select ".page-head a.btn.primary[href=?]", new_model_path, text: "Import model"
    end

    # THE VIEW'S OWN SEARCH USES THE FILES IDIOM (LOWER, ESCAPE), because /search's "See all" lands
    # here with the same query: a `%` that previewed one model there must find the same one here.
    test "?q= is case-insensitive and treats % and _ as literals" do
      literal = @user.maker_models.create!(title: "100% infill test")
      get files_models_path(q: "100%")
      assert_select "a[href=?]", model_path(literal)
      assert_select "a[href=?]", model_path(@model), false
      get files_models_path(q: "BENCHY")
      assert_select "a[href=?]", model_path(@model)
    end

    # NO STATUS BADGE ON THE CARD (2026-10-20, the owner's call): it covered the corner of the
    # picture, and the status is one click away -- the chips above the grid filter by it and the
    # model's own page shows it.
    test "a model card carries no status badge" do
      get files_models_path
      assert_select ".model-card", minimum: 1
      assert_select ".model-card .model-name", text: "Benchy"
      assert_select ".model-card .badge", count: 0
    end

    # NO EMOJI IN THE INTERFACE (slice 5 retired the cube placeholders): an empty cover is the 3D models
    # icon, on the view's card and on the page's hero alike.
    test "an empty cover is the 3D models icon on the card and on the model page" do
      bare = @user.maker_models.create!(title: "Bare")
      get files_models_path
      assert_select ".model-card[href=?] .project-thumb-empty[aria-hidden='true'] svg.rail-icon", model_path(bare)
      get model_path(bare)
      assert_select ".model-hero-empty[aria-hidden='true'] svg.rail-icon"
      assert_no_match "\u{1F9CA}", response.body
    end

    test "the model page's actions are buttons and its print log is a closed composer" do
      get model_path(@model)
      assert_select ".head-actions a.btn[href=?]", edit_model_path(@model), text: "Edit"
      assert_select ".head-actions form[action=?] button.btn.danger", model_path(@model), text: "Delete"
      assert_select ".print-log details.composer:not([open]) > summary", text: "Log a print"
      assert_select ".print-log details.composer form.print-form[action=?] input[type='submit'][value='Log a print']",
                    model_print_runs_path(@model)
    end

    test "the import form's file field is a drop zone that keeps the importer's wiring" do
      get new_model_path
      assert_select "[data-controller='importer'] label.dropzone input[type='file'][multiple][data-importer-target='input'][data-action='importer#choose']"
      assert_select "[data-controller='importer'] [data-importer-target='summary']", text: "No files selected."
    end
  end
end
