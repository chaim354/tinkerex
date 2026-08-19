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

    # THE STRUCTURAL HALF OF THE FIX. `TASKABLE_TYPES` and the owner-class `case` used to be two
    # independent enumerations of one set, and the split failed OPEN — a type in the array with no
    # `case` arm got no tenant check at all. Derived from the map's keys they cannot disagree, and
    # this is what says so, because with the map in place a split pair is no longer expressible in
    # the code the mutation test would have to break.
    test "TASKABLE_TYPES is derived from TASKABLE_OWNERS, so the pair cannot split" do
      assert_equal Task::TASKABLE_OWNERS.keys, Task::TASKABLE_TYPES
      assert Task::TASKABLE_OWNERS.values.all? { |k| k.is_a?(Class) },
             "every declared type must supply a real class — that is what makes the map unsplittable"
    end

    # DERIVED FROM THE CONSTANT, NEVER WRITTEN PER TYPE. Every existing cross-tenant task assertion
    # in this repo is hardcoded to one literal type, which is exactly why none of them could see a
    # third type arriving with no check behind it. Looping the constant means a type added tomorrow
    # inherits this coverage on the day it is added.
    test "no declared taskable type may reference another user's row" do
      other = User.create!(email: "derived-owner@example.com")
      Task::TASKABLE_OWNERS.each do |type, klass|
        foreign = foreign_row_for(klass, other)
        task = @user.maker_tasks.build(title: "x", taskable_type: type, taskable_id: foreign.id)

        assert_not task.valid?, "#{type} accepted another user's row — the tenant check did not run"
        # The MESSAGE, not merely invalidity: a bogus type is refused by the `inclusion:` validator
        # alone, so asserting `errors.any?` would pass over a tenant check that never ran.
        assert_includes task.errors[:taskable_id], "must reference your own #{klass.model_name.element}"
      end
    end

    # THE TRAP THE FIX MUST NOT SPRING. A row with a `taskable_id` and no `taskable_type` is
    # reachable through the v1 API today (`taskable_type` is allow_nil, the check is guarded on
    # `taskable_id.present?`, and the two params are permitted independently), so failing closed on
    # every unresolvable type would make such a row permanently unsaveable — §14d's dangling-id
    # lock, one model over. Without this test that lock ships silently.
    # BOTH HALVES ARE NEEDED, because they stop being the same test the day the create door changes.
    # The first is the state as it arrives TODAY (probed through the real API: POST answers 201).
    # The second is the state as a row already in the database HAS it, built past the validations —
    # that is the one the lock would be permanent for, and it survives somebody later deciding a
    # bare `taskable_id` may no longer be created.
    test "a task with a taskable_id and no taskable_type stays editable" do
      task = @user.maker_tasks.create!(title: "half orphan", taskable_id: 99_999)
      assert_nil task.taskable_type

      task.title = "renamed"
      assert task.save, task.errors.full_messages.to_sentence
      assert_equal "renamed", task.reload.title
    end

    test "an already-persisted task with a dangling taskable_id and no type is not locked" do
      task = @user.maker_tasks.create!(title: "legacy", taskable: @item)
      task.update_columns(taskable_type: nil, taskable_id: 99_999)   # past every validation

      task.reload.title = "still editable"
      assert task.save, task.errors.full_messages.to_sentence
      assert_equal "still editable", task.reload.title
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

    private

    # Builds one row of `klass` owned by `owner`. A type added to `TASKABLE_OWNERS` with no arm here
    # RAISES rather than being skipped — the derived loop above must not silently stop covering a
    # type, and a hard error naming the class is the cheapest way to say "add your fixture".
    def foreign_row_for(klass, owner)
      case klass.name
      when "Maker::Item"    then owner.maker_items.create!(title: "Theirs")
      when "Maker::Project" then owner.maker_projects.create!(name: "Theirs")
      else raise "TASKABLE_OWNERS gained #{klass.name}: add a fixture arm to foreign_row_for"
      end
    end
  end
end
