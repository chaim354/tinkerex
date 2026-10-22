# EACH maker_addon_files ROW SAYS WHICH SAVE LAST WROTE IT. A row means "this saved item produced
# that library file", and an item outlives a save: a revision that emits a differently-named file
# leaves the previous save's row in place (Maker::Addons::LibraryOutput#upsert_file!, because a save
# door must not delete user bytes). Until this column nothing on the row said which save it came
# from, so "this item's CURRENT outputs" was guessed with a (position, id) tiebreak, and at a tie
# that guess picked the stale row. `revision` is the item's `maker_addon_states.revision` at the save
# that last wrote the row, stamped by the one writer, `upsert_file!`, inside the save's transaction.
#
# `integer, null: false, default: 1` IS THE SHAPE OF `maker_addon_states.revision`, and 1 is every
# item's first save. IT IS NOT THE COUNT COLUMN CreateMakerAddonStateRevisions refuses: that would be
# a second copy of the item's number to keep in step, whereas this is a per-row fact the one writer
# sets once per save.
#
# NO INDEX. Every reader reaches these rows through `addon_state_id` (the unique
# [addon_state_id, node_id] index) and sorts the handful one item owns.
class AddRevisionToMakerAddonFiles < ActiveRecord::Migration[8.1]
  def up
    add_column :maker_addon_files, :revision, :integer, null: false, default: 1

    # BACKFILL: every existing row takes its item's CURRENT revision. Which save wrote a legacy row
    # cannot be recovered (that is the gap this column closes), so an item's legacy rows all tie and
    # keep today's (position, id) order among themselves; the order changes only for saves made after
    # this deploy. Written with the connection rather than the models, so a later change to
    # Maker::AddonFile cannot change what this migration did. A correlated UPDATE, valid on SQLite and
    # Postgres alike. `addon_state_id` is NOT NULL under a foreign key, so the subquery always finds
    # the item; were it ever empty, the NOT NULL column would refuse the NULL loudly.
    say_with_time "stamping existing addon files with their item's current revision" do
      execute(<<~SQL.squish)
        UPDATE maker_addon_files
        SET revision = (SELECT maker_addon_states.revision FROM maker_addon_states
                        WHERE maker_addon_states.id = maker_addon_files.addon_state_id)
      SQL
    end
  end

  def down
    remove_column :maker_addon_files, :revision
  end
end
