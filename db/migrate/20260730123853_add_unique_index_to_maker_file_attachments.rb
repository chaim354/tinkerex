class AddUniqueIndexToMakerFileAttachments < ActiveRecord::Migration[8.1]
  # Attaching the same library file to the same project (or model) twice is meaningless, and the
  # application already refuses it — measured, two sequential POSTs create one row. What the app
  # check cannot cover is two CONCURRENT requests both passing it before either commits: a
  # double-clicked button, or a fetch() the browser retried. Hence a constraint.
  #
  # DEDUPE BEFORE CONSTRAINING. `add_index unique:` fails outright on a table that already
  # violates it, and this runs against deployed databases this branch cannot inspect (the
  # worktree's own dev DB is not even migrated). A migration that only works on a clean table is
  # a migration that fails in production.
  #
  # Raw SQL rather than the model, so this does not depend on app code that may have moved by the
  # time it runs on an old database — the convention the existing data migrations under
  # test/models/maker/*_migration_test.rb follow.
  #
  # THE KEY IS ALL FOUR COLUMNS. user_id because node_id is only unique per user (two users each
  # have their own "n1"); attachable_type because a polymorphic sibling — the same file on a
  # project AND on a model — is legitimate. A narrower index would reject real data, and the
  # accompanying test has a case for each of those two so a narrowing is caught.
  def up
    execute <<~SQL
      DELETE FROM maker_file_attachments
      WHERE id NOT IN (
        SELECT MIN(id) FROM maker_file_attachments
        GROUP BY user_id, attachable_type, attachable_id, node_id
      )
    SQL

    add_index :maker_file_attachments,
              %i[user_id attachable_type attachable_id node_id],
              unique: true,
              name: "index_maker_file_attachments_uniqueness"
  end

  # Reversible only in the index direction. The deleted duplicate rows are NOT restored, and
  # cannot be — nothing recorded which ids went. Stated rather than implied, because `down`
  # existing at all invites the reading that this migration is fully undoable.
  def down
    remove_index :maker_file_attachments, name: "index_maker_file_attachments_uniqueness"
  end
end
