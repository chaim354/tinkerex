require "test_helper"

module Web
  class CurrentProjectSetFromProjectTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "sp-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      @project = @user.maker_projects.create!(name: "Desk Lamp")
    end

    test "the project page offers 'Set as current' when it is not current" do
      get project_path(@project)
      assert_response :success
      assert_select "form[action=?] button", current_project_path, text: /set as current/i
    end

    test "setting it from the project page makes it the session current project" do
      patch current_project_path, params: { project_id: @project.id }
      assert_equal @project.id, session[:current_project_id]
    end

    test "the project page shows a current badge + Clear once it is current" do
      patch current_project_path, params: { project_id: @project.id }
      get project_path(@project)
      assert_select ".current-project-badge"
      assert_select "form[action=?] button", current_project_path, text: /clear/i
      assert_select "button", text: /set as current/i, count: 0
    end
  end
end
