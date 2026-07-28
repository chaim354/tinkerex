# Moves attachments that were "other" only because ROLE_BY_EXT had no entry for their extension
# into the two roles added alongside this migration.
#
# SELF-CONTAINED ON PURPOSE. It does not call Maker::FileAttachment.role_for and does not use the
# app's models: a data migration runs against whatever the schema and the code look like months
# from now, and app code keeps moving.
class RederiveVectorAndCadSourceRoles < ActiveRecord::Migration[8.1]
  # Must stay in step with the extensions ROLE_BY_EXT gained in Task 1. This list is deliberately a
  # COPY rather than a reference, and the cost of that choice is exactly this: an extension added to
  # the model *after* this migration runs will never re-derive the rows already sitting in `other`,
  # and closing that needs a SECOND migration.
  #
  # `down` returns EVERY vector/cad_source row to "other", not only the rows `up` moved — it has no
  # record of which those were. That is exact only until the first attachment is created directly
  # with one of these roles, which `role_for` does at upload/attach time in four controllers; that
  # code is already live, so the window can close before `up` ever runs, not "once the UI ships".
  # Acceptable because the pair is self-healing: re-running `up` re-derives migrated and organic
  # rows identically, since the mapping is a pure function of the current filename.
  NEW_ROLE_BY_EXT = {
    "svg" => "vector", "dxf" => "vector", "lbrn2" => "vector",
    "scad" => "cad_source", "f3d" => "cad_source", "fcstd" => "cad_source",
    "sldprt" => "cad_source", "sldasm" => "cad_source"
  }.freeze

  class MigrationAttachment < ActiveRecord::Base
    self.table_name = "maker_file_attachments"
  end

  class MigrationNode < ActiveRecord::Base
    self.table_name = "nodes"
  end

  def up
    moved = 0
    MigrationAttachment.where(role: "other").find_each do |att|
      node = MigrationNode.find_by(user_id: att.user_id, node_id: att.node_id)
      next if node.nil? # attachment to a deleted/missing node — nothing to derive from
      ext = File.extname(node.name.to_s).downcase.delete(".")
      new_role = NEW_ROLE_BY_EXT[ext]
      next if new_role.nil?
      att.update_columns(role: new_role)
      moved += 1
    end
    say "re-derived #{moved} attachment role#{"s" unless moved == 1}"
  end

  def down
    MigrationAttachment.where(role: NEW_ROLE_BY_EXT.values.uniq).update_all(role: "other")
  end
end
