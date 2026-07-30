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

ActiveRecord::Schema[8.1].define(version: 2026_07_30_123853) do
  create_table "action_text_rich_texts", force: :cascade do |t|
    t.text "body"
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.datetime "updated_at", null: false
    t.index ["record_type", "record_id", "name"], name: "index_action_text_rich_texts_uniqueness", unique: true
  end

  create_table "active_storage_attachments", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

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
    t.index ["user_id", "node_id", "incoming_version_id"], name: "index_conflicts_on_user_node_incoming", unique: true
    t.index ["user_id", "node_id"], name: "index_conflicts_on_user_id_and_node_id"
    t.index ["user_id", "resolved_at"], name: "index_conflicts_on_user_id_and_resolved_at"
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

  create_table "maker_addon_files", force: :cascade do |t|
    t.integer "addon_state_id", null: false
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "node_id", null: false
    t.integer "position", default: 0, null: false
    t.string "role", null: false
    t.datetime "updated_at", null: false
    t.index ["addon_state_id", "node_id"], name: "index_maker_addon_files_on_addon_state_id_and_node_id", unique: true
    t.index ["addon_state_id"], name: "index_maker_addon_files_on_addon_state_id"
  end

  create_table "maker_addon_states", force: :cascade do |t|
    t.string "addon_key", null: false
    t.datetime "created_at", null: false
    t.json "data", default: {}, null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["user_id", "addon_key"], name: "index_maker_addon_states_on_user_id_and_addon_key"
    t.index ["user_id"], name: "index_maker_addon_states_on_user_id"
  end

  create_table "maker_bom_lines", force: :cascade do |t|
    t.integer "bom_id", null: false
    t.datetime "created_at", null: false
    t.integer "inventory_item_id"
    t.string "node_id"
    t.text "notes"
    t.string "part_name"
    t.integer "position", default: 0, null: false
    t.decimal "quantity", precision: 12, scale: 3, default: "1.0", null: false
    t.string "reference"
    t.integer "supplier_id"
    t.string "unit", default: "each", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["user_id", "bom_id", "position"], name: "index_maker_bom_lines_on_bom_position"
    t.index ["user_id", "inventory_item_id"], name: "index_maker_bom_lines_on_user_id_and_inventory_item_id"
  end

  create_table "maker_boms", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", default: "BOM", null: false
    t.integer "project_id", null: false
    t.integer "revision", default: 1, null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["project_id", "revision"], name: "index_maker_boms_on_project_id_and_revision"
    t.index ["user_id", "project_id"], name: "index_maker_boms_on_user_id_and_project_id"
  end

  create_table "maker_build_log_entries", force: :cascade do |t|
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
    t.index ["user_id", "attachable_type", "attachable_id", "node_id"], name: "index_maker_file_attachments_uniqueness", unique: true
    t.index ["user_id", "attachable_type", "attachable_id"], name: "index_maker_file_attachments_on_attachable"
    t.index ["user_id", "node_id"], name: "index_maker_file_attachments_on_user_id_and_node_id"
  end

  create_table "maker_inventory_items", force: :cascade do |t|
    t.string "category"
    t.datetime "created_at", null: false
    t.integer "location_id"
    t.decimal "min_quantity", precision: 12, scale: 3, default: "0.0", null: false
    t.string "name", null: false
    t.text "notes"
    t.string "part_number"
    t.decimal "quantity_cached", precision: 12, scale: 3, default: "0.0", null: false
    t.integer "supplier_id"
    t.string "unit", default: "each", null: false
    t.decimal "unit_cost", precision: 12, scale: 4
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["user_id", "category"], name: "index_maker_inventory_items_on_user_id_and_category"
    t.index ["user_id", "location_id"], name: "index_maker_inventory_items_on_user_id_and_location_id"
    t.index ["user_id", "name"], name: "index_maker_inventory_items_on_user_id_and_name"
    t.index ["user_id", "supplier_id"], name: "index_maker_inventory_items_on_user_id_and_supplier_id"
  end

  create_table "maker_inventory_transactions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.decimal "delta", precision: 12, scale: 3, null: false
    t.integer "inventory_item_id", null: false
    t.text "note"
    t.integer "project_id"
    t.string "reason", default: "adjusted", null: false
    t.integer "user_id", null: false
    t.index ["user_id", "inventory_item_id", "created_at"], name: "index_maker_inventory_transactions_on_item_created_at"
    t.index ["user_id", "project_id"], name: "index_maker_inventory_transactions_on_user_id_and_project_id"
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

  create_table "maker_locations", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.string "name", null: false
    t.integer "parent_id"
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["user_id", "name"], name: "index_maker_locations_on_user_id_and_name"
    t.index ["user_id", "parent_id"], name: "index_maker_locations_on_user_id_and_parent_id"
  end

  create_table "maker_models", force: :cascade do |t|
    t.string "cover_node_id"
    t.datetime "created_at", null: false
    t.string "designer"
    t.string "folder_node_id"
    t.string "license"
    t.text "notes"
    t.json "print_settings"
    t.string "print_status", default: "want_to_print", null: false
    t.string "slug", null: false
    t.string "source_url"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["user_id", "print_status"], name: "index_maker_models_on_user_id_and_print_status"
    t.index ["user_id", "slug"], name: "index_maker_models_on_user_id_and_slug", unique: true
  end

  create_table "maker_notes", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "node_id", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["user_id", "node_id"], name: "index_maker_notes_on_user_id_and_node_id"
  end

  create_table "maker_previews", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "error"
    t.integer "height"
    t.string "kind", default: "thumbnail", null: false
    t.json "metadata"
    t.string "node_id", null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.string "version_id"
    t.integer "width"
    t.index ["user_id", "node_id", "kind"], name: "idx_maker_previews_unique", unique: true
    t.index ["user_id", "status"], name: "index_maker_previews_on_user_id_and_status"
  end

  create_table "maker_print_runs", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.decimal "duration_hours", precision: 6, scale: 2
    t.integer "filament_grams"
    t.string "material"
    t.integer "model_id", null: false
    t.text "notes"
    t.string "outcome", null: false
    t.date "printed_on", null: false
    t.string "printer"
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["model_id", "printed_on"], name: "index_maker_print_runs_on_model_id_and_printed_on"
    t.index ["user_id"], name: "index_maker_print_runs_on_user_id"
  end

  create_table "maker_projects", force: :cascade do |t|
    t.datetime "archived_at"
    t.datetime "created_at", null: false
    t.text "description"
    t.string "folder_node_id"
    t.string "name", null: false
    t.string "slug", null: false
    t.string "status", default: "planning", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["user_id", "slug"], name: "index_maker_projects_on_user_id_and_slug", unique: true
    t.index ["user_id", "status"], name: "index_maker_projects_on_user_id_and_status"
  end

  create_table "maker_sheets", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.json "data"
    t.string "name", null: false
    t.integer "position", default: 0, null: false
    t.integer "project_id", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["user_id", "project_id", "position"], name: "index_maker_sheets_on_project_position"
  end

  create_table "maker_suppliers", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.text "notes"
    t.datetime "updated_at", null: false
    t.string "url"
    t.integer "user_id", null: false
    t.index ["user_id", "name"], name: "index_maker_suppliers_on_user_id_and_name"
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
    t.string "content_hash"
    t.datetime "created_at", null: false
    t.string "current_version_id"
    t.boolean "deleted", default: false, null: false
    t.string "kind", null: false
    t.integer "mode"
    t.bigint "mtime"
    t.string "name", null: false
    t.string "node_id", null: false
    t.string "parent_node_id"
    t.bigint "size"
    t.string "storage_path"
    t.binary "symlink_target"
    t.datetime "updated_at", null: false
    t.bigint "updated_seq", default: 0, null: false
    t.integer "user_id", null: false
    t.index ["user_id", "content_hash"], name: "index_nodes_on_user_id_and_content_hash"
    t.index ["user_id", "node_id"], name: "index_nodes_on_user_id_and_node_id", unique: true
    t.index ["user_id", "parent_node_id"], name: "index_nodes_on_user_id_and_parent_node_id"
    t.index ["user_id", "storage_path"], name: "index_nodes_on_user_id_and_storage_path", unique: true, where: "deleted = false"
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

  create_table "share_links", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at"
    t.string "manifest_id", null: false
    t.string "node_id", null: false
    t.datetime "revoked_at"
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.string "version_id", null: false
    t.index ["token_digest"], name: "index_share_links_on_token_digest", unique: true
    t.index ["user_id", "version_id"], name: "index_share_links_on_user_id_and_version_id"
    t.index ["user_id"], name: "index_share_links_on_user_id"
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
    t.string "confirmation_token"
    t.datetime "confirmed_at"
    t.datetime "created_at", null: false
    t.datetime "current_sign_in_at"
    t.string "current_sign_in_ip"
    t.string "email", null: false
    t.string "encrypted_password", default: "", null: false
    t.integer "failed_attempts", default: 0, null: false
    t.bigint "head_seq", default: 0, null: false
    t.datetime "last_sign_in_at"
    t.string "last_sign_in_ip"
    t.datetime "locked_at"
    t.datetime "remember_created_at"
    t.datetime "reset_password_sent_at"
    t.string "reset_password_token"
    t.integer "sign_in_count", default: 0, null: false
    t.string "unconfirmed_email"
    t.string "unlock_token"
    t.datetime "updated_at", null: false
    t.index ["confirmation_token"], name: "index_users_on_confirmation_token", unique: true
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
    t.index ["unlock_token"], name: "index_users_on_unlock_token", unique: true
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

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "changelog_entries", "users"
  add_foreign_key "chunks", "users"
  add_foreign_key "devices", "users"
  add_foreign_key "maker_addon_files", "maker_addon_states", column: "addon_state_id"
  add_foreign_key "maker_addon_states", "users"
  add_foreign_key "manifest_chunks", "users"
  add_foreign_key "nodes", "users"
  add_foreign_key "pending_commits", "users"
  add_foreign_key "share_links", "users"
  add_foreign_key "user_identities", "users"
  add_foreign_key "versions", "users"
end
