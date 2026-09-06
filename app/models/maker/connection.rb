module Maker
  # A wiring-table row (stage 3, S3-3): two labelled ends, an optional wire/pin note and a free
  # note, in order on the project. Read-only rendering on the public page (S3-4) reuses the same
  # shape -- see projects/_wiring.html.erb.
  class Connection < ApplicationRecord
    self.table_name = "maker_connections"

    belongs_to :user
    belongs_to :project, class_name: "Maker::Project"

    normalizes :from_label, :to_label, :wire, with: ->(s) { s.to_s.strip }

    validates :from_label, :to_label, presence: true, length: { maximum: 120 }
    validates :wire, length: { maximum: 60 }
    validates :note, length: { maximum: 500 }
    validate :project_belongs_to_user

    private

    def project_belongs_to_user
      unless Maker::Project.exists?(id: project_id, user_id: user_id)
        errors.add(:project_id, "must reference your own project")
      end
    end
  end
end
