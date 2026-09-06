require "test_helper"

module Web
  # THE PROJECT FORM'S publishing controls (stage 3, S3-4): the Visibility and License selects, the
  # "choose a handle first" hint, and `project_params` actually permitting the two. Field names are
  # asserted as RENDERED (§14d): the form is `scope: :project` over a NAMESPACED model, so without
  # it the selects would be named `maker_project[...]` and every save would silently drop them.
  class ProjectPublishingFormTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "pubform-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      @project = @user.maker_projects.create!(name: "Desk Lamp")
    end

    # --- the rendered form ---------------------------------------------------------------------

    test "the edit form renders both selects under the names the controller permits" do
      get edit_project_path(@project)
      assert_response :success

      assert_select "select[name=?]", "project[visibility]" do
        assert_select "option", 3
        assert_select "option[value=private]"
        assert_select "option[value=unlisted]"
        assert_select "option[value=public]"
      end
      assert_select "select[name=?]", "project[license]" do
        assert_select "option[value=?]", "MIT"
        assert_select "option[value=?]", "CERN-OHL-S-2.0"
      end
    end

    test "without a handle the form points at the account page" do
      get edit_project_path(@project)
      assert_select "a[href=?]", edit_user_registration_path, text: "choose a handle"
    end

    test "with a handle the hint is gone" do
      @user.update!(handle: "chaim")
      get edit_project_path(@project)
      assert_select "a[href=?]", edit_user_registration_path, false
    end

    # --- the save ------------------------------------------------------------------------------

    test "with a handle, a patch publishes the project and mints its token" do
      @user.update!(handle: "chaim")

      patch project_path(@project), params: { project: { visibility: "public", license: "MIT" } }

      assert_response :redirect
      @project.reload
      assert_equal "public", @project.visibility
      assert_equal "MIT", @project.license
      assert_match(/\A\h{32}\z/, @project.unlisted_token)
    end

    test "without a handle the form re-renders with the error and the project stays private" do
      patch project_path(@project), params: { project: { visibility: "public" } }

      assert_response :unprocessable_content
      assert_equal "private", @project.reload.visibility
      assert_select ".form-errors", /handle/
    end

    test "the project page badges a published project" do
      @user.update!(handle: "chaim")
      @project.update!(visibility: "public")

      get project_path(@project)
      assert_select ".page-head .badge.visibility-public", text: "Public"
    end

    test "a private project carries no visibility badge" do
      get project_path(@project)
      assert_select ".page-head .badge[class*=visibility-]", 0
    end
  end
end
