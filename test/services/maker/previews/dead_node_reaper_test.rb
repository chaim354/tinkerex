require "test_helper"

module Maker
  module Previews
    # The SECOND orphan class, and the one the (node, kind) unique index cannot reach: a preview
    # whose node no longer exists. A dead node's row is the ONLY row for that node, so there is no
    # duplicate group to collapse and nothing sweeps it. Measured after the collapse migration:
    # 93 on the deployed share library, 3 on chunk.
    #
    # The whole design question here is REVIVABILITY, so that is what these tests are about.
    class DeadNodeReaperTest < ActiveSupport::TestCase
      def user
        @user ||= User.create!(email: "dnr-#{SecureRandom.hex(3)}@example.com",
                               password: "correct horse battery staple", confirmed_at: Time.current)
      end

      def preview_for(node_id, attached: true)
        p = user.maker_previews.create!(node_id:, version_id: "v1", kind: "thumbnail", status: "ready")
        p.asset.attach(io: StringIO.new("PNGBYTES"), filename: "t.png", content_type: "image/png") if attached
        p
      end

      def node!(node_id, deleted:, tombstoned_at: Time.current)
        n = user.nodes.create!(node_id:, name: "#{node_id}.stl", kind: "file",
                               storage_path: "#{node_id}.stl", deleted:)
        n.update_columns(updated_at: tombstoned_at)
        n
      end

      # NO NODE ROW AT ALL means no way back. Both revive paths need the tombstone: the share
      # Reconciler's revive-by-path looks up `deleted: true` rows BY storage_path, and `undelete`
      # reconstructs from the tombstone. With no row, that node_id can never return — so there is
      # nothing to protect and no grace to serve.
      test "a preview whose node row does not exist at all is reaped immediately" do
        p = preview_for("vanished")

        assert_equal 1, Maker::Previews::DeadNodeReaper.reap_all!
        assert_not Maker::Preview.exists?(p.id)
      end

      # A TOMBSTONE IS NOT A DELETION — it is a deletion that can be taken back, and taking it back
      # returns the SAME node_id. Reaping inside the window turns an undo into a re-render.
      test "a tombstoned node's preview is spared inside the grace window" do
        node!("recent", deleted: true, tombstoned_at: 2.days.ago)
        p = preview_for("recent")

        assert_equal 0, Maker::Previews::DeadNodeReaper.reap_all!(grace: 30.days)
        assert Maker::Preview.exists?(p.id)
      end

      test "a tombstoned node's preview is reaped once the grace window has passed" do
        node!("ancient", deleted: true, tombstoned_at: 40.days.ago)
        p = preview_for("ancient")

        assert_equal 1, Maker::Previews::DeadNodeReaper.reap_all!(grace: 30.days)
        assert_not Maker::Preview.exists?(p.id)
      end

      # Belt and braces. The unique index makes a stale-version row impossible now, but a reaper
      # that could ever touch a LIVE node's preview would be deleting the thing the page renders.
      test "a live node's preview is never reaped, whatever its version" do
        node!("alive", deleted: false)
        p = preview_for("alive")

        assert_equal 0, Maker::Previews::DeadNodeReaper.reap_all!(grace: 0.seconds)
        assert Maker::Preview.exists?(p.id)
      end

      # Deleting the row without the blob would trade a database leak for a stored-file one, which
      # is the mistake this whole arc has been about.
      test "the blob is purged, not just the row" do
        p = preview_for("vanished2")
        blob_id = p.asset.blob.id

        Maker::Previews::DeadNodeReaper.reap_all!
        assert_not ActiveStorage::Blob.exists?(blob_id)
      end

      test "dry_run reports what it would reap and deletes nothing" do
        p = preview_for("vanished3")

        assert_equal 1, Maker::Previews::DeadNodeReaper.reap_all!(dry_run: true)
        assert Maker::Preview.exists?(p.id)
      end

      test "one user's previews are never reaped on another user's behalf" do
        other = User.create!(email: "dnr-other-#{SecureRandom.hex(3)}@example.com",
                             password: "correct horse battery staple", confirmed_at: Time.current)
        mine = preview_for("vanished4")
        theirs = other.maker_previews.create!(node_id: "vanished4", version_id: "v1",
                                              kind: "thumbnail", status: "ready")
        other.nodes.create!(node_id: "vanished4", name: "x.stl", kind: "file",
                            storage_path: "x.stl", deleted: false)

        assert_equal 1, Maker::Previews::DeadNodeReaper.reap!(user)
        assert_not Maker::Preview.exists?(mine.id)
        assert Maker::Preview.exists?(theirs.id), "the other user's node is live; their row stands"
      end
    end
  end
end
