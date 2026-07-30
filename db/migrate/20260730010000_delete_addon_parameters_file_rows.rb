# The `.params.json` file is no longer part of an addon bundle: `Maker::AddonState#data` is the
# record, nothing ever read the file back, and `Tools::AddonParamsController` serves it as a download
# for anyone who wants it outside the app. This drops the JOIN ROWS for the files already written, so
# the show pages stop listing a file the addon no longer produces.
#
# THE FILES THEMSELVES ARE LEFT ALONE, deliberately. They are ordinary library files the user may
# have renamed, organized, or attached to a project, and a migration must not delete user bytes.
# What survives, all of it intended:
#   - a params file attached to a project keeps its `Maker::FileAttachment` (a separate record), so it
#     stays visible in the project panel — it just stops being part of the addon BUNDLE;
#   - its `Maker::Preview` rows stay valid, because the node still exists (the preview reaper only
#     reaps previews whose node is gone);
#   - the file name embeds the state id, so it is still traceable by hand.
#
# Raw SQL, not `Maker::AddonFile.where(...).delete_all`: a migration is history and must not depend on
# a model that may later change or disappear. Valid on both SQLite and Postgres (§15: adapter-agnostic).
class DeleteAddonParametersFileRows < ActiveRecord::Migration[8.1]
  def up
    execute "DELETE FROM maker_addon_files WHERE role = 'parameters'"
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
