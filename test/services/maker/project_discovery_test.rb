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

    # ARCHIVING IS THE DISMISSAL, AND THIS IS THE TEST THAT MAKES IT ONE. An archived project keeps
    # its folder_node_id, so the unscoped claim lookup passes over its folder forever.
    test "an archived project still claims its folder" do
      folder = dir("d-lamp", "Desk Lamp", "d-projects")
      project = @user.maker_projects.create!(name: "Desk Lamp")
      project.update_column(:folder_node_id, folder.node_id)
      project.archive!

      run = Maker::ProjectDiscovery.for_user(user: @user)

      assert_equal 0, run.created
      assert_equal 1, @user.maker_projects.count
    end

    # `.git` KEEPS ITS NODE (§14b) — it is the evidence a directory is a working tree — so without
    # the dot rule a repo checked out at the Projects/ root becomes a project titled ".git".
    test "dot-folders are skipped" do
      dir("d-git", ".git", "d-projects")
      dir("d-hidden", ".scratch", "d-projects")

      run = Maker::ProjectDiscovery.for_user(user: @user)

      assert_equal 0, run.created
      assert_equal 0, run.candidates
    end

    test "a folder deeper than a direct child is not adopted" do
      lamp = dir("d-lamp", "Desk Lamp", "d-projects")
      dir("d-models", "models", lamp.node_id)

      Maker::ProjectDiscovery.for_user(user: @user)

      assert_equal [ "d-lamp" ], @user.maker_projects.pluck(:folder_node_id)
    end

    test "a file directly under Projects is not adopted" do
      file("f-stray", "stray.stl", "d-projects")

      run = Maker::ProjectDiscovery.for_user(user: @user)

      assert_equal 0, run.created
    end

    test "a tombstoned folder is not adopted" do
      dir("d-gone", "Gone", "d-projects").update!(deleted: true)

      run = Maker::ProjectDiscovery.for_user(user: @user)

      assert_equal 0, run.created
    end

    # NEVER MINTS `Projects/`. A user with no Projects folder is not swept — creating one as a side
    # effect of merely looking is Projects::AttachmentsController#relocate's recorded bug at
    # library-sweep scale.
    test "a library with no Projects folder creates nothing and mints nothing" do
      @user.nodes.destroy_all
      dir("d-other", "3D Models", nil)

      run = Maker::ProjectDiscovery.for_user(user: @user)

      assert_equal :no_projects_folder, run.status
      assert_equal 0, run.created
      assert_nil @user.nodes.present.find_by(name: "Projects", kind: "dir")
    end

    # THE PORT IS NEVER TOUCHED — no mkdir, no move, no bytes. That is what makes this sweep
    # identical on all three backends.
    test "the sweep creates no library nodes at all" do
      dir("d-lamp", "Desk Lamp", "d-projects")
      before = @user.nodes.count

      # ASSERT THE SCANNED SET IS NON-EMPTY FIRST (§14e): "no nodes were created" is satisfied just
      # as happily by a sweep that found nothing to do, and that arm proves nothing.
      run = Maker::ProjectDiscovery.for_user(user: @user)
      assert_equal 1, run.created, "precondition: the sweep must actually have adopted something"

      assert_equal before, @user.nodes.count
    end
  end
end
