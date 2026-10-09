require "test_helper"

module Web
  # The model catalog after PR 3 (spec §8): a Files-style toolbar on the index with the status
  # filters as chips, the status badge over the cover, button actions on the model page, a print
  # composer that opens on demand, and a drop-zone import field. (The shelves page's buttons moved
  # to shelves_test.rb in slice 5, with the page, to Settings.)
  class ModelsPagesTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "mp-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      @user.nodes.create!(node_id: "n-benchy", name: "benchy.stl", kind: "file", mtime: 1_000_000_000, size: 10)
      @model = @user.maker_models.create!(title: "Benchy", print_status: "printed")
      @model.file_attachments.create!(user: @user, node_id: "n-benchy", role: "model")
    end

    test "the index carries a toolbar with the search, the status chips, the tag and sort selects" do
      get models_path
      assert_response :success
      assert_select "form.toolbar.models-toolbar input[type='search'][name='q']"
      assert_select "form.toolbar.models-toolbar a.filter.chip.active", text: "All"
      assert_select "form.toolbar.models-toolbar a.filter.chip", text: "Printed"
      assert_select "form.toolbar.models-toolbar select[name='sort']"
      assert_select ".page-head a.btn.primary[href=?]", new_model_path, text: "Import model"
    end

    # THE INDEX'S OWN SEARCH USES THE FILES IDIOM (LOWER, ESCAPE), because /search's "See all" lands
    # here with the same query: a `%` that previewed one model there must find the same one here.
    test "?q= is case-insensitive and treats % and _ as literals" do
      literal = @user.maker_models.create!(title: "100% infill test")
      get models_path(q: "100%")
      assert_select "a[href=?]", model_path(literal)
      assert_select "a[href=?]", model_path(@model), false
      get models_path(q: "BENCHY")
      assert_select "a[href=?]", model_path(@model)
    end

    test "a model card keeps its badge, which the stylesheet places over the cover" do
      get models_path
      assert_select ".model-card .badge.mstatus-printed", text: /printed/i
      assert_select ".model-card .model-name", text: "Benchy"
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
