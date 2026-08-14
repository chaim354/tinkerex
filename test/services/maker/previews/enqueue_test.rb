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

      # THE FIXTURE CARRIES THE RENDERER'S CURRENT REVISION, and it has to: this test is about the
      # CONTENT axis (same node, same version -> no rebuild), and a row left at the column default
      # would be stale on the OTHER axis, so it re-enqueues for a reason that has nothing to do with
      # what is being asserted. It went red the moment `.stl` first declared a revision — the
      # mechanism working, not a regression.
      test "is idempotent: re-enqueuing a ready (node, version) does not enqueue again" do
        p = @user.maker_previews.create!(node_id: "n1", version_id: "v1", kind: "thumbnail",
                                         status: "ready",
                                         renderer_revision: Enqueue.revision_for_name("part.stl", "thumbnail"))
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
        # STATUS IS LEFT ALONE on a renderer-only rebuild — the artifact still depicts this exact
        # file, and blanking it strands a spinner on the (non-polling) file page. Consumers that
        # cannot tolerate an older build's output say so themselves: FilesController#geometry
        # answers "pending" whenever it had to enqueue, without reading this status at all.
        assert_equal "ready", row.status,
                     "a renderer rebuild must not blank an artifact that is still of this file"
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

      # REVISIONS ARE PER KIND, and this is what keeps a fix to one artifact from becoming an
      # unannounced rebuild of another. Lbrn2 renders both a thumbnail and a geometry payload from
      # one file, and they must be able to move independently.
      #
      # ASSERTED THROUGH A STAND-IN RENDERER RATHER THAN AGAINST Lbrn2's OWN NUMBERS, and the
      # reason is worth stating because the obvious version of this test is worthless right now:
      # Lbrn2's two revisions BOTH happen to be 2, so code that ignored `kind` entirely and
      # returned one revision for both would satisfy every value-based assertion. A double whose
      # two kinds differ is the only thing that can tell dispatch from coincidence.
      test "revision_for asks the renderer for the specific kind" do
        two_kinds = Class.new do
          def self.payload_revision(kind) = kind == "geometry" ? 7 : 3
        end

        assert_equal 7, Maker::Previews::Enqueue.revision_for(two_kinds, "geometry")
        assert_equal 3, Maker::Previews::Enqueue.revision_for(two_kinds, "thumbnail")
      end

      # And the consequence at the door: a thumbnail already at ITS revision is left alone, whatever
      # geometry's happens to be.
      test "a thumbnail at its own current revision is not re-enqueued" do
        thumb = Maker::Previews::Enqueue.revision_for_name("design.lbrn2", "thumbnail")
        @user.maker_previews.create!(node_id: "n1", version_id: "v1", kind: "thumbnail",
                                     status: "ready", renderer_revision: thumb)
        assert_no_enqueued_jobs do
          Maker::Previews::Enqueue.call(user: @user, node_id: "n1", name: "design.lbrn2",
                                        version_id: "v1", kind: "thumbnail")
        end
      end

      # A renderer declaring no revision sits at the base — which is exactly what the migration
      # stamped every pre-existing row with, so installing this mechanism invalidated nothing.
      #
      # `.obj` (Mesh), NOT `.stl`: this test named a real extension, and the extension it named
      # acquired a revision when the STL camera was fixed — at which point the test failed for the
      # right reason and had to move rather than be relaxed. If Mesh ever declares one too, MOVE THE
      # FIXTURE AGAIN to whatever still declares nothing (Pdf, ImageThumb, TextThumb); do not delete
      # the assertion, because "silence means BASE_REVISION" is what makes a renderer's cache
      # invalidate only when someone deliberately says so.
      test "a renderer with no declared revision sits at the base" do
        assert_not Maker::Previews::Mesh.respond_to?(:payload_revision),
                   "this fixture needs a renderer that declares NOTHING — pick another one"
        assert_equal Maker::Previews::Enqueue::BASE_REVISION,
                     Maker::Previews::Enqueue.revision_for_name("part.obj", "thumbnail")

        @user.maker_previews.create!(node_id: "n1", version_id: "v1", kind: "thumbnail",
                                     status: "ready", renderer_revision: 1)
        assert_no_enqueued_jobs do
          Maker::Previews::Enqueue.call(user: @user, node_id: "n1", name: "part.obj", version_id: "v1")
        end
      end

      # THE ROW AND THE JOB ARE IN DIFFERENT DATABASES, so `perform_later` is NOT covered by the
      # caller's transaction: it commits to the QUEUE database immediately while `preview.save!` is
      # still uncommitted on PRIMARY. Every addon save runs inside one
      # (`Tools::AddonsController#create`'s `ApplicationRecord.transaction`), Solid Queue runs in
      # the Puma process on this deployment (SOLID_QUEUE_IN_PUMA) and polls sub-second, so the
      # worker claimed the job, could not see the row, and `discard_on RecordNotFound` swallowed it
      # — no failure, no log, job marked finished.
      #
      # NOT THEORETICAL. On the deployed share library, job 15583 was created AND finished at
      # 2026-08-13 23:09:20 while preview 1747 ("history-test.svg") was never touched — its
      # created_at still equalled its updated_at days later, and the file span forever.
      test "the job is not enqueued until the caller's transaction has committed" do
        ApplicationRecord.transaction do
          Maker::Previews::Enqueue.call(user: @user, node_id: "n1", name: "part.stl", version_id: "v1")
          assert_equal 0, enqueued_jobs.size,
                       "the worker could see the job before its preview row committed"
        end
        assert_equal 1, enqueued_jobs.size, "and it must still be enqueued once the transaction commits"
      end

      # A `pending` ROW ASSERTS "A JOB IS COMING FOR ME", AND NOTHING VERIFIES THAT ASSERTION. When
      # it is false the row is unrecoverable: every other branch of the guard above returns early,
      # so the 15-minute scan, the Files-page backfill, #show and the addon door all no-op on it
      # forever while the grid spins until its poll gives up. `failed` re-enqueues, `ready` is done
      # and `unsupported` is terminal by design — `pending` was the one status with no way back.
      #
      # Three rows were wedged this way on the live share library (2026-08-05, 08-13 and 08-13),
      # the oldest for over a week.
      test "a pending row whose job never ran is re-enqueued rather than wedged forever" do
        travel_to 3.days.ago do
          Maker::Previews::Enqueue.call(user: @user, node_id: "n1", name: "part.stl", version_id: "v1")
        end
        clear_enqueued_jobs # the job was discarded; the row still says pending

        assert_enqueued_with(job: Maker::GeneratePreviewJob) do
          Maker::Previews::Enqueue.call(user: @user, node_id: "n1", name: "part.stl", version_id: "v1")
        end
      end

      # THE OTHER HALF, and the one that keeps the recovery from becoming a stampede: a row that
      # only just went pending is believed. `backfill_thumbnails` calls this once per row on every
      # Files page load, so a window-less "re-enqueue any pending" would enqueue a duplicate job
      # for every spinner on screen, every render.
      test "a freshly pending row is left alone — its job really is still coming" do
        Maker::Previews::Enqueue.call(user: @user, node_id: "n1", name: "part.stl", version_id: "v1")
        clear_enqueued_jobs

        assert_no_enqueued_jobs do
          Maker::Previews::Enqueue.call(user: @user, node_id: "n1", name: "part.stl", version_id: "v1")
        end
      end

      # `processing` NEEDS THE SAME ESCAPE, and GeneratePreviewJob's own comment already promised
      # it: a FetchError that exhausts its retries deliberately leaves the row non-terminal "so a
      # later manual/scheduled re-enqueue can still succeed". There was no such re-enqueue — this
      # guard returned early on `processing` too, so that sentence described something that could
      # not happen.
      test "a processing row stalled past the window is re-enqueued too" do
        travel_to 3.days.ago do
          @user.maker_previews.create!(node_id: "n1", version_id: "v1", kind: "thumbnail",
                                       status: "processing",
                                       renderer_revision: Enqueue.revision_for_name("part.stl", "thumbnail"))
        end

        assert_enqueued_with(job: Maker::GeneratePreviewJob) do
          Maker::Previews::Enqueue.call(user: @user, node_id: "n1", name: "part.stl", version_id: "v1")
        end
      end

      # THE RESTAMP IS LOAD-BEARING AND IS THE EASIEST HALF TO LEAVE OUT. Healing a stalled row
      # changes no other attribute, and `save!` on an unchanged record is a NO-OP that does not
      # touch `updated_at` — so without an explicit restamp the row stays stale forever and every
      # caller after it enqueues yet another duplicate, on every scan and every page load.
      test "healing a stalled row restamps it, so the next caller does not enqueue again" do
        travel_to 3.days.ago do
          Maker::Previews::Enqueue.call(user: @user, node_id: "n1", name: "part.stl", version_id: "v1")
        end
        Maker::Previews::Enqueue.call(user: @user, node_id: "n1", name: "part.stl", version_id: "v1")
        clear_enqueued_jobs

        assert_no_enqueued_jobs do
          Maker::Previews::Enqueue.call(user: @user, node_id: "n1", name: "part.stl", version_id: "v1")
        end
      end
    end
  end
end
