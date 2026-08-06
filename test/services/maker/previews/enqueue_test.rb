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

      # THE SECOND STALENESS AXIS. `version_id` asks whether an artifact was made from the file's
      # current CONTENT; `renderer_revision` asks whether it was made by the current CODE. Only the
      # first existed, so when the .lbrn2 geometry thinning was fixed, every already-measured file
      # went on serving the old algorithm's output — its content had not changed and nothing else
      # was compared. Four had to be found and destroyed by hand on the live box.
      test "a renderer revision bump makes an otherwise current preview stale" do
        current = Maker::Previews::Enqueue.revision_for_name("design.lbrn2", "geometry")
        @user.maker_previews.create!(node_id: "n1", version_id: "v1", kind: "geometry",
                                     status: "ready", renderer_revision: current - 1)

        assert_enqueued_with(job: Maker::GeneratePreviewJob) do
          Maker::Previews::Enqueue.call(user: @user, node_id: "n1", name: "design.lbrn2",
                                        version_id: "v1", kind: "geometry")
        end
        row = @user.maker_previews.find_by!(node_id: "n1", kind: "geometry")
        assert_equal current, row.renderer_revision
        assert_equal "pending", row.status
      end

      test "a preview already at the current revision is left alone" do
        current = Maker::Previews::Enqueue.revision_for_name("design.lbrn2", "geometry")
        @user.maker_previews.create!(node_id: "n1", version_id: "v1", kind: "geometry",
                                     status: "ready", renderer_revision: current)

        assert_no_enqueued_jobs do
          Maker::Previews::Enqueue.call(user: @user, node_id: "n1", name: "design.lbrn2",
                                        version_id: "v1", kind: "geometry")
        end
      end

      # REVISIONS ARE PER KIND, and this is the assertion that keeps a geometry fix from becoming
      # an unannounced full-library rebuild. Lbrn2 renders both artifacts from one file; the live
      # share backend holds ~1400 thumbnails, and re-rendering all of them as a side effect of an
      # unrelated change would be an outage-shaped event, not a tidy-up.
      test "bumping the geometry revision does not invalidate a thumbnail" do
        assert_operator Maker::Previews::Enqueue.revision_for_name("design.lbrn2", "geometry"),
                        :>, Maker::Previews::Enqueue::BASE_REVISION,
                        "this proves nothing unless geometry has actually moved past the base"
        assert_equal Maker::Previews::Enqueue::BASE_REVISION,
                     Maker::Previews::Enqueue.revision_for_name("design.lbrn2", "thumbnail")

        @user.maker_previews.create!(node_id: "n1", version_id: "v1", kind: "thumbnail",
                                     status: "ready", renderer_revision: 1)
        assert_no_enqueued_jobs do
          Maker::Previews::Enqueue.call(user: @user, node_id: "n1", name: "design.lbrn2",
                                        version_id: "v1", kind: "thumbnail")
        end
      end

      # A renderer declaring no revision sits at the base — which is exactly what the migration
      # stamped every pre-existing row with, so installing this mechanism invalidated nothing.
      test "a renderer with no declared revision sits at the base" do
        assert_equal Maker::Previews::Enqueue::BASE_REVISION,
                     Maker::Previews::Enqueue.revision_for_name("part.stl", "thumbnail")

        @user.maker_previews.create!(node_id: "n1", version_id: "v1", kind: "thumbnail",
                                     status: "ready", renderer_revision: 1)
        assert_no_enqueued_jobs do
          Maker::Previews::Enqueue.call(user: @user, node_id: "n1", name: "part.stl", version_id: "v1")
        end
      end
    end
  end
end
