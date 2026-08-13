# One immutable snapshot of a saved addon state's params. A state is ONE saved thing (a box, a
# drawing); a revision is what its params were at one save.
#
# NO `updated_at` — but that column's ABSENCE is not what makes a snapshot immutable, and this
# comment used to claim it was. It doesn't: nothing about a missing column stops an `UPDATE`
# statement. The actual enforcement is `attr_readonly` on `Maker::AddonStateRevision`, one layer up
# — see that model for what it does and does not catch. Omitting `t.timestamps` here is narrower:
# it means there is no `updated_at` for a write that DOES get through one of the doors
# `attr_readonly` cannot cover (a relation-level `update_all`, raw SQL) to bump — nothing making a
# bypassed edit look like an ordinary, sanctioned save.
#
# `maker_addon_states.revision` IS THE CURRENT NUMBER AND THERE IS NO COUNT COLUMN: nothing deletes
# a revision, so the count equals the current number. Add a count column with the deletion, not
# before — two values to keep in step, for no present reader, is how they drift.
class CreateMakerAddonStateRevisions < ActiveRecord::Migration[8.1]
  def up
    create_table :maker_addon_state_revisions do |t|
      t.references :addon_state, null: false, foreign_key: { to_table: :maker_addon_states }
      t.integer :revision, null: false
      t.json :data, null: false, default: {}
      t.datetime :created_at, null: false
    end
    add_index :maker_addon_state_revisions, [ :addon_state_id, :revision ], unique: true,
              name: "index_maker_addon_state_revisions_on_state_and_revision"

    add_column :maker_addon_states, :revision, :integer, null: false, default: 1

    # BACKFILL: every existing state comes out of this migration with a coherent one-entry history
    # rather than an empty one. `created_at` is the STATE's own, not now() — the snapshot describes
    # a save that happened then. Written with the connection rather than the model so a later change
    # to Maker::AddonState cannot change what this migration did.
    say_with_time "backfilling revision 1 for existing addon states" do
      execute(<<~SQL.squish)
        INSERT INTO maker_addon_state_revisions (addon_state_id, revision, data, created_at)
        SELECT id, 1, data, created_at FROM maker_addon_states
      SQL
    end
  end

  def down
    remove_column :maker_addon_states, :revision
    drop_table :maker_addon_state_revisions
  end
end
