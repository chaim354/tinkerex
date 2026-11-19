module Maker
  # ONE TIDY-UP SUGGESTION THE MAKER DISMISSED (the Shop manual's §9 tidy-up list, 2026-11-19).
  #
  # `kind` is the check that raised it (Maker::TidyUp::KINDS), `subject` the stable key of what it
  # is about, and `state` what that subject looked like at the moment it was dismissed. A suggestion
  # is hidden only while the check computes the SAME state for the same subject, so a new
  # occurrence comes back by itself and nothing ever has to clear a row for it:
  #
  #   loose        — subject: the loose file's node id; state: the path that blocks it
  #                  ("design/x.svg"). Renaming the file onto another taken name raises it again.
  #   export_older — subject: "<derived node id>><source node id>"; state: the SOURCE's mtime.
  #                  Editing the source again raises it again.
  #   uncommitted  — subject: the repository's root node id; state: a digest of the changed paths
  #                  git reports. A different set of changed paths raises it again, and so does a
  #                  save through this app after the dismissal (`updated_at` against the newest
  #                  Maker::RepoEdit), which is the one change Home can see too.
  #
  # THE SERVER WRITES THE STATE, NEVER THE BROWSER. Projects::TidyDismissalsController looks the
  # suggestion up in a fresh Maker::TidyUp and stores the state that computed, so a dismissal can
  # only ever name a suggestion the page really showed.
  class TidyDismissal < ApplicationRecord
    self.table_name = "maker_tidy_dismissals"

    SUBJECT_MAX = 200
    STATE_MAX = 500

    belongs_to :user
    belongs_to :project, class_name: "Maker::Project"

    validates :kind, inclusion: { in: ->(_) { Maker::TidyUp::KINDS } }
    validates :subject, presence: true, length: { maximum: SUBJECT_MAX }
    validates :state, length: { maximum: STATE_MAX }
    validate :project_belongs_to_user

    # Record (or re-record) a dismissal: one row per (project, kind, subject), its state and its
    # time replaced. `updated_at` is the time of the LATEST dismissal, which the uncommitted check
    # compares the newest pending edit against, so a re-dismissal must bump it even when the state
    # is unchanged — `touch` does that where `save!` on an unchanged row would not.
    def self.record!(user:, project:, kind:, subject:, state:)
      row = find_or_initialize_by(project:, kind:, subject:)
      row.user = user
      row.state = state
      if row.persisted? && !row.changed?
        row.touch
      else
        row.save!
      end
      row
    rescue ActiveRecord::RecordNotUnique
      # Two dismissals of one suggestion racing: the other request's row is the answer.
      retry
    end

    private

    def project_belongs_to_user
      return if project.nil? || user_id.nil? || project.user_id == user_id

      errors.add(:project, "must be yours")
    end
  end
end
