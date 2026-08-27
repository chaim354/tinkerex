module Maker
  # Bookkeeping for a project's repository. AN INDEX, NEVER A SOURCE OF TRUTH.
  #
  # The authoritative head is the repo's own `refs/heads/main`, and the authoritative answer to
  # "is this repo app-managed" is the git config key `tinkerex.managed` -- both travel WITH the
  # repo, so a restore, a re-hydrate, or a maker copying their library to a new NAS keeps them.
  # This row exists so the UI and the intake sweep can ask "does this project have a repo, and
  # roughly where is its head" WITHOUT hydrating, which on s3 is real billed requests.
  #
  # CONSEQUENCE TO RESPECT: this row may be STALE or ABSENT while the repo is perfectly valid.
  # Never treat its absence as "no repo" for a destructive decision.
  #
  # NOT USER-SCOPED, unlike almost every other Maker:: model. Tenancy comes from the project, the
  # way Maker::AddonFile takes it from its addon state -- see the migration for why this table is
  # the same shape as those two and not the same shape as maker_sheets.
  class GitRepo < ApplicationRecord
    self.table_name = "maker_git_repos"

    belongs_to :project, class_name: "Maker::Project"

    # BOTH HALVES OF THIS ARE LOAD-BEARING AND NEITHER SUBSTITUTES FOR THE OTHER. The validation
    # gives a door a 422 instead of a 500; the unique index behind it is what actually holds,
    # because a validation is a read-then-write and two workers can both read "no row yet".
    validates :project_id, uniqueness: true
  end
end
