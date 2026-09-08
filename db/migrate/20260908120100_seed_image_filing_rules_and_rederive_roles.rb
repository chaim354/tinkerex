# AN iPHONE'S AND A SCANNER'S RASTERS REACH EXISTING USERS ONCE (tinkerex#285): `.heic`, `.heif`,
# `.tif` and `.tiff` gain the `image` role, so they file into `images/`, the photo door takes them
# and libvips thumbnails them. The same two doors every widening uses (SeedBenchFilingRules...
# is the shape), in one migration because they are one fact:
#
# 1. FILING RULES. `Maker::FilingRules.seed!` is guarded by `exists?` on purpose, so a user seeded
#    before these keys existed has no row for them; a migration runs exactly once, which is what
#    makes a top-up safe. `insert_all(..., unique_by:)` is ON CONFLICT DO NOTHING — an edited row
#    wins. Users with NO rows are skipped and get everything on their first read.
# 2. ATTACHMENT ROLES. Only rows still carrying the PRIOR role (`other`) are touched — a role set
#    deliberately is never rewritten — a row whose node is gone is skipped, and `down` returns
#    exactly these extensions to `other`.
#
# SELF-CONTAINED: it names its own lists rather than reading the app's constants, because it runs
# against whatever the code looks like months from now; its test pins the copy against today's
# vocabulary.
#
# `down` TAKES ONLY WHAT `up` COULD HAVE WRITTEN — the folder column is free-form, so a maker who
# mapped `.heic` into `photos` by hand must survive a rollback (`where(ext:, folder:)`, never
# `where(ext:)`; SeedPcbFilingRules' recorded lesson). And `down` cannot tell a row `up` re-derived
# from one that was `image` all along: an attachment created after this migration by ordinary
# `role_for` derivation is returned to `other` too — the accepted cost of a reversible data
# migration, the S4-2 precedent's as well, recorded rather than hidden.
#
# TWO GUARDS ON ONE FACT in `up`, and neither alone is provable by this migration's test: the outer
# `where(role: "other")` narrows the scan, and `att.role != prior` states the pairing PER KEY, which
# is the one that would still be right if a later RULES entry carried a prior other than "other".
# Every prior here is "other", so each guard subsumes the other today.
class SeedImageFilingRulesAndRederiveRoles < ActiveRecord::Migration[8.1]
  # ext => [folder, prior role, new role]
  RULES = {
    "heic" => [ "images", "other", "image" ],
    "heif" => [ "images", "other", "image" ],
    "tif"  => [ "images", "other", "image" ],
    "tiff" => [ "images", "other", "image" ]
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
    say "seeded #{seeded} image filing rule#{"s" unless seeded == 1}"

    moved = 0
    MigrationAttachment.where(role: "other").find_each do |att|
      node = MigrationNode.find_by(user_id: att.user_id, node_id: att.node_id)
      next if node.nil?

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
    say "removed #{removed} image filing rule#{"s" unless removed == 1}"

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
