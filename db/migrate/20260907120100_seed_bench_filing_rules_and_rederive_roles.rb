# THE BENCH'S OWN FORMATS REACH EXISTING USERS ONCE, HERE (stage 4, S4-2) — the same two doors
# every earlier widening used, in one migration because they are one fact: `.mage`, `.lbrn` and
# `.ai` have roles and folders now, and `.kicad_sch`/`.kicad_pcb` have folders (they can never have
# roles — they fail FilesController::EXT_RE).
#
# 1. FILING RULES. `Maker::FilingRules.seed!` is guarded by `exists?` on purpose (/settings/filing
#    promises a removed rule "will file into other until you add a new one", and a top-up on every
#    read would resurrect it), so a user seeded before these keys existed has no row for them. A
#    migration runs exactly once, which is what makes a top-up safe: a rule removed AFTER it stays
#    removed. Users with NO rows are skipped and get everything on their first read.
#    `insert_all(..., unique_by:)` is ON CONFLICT DO NOTHING, never an upsert — an edited row wins.
#
# 2. ATTACHMENT ROLES. `maker_file_attachments.role` is derived at attach time, so a `.mage`
#    attached last month carries `other`. `RederiveCodeRoles` and its siblings are the shape: only
#    rows holding the PRIOR role are touched (a role set deliberately is never rewritten), a row
#    whose node is gone is skipped, and `down` returns exactly these extensions to the prior role.
#
# SELF-CONTAINED, like every re-derive migration here: it names its own lists and tables rather
# than reading the app's constants, because it runs against whatever the code looks like months
# from now. Its test pins the copy against today's vocabulary.
#
# `down` TAKES ONLY WHAT `up` COULD HAVE WRITTEN — the folder column is free-form, so a maker who
# mapped `.stp` into `pcb` by hand must survive a rollback (SeedPcbFilingRules' recorded lesson).
class SeedBenchFilingRulesAndRederiveRoles < ActiveRecord::Migration[8.1]
  # ext => [folder, prior role, new role]. A nil new role means "no role exists for this key" —
  # the KiCad pair, which gets a folder and nothing else.
  RULES = {
    "mage"      => [ "cnc",    "other", "cnc_design" ],
    "lbrn"      => [ "laser",  "other", "laser" ],
    "ai"        => [ "design", "other", "vector" ],
    "kicad_sch" => [ "pcb",    nil,     nil ],
    "kicad_pcb" => [ "pcb",    nil,     nil ]
  }.freeze

  class MigrationFilingRule < ActiveRecord::Base
    self.table_name = "maker_filing_rules"
  end

  class MigrationAttachment < ActiveRecord::Base
    self.table_name = "maker_file_attachments"
  end

  class MigrationNode < ActiveRecord::Base
    self.table_name = "nodes"
  end

  def up
    now = Time.current
    seeded = 0
    MigrationFilingRule.distinct.pluck(:user_id).each do |user_id|
      rows = RULES.map { |ext, (folder, _prior, _new)| { user_id:, ext:, folder:, created_at: now, updated_at: now } }
      seeded += MigrationFilingRule.insert_all(rows, unique_by: %i[user_id ext]).rows.size
    end
    say "seeded #{seeded} bench filing rule#{"s" unless seeded == 1}"

    moved = 0
    MigrationAttachment.where(role: "other").find_each do |att|
      node = MigrationNode.find_by(user_id: att.user_id, node_id: att.node_id)
      next if node.nil?

      # TWO GUARDS ON ONE FACT, AND NEITHER ALONE IS PROVABLE BY THIS MIGRATION'S TEST — recorded
      # rather than hidden, the way SeedPcbFilingRules records what its own `unique_by:` cannot
      # demonstrate. The outer `where(role: "other")` narrows the scan; `att.role != prior` states
      # the pairing PER KEY, which is the one that would still be right if a later RULES entry
      # carried a prior other than "other". Every prior in RULES is "other" today, so each guard
      # subsumes the other: mutation-checked, removing EITHER leaves the suite green and removing
      # BOTH turns `deliberate.mage` from `image` into `cnc_design` and fails
      # "a role set deliberately is never re-derived".
      _folder, prior, new_role = RULES[File.extname(node.name.to_s).downcase.delete(".")]
      next if new_role.nil? || att.role != prior

      att.update_columns(role: new_role)
      moved += 1
    end
    say "re-derived #{moved} attachment role#{"s" unless moved == 1}"
  end

  def down
    removed = 0
    RULES.each { |ext, (folder, _prior, _new)| removed += MigrationFilingRule.where(ext:, folder:).delete_all }
    say "removed #{removed} bench filing rule#{"s" unless removed == 1}"

    reverted = 0
    MigrationAttachment.find_each do |att|
      node = MigrationNode.find_by(user_id: att.user_id, node_id: att.node_id)
      next if node.nil?

      _folder, prior, new_role = RULES[File.extname(node.name.to_s).downcase.delete(".")]
      next if new_role.nil? || att.role != new_role

      att.update_columns(role: prior)
      reverted += 1
    end
    say "returned #{reverted} attachment role#{"s" unless reverted == 1} to other"
  end
end
