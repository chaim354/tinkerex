module Maker
  # Periodic sweep for maker rows pointing at a node the library no longer has. Scheduled from
  # config/recurring.yml.
  #
  # DAILY, WHERE DeadNodeReaperJob IS WEEKLY, and the difference is argued rather than inherited.
  # Both are DB-only and both wait out the same 30-day grace, so neither cadence is about cost or
  # about reclaiming sooner. What differs is what a late sweep leaves behind: a stale PREVIEW row is
  # invisible (nothing renders it), while a stale ATTACHMENT is a row the user can still see through
  # the v1 API and the one they complained about. Checking a day after the window closes rather than
  # up to a week after is the whole of the difference, and it costs two queries per user.
  #
  # Backend-neutral: a dead node is dead on chunk, share and s3 alike, so there is no capability to
  # gate on.
  class AttachmentReaperJob < ApplicationJob
    queue_as :background

    def perform(grace: Maker::AttachmentReaper::GRACE, dry_run: false)
      reaped = Maker::AttachmentReaper.reap_all!(grace:, dry_run:)
      Rails.logger.info("AttachmentReaperJob #{dry_run ? '[dry-run] would reap' : 'reaped'} " \
                        "#{reaped} attachment(s)/cover(s) whose node no longer exists")
      reaped
    end
  end
end
