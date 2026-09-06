require "test_helper"

module Maker
  # STAGE 3, S3-5. The row itself: what a version may be named, that a version is unique WITHIN a
  # project and free to repeat across projects, and the four deletion behaviours a release depends
  # on (its files go with it, its project takes it with it, its BOM does not, and the recorded
  # revision number survives the BOM that had it).
  class ReleaseTest < ActiveSupport::TestCase
    ATTACHMENT = %q(<action-text-attachment sgid="abc" caption="a photo"></action-text-attachment>).freeze

    setup do
      @user = User.create!(email: "rel-#{SecureRandom.hex(4)}@example.com")
      @project = @user.maker_projects.create!(name: "Desk Lamp")
    end

    def build_release(**attrs)
      @project.releases.build({ user: @user, version: "v0.1.0", published_at: Time.current }.merge(attrs))
    end

    test "a plain release is valid" do
      assert build_release.valid?
    end

    test "the versions a maker actually types are accepted" do
      %w[v0.1.0 1.0 2026-09-06 rev_2 A].each do |version|
        release = build_release(version:)
        assert release.valid?, "#{version.inspect} should be a valid version: #{release.errors.full_messages}"
      end
    end

    test "a version is trimmed before it is validated" do
      release = build_release(version: "  v1.2.3  ")
      assert release.valid?
      assert_equal "v1.2.3", release.version
    end

    test "a blank version is refused" do
      release = build_release(version: "   ")
      assert_not release.valid?
      assert_includes release.errors[:version], "can't be blank"
    end

    # The format is a NAME, not a path and not a sentence: it reaches a flash message and a URL's
    # query string, and 40 characters is a version rather than a changelog.
    test "a version longer than 40 characters, with a space, or with a path segment is refused" do
      { "v" + ("1" * 40) => "41 characters",
        "v 1"            => "a space",
        "../x"           => "a path segment",
        ".hidden"        => "a leading dot" }.each do |version, why|
        release = build_release(version:)
        assert_not release.valid?, "#{version.inspect} (#{why}) should be refused"
        assert_includes release.errors[:version].join, "letters, digits"
      end
    end

    test "published_at is required" do
      release = build_release(published_at: nil)
      assert_not release.valid?
      assert_includes release.errors[:published_at], "can't be blank"
    end

    test "a version is unique within one project" do
      build_release.save!
      duplicate = build_release
      assert_not duplicate.valid?
      assert_includes duplicate.errors[:version], "is already a release of this project"
    end

    # The half a uniqueness scope is for: the same version number on a DIFFERENT project is the
    # normal case, not a collision.
    test "the same version on a second project is fine" do
      build_release.save!
      other = @user.maker_projects.create!(name: "Bench PSU")
      assert other.releases.build(user: @user, version: "v0.1.0", published_at: Time.current).valid?
    end

    test "a release must name the acting user's own project" do
      stranger = User.create!(email: "other-#{SecureRandom.hex(4)}@example.com")
      theirs = stranger.maker_projects.create!(name: "Not Yours")
      release = Maker::Release.new(user: @user, project: theirs, version: "v1", published_at: Time.current)
      assert_not release.valid?
      assert_includes release.errors[:project_id], "must reference your own project"
    end

    test "short_oid is eight characters, and nil when no commit was recorded" do
      assert_equal "deadbeef", build_release(git_oid: "deadbeefcafe1234").short_oid
      assert_nil build_release.short_oid
      assert_nil build_release(git_oid: "").short_oid
    end

    test "a blank tag normalizes to nil so a release without one records nothing" do
      release = build_release(git_tag: "   ")
      release.save!
      assert_nil release.reload.git_tag
    end

    # The server half of the text-only policy, on the attribute this model actually carries.
    # Maker::TextOnlyRichText read `body` LITERALLY until S3-5; a release's changelog is `notes`,
    # so without the attribute being configurable this save raises NoMethodError.
    test "an attachment in the changelog does not survive the save" do
      release = build_release(notes: "<div>shipped #{ATTACHMENT} it</div>")
      release.save!
      release.reload
      assert_equal 0, release.notes.body.attachments.size
      assert_not_includes release.notes.body.to_html, "action-text-attachment"
      assert_includes release.notes.body.to_html, "shipped"
    end

    test "destroying a release destroys its files" do
      release = build_release
      release.save!
      release.files.create!(user: @user, node_id: SecureRandom.uuid, name: "base.stl")

      assert_difference -> { Maker::ReleaseFile.count }, -1 do
        release.destroy!
      end
    end

    test "destroying a project destroys its releases and their files" do
      release = build_release
      release.save!
      release.files.create!(user: @user, node_id: SecureRandom.uuid, name: "base.stl")

      @project.destroy!

      assert_equal 0, Maker::Release.where(project_id: @project.id).count
      assert_equal 0, Maker::ReleaseFile.where(release_id: release.id).count
    end

    # A RELEASE OUTLIVES THE BOM IT RECORDED, and the recorded number is the reason: `bom_revision`
    # is a copy taken at release time, so "revision 3 was current" stays true after revision 3 is
    # deleted. `dependent: :destroy` on Bom#releases would delete published releases as a side
    # effect of tidying a BOM.
    test "destroying a BOM nullifies the pointer and keeps the recorded revision" do
      bom = @project.boms.create!(user: @user, revision: 3)
      release = build_release(bom:, bom_revision: bom.revision)
      release.save!

      bom.destroy!
      release.reload

      assert_nil release.bom_id
      assert_equal 3, release.bom_revision
    end

    test "a release file needs a node and a name" do
      release = build_release
      release.save!
      file = release.files.build(user: @user)
      assert_not file.valid?
      assert_includes file.errors[:node_id], "can't be blank"
      assert_includes file.errors[:name], "can't be blank"
    end

    test "files are listed by path then name" do
      release = build_release
      release.save!
      release.files.create!(user: @user, node_id: SecureRandom.uuid, name: "z.stl", path: "models/z.stl")
      release.files.create!(user: @user, node_id: SecureRandom.uuid, name: "a.stl", path: "models/a.stl")
      release.files.create!(user: @user, node_id: SecureRandom.uuid, name: "readme.md", path: "readme.md")

      assert_equal %w[models/a.stl models/z.stl readme.md], release.files.reload.map(&:path)
    end
  end
end
