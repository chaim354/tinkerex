require "test_helper"

module Web
  # /tags/:name (stage 2, S2-5): everything wearing a tag, grouped by kind. Read-only,
  # session-authed; no library involvement (Project/Model/InventoryItem tags never touch
  # FileLayer), so no use_fresh_share_library! anywhere here.
  class TagsTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "tags-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
    end

    test "the page groups by kind, each with a count and links" do
      project = @user.maker_projects.create!(name: "Desk Lamp", tag_list: "laser")
      model = @user.maker_models.create!(title: "Bracket", tag_list: "laser")
      item = @user.maker_inventory_items.create!(name: "M3 bolt", unit: "each", tag_list: "laser")

      get tag_path("laser")
      assert_response :success
      assert_select ".page-head h1 .tag-chip", text: "laser"
      # BY KIND (UX audit D11, 2026-11-02): it read "3 things", which said nothing about what to look
      # for below.
      assert_select ".page-subtitle", text: "1 project · 1 3D model · 1 inventory item"

      assert_select ".result-group--project h2", text: "Projects 1"
      assert_select ".result-group--project .result-row a[href=?]", project_path(project), text: "Desk Lamp"

      assert_select ".result-group--model h2", text: "3D models 1"
      assert_select ".result-group--model .result-row a[href=?]", model_path(model), text: "Bracket"

      assert_select ".result-group--inventory_item h2", text: "Inventory 1"
      assert_select ".result-group--inventory_item .result-row a[href=?]", inventory_item_path(item), text: "M3 bolt"
    end

    # A MODEL ROW NAMES ITS FOLDER, A ONE-FILE MODEL'S TOO (Maker::Model.placements). This page read
    # `folder_node_id` alone, which a one-file model does not have: the rows the folder exists to
    # tell apart (one design catalogued from three files) were the ones that named nothing. Bare
    # catalog rows, no port, as search_folders_test.rb.
    test "a model row names the folder it sits in, a one-file model's too" do
      @user.nodes.create!(node_id: "d-models", name: "Models", kind: "dir")
      @user.nodes.create!(node_id: "d-kit", name: "kit", kind: "dir", parent_node_id: "d-models")
      kit = @user.maker_models.create!(title: "Kit", folder_node_id: "d-kit", tag_list: "laser")
      @user.nodes.create!(node_id: "n-clip", name: "clip.stl", kind: "file", parent_node_id: "d-models")
      clip = @user.maker_models.create!(title: "Clip", origin: "auto", auto_node_id: "n-clip", tag_list: "laser")
      bare = @user.maker_models.create!(title: "Bare", tag_list: "laser")

      get tag_path("laser")
      assert_response :success
      path = lambda do |model|
        row = css_select(".result-group--model .result-row").find { |li| li.at_css("a[href='#{model_path(model)}']") }
        refute_nil row, "no row links #{model.title}"
        row.at_css(".result-path")&.text
      end
      assert_equal "Models/kit", path.call(kit)
      assert_equal "Models", path.call(clip)
      assert_nil path.call(bare), "a model with nothing to place it by must not claim the root"
    end

    # A MODEL THE MAKER REMOVED FROM THE CATALOG IS REMOVED HERE TOO. Search and the 3D models view
    # both start from `catalogued`; this page did not, so a dismissed model stayed listed under its
    # tag and counted in the heading, and "See all" led to a view that did not show it.
    test "a dismissed model is not listed under its tag, nor counted" do
      kept = @user.maker_models.create!(title: "Bracket", tag_list: "laser")
      gone = @user.maker_models.create!(title: "Old bracket", tag_list: "laser", dismissed_at: Time.current)

      get tag_path("laser")

      assert_select ".result-group--model h2", text: "3D models 1"
      assert_select ".page-subtitle", text: "1 3D model"
      assert_select ".result-group--model .result-row a[href=?]", model_path(kept)
      assert_select ".result-row a[href=?]", model_path(gone), count: 0
    end

    test "a name is normalized: /tags/LASER finds laser" do
      project = @user.maker_projects.create!(name: "Desk Lamp", tag_list: "laser")
      get tag_path("LASER")
      assert_response :success
      assert_select ".tag-chip", text: "laser"
      assert_select ".result-group--project .result-row a[href=?]", project_path(project)
    end

    test "an unknown tag 404s" do
      get tag_path("nonexistent")
      assert_response :not_found
    end

    test "another user's tag 404s" do
      theirs = User.create!(email: "tags-other-#{SecureRandom.hex(4)}@example.com",
                            confirmed_at: Time.current, omniauth_signup: true)
      theirs.maker_projects.create!(name: "Theirs", tag_list: "secret")

      get tag_path("secret")
      assert_response :not_found
    end

    test "a dotted name routes" do
      project = @user.maker_projects.create!(name: "Board", tag_list: "v2.1")
      get tag_path("v2.1")
      assert_response :success
      assert_select ".tag-chip", text: "v2.1"
      assert_select ".result-group--project .result-row a[href=?]", project_path(project)
    end

    test "a group past the cap shows the true total and a See all link into that kind's own index" do
      (TagsController::GROUP_CAP + 1).times { |i| @user.maker_projects.create!(name: "P#{i}", tag_list: "laser") }

      get tag_path("laser")
      assert_response :success
      assert_select ".result-group--project .result-row", TagsController::GROUP_CAP
      assert_select ".result-group--project h2", text: "Projects #{TagsController::GROUP_CAP + 1}"
      assert_select ".result-group--project .result-more a[href=?]", projects_path(tag: "laser"),
                    text: "See all #{TagsController::GROUP_CAP + 1}"
    end

    # The models group's "See all" lands on the Library's 3D models view (slice 5), filtered by the tag;
    # /models itself only 301s there now, which would cost the click a redirect.
    test "the models group's See all lands on the 3D models view, filtered by the tag" do
      (TagsController::GROUP_CAP + 1).times { |i| @user.maker_models.create!(title: "M#{i}", tag_list: "laser") }

      get tag_path("laser")
      assert_response :success
      assert_select ".result-group--model .result-more a[href=?]", files_models_path(tag: "laser"),
                    text: "See all #{TagsController::GROUP_CAP + 1}"
    end

    test "a tag nobody wears any more (all taggings removed) shows the empty state, not a 404" do
      project = @user.maker_projects.create!(name: "Desk Lamp", tag_list: "laser")
      project.update!(tag_list: "")
      assert_empty project.reload.tags

      get tag_path("laser")
      assert_response :success
      assert_select ".empty", text: /Nothing wears this tag/
      # THE NEXT STEP (UX audit D11): where a tag is added, and a way into the Library.
      assert_select ".empty a[href=?]", files_path, text: "browse the Library"
      assert_select ".page-subtitle", text: "Nothing yet"
    end

    # THE CRUMB GOES SOMEWHERE (UX audit D11): the tag list is Settings › Tags.
    test "the Tags crumb links the tag list" do
      @user.maker_projects.create!(name: "Desk Lamp", tag_list: "laser")
      get tag_path("laser")
      assert_select "nav.breadcrumb a[href=?]", settings_tags_path, text: "Tags"
    end
  end
end
