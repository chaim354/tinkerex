module Maker
  class Task < ApplicationRecord
    self.table_name = "maker_tasks"

    belongs_to :user
    belongs_to :taskable, polymorphic: true, optional: true

    STATUSES = %w[todo doing done].freeze

    validates :title, presence: true
    validates :status, inclusion: { in: STATUSES }

    scope :open, -> { where.not(status: "done") }

    def complete!
      update!(status: "done", completed_at: Time.current)
    end
  end
end
