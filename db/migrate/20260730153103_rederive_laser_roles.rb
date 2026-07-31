# Moves attachments that were `vector` only because ROLE_BY_EXT had no `laser` role into the one
# added alongside this migration.
#
# SELF-CONTAINED ON PURPOSE, as both predecessors are
# (20260728124303_rederive_vector_and_cad_source_roles.rb,
# 20260729035422_rederive_document_roles.rb). It does not call Maker::FileAttachment.role_for and
# does not use the app's models: a data migration runs against whatever the schema and the code look
# like months from now, and app code keeps moving.
#
# IT IS NOT A COPY OF EITHER PREDECESSOR, AND THE DIFFERENCE IS THE WHOLE MIGRATION. Both of those
# added BRAND-NEW extensions, so every row they had to fix was sitting in "other" — they select
# `role: "other"` and their `down` returns rows to "other". `lbrn2` already HAD a role. So:
#
#   * `up` selects `role: "vector"`. Selecting "other" would find nothing and succeed silently.
#   * `down` returns to "vector". Returning to "other" would leave these rows WORSE OFF than
#     before this migration ran — a rollback that loses information the forward migration had.
#
# Both halves are pinned by test/models/maker/rederive_laser_roles_migration_test.rb, because
# neither failure is visible from reading it next to its predecessors.
class RederiveLaserRoles < ActiveRecord::Migration[8.1]
  # The extensions that moved INTO `laser`. A COPY rather than a reference, for the predecessors'
  # stated reason — and with the same accepted cost: an extension added to the model after this runs
  # never re-derives the rows already sitting in `vector`, and closing that needs another migration.
  LASER_EXTS = %w[lbrn2].freeze

  # Where they came FROM. Named rather than inlined because `down` needs the same value, and the two
  # being one constant is what stops a rollback sending rows somewhere they were never.
  PRIOR_ROLE = "vector".freeze
  NEW_ROLE = "laser".freeze

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
      next unless LASER_EXTS.include?(ext)
      att.update_columns(role: NEW_ROLE)
      moved += 1
    end
    say "re-derived #{moved} attachment role#{"s" unless moved == 1}"
  end

  # Returns EVERY laser row to `vector`, not only the rows `up` moved — it has no record of which
  # those were, and `role_for` is already live in four controllers, so organic `laser` rows can
  # exist before `up` ever runs. Acceptable for the predecessors' reason: the pair is self-healing,
  # since the mapping is a pure function of the current filename.
  def down
    MigrationAttachment.where(role: NEW_ROLE).update_all(role: PRIOR_ROLE)
  end
end
