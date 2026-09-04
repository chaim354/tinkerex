require "test_helper"

# DESTROYING A USER MUST EMPTY EVERY TABLE THAT CARRIES THEIR user_id — the guard tinkerex#152
# found missing. Tenant cleanup rests entirely on hand-written `dependent:` lines in
# app/models/user.rb; nothing asserted that set was COMPLETE. It is complete today. The failure
# this exists to catch is table 27: a new user-scoped table added with no cleanup, which is
# invisible until someone deletes an account and the rows outlive it.
#
# WHY NOT A DATABASE FOREIGN KEY. tinkerex#152 weighed `add_foreign_key ... on_delete: :cascade`
# on all 26 and did not take it — see that issue for the argument (the deciding orphan census on
# the three live deployments was never run, and Rails implements add_foreign_key on SQLite by
# REBUILDING the table, which is a full copy per table on a live self-host box). A constraint would
# also be the wrong instrument for the one shape that actually hurt a user: tinkerex#74's
# `InventoryItem#release_bom_lines` copies the item's name into the BOM line BEFORE dropping the
# pointer, which no `ON DELETE` action can do. This test is the floor that was actually missing.
#
# THE REGISTRY IS THE POINT, NOT THE ASSERTIONS. TABLES is derived from the live schema, so a new
# user-scoped table appears here the moment it is migrated, and the `missing builders` assertion
# fails until someone decides what its cleanup is. A hand-maintained list of tables would simply
# not mention table 27 and would go on passing — the shape §14e warns about, where a guard whose
# subject is a set silently stops covering what it was written for.
class TenantCleanupTest < ActiveSupport::TestCase
  # Every table with a user_id column, read from the connection rather than listed. Excludes
  # tables in the queue/cache/cable databases, which are not user-scoped and not in this schema.
  TABLES = ActiveRecord::Base.connection.tables.select { |t|
    ActiveRecord::Base.connection.columns(t).any? { |c| c.name == "user_id" }
  }.sort.freeze

  # One row per table, built for the user under test. Fiddly on purpose: a builder that cannot
  # produce a row is a table whose cleanup nobody can demonstrate.
  #
  # `nodes` rows are built directly rather than through FileLayer — this test is about
  # `dependent:`, not about the port, and going through an adapter would make it need a real
  # library on each of the three backend legs.
  BUILDERS = {
    "devices" => ->(u) { u.devices.create!(name: "d", token_digest: SecureRandom.hex(16)) },

    "nodes" => ->(u) {
      u.nodes.create!(node_id: SecureRandom.uuid, name: "f.stl", kind: "file",
                      storage_path: "f-#{SecureRandom.hex(4)}.stl")
    },

    "remote_manifest_chunks" => ->(u) {
      u.remote_manifest_chunks.create!(version_id: SecureRandom.uuid, seq: 0,
                                       chunk_hash: SecureRandom.hex(32), offset: 0, length: 10)
    },

    "user_identities" => ->(u) {
      u.identities.create!(provider: "developer", uid: SecureRandom.hex(8))
    },

    "maker_items" => ->(u) { u.maker_items.create!(title: "Bracket") },
    "maker_models" => ->(u) { u.maker_models.create!(title: "Benchy") },
    "maker_tags" => ->(u) { u.maker_tags.create!(name: "brackets") },
    "maker_projects" => ->(u) { u.maker_projects.create!(name: "Lamp") },
    "maker_locations" => ->(u) { u.maker_locations.create!(name: "Shelf A") },
    "maker_suppliers" => ->(u) { u.maker_suppliers.create!(name: "Digikey") },
    "maker_filing_rules" => ->(u) { u.maker_filing_rules.create!(ext: "stl", folder: "models") },
    "maker_collections" => ->(u) { u.maker_collections.create!(name: "Favourites") },
    "maker_shelves" => ->(u) { u.maker_shelves.create!(path: "Models") },
    "maker_notes" => ->(u) { u.maker_notes.create!(node_id: SecureRandom.uuid, body: "note") },
    "maker_tasks" => ->(u) { u.maker_tasks.create!(title: "Sand it") },

    "maker_previews" => ->(u) {
      u.maker_previews.create!(node_id: SecureRandom.uuid, kind: "thumbnail")
    },

    "maker_addon_states" => ->(u) {
      u.maker_addon_states.create!(addon_key: "boxes", name: "box-1", data: {})
    },

    "maker_print_runs" => ->(u) {
      u.maker_models.first.print_runs.create!(user: u, outcome: "success", printed_on: Date.current)
    },

    "maker_taggings" => ->(u) {
      u.maker_taggings.create!(tag: u.maker_tags.first, taggable: u.maker_items.first)
    },

    "maker_repo_edits" => ->(u) {
      u.maker_repo_edits.create!(repo_root_node_id: SecureRandom.uuid, node_id: SecureRandom.uuid)
    },

    "maker_file_attachments" => ->(u) {
      u.maker_file_attachments.create!(attachable: u.maker_items.first,
                                       node_id: SecureRandom.uuid, role: "model")
    },

    "maker_collection_items" => ->(u) {
      u.maker_collections.first.collection_items.create!(user: u, item: u.maker_items.first)
    },

    "maker_build_log_entries" => ->(u) {
      u.maker_projects.first.build_log_entries.create!(user: u, entry_type: "note",
                                                       body: "did a thing")
    },

    "maker_sheets" => ->(u) {
      u.maker_projects.first.sheets.create!(user: u, name: "Cut list")
    },

    "maker_boms" => ->(u) { u.maker_projects.first.boms.create!(user: u) },

    "maker_inventory_items" => ->(u) {
      u.maker_inventory_items.create!(name: "M3 bolt", supplier: u.maker_suppliers.first,
                                      location: u.maker_locations.first)
    },

    "maker_inventory_transactions" => ->(u) {
      u.maker_inventory_items.first.transactions.create!(user: u, delta: 5, reason: "adjusted")
    },

    "maker_bom_lines" => ->(u) {
      u.maker_boms.first.lines.create!(user: u, part_name: "M3 bolt", quantity: 4)
    }
  }.freeze

  # The builders above reference each other's rows (a tagging needs a tag and an item), so they
  # run in dependency order rather than in TABLES order.
  BUILD_ORDER = %w[
    devices nodes remote_manifest_chunks user_identities
    maker_items maker_models maker_tags maker_projects maker_locations maker_suppliers
    maker_filing_rules
    maker_collections maker_shelves maker_notes maker_tasks maker_previews maker_addon_states
    maker_print_runs maker_taggings maker_file_attachments maker_collection_items maker_repo_edits
    maker_build_log_entries maker_sheets maker_boms maker_inventory_items
    maker_inventory_transactions maker_bom_lines
  ].freeze

  def rows_for(user, table)
    ActiveRecord::Base.connection.select_value(
      "SELECT COUNT(*) FROM #{table} WHERE user_id = #{user.id.to_i}"
    ).to_i
  end

  test "the derived table set is non-empty and every table has a builder" do
    # NON-EMPTY FIRST. §14e: a guard that scans for its own subject reports a clean result when
    # the subject disappears — `assert_empty` over an accidentally-empty set passes perfectly.
    assert_operator TABLES.size, :>=, 20,
      "expected ~26 user-scoped tables, found #{TABLES.size} — has the schema been loaded?"

    missing = TABLES - BUILDERS.keys
    assert_empty missing, <<~MSG
      These tables carry a user_id and have no builder in TenantCleanupTest::BUILDERS:

        #{missing.join("\n  ")}

      A new user-scoped table needs a decision, not a skip: give User a
      `has_many ... dependent: :destroy` (or document the transitive path that already destroys
      it), then add a builder here so the sweep is demonstrated rather than assumed.
    MSG

    stale = BUILDERS.keys - TABLES
    assert_empty stale, "builders for tables that no longer exist: #{stale.join(', ')}"

    assert_equal TABLES.sort, BUILD_ORDER.sort,
      "BUILD_ORDER and the derived table set disagree"
  end

  test "user.destroy empties every table carrying their user_id" do
    user = User.create!(email: "tenant-#{SecureRandom.hex(4)}@example.com")

    BUILD_ORDER.each { |t| BUILDERS.fetch(t).call(user) }

    # VACUITY CHECK. Without this, a builder that quietly failed to persist would leave its table
    # empty and the post-destroy assertion would pass having proved nothing — this repo's dominant
    # failure mode (§15), and the exact reason the nine capability-gating tests could not fail.
    TABLES.each do |t|
      assert_operator rows_for(user, t), :>=, 1,
        "builder for #{t} produced no row, so its cleanup would not be exercised"
    end

    user.destroy!

    leaked = TABLES.reject { |t| rows_for(user, t).zero? }
    assert_empty leaked, <<~MSG
      user.destroy left rows behind in: #{leaked.join(', ')}

      Every table carrying a user_id must be swept when the account goes. Add the missing
      `dependent:` to app/models/user.rb, or — if the table is destroyed transitively through a
      parent — make sure that parent is itself reachable from a User association.
    MSG
  end

  test "a user's rows survive another user's destruction" do
    keeper = User.create!(email: "keeper-#{SecureRandom.hex(4)}@example.com")
    doomed = User.create!(email: "doomed-#{SecureRandom.hex(4)}@example.com")

    BUILD_ORDER.each { |t| BUILDERS.fetch(t).call(keeper) }
    BUILD_ORDER.each { |t| BUILDERS.fetch(t).call(doomed) }

    doomed.destroy!

    kept = TABLES.reject { |t| rows_for(keeper, t) >= 1 }
    # THE MESSAGE DISTINGUISHES THE TWO CAUSES, because for one of them the obvious reading is
    # WRONG and expensive. A table with no builder never had a keeper row to lose, so it lands here
    # looking exactly like cross-tenant data loss -- observed on maker_repo_edits (tinkerex#178),
    # where it read as a live tenancy bug and was in fact one missing `has_many`. The builder gap
    # has its own test above; this one is about destruction crossing a tenant boundary, and saying
    # so keeps the next reader from hunting a bug that is not there.
    unbuilt = kept & (TABLES - BUILDERS.keys)
    assert_empty kept, <<~MSG
      destroying one user removed another user's rows from: #{kept.join(', ')}
      #{"\nNOT NECESSARILY A TENANCY BUG: #{unbuilt.join(', ')} #{unbuilt.one? ? 'has' : 'have'} " \
        "no BUILDERS entry, so the keeper never had a row here. Add the builder (and the User " \
        "association it implies) first, then re-read this failure." if unbuilt.any?}
    MSG
  end
end
