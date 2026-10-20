module Maker
  class InventoryTransaction < ApplicationRecord
    self.table_name = "maker_inventory_transactions"

    # Immutable append-only ledger: no updated_at. Rails sets created_at on create.
    REASONS = %w[consumed restocked adjusted initial].freeze

    belongs_to :user
    belongs_to :inventory_item, class_name: "Maker::InventoryItem"
    # SOFT REFERENCE, NOT A VALIDATED ONE — deliberately no `belongs_to ... optional: false` and no
    # `*_belongs_to_user` validation to match. `project_id` records PROVENANCE ("this consumption was
    # for project X"), and Maker::Project already nullifies it on destroy
    # (`has_many :inventory_transactions, dependent: :nullify`) for exactly the reason a validated,
    # required association would break: the ledger is immutable (§ above) and a deleted project must
    # not strand a posted row unsavable. `optional: true` is what makes `includes(:project)` on the
    # web ledger (InventoryItemsController#show) resolve without an association error, and a
    # since-deleted project renders as "—" rather than 500ing. TENANCY IS A NORMALISATION IN apply!,
    # NOT A VALIDATION: a project the item's owner does not own is DROPPED there, at every door, and
    # the stock change still posts (a check guarded on `if: project_id.present?` would be §14d's
    # lock). A row written with a foreign project before apply! dropped them keeps that id; the item
    # page shows "—" for it only because it compares the project's owner with the item's. See
    # test/models/maker/inventory_transaction_test.rb's "project_id is a soft reference" test.
    belongs_to :project, class_name: "Maker::Project", optional: true

    # THIS MODEL DECIDES WHAT A POSTABLE AMOUNT IS, FOR EVERY DOOR: web adjust and initial quantity,
    # v1 adjust, BOM consume. It lived in the web controller alone, so v1 and consume posted what the
    # web refused. Finite, non-zero, and inside the decimal(12,3) column: `in:` is Range#include?,
    # false for ±Infinity and NaN ("1e400" parses to Infinity). A non-finite row is permanent damage:
    # the ledger is immutable, so no later post, and no rebuild_quantity_cached! (it writes the
    # Infinity back), can return the balance to a number. The checks see the amount at the column's
    # scale, so "0.0001" is a zero. ON CREATE ONLY: before_update refuses every update outright, and
    # must keep answering ReadOnlyRecord rather than a validation error.
    MAX_DELTA = BigDecimal("999999999.999")
    validates :delta, presence: true, on: :create, numericality: {
      other_than: 0, in: -MAX_DELTA..MAX_DELTA,
      message: "must be a non-zero number within ±#{ActiveSupport::NumberHelper.number_to_delimited(MAX_DELTA.to_s("F"))}"
    }
    validates :reason, inclusion: { in: REASONS }

    after_create :apply_to_cached_balance

    # Block edits/deletes of a posted ledger row. BOTH hooks are unconditional, and the destroy
    # one deliberately asks nothing about the parent item: it used to permit a destroy whenever
    # `inventory_item` was nil/destroyed?/marked_for_destruction?, none of which the real cascades
    # ever set — `dependent: :delete_all` issues one DELETE and instantiates nothing, and a
    # `:destroy` cascade sets `destroyed_by_association`, not those flags. So the "only with the
    # parent" branch was never the thing letting a cascade through; declaration ORDER on User was
    # (see the `dependent:` comment there). Rows are removed row-level, never record-level.
    before_update  { raise ActiveRecord::ReadOnlyRecord, "inventory transactions are immutable" }
    before_destroy { raise ActiveRecord::ReadOnlyRecord, "inventory transactions are immutable" }

    # Atomic post: insert the ledger row AND move the item's cached balance in one DB transaction,
    # holding a row lock on the item so concurrent posts can't lose an update. Works on SQLite + PG.
    def self.apply!(item:, user:, delta:, reason: "adjusted", project_id: nil, note: nil)
      transaction do
        locked = Maker::InventoryItem.where(id: item.id, user_id: item.user_id).lock.first!   # SELECT ... FOR UPDATE on PG; serialized on SQLite
        # A PROJECT THAT IS NOT THE ITEM OWNER'S IS DROPPED, NOT REFUSED: provenance is optional, so
        # the stock change still posts and simply names no project.
        project_id = project_id.presence && Maker::Project.where(id: project_id, user_id: locked.user_id).pick(:id)
        txn = locked.transactions.create!(
          user: user, delta: delta, reason: reason, project_id: project_id, note: note.presence
        )
        item.reload if item.equal?(locked) == false
        txn
      end
    end

    private

    # Keep quantity_cached == SUM(delta) without re-summing the whole ledger on the hot path:
    # increment by this row's delta. Runs inside apply!'s transaction (and the item is row-locked
    # there); a bare create! (e.g. in tests/seed) still keeps the balance correct.
    def apply_to_cached_balance
      Maker::InventoryItem.where(id: inventory_item_id)
                          .update_all([ "quantity_cached = quantity_cached + ?", delta ])
    end
  end
end
