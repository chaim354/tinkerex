module Maker
  module Git
    # ONE USER'S PROJECTS, COMMITTED. The per-project pass is Maker::Git::ProjectCommit; this is the
    # loop around it, the audit trail for what it did, and the scheduled fan-out.
    #
    # THE SCHEDULE IS FOR CHUNK DEPLOYMENTS ONLY, and .commit_all! is where that is decided —
    # Maker::ProjectIntakeJob's rule, for the same reason and one extra. On a scanned backend
    # Library::ScanJob calls this at the end of its own #perform, strictly AFTER the project intake,
    # so a second scheduled caller would commit files the intake is about to move: git keeps
    # whatever it was told, so that history is wrong permanently rather than until the next pass.
    #
    # THE GATE IS ON THE FAN-OUT, NOT ON #perform, which is Library::ScanJob's distinction stated
    # there: `commit_all!` is a SCHEDULE, so declining to enqueue is a real answer, while #perform
    # is a COMMAND — a caller named a user, and a `return unless` there would make an operator's
    # explicit run silently do nothing. It asks a CAPABILITY rather than a class, per the Phase 3
    # trap `is_a?(Share)` shipped (§14b).
    class CommitJob < ApplicationJob
      queue_as :background

      # The user can be deleted between the fan-out and this running. Nothing to commit and nothing
      # wrong — discard rather than record a failure (GeneratePreviewJob sets the precedent).
      discard_on ActiveRecord::RecordNotFound

      # ONE PASS PER USER AT A TIME, the shape Maker::ProjectIntakeJob and Maker::ModelIntakeJob
      # already use — and here it also protects a REPOSITORY. Two concurrent passes over one
      # project both read HEAD, both build a tree from it, and the loser's `Rugged::Commit.create`
      # updates `refs/heads/main` off a parent that is no longer the head, so one of the two
      # commits is silently orphaned. :discard because a queued second pass re-does the first
      # one's work; the 15-minute schedule is the retry.
      #
      # ONLY THE SCHEDULED FAN-OUT IS LIMITED — concurrency controls apply at ENQUEUE, so
      # Library::ScanJob's `perform_now` is untouched, which is required rather than incidental:
      # the pass MUST run inline, in that job, after the intake, and a limit that could discard it
      # would break that guarantee rather than protect it.
      limits_concurrency to: 1, key: ->(args) { args[:user_id] },
                         duration: 15.minutes, on_conflict: :discard

      # `scan_started_at` IS THE SETTLE ANCHOR AND THE CALLER OWNS IT. Library::ScanJob captures it
      # BEFORE its observer runs and threads it through, because every row that scan touched was
      # written after that instant — anchoring here instead would make all of them read as settled
      # and commit a file still being written.
      #
      # THE DEFAULT IS FOR THE SCHEDULED PATH, WHICH HAS NO SCAN TO ANCHOR TO, and its weakness is
      # worth stating rather than discovering: on chunk_remote "settled" then means "not touched
      # since this job started", and the mirror is refreshed by a changelog pull up to two minutes
      # earlier (§14a), so a file written in that window can look quiet. That is a smaller error
      # than it looks — the pull writes the row when the SERVER accepted the commit, so the bytes
      # are already whole — but it is not the full quiet interval a scanned backend gets.
      def perform(user_id:, scan_started_at: Time.current)
        user = User.find(user_id)
        considered = committed = failed = 0

        # A project with no folder has nothing under it to commit — every path the pass derives is
        # relative to that folder's own storage_path. Same filter, same spelling, as
        # Maker::ProjectIntake.for_user's.
        user.maker_projects.where.not(folder_node_id: nil).find_each do |project|
          considered += 1
          oid = ProjectCommit.new(project:, scan_started_at:).call!
          next if oid.nil?

          committed += 1
          Rails.logger.info("Maker::Git::CommitJob #{project.slug}: committed #{oid}")
        rescue StandardError => e
          # ONE PROJECT'S FAILURE MUST NOT STALL THE REST. A project whose bytes are briefly
          # unreachable is ordinary on a NAS, and letting it raise would leave every project after
          # it in this loop uncommitted with nothing anywhere saying why. Scoped per project, never
          # around the loop, for exactly that reason.
          failed += 1
          Rails.logger.error("Maker::Git::CommitJob: project #{project.slug} (#{project.id}) " \
                             "failed for user #{user.id}: #{e.class}: #{e.message}")
        end

        report(user, considered:, committed:, failed:)
        committed
      end

      def self.commit_all!
        return if FileLayer.current.capabilities.scannable?

        User.find_each { |user| perform_later(user_id: user.id) }
      end

      private

      # THE LOG IS THE ENTIRE AUDIT TRAIL FOR A FAILURE, which is a narrower claim than
      # Maker::ProjectIntakeJob#report's and deliberately so: a SUCCESS here persists a marker
      # (Maker::GitRepo's head_oid/last_commit_at, and the commit itself), so it can be read back
      # later. A refusal or an exception persists nothing at all. These lines are the only place a
      # pass that accomplished nothing is ever written down.
      #
      # SILENT AT STEADY STATE. This runs every 15 minutes forever and a quiet library commits
      # nothing, so a run with no commits and no failures says nothing rather than printing a row
      # per project per quarter hour — Maker::ProjectIntakeJob#report's rule.
      #
      # A RUN THAT COMMITTED NOTHING AND A RUN THAT FAILED ON EVERYTHING ARE DIFFERENT EVENTS AND
      # MUST NOT READ THE SAME. Silence is the first; the second is N error lines plus this WARN,
      # which is what carries the DENOMINATOR — with a hundred projects, a hundred error lines
      # still do not say whether anything got committed.
      def report(user, considered:, committed:, failed:)
        if failed.positive?
          Rails.logger.warn("Maker::Git::CommitJob: user #{user.id} committed #{committed} of " \
                            "#{considered} projects — #{failed} FAILED (see the errors above).")
        elsif committed.positive?
          Rails.logger.info("Maker::Git::CommitJob: user #{user.id} committed #{committed} of " \
                            "#{considered} projects.")
        end
      end
    end
  end
end
