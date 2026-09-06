class CreateMakerReleases < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_releases do |t|
      t.references :user, null: false, foreign_key: true, index: false
      t.references :project, null: false, index: false
      t.string   :version, null: false
      t.string   :git_tag
      t.string   :git_oid
      t.string   :repo_node_id
      t.references :bom, null: true, index: false
      t.integer  :bom_revision
      t.datetime :published_at, null: false
      t.timestamps
    end
    # One version per project; the panel and the public page read "newest first" by project.
    # Neither index is a prefix of the other (test/architecture_invariants_test.rb's prefix guard).
    add_index :maker_releases, %i[user_id project_id version], unique: true
    add_index :maker_releases, %i[project_id published_at]

    create_table :maker_release_files do |t|
      t.references :user, null: false, foreign_key: true, index: false
      t.references :release, null: false, index: false
      t.string  :node_id, null: false
      t.string  :name, null: false
      t.string  :path
      t.string  :content_token
      t.bigint  :size
      t.timestamps
    end
    add_index :maker_release_files, %i[release_id node_id], unique: true
    add_index :maker_release_files, %i[user_id node_id]
  end
end
