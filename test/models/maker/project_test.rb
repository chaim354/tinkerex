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

    test "slugify normalizes a folder name" do
      assert_equal "desk-lamp", Maker::Project.slugify("Desk Lamp")
      assert_equal "desk-lamp", Maker::Project.slugify("  Desk--Lamp!  ")
      assert_equal "", Maker::Project.slugify("プロジェクト")
    end

    test "available_slug de-dups against the user's existing projects" do
      @user.maker_projects.create!(name: "Desk Lamp")

      assert_equal "desk-lamp-2", Maker::Project.available_slug(@user, from: "Desk Lamp")
    end

    # ANY PURELY NON-LATIN NAME REDUCES TO "" — slugify keeps only [a-z0-9] — and
    # `validates :slug, presence: true` would then raise inside a recurring job. Not exotic:
    # プロジェクト, Проект, 模型.
    test "available_slug falls back to project for a name with no latin characters" do
      assert_equal "project", Maker::Project.available_slug(@user, from: "プロジェクト")
    end

    # THE SLUG MUST SURVIVE THE CALLBACK. #ensure_slug re-normalizes `slug.presence || name`, so a
    # de-duped slug handed in explicitly has to normalize to itself — otherwise the -2 is stripped
    # back off on save and the create raises anyway.
    test "an explicitly supplied de-duped slug is stable through ensure_slug" do
      @user.maker_projects.create!(name: "Desk Lamp")
      slug = Maker::Project.available_slug(@user, from: "Desk Lamp")

      project = @user.maker_projects.create!(name: "Desk Lamp", slug:)

      assert_equal "desk-lamp-2", project.slug
    end

    # THE WEB FORM'S BEHAVIOUR IS DELIBERATELY UNCHANGED. A human typing a duplicate name SHOULD be
    # told; only the sweep gets the import treatment. This is the guard that Task 2's refactor did
    # not quietly turn #ensure_slug into a de-duper.
    test "a duplicate name still fails validation when no slug is supplied" do
      @user.maker_projects.create!(name: "Desk Lamp")

      duplicate = @user.maker_projects.new(name: "Desk Lamp")

      refute_predicate duplicate, :valid?
      assert_includes duplicate.errors[:slug], "has already been taken"
    end

    # STAGE 4, S4-7: the column defaults are what make the migration invisible (spec §4).
    test "a new project is other, with no overrides and today's panel list" do
      project = @user.maker_projects.create!(name: "Fresh")

      assert_equal "other", project.kind
      assert_nil project[:panels]
      assert_equal Maker::Project::PANELS, project.visible_panels
    end

    test "kind is validated against KINDS" do
      project = @user.maker_projects.new(name: "Bad", kind: "wormhole")

      refute project.valid?
      assert_includes project.errors[:kind].join, "not included"
    end

    # THE PRESET IS A GUESS; A CHOSEN COVER IS AN ANSWER. Asserted through #cover_node_id (the
    # reader every card and the hero use), not through #derived_cover_node_id, because the ordering
    # of those two is the rule.
    test "a print project prefers a model for its hero, and a chosen cover still wins" do
      project = @user.maker_projects.create!(name: "Bracket", kind: "print")
      project.file_attachments.create!(user: @user, node_id: "img", role: "image", position: 0)
      project.file_attachments.create!(user: @user, node_id: "mdl", role: "model", position: 1)

      assert_equal "mdl", project.cover_node_id

      project.update!(cover_node_id: "img")
      assert_equal "img", project.cover_node_id
    end

    test "an other project's hero is the image, exactly as before the kind existed" do
      project = @user.maker_projects.create!(name: "Tray")
      project.file_attachments.create!(user: @user, node_id: "mdl", role: "model", position: 0)
      project.file_attachments.create!(user: @user, node_id: "img", role: "image", position: 1)

      assert_equal "img", project.cover_node_id
    end
  end
end
