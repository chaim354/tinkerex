# Moves attachments that were "other" only because ROLE_BY_EXT had no entry for their extension
# into the `code` role added alongside this migration.
#
# SELF-CONTAINED ON PURPOSE, as all three predecessors are
# (20260728124303_rederive_vector_and_cad_source_roles.rb,
# 20260729035422_rederive_document_roles.rb, 20260730153103_rederive_laser_roles.rb). It does not
# call Maker::FileAttachment.role_for and does not use the app's models: a data migration runs
# against whatever the schema and the code look like months from now, and app code keeps moving.
#
# IT IS THE FIRST TWO'S SHAPE, NOT THE THIRD'S, AND THAT IS THE CHOICE TO CHECK. `lbrn2` already
# HAD a role, so RederiveLaserRoles selects `vector` and rolls back to `vector`. Every one of the
# 26 extensions here was either brand new to ROLE_BY_EXT or mapped nowhere at all — five of them
# (xml log ini cfg conf) the detail page previewed as text while the vocabulary called them
# "other" — so every row needing repair is in "other". `up` selects "other" and `down` returns rows
# there. Copy the third instead and `up` selects a role no row has and succeeds SILENTLY, while
# `down` files these rows under `vector`, somewhere they have never been.
#
# ONLY THE CONSTANTS FOLLOW THE THIRD: one new role and 26 extensions, so a 26-entry hash all
# mapping to the same string would be noise, and naming PRIOR_ROLE once is what stops `down`
# sending rows anywhere else.
class RederiveCodeRoles < ActiveRecord::Migration[8.1]
  # The extensions that moved INTO `code`. A COPY rather than a reference, for the predecessors'
  # stated reason — and with the same accepted cost: an extension added to the model AFTER this
  # migration runs never re-derives the rows already sitting in "other", and closing that needs
  # ANOTHER migration. That is the price of the self-contained style, not a defect of it. Pinned
  # against the model by test/models/maker/rederive_code_roles_migration_test.rb, which is the only
  # thing that would notice the copy drifting.
  CODE_EXTS = %w[c h cpp cc hpp ino py rb js ts rs go sh lua sql
                 html css xml log toml ini cfg conf yml yaml cmake].freeze

  # Where the rows come FROM and go TO. Named rather than inlined because `down` needs the same
  # value, and the two being one constant is what stops a rollback sending rows somewhere new.
  PRIOR_ROLE = "other".freeze
  NEW_ROLE = "code".freeze

  class MigrationAttachment < ActiveRecord::Base
    self.table_name = "maker_file_attachments"
  end

  class MigrationNode < ActiveRecord::Base
    self.table_name = "nodes"
  end

  def up
    moved = 0
    MigrationAttachment.where(role: PRIOR_ROLE).find_each do |att|
      node = MigrationNode.find_by(user_id: att.user_id, node_id: att.node_id)
      next if node.nil? # attachment to a deleted/missing node — nothing to derive from
      ext = File.extname(node.name.to_s).downcase.delete(".")
      next unless CODE_EXTS.include?(ext)
      att.update_columns(role: NEW_ROLE)
      moved += 1
    end
    say "re-derived #{moved} attachment role#{"s" unless moved == 1}"
  end

  # Returns EVERY code row to "other", not only the rows `up` moved — it has no record of which
  # those were, and `role_for` is live in four controllers, so organic `code` rows exist from the
  # moment the role shipped rather than from the moment this runs. Acceptable for the predecessors'
  # reason: the pair is self-healing, since the mapping is a pure function of the current filename.
  def down
    MigrationAttachment.where(role: NEW_ROLE).update_all(role: PRIOR_ROLE)
  end
end
