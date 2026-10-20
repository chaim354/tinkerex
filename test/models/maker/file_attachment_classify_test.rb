require "test_helper"

module Maker
  # STORED ROLES FOLLOW THE VOCABULARY BY ONE RULE (F-S33-1, 2026-10-19). `role` is written when the
  # row is, so a row written before `ROLE_BY_EXT` learned its extension says `other` until something
  # rewrites it. That used to be a hand-copied data migration per widening — seven of them, beside
  # an eighth role migration that RE-classified `lbrn2` — and two widenings never got one:
  # `nc`/`tap`/`ngc` (2026-07-31) and the 24 Gerber extensions (2026-09-06, whose SeedPcbFilingRules
  # seeds filing rules only), which is how an electronics project came to show a photo where its
  # board should be. `Maker::FileAttachment.classify_unclassified!` is the one owner now: it
  # re-reads a user's `other` rows against TODAY's table, so the next widening's row half is the
  # table edit and nothing else.
  class FileAttachmentClassifyTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "classify-#{SecureRandom.hex(4)}@example.com")
      @project = @user.maker_projects.create!(name: "Board")
    end

    def classify(user = @user) = Maker::FileAttachment.classify_unclassified!(user)

    # A file named `name` in `user`'s library, and `project`'s attachment to it, stored as `role`.
    def attach(name, role, user: @user, project: @project)
      node_id = SecureRandom.uuid
      user.nodes.create!(node_id:, name:, kind: "file", mtime: 1, size: 1)
      project.file_attachments.create!(user:, node_id:, role:)
    end

    # DERIVED FROM THE TABLE, NEVER COPIED — which is the whole difference from the nine migration
    # tests: a list written out here would be the tenth copy, and would miss the next widening exactly
    # the way the migrations missed two. `valid?` because the sweep writes with `update_all`, which
    # skips the inclusion validation every attach door goes through.
    test "every extension the vocabulary names takes its role from a row stored other" do
      rows = Maker::FileAttachment::ROLE_BY_EXT.keys.index_with { |ext| attach("f.#{ext}", "other") }

      assert_equal rows.size, classify
      rows.each do |ext, att|
        assert_equal Maker::FileAttachment::ROLE_BY_EXT.fetch(ext), att.reload.role, ".#{ext}"
        assert att.valid?, ".#{ext} was given a role the validation refuses"
      end
    end

    # THE TWO WIDENINGS THAT NEVER GOT THEIR ROW HALF, named so the defect has a test of its own. The
    # upper case is deliberate: the sweep asks `role_for`, which downcases, rather than matching an
    # extension in SQL — a "faster" spelling that dropped the downcase would leave this Gerber `other`.
    test "the g-code dialects and the Gerber layers a migration never reached heal" do
      dialects = %w[part.nc part.tap part.ngc].map { |name| attach(name, "other") }
      gerber = attach("Board.GTL", "other")

      assert_equal 4, classify
      dialects.each { |att| assert_equal "gcode", att.reload.role }
      assert_equal "pcb", gerber.reload.role
    end

    # `other` IS THE ONE STORED STATE THE VOCABULARY CAN STILL IMPROVE, and "nothing classified this
    # name" is what it means. A name the table does not know — an unknown extension, or a basename-only
    # text file (`TEXT_BASENAMES` grants no ROLE, on purpose: a role would move `LICENSE` into `docs/`)
    # — stays exactly where it is.
    test "a name the vocabulary does not know stays other" do
      rows = [ attach("blob.xyz", "other"), attach("LICENSE", "other"), attach("Makefile", "other") ]

      assert_equal 0, classify
      rows.each { |att| assert_equal "other", att.reload.role }
    end

    # A ROLE ANYTHING WROTE ON PURPOSE IS NEVER REWRITTEN. The schema keeps no "chosen vs derived"
    # column, so `other` is the discriminator: the build-log photo door writes `image` for any node it
    # is handed, and a v1 client may post any role it likes. Both names below would derive something
    # else (`code`, `pcb`), which is what makes the refusal visible.
    test "a role written deliberately is never rewritten, whatever the name derives" do
      log = attach("serial.log", "instructions")
      photo = attach("board.gbr", "image")

      assert_equal 0, classify
      assert_equal "instructions", log.reload.role
      assert_equal "image", photo.reload.role
    end

    test "a row whose node is gone is left alone, not crashed on" do
      ghost = @project.file_attachments.create!(user: @user, node_id: "ghost", role: "other")

      assert_equal 0, classify
      assert_equal "other", ghost.reload.role
    end

    # ZERO WRITES IN STEADY STATE, and the count says so. The second run still READS the `.xyz` row
    # (it is `other`); what it must not do is report a no-op rewrite of it as work.
    test "a second run finds nothing to do" do
      attach("f.gbr", "other")
      attach("blob.xyz", "other")

      assert_equal 1, classify
      assert_equal 0, classify
    end

    # TENANT = USER (§8), twice over. The rows swept are this user's...
    test "another user's stale row waits for their own run" do
      other = User.create!(email: "classify-other-#{SecureRandom.hex(4)}@example.com")
      theirs = attach("theirs.gbr", "other", user: other, project: other.maker_projects.create!(name: "Theirs"))
      mine = attach("mine.gbr", "other")

      assert_equal 1, classify
      assert_equal "pcb", mine.reload.role
      assert_equal "other", theirs.reload.role
    end

    # ...and the NAME read is off this user's node. node_ids are unique per user, not globally, so a
    # dangling row whose id another user's library happens to hold must not borrow that file's name.
    test "a name is read off the row's own user's node, never another user's node with the same id" do
      other = User.create!(email: "classify-other-#{SecureRandom.hex(4)}@example.com")
      other.nodes.create!(node_id: "same-id", name: "board.gbr", kind: "file", mtime: 1, size: 1)
      dangling = @project.file_attachments.create!(user: @user, node_id: "same-id", role: "other")

      assert_equal 0, classify
      assert_equal "other", dangling.reload.role
    end

    # THE REPORTED SHAPE, END TO END: the electronics hero prefers `pcb` (Maker::ProjectKind
    # HERO_ROLES), so a board attached while `.gtl` was still `other` lost the hero to a photo.
    test "an electronics project's hero moves from the photo to the board once its Gerber is classified" do
      @project.update!(kind: "electronics")
      gerber = attach("top.gtl", "other")
      photo = attach("bench.jpg", "image")
      assert_equal photo.node_id, @project.reload.cover_node_id, "before the sweep the photo wins"

      classify

      assert_equal gerber.node_id, @project.reload.cover_node_id
    end
  end
end
