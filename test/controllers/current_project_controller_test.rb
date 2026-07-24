require "test_helper"

class CurrentProjectControllerTest < ActionDispatch::IntegrationTest
  PASSWORD = "correct horse battery staple".freeze

  setup do
    @user = User.create!(email: "cp-#{SecureRandom.hex(4)}@example.com",
                         password: PASSWORD, confirmed_at: Time.current)
    post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
  end

  test "update sets the session current project and redirects" do
    project = @user.maker_projects.create!(name: "Lamp")
    patch current_project_path, params: { project_id: project.id }
    assert_equal project.id, session[:current_project_id]
    assert_redirected_to files_path
  end

  test "update with a blank project_id clears the selection" do
    project = @user.maker_projects.create!(name: "Lamp")
    patch current_project_path, params: { project_id: project.id }
    patch current_project_path, params: { project_id: "" }
    assert_nil session[:current_project_id]
  end

  test "update ignores a project that is not the user's own" do
    other = User.create!(email: "cp-other-#{SecureRandom.hex(4)}@example.com",
                         password: PASSWORD, confirmed_at: Time.current)
    foreign = other.maker_projects.create!(name: "Theirs")
    patch current_project_path, params: { project_id: foreign.id }
    assert_nil session[:current_project_id]
  end

  test "destroy clears the current project" do
    project = @user.maker_projects.create!(name: "Lamp")
    patch current_project_path, params: { project_id: project.id }
    delete current_project_path
    assert_nil session[:current_project_id]
  end

  test "requires sign-in" do
    delete destroy_user_session_path
    patch current_project_path, params: { project_id: 1 }
    assert_redirected_to new_user_session_path
  end
end
