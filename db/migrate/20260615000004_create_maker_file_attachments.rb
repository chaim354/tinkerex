class CreateMakerFileAttachments < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_file_attachments do |t|
      t.integer :user_id, null: false
      t.string  :attachable_type, null: false
      t.integer :attachable_id, null: false
      t.string  :node_id, null: false
      t.string  :version_id
      t.string  :role, null: false, default: "other"
      t.string  :label
      t.integer :position, null: false, default: 0
      t.timestamps
    end
    add_index :maker_file_attachments, [ :user_id, :attachable_type, :attachable_id ],
              name: "index_maker_file_attachments_on_attachable"
    add_index :maker_file_attachments, [ :user_id, :node_id ]
  end
end
