# EVERY TOOL CAN BE PINNED TO THE SIDEBAR, NOT ONLY THE CALCULATOR (2026-10-22). One ordered list
# replaces the one-tool flag: `[{"key" => "calculator"}, {"key" => "boxes", "title" => "Box Generator"}]`,
# read by Maker::ToolPins. Still a column on the user and not a table, for the reason the flag was:
# a display preference with no rows of its own to join, and it follows the maker to every device.
#
# `calculator_pinned` IS LEFT IN PLACE AND IGNORED BY User, NOT DROPPED HERE. It is live (every
# deploy since #458 carries it) and the container being replaced keeps serving while this one
# migrates, reading that column on every page's rail; dropping it in the same deploy would 500 the
# old container's pages for that window. A later migration drops it once no running code reads it.
class AddPinnedToolsToUsers < ActiveRecord::Migration[8.1]
  class MigrationUser < ActiveRecord::Base
    self.table_name = "users"
  end

  def up
    add_column :users, :pinned_tools, :json, null: false, default: []

    # A maker who pinned the calculator keeps it pinned.
    MigrationUser.reset_column_information
    MigrationUser.where(calculator_pinned: true).update_all(pinned_tools: [ { "key" => "calculator" } ])
  end

  def down
    remove_column :users, :pinned_tools
  end
end
