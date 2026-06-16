# The custom server-side Session model is replaced by Devise/Warden cookie sessions.
class DropSessions < ActiveRecord::Migration[8.1]
  def up
    drop_table :sessions, if_exists: true
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
