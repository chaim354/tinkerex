# A NEW ROLE'S RULES REACH EXISTING USERS ONCE, HERE — NEVER BY RE-SEEDING ON READ.
#
# `Maker::FilingRules.seed!` is guarded by `exists?` on purpose and that guard must not be weakened:
# /settings/filing promises that a removed rule "will file into other until you add a new one", so a
# per-extension top-up on every read would resurrect a rule the user deliberately deleted. A
# MIGRATION runs exactly once, which is what makes the top-up safe: a `pcb` rule removed AFTER this
# ran stays removed.
#
# USERS WITH NO ROWS AT ALL ARE SKIPPED, and that is the same argument from the other side. Their
# map has never been seeded, so their first read seeds the WHOLE table — `pcb` included, from
# ROLE_BY_EXT — and inserting rows for them here would hand them a partial map that `seed!`'s
# `exists?` guard then refuses to complete, which is the one state that guard is documented to leave
# alone. `where(id: Maker::FilingRule.select(:user_id))` is one subselect, not a load.
#
# SELF-CONTAINED, LIKE EVERY RE-DERIVE MIGRATION IN THIS DIRECTORY (the five
# `rederive_*_roles` ones say so at length): a data migration runs against whatever the schema and
# the app code look like months from now, so it names its own extension list and its own table
# rather than reading `Maker::FileAttachment::ROLE_BY_EXT` and `Maker::ProjectFolders::ROLE_FOLDERS`
# through constants that will have moved. The accepted cost is the predecessors' accepted cost: an
# extension added to the `pcb` role AFTER this runs needs another migration to reach existing users.
# Pinned against the model by test/models/maker/seed_pcb_filing_rules_migration_test.rb, which is
# the only thing that would notice the copy drifting.
#
# `insert_all(..., unique_by:)` NAMES THE REAL UNIQUE INDEX — `index_maker_filing_rules_on_user_id_and_ext`
# over (user_id, ext) — which is what makes this idempotent AND non-destructive at once: a user who
# somehow already holds a `pcb` row (they added `.drl` by hand at /settings/filing before this ran)
# keeps THEIR folder, because ON CONFLICT DO NOTHING never overwrites.
#
# WHAT NAMING THE TARGET BUYS IS NOT THE SKIP — MEASURED, NOT ASSUMED, because the obvious claim is
# wrong and this comment used to make it. Both spellings skip:
#
#   insert_all(rows, unique_by: %i[user_id ext])  ->  ON CONFLICT ("user_id","ext") DO NOTHING
#   insert_all(rows)                              ->  ON CONFLICT DO NOTHING
#
# (probed against this app's SQLite in `bin/rails runner`; `Maker::FilingRules.seed!` relies on the
# second form's behaviour and its own header says so). What the named target buys is that ONLY the
# expected collision is swallowed: the bare form silently absorbs a conflict on ANY constraint —
# the primary key, or a unique index added later — where the named one lets a collision nobody
# predicted raise instead of vanishing. That is the reason to keep it, and it is a reason no test
# in this repo can demonstrate today, which is why it is written down here.
#
# ADAPTER-AGNOSTIC (§14e): `insert_all` compiles to ON CONFLICT DO NOTHING on both SQLite and
# Postgres, and the index it names exists on both. No raw SQL.
class SeedPcbFilingRules < ActiveRecord::Migration[8.1]
  # A COPY of the `pcb` half of Maker::FileAttachment::ROLE_BY_EXT, for the reason above.
  PCB_EXTS = %w[
    gbr gtl gbl gts gbs gto gbo gtp gbp gko gm1 gm2 gm3 gp1 gp2 g1 g2 g3 g4 gd1 gg1 drl xln gbrjob
  ].freeze

  # A COPY of Maker::ProjectFolders::ROLE_FOLDERS["pcb"], same reason.
  FOLDER = "pcb".freeze

  class MigrationFilingRule < ActiveRecord::Base
    self.table_name = "maker_filing_rules"
  end

  def up
    now = Time.current
    added = 0
    MigrationFilingRule.distinct.pluck(:user_id).each do |user_id|
      rows = PCB_EXTS.map { |ext| { user_id:, ext:, folder: FOLDER, created_at: now, updated_at: now } }
      result = MigrationFilingRule.insert_all(rows, unique_by: %i[user_id ext])
      added += result.rows.size
    end
    say "seeded #{added} pcb filing rule#{"s" unless added == 1}"
  end

  # EVERY `pcb` ROW, NOT JUST THE ONES `up` WROTE, and that is the blunt spelling the four
  # `rederive_*` migrations use with the same justification: `pcb` is a role this arc INTRODUCES, so
  # before it ran no row in this table could carry that folder — nothing to destroy that this
  # migration did not create. (A user who has since RENAMED their pcb folder to something else keeps
  # that row, correctly: it is no longer a `pcb` row.)
  def down
    removed = MigrationFilingRule.where(folder: FOLDER).delete_all
    say "removed #{removed} pcb filing rule#{"s" unless removed == 1}"
  end
end
