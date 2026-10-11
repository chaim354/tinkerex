# frozen_string_literal: true

# THE CURRENT PROJECT'S TWO COLUMNS GO (structural redesign spec §9.1, slice 7). Slice 4 retired the
# concept — new files land in the folder the maker is looking at (FolderDestination), and nothing reads a
# destination from session or user state (test/architecture_invariants_test.rb) — and left these two
# `ignored_columns` for one release, so a deploy's old and new code never disagreed about a column
# mid-rollout. That release has shipped (#384, 2026-10-09).
#
# A DROP, ADDED — never a rewrite of 20260910120000_add_current_project_to_users.rb, which runs forward
# everywhere as it is (CLAUDE.md §10). REVERSIBLE, unlike the two table drops before it: their DDL lived
# in another repository, while these are one typed line each, and their values have been unread since
# slice 4. No `if_exists:` — every database reaching this ran the add, and a silent skip would hide a
# database that did not.
class DropRetiredCurrentProjectColumns < ActiveRecord::Migration[8.1]
  def change
    remove_column :users, :current_project_id, :bigint
    remove_column :users, :remember_current_project, :boolean, default: true, null: false
  end
end
