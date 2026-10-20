require "test_helper"

module Maker
  # The schedule half of F-S33-1: Maker::FileAttachment.classify_unclassified! is the rule, and this
  # job is what runs it for every user without anyone having to remember a migration.
  class ClassifyAttachmentRolesJobTest < ActiveJob::TestCase
    # The house stub helper (new_menu_test.rb carries the same body; Minitest 6 has no Object#stub).
    # Replaces a SINGLETON method for the block, removing an inherited one after.
    def replacing(owner, name, replacement)
      mod = owner.singleton_class
      own = mod.instance_methods(false).include?(name)
      original = mod.instance_method(name)
      mod.define_method(name, &replacement)
      yield
    ensure
      own ? mod.define_method(name, original) : mod.remove_method(name)
    end

    def user!(tag)
      User.create!(email: "classify-job-#{tag}-#{SecureRandom.hex(4)}@example.com")
    end

    # A stale row: a Gerber attached while the vocabulary still called `.gbr` nothing.
    def stale_gerber!(user)
      node_id = SecureRandom.uuid
      user.nodes.create!(node_id:, name: "top.gbr", kind: "file", mtime: 1, size: 1)
      user.maker_projects.create!(name: "Board").file_attachments.create!(user:, node_id:, role: "other")
    end

    test "perform classifies every user's stale rows and returns the total" do
      mine = stale_gerber!(user!("a"))
      theirs = stale_gerber!(user!("b"))

      assert_equal 2, Maker::ClassifyAttachmentRolesJob.perform_now
      assert_equal "pcb", mine.reload.role
      assert_equal "pcb", theirs.reload.role
    end

    # ONE USER'S FAILURE MUST NOT STOP THE SWEEP FOR EVERYONE ELSE — Maker::AttachmentReaper.reap_all!'s
    # isolation, copied. Induced for real here: the reaper's own test of the same name never makes a
    # user fail, so it would stay green with the rescue deleted.
    test "one user's failure does not stop the sweep for everyone else" do
      broken = user!("broken")
      broken_row = stale_gerber!(broken)
      fine_row = stale_gerber!(user!("fine"))
      real = Maker::FileAttachment.method(:classify_unclassified!)
      failing = ->(user) { user.id == broken.id ? raise(ActiveRecord::StatementInvalid, "induced") : real.call(user) }

      classified = replacing(Maker::FileAttachment, :classify_unclassified!, failing) do
        Maker::ClassifyAttachmentRolesJob.perform_now
      end

      assert_equal 1, classified
      assert_equal "pcb", fine_row.reload.role
      assert_equal "other", broken_row.reload.role
    end

    # config/recurring.yml is read by the Solid Queue SUPERVISOR, never by the process the suite boots
    # (test/recurring_schedule_test.rb's header), so an entry that is missing or names another class is
    # a sweep that silently never runs. That file checks that every entry RESOLVES; this checks that
    # THIS one exists and points here.
    test "the recurring schedule runs this job every day" do
      entry = YAML.load_file(Rails.root.join("config/recurring.yml")).dig("production", "classify_attachment_roles")

      assert entry, "config/recurring.yml has no classify_attachment_roles entry"
      assert_equal "Maker::ClassifyAttachmentRolesJob", entry["class"]
      assert_match(/\Aevery day at /, entry["schedule"])
    end
  end
end
