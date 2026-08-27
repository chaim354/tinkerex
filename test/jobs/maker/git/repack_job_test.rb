require "test_helper"

module Maker
  module Git
    # THE LOOP AROUND Maker::Git::Repo#repack_all!, its audit trail, and the scheduled fan-out. The
    # collapse itself has its own suite (test/services/maker/git/repo_test.rb, on BOTH backend
    # shapes); what is asserted here is only what the JOB adds — which projects it visits, which it
    # must not TOUCH, what survives a failure, and what an operator can read afterwards.
    #
    # THE BACKEND IS PINNED, NEVER AMBIENT, for commit_job_test.rb's measured reason: the job
    # resolves FileLayer.current itself, so an ambient adapter aims a real S3 client at config/ci.rb's
    # stub bucket on the `test-s3` leg and writes a `Projects/` tree into the repo root on the `test`
    # leg. `use_fresh_share_library!` owns the teardown of the root it mints.
    class RepackJobTest < ActiveSupport::TestCase
      include ActiveJob::TestHelper

      setup do
        @root = use_fresh_share_library!
        @user = User.create!(email: "grj-#{SecureRandom.hex(4)}@example.com")
        @project = project!("Desk Lamp")
      end

      teardown { FileLayer.reset! }

      # ---- the pass itself ---------------------------------------------------------------------

      test "a repository over the pack limit is collapsed, and keeps its history" do
        pack!(@project, Maker::Git::Repo::MAX_PACKS + 1)

        assert_equal 1, Maker::Git::RepackJob.perform_now(user_id: @user.id)

        repo = Maker::Git::Repo.for(@project)
        assert_equal 1, repo.pack_idx_rels.size
        assert_equal Maker::Git::Repo::MAX_PACKS + 1, repo.log(limit: 200).size,
                     "the repack collapsed the packs and lost the history"
        assert_equal "0\n", repo.blob_at(oid: repo.head_oid, path: "f0.txt")
      end

      # A repack reads and rewrites every object a repository has, which on a hydrated backend is a
      # full download and a full re-upload. THE THRESHOLD is what keeps that rare — the weekly
      # cadence only decides how long a repository sits over the limit once it crosses it.
      test "a repository below the pack limit is left alone" do
        pack!(@project, 3)

        assert_equal 0, Maker::Git::RepackJob.perform_now(user_id: @user.id)
        assert_equal 3, Maker::Git::Repo.for(@project).pack_idx_rels.size
      end

      # THE ONE THING A TIDY-UP SWEEP COULD BREAK THAT NOTHING WOULD REPORT. `Repo#hydrate!` mints
      # `.git`, and that directory is the marker Maker::AttachToProject reads to decide whether
      # project-intake filing applies to a folder — so a sweep that opened every project would
      # switch filing off across the whole library, silently, at the next scan and nowhere near
      # here. Maker::GitRepo is the filter, and its absent-row answer must stay SKIP.
      test "a project that has never been committed is not even opened" do
        pack!(@project, Maker::Git::Repo::MAX_PACKS + 1)
        untouched = project!("Sketchbook")

        Maker::Git::RepackJob.perform_now(user_id: @user.id)

        assert_nil Maker::GitRepo.find_by(project: untouched)
        refute File.exist?(Maker::Git::Repo.for(untouched).git_dir),
               "hydrating a project with no repository mints the .git marker and switches off its filing"
      end

      # ---- one bad project must not stall the rest ---------------------------------------------

      # THE FAILING PROJECT IS THE ONE WITH THE LOWER ID, DELIBERATELY: find_each walks in id order,
      # so a rescue that merely returned early would still leave this green if the good project ran
      # first. @project comes from setup, so it is that one.
      test "one project's failure does not stall the projects after it, and is written down" do
        later = project!("Later")
        pack!(@project, Maker::Git::Repo::MAX_PACKS + 1)
        pack!(later, Maker::Git::Repo::MAX_PACKS + 1)

        log = capture_log do
          failing_repack(->(project) { project.id == @project.id }) do
            assert_equal 1, Maker::Git::RepackJob.perform_now(user_id: @user.id),
                         "the project after the failure must still be repacked"
          end
        end

        assert_equal 1, Maker::Git::Repo.for(later).pack_idx_rels.size
        assert_equal Maker::Git::Repo::MAX_PACKS + 1, Maker::Git::Repo.for(@project).pack_idx_rels.size,
                     "a failed repack must leave every pack where it was"
        assert_match(/project #{@project.slug} \(#{@project.id}\) failed for user #{@user.id}: RuntimeError: unreachable/,
                     log, "the swallowed failure must name the project AND the exception")
      end

      # ---- the audit trail ---------------------------------------------------------------------

      # THE STEADY STATE, and it is nearly every run: the threshold declines and there is nothing to
      # say. Silence is the right answer — Maker::Git::CommitJob#report's rule, or the log fills
      # with rows of zeroes for the life of the deployment.
      test "a run that repacks nothing says nothing" do
        pack!(@project, 3)

        log = capture_log { Maker::Git::RepackJob.perform_now(user_id: @user.id) }

        assert_no_match(/repacked/, log)
        assert_no_match(/FAILED/, log)
      end

      # THE OTHER HALF, and the pair IS the requirement: silence must not be what a total failure
      # looks like. The WARN carries the DENOMINATOR — with a hundred repositories, a hundred error
      # lines still do not say whether anything got collapsed.
      test "a run that failed on every repository is loud, and says how many" do
        second = project!("Also Broken")
        pack!(@project, Maker::Git::Repo::MAX_PACKS + 1)
        pack!(second, Maker::Git::Repo::MAX_PACKS + 1)

        log = capture_log do
          failing_repack(->(_project) { true }) do
            assert_equal 0, Maker::Git::RepackJob.perform_now(user_id: @user.id)
          end
        end

        assert_match(/repacked 0 of 2 repositories — 2 FAILED/, log)
        assert_equal 2, log.scan(/RuntimeError: unreachable/).size,
                     "each failure gets its own line; the summary is not a substitute for them"
      end

      # ---- the schedule ------------------------------------------------------------------------

      # NO BACKEND GATE, unlike Maker::Git::CommitJob.commit_all! and every gated entry in
      # recurring.yml — this is the assertion that says so rather than leaving it to be inferred
      # from an absence. Share is scannable; nothing else calls a repack on any backend, and every
      # backend pays for the file count (GETs, WAN round trips, SMB metadata round trips).
      test "repack_all! enqueues on a scannable backend, because nothing else is its caller there" do
        assert_enqueued_with(job: Maker::Git::RepackJob, args: [ { user_id: @user.id } ]) do
          Maker::Git::RepackJob.repack_all!
        end
      end

      # The user can be deleted between the fan-out and this running. Nothing to repack and nothing
      # wrong (GeneratePreviewJob sets the precedent).
      test "a missing user is discarded, not failed" do
        assert_nothing_raised do
          perform_enqueued_jobs { Maker::Git::RepackJob.perform_later(user_id: 999_999_999) }
        end
      end

      private

      def project!(name)
        project = @user.maker_projects.create!(name:)
        project.ensure_library_folder!(@user)
        project.reload
      end

      # One pack per commit, which is what the commit loop produces one window at a time — and the
      # whole reason this job exists. Goes through the real Repo rather than PackWriter directly, so
      # the `Maker::GitRepo` row the job filters on is written by the code that owns it.
      def pack!(project, count)
        repo = Maker::Git::Repo.for(project).hydrate!
        count.times do |i|
          repo.commit!(paths: { "f#{i}.txt" => "#{i}\n" }, message: "c#{i}")
          repo.consolidate!
        end
        repo
      end

      # Hand-rolled override with an ensure-restore — commit_job_test.rb's `failing_pass` idiom,
      # and minitest 6 dropped Object#stub so there is no alternative. The ensure is load-bearing: a
      # leaked override makes every later test in this worker see a broken repack, a whole debugging
      # session away from here.
      def failing_repack(predicate)
        original = Maker::Git::Repo.instance_method(:repack_all!)
        Maker::Git::Repo.define_method(:repack_all!) do
          raise "unreachable" if predicate.call(@project)

          original.bind(self).call
        end
        yield
      ensure
        Maker::Git::Repo.define_method(:repack_all!, original)
      end

      # commit_job_test.rb's, verbatim: the summary is a real Rails.logger line, so read it there
      # rather than through a seam invented for the test.
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
