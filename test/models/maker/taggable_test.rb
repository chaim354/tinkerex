require "test_helper"

module Maker
  # Maker::Taggable (stage 2, S2-5): the concern Maker::Model's tag behaviour was lifted into so
  # Project and InventoryItem can share it verbatim. Exercised on those two rather than on Model
  # (whose own tag_list coverage stays in model_test.rb, unchanged, to prove the lift moved
  # nothing) -- and across BOTH included classes, so a scope or callback wired to one class by
  # accident (e.g. `Maker::Project.tagged_with` defined but not `Maker::InventoryItem`'s) shows up.
  class TaggableTest < ActiveSupport::TestCase
    setup { @user = User.create!(email: "taggable@example.com") }

    test "tag_list= on a new record applies after save, not before" do
      project = @user.maker_projects.build(name: "Desk Lamp")
      project.tag_list = "laser, firmware"
      assert_empty project.tags, "the pending list must not apply until save"
      project.save!
      assert_equal %w[firmware laser], project.reload.tag_list.split(", ").sort
    end

    test "tag_list= replaces the set rather than adding to it" do
      item = @user.maker_inventory_items.create!(name: "M3 bolt", unit: "each", tag_list: "fasteners")
      item.update!(tag_list: "hardware")
      assert_equal [ "hardware" ], item.reload.tags.pluck(:name)
    end

    test "tag_list= normalizes whitespace, case and duplicates" do
      project = @user.maker_projects.create!(name: "Desk Lamp", tag_list: "  Laser , LASER, firmware ")
      assert_equal %w[firmware laser], project.reload.tag_list.split(", ").sort
      assert_equal 2, @user.maker_tags.count
    end

    test "a tag shared by a model and a project is one maker_tags row" do
      model = @user.maker_models.create!(title: "Bracket", tag_list: "laser")
      project = @user.maker_projects.create!(name: "Desk Lamp", tag_list: "laser")
      assert_equal 1, @user.maker_tags.where(name: "laser").count
      assert_equal model.tags.first, project.tags.first
    end

    # THE NEGATIVE CASE MUST WEAR A DIFFERENT TAG, NOT NO TAG AT ALL -- an untagged record is
    # already excluded by the scope's INNER JOIN alone, so a mutation that drops the `where` (name
    # match) entirely still passes an "untagged sibling" test (mutation-checked: it did, silently).
    # A sibling wearing a DIFFERENT tag is still a match for `joins(:tags)` with no name filter, so
    # it is the negative case that actually exercises the `where`.
    test "tagged_with finds the record wearing the named tag and not one wearing a different tag" do
      laser = @user.maker_projects.create!(name: "Desk Lamp", tag_list: "laser")
      @user.maker_projects.create!(name: "Board", tag_list: "firmware")
      assert_equal [ laser ], @user.maker_projects.tagged_with("laser").to_a
    end

    test "tagged_with normalizes the name it is asked about" do
      laser = @user.maker_projects.create!(name: "Desk Lamp", tag_list: "laser")
      @user.maker_projects.create!(name: "Board", tag_list: "firmware")
      assert_equal [ laser ], @user.maker_projects.tagged_with("  LASER ").to_a
    end

    test "destroying the project destroys its taggings and not the tag" do
      project = @user.maker_projects.create!(name: "Desk Lamp", tag_list: "laser")
      tag = @user.maker_tags.find_by!(name: "laser")
      assert_difference -> { Maker::Tagging.count }, -1 do
        project.destroy!
      end
      assert Maker::Tag.exists?(tag.id), "the tag itself must survive"
    end
  end
end
