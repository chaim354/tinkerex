class CreateMakerRepoEdits < ActiveRecord::Migration[8.1]
  # One row per file edited through tinkerex and not yet committed.
  #
  # NO PATH COLUMN, DELIBERATELY. The catalog is the one source and the path is recomputed on read
  # via Maker::LibraryTree#path_for. A stored path would let this table disagree with the library
  # the moment a node moved, with no way to tell which was right.
  #
  # `node_id` AND `repo_root_node_id` ARE BARE STRINGS WITH NO FOREIGN KEY, the same shape and the
  # same population as maker_file_attachments. Reconciliation when the commit box opens is the
  # correctness mechanism (spec part 6 step 5); Maker::AttachmentReaper's precedent covers rows
  # whose node is gone for good.
  def change
    create_table :maker_repo_edits do |t|
      # `index: false` BECAUSE BOTH INDEXES BELOW ALREADY LEAD WITH `user_id`, and the bare one
      # t.references mints by default is a strict prefix of each -- redundant on reads, a btree
      # write on every insert and update. test/architecture_invariants_test.rb refuses it (that is
      # how ten of them accumulated before 20260819120000_drop_redundant_prefix_indexes); the
      # exemption it offers needs a production-scale measurement, and there is none to make here.
      t.references :user, null: false, foreign_key: true, index: false
      t.string :repo_root_node_id, null: false
      t.string :node_id, null: false
      t.timestamps
    end

    add_index :maker_repo_edits, %i[user_id node_id], unique: true
    add_index :maker_repo_edits, %i[user_id repo_root_node_id]
  end
end
