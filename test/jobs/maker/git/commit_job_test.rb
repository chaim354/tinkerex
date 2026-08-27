require "test_helper"

module Maker
  module Git
    # THE LOOP AROUND Maker::Git::ProjectCommit, its audit trail, and the scheduled fan-out. The
    # per-project pass has its own suite (test/services/maker/git/project_commit_test.rb); what is
    # asserted here is only what the JOB adds — which projects it visits, what survives a failure,
    # what an operator can read afterwards, and when the schedule declines.
    #
    # THE BACKEND IS PINNED, NEVER AMBIENT, for project_commit_test.rb's measured reason: the pass
    # resolves FileLayer.current itself, so an ambient adapter aims a real S3 client at config/ci.rb's
    # stub bucket on the `test-s3` leg and writes a `Projects/` tree into the repo root on the `test`
    # leg. `use_fresh_share_library!` owns the teardown of the root it mints.
    class CommitJobTest < ActiveSupport::TestCase
      include ActiveJob::TestHelper

      setup do
        @root = use_fresh_share_library!
        @user = User.create!(email: "gcj-#{SecureRandom.hex(4)}@example.com")
        @project = project!("Desk Lamp")
      end

      teardown { FileLayer.reset! }

      # ---- the pass itself ---------------------------------------------------------------------

      # #perform HAS NO BACKEND GATE — the house rule Library::ScanJob states: a `return unless`
      # there would make an operator's explicit run silently do nothing. Share is scannable, so a
      # gated #perform would commit nothing here.
      test "perform commits a settled file on a scannable backend, because only the schedule is gated" do
        travel_to(3.days.ago) { file!("notes.md", content: "hello\n") }

        assert_equal 1, Maker::Git::CommitJob.perform_now(user_id: @user.id)

        repo = Maker::Git::Repo.for(@project)
        assert_equal "hello\n", repo.blob_at(oid: repo.head_oid, path: "notes.md")
      end

      # `scan_started_at` IS THE SETTLE ANCHOR AND THE CALLER OWNS IT. Library::ScanJob passes its
      # own, captured before its observer ran; a pass handed an anchor OLDER than the row commits
      # nothing, which is what keeps a file still being written out of the history.
      #
      # THREE DAYS, NOT THREE SECONDS (§15): two events in the same second make a timestamp
      # comparison a guard that usually cannot fail.
      test "a node touched since the anchor is not committed" do
        file!("notes.md", content: "hello\n") # written now...

        assert_equal 0, Maker::Git::CommitJob.perform_now(user_id: @user.id,
                                                          scan_started_at: 3.days.ago)
        assert_nil Maker::GitRepo.find_by(project: @project)
      end

      # A project with no library folder has nothing beneath it to commit — every committed path is
      # derived from that folder's own storage_path. The pass would decline too (it resolves the
      # folder first and yields Node.none), so what this pins is that the LOOP does not ask: the
      # same filter, in the same spelling, as Maker::ProjectIntake.for_user's.
      test "a project with no library folder is skipped, and does not stop the others" do
        @user.maker_projects.create!(name: "Sketchbook") # no ensure_library_folder!
        travel_to(3.days.ago) { file!("notes.md", content: "hello\n") }

        assert_equal 1, Maker::Git::CommitJob.perform_now(user_id: @user.id)
        assert_equal [ @project.id ], Maker::GitRepo.pluck(:project_id)
      end

      # ---- one bad project must not stall the rest ---------------------------------------------

      # A PROJECT WHOSE BYTES ARE BRIEFLY UNREACHABLE IS ORDINARY ON A NAS. Letting it raise would
      # leave every project AFTER it in this loop uncommitted, with nothing anywhere saying why —
      # so the rescue is per project, never around the loop.
      #
      # THE FAILING PROJECT IS THE ONE WITH THE LOWER ID, DELIBERATELY: find_each walks in id order,
      # so a rescue that merely returned early would still leave this green if the good project ran
      # first. @project comes from setup, so it is that one.
      test "one project's failure does not stall the projects after it, and is written down" do
        later = project!("Later")
        travel_to(3.days.ago) do
          file!("bad.md", content: "b\n")
          file!("notes.md", project: later, content: "hello\n")
        end

        log = capture_log do
          failing_pass(->(project) { project.id == @project.id }) do
            assert_equal 1, Maker::Git::CommitJob.perform_now(user_id: @user.id),
                         "the project after the failure must still be committed"
          end
        end

        assert Maker::GitRepo.find_by(project: later)&.head_oid,
               "the later project committed even though an earlier one raised"
        assert_nil Maker::GitRepo.find_by(project: @project)
        assert_match(/project #{@project.slug} \(#{@project.id}\) failed for user #{@user.id}: RuntimeError: unreachable/,
                     log, "the swallowed failure must name the project AND the exception")
      end

      # ---- the audit trail ---------------------------------------------------------------------

      # A RUN THAT COMMITTED NOTHING AND A RUN THAT FAILED ON EVERY PROJECT ARE DIFFERENT EVENTS.
      # This half: a quiet library runs this every 15 minutes forever, so silence is the right
      # answer — Maker::ProjectIntakeJob#report's rule, or the log fills with rows of zeroes.
      # THE STEADY STATE IS A PROJECT WITH NOTHING NEW UNDER IT, not a file held back by the anchor
      # — that case is the test above and it is a different event. This is the one that repeats
      # every fifteen minutes for the life of the deployment.
      test "a run that commits nothing says nothing" do
        log = capture_log { Maker::Git::CommitJob.perform_now(user_id: @user.id) }

        assert_no_match(/committed/, log)
        assert_no_match(/FAILED/, log)
      end

      # THE OTHER HALF, and the pair IS the requirement: silence must not be what a total failure
      # looks like. The WARN carries the DENOMINATOR — with a hundred projects, a hundred error
      # lines still do not say whether anything got committed.
      test "a run that failed on every project is loud, and says how many" do
        second = project!("Also Broken")
        travel_to(3.days.ago) do
          file!("notes.md", content: "hello\n")
          file!("notes.md", project: second, content: "hello\n")
        end

        log = capture_log do
          failing_pass(->(_project) { true }) do
            assert_equal 0, Maker::Git::CommitJob.perform_now(user_id: @user.id)
          end
        end

        assert_match(/committed 0 of 2 projects — 2 FAILED/, log)
        assert_equal 2, log.scan(/RuntimeError: unreachable/).size,
                     "each failure gets its own line; the summary is not a substitute for them"
      end

      # ---- the schedule ------------------------------------------------------------------------

      # THE GATE IS ON THE FAN-OUT AND IT MUST LIVE IN THE CLASS, NOT IN recurring.yml: Solid Queue
      # resolves `class:` at load and reads ONE file with no merge mechanism, which is why every
      # gated entry there uses `command:`.
      #
      # ON A SCANNED BACKEND Library::ScanJob IS ALREADY THE CALLER, at the end of its own perform
      # and strictly AFTER the project intake. A second, unsequenced caller would commit files the
      # intake is about to move — and git keeps whatever it was told, so that history is wrong
      # permanently rather than until the next pass.
      test "commit_all! declines on a scannable backend" do
        assert_no_enqueued_jobs(only: Maker::Git::CommitJob) { Maker::Git::CommitJob.commit_all! }
      end

      # THE POSITIVE HALF, and it is not optional: on its own the test above passes for a
      # `def commit_all!; end`.
      test "commit_all! enqueues on a non-scannable backend" do
        FileLayer.current = FileLayer::ChunkRemote.new

        assert_enqueued_with(job: Maker::Git::CommitJob, args: [ { user_id: @user.id } ]) do
          Maker::Git::CommitJob.commit_all!
        end
      end

      # The user can be deleted between the fan-out and this running. Nothing to commit and nothing
      # wrong (GeneratePreviewJob sets the precedent).
      test "a missing user is discarded, not failed" do
        assert_nothing_raised do
          perform_enqueued_jobs { Maker::Git::CommitJob.perform_later(user_id: 999_999_999) }
        end
      end

      private

      def project!(name)
        project = @user.maker_projects.create!(name:)
        project.ensure_library_folder!(@user)
        project.reload
      end

      # A ROW **PLUS THE FILE IT CLAIMS TO BE** — on share a read resolves through storage_path and
      # opens an actual file, so a bare nodes.create! is a node whose bytes were never there (§14a).
      def file!(name, project: nil, content: "x\n")
        project ||= @project
        folder = @user.nodes.find_by!(node_id: project.folder_node_id)
        rel = File.join(folder.storage_path, name)
        path = @root.join(rel)
        path.dirname.mkpath
        path.binwrite(content)
        @user.nodes.create!(node_id: SecureRandom.uuid, name:, kind: "file",
                            parent_node_id: folder.node_id, storage_path: rel,
                            size: content.bytesize,
                            content_hash: "sha256:#{Digest::SHA256.hexdigest(content)}")
      end

      # Hand-rolled override with an ensure-restore — generate_preview_job_test.rb's
      # forcing_available idiom, and the ensure is load-bearing: a leaked override makes every later
      # test in this worker see a broken commit pass, a whole debugging session away from here.
      def failing_pass(predicate)
        original = Maker::Git::ProjectCommit.instance_method(:call!)
        Maker::Git::ProjectCommit.define_method(:call!) do
          raise "unreachable" if predicate.call(@project)

          original.bind(self).call
        end
        yield
      ensure
        Maker::Git::ProjectCommit.define_method(:call!, original)
      end

      def capture_log
        io = StringIO.new
        prior = Rails.logger
        Rails.logger = ActiveSupport::Logger.new(io)
        yield
        io.string
      ensure
        Rails.logger = prior
      end
    end
  end
end
