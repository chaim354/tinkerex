require "test_helper"

module Maker
  # The destructive half of "a deleted file leaves its projects". The panel stops SHOWING a dead
  # attachment immediately (ProjectsController#show); this is what eventually destroys the row, and
  # the whole design question is how long "eventually" is — see Maker::DeadNodes.
  class AttachmentReaperTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "reap-#{SecureRandom.hex(4)}@example.com")
      @project = @user.maker_projects.create!(name: "Lamp")
    end

    def attach(node_id, role: "model")
      @project.file_attachments.create!(user: @user, node_id:, role:)
    end

    def node(node_id, deleted: false, updated_at: Time.current)
      n = @user.nodes.create!(node_id:, name: "#{node_id}.stl", kind: "file", deleted:)
      n.update_column(:updated_at, updated_at)
      n
    end

    test "an attachment whose node row is gone for good is reaped immediately" do
      attach("never-existed")
      assert_equal 1, Maker::AttachmentReaper.reap_all!
      assert_equal 0, @project.file_attachments.count
    end

    # A LIVE NODE IS NEVER TOUCHED. A reaper that could reach one would be deleting the thing the
    # page renders — the single worst failure available to this class of job.
    test "a live node's attachment is never reaped, whatever the grace" do
      node("alive")
      attach("alive")
      assert_equal 0, Maker::AttachmentReaper.reap_all!(grace: 0.seconds)
      assert_equal 1, @project.file_attachments.count
    end

    # THE POINT OF THE GRACE WINDOW. A tombstone is one undo away from returning with the SAME
    # node_id, and the attachment is keyed on that id — so reaping inside the window turns "restore
    # from Trash" into "restore, then re-file this into every project by hand".
    test "a fresh tombstone is spared, so an undo still returns a filed file" do
      node("tombstoned", deleted: true)
      attach("tombstoned")
      assert_equal 0, Maker::AttachmentReaper.reap_all!(grace: 30.days)
      assert_equal 1, @project.file_attachments.count
    end

    test "a tombstone past its undo window is reaped" do
      node("old", deleted: true, updated_at: 31.days.ago)
      attach("old")
      assert_equal 1, Maker::AttachmentReaper.reap_all!(grace: 30.days)
      assert_equal 0, @project.file_attachments.count
    end

    # DATED FROM THE NODE, NOT FROM THE ATTACHMENT. The attachment records when the user filed the
    # file, which can be a year before the deletion — reading it would reap a file deleted seconds
    # ago because it had been attached for long enough.
    test "the window is measured from the deletion, not from when the file was attached" do
      node("recent", deleted: true, updated_at: 1.day.ago)
      att = attach("recent")
      att.update_column(:created_at, 2.years.ago)

      assert_equal 0, Maker::AttachmentReaper.reap_all!(grace: 30.days)
      assert_equal 1, @project.file_attachments.count
    end

    test "dry_run counts without destroying" do
      attach("never-existed")
      assert_equal 1, Maker::AttachmentReaper.reap_all!(dry_run: true)
      assert_equal 1, @project.file_attachments.count
    end

    test "one user's failure does not stop the sweep for everyone else" do
      other = User.create!(email: "other-#{SecureRandom.hex(4)}@example.com")
      other.maker_projects.create!(name: "Theirs").file_attachments
           .create!(user: other, node_id: "also-gone", role: "model")
      attach("never-existed")

      assert_equal 2, Maker::AttachmentReaper.reap_all!
    end

    test "another user's attachments are never reaped by this user's sweep" do
      other = User.create!(email: "other-#{SecureRandom.hex(4)}@example.com")
      theirs = other.maker_projects.create!(name: "Theirs")
      theirs.file_attachments.create!(user: other, node_id: "gone", role: "model")

      Maker::AttachmentReaper.reap!(@user)
      assert_equal 1, theirs.file_attachments.count
    end

    # --- chosen covers ---------------------------------------------------------

    test "a chosen cover pointing at a dead node is cleared" do
      @project.update!(cover_node_id: "never-existed")
      assert_equal 1, Maker::AttachmentReaper.reap_all!
      assert_nil @project.reload[:cover_node_id]
    end

    test "a chosen cover on a live node is left alone" do
      node("alive")
      @project.update!(cover_node_id: "alive")
      assert_equal 0, Maker::AttachmentReaper.reap_all!(grace: 0.seconds)
      assert_equal "alive", @project.reload[:cover_node_id]
    end

    # A PROJECT WITH NO CHOSEN COVER HAS NOTHING TO SWEEP, and the `where.not(cover_node_id: [nil,
    # ""])` filter is what says so. Without it a blank column arrives as nil, `nodes[nil]` misses,
    # `reapable?(nil, …)` answers true, and the sweep "clears" a column that was already empty —
    # a pointless write reported as work done, on every project, on every run.
    #
    # THE FIXTURE'S DERIVED COVER IS LIVE ON PURPOSE. `cover_node_id` the METHOD falls back to that
    # derived pick, so a reaper reading the method instead of the column would find a live node and
    # also answer 0 — this test cannot tell those two spellings apart and does not claim to. What it
    # pins is the filter. (Mutation-checked both ways: removing the `where.not` reddens it; swapping
    # `p[:cover_node_id]` for `p.cover_node_id` does not, which is why the comment at that line says
    # so rather than claiming a distinction it does not have.)
    test "a project that never chose a cover is not counted as having a stale one" do
      node("alive")
      attach("alive")
      assert_equal "alive", @project.cover_node_id, "the derived fallback should be in play here"
      assert_nil @project[:cover_node_id], "and nothing is stored in the column itself"
      assert_equal 0, Maker::AttachmentReaper.reap_all!(grace: 0.seconds)
    end

    test "clearing a cover does not bump updated_at and reorder the project list" do
      @project.update!(cover_node_id: "never-existed")
      before = @project.reload.updated_at

      Maker::AttachmentReaper.reap_all!
      assert_equal before.to_i, @project.reload.updated_at.to_i,
                   "a background sweep must not reorder a list the user sorts by recent activity"
    end

    # --- the shared window -----------------------------------------------------

    # ONE definition, two reapers. They ask the identical question about the identical rows, so a
    # second copy is how they come to disagree the first time either changes.
    test "the attachment and preview reapers share one grace window" do
      assert_equal Maker::DeadNodes::GRACE, Maker::AttachmentReaper::GRACE
      assert_equal Maker::DeadNodes::GRACE, Maker::Previews::DeadNodeReaper::GRACE
    end
  end
end
