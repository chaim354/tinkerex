# frozen_string_literal: true

module McpServer
  module Tools
    # REFERENCE DATA: suppliers and locations, listed and added. Both are small per user, so no cap.
    module Reference
      def self.all = [ ListSuppliers, CreateSupplier, ListLocations, CreateLocation ]

      class ListSuppliers < McpServer::Tool
        tool_name "list_suppliers"
        description "Every supplier, by name: id, name, url, notes."
        input_schema(properties: {}, required: [], additionalProperties: false)
        reads!

        def self.perform(user)
          { suppliers: user.maker_suppliers.order(:name, :id).map { |s| Render.supplier(s) } }
        end
      end

      class CreateSupplier < McpServer::Tool
        tool_name "create_supplier"
        description "Add a supplier by name, optionally with its website url and notes (lead times, " \
                    "an account number). Inventory items and BOM lines can then name it by id."
        input_schema(
          properties: { name: { type: "string", minLength: 1, maxLength: 200 }, url: { type: "string", maxLength: 500 }, notes: { type: "string" } },
          required: %w[name], additionalProperties: false
        )
        writes!

        def self.perform(user, name:, url: nil, notes: nil)
          { supplier: Render.supplier(user.maker_suppliers.create!(name: name, url: url, notes: notes)) }
        end
      end

      class ListLocations < McpServer::Tool
        tool_name "list_locations"
        description "Every storage location, by name: id, name, parent (name and id), description."
        input_schema(properties: {}, required: [], additionalProperties: false)
        reads!

        def self.perform(user)
          { locations: user.maker_locations.includes(:parent).order(:name, :id).map { |l| Render.location(l) } }
        end
      end

      class CreateLocation < McpServer::Tool
        tool_name "create_location"
        description "Add a storage location, optionally inside another (parent_id)."
        input_schema(
          properties: { name: { type: "string", minLength: 1, maxLength: 200 }, parent_id: { type: "integer" }, description: { type: "string" } },
          required: %w[name], additionalProperties: false
        )
        writes!

        def self.perform(user, name:, parent_id: nil, description: nil)
          { location: Render.location(user.maker_locations.create!(name: name, parent_id: parent_id, description: description)) }
        end
      end
    end
  end
end
