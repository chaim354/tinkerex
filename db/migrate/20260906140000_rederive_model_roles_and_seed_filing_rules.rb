# THE THIRTEEN MESH AND CAD FORMATS THE VIEWER NOW OPENS (Online3DViewer, 2026-09-06) REACH EXISTING
# USERS ONCE, HERE — the same two doors the earlier widenings used, in one migration because they
# are one fact: `gltf glb ply off dae wrl 3ds fbx 3dm amf iges igs brep` are `model` now.
#
# 1. FILING RULES. `Maker::FilingRules.seed!` is guarded by `exists?` on purpose (/settings/filing
#    promises a removed rule "will file into other until you add a new one", and a top-up on every
#    read would resurrect it), so a user seeded before these extensions existed has no row for them
#    and a `.glb` dropped at a project root files into `other/`. A migration runs exactly once, so a
#    rule removed AFTER it stays removed; users with no rows are skipped and get everything on their
#    first read. `SeedPcbFilingRules` (the Gerber slice) is the precedent, and its `down` lesson is
#    kept: the folder column is free-form, so a rollback takes only these EXTENSIONS filing into the
#    role's default folder, never "every row whose folder is models".
#
# 2. ATTACHMENT ROLES. `maker_file_attachments.role` is derived at attach time, so a `.glb` attached
#    last month carries `other`. `RederiveCodeRoles` and its four siblings are the shape: only rows
#    holding the PRIOR role are touched (a role set deliberately is never rewritten), a row whose
#    node is gone is skipped, and `down` returns exactly these extensions to the prior role.
#
# SELF-CONTAINED, like every re-derive migration here: it names its own extension list and its own
# tables rather than reading the app's constants, because it runs against whatever the code looks
# like months from now. The test pins that the list equals today's vocabulary.
class RederiveModelRolesAndSeedFilingRules < ActiveRecord::Migration[8.1]
  MODEL_EXTS = %w[gltf glb ply off dae wrl 3ds fbx 3dm amf iges igs brep].freeze
  FOLDER = "models".freeze
  PRIOR_ROLE = "other".freeze
  NEW_ROLE = "model".freeze

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
      rows = MODEL_EXTS.map { |ext| { user_id:, ext:, folder: FOLDER, created_at: now, updated_at: now } }
      seeded += MigrationFilingRule.insert_all(rows, unique_by: %i[user_id ext]).rows.size
    end
    say "seeded #{seeded} model filing rule#{"s" unless seeded == 1}"

    moved = 0
    MigrationAttachment.where(role: PRIOR_ROLE).find_each do |att|
      node = MigrationNode.find_by(user_id: att.user_id, node_id: att.node_id)
      next if node.nil?

      ext = File.extname(node.name.to_s).downcase.delete(".")
      next unless MODEL_EXTS.include?(ext)

      att.update_columns(role: NEW_ROLE)
      moved += 1
    end
    say "re-derived #{moved} attachment role#{"s" unless moved == 1}"
  end

  def down
    removed = MigrationFilingRule.where(folder: FOLDER, ext: MODEL_EXTS).delete_all
    say "removed #{removed} model filing rule#{"s" unless removed == 1}"

    reverted = 0
    MigrationAttachment.where(role: NEW_ROLE).find_each do |att|
      node = MigrationNode.find_by(user_id: att.user_id, node_id: att.node_id)
      next if node.nil?
      next unless MODEL_EXTS.include?(File.extname(node.name.to_s).downcase.delete("."))

      att.update_columns(role: PRIOR_ROLE)
      reverted += 1
    end
    say "returned #{reverted} attachment role#{"s" unless reverted == 1} to #{PRIOR_ROLE}"
  end
end
