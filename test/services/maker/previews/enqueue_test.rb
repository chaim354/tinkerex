require "test_helper"

module Maker
  module Previews
    class EnqueueTest < ActiveSupport::TestCase
      include ActiveJob::TestHelper

      setup { @user = User.create!(email: "enq@example.com") }

      # A `ready` thumbnail of part.stl with a picture attached, at this build's revision unless told
      # otherwise — the shape a row has once a render (or the maker's viewer capture) has landed.
      def ready_thumbnail!(source: "renderer", version_id: "v1",
                           renderer_revision: Enqueue.revision_for_name("part.stl", "thumbnail"))
        row = @user.maker_previews.create!(node_id: "n1", version_id:, kind: "thumbnail", status: "ready",
                                           source:, renderer_revision:)
        row.asset.attach(io: StringIO.new("\x89PNG chosen".b), filename: "t.png", content_type: "image/png")
        row
      end

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
        row = @user.maker_previews.create!(node_id: "n1", version_id: "v1", kind: "geometry",
                                           status: "ready", renderer_revision: current - 1)
        row.asset.attach(io: StringIO.new("{}"), filename: "g.json", content_type: "application/json")

        assert_enqueued_with(job: Maker::GeneratePreviewJob) do
          Maker::Previews::Enqueue.call(user: @user, node_id: "n1", name: "design.lbrn2",
                                        version_id: "v1", kind: "geometry")
        end
        row.reload
        assert_equal current, row.renderer_revision
        # A RENDERER-ONLY REBUILD IS `rebuilding` (F-S08-2), WHICH IS TWO TRUE THINGS AT ONCE: the
        # artifact still depicts this exact file, so a picture surface keeps showing it; and it is
        # not the build its coordinates now name, so a surface that MEASURES from it refuses it.
        # It used to stay `ready`, which said only the first — and the Measure poll then served
        # the older build's payload as current until the job ran.
        assert_equal "rebuilding", row.status
        assert row.showable?, "a renderer rebuild must not blank an artifact that is still of this file"
        assert_not row.current_build?, "an older build's artifact must not read as the current build"
        assert row.in_flight?, "a rebuild is a job believed coming, which the stall window verifies"
      end

      # THE OTHER HALF OF THE RULE: `rebuilding` is for a row that HAS a picture to keep. Anything
      # else a renderer bump finds has nothing on screen worth protecting, so it goes `pending`
      # like any other row that is waiting for a job — `unsupported` included, which used to keep
      # claiming "no renderer here" through the very render that might prove otherwise.
      test "a renderer bump on a row with no picture to keep goes pending" do
        current = Maker::Previews::Enqueue.revision_for_name("part.stl", "thumbnail")
        { "n-unsupported" => "unsupported", "n-no-asset" => "ready", "n-busy" => "processing" }.each do |node_id, status|
          @user.maker_previews.create!(node_id:, version_id: "v1", kind: "thumbnail", status:,
                                       renderer_revision: current - 1)
          Maker::Previews::Enqueue.call(user: @user, node_id:, name: "part.stl", version_id: "v1")

          assert_equal "pending", @user.maker_previews.find_by!(node_id:).status, "#{status} with no picture"
        end
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
      # only just went pending is believed. `ThumbnailMap`'s backfill asks this (as `needs_job?`) of
      # every row on every Files page load, so a window-less "re-enqueue any pending" would enqueue a
      # duplicate job for every spinner on screen, every render.
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

      # A REBUILD WHOSE JOB WAS LOST IS HEALED LIKE ANY OTHER IN-FLIGHT ROW, AND KEEPS ITS PICTURE.
      # `ready` was never in the stall set, so a renderer rebuild whose job vanished used to show
      # the older build for good, with nothing anywhere to say a newer one was owed. The heal
      # changes nothing but the job and the stamp: a lost rebuild is still a rebuild.
      test "a rebuilding row stalled past the window is re-enqueued and still shows its picture" do
        row = @user.maker_previews.create!(node_id: "n1", version_id: "v1", kind: "thumbnail",
                                           status: "rebuilding",
                                           renderer_revision: Enqueue.revision_for_name("part.stl", "thumbnail"))
        row.asset.attach(io: StringIO.new("PNG"), filename: "t.png", content_type: "image/png")
        # AGED AFTER THE ATTACH, which touches the row: aged first, the attach would leave it fresh
        # and the test would fail for a reason that has nothing to do with the heal.
        row.update_column(:updated_at, 3.days.ago)

        assert_enqueued_with(job: Maker::GeneratePreviewJob) do
          Maker::Previews::Enqueue.call(user: @user, node_id: "n1", name: "part.stl", version_id: "v1")
        end
        row.reload
        assert_equal "rebuilding", row.status, "the heal blanked a picture that is still of this file"
        assert_operator row.updated_at, :>, 1.minute.ago, "the heal did not restamp the row"
      end

      # THE TRANSITION TABLE, ASKED DIRECTLY: `needs_job?` is the one answer `call` and every door
      # that already holds a row give to "does this row need a job?". Every arm is a row a door
      # really meets, and `retry_failed:` is the one place the two policies differ — the eager seams
      # retry a failed render (`call`'s default), the read doors never do.
      test "needs_job? answers a missing row, moved coordinates, a stall, and a failure only on request" do
        rev = Enqueue.revision_for_name("part.stl", "thumbnail")
        row = lambda do |status, version_id: "v1", revision: rev, at: Time.current|
          travel_to(at) do
            @user.maker_previews.create!(node_id: "n-#{SecureRandom.hex(4)}", kind: "thumbnail",
                                         version_id:, status:, renderer_revision: revision)
          end
        end
        ask = lambda do |preview, retry_failed: false|
          Enqueue.needs_job?(preview, version_id: "v1", revision: rev, retry_failed:)
        end

        assert ask.call(nil), "no row at all"
        assert ask.call(@user.maker_previews.new(node_id: "n-new", kind: "thumbnail")), "a row never saved"
        assert ask.call(row.call("ready", version_id: "v0")), "the content moved"
        assert ask.call(row.call("ready", revision: rev + 1)), "the renderer moved"
        assert_not ask.call(row.call("ready")), "current and done"
        assert_not ask.call(row.call("unsupported")), "terminal by design"

        failed = row.call("failed")
        assert_not ask.call(failed), "a read door retried a failed render"
        assert ask.call(failed, retry_failed: true), "an eager seam did not retry a failed render"

        # NAMED HERE, NOT READ FROM `Maker::Preview::IN_FLIGHT`: iterating the constant would let a
        # status dropped from it drop out of this assertion too.
        %w[pending processing rebuilding].each do |status|
          assert_not ask.call(row.call(status)), "#{status} inside the window: its job is believed"
          assert ask.call(row.call(status, at: (Enqueue::STALLED_AFTER + 1.minute).ago)),
                 "#{status} past STALLED_AFTER: nothing verifies the job is still coming"
        end
      end

      # THE SAME POLICY THROUGH `call`, for a caller that holds no row: `retry_failed: false` leaves a
      # current failed render alone, where the default ("re-enqueues a previously failed preview",
      # above) retries it.
      test "call with retry_failed: false leaves a failed render alone" do
        @user.maker_previews.create!(node_id: "n1", version_id: "v1", kind: "thumbnail", status: "failed",
                                     renderer_revision: Enqueue.revision_for_name("part.stl", "thumbnail"))
        assert_no_enqueued_jobs do
          Maker::Previews::Enqueue.call(user: @user, node_id: "n1", name: "part.stl", version_id: "v1",
                                        retry_failed: false)
        end
        assert_equal "failed", @user.maker_previews.find_by!(node_id: "n1").status
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

      # A VIEWER PREVIEW IS CURRENT WHILE ITS CONTENT IS (2026-10-20): a renderer upgrade must not
      # repaint the angle the maker chose.
      test "a viewer preview survives a renderer revision bump" do
        row = ready_thumbnail!(source: "viewer", renderer_revision: 0) # 0: older than any real revision
        assert_no_enqueued_jobs only: Maker::GeneratePreviewJob do
          Maker::Previews::Enqueue.call(user: @user, node_id: row.node_id, name: "part.stl",
                                        version_id: row.version_id)
        end
        row.reload
        assert_equal [ "viewer", "ready" ], [ row.source, row.status ]
      end

      test "a viewer preview of old content goes back to the renderer" do
        row = ready_thumbnail!(source: "viewer")
        assert_enqueued_jobs 1, only: Maker::GeneratePreviewJob do
          Maker::Previews::Enqueue.call(user: @user, node_id: row.node_id, name: "part.stl",
                                        version_id: "new-content")
        end
        row.reload
        assert_equal [ "renderer", "pending", "new-content" ], [ row.source, row.status, row.version_id ]
      end

      test "a viewer preview is current whatever its renderer revision" do
        row = ready_thumbnail!(source: "viewer", renderer_revision: 0)
        assert_equal row, Maker::Previews::Enqueue.current_preview(user: @user, node_id: row.node_id,
                                                                    name: "part.stl", version_id: row.version_id,
                                                                    kind: "thumbnail")
        assert Maker::Previews::Enqueue.current_preview?(row, name: "part.stl", version_id: row.version_id)
      end

      # A VERSION-LESS ASK IS NOT A CONTENT CHANGE (found in review): the v1 previews API forwards a
      # POST that names no `version_id` as nil, and nil != "v1" used to repoint the maker's picture.
      test "a request that names no content leaves a viewer preview alone" do
        row = ready_thumbnail!(source: "viewer")
        assert_no_enqueued_jobs only: Maker::GeneratePreviewJob do
          Maker::Previews::Enqueue.call(user: @user, node_id: row.node_id, name: "part.stl", version_id: nil)
        end
        row.reload
        assert_equal [ "viewer", "ready", "v1" ], [ row.source, row.status, row.version_id ]
      end
    end
  end
end
