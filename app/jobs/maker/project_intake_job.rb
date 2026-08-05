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
