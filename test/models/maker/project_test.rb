require "test_helper"

module Maker
  class ProjectTest < ActiveSupport::TestCase
    setup { @user = User.create!(email: "proj@example.com") }

    test "valid with a name" do
      project = @user.maker_projects.build(name: "Smart Lamp")
      assert project.valid?
    end

    test "name is required" do
      project = @user.maker_projects.build(name: nil)
      assert_not project.valid?
      assert_includes project.errors[:name], "can't be blank"
    end

    test "slug is auto-generated from the name on create" do
      project = @user.maker_projects.create!(name: "Smart Lamp v2!")
      assert_equal "smart-lamp-v2", project.slug
    end

    test "explicit slug is respected and normalized" do
      project = @user.maker_projects.create!(name: "Lamp", slug: "My Custom Slug")
      assert_equal "my-custom-slug", project.slug
    end

    test "slug is unique per user" do
      @user.maker_projects.create!(name: "Lamp")
      dup = @user.maker_projects.build(name: "Lamp")
      assert_not dup.valid?
      assert_includes dup.errors[:slug], "has already been taken"
    end

    test "same slug allowed for a different user" do
      @user.maker_projects.create!(name: "Lamp")
      other = User.create!(email: "other@example.com")
      assert other.maker_projects.build(name: "Lamp").valid?
    end

    test "status must be in the allowed set" do
      assert_not @user.maker_projects.build(name: "x", status: "bogus").valid?
    end

    test "defaults status to planning" do
      project = @user.maker_projects.create!(name: "x")
      assert_equal "planning", project.status
    end

    test "archive! stamps archived_at and sets status archived" do
      project = @user.maker_projects.create!(name: "x")
      project.archive!
      assert_equal "archived", project.status
      assert_not_nil project.archived_at
    end

    test "scoped to the user via the association" do
      @user.maker_projects.create!(name: "mine")
      other = User.create!(email: "o2@example.com")
      other.maker_projects.create!(name: "theirs")
      assert_equal [ "mine" ], @user.maker_projects.pluck(:name)
    end

    test "archive! then unarchive! round-trips the lifecycle state" do
      project = @user.maker_projects.create!(name: "Old Rig")

      project.archive!
      assert_equal "archived", project.status
      assert_not_nil project.archived_at

      project.unarchive!
      assert_equal "active", project.status
      assert_nil project.archived_at
    end
  end
end
