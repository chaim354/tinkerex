# WHEN A LIBRARY SCAN LAST FINISHED, so Rescan can say so instead of guessing (stage 4, S4-3).
# NULL means "no scan has ever completed for this user", which is the state a fresh install and a
# chunk_remote deployment both sit in permanently — chunk_remote's catalog is a mirror of the sync
# server's changelog and no Library::ScanJob ever runs for it (§14b's `scannable`).
#
# NULLABLE, NO DEFAULT, NO INDEX. A default would claim a scan that never happened; the only reader
# is `current_user`, already loaded by the session, so there is nothing to index (and
# test/architecture_invariants_test.rb's prefix guard is about indexes, not columns).
class AddLibraryScannedAtToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :library_scanned_at, :datetime
  end
end
