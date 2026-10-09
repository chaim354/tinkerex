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
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
    end

    test "the page groups by kind, each with a count and links" do
      project = @user.maker_projects.create!(name: "Desk Lamp", tag_list: "laser")
      model = @user.maker_models.create!(title: "Bracket", tag_list: "laser")
      item = @user.maker_inventory_items.create!(name: "M3 bolt", unit: "each", tag_list: "laser")

      get tag_path("laser")
      assert_response :success
      assert_select ".page-head h1 .tag-chip", text: "laser"
      assert_select ".page-subtitle", text: "3 things"

      assert_select ".result-group--project h2", text: "Projects 1"
      assert_select ".result-group--project .result-row a[href=?]", project_path(project), text: "Desk Lamp"

      assert_select ".result-group--model h2", text: "Models 1"
      assert_select ".result-group--model .result-row a[href=?]", model_path(model), text: "Bracket"

      assert_select ".result-group--inventory_item h2", text: "Inventory 1"
      assert_select ".result-group--inventory_item .result-row a[href=?]", inventory_item_path(item), text: "M3 bolt"
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
    end
  end
end
