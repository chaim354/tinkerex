class CreateMakerFileLinks < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_file_links do |t|
      t.integer :user_id, null: false
      # BARE NODE-ID STRINGS, NO FOREIGN KEY — the convention every maker table keeps (§14a).
      # `nodes.node_id` is a per-user string, a tombstone outlives its file, and a restore returns
      # the SAME id, which is the whole reason attachments, BOM lines and tags are keyed on it.
      t.string  :from_node_id, null: false
      t.string  :to_node_id,   null: false
      t.string  :kind,         null: false
      t.timestamps
    end

    # ONE PAIR PER KIND. Also the panel's `from` half: (user_id, from_node_id, …) is its leading
    # prefix, so `from_node_id = ?` seeks it.
    add_index :maker_file_links, %i[user_id from_node_id to_node_id kind],
              unique: true, name: "index_maker_file_links_uniqueness"
    # THE OTHER HALF OF FilesController#show's ONE query. Its OR asks about both columns and the
    # unique index above cannot serve `to_node_id` — its second column is `from_node_id`. Exactly
    # the pair maker_file_attachments carries for the same reason.
    #
    # AND DELIBERATELY NO BARE `user_id` INDEX: it would be a strict PREFIX of the unique index,
    # which test/architecture_invariants_test.rb refuses — every seek it answers, the wider one
    # answers too, and it would cost a btree write on every insert and delete for nothing.
    add_index :maker_file_links, %i[user_id to_node_id]
  end
end
