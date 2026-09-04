require "test_helper"

module Maker
  # Stage 3, S3-1: the per-user extension map's one row. Validation shape copied from
  # Maker::Shelf#path_segments_are_allowed (the same two reserved-name questions), and Task A's
  # own decision to key off FilesController::EXT_RE rather than a second regex
  # (docs/invariants/files-preview.md: every extension in the one vocabulary must satisfy it).
  class FilingRuleTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "filing-rule-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
    end

    test "ext and folder are normalized before validation" do
      rule = @user.maker_filing_rules.create!(ext: ".STL", folder: "  Models  ")
      assert_equal "stl", rule.ext
      assert_equal "models", rule.folder
    end

    # THE SAME BOUND EVERY ROLE_BY_EXT ENTRY MEETS -- referencing FilesController::EXT_RE rather
    # than a second copy, so a rule this validation accepts can never be one the Files page's own
    # filter chip fails to link to.
    test "ext must satisfy FilesController::EXT_RE" do
      assert @user.maker_filing_rules.new(ext: "stl", folder: "models").valid?
      assert @user.maker_filing_rules.new(ext: "markdown", folder: "docs").valid? # the 8-char bound

      refute @user.maker_filing_rules.new(ext: "toolongext", folder: "docs").valid? # 9 chars
      refute @user.maker_filing_rules.new(ext: "kicad_pcb", folder: "docs").valid? # underscore
      refute @user.maker_filing_rules.new(ext: "", folder: "docs").valid?
    end

    # THE REJECTIONS ARE THE POINT (test/models/maker/shelf_test.rb's own comment for the
    # identical pair of questions, asked here about a filing rule's folder instead of a shelf's
    # path). A reserved name here would become a real directory this app refuses to write to on
    # every other door -- .trash, a temp-file prefix and a repo marker.
    test "a reserved or malformed folder name is refused" do
      [ ".trash", ".maker-tmp-x", ".git", "a/b", "..", "." ].each do |bad|
        rule = @user.maker_filing_rules.new(ext: "stl", folder: bad)
        assert_not rule.valid?, "#{bad.inspect} should be refused as a folder name"
        assert_includes rule.errors[:folder].join, "isn't allowed"
      end
    end

    test "an ordinary lowercase folder name is accepted" do
      assert @user.maker_filing_rules.new(ext: "stl", folder: "models").valid?
      assert @user.maker_filing_rules.new(ext: "pdf", folder: "docs").valid?
    end

    test "ext is unique per user, not globally" do
      @user.maker_filing_rules.create!(ext: "stl", folder: "models")

      dup = @user.maker_filing_rules.new(ext: "STL", folder: "prints") # normalizes to the same ext
      assert_not dup.valid?
      assert_includes dup.errors[:ext].join, "taken"

      other_user = User.create!(email: "filing-rule-other-#{SecureRandom.hex(4)}@example.com",
                                confirmed_at: Time.current, omniauth_signup: true)
      assert other_user.maker_filing_rules.new(ext: "stl", folder: "models").valid?
    end

    test "folder presence is required" do
      rule = @user.maker_filing_rules.new(ext: "stl", folder: "")
      assert_not rule.valid?
      assert_includes rule.errors[:folder].join, "blank"
    end
  end
end
