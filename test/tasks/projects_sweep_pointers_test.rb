require "test_helper"
require "rake"

# `rake projects:sweep_pointers` — deletes a stray `*.ptr` stub through the port (so it lands in
# the trash, restorable, never the void) when its real file sits beside it under Projects/; leaves
# one with no real file, one outside Projects/, and everything under DRY_RUN untouched.
#
# NO EXISTING RAKE-TASK TEST TO FOLLOW AS AN IDIOM (checked: no `test/tasks/` directory, no
# `Rake::Task` reference anywhere else in this suite) — the plan that named this file assumed one
# existed. This establishes the pattern: load the task definitions once per process
# (`Rails.application.load_tasks` is not safe to call twice — a second load would append a SECOND
# action to the same task, running its body twice per invoke), then `reenable` before and after
# each invocation so a later test in this file (or a later run in the same process) is not skipped
# as "already invoked".
#
# A REAL SHARE LIBRARY (`use_fresh_share_library!` + `create_node!`), because the task deletes
# THROUGH THE PORT — `FileLayer::Share#delete` needs a real `storage_path` and a real file on disk
# to rename into `.trash`, which a bare `nodes.create!` does not provide (`create_node!` is the
# house helper that writes both, test_helper.rb).
class ProjectsSweepPointersTaskTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("projects:sweep_pointers")
    @task = Rake::Task["projects:sweep_pointers"]
    @task.reenable
    @root = use_fresh_share_library!
    @user = User.create!(email: "sweep-#{SecureRandom.hex(4)}@example.com",
                         confirmed_at: Time.current, omniauth_signup: true)
  end

  teardown do
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
    ENV.delete("DRY_RUN")
  end

  def dir!(node_id, name, parent)
    create_node!(@user, node_id:, name:, kind: "dir", parent_node_id: parent)
  end

  def file!(node_id, name, parent)
    create_node!(@user, node_id:, name:, kind: "file", parent_node_id: parent)
  end

  # RE-DISABLE AFTER EVERY INVOKE, success or failure — `Rake::Task#invoke` only runs a task's
  # action the FIRST time it is invoked per process by design (it is meant to be called once per
  # `rake` process); without re-enabling, the second test in this file would see the task silently
  # do nothing and its own assertions would fail for the wrong reason.
  def invoke!
    @task.invoke
  ensure
    @task.reenable
  end

  def projects_desk_lamp
    projects = dir!("dir-projects", Maker::ProjectFolders::ROOT, nil)
    dir!("dir-desk-lamp", "desk-lamp", projects.node_id)
  end

  test "a pointer beside its real file under Projects/ is tombstoned through the port, and the real file survives" do
    desk_lamp = projects_desk_lamp
    file!("f-real", "bracket.stl", desk_lamp.node_id)
    ptr = file!("f-ptr", "bracket.stl.ptr", desk_lamp.node_id)

    invoke!

    assert ptr.reload.deleted?, "the pointer must be tombstoned, not merely hidden"
    assert_nil ptr.storage_path, "the port's delete releases storage_path (§14a)"
    assert @user.nodes.present.exists?(node_id: "f-real"), "the real file must be untouched"
    # THE BYTES REACHED .trash — the whole point of going through the port. A row-only tombstone
    # (deleted + NULL storage_path, the file left on disk) satisfies the assertions above and is
    # §14a's copy→delete→tombstone landmine; these two are what tell the two apart (review).
    assert @root.join(".trash", "f-ptr", "bracket.stl.ptr").exist?, "the pointer's bytes must land in .trash/<node_id>/"
    assert_not @root.join(Maker::ProjectFolders::ROOT, "desk-lamp", "bracket.stl.ptr").exist?, "the pointer must leave the folder"
  end

  test "a pointer under a sibling folder whose name merely starts with Projects is left alone" do
    archive = dir!("dir-archive", "#{Maker::ProjectFolders::ROOT}Archive", nil)
    file!("f-arch-real", "old.stl", archive.node_id)
    ptr = file!("f-arch-ptr", "old.stl.ptr", archive.node_id)

    invoke!

    assert_not ptr.reload.deleted?, "a bare prefix match would sweep ProjectsArchive/ too (review)"
  end

  # DATA LOSS IF THIS WERE EVER WRONG: the pointer stands for a binary that lives elsewhere (the
  # git-tracking arc's own shape), so deleting an orphaned one destroys the only record of it.
  test "a pointer with no real file beside it is kept" do
    desk_lamp = projects_desk_lamp
    ptr = file!("f-ptr", "orphan.stl.ptr", desk_lamp.node_id)

    invoke!

    assert_not ptr.reload.deleted?, "a pointer with no real file beside it must not be touched"
  end

  test "DRY_RUN=1 deletes nothing" do
    desk_lamp = projects_desk_lamp
    file!("f-real", "bracket.stl", desk_lamp.node_id)
    ptr = file!("f-ptr", "bracket.stl.ptr", desk_lamp.node_id)

    ENV["DRY_RUN"] = "1"
    invoke!

    assert_not ptr.reload.deleted?, "DRY_RUN must write nothing, even where a real run would delete"
  end

  test "a pointer outside Projects/ is left alone even though its real file sits beside it" do
    elsewhere = dir!("dir-elsewhere", "Elsewhere", nil)
    file!("f-real", "bracket.stl", elsewhere.node_id)
    ptr = file!("f-ptr", "bracket.stl.ptr", elsewhere.node_id)

    invoke!

    assert_not ptr.reload.deleted?, "the sweep is scoped to Projects/ only"
  end

  # A LIBRARY-ROOT POINTER (no parent at all) IS THE SAME "outside Projects/" CASE, reached through
  # `LibraryTree#path_for(nil) == ""` rather than a different code path — worth its own test since
  # a nil parent is the one input `path_for` handles as a special case internally.
  test "a pointer at the library root (no parent) is left alone" do
    file!("f-real", "bracket.stl", nil)
    ptr = file!("f-ptr", "bracket.stl.ptr", nil)

    invoke!

    assert_not ptr.reload.deleted?
  end
end
