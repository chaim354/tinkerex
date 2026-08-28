# The git-tracked-projects feature is reverted (tinkerex#161 -> tinkerex#178), and its two tables go
# with it. THIS IS A DROP RATHER THAN A DELETION OF THE CREATE-MIGRATIONS, which is the rule
# CLAUDE.md §10 already states for the retired sync-engine tables: adding a drop RUNS FORWARD
# EVERYWHERE, where rewriting history does not. The share deployment ran both creates and holds
# rows in `maker_git_repos`; removing only the create-migrations would leave that database carrying
# two tables no schema.rb mentions, and the next feature to mint a table by either name would fail
# with "table already exists" on that box alone.
#
# `if_exists: true` because the two audiences differ and both must work: a database that ran the
# creates has the tables, and a fresh one -- CI, a new self-host install -- never will, since the
# create-migrations are gone from this tree.
#
# IRREVERSIBLE ON PURPOSE. `down` cannot honestly recreate these: their definitions left with the
# revert, and a guessed CREATE TABLE that merely satisfied the migration would be a schema nobody
# wrote. tinkerex#178 will mint whatever it actually needs.
class DropRetiredGitTrackedProjectTables < ActiveRecord::Migration[8.1]
  def up
    drop_table :maker_version_previews, if_exists: true
    drop_table :maker_git_repos, if_exists: true
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          "the git-tracked-projects tables were reverted with their definitions; see tinkerex#178"
  end
end
