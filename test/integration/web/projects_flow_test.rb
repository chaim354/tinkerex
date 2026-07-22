require "test_helper"

module Web
  class ProjectsFlowTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    def sign_in(email = "maker@example.com")
      user = User.find_by(email:) ||
             User.create!(email:, password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email:, password: PASSWORD } }
      user
    end

    test "requires login" do
      get projects_path
      assert_redirected_to new_user_session_path
    end

    test "index lists the user's projects grouped by status, empty state otherwise" do
      user = sign_in
      get projects_path
      assert_response :success
      assert_select "h1", "Projects"
      assert_select ".projects-empty"

      user.maker_projects.create!(name: "Desk Lamp", status: "active")
      user.maker_projects.create!(name: "Old Rig", status: "archived")
      get projects_path
      assert_select ".project-card .project-name", text: "Desk Lamp"
      # Archived projects are not in the default (non-archived) listing.
      assert_select ".project-card .project-name", text: "Old Rig", count: 0
    end

    test "index shows only the current user's projects" do
      sign_in("a@example.com").maker_projects.create!(name: "Mine")
      other = User.create!(email: "b@example.com", password: PASSWORD, confirmed_at: Time.current)
      other.maker_projects.create!(name: "Theirs")
      get projects_path
      assert_select ".project-name", text: "Mine"
      assert_select ".project-name", text: "Theirs", count: 0
    end
  end
end
