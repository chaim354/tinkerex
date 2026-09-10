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
    assert_equal project.id, current_project_id_for(@user)
    assert_redirected_to files_path
  end

  test "update with a blank project_id clears the selection" do
    project = @user.maker_projects.create!(name: "Lamp")
    patch current_project_path, params: { project_id: project.id }
    patch current_project_path, params: { project_id: "" }
    assert_nil current_project_id_for(@user)
  end

  test "update ignores a project that is not the user's own" do
    other = User.create!(email: "cp-other-#{SecureRandom.hex(4)}@example.com",
                         password: PASSWORD, confirmed_at: Time.current)
    foreign = other.maker_projects.create!(name: "Theirs")
    patch current_project_path, params: { project_id: foreign.id }
    assert_nil current_project_id_for(@user)
  end

  test "destroy clears the current project" do
    project = @user.maker_projects.create!(name: "Lamp")
    patch current_project_path, params: { project_id: project.id }
    delete current_project_path
    assert_nil current_project_id_for(@user)
  end

  test "requires sign-in" do
    delete destroy_user_session_path
    patch current_project_path, params: { project_id: 1 }
    assert_redirected_to new_user_session_path
  end

  # STORY 1.5 / 4.5: "a switch gives no confirmation". Every branch, because the branch that says
  # nothing is the one a maker will hit and misread.
  test "every switch says what it did" do
    project = @user.maker_projects.create!(name: "Lamp")

    patch current_project_path, params: { project_id: project.id }
    assert_match(/Current project: Lamp — uploads and tool output land there\./, flash[:notice].to_s)

    patch current_project_path, params: { project_id: "" }
    assert_match(/No current project — uploads go to the library root\./, flash[:notice].to_s)

    delete current_project_path
    assert_match(/No current project/, flash[:notice].to_s)
  end

  # NOT A 500, NOT A SILENT CLEAR, AND NOT A DISCLOSURE. The session must survive untouched.
  test "an id that resolves to nothing alerts and leaves the choice alone" do
    mine = @user.maker_projects.create!(name: "Lamp")
    patch current_project_path, params: { project_id: mine.id }

    other = User.create!(email: "cp-x-#{SecureRandom.hex(4)}@example.com",
                         password: PASSWORD, confirmed_at: Time.current)
    foreign = other.maker_projects.create!(name: "Theirs")

    patch current_project_path, params: { project_id: foreign.id }

    assert_equal mine.id, current_project_id_for(@user), "a foreign id must not clear a real choice"
    assert_match(/isn't available/i, flash[:alert].to_s)
    refute_match(/Theirs/, flash[:alert].to_s + flash[:notice].to_s)
  end

  test "an archived project cannot become current and says so" do
    archived = @user.maker_projects.create!(name: "Old Rig", status: "archived")
    patch current_project_path, params: { project_id: archived.id }
    assert_nil current_project_id_for(@user)
    assert_match(/isn't available/i, flash[:alert].to_s)
  end
end
