module Maker
  # The tie between an AddonState and one library node it produced, carrying the file's `role`
  # (currently only "output") so the addon and UI know what each file in the bundle is. `role` earns
  # its place the moment an addon emits a second FORMAT; it is not for metadata — the "parameters"
  # role was removed 2026-07-29 because `AddonState#data` already records the params and nothing ever
  # read the file back.
  class AddonFile < ApplicationRecord
    self.table_name = "maker_addon_files"

    belongs_to :addon_state, class_name: "Maker::AddonState"

    validates :node_id, presence: true
    validates :role, presence: true
  end
end
