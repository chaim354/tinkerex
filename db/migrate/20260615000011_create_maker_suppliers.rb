class CreateMakerSuppliers < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_suppliers do |t|
      t.integer :user_id, null: false
      t.string  :name, null: false
      t.string  :url
      t.text    :notes
      t.timestamps
    end
    add_index :maker_suppliers, [ :user_id, :name ]
  end
end
