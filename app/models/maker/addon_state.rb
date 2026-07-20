module Maker
  # One saved addon "thing": structured `data` (the addon's own shape, for reload) plus a tied
  # bundle of output files (`files`, each a library node with a role). Every addon persists the
  # same way through this one model — nothing here is addon-specific.
  class AddonState < ApplicationRecord
    self.table_name = "maker_addon_states"

    belongs_to :user
    has_many :files, -> { order(:position) }, class_name: "Maker::AddonFile", dependent: :destroy

    validates :addon_key, presence: true
    validates :name, presence: true

    scope :for_addon, ->(key) { where(addon_key: key) }
  end
end
