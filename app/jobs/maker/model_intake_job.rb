module Maker
  # The scheduled half of Maker::ModelIntake. Mirrors Maker::ProjectIntakeJob down to why each
  # decision is what it is -- read that file before changing this one.
  class ModelIntakeJob < ApplicationJob
    queue_as :background

    # The user can be deleted between the fan-out and this running. Nothing to sweep and nothing
    # wrong (GeneratePreviewJob sets the precedent).
    discard_on ActiveRecord::RecordNotFound

    # ONE SWEEP PER USER AT A TIME, and a dropped tick is better than a backlog: the 15-minute
    # schedule IS the retry, and it re-reads the world rather than replaying a stale verdict.
    limits_concurrency to: 1, key: ->(args) { args[:user_id] },
                       duration: 15.minutes, on_conflict: :discard

    def perform(user_id:)
      user = User.find(user_id)
      run = Maker::ModelIntake.for_user(user:)
      if run.created.positive? || run.status == :capped
        Rails.logger.info("Maker::ModelIntakeJob: user #{user.id} created #{run.created}, " \
                          "attached #{run.attached}, status #{run.status}")
      end
      run
    end

    # THE GATE IS HERE AND NOT IN #perform, matching Library::ScanJob.scan_all! and
    # Maker::ProjectIntakeJob.sweep_all!: on a scannable backend Library::ScanJob already calls the
    # intake at the end of its own perform, strictly after the reconcile. A second caller would
    # catalogue paths the reconcile has not settled yet.
    def self.sweep_all!
      return if FileLayer.current.capabilities.scannable?

      User.find_each { |user| perform_later(user_id: user.id) }
    end
  end
end
