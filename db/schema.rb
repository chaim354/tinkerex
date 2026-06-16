# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_06_15_000009) do
  create_table "changelog_entries", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "node_id", null: false
    t.string "op", null: false
    t.bigint "seq", null: false
    t.integer "user_id", null: false
    t.string "version_id"
    t.index ["user_id", "seq"], name: "index_changelog_entries_on_user_id_and_seq", unique: true
    t.index ["user_id"], name: "index_changelog_entries_on_user_id"
  end

  create_table "chunks", force: :cascade do |t|
    t.string "chunk_hash", null: false
    t.datetime "created_at", null: false
    t.integer "refcount", default: 0, null: false
    t.bigint "size", default: 0, null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["user_id", "chunk_hash"], name: "index_chunks_on_user_id_and_chunk_hash", unique: true
    t.index ["user_id", "refcount"], name: "index_chunks_on_user_id_and_refcount"
    t.index ["user_id"], name: "index_chunks_on_user_id"
  end

  create_table "conflicts", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "current_version_id", null: false
    t.string "incoming_version_id", null: false
    t.string "node_id", null: false
    t.datetime "resolved_at"
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["user_id", "node_id"], name: "index_conflicts_on_user_id_and_node_id"
    t.index ["user_id", "resolved_at"], name: "index_conflicts_on_user_id_and_resolved_at"
  end

  create_table "device_pairings", force: :cascade do |t|
    t.datetime "claimed_at"
    t.string "code_digest", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["user_id", "code_digest"], name: "index_device_pairings_on_user_id_and_code_digest", unique: true
    t.index ["user_id", "expires_at"], name: "index_device_pairings_on_user_id_and_expires_at"
  end

  create_table "devices", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "last_seen_at"
    t.string "name", default: "device", null: false
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["token_digest"], name: "index_devices_on_token_digest", unique: true
    t.index ["user_id"], name: "index_devices_on_user_id"
  end

  create_table "file_locks", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "device_id", null: false
    t.datetime "expires_at", null: false
    t.string "node_id", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["user_id", "expires_at"], name: "index_file_locks_on_user_id_and_expires_at"
    t.index ["user_id", "node_id"], name: "index_file_locks_on_user_id_and_node_id", unique: true
  end

  create_table "maker_build_log_entries", force: :cascade do |t|
    t.text "body", null: false
    t.datetime "created_at", null: false
    t.string "entry_type", default: "note", null: false
    t.datetime "logged_at", null: false
    t.integer "project_id", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["user_id", "project_id", "logged_at"], name: "index_maker_build_log_entries_on_project_logged_at"
  end

  create_table "maker_collection_items", force: :cascade do |t|
    t.integer "collection_id", null: false
    t.datetime "created_at", null: false
    t.integer "item_id", null: false
    t.integer "position", default: 0, null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["collection_id", "item_id"], name: "index_maker_collection_items_unique", unique: true
    t.index ["user_id", "collection_id", "position"], name: "index_maker_collection_items_on_position"
  end

  create_table "maker_collections", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["user_id", "name"], name: "index_maker_collections_on_user_id_and_name"
  end

  create_table "maker_file_attachments", force: :cascade do |t|
    t.integer "attachable_id", null: false
    t.string "attachable_type", null: false
    t.datetime "created_at", null: false
    t.string "label"
    t.string "node_id", null: false
    t.integer "position", default: 0, null: false
    t.string "role", default: "other", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.string "version_id"
    t.index ["user_id", "attachable_type", "attachable_id"], name: "index_maker_file_attachments_on_attachable"
    t.index ["user_id", "node_id"], name: "index_maker_file_attachments_on_user_id_and_node_id"
  end

  create_table "maker_items", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.boolean "favorited", default: false, null: false
    t.text "instructions"
    t.string "item_type", default: "other", null: false
    t.string "origin", default: "downloaded", null: false
    t.string "primary_node_id"
    t.string "source_name"
    t.string "source_url"
    t.string "summary"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["user_id", "favorited"], name: "index_maker_items_on_user_id_and_favorited"
    t.index ["user_id", "item_type"], name: "index_maker_items_on_user_id_and_item_type"
    t.index ["user_id", "title"], name: "index_maker_items_on_user_id_and_title"
  end

  create_table "maker_projects", force: :cascade do |t|
    t.datetime "archived_at"
    t.datetime "created_at", null: false
    t.text "description"
    t.string "name", null: false
    t.string "slug", null: false
    t.string "status", default: "planning", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["user_id", "slug"], name: "index_maker_projects_on_user_id_and_slug", unique: true
    t.index ["user_id", "status"], name: "index_maker_projects_on_user_id_and_status"
  end

  create_table "maker_taggings", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "tag_id", null: false
    t.integer "taggable_id", null: false
    t.string "taggable_type", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["tag_id", "taggable_type", "taggable_id"], name: "index_maker_taggings_unique", unique: true
    t.index ["user_id", "taggable_type", "taggable_id"], name: "index_maker_taggings_on_taggable"
  end

  create_table "maker_tags", force: :cascade do |t|
    t.string "color"
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["user_id", "name"], name: "index_maker_tags_on_user_id_and_name", unique: true
  end

  create_table "maker_tasks", force: :cascade do |t|
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.text "notes"
    t.integer "position", default: 0, null: false
    t.string "status", default: "todo", null: false
    t.integer "taskable_id"
    t.string "taskable_type"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["user_id", "status"], name: "index_maker_tasks_on_user_id_and_status"
    t.index ["user_id", "taskable_type", "taskable_id"], name: "index_maker_tasks_on_taskable"
  end

  create_table "manifest_chunks", force: :cascade do |t|
    t.string "chunk_hash", null: false
    t.bigint "length", null: false
    t.string "manifest_id", null: false
    t.bigint "offset", null: false
    t.integer "seq", null: false
    t.integer "user_id", null: false
    t.index ["user_id", "manifest_id", "seq"], name: "index_manifest_chunks_on_user_id_and_manifest_id_and_seq", unique: true
    t.index ["user_id"], name: "index_manifest_chunks_on_user_id"
  end

  create_table "nodes", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "current_version_id"
    t.boolean "deleted", default: false, null: false
    t.string "kind", null: false
    t.integer "mode"
    t.bigint "mtime"
    t.string "name", null: false
    t.string "node_id", null: false
    t.string "parent_node_id"
    t.datetime "updated_at", null: false
    t.bigint "updated_seq", default: 0, null: false
    t.integer "user_id", null: false
    t.index ["user_id", "node_id"], name: "index_nodes_on_user_id_and_node_id", unique: true
    t.index ["user_id", "parent_node_id"], name: "index_nodes_on_user_id_and_parent_node_id"
    t.index ["user_id", "updated_seq"], name: "index_nodes_on_user_id_and_updated_seq"
    t.index ["user_id"], name: "index_nodes_on_user_id"
  end

  create_table "pending_commits", force: :cascade do |t|
    t.string "base_version_id"
    t.string "commit_id", null: false
    t.datetime "created_at", null: false
    t.bigint "device_id"
    t.string "manifest_id", null: false
    t.text "manifest_json", null: false
    t.integer "mode"
    t.bigint "mtime"
    t.string "name", null: false
    t.string "node_id", null: false
    t.string "parent_node_id"
    t.bigint "size", default: 0, null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["user_id", "commit_id"], name: "index_pending_commits_on_user_id_and_commit_id", unique: true
    t.index ["user_id"], name: "index_pending_commits_on_user_id"
  end

  create_table "sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.integer "user_id", null: false
    t.index ["token_digest"], name: "index_sessions_on_token_digest", unique: true
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "user_identities", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "provider", null: false
    t.string "uid", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["provider", "uid"], name: "index_user_identities_on_provider_and_uid", unique: true
    t.index ["user_id"], name: "index_user_identities_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "confirmation_sent_at"
    t.string "confirmation_token_digest"
    t.datetime "confirmed_at"
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.bigint "head_seq", default: 0, null: false
    t.string "password_digest"
    t.datetime "reset_sent_at"
    t.string "reset_token_digest"
    t.datetime "updated_at", null: false
    t.index ["confirmation_token_digest"], name: "index_users_on_confirmation_token_digest", unique: true
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["reset_token_digest"], name: "index_users_on_reset_token_digest", unique: true
  end

  create_table "versions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "device_id"
    t.string "manifest_id", null: false
    t.string "node_id", null: false
    t.string "parent_version_id"
    t.boolean "pinned", default: false, null: false
    t.bigint "size", default: 0, null: false
    t.integer "user_id", null: false
    t.string "version_id", null: false
    t.index ["user_id", "node_id", "id"], name: "index_versions_on_user_id_and_node_id_and_id"
    t.index ["user_id", "version_id"], name: "index_versions_on_user_id_and_version_id", unique: true
    t.index ["user_id"], name: "index_versions_on_user_id"
  end

  add_foreign_key "changelog_entries", "users"
  add_foreign_key "chunks", "users"
  add_foreign_key "devices", "users"
  add_foreign_key "manifest_chunks", "users"
  add_foreign_key "nodes", "users"
  add_foreign_key "pending_commits", "users"
  add_foreign_key "sessions", "users"
  add_foreign_key "user_identities", "users"
  add_foreign_key "versions", "users"
end
