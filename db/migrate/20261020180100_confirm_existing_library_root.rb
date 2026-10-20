# AN EXISTING DEPLOYMENT HAS BEEN USING THE WHOLE MOUNT ALL ALONG, SO IT IS CONFIRMED BY CONSTRUCTION
# (K §2). With any account present, write `library.root = ""` -- the whole mount, today's behaviour --
# so its scans never pause and nobody is sent to a first-run screen. A fresh install has no account
# when this runs (and a brand-new database loads schema.rb, which runs no migration at all), so its
# row stays absent and the first-run screen is pending. s3 and chunk_remote deployments get the row
# too, harmlessly: Tinkerex::LibraryRoot.pending? is false there whatever it says.
#
# RAW SQL, NOT the Setting model: a model used in a migration drifts from the schema the migration
# saw. Quoted identifiers, because `key` and `value` are keywords to some dialects. Idempotent on the
# NOT EXISTS, so a re-run never fails on the unique index.
class ConfirmExistingLibraryRoot < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL.squish
      INSERT INTO settings ("key", "value", created_at, updated_at)
      SELECT 'library.root', '', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      WHERE EXISTS (SELECT 1 FROM users)
        AND NOT EXISTS (SELECT 1 FROM settings WHERE "key" = 'library.root')
    SQL
  end

  # Nothing to undo: deleting the row would send a running deployment to the first-run screen.
  def down; end
end
