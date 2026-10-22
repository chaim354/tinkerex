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

      # Read from the renderer, never written as a literal: these fixtures must keep meaning the
      # same thing after the next revision bump, and a hard-coded 2 would quietly stop testing the
      # condition it names the day someone ships a 3.
      def current_revision(name) = Maker::Previews::Enqueue.revision_for_name(name, "thumbnail")

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

      # THE FIXTURE CARRIES THE RENDERER'S CURRENT REVISION, and it has to: this test is about the
      # CONTENT axis, and a row left at the column default is stale on the OTHER axis, so it would
      # be enqueued for a reason that has nothing to do with what is being asserted. It went red
      # the moment `.stl` first declared a revision — the mechanism working, not a regression.
      test "skips a file that already has a row for its current content" do
        fine = node!("fine.stl", "tok-cur")
        Maker::Preview.create!(user:, node_id: fine.node_id, version_id: token_for(fine),
                               kind: "thumbnail", status: "ready",
                               renderer_revision: current_revision("fine.stl"))

        assert_no_enqueued_jobs only: Maker::GeneratePreviewJob do
          assert_equal 0, Maker::Previews::MissingBackfill.call
        end
      end

      # --- the renderer-revision axis -------------------------------------------

      # THE GAP THIS SWEEP HAD. A row built by an OLDER build sits at the current content, so a
      # check keyed on (node_id, version_id) alone called it covered — while `ThumbnailMap` and
      # `current_thumbnail`, which DO compare revisions, treated the very same row as absent. Two
      # answers to one question, and the sweep held the wrong one: `rake previews:backfill_missing`
      # reported "Enqueued 0" over a library whose every STL thumbnail was drawn by the pre-Z-up
      # camera.
      test "enqueues a row built by an older renderer, at the current content" do
        stale = node!("old-build.stl", "tok-cur")
        Maker::Preview.create!(user:, node_id: stale.node_id, version_id: token_for(stale),
                               kind: "thumbnail", status: "ready", renderer_revision: 1)
        assert_operator current_revision("old-build.stl"), :>, 1,
                        "this fixture needs a renderer that has actually moved past revision 1"

        assert_enqueued_jobs 1, only: Maker::GeneratePreviewJob do
          assert_equal 1, Maker::Previews::MissingBackfill.call
        end
        assert_equal current_revision("old-build.stl"),
                     user.maker_previews.find_by!(node_id: stale.node_id).renderer_revision
      end

      # THE POPULATION `LbrnBackfill` USED TO SWEEP, PINNED HERE BECAUSE THAT SERVICE IS GONE.
      # It re-rendered `.lbrn`/`.lbrn2` thumbnail rows with `metadata: nil` — rows built before the
      # column existed — but it called `perform_later` WITHOUT repointing the row first, so the
      # job's `commit_if_current` captured the row's own current values and compared it to itself.
      # Revision-4 bytes landed on a row still claiming the 1 that migration 20260806120000 stamped,
      # every read path then correctly judged that row stale, and the grid showed a spinner over a
      # row that was `ready` and correct. `Enqueue` writes BOTH axes before enqueueing, which is
      # what makes the general sweep able to make the assertion the deleted path could not.
      #
      # Every such row sits at revision 1 against a renderer past it, so this sweep covers the whole
      # target population — and covers it on the CONDITION THAT WAS ACTUALLY MEANT. `metadata: nil`
      # was never that condition: `LbrnMetadata.parse` legitimately answers nil (`.compact.presence`,
      # and a blanket rescue), so a file that simply has nothing to report re-rendered on every run,
      # forever. Here it is swept once and then left alone — asserted by the second call.
      test "enqueues a lightburn row with no metadata, and repoints it, then leaves it alone" do
        lbrn = node!("design.lbrn2", "tok-cur")
        Maker::Preview.create!(user:, node_id: lbrn.node_id, version_id: token_for(lbrn),
                               kind: "thumbnail", status: "ready", renderer_revision: 1,
                               metadata: nil)
        assert_operator current_revision("design.lbrn2"), :>, 1,
                        "this fixture needs a renderer that has actually moved past revision 1"

        assert_enqueued_jobs 1, only: Maker::GeneratePreviewJob do
          assert_equal 1, Maker::Previews::MissingBackfill.call
        end
        # THE ASSERTION THE DELETED PATH COULD NOT MAKE. A job count alone is GREEN over the
        # revision mutation below (drop `enqueue.rb`'s `renderer_revision =` and only this line
        # catches it) — PROBED, not reasoned; it does red under the seen-key collapse, so "passes
        # over both mutations" would be false. A count was the whole of `lbrn_backfill_test.rb`,
        # which is why that sat green over this defect for as long as the service shipped.
        assert_equal current_revision("design.lbrn2"),
                     user.maker_previews.find_by!(node_id: lbrn.node_id).renderer_revision

        assert_no_enqueued_jobs only: Maker::GeneratePreviewJob do
          assert_equal 0, Maker::Previews::MissingBackfill.call
        end
      end

      # THE SWEEP AND THE READ PATH MUST GIVE THE SAME ANSWER. Asserted as an AGREEMENT
      # rather than by restating the columns, so the two cannot be "fixed" apart: whatever
      # `Enqueue` considers current is what this sweep must consider covered.
      test "what the sweep considers covered is exactly what Enqueue would not re-enqueue" do
        n = node!("agree.stl", "tok-cur")
        Maker::Preview.create!(user:, node_id: n.node_id, version_id: token_for(n),
                               kind: "thumbnail", status: "ready",
                               renderer_revision: current_revision("agree.stl"))

        # Enqueue leaves it alone...
        assert_no_enqueued_jobs only: Maker::GeneratePreviewJob do
          Maker::Previews::Enqueue.call(user:, node_id: n.node_id, name: n.name,
                                        version_id: token_for(n))
        end
        # ...and so does the sweep.
        assert_equal 0, Maker::Previews::MissingBackfill.call
      end

      # A ROW WHOSE JOB WAS LOST IS NOT COVERED, AND THE SWEEP ASKS THE PREDICATE THE READ DOORS ASK.
      # It compared a plucked (node_id, version_id, renderer_revision) triple, which a row wedged at
      # `processing` on current content matches exactly — so `rake previews:backfill_missing`
      # reported 0 over every wedged spinner. It now loads the batch's rows and asks
      # `Enqueue.needs_job?` with the read doors' policy: a stalled row is counted, one that only
      # just went in flight is believed, and a `failed` render is not retried from here either.
      # MUTATION: delete the stall line from `needs_job?` and the first count is 0.
      test "counts and heals a row whose job was lost, believes a fresh one, and leaves a failure alone" do
        lost  = node!("lost.stl", "tok-cur")
        fresh = node!("fresh.stl", "tok-cur")
        broke = node!("broke.stl", "tok-cur")
        row = travel_to(3.days.ago) do
          Maker::Preview.create!(user:, node_id: lost.node_id, version_id: token_for(lost), kind: "thumbnail",
                                 status: "processing", renderer_revision: current_revision("lost.stl"))
        end
        Maker::Preview.create!(user:, node_id: fresh.node_id, version_id: token_for(fresh), kind: "thumbnail",
                               status: "processing", renderer_revision: current_revision("fresh.stl"))
        Maker::Preview.create!(user:, node_id: broke.node_id, version_id: token_for(broke), kind: "thumbnail",
                               status: "failed", renderer_revision: current_revision("broke.stl"))

        assert_equal 1, Maker::Previews::MissingBackfill.call(dry_run: true)
        assert_enqueued_jobs 1, only: Maker::GeneratePreviewJob do
          assert_equal 1, Maker::Previews::MissingBackfill.call
        end
        assert_equal row.id, enqueued_jobs.last[:args].first, "the sweep healed the wrong row"
        assert_equal 0, Maker::Previews::MissingBackfill.call, "the heal did not restamp, so it repeats"
      end

      # `dry_run` COUNTS EXACTLY WHAT A REAL RUN WOULD DO, and both halves are asserted: a report
      # that enqueues is a bug, and a report whose number does not match the real run is worse than
      # no report — an operator uses it to decide whether to trigger a full-library re-render.
      test "dry_run reports the same number it would enqueue, and enqueues nothing" do
        3.times { |i| node!("m#{i}.stl", "tok-cur") }

        assert_no_enqueued_jobs only: Maker::GeneratePreviewJob do
          assert_equal 3, Maker::Previews::MissingBackfill.call(dry_run: true)
        end
        assert_equal 0, user.maker_previews.count, "a dry run must not create rows either"

        assert_enqueued_jobs 3, only: Maker::GeneratePreviewJob do
          assert_equal 3, Maker::Previews::MissingBackfill.call
        end
      end

      # A NAME NOTHING RENDERS MUST NOT BE COUNTED FOREVER. `revision_for_name` answers
      # BASE_REVISION for one, so a sweep that left the renderer check to Enqueue's nil return
      # would count it as stale on every run — a dry-run number that never reaches zero, on a
      # library where nothing is wrong.
      test "a non-renderable file is never counted, however many times the sweep runs" do
        node!("notes.xyzzy", "tok-cur")

        assert_equal 0, Maker::Previews::MissingBackfill.call(dry_run: true)
        assert_equal 0, Maker::Previews::MissingBackfill.call
        assert_equal 0, Maker::Previews::MissingBackfill.call(dry_run: true)
      end

      # Idempotence across the revision axis: the first run clears the backlog, the second finds
      # nothing. Without it a bumped revision would re-enqueue the whole library on every run.
      test "a second run after a revision bump enqueues nothing" do
        n = node!("once.stl", "tok-cur")
        Maker::Preview.create!(user:, node_id: n.node_id, version_id: token_for(n),
                               kind: "thumbnail", status: "ready", renderer_revision: 1)

        assert_equal 1, Maker::Previews::MissingBackfill.call
        assert_equal 0, Maker::Previews::MissingBackfill.call
      end

      # An `unsupported` row IS a row for the current content, so this sweep leaves it alone —
      # deliberately. Clearing those is the separate, still-open F3D sweep (the record, CLAUDE.md §11); doing
      # it here would silently merge two migrations with different correctness arguments.
      #
      # AT THE CURRENT REVISION, stated rather than defaulted: this is a claim about the CONTENT
      # axis, and the column default (1) silently stopped being current the day Mesh declared a
      # revision (2 — ink on paper, 2026-10-21). An `unsupported` row an older build wrote IS stale
      # on the code axis and re-enqueues, by design — that is how F3D's re-render reaches them.
      test "leaves an unsupported row for the current content alone" do
        n = node!("part.step", "tok-cur")
        Maker::Preview.create!(user:, node_id: n.node_id, version_id: token_for(n),
                               kind: "thumbnail", status: "unsupported",
                               renderer_revision: current_revision("part.step"))

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
