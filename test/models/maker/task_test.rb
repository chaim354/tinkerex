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
