# Moves attachments that were "other" only because ROLE_BY_EXT had no entry for their extension
# into the `code` and `document` roles, for the 25 extensions the 2026-08-26 previews arc wired up
# (java kt swift cs php pl jl r jsx tsx vue svelte bat ps1 mk gradle asm s v vhd diff patch, and
# rst tex tsv). Those files answered `role_for -> "other"`, so they got no source viewer, no
# thumbnail and no filing.
#
# SELF-CONTAINED ON PURPOSE, as all four predecessors are
# (20260728124303_rederive_vector_and_cad_source_roles.rb,
# 20260729035422_rederive_document_roles.rb, 20260730153103_rederive_laser_roles.rb,
# 20260826130000_rederive_code_roles.rb). It does not call Maker::FileAttachment.role_for and does
# not use the app's models: a data migration runs against whatever the schema and the code look
# like months from now, and app code keeps moving.
#
# ITS `up` IS THE FIRST TWO'S SHAPE: every one of these 25 extensions mapped NOWHERE before, so
# every row needing repair sits in "other". Copy RederiveLaserRoles instead and `up` selects a role
# no row has and succeeds SILENTLY.
#
# ITS `down` IS THE ONE PLACE IT MUST NOT COPY ANY PREDECESSOR, AND THIS IS THE WHOLE REASON TO
# READ BEFORE EDITING. Each of the four introduced a role that DID NOT EXIST BEFORE IT RAN
# (`vector`, `cad_source`, `document`, `code`), so `where(role: NEW_ROLE).update_all(role: "other")`
# could only ever touch rows that migration itself had created — which is why every one of them is
# spelled that blunt way and says so in its own comment. THIS migration introduces no role at all:
# it adds extensions to `code` and `document`, both of which already hold every `.rb`, `.py`,
# `.txt` and `.md` in the library. The blunt spelling here would file ALL of them under "other" in
# a single statement and silently undo all four predecessors' work — a rollback that destroys data
# it never touched on the way in. So `down` re-derives from the node's extension exactly as `up`
# does, and only returns a row whose extension is in THIS migration's list.
class RederiveWidenedTextRoles < ActiveRecord::Migration[8.1]
  # A COPY rather than a reference, for the predecessors' stated reason — and with the same
  # accepted cost: an extension added to the model AFTER this runs never re-derives the rows
  # already sitting in "other", and closing that needs ANOTHER migration. Pinned against the model
  # by test/models/maker/rederive_widened_text_roles_migration_test.rb, which is the only thing
  # that would notice the copy drifting.
  NEW_ROLE_BY_EXT = {
    "java" => "code", "kt" => "code", "swift" => "code", "cs" => "code",
    "php" => "code", "pl" => "code", "jl" => "code", "r" => "code",
    "jsx" => "code", "tsx" => "code", "vue" => "code", "svelte" => "code",
    "bat" => "code", "ps1" => "code", "mk" => "code", "gradle" => "code",
    "asm" => "code", "s" => "code", "v" => "code", "vhd" => "code",
    "diff" => "code", "patch" => "code",
    "rst" => "document", "tex" => "document", "tsv" => "document"
  }.freeze

  # Where the rows come FROM and go back TO. Named once so `up` and `down` cannot disagree.
  PRIOR_ROLE = "other".freeze

  class MigrationAttachment < ActiveRecord::Base
    self.table_name = "maker_file_attachments"
  end

  class MigrationNode < ActiveRecord::Base
    self.table_name = "nodes"
  end

  def up
    moved = 0
    MigrationAttachment.where(role: PRIOR_ROLE).find_each do |att|
      new_role = NEW_ROLE_BY_EXT[extension_for(att)]
      next if new_role.nil?
      att.update_columns(role: new_role)
      moved += 1
    end
    say "re-derived #{moved} attachment role#{"s" unless moved == 1}"
  end

  def down
    returned = 0
    MigrationAttachment.where(role: NEW_ROLE_BY_EXT.values.uniq).find_each do |att|
      next unless NEW_ROLE_BY_EXT.key?(extension_for(att))
      att.update_columns(role: PRIOR_ROLE)
      returned += 1
    end
    say "returned #{returned} attachment role#{"s" unless returned == 1} to #{PRIOR_ROLE}"
  end

  private

  # node_id carries no FK and the filename lives on the node, so both directions have to join.
  # A missing node yields nil, which neither direction maps — an attachment to a deleted node has
  # nothing to derive from and is skipped rather than crashed on.
  def extension_for(att)
    node = MigrationNode.find_by(user_id: att.user_id, node_id: att.node_id)
    node && File.extname(node.name.to_s).downcase.delete(".")
  end
end
