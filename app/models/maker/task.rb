module Maker
  class Task < ApplicationRecord
    self.table_name = "maker_tasks"

    belongs_to :user
    belongs_to :taskable, polymorphic: true, optional: true

    STATUSES       = %w[todo doing done].freeze
    TASKABLE_TYPES = %w[Maker::Item].freeze

    validates :title, presence: true
    validates :status, inclusion: { in: STATUSES }
    validates :taskable_type, inclusion: { in: TASKABLE_TYPES }, allow_nil: true
    validate  :taskable_belongs_to_owner, if: -> { taskable_id.present? }

    scope :open, -> { where.not(status: "done") }

    def complete!
      update!(status: "done", completed_at: Time.current)
    end

    private

    def taskable_belongs_to_owner
      return unless taskable_type == "Maker::Item"
      unless Maker::Item.exists?(id: taskable_id, user_id: user_id)
        errors.add(:taskable_id, "must reference your own item")
      end
    end
  end
end
