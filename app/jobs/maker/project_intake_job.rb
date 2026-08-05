module Maker
  # Periodic project-folder intake: attach what is under each project folder, file what is loose at
  # its root. Scheduled from config/recurring.yml.
  #
  # THE SCHEDULE IS FOR CHUNK DEPLOYMENTS ONLY, and .sweep_all! is where that is decided. On a
  # scanned backend (share/s3) Library::ScanJob calls the intake at the end of its own #perform, so
  # the two are strictly sequential; a second, scheduled caller would reintroduce exactly the
  # overlap that placement exists to prevent — a move made after the Scanner captured its
  # observations gets paired back by (content_hash, size), leaving the node pointed at a path with
  # no bytes until the next scan.
  #
  # THE GATE IS ON THE FAN-OUT, NOT ON #perform, and the distinction is Library::ScanJob's, stated
  # there: `sweep_all!` is a SCHEDULE, so declining to enqueue is a real answer, while #perform is a
  # COMMAND — a caller named a user, and a `return unless` there would make an operator's explicit
  # run silently do nothing. It also asks a CAPABILITY rather than a class, per the Phase 3 trap
  # `is_a?(Share)` shipped: a gate that names classes answers false for the next backend and
  # silently never runs.
  class ProjectIntakeJob < ApplicationJob
    queue_as :background

    # The user can be deleted between the fan-out and this running. Nothing to sweep and nothing
    # wrong — discard rather than record a failure (GeneratePreviewJob sets the precedent).
    discard_on ActiveRecord::RecordNotFound

    # ONE SWEEP PER USER AT A TIME, same shape and same reasoning as Library::ScanJob's — two
    # concurrent sweeps over one user's project folders both read "what is loose at the root",
    # both decide to file the same file, and the loser's move runs against a node the winner has
    # already moved. :discard because a queued second sweep re-does the first one's work; the
    # 15-minute schedule is the retry.
    #
    # ONLY THE SCHEDULED FAN-OUT IS LIMITED. Concurrency controls apply at ENQUEUE, so the two
    # entry points that run this work synchronously are untouched, which is required rather than
    # incidental: Library::ScanJob#intake_project_folders calls `perform_now` (§14f — the intake
    # MUST run inline, after the reconcile, or a move races the Scanner's observations), and the
    # eager nudge calls Maker::ProjectIntake directly rather than going through this job at all.
    #
    # duration: a capped sweep is bounded work (MAX_MOVES 500) and measured in tens of ms at
    # steady state, so 15 minutes — one schedule tick — is ample cover for a crashed worker.
    limits_concurrency to: 1, key: ->(args) { args[:user_id] },
                       duration: 15.minutes, on_conflict: :discard

    def perform(user_id:)
      user = User.find(user_id)
      run = Maker::ProjectIntake.for_user(user:)
      report(run, user)
      run
    end

    def self.sweep_all!
      return if FileLayer.current.capabilities.scannable?

      User.find_each { |user| perform_later(user_id: user.id) }
    end

    # How long a nudge waits before sweeping — long enough for the rest of a device's batch to land,
    # short enough that "I dropped files in and nothing happened" is never the experience.
    NUDGE_DELAY = 30.seconds

    # THE DEVICE-PUSH NUDGE — the gap CLAUDE.md §12 item 10 records, closed in the shape that item
    # said a fix would have to take rather than the shape it said would be worse.
    #
    # A file arriving through the MOUNT had no fast path at all: the three web upload doors call
    # Maker::ProjectIntake.for_node inline, but a device push never did, so it waited up to 15
    # minutes for the periodic sweep. §12.10 rejected the obvious fix on solid grounds —
    # Sync::Commit#finalize runs once PER FILE, so sweeping there would turn a 500-file device sync
    # into 500 synchronous full-project sweeps.
    #
    # ASYNC + DEDUPLICATED IS THE WHOLE DIFFERENCE. This ENQUEUES rather than sweeps, and this job's
    # own `limits_concurrency to: 1, key: user_id, on_conflict: :discard` collapses those 500
    # enqueues into ONE sweep a few seconds after the batch settles: same trigger as the rejected
    # version, one sweep instead of five hundred.
    #
    # ONLY WHEN THE FILE LANDED AT A PROJECT FOLDER'S ROOT — both a cost control and a faithful
    # reading of the rule. §14f's "ROOT = INBOX IS THE WHOLE SORT RULE" means a file arriving deeper
    # is already where someone put it and there is nothing to file. One indexed `exists?` per
    # finalize is the price, paid on the sync hot path, and it is what stops this enqueueing for
    # every commit in the library.
    #
    # THE RESIDUAL, STATED PLAINLY: the ENQUEUES are not deduplicated, only the SWEEP is. 500
    # root-landing files write 500 job rows of which 499 are discarded when they become ready;
    # Solid Queue's hourly clear_solid_queue_finished_jobs reclaims them. Deduplicating the enqueue
    # itself means asking the queue what is already scheduled, which couples this to Solid Queue's
    # schema to save a row rather than a sweep.
    #
    # BEST-EFFORT: nothing here may fail the commit a device is waiting on.
    def self.nudge(user:, node:)
      return if node.nil? || node.parent_node_id.blank?
      return unless user.maker_projects.where(folder_node_id: node.parent_node_id).exists?

      set(wait: NUDGE_DELAY).perform_later(user_id: user.id)
    rescue StandardError => e
      Rails.logger.warn("Maker::ProjectIntakeJob.nudge failed for user #{user.id}: " \
                        "#{e.class}: #{e.message}")
    end

    private

    # THE LOG IS THE ENTIRE AUDIT TRAIL. Nothing persists a marker for what was filed, so these
    # lines are the only record of it — the same argument Maker::AttachToProject#log_failure makes,
    # and the counts are behaviour rather than phrasing.
    #
    # ONE LINE PER PROJECT THAT DID SOMETHING, so a steady state (every 15 minutes, forever,
    # nothing loose) is silent instead of printing a row of zeroes per project per quarter hour.
    def report(run, user)
      if run.status == :refused_too_many_moves
        Rails.logger.warn("Maker::ProjectIntakeJob: attached, but REFUSED to file " \
                          "#{run.inbox_total} loose files for user #{user.id} — over the " \
                          "#{run.cap} cap. Inspect with `DRY_RUN=1 rake projects:organize`, then " \
                          "run `rake projects:organize` (it lifts the cap) or raise " \
                          "PROJECT_ORGANIZE_MAX_MOVES.")
      end

      run.results.each do |project, result|
        next if result.attached.zero? && result.moved.zero? && result.skipped.zero?

        Rails.logger.info("Maker::ProjectIntakeJob #{project.slug}: attached #{result.attached}, " \
                          "filed #{result.moved}, left #{result.skipped}")
      end
    end
  end
end
