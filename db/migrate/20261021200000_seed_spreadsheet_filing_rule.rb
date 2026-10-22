# `.xlsx` GAINS A ROLE, `spreadsheet`, AND ITS FILING RULE REACHES EXISTING USERS ONCE (2026-10-21,
# the workbook viewer). The filing half of a widening, in the shape SeedImageFilingRulesAndRederiveRoles
# set; the ROLE half needs no migration since F-S33-1 (`Maker::FileAttachment.classify_unclassified!`
# re-reads `other` rows daily and `rake maker:classify_roles` does it on demand).
#
# `Maker::FilingRules.seed!` is guarded on purpose, so a user seeded before `xlsx` existed has no
# row for it; a migration runs exactly once, which is what makes a top-up safe. `insert_all(...,
# unique_by:)` is ON CONFLICT DO NOTHING — a rule the maker already wrote for `xlsx` wins. Users with
# no rules are skipped and get everything on their first read.
#
# ONLY USERS WHO STILL FILE SOMETHING INTO `docs`, AND THAT IS NEW SINCE THE LAST WIDENING. Shelves
# became the filing folders on 2026-10-20, and removing a shelf removes its rules so its extensions
# file into `other`; `Maker::Shelves.ensure!` then makes a shelf for every folder a rule names. A
# top-up naming `docs` for a maker who removed that shelf would bring it back on their next visit
# to the Shelves page — the "a removed shelf stays removed" promise, broken by a migration. Such a
# user keeps filing `.xlsx` into `other`, the same as every extension of the shelf they removed.
#
# WHAT THIS MOVES ON A NAS, said so the deploy is not a surprise: the intake sweep re-sorts project
# files sitting in `other/` whose extension now has a rule (Maker::ProjectIntake.resortable?), so a
# project's `other/foo.xlsx` moves to `docs/foo.xlsx` after this runs — never inside a git working
# tree, which intake never files.
#
# SELF-CONTAINED: it names its own values rather than reading the app's constants, because it runs
# against whatever the code looks like months from now; its test pins the copy against today's
# vocabulary. `down` takes only what `up` could have written (`where(ext:, folder:)`), so a rule the
# maker pointed somewhere else by hand survives a rollback.
class SeedSpreadsheetFilingRule < ActiveRecord::Migration[8.1]
  EXT = "xlsx".freeze
  FOLDER = "docs".freeze

  class MigrationFilingRule < ActiveRecord::Base
    self.table_name = "maker_filing_rules"
  end

  def up
    now = Time.current
    users = MigrationFilingRule.where(folder: FOLDER).distinct.pluck(:user_id)
    rows = users.map { |user_id| { user_id:, ext: EXT, folder: FOLDER, created_at: now, updated_at: now } }
    seeded = rows.any? ? MigrationFilingRule.insert_all(rows, unique_by: %i[user_id ext]).rows.size : 0
    say "seeded #{seeded} xlsx filing rule#{"s" unless seeded == 1}"
  end

  def down
    removed = MigrationFilingRule.where(ext: EXT, folder: FOLDER).delete_all
    say "removed #{removed} xlsx filing rule#{"s" unless removed == 1}"
  end
end
