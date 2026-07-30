# Moves attachments that were "other" only because ROLE_BY_EXT had no entry for their extension
# into the `document` role added alongside this migration.
#
# SELF-CONTAINED ON PURPOSE, exactly as its predecessor
# (20260728124303_rederive_vector_and_cad_source_roles.rb) is. It does not call
# Maker::FileAttachment.role_for and does not use the app's models: a data migration runs against
# whatever the schema and the code look like months from now, and app code keeps moving.
class RederiveDocumentRoles < ActiveRecord::Migration[8.1]
  # Must stay in step with the extensions ROLE_BY_EXT gained for `document`. This list is
  # deliberately a COPY rather than a reference, and the cost is the same one the predecessor
  # records — and this migration EXISTS because of it: an extension added to the model after a
  # migration runs never re-derives rows already sitting in `other`, so closing that gap needs
  # ANOTHER migration. That is the accepted price of the self-contained style, not a defect of it.
  NEW_ROLE_BY_EXT = {
    "txt" => "document", "md" => "document", "markdown" => "document",
    "json" => "document", "csv" => "document"
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

  # Returns EVERY document row to "other", not only the rows `up` moved — it has no record of which
  # those were, and `role_for` is already live in four controllers, so organic `document` rows can
  # exist before `up` ever runs. Acceptable for the predecessor's reason: the pair is self-healing,
  # since the mapping is a pure function of the current filename.
  def down
    MigrationAttachment.where(role: NEW_ROLE_BY_EXT.values.uniq).update_all(role: "other")
  end
end
