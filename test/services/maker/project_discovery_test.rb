require "test_helper"

module Maker
  class ProjectDiscoveryTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "pd-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
      @root = dir("d-projects", "Projects", nil)
    end

    def dir(node_id, name, parent)
      @user.nodes.create!(node_id:, name:, kind: "dir", parent_node_id: parent, mtime: 1, size: 0)
    end

    def file(node_id, name, parent)
      @user.nodes.create!(node_id:, name:, kind: "file", parent_node_id: parent, mtime: 1, size: 1)
    end

    test "an unclaimed folder becomes a project named verbatim and pointed at that folder" do
      dir("d-lamp", "Desk Lamp", "d-projects")

      Maker::ProjectDiscovery.for_user(user: @user)

      project = @user.maker_projects.sole
      assert_equal "Desk Lamp", project.name
      assert_equal "desk-lamp", project.slug
      assert_equal "d-lamp", project.folder_node_id
    end

    test "the run reports its own delta and the candidate count" do
      dir("d-lamp", "Desk Lamp", "d-projects")
      dir("d-rack", "Rack", "d-projects")

      run = Maker::ProjectDiscovery.for_user(user: @user)

      assert_equal 2, run.created
      assert_equal 2, run.candidates
      assert_equal :ok, run.status
    end

    # STEADY STATE REPORTS 0, not the number of projects the user has.
    test "a second sweep creates nothing" do
      dir("d-lamp", "Desk Lamp", "d-projects")
      Maker::ProjectDiscovery.for_user(user: @user)

      run = Maker::ProjectDiscovery.for_user(user: @user)

      assert_equal 0, run.created
      assert_equal 1, @user.maker_projects.count
    end

    # TWO FOLDERS THAT SLUGIFY THE SAME BOTH ADOPT. `Projects/desk-lamp` (a project's own folder)
    # beside `Projects/Desk Lamp` (one made by hand) is the reachable case.
    test "colliding names both adopt, the second de-duped" do
      dir("d-a", "Desk Lamp", "d-projects")
      dir("d-b", "desk-lamp", "d-projects")

      Maker::ProjectDiscovery.for_user(user: @user)

      assert_equal %w[desk-lamp desk-lamp-2], @user.maker_projects.order(:slug).pluck(:slug)
    end

    test "a name with no latin characters adopts as project" do
      dir("d-jp", "プロジェクト", "d-projects")

      Maker::ProjectDiscovery.for_user(user: @user)

      project = @user.maker_projects.sole
      assert_equal "プロジェクト", project.name
      assert_equal "project", project.slug
    end
  end
end
