require "test_helper"

module Web
  class CurrentProjectTopbarTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "tb-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
    end

    test "the top bar shows a project selector listing this user's active projects" do
      @user.maker_projects.create!(name: "Desk Lamp")
      get files_path
      assert_response :success
      assert_select "form[action=?] select[name='project_id']", current_project_path do
        assert_select "option[value='']", text: /none/i
        assert_select "option", text: "Desk Lamp"
      end
    end

    test "the selector marks the current project as selected" do
      project = @user.maker_projects.create!(name: "Desk Lamp")
      patch current_project_path, params: { project_id: project.id }
      get files_path
      assert_select "select[name='project_id'] option[selected='selected'][value=?]", project.id.to_s,
                    text: "Desk Lamp"
    end

    test "an archived current project falls back to none (auto-clear)" do
      project = @user.maker_projects.create!(name: "Desk Lamp")
      patch current_project_path, params: { project_id: project.id }
      project.archive!
      get files_path
      # archived project is not offered and is not selected
      assert_select "select[name='project_id'] option", text: "Desk Lamp", count: 0
      assert_select "select[name='project_id'] option[selected='selected']", count: 0
    end

    test "no selector when the user has no projects" do
      get files_path
      assert_select "select[name='project_id']", count: 0
    end
  end
end
