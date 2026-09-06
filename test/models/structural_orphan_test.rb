require "test_helper"
require "schema_map"

# DESTROYING A PARENT ROW MUST NOT LEAVE A CHILD POINTING AT IT — tinkerex#152 part (b), the ~13
# structural parent pointers that tinkerex#74 never examined. #74 scoped itself to four SIBLING
# pointers (supplier/location/inventory_item on inventory items and BOM lines) and settled those;
# nothing covered `maker_boms.project_id`, `maker_bom_lines.bom_id`, `maker_taggings.tag_id` and
# the rest, most of which are `null: false` and none of which the database enforces.
#
# THIS ASSERTS EXACTLY WHAT A FOREIGN KEY WOULD HAVE GIVEN, WITHOUT THE FOREIGN KEY. `add_foreign_key
# ... on_delete: :cascade|:nullify` guarantees one thing at delete time: no surviving child holds a
# non-null id with no parent. That is the property below, checked through the real associations. See
# tinkerex#152 for why the constraint itself was not taken (the deciding live orphan census was
# never run, and Rails rebuilds the whole table to add an FK on SQLite — a full copy per table on a
# live self-host box). A cascade would also be the WRONG answer for
# `maker_bom_lines.inventory_item_id`: `InventoryItem#release_bom_lines` copies the item's name into
# the line before dropping the pointer, so the line survives as editable free text (§14d). The test
# accepts either outcome — destroyed, or nulled — because a dangling id is the only real defect.
#
# THE CASE LIST IS DERIVED FROM SchemaMap::EDGES, NOT WRITTEN OUT. A new structural edge fails the
# first test until someone supplies a case, which is the point: an unenforced pointer nobody
# considered is exactly how these thirteen accumulated.
class StructuralOrphanTest < ActiveSupport::TestCase
  # Structural edges only: maker-layer, pointing at a real `id` primary key. This deliberately
  # excludes the `node_id`/`cover_node_id`/`folder_node_id`/`auto_node_id` string columns (they
  # point at `nodes.node_id` and must stay SOFT — a tombstone outliving its row is the design,
  # §14a) and the polymorphic pairs, which cannot take a constraint at all.
  EDGES = SchemaMap::EDGES.reject { |(_c, _p, kind, _l)| kind == "poly" }
                          .select { |(child, parent, _k, _l)|
                            child.start_with?("maker_") && parent.end_with?(".id")
                          }.map { |(child, parent, _k, _l)| [ child, parent ] }.uniq.sort.freeze

  # Each case returns [parent_record, child_record]. The child must point at the parent through
  # the column named by the edge.
  CASES = {
    "maker_boms.project_id" => ->(u) {
      p = u.maker_projects.create!(name: "Lamp")
      [ p, p.boms.create!(user: u) ]
    },
    "maker_bom_lines.bom_id" => ->(u) {
      bom = u.maker_projects.create!(name: "Lamp").boms.create!(user: u)
      [ bom, bom.lines.create!(user: u, part_name: "M3 bolt", quantity: 4) ]
    },
    "maker_bom_lines.inventory_item_id" => ->(u) {
      item = u.maker_inventory_items.create!(name: "M3 bolt")
      bom  = u.maker_projects.create!(name: "Lamp").boms.create!(user: u)
      [ item, bom.lines.create!(user: u, inventory_item: item, quantity: 4) ]
    },
    "maker_bom_lines.supplier_id" => ->(u) {
      sup = u.maker_suppliers.create!(name: "Digikey")
      bom = u.maker_projects.create!(name: "Lamp").boms.create!(user: u)
      [ sup, bom.lines.create!(user: u, part_name: "M3 bolt", supplier: sup, quantity: 4) ]
    },
    "maker_build_log_entries.project_id" => ->(u) {
      p = u.maker_projects.create!(name: "Lamp")
      [ p, p.build_log_entries.create!(user: u, entry_type: "note", body: "started") ]
    },
    "maker_sheets.project_id" => ->(u) {
      p = u.maker_projects.create!(name: "Lamp")
      [ p, p.sheets.create!(user: u, name: "Cut list") ]
    },
    "maker_connections.project_id" => ->(u) {
      p = u.maker_projects.create!(name: "Lamp")
      [ p, p.connections.create!(user: u, from_label: "Driver board", to_label: "Stepper motor") ]
    },
    "maker_releases.project_id" => ->(u) {
      p = u.maker_projects.create!(name: "Lamp")
      [ p, p.releases.create!(user: u, version: "v0.1.0", published_at: Time.current) ]
    },
    # `:nullify` here, not `:destroy` — a release outlives the BOM it recorded, because
    # `bom_revision` is a copy taken at release time. "No orphan" is satisfied by either, so the
    # half this cannot express (the release SURVIVES with its revision) is pinned in
    # test/models/maker/release_test.rb, the same division the inventory ledger case makes below.
    "maker_releases.bom_id" => ->(u) {
      p = u.maker_projects.create!(name: "Lamp")
      bom = p.boms.create!(user: u)
      [ bom, p.releases.create!(user: u, version: "v0.1.0", published_at: Time.current,
                                bom: bom, bom_revision: bom.revision) ]
    },
    "maker_release_files.release_id" => ->(u) {
      rel = u.maker_projects.create!(name: "Lamp")
             .releases.create!(user: u, version: "v0.1.0", published_at: Time.current)
      [ rel, rel.files.create!(user: u, node_id: SecureRandom.uuid, name: "base.stl") ]
    },
    "maker_collection_items.collection_id" => ->(u) {
      c = u.maker_collections.create!(name: "Favourites")
      [ c, c.collection_items.create!(user: u, item: u.maker_items.create!(title: "Bracket")) ]
    },
    "maker_collection_items.item_id" => ->(u) {
      item = u.maker_items.create!(title: "Bracket")
      c    = u.maker_collections.create!(name: "Favourites")
      [ item, c.collection_items.create!(user: u, item: item) ]
    },
    "maker_inventory_items.location_id" => ->(u) {
      loc = u.maker_locations.create!(name: "Shelf A")
      [ loc, u.maker_inventory_items.create!(name: "M3 bolt", location: loc) ]
    },
    "maker_inventory_items.supplier_id" => ->(u) {
      sup = u.maker_suppliers.create!(name: "Digikey")
      [ sup, u.maker_inventory_items.create!(name: "M3 bolt", supplier: sup) ]
    },
    "maker_inventory_transactions.inventory_item_id" => ->(u) {
      item = u.maker_inventory_items.create!(name: "M3 bolt")
      [ item, item.transactions.create!(user: u, delta: 5, reason: "adjusted") ]
    },
    "maker_inventory_transactions.project_id" => ->(u) {
      p    = u.maker_projects.create!(name: "Lamp")
      item = u.maker_inventory_items.create!(name: "M3 bolt")
      [ p, item.transactions.create!(user: u, delta: -2, reason: "consumed", project_id: p.id) ]
    },
    "maker_locations.parent_id" => ->(u) {
      parent = u.maker_locations.create!(name: "Cabinet")
      [ parent, u.maker_locations.create!(name: "Shelf A", parent: parent) ]
    },
    "maker_print_runs.model_id" => ->(u) {
      m = u.maker_models.create!(title: "Benchy")
      [ m, m.print_runs.create!(user: u, outcome: "success", printed_on: Date.current) ]
    },
    # The two edges that ALREADY have a real database foreign key (the only maker_* ones that do).
    # They are covered here anyway: an FK and a `dependent:` are two mechanisms for one property,
    # and this test asserts the property, so it must not care which is doing the work.
    "maker_addon_files.addon_state_id" => ->(u) {
      st = u.maker_addon_states.create!(addon_key: "boxes", name: "box-1", data: {})
      [ st, st.files.create!(node_id: SecureRandom.uuid, role: "output") ]
    },
    "maker_addon_state_revisions.addon_state_id" => ->(u) {
      st = u.maker_addon_states.create!(addon_key: "boxes", name: "box-1", data: {})
      [ st, st.revisions.create!(revision: 1, data: {}) ]
    },

    "maker_taggings.tag_id" => ->(u) {
      tag = u.maker_tags.create!(name: "brackets")
      [ tag, u.maker_taggings.create!(tag: tag, taggable: u.maker_items.create!(title: "B")) ]
    }
  }.freeze

  def new_user = User.create!(email: "orphan-#{SecureRandom.hex(4)}@example.com")

  test "every structural maker edge has a case" do
    # NON-EMPTY FIRST (§14e): this set is derived, and a derived set that quietly becomes empty
    # satisfies `assert_empty` perfectly while proving nothing.
    assert_operator EDGES.size, :>=, 12,
      "expected ~15 structural maker edges, derived #{EDGES.size} from SchemaMap::EDGES"

    missing = EDGES.map(&:first).zip(EDGES.map(&:last)).map { |c, _p| c } - CASES.keys
    assert_empty missing.uniq, <<~MSG
      Structural edges in SchemaMap::EDGES with no case here:

        #{missing.uniq.join("\n  ")}

      Add one. An unenforced parent pointer that nobody demonstrated is how tinkerex#152's
      thirteen accumulated.
    MSG

    stale = CASES.keys - EDGES.map(&:first)
    assert_empty stale, "cases for edges no longer in SchemaMap::EDGES: #{stale.join(', ')}"
  end

  EDGES.each do |(child, parent)|
    table, column = child.split(".")

    test "destroying #{parent.sub('.id', '')} leaves no #{table} row pointing at it via #{column}" do
      user = new_user
      parent_record, child_record = CASES.fetch(child).call(user)

      # VACUITY CHECK: the child must really point at the parent, or destroying the parent proves
      # nothing. This repo's dominant failure mode is a green suite over a test that never
      # established its own precondition (§15).
      assert_equal parent_record.id, child_record.public_send(column),
        "#{child} was not pointing at the parent before the destroy"

      parent_record.destroy!

      still = ActiveRecord::Base.connection.select_value(
        "SELECT COUNT(*) FROM #{table} WHERE #{column} = #{parent_record.id.to_i}"
      ).to_i

      assert_equal 0, still, <<~MSG
        #{still} #{table} row(s) still hold #{column} = #{parent_record.id} after their parent
        (#{parent.sub('.id', '')}) was destroyed — a dangling reference no constraint would allow.

        Fix it on the PARENT association: `dependent: :destroy` if the child is meaningless without
        it, or `dependent: :nullify` if it should survive. Do not reach for a database foreign key
        without reading tinkerex#152 first.
      MSG
    end
  end

  # THE COMPANION TO THE project_id CASE ABOVE. "No orphan" is satisfied by destroying the child
  # too, so the generated test alone would stay green if someone changed Project's `:nullify` to
  # `:destroy` — which would raise on the immutable ledger, and if the guard were ever removed
  # would silently desynchronise `quantity_cached`. This asserts the row SURVIVES, which is the
  # half a dangling-reference check cannot express.
  test "destroying a project keeps its inventory ledger and the item's balance" do
    user = new_user
    project = user.maker_projects.create!(name: "Lamp")
    item = user.maker_inventory_items.create!(name: "M3 bolt")

    Maker::InventoryTransaction.apply!(item: item, user: user, delta: 10, reason: "restocked")
    Maker::InventoryTransaction.apply!(item: item, user: user, delta: -4, reason: "consumed",
                                       project_id: project.id)
    balance_before = item.reload.quantity_cached

    assert_nothing_raised { project.destroy! }

    ledger = item.reload.transactions.to_a
    assert_equal 2, ledger.size, "destroying a project must not delete its stock movements"
    assert_equal [ 10, -4 ], ledger.map { |t| t.delta.to_i }
    assert_nil ledger.last.project_id, "the provenance pointer should be nulled, not left dangling"
    assert_equal balance_before, item.quantity_cached,
      "the cached balance must not move when a project is deleted"
  end
end
