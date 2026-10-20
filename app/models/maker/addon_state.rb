module Maker
  # One saved addon "thing": structured `data` (the addon's own shape, for reload) plus a tied
  # bundle of output files (`files`, each a library node with a role). Every addon persists the
  # same way through this one model — nothing here is addon-specific.
  class AddonState < ApplicationRecord
    self.table_name = "maker_addon_states"

    belongs_to :user
    # THE LATEST SAVE'S FILES FIRST, IN THE ORDER THAT SAVE LISTED THEM, THEN THE ROWS EARLIER SAVES
    # LEFT. A state outlives a save: a revision that emits a differently-named file leaves the
    # previous save's row in place (Maker::Addons::LibraryOutput#upsert_file!), so `position`, a
    # save's index into its own outputs, repeats across saves. `revision` records the save that last
    # wrote each row, and `revision: :desc` is what puts the current outputs at `files[0]`, where both
    # shipped bundles look: Tools::AddonsController#states serialises this collection to every one.
    # Tools::AddonsController#latest_output_folder spells the same order in SQL; keep the two alike.
    #
    # `:id` IS THE LAST TIEBREAK, FOR ROWS THE BACKFILL STAMPED. A row written before `revision`
    # existed took its state's current number, so a state's legacy rows can still tie on (revision,
    # position). Not test-pinned, said rather than left quietly unguarded: SQLite returns tied rows in
    # rowid order with or without `:id`, so an assertion on that order cannot fail. It is correctness
    # against a planner free to reorder a tie. `revision` and `position` ARE pinned, in
    # addon_state_test.rb, by rows created in an order that disagrees with this one.
    has_many :files, -> { order(revision: :desc, position: :asc, id: :asc) },
             class_name: "Maker::AddonFile", dependent: :destroy

    # THE HISTORY. Ordered oldest-first here; the endpoint that serves it reverses, because a
    # reader wants the newest revision at the top and a writer wants `maximum(:revision)`.
    has_many :revisions, -> { order(:revision) }, class_name: "Maker::AddonStateRevision",
             foreign_key: :addon_state_id, dependent: :destroy

    validates :addon_key, presence: true
    validates :name, presence: true

    scope :for_addon, ->(key) { where(addon_key: key) }
  end
end
