require "test_helper"

module Web
  # THE PUBLISHING SAVE (stage 3, S3-4; the panel arrived in stage 4, S4-4). The Visibility and
  # Licence CONTROLS moved to projects/_publish.html.erb — one column, one control (§14a's
  # one-question-two-answers rule) — and their rendered-field assertions moved with them to
  # publishing_test.rb. What stays here is `project_params` actually permitting the two, the
  # handle-required refusal on a PATCH that carries no `return_to` (no form in the app produces that
  # request any more — the Publishing tab always sends `return_to=publishing` — so it is the hand-crafted /
  # API-shaped path, kept because the arm still exists), and the page-head badge.
  class ProjectPublishingFormTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "pubform-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
      @project = @user.maker_projects.create!(name: "Desk Lamp")
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

    test "without a handle a PATCH with no return_to re-renders the edit form with the error and the project stays private" do
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
