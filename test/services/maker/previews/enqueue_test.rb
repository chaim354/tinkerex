require "test_helper"

module Maker
  module Previews
    class EnqueueTest < ActiveSupport::TestCase
      include ActiveJob::TestHelper

      setup { @user = User.create!(email: "enq@example.com") }

      test "creates a pending thumbnail preview and enqueues the job" do
        assert_enqueued_with(job: Maker::GeneratePreviewJob) do
          Maker::Previews::Enqueue.call(user: @user, node_id: "n1", name: "part.stl", version_id: "v1")
        end
        p = @user.maker_previews.find_by(node_id: "n1", version_id: "v1", kind: "thumbnail")
        assert_equal "pending", p.status
      end

      test "is idempotent: re-enqueuing a ready (node, version) does not enqueue again" do
        p = @user.maker_previews.create!(node_id: "n1", version_id: "v1", kind: "thumbnail", status: "ready")
        assert_no_enqueued_jobs do
          result = Maker::Previews::Enqueue.call(user: @user, node_id: "n1", name: "part.stl", version_id: "v1")
          assert_equal p.id, result.id
        end
      end

      test "re-enqueues a previously failed preview" do
        @user.maker_previews.create!(node_id: "n1", version_id: "v1", kind: "thumbnail", status: "failed")
        assert_enqueued_with(job: Maker::GeneratePreviewJob) do
          Maker::Previews::Enqueue.call(user: @user, node_id: "n1", name: "part.stl", version_id: "v1")
        end
      end

      # A NEW VERSION REPOINTS THE ONE ROW; it does not mint a second. The old shape keyed rows by
      # (node, VERSION, kind), so every save stranded its predecessor — nothing reads a superseded
      # preview (every surface resolves by the node's current content_token) and nothing deleted
      # one either. 160 of 1334 rows on the deployed share library were orphans that way.
      test "a new version REPOINTS the single row rather than minting a second" do
        p = @user.maker_previews.create!(node_id: "n1", version_id: "v1", kind: "thumbnail", status: "ready")
        assert_enqueued_with(job: Maker::GeneratePreviewJob) do
          Maker::Previews::Enqueue.call(user: @user, node_id: "n1", name: "part.stl", version_id: "v2")
        end
        assert_equal 1, @user.maker_previews.where(node_id: "n1", kind: "thumbnail").count,
                     "one row per (node, kind) — a save must not leak its predecessor"
        p.reload
        assert_equal "v2", p.version_id
        assert_equal "pending", p.status, "the stale render must not read as ready for the new content"
      end

      # Different KINDS still coexist: the key is (node, kind), and `model_glb` is a different
      # artefact from `thumbnail`, not a newer one.
      test "a second kind gets its own row" do
        Maker::Previews::Enqueue.call(user: @user, node_id: "n1", name: "part.stl", version_id: "v1")
        Maker::Previews::Enqueue.call(user: @user, node_id: "n1", name: "part.stl", version_id: "v1",
                                      kind: "model_glb")
        assert_equal 2, @user.maker_previews.where(node_id: "n1").count
      end

      test "does nothing for a name with no registered renderer" do
        assert_no_enqueued_jobs do
          result = Maker::Previews::Enqueue.call(user: @user, node_id: "n1", name: "part.sldprt", version_id: "v1")
          assert_nil result
        end
        assert_not @user.maker_previews.exists?(node_id: "n1")
      end
    end
  end
end
