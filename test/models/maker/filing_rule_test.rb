require "test_helper"

module Maker
  # Stage 3, S3-1: the per-user extension map's one row. Its folder check is
  # Maker::FilingRule.plain_segment? (the same two reserved-name questions every leaf-name door
  # asks), which Maker::Shelf's name asks too since 2026-10-20, and Task A's
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

    # THE FILING MAP'S KEY RULE IS WIDER THAN THE VOCABULARY'S, ON PURPOSE (stage 4, S4-2).
    # `kicad_sch`/`kicad_pcb` are nine characters with an underscore, so they fail
    # FilesController::EXT_RE and can never earn a ROLE_BY_EXT entry — an entry there renders a
    # filter chip that links and silently does nothing (docs/invariants/files-preview.md). A
    # filing rule renders no chip and grants no role: it answers one question, "which subfolder",
    # so it can carry a key the vocabulary cannot.
    test "ext satisfies KEY_RE, which admits the KiCad extensions EXT_RE cannot" do
      %w[stl kicad_sch kicad_pcb markdown gbrjob mage].each do |ext|
        rule = @user.maker_filing_rules.new(ext:, folder: "pcb")
        assert rule.valid?, "#{ext} should be a legal filing-rule key: #{rule.errors.full_messages}"
      end
      refute_match Maker::FilingRule::KEY_RE, "kicad_sch".upcase
      assert_no_match FilesController::EXT_RE, "kicad_sch"
    end

    # `"UPPER"` IS DELIBERATELY ABSENT FROM THIS LIST: `normalizes` downcases before validation
    # runs, so it lands on the same row as `"upper"` and IS valid — asserting it invalid would be
    # asserting the normalization away. What stays are the keys `Maker::ProjectFolders.ext_of` can
    # never produce (a dot), the ones past the bound, and the characters KEY_RE does not admit.
    test "a key that is not an extension at all is still refused" do
      [ "tar.gz", "way_too_long_ext", "with space", "", "a-b" ].each do |ext|
        rule = @user.maker_filing_rules.new(ext:, folder: "pcb")
        refute rule.valid?, "#{ext.inspect} must not be a legal key"
        assert_includes rule.errors.attribute_names, :ext
      end
    end

    # THE REJECTIONS ARE THE POINT: the pair of questions every leaf-name door asks, here about a
    # filing rule's folder (test/models/maker/shelf_test.rb asks them of a shelf's name through the
    # same .plain_segment?). A reserved name here would become a real directory this app refuses
    # to write to on every other door -- .trash, a temp-file prefix and a repo marker.
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
