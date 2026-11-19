require "test_helper"

module Maker
  class StackExclusionTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "unstack-#{SecureRandom.hex(4)}@example.com")
      @file = @user.nodes.create!(node_id: "file-a", name: "box v1.svg", kind: "file")
    end

    test "a pull-out names a live file in its own user's library" do
      assert Maker::StackExclusion.pull_out!(@user, @file.node_id).persisted?

      dir = @user.nodes.create!(node_id: "dir-a", name: "laser", kind: "dir")
      refute @user.maker_stack_exclusions.new(node_id: dir.node_id).valid?, "a folder is in no stack"

      gone = @user.nodes.create!(node_id: "file-gone", name: "box v2.svg", kind: "file", deleted: true)
      refute @user.maker_stack_exclusions.new(node_id: gone.node_id).valid?, "a tombstone is in no stack"

      other = User.create!(email: "other-#{SecureRandom.hex(4)}@example.com")
      other.nodes.create!(node_id: "file-b", name: "theirs.svg", kind: "file")
      assert_raises(ActiveRecord::RecordInvalid) { Maker::StackExclusion.pull_out!(@user, "file-b") }
    end

    test "pulling out twice keeps one row, and putting back is idempotent" do
      first = Maker::StackExclusion.pull_out!(@user, @file.node_id)
      assert_equal first, Maker::StackExclusion.pull_out!(@user, @file.node_id)
      assert_equal 1, @user.maker_stack_exclusions.count

      assert Maker::StackExclusion.put_back!(@user, @file.node_id)
      refute Maker::StackExclusion.put_back!(@user, @file.node_id)
      assert_equal 0, @user.maker_stack_exclusions.count
    end

    test "putting back touches only this user's pull-out" do
      other = User.create!(email: "other-#{SecureRandom.hex(4)}@example.com")
      other.nodes.create!(node_id: @file.node_id, name: "theirs.svg", kind: "file")
      Maker::StackExclusion.pull_out!(other, @file.node_id)
      Maker::StackExclusion.pull_out!(@user, @file.node_id)

      Maker::StackExclusion.put_back!(@user, @file.node_id)
      assert_equal 1, other.maker_stack_exclusions.count
    end
  end
end
