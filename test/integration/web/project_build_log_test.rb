require "test_helper"

module Web
  class ProjectBuildLogTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    def sign_in(email = "maker@example.com")
      user = User.find_by(email:) ||
             User.create!(email:, password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email:, password: PASSWORD } }
      user
    end

    test "add a build-log entry" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      assert_difference "project.build_log_entries.count", 1 do
        post project_build_log_entries_path(project), params: { build_log_entry: { body: "Cut the panels" } }
      end
      assert_redirected_to project_path(project)
      follow_redirect!
      assert_select ".log-entry .entry-body", text: /Cut the panels/
    end

    test "a blank entry body is rejected" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      assert_no_difference "Maker::BuildLogEntry.count" do
        post project_build_log_entries_path(project), params: { build_log_entry: { body: "" } }
      end
      assert_redirected_to project_path(project)
    end

    test "delete a build-log entry" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      entry = project.build_log_entries.create!(user:, body: "oops")
      assert_difference "project.build_log_entries.count", -1 do
        delete build_log_entry_path(entry)
      end
    end

    test "entries render newest first" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      project.build_log_entries.create!(user:, body: "first", logged_at: 2.days.ago)
      project.build_log_entries.create!(user:, body: "second", logged_at: 1.day.ago)
      get project_path(project)
      bodies = css_select(".log-entry .entry-body").map(&:text).map(&:strip)
      assert_equal [ "second", "first" ], bodies
    end
  end
end
