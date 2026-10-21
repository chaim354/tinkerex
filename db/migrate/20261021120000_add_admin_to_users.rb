# WHO MAY MANAGE ACCOUNTS (2026-10-21; docs/superpowers/specs/2026-10-21-admin-users-design.md).
# Until now "the first account is the owner" was true only in that it came first: nothing recorded
# it, and every account could do everything. Default false: an account is an admin only when a door
# says so (the sign-up form's first account, `tinkerex:owner`'s first, `tinkerex:admin`, Settings ->
# Users) or MarkOldestAccountAdmin backfills it.
class AddAdminToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :admin, :boolean, null: false, default: false
  end
end
