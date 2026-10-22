# AN EXISTING DEPLOYMENT GETS ITS ADMIN WITHOUT A CONSOLE VISIT: the oldest account, the one the
# sign-up page called the owner. A no-op where any admin already exists, so a re-run never makes a
# second. A fresh install has no account when this runs (and a new database loads schema.rb, which
# runs no migration), so its first account is made admin by the door that creates it instead.
#
# THE DEMO ACCOUNT IS PASSED OVER (Tinkerex::Demo, read from DEMO_ACCOUNT_EMAIL as this runs): it can
# never manage accounts (User#can_manage_accounts?), so marking it would leave the server with no
# working admin. With no demo configured, `email <> ''` passes over nobody -- an email is never blank.
#
# RAW SQL, NOT the User model (a model drifts from the schema the migration saw), with the adapter's
# own spelling of true: 1 on SQLite, TRUE on Postgres.
class MarkOldestAccountAdmin < ActiveRecord::Migration[8.1]
  def up
    yes = connection.quoted_true
    demo = connection.quote(Tinkerex::Demo.email.to_s)
    execute <<~SQL.squish
      UPDATE users SET admin = #{yes}
      WHERE id = (SELECT MIN(id) FROM users WHERE email <> #{demo})
        AND NOT EXISTS (SELECT 1 FROM users WHERE admin = #{yes})
    SQL
  end

  # Nothing to undo: AddAdminToUsers's own rollback removes the column.
  def down; end
end
