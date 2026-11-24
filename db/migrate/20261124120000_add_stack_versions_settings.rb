# VERSION STACKS AS A SETTING (2026-11-24; docs/superpowers/specs/2026-11-24-project-panel-click-through-design.md).
# The account's master default is ON for everyone, existing and new, so no account-creation door has
# to set it. A project's own choice is NULL until the maker makes one, and NULL means "follow mine".
class AddStackVersionsSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :stack_versions, :boolean, default: true, null: false
    add_column :maker_projects, :stack_versions, :boolean
  end
end
