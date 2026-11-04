# frozen_string_literal: true

module McpServer
  module Tools
    # INVENTORY: the items, their ledger, and the one way the balance moves --
    # Maker::InventoryTransaction.apply!, exactly as v1's adjust and the web's composer post it.
    module Inventory
      def self.all = [ ListInventory, GetInventoryItem, CreateInventoryItem, UpdateInventoryItem, AdjustInventory ]

      CAP = 200

      # The editable columns, shared by create and update. `quantity` is NOT one: the balance is
      # the ledger's sum and only a transaction moves it.
      FIELDS = {
        part_number: { type: "string", maxLength: 100 },
        category: { type: "string", maxLength: 100 },
        unit: { type: "string", enum: Maker::InventoryItem::UNITS },
        min_quantity: { type: "number", minimum: 0 },
        unit_cost: { type: "number", minimum: 0 },
        location_id: { type: "integer" },
        supplier_id: { type: "integer" },
        notes: { type: "string" }
      }.freeze

      class ListInventory < McpServer::Tool
        tool_name "list_inventory"
        description "Inventory items by name: id, quantity on hand, unit, minimum, location, supplier, " \
                    "low_stock. Filter by a name or part-number substring, low_stock: true, or a " \
                    "location_id. At most #{CAP}."
        input_schema(
          properties: {
            q: { type: "string", maxLength: 80 },
            low_stock: { type: "boolean" },
            location_id: { type: "integer" }
          },
          required: [], additionalProperties: false
        )
        reads!

        def self.perform(user, q: nil, low_stock: nil, location_id: nil)
          scope = user.maker_inventory_items.includes(:location, :supplier).order(:name, :id)
          scope = scope.low_stock if low_stock
          scope = scope.where(location_id: location_id) if location_id
          if q.present?
            pattern = like(Maker::InventoryItem, q)
            scope = scope.where("LOWER(name) LIKE ? ESCAPE '\\' OR LOWER(COALESCE(part_number, '')) LIKE ? ESCAPE '\\'",
                                pattern, pattern)
          end
          rows, truncated = capped(scope, CAP)
          { items: rows.map { |i| Render.item(i) }, truncated: }
        end
      end

      class GetInventoryItem < McpServer::Tool
        TRANSACTIONS = 20

        tool_name "get_inventory_item"
        description "One inventory item in full, with its last #{TRANSACTIONS} ledger transactions newest first."
        input_schema(properties: { id: { type: "integer" } }, required: %w[id], additionalProperties: false)
        reads!

        def self.perform(user, id:)
          i = item!(user, id)
          ledger = i.transactions.reorder(created_at: :desc, id: :desc).limit(TRANSACTIONS).to_a
          { item: Render.item(i, full: true), transactions: ledger.map { |t| Render.transaction(t) } }
        end
      end

      class CreateInventoryItem < McpServer::Tool
        tool_name "create_inventory_item"
        description "Add an inventory item. quantity is the opening stock, posted to the ledger as " \
                    "initial stock. unit is one of #{Maker::InventoryItem::UNITS.join(", ")} (default each)."
        input_schema(
          properties: { name: { type: "string", minLength: 1, maxLength: 200 }, quantity: { type: "number" } }.merge(FIELDS),
          required: %w[name], additionalProperties: false
        )
        writes!

        def self.perform(user, name:, quantity: nil, **fields)
          i = user.maker_inventory_items.create!({ name: name }.merge(fields))
          if quantity && !quantity.zero?
            Maker::InventoryTransaction.apply!(item: i, user: user, delta: quantity, reason: "initial")
            i.reload
          end
          { item: Render.item(i, full: true) }
        end
      end

      class UpdateInventoryItem < McpServer::Tool
        tool_name "update_inventory_item"
        description "Change an inventory item's name, part number, category, unit, minimum, unit cost, " \
                    "location, supplier or notes. Never the balance: use adjust_inventory."
        input_schema(
          properties: { id: { type: "integer" }, name: { type: "string", minLength: 1, maxLength: 200 } }.merge(FIELDS),
          required: %w[id], additionalProperties: false
        )
        writes!(idempotent: true)

        def self.perform(user, id:, **fields)
          i = item!(user, id)
          i.update!(fields)
          { item: Render.item(i, full: true) }
        end
      end

      class AdjustInventory < McpServer::Tool
        tool_name "adjust_inventory"
        description "Move an item's balance by a signed delta (negative takes stock out), posting a " \
                    "ledger row. reason is one of #{Maker::InventoryTransaction::REASONS.join(", ")} " \
                    "(default adjusted); project is a slug the row is attributed to."
        input_schema(
          properties: {
            id: { type: "integer" },
            delta: { type: "number" },
            reason: { type: "string", enum: Maker::InventoryTransaction::REASONS },
            note: { type: "string" },
            project: { type: "string", description: "A project slug." }
          },
          required: %w[id delta], additionalProperties: false
        )
        writes!

        def self.perform(user, id:, delta:, reason: "adjusted", note: nil, project: nil)
          i = item!(user, id)
          raise Refused, "delta must not be zero." if delta.zero?

          project_id = project && project!(user, project).id
          txn = Maker::InventoryTransaction.apply!(item: i, user: user, delta: delta, reason: reason,
                                                   project_id: project_id, note: note)
          { item: Render.item(i.reload, full: true), transaction: Render.transaction(txn) }
        end
      end
    end
  end
end
