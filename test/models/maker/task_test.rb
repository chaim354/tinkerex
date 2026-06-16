require "test_helper"

module Maker
  class TaskTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "task@example.com")
      @item = @user.maker_items.create!(title: "Bracket")
    end

    test "a standalone task with no owner is valid" do
      task = @user.maker_tasks.build(title: "Buy M3 bolts")
      assert task.valid?
      assert_nil task.taskable
    end

    test "a task can be owned by an item" do
      task = @user.maker_tasks.create!(title: "Print this", taskable: @item)
      assert_equal @item, task.taskable
    end

    test "a task can be owned by a project" do
      project = @user.maker_projects.create!(name: "Lamp")
      task = @user.maker_tasks.create!(title: "Wire the LEDs", taskable: project)
      assert_equal project, task.taskable
    end

    test "a task cannot be owned by another user's project" do
      other = User.create!(email: "owner@example.com")
      project = other.maker_projects.create!(name: "Theirs")
      task = @user.maker_tasks.build(title: "x", taskable_type: "Maker::Project", taskable_id: project.id)
      assert_not task.valid?
      assert_includes task.errors[:taskable_id], "must reference your own project"
    end

    test "an unknown taskable_type is rejected" do
      task = @user.maker_tasks.build(title: "x", taskable_type: "Maker::Bogus", taskable_id: 1)
      assert_not task.valid?
    end

    test "status must be in the allowed set" do
      assert_not @user.maker_tasks.build(title: "x", status: "bogus").valid?
    end

    test "complete! stamps completed_at and sets status done" do
      task = @user.maker_tasks.create!(title: "x")
      task.complete!
      assert_equal "done", task.status
      assert_not_nil task.completed_at
    end
  end
end
