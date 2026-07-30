module Maker
  # Periodic sweep for previews whose node no longer exists. Scheduled from config/recurring.yml.
  #
  # WEEKLY, and the cadence is argued rather than copied: the reaper's own grace window is measured
  # in DAYS (30 by default), so nothing is reclaimed sooner by running it more often, and it is
  # DB-only — no bucket list, no per-request billing — so unlike ChunkReaperJob the cost is not what
  # keeps it infrequent. The window is.
  #
  # Backend-neutral, unlike library_scan and library_trash_purge: a dead node's preview is dead on
  # chunk, share and s3 alike, so there is no capability to gate on and no reason for a class
  # method that declines.
  class DeadNodeReaperJob < ApplicationJob
    queue_as :background

    def perform(grace: Maker::Previews::DeadNodeReaper::GRACE, dry_run: false)
      reaped = Maker::Previews::DeadNodeReaper.reap_all!(grace:, dry_run:)
      Rails.logger.info("DeadNodeReaperJob #{dry_run ? '[dry-run] would reap' : 'reaped'} " \
                        "#{reaped} preview(s) whose node no longer exists")
      reaped
    end
  end
end
