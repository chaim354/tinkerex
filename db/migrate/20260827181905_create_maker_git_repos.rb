# ONE ROW PER PROJECT, ENFORCED BY A UNIQUE INDEX RATHER THAN BY CONVENTION. Two rows would let
# two workers each believe they hold the head, and neither would be wrong about its own row.
#
# NO `user_id`, WHICH IS DELIBERATE AND MATCHES THE ONLY OTHER SHAPE LIKE IT IN THIS SCHEMA.
# Every user-scoped maker table carries `user_id`; the two that do not -- `maker_addon_files` and
# `maker_addon_state_revisions` -- are the two that hang off a parent through a REAL foreign key,
# taking their tenancy from it. This is that shape: a repo belongs to a project, and a project
# belongs to a user. A `user_id` here would be a second answer to "whose is this".
#
# THE FOREIGN KEY IS NOT WHAT tinkerex#152 WEIGHED. That issue is about RETROFITTING constraints
# onto 34 populated columns -- an orphan census it did not have, and a full SQLite table rebuild
# per table on a live box. A brand-new empty table has neither cost, and `t.references ...
# foreign_key:` is what both existing maker child tables already do.
#
# `on_delete: :cascade` RATHER THAN A `dependent:` ON Maker::Project, and it is the one place this
# table departs from those two. A row here is bookkeeping ABOUT a project and means nothing without
# it, so the delete-time protection tinkerex#152 argues for -- the one that also covers
# `delete_all`, a console `destroy_all` and a raw-SQL data migration, none of which run a callback
# -- costs nothing on an empty table. It DELETES THE ROW, NEVER THE REPOSITORY: the `.git`
# directory is in the library and this row was only ever an index into it.
class CreateMakerGitRepos < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_git_repos do |t|
      t.references :project, null: false, index: { unique: true },
                             foreign_key: { to_table: :maker_projects, on_delete: :cascade }
      # BOOKKEEPING, NOT TRUTH. The authoritative head is the repo's own refs/heads/main; these
      # two are a cache so the UI and the intake sweep need not hydrate to ask "is there a repo,
      # and roughly where is its head" -- which on s3 is real billed requests. Both nullable: a
      # row may legitimately exist before the first commit.
      t.string   :head_oid
      t.datetime :last_commit_at
      t.timestamps
    end
  end
end
