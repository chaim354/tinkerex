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

    # THE SAME COLUMN LIVES ON `maker_models`, AND THE SWEEP HAS TO READ BOTH OR THE FALLBACK NEVER
    # TAKES OVER. A non-blank column permanently shadows the derived pick, and `stat_all` answers a
    # tombstone with an ABSENT KEY — so `Maker::Previews::ThumbnailMap` yields nothing for it, the
    # card paints a spinner, and `thumbs_controller.js` skips a node it got no entry for. It spins
    # on every page load, forever, and no other sweep clears it.
    #
    # ASSERT THE RAW COLUMN, WITH `[]`, AND THE LIVE ATTACHMENT IS WHAT MAKES THAT SPELLING CARRY
    # WEIGHT. Probed: before the sweep the column and the method BOTH read "never-existed" (the
    # column shadows the derived pick — that is the bug); after it the column is nil and the method
    # answers "alive". So `assert_nil model.reload.cover_node_id` would fail over a CORRECT fix,
    # and only the column spelling can pin this.
    #
    # AND AN ASSERTION ABOUT THE MODEL'S ATTACHMENTS WOULD PASS WITH OR WITHOUT THE FIX —
    # `user.maker_file_attachments` is polymorphic and has always swept a model's attachments. The
    # COVER is the half that was missing, which is why the attachment here is a LIVE one.
    test "a model's chosen cover pointing at a dead node is cleared, restoring the derived pick" do
      node("alive")
      model = @user.maker_models.create!(title: "Case", cover_node_id: "never-existed")
      model.file_attachments.create!(user: @user, node_id: "alive", role: "model")

      assert_equal 1, Maker::AttachmentReaper.reap_all!
      assert_nil model.reload[:cover_node_id]
      assert_equal "alive", model.cover_node_id, "the derived fallback takes over once the column is cleared"
    end

    # The model path goes through the SAME window rather than clearing on sight — a tombstone is one
    # undo away from returning with the same node_id, and the cover is keyed on that id.
    test "a model's tombstoned cover is spared inside its undo window and cleared past it" do
      node("tombstoned", deleted: true, updated_at: 29.days.ago)
      model = @user.maker_models.create!(title: "Case", cover_node_id: "tombstoned")

      assert_equal 0, Maker::AttachmentReaper.reap_all!(grace: 30.days)
      assert_equal "tombstoned", model.reload[:cover_node_id]

      @user.nodes.find_by!(node_id: "tombstoned").update_column(:updated_at, 31.days.ago)
      assert_equal 1, Maker::AttachmentReaper.reap_all!(grace: 30.days)
      assert_nil model.reload[:cover_node_id]
    end

    # The `where.not(cover_node_id: [nil, ""])` filter on the NEW term, same argument as the project
    # one above: without it a blank column arrives as nil, `nodes[nil]` misses, `reapable?(nil, …)`
    # answers true, and the sweep reports a pointless write as work done on every model, every run.
    test "a model that never chose a cover is not counted as having a stale one" do
      @user.maker_models.create!(title: "Case")

      assert_equal 0, Maker::AttachmentReaper.reap_all!(grace: 0.seconds)
    end

    # ---- file links (stage 4, S4-8) ------------------------------------------------------

    def link(from, to, kind: "derived_from")
      @user.maker_file_links.create!(from_node_id: from, to_node_id: to, kind:)
    end

    test "a link is reaped when EITHER end is gone for good, and not while both are live" do
      node("live-a"); node("live-b")
      link("live-a", "live-b")
      assert_equal 0, Maker::AttachmentReaper.reap_all!, "a link between two live files is never touched"

      node("live-c")
      link("live-c", "never-existed")
      assert_equal 1, Maker::AttachmentReaper.reap_all!
      assert_equal 1, @user.maker_file_links.count

      link("never-existed-either", "live-c")
      assert_equal 1, Maker::AttachmentReaper.reap_all!, "the FROM end counts as much as the TO end"
      assert_equal 1, @user.maker_file_links.count
    end

    test "a link to a fresh tombstone is spared and one past the window is reaped" do
      node("live-d")
      node("tomb", deleted: true, updated_at: 2.days.ago)
      link("live-d", "tomb")
      assert_equal 0, Maker::AttachmentReaper.reap_all!, "an undo would bring the file back with the same id"

      @user.nodes.find_by!(node_id: "tomb").update_column(:updated_at, 31.days.ago)
      assert_equal 1, Maker::AttachmentReaper.reap_all!
      assert_equal 0, @user.maker_file_links.count
    end

    test "dry_run counts links without destroying them" do
      link("gone-1", "gone-2")
      assert_equal 1, Maker::AttachmentReaper.reap_all!(dry_run: true)
      assert_equal 1, @user.maker_file_links.count
    end

    test "another user's links are never reaped by this user's sweep" do
      other = User.create!(email: "other-#{SecureRandom.hex(4)}@example.com")
      other.maker_file_links.create!(from_node_id: "x", to_node_id: "y", kind: "photo_of")
      assert_equal 0, Maker::AttachmentReaper.reap!(@user)
      assert_equal 1, other.maker_file_links.count
    end

    # --- the shared window -----------------------------------------------------

    # ONE definition, two reapers. They ask the identical question about the identical rows, so a
    # second copy is how they come to disagree the first time either changes.
    test "the attachment and preview reapers share one grace window" do
      assert_equal Maker::DeadNodes::GRACE, Maker::AttachmentReaper::GRACE
      assert_equal Maker::DeadNodes::GRACE, Maker::Previews::DeadNodeReaper::GRACE
    end

    test "a pin is reaped with its folder: gone for good at once, a tombstone only past the window" do
      gone  = @user.nodes.create!(node_id: "pin-gone", name: "gone", kind: "dir")
      old   = @user.nodes.create!(node_id: "pin-old", name: "old", kind: "dir")
      fresh = @user.nodes.create!(node_id: "pin-fresh", name: "fresh", kind: "dir")
      live  = @user.nodes.create!(node_id: "pin-live", name: "live", kind: "dir")
      [ gone, old, fresh, live ].each { |n| @user.maker_pins.create!(node_id: n.node_id) }
      gone.destroy!
      old.update_columns(deleted: true, updated_at: 31.days.ago)
      fresh.update_columns(deleted: true)

      assert_equal 2, Maker::AttachmentReaper.reap_all!(grace: 30.days)
      assert_equal %w[pin-fresh pin-live], @user.maker_pins.order(:node_id).pluck(:node_id)
    end
  end
end
