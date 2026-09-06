require "test_helper"

module Maker
  # PUBLISHING (stage 3, S3-4): visibility, the unlisted token and the SPDX license. The two rules
  # worth breaking on purpose are that publishing needs a handle (no handle, no URL) and that the
  # token is minted ONCE -- a link already handed out must keep working.
  class ProjectPublishingTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "pub-#{SecureRandom.hex(4)}@example.com", handle: "chaim")
      @project = @user.maker_projects.create!(name: "Desk Lamp")
    end

    # --- the default ---------------------------------------------------------------------------

    test "a new project is private and carries no token" do
      assert_equal "private", @project.visibility
      assert_nil @project.unlisted_token
      assert_not_predicate @project, :published?
      assert_not_predicate @project, :publicly_listed?
    end

    test "visibility is one of the three" do
      @project.visibility = "secret"
      assert_not @project.valid?
      assert_includes @project.errors[:visibility], "is not included in the list"
    end

    # --- the token -----------------------------------------------------------------------------

    test "leaving private mints 32 hex characters" do
      assert @project.update(visibility: "unlisted"), @project.errors.full_messages.to_sentence
      assert_match(/\A\h{32}\z/, @project.unlisted_token)
      assert_predicate @project, :unlisted?
      assert_predicate @project, :published?
    end

    test "the token survives a second save, a switch to public, and a switch back to private" do
      # THE WHOLE POINT OF `||=`. Reminting on any of these three silently 404s a link someone was
      # already given, with nothing anywhere going red.
      @project.update!(visibility: "unlisted")
      minted = @project.unlisted_token

      @project.update!(name: "Desk Lamp v2")
      assert_equal minted, @project.reload.unlisted_token, "a plain save reminted the token"

      @project.update!(visibility: "public")
      assert_equal minted, @project.reload.unlisted_token, "going public reminted the token"

      @project.update!(visibility: "private")
      assert_equal minted, @project.reload.unlisted_token, "going private cleared or reminted the token"
    end

    test "two published projects get different tokens" do
      @project.update!(visibility: "unlisted")
      other = @user.maker_projects.create!(name: "Lathe", visibility: "unlisted")
      assert_not_equal @project.unlisted_token, other.unlisted_token
    end

    # --- the handle ----------------------------------------------------------------------------

    test "publishing without a handle is refused, naming the handle" do
      handleless = User.create!(email: "nh-#{SecureRandom.hex(4)}@example.com")
      project = handleless.maker_projects.create!(name: "Desk Lamp")

      assert_not project.update(visibility: "public")
      assert_includes project.errors[:visibility].join(" "), "handle"
      assert_equal "private", project.reload.visibility
    end

    test "staying private without a handle is fine" do
      handleless = User.create!(email: "nh-#{SecureRandom.hex(4)}@example.com")
      assert handleless.maker_projects.create!(name: "Desk Lamp").valid?
    end

    # --- the license ---------------------------------------------------------------------------

    test "no license is a legitimate license" do
      assert_predicate @project, :valid?
      assert_nil @project.license
      assert_nil @project.license_label
    end

    test "an SPDX id from the list is accepted and labelled" do
      assert @project.update(license: "MIT")
      assert_equal "MIT", @project.license_label
      assert @project.update(license: "CERN-OHL-S-2.0")
      assert_equal "CERN OHL v2 Strongly Reciprocal", @project.license_label
    end

    test "an id off the list is refused" do
      @project.license = "WTFPL"
      assert_not @project.valid?
      assert_includes @project.errors[:license], "is not included in the list"
    end

    test "a blank license normalizes to nil rather than failing the inclusion check" do
      # The form's "None" option posts "", which must mean "no license" and not "the empty license".
      assert @project.update(license: ""), @project.errors.full_messages.to_sentence
      assert_nil @project.reload.license
    end

    # --- the scopes ----------------------------------------------------------------------------

    test "published is everything not private; publicly_listed is public alone" do
      unlisted = @user.maker_projects.create!(name: "Lathe", visibility: "unlisted")
      public_p = @user.maker_projects.create!(name: "Kiln", visibility: "public")

      assert_equal [ public_p, unlisted ].map(&:id).sort, @user.maker_projects.published.pluck(:id).sort
      assert_equal [ public_p.id ], @user.maker_projects.publicly_listed.pluck(:id)
    end
  end
end
