module Maker
  # The tie between an AddonState and one library node it produced, carrying the file's `role`
  # (e.g. "output" | "parameters") so the addon and UI know what each file in the bundle is.
  class AddonFile < ApplicationRecord
    self.table_name = "maker_addon_files"

    belongs_to :addon_state, class_name: "Maker::AddonState"

    validates :node_id, presence: true
    validates :role, presence: true
  end
end
