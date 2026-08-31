module Maker
  class InventoryItem < ApplicationRecord
    self.table_name = "maker_inventory_items"

    UNITS = %w[each g kg m mm cm ml l pack roll sheet other].freeze

    belongs_to :user
    belongs_to :location, class_name: "Maker::Location", optional: true
    belongs_to :supplier, class_name: "Maker::Supplier", optional: true
    # `:delete_all` IS LOAD-BEARING, NOT A PERFORMANCE CHOICE. `Maker::InventoryTransaction`'s
    # `before_destroy` raises unconditionally, so the ledger can only ever be removed row-level.
    # Switch this to `:destroy` and every `item.destroy` raises ReadOnlyRecord instead.
    has_many :transactions, -> { order(created_at: :asc, id: :asc) },
             class_name: "Maker::InventoryTransaction", foreign_key: :inventory_item_id,
             dependent: :delete_all
    # NO `dependent:` HERE ON PURPOSE — `release_bom_lines` below does the work, and its statements
    # have to run in that order (the line is given a target BEFORE the pointer is dropped). Adding
    # `dependent: :nullify` to this line would be actively wrong; read that method's comment before
    # "tidying" it.
    has_many :bom_lines, class_name: "Maker::BomLine", foreign_key: :inventory_item_id

    before_destroy :release_bom_lines

    validates :name, presence: true
    validates :unit, inclusion: { in: UNITS }
    validates :quantity_cached, :min_quantity, numericality: true
    validate :location_belongs_to_user, if: -> { location_id.present? }
    validate :supplier_belongs_to_user, if: -> { supplier_id.present? }

    # quantity_cached <= min_quantity  ==>  needs restocking.
    scope :low_stock, -> { where("quantity_cached <= min_quantity") }

    # Recompute the denormalized balance from the immutable ledger (drift repair / migration).
    def rebuild_quantity_cached!
      total = transactions.sum(:delta)
      update_column(:quantity_cached, total)
      total
    end

    private

    # A BOM line whose inventory item is destroyed survives as a FREE-TEXT line. It is neither
    # nullified nor destroyed, and both of those obvious answers are wrong:
    #
    # `dependent: :nullify` swaps one permanent lock for another. `exactly_one_target` requires
    # exactly one of inventory_item_id / node_id / part_name, so a nulled line has NONE and fails
    # validation on every subsequent save — the same unsavable row this fix exists to prevent,
    # wearing a different error message. `dependent: :destroy` is worse: a BOM records what the
    # project needs, and deleting a stock row is a statement about the shelf, not about the design.
    #
    # Carrying the item's name into `part_name` leaves a valid, editable line that still says what
    # part the project needs ("4 × M3 bolt"), in a shape `resolved_target` already renders. It MUST
    # run before the pointer is dropped, because the name belongs to the row about to disappear —
    # which is equally why lines already stranded by this bug cannot be repaired after the fact
    # (the record, CLAUDE.md §11). The line does lose the item's live stock figures, which is honest: there is
    # no stock row any more.
    def release_bom_lines
      mine = bom_lines.where(user_id: user_id)
      # EVERY statement here runs through `mine`, so the whole method is scoped to this item's
      # owner. The contrast worth drawing is with the association-level `dependent: :nullify` on
      # Maker::Supplier and Maker::Location, which is not scoped at all — clearing a foreign
      # pointer can at worst repair an illegal cross-tenant reference, whereas the halves here
      # WRITE this user's item name and supplier into a row, which on someone else's row would be
      # a disclosure. `inventory_item_belongs_to_user` makes such a row unreachable today, so the
      # scope costs one clause and removes the question; keeping the final nullify inside the same
      # scope is a behavioural wash and keeps the method reading as one operation.
      #
      # Only lines that would otherwise be left with NO target are converted; blank is checked
      # alongside NULL because these are nullable strings the API accepts as "" and
      # `exactly_one_target` asks `present?`, not `nil?`. Reachable, not defensive padding: a POST
      # to /v1/maker/boms/:id/bom_lines carrying `part_name: ""` beside an inventory item is a 201
      # that persists the blank, and with a nil-only filter that line comes out of this method with
      # no target at all — the very lock the method exists to prevent. Pinned, both arms, in
      # test/integration/v1/maker/referential_integrity_test.rb.
      #
      # The ids are captured rather than re-running the relation, because the two column writes
      # below address ONE set of lines and the second write would otherwise narrow it: once
      # `part_name` is set the `part_name: [nil, ""]` clause no longer matches, so the statements
      # would silently depend on their order.
      converting = mine.where(node_id: [ nil, "" ], part_name: [ nil, "" ]).ids

      if converting.any?
        lines = Maker::BomLine.where(id: converting)
        # THE SUPPLIER RIDES ALONG. For a BOM, "what is it" and "who do I buy it from" are the two
        # fields that make a line orderable, `maker_bom_lines` has its own `supplier_id`, and
        # `resolved_target`'s free-text shape already renders `supplier_id`/`supplier_name` — so
        # leaving it nil dropped a field with a destination waiting for it. Three qualifiers, each
        # load-bearing:
        #   * only onto lines being CONVERTED. A line that kept its own design-file target is not
        #     becoming a free-text part, and `resolved_target` renders no supplier for that shape.
        #   * never over a supplier the line already names. That one is the user's own annotation
        #     about this line; the item's is a fallback for a line that had none. Same principle as
        #     not overwriting a `part_name` that was already set.
        #   * only if that supplier still exists and is ours. An item stranded by the pre-fix bug
        #     can itself carry a dangling `supplier_id` (nothing backfilled those), and copying that
        #     across would leave the line failing `supplier_belongs_to_user` on every save — this
        #     method's own bug, reintroduced on the row it just rescued. `exists?(id: nil)` is
        #     false, so the one expression also covers "the item had no supplier".
        # `part_number` is NOT carried, because `maker_bom_lines` has no column to put it in. A
        # line records the part and its supplier; the supplier's catalogue number went with the
        # stock row.
        if Maker::Supplier.exists?(id: supplier_id, user_id: user_id)
          lines.where(supplier_id: nil)
               .update_all(supplier_id: supplier_id, updated_at: Time.current)
        end
        lines.update_all(part_name: name, updated_at: Time.current)
      end

      mine.update_all(inventory_item_id: nil, updated_at: Time.current)
    end

    def location_belongs_to_user
      unless Maker::Location.exists?(id: location_id, user_id: user_id)
        errors.add(:location_id, "must reference your own location")
      end
    end

    def supplier_belongs_to_user
      unless Maker::Supplier.exists?(id: supplier_id, user_id: user_id)
        errors.add(:supplier_id, "must reference your own supplier")
      end
    end
  end
end
