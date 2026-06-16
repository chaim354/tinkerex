module Maker
  class InventoryTransaction < ApplicationRecord
    self.table_name = "maker_inventory_transactions"

    # Immutable append-only ledger: no updated_at. Rails sets created_at on create.
    REASONS = %w[consumed restocked adjusted initial].freeze

    belongs_to :user
    belongs_to :inventory_item, class_name: "Maker::InventoryItem"

    validates :delta, presence: true, numericality: true
    validates :reason, inclusion: { in: REASONS }

    after_create :apply_to_cached_balance

    # Block edits/deletes of a posted ledger row from ordinary code paths.
    before_update  { raise ActiveRecord::ReadOnlyRecord, "inventory transactions are immutable" }
    before_destroy :allow_destroy_only_with_parent

    # Atomic post: insert the ledger row AND move the item's cached balance in one DB transaction,
    # holding a row lock on the item so concurrent posts can't lose an update. Works on SQLite + PG.
    def self.apply!(item:, user:, delta:, reason: "adjusted", project_id: nil, note: nil)
      transaction do
        locked = Maker::InventoryItem.where(id: item.id, user_id: item.user_id).lock.first!   # SELECT ... FOR UPDATE on PG; serialized on SQLite
        txn = locked.transactions.create!(
          user: user, delta: delta, reason: reason, project_id: project_id, note: note
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

    def allow_destroy_only_with_parent
      # Permit row removal only when the parent item is being destroyed (dependent: :destroy),
      # so the immutable ledger can't be cherry-picked apart while the item still exists.
      unless inventory_item.nil? || inventory_item.destroyed? || inventory_item.marked_for_destruction?
        raise ActiveRecord::ReadOnlyRecord, "inventory transactions are immutable"
      end
    end
  end
end
