require "test_helper"

module Maker
  module Previews
    # The repair half of the save bug (Library::Reconciler#match_live_paths is the source half).
    # Every assertion reads the CURRENT content token back out of the port rather than assuming
    # how a backend computes one — chunk answers `current_version_id` and share/s3 answer
    # `content_hash` — so these run identically on all three legs.
    class MissingBackfillTest < ActiveJob::TestCase
      def user
        @user ||= User.create!(email: "mbf@example.com", password: "correct horse battery staple",
                               confirmed_at: Time.current)
      end

      # Both identity columns are set to the same value so the node has a well-defined token
      # whichever adapter is current.
      def node!(name, token)
        user.nodes.create!(node_id: "node-#{name}", name:, kind: "file", storage_path: name,
                           content_hash: token, current_version_id: token, size: 3, mtime: 1)
      end

      def token_for(node)
        FileLayer.current.stat_all(user, node_ids: [ node.node_id ]).fetch(node.node_id).content_token
      end

      test "enqueues for a file whose CURRENT content has no preview row" do
        saved = node!("saved.stl", "tok-new")
        # The bug's fingerprint: a row keyed to content this file no longer holds.
        Maker::Preview.create!(user:, node_id: saved.node_id, version_id: "tok-old",
                               kind: "thumbnail", status: "ready")

        assert_enqueued_jobs 1, only: Maker::GeneratePreviewJob do
          assert_equal 1, Maker::Previews::MissingBackfill.call
        end
        assert user.maker_previews.exists?(node_id: saved.node_id, kind: "thumbnail",
                                           version_id: token_for(saved))
      end

      test "skips a file that already has a row for its current content" do
        fine = node!("fine.stl", "tok-cur")
        Maker::Preview.create!(user:, node_id: fine.node_id, version_id: token_for(fine),
                               kind: "thumbnail", status: "ready")

        assert_no_enqueued_jobs only: Maker::GeneratePreviewJob do
          assert_equal 0, Maker::Previews::MissingBackfill.call
        end
      end

      # An `unsupported` row IS a row for the current content, so this sweep leaves it alone —
      # deliberately. Clearing those is the separate, still-open F3D sweep (docs/STATUS.md); doing
      # it here would silently merge two migrations with different correctness arguments.
      test "leaves an unsupported row for the current content alone" do
        n = node!("part.step", "tok-cur")
        Maker::Preview.create!(user:, node_id: n.node_id, version_id: token_for(n),
                               kind: "thumbnail", status: "unsupported")

        assert_no_enqueued_jobs only: Maker::GeneratePreviewJob do
          assert_equal 0, Maker::Previews::MissingBackfill.call
        end
      end

      # The tombstone half passes because `stat_all` omits a deleted node entirely (an absent key,
      # never a raise — the port's contract), so the sweep sees no token for it. Mutation-checked:
      # dropping the sweep's own `present` scope leaves this GREEN, which is why that scope is
      # written as a way to not load tombstones into the batch and NOT as the thing keeping a
      # deleted file from sprouting previews.
      test "skips a name no renderer claims, and a tombstoned node" do
        node!("notes.xyzzy", "tok-cur")
        node!("gone.stl", "tok-cur").update!(deleted: true)

        assert_no_enqueued_jobs only: Maker::GeneratePreviewJob do
          assert_equal 0, Maker::Previews::MissingBackfill.call
        end
      end
    end
  end
end
