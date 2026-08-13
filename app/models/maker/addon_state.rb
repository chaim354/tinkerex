module Maker
  # One saved addon "thing": structured `data` (the addon's own shape, for reload) plus a tied
  # bundle of output files (`files`, each a library node with a role). Every addon persists the
  # same way through this one model — nothing here is addon-specific.
  class AddonState < ApplicationRecord
    self.table_name = "maker_addon_states"

    belongs_to :user
    # ORDERED BY (position, id), AND THE `:id` IS A REAL TIEBREAK RATHER THAN DECORATION. `position`
    # is this save's index into its own output list, and a state can now outlive a save: a revision
    # that emits a differently-named file leaves the previous save's row in place (see
    # Maker::Addons::LibraryOutput#upsert_file!), so TWO rows can hold position 0. `order(:position)`
    # alone is then non-deterministic, and Tools::AddonsController#states serialises this collection
    # to every published bundle — an order that changes between two identical requests. `:id` makes
    # it stable and puts the older row first; it does NOT make the number meaningful across saves.
    #
    # NOT TEST-PINNED, AND SAID RATHER THAN QUIETLY LEFT UNGUARDED: with two rows tied at position
    # 0, SQLite returns them in rowid order whether or not `:id` is here, so an assertion on the
    # order passes identically with the tiebreak removed — a guard that cannot fail. This is
    # correctness against an engine that would NOT (any planner free to reorder a tie), so the
    # probe that justifies it is the position collision itself, which IS asserted, in
    # addons_controller_test.rb's revise test.
    has_many :files, -> { order(:position, :id) }, class_name: "Maker::AddonFile", dependent: :destroy

    # THE HISTORY. Ordered oldest-first here; the endpoint that serves it reverses, because a
    # reader wants the newest revision at the top and a writer wants `maximum(:revision)`.
    has_many :revisions, -> { order(:revision) }, class_name: "Maker::AddonStateRevision",
             foreign_key: :addon_state_id, dependent: :destroy

    validates :addon_key, presence: true
    validates :name, presence: true

    scope :for_addon, ->(key) { where(addon_key: key) }
  end
end
