# Remove the pairing-code mechanism (replaced by device-login enrollment).
class DropDevicePairings < ActiveRecord::Migration[8.1]
  def up
    drop_table :device_pairings, if_exists: true
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
