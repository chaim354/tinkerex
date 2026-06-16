module Maker
  class Supplier < ApplicationRecord
    self.table_name = "maker_suppliers"

    belongs_to :user

    validates :name, presence: true
  end
end
