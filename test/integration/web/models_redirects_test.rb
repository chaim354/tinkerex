require "test_helper"

module Web
  # /models FOLDS INTO THE LIBRARY (structural redesign §5.4, slice 5): the index is a Library view at
  # /files/models, and a model page redirects to its folder whenever that folder will show its strip —
  # otherwise the page stays (Maker::ModelFolder.landing_folder_id is the one answer).
  class ModelsRedirectsTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "mr-#{SecureRandom.hex(4)}@example.com", password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      @user.nodes.create!(node_id: "d-bracket", name: "bracket", kind: "dir", mtime: 1, size: 0)
      @user.nodes.create!(node_id: "n-bracket", name: "bracket.stl", kind: "file", parent_node_id: "d-bracket",
                          mtime: 1, size: 1, content_hash: "h", current_version_id: "v")
    end

    test "/models is a permanent redirect to the 3D models view, keeping its filters" do
      get models_path(q: "brack", status: "printed", tag: "shop", sort: "title", junk: "x")
      assert_response :moved_permanently
      assert_redirected_to files_models_path(q: "brack", status: "printed", tag: "shop", sort: "title")
    end

    test "a folder model's page redirects to its folder, temporarily, and the folder shows its strip" do
      model = @user.maker_models.create!(title: "Wall Bracket", folder_node_id: "d-bracket")
      get model_path(model)
      assert_response :found
      assert_redirected_to files_path(folder: "d-bracket")
      follow_redirect!
      assert_select ".model-strip h2", text: "Wall Bracket"
    end

    test "a one-file model and a folderless import keep the model page" do
      one_file = @user.maker_models.create!(title: "Loose Clip", origin: "auto", auto_node_id: "n-bracket")
      one_file.file_attachments.create!(user: @user, node_id: "n-bracket", role: "model")
      get model_path(one_file)
      assert_response :success
      assert_select "h1", text: "Loose Clip"

      folderless = @user.maker_models.create!(title: "Orphan")
      get model_path(folderless)
      assert_response :success
    end

    test "a model whose folder is in the trash keeps the model page" do
      model = @user.maker_models.create!(title: "Wall Bracket", folder_node_id: "d-bracket")
      @user.nodes.find_by!(node_id: "d-bracket").update!(deleted: true)
      get model_path(model)
      assert_response :success
    end

    # A PROJECT'S CLAIM WINS (model-intake.md), so the folder shows the project and no strip — and a
    # redirect there would land the maker on a folder that shows nothing of the model they clicked.
    test "a model whose folder a project claims keeps the model page" do
      model = @user.maker_models.create!(title: "Wall Bracket", folder_node_id: "d-bracket")
      @user.maker_projects.create!(name: "Shelf Unit").update_column(:folder_node_id, "d-bracket")
      get model_path(model)
      assert_response :success
      assert_select "h1", text: "Wall Bracket"
    end

    # THE OWNERSHIP 404 COMES FIRST. `set_model` resolves through current_user before #show reaches
    # Maker::ModelFolder, so another user's FOLDER model — one that WOULD redirect for its owner — is a
    # 404 here, never a 302 whose Location names their folder. A folderless fixture could not tell the
    # two orders apart (cross_user_authorization_test.rb's assert_unreadable passes on any non-2xx).
    test "another user's folder model is a 404, never a redirect into their folder" do
      other = User.create!(email: "mr-other-#{SecureRandom.hex(4)}@example.com", password: PASSWORD,
                           confirmed_at: Time.current)
      other.nodes.create!(node_id: "d-theirs", name: "theirs", kind: "dir", mtime: 1, size: 0)
      theirs = other.maker_models.create!(title: "Their Bracket", folder_node_id: "d-theirs")
      assert_equal "d-theirs", Maker::ModelFolder.landing_folder_id(other, theirs), "fixture: it redirects for its owner"

      get model_path(theirs)
      assert_response :not_found
    end

    test "the 3D models view lists catalogued models as cover tiles that open the model" do
      shown = @user.maker_models.create!(title: "Wall Bracket", folder_node_id: "d-bracket")
      @user.maker_models.create!(title: "Gone", dismissed_at: Time.current)
      get files_models_path
      assert_response :success
      assert_select "h1", text: "3D models"
      assert_select "header.topbar nav.breadcrumb a[href=?]", files_path, text: "Files"
      assert_select "header.topbar nav.breadcrumb [aria-current='page']", text: "3D models"
      assert_select ".model-card[href=?]", model_path(shown), count: 1
      assert_select ".model-card", text: /Gone/, count: 0
      assert_select ".page-head a.btn.primary[href=?]", new_model_path, text: "Import model"
      assert_select "a[href=?]", settings_shelves_path
      # Model tiles are links, never selection items (a model is not a file in a listing).
      assert_select "[data-selection-target]", count: 0
    end

    test "the 3D models view filters by status, title and tag, and its controls stay on its own path" do
      @user.maker_models.create!(title: "Wall Bracket", print_status: "printed", tag_list: "shop")
      @user.maker_models.create!(title: "Desk Clip")
      get files_models_path(status: "printed")
      assert_response :success
      assert_select ".model-card", count: 1
      get files_models_path(q: "desk")
      assert_select ".model-card", count: 1
      assert_select ".model-card", text: /Desk Clip/
      get files_models_path(tag: "shop")
      assert_select ".model-card", count: 1
      assert_select ".model-card", text: /Wall Bracket/
      assert_select "form.models-toolbar[action=?]", files_models_path
      assert_select "form.models-toolbar a.filter.chip[href=?]", files_models_path(status: "printed", tag: "shop"),
                    text: "Printed"
    end

    # A CRAFTED FILTER IS ABSENT, NEVER A 500. `?q[a]=b` arrives as a hash; handed to the status chips'
    # files_models_path it raised "unable to convert unpermitted parameters to hash" (found in slice 5's
    # review, older than it). The /models redirect drops it too.
    test "a filter that is not a string is ignored, on the view and through the redirect" do
      @user.maker_models.create!(title: "Wall Bracket")
      get "#{files_models_path}?q[a]=b&status[]=printed&tag[x]=y&sort[]=title"
      assert_response :success
      assert_select ".model-card", count: 1
      get "/models?q[a]=b&status=printed"
      assert_redirected_to files_models_path(status: "printed")
    end

    test "the sidebar lights 3D models on the view, and the phone tab bar lights Library" do
      get files_models_path
      assert_select "aside.rail [aria-current='page']", count: 1, text: /3D models/
      assert_select "aside.rail a.rail-link[href=?]", files_models_path, text: /3D models/
      assert_select "nav.tabbar a.tabbar-link[aria-current='page']", count: 1, text: /Library/

      # The same key on a model page that survives: ModelsController's pages are the 3D models place.
      get model_path(@user.maker_models.create!(title: "Orphan"))
      assert_select "aside.rail [aria-current='page']", count: 1, text: /3D models/
      assert_select "nav.tabbar a.tabbar-link[aria-current='page']", count: 1, text: /Library/
    end
  end
end
