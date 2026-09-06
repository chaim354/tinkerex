class AddPublishingToUsersAndProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :handle, :string
    add_index  :users, :handle, unique: true

    add_column :maker_projects, :visibility, :string, null: false, default: "private"
    add_column :maker_projects, :unlisted_token, :string
    add_column :maker_projects, :license, :string
    add_index  :maker_projects, :unlisted_token, unique: true
    # /explore and /u/:handle read "public, newest first"; no existing index is a prefix of this
    # one and it is a prefix of none (test/architecture_invariants_test.rb's prefix guard).
    add_index  :maker_projects, %i[visibility updated_at]
  end
end
