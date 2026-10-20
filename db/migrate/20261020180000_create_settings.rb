# DEPLOYMENT-WIDE FACTS CHOSEN IN THE APP RATHER THAN IN THE ENVIRONMENT (K, 2026-10-20). One row per
# fact, keyed by name, because the next such fact should not need a migration of its own; the one key
# today is `library.root` (Tinkerex::LibraryRoot). An integer id beside a unique `key`, like every
# other table here, so the YAML fixture that confirms the test library needs nothing special.
#
# `users.library_scan_refusal` rides along: Library::ScanJob records an UnsafeScan's message there so
# /settings/library can show a refused folder change with its next step. A per-user stamp beside
# `library_scanned_at`, which is the same kind of fact.
class CreateSettings < ActiveRecord::Migration[8.1]
  def change
    create_table :settings do |t|
      t.string :key, null: false
      t.text :value, null: false, default: ""
      t.timestamps
    end
    add_index :settings, :key, unique: true

    add_column :users, :library_scan_refusal, :text
  end
end
