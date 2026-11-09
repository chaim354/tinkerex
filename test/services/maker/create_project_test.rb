require "test_helper"

module Maker
  # ONE WAY TO START A PROJECT FROM A FORM (onboarding wizard, 2026-11-09): New project and the
  # wizard's Project step. A real share library per test, because making the folder IS the point:
  # rows alone would let a regression in the minting branch pass (project-intake.md says so of the
  # door tests in projects_flow_test.rb, which keep covering ProjectsController#create unchanged).
  class CreateProjectTest < ActiveSupport::TestCase
    setup do
      @root = use_fresh_share_library!
      @user = User.create!(email: "create-#{SecureRandom.hex(4)}@example.com",
                           password: "correct horse battery staple", confirmed_at: Time.current)
    end

    test "saves the project, makes its folder, and names the folder in the notice" do
      project = @user.maker_projects.new(name: "Desk Lamp")
      result = Maker::CreateProject.call(@user, project)

      assert result.created?
      assert @root.join("Projects", "desk-lamp").directory?
      assert_equal @user.nodes.present.find_by!(name: "desk-lamp", kind: "dir").node_id, project.reload.folder_node_id
      assert_equal "Created Desk Lamp. Its folder is Projects/desk-lamp.", result.notice
      assert_nil result.alert
    end

    test "an invalid project is not created and makes no folder" do
      result = Maker::CreateProject.call(@user, @user.maker_projects.new(name: ""))

      assert_not result.created?
      assert_not @root.join("Projects").exist?
      assert result.project.errors[:name].any?
    end

    test "an unreachable library keeps the project and says to try again, never the class name" do
      project = @user.maker_projects.new(name: "Lamp")
      project.define_singleton_method(:ensure_library_folder!) { |_user| raise FileLayer::FetchError, "mount gone" }
      result = Maker::CreateProject.call(@user, project)

      assert result.created?
      assert_equal "Created Lamp.", result.notice
      assert_match(/could not be reached/, result.alert)
      assert_no_match(/FileLayer/, result.alert)
    end

    test "a name in the way keeps the project and says the folder could not be made" do
      project = @user.maker_projects.new(name: "Lamp")
      project.define_singleton_method(:ensure_library_folder!) { |_user| raise FileLayer::UnsupportedOperation, "taken" }
      result = Maker::CreateProject.call(@user, project)

      assert result.created?
      assert_match(/could not be made in the library/, result.alert)
    end
  end
end
