module Maker
  class Task < ApplicationRecord
    self.table_name = "maker_tasks"

    belongs_to :user
    belongs_to :taskable, polymorphic: true, optional: true

    STATUSES       = %w[todo doing done].freeze
    TASKABLE_TYPES = %w[Maker::Item Maker::Project].freeze

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
      owner_class =
        case taskable_type
        when "Maker::Item"    then Maker::Item
        when "Maker::Project" then Maker::Project
        end
      return unless owner_class

      unless owner_class.exists?(id: taskable_id, user_id: user_id)
        errors.add(:taskable_id, "must reference your own #{owner_class.model_name.element}")
      end
    end
  end
end
