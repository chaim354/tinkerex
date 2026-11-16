require "test_helper"

module Web
  # THE 3D MODELS VIEW TELLS ITS CARDS APART, AND SAYS HOW A MODEL IS ADDED (UX audit 2026-11-01, E1
  # and E3). The sweep makes one model per file on a shelf (docs/invariants/model-intake.md), so
  # tetra.stl, tetra.obj and tetra.off side by side were three identical "tetra" cards; each card now
  # carries its formats and its folder (Maker::Model.card_facts). The primary was "Import model", the
  # Printables-zip flow alone; it is "Add model" with both routes. A filter that matches nothing says
  # "No models match" with the way back, where it said "No models yet. Import your first one."
  #
  # MUTATION-CHECKED (§15): dropping the facts line from models/_card reddens "three files named
  # tetra are three cards that say which is which". Output in this task's report.
  class ModelsCardsTest < ActionDispatch::IntegrationTest
    setup do
      @root = use_fresh_share_library!
      @user = User.create!(email: "mc-#{SecureRandom.hex(4)}@example.com",
                           password: WEB_PASSWORD, confirmed_at: Time.current)
      sign_in_web!(@user)
    end

    teardown do
      FileLayer.reset!
      FileUtils.remove_entry(@root) if @root&.exist?
    end

    def dir(node_id, name, parent = nil)
      @user.nodes.create!(node_id:, name:, kind: "dir", parent_node_id: parent, mtime: 1, size: 0)
    end

    # A one-file auto model, keyed on its FILE the way Maker::ModelIntake keys one.
    def one_file_model(name, parent)
      node_id = "n-#{name.parameterize}"
      @user.nodes.create!(node_id:, name:, kind: "file", parent_node_id: parent, mtime: 1, size: 1)
      @user.maker_models.create!(title: File.basename(name, ".*"), origin: "auto", auto_node_id: node_id).tap do |m|
        m.file_attachments.create!(user: @user, node_id:, role: "model")
      end
    end

    test "three files named tetra are three cards that say which is which" do
      dir("d-shapes", "shapes")
      dir("d-solids", "solids", "d-shapes")
      models = %w[tetra.stl tetra.obj].map { |name| one_file_model(name, "d-solids") }
      loose = one_file_model("tetra.3mf", nil)

      get files_models_path
      assert_response :success
      facts = models.to_h { |m| [ m.id, css_select(".model-card[href='#{model_path(m)}'] .model-facts").map { |e| e.text.squish } ] }
      assert_equal [ "STL shapes/solids" ], facts[models[0].id]
      assert_equal [ "OBJ shapes/solids" ], facts[models[1].id]
      # A file at the top of the library sits in the Library itself.
      assert_select ".model-card[href=?] .model-facts", model_path(loose), text: /3MF\s+Library/
      cards = css_select(".model-card .model-facts").map { |e| e.text.squish }
      assert_equal cards.uniq, cards, "two cards read the same"
    end

    test "a folder model names its own folder and every format inside it" do
      dir("d-models", "Models")
      dir("d-bracket", "bracket", "d-models")
      model = @user.maker_models.create!(title: "Bracket", origin: "auto", auto_node_id: "d-bracket", folder_node_id: "d-bracket")
      %w[base.stl lid.stl clip.3mf].each do |name|
        @user.nodes.create!(node_id: "n-#{name}", name:, kind: "file", parent_node_id: "d-bracket", mtime: 1, size: 1)
        model.file_attachments.create!(user: @user, node_id: "n-#{name}", role: "model")
      end

      get files_models_path
      assert_select ".model-card[href=?] .model-facts-ext", model_path(model), text: "3MF, STL"
      assert_select ".model-card[href=?] .model-facts-folder", model_path(model), text: "Models/bracket"
    end

    # THE CARD AND ITS GROUP HEADING READ ONE PLACE (Maker::Model.placements). An import with no
    # folder is placed by its first file. The card used to read its first MESH instead, so this kit
    # sat under "Lamp" while its card said "elsewhere".
    test "an import with no folder names the folder its project group is under" do
      dir("d-lamp", "lamp")
      dir("d-other", "elsewhere")
      @user.maker_projects.create!(name: "Lamp").update_column(:folder_node_id, "d-lamp")
      kit = @user.maker_models.create!(title: "Kit", origin: "import")
      @user.nodes.create!(node_id: "n-pic", name: "pic.jpg", kind: "file", parent_node_id: "d-lamp", mtime: 1, size: 1)
      @user.nodes.create!(node_id: "n-mesh", name: "part.stl", kind: "file", parent_node_id: "d-other", mtime: 1, size: 1)
      kit.file_attachments.create!(user: @user, node_id: "n-pic", role: "image", position: 0)
      kit.file_attachments.create!(user: @user, node_id: "n-mesh", role: "model", position: 1)

      get files_models_path
      assert_response :success
      group = css_select(".models-group").find { |s| s.at_css("h2.group-head a")&.text == "Lamp" }
      refute_nil group, "premise: the kit is grouped under the project its first file is in"
      assert_equal "STL lamp", group.at_css(".model-card[href='#{model_path(kit)}'] .model-facts").text.squish
    end

    # A MODEL WHOSE FILE IS IN THE TRASH KEEPS THE FOLDER THAT HELD IT until its rows are reaped (the
    # chosen reading, model_placements_test.rb). The group heading always placed it there; the card
    # read live files only and said nothing.
    test "a model whose file is in the trash still names the folder that held it" do
      dir("d-shapes", "shapes")
      model = one_file_model("cube.stl", "d-shapes")
      @user.nodes.find_by!(node_id: "n-cube-stl").update!(deleted: true)

      get files_models_path
      assert_select ".model-card[href=?] .model-facts-folder", model_path(model), text: "shapes"
    end

    # NO PLACE IS NOT THE LIBRARY ROOT. An import with no folder and no file has nothing to place it
    # by, and its card names no folder; "Library" there would put it at the top of the library.
    test "a model with nothing to place it by names no folder" do
      bare = @user.maker_models.create!(title: "Dragon", origin: "import")

      get files_models_path
      assert_select ".model-card[href=?]", model_path(bare)
      assert_select ".model-card[href=?] .model-facts", model_path(bare), count: 0
    end

    test "the primary is Add model, with both routes" do
      get files_models_path
      assert_select ".page-head details.menu > summary.btn.primary", text: "Add model ▾"
      assert_select ".page-head .btn.primary", count: 1
      assert_select ".page-head details.menu a.menu-item[href=?]", new_model_path, text: "Import a Printables zip"
      assert_select ".page-head details.menu a.menu-item[href=?]", help_path(anchor: "models"),
                    text: "From a file in your library"
    end

    test "the import page's title and button agree" do
      get new_model_path
      assert_select "h1", text: "Import model"
      assert_select "button[data-importer-target='submit']", text: "Import"
    end

    test "a filter that matches nothing says so, and an empty catalog says where models come from" do
      get files_models_path
      assert_select "p.empty", text: /No models yet/ do
        assert_select "code", text: "Models/"
        assert_select "a[href=?]", new_model_path
      end

      @user.maker_models.create!(title: "Dragon")
      get files_models_path(q: "zzz")
      assert_select "p.empty", text: /No models match/ do
        assert_select "a[href=?]", files_models_path, text: "Clear filters"
      end
      get files_models_path(status: "failed")
      assert_select "p.empty", text: /No models match/
    end
  end
end
