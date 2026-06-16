class CreateMakerPreviews < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_previews do |t|
      t.integer :user_id,    null: false
      t.string  :node_id,    null: false
      t.string  :version_id
      t.string  :kind,       null: false, default: "thumbnail"
      t.string  :status,     null: false, default: "pending"
      t.text    :error
      t.integer :width
      t.integer :height
      t.timestamps
    end
    # One preview per (user, node, version, kind) — regenerating updates in place.
    add_index :maker_previews, [ :user_id, :node_id, :version_id, :kind ],
              unique: true, name: "idx_maker_previews_unique"
    add_index :maker_previews, [ :user_id, :status ]
  end
end
