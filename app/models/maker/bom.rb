module Maker
  class Bom < ApplicationRecord
    self.table_name = "maker_boms"

    belongs_to :user
    belongs_to :project, class_name: "Maker::Project"
    has_many :lines, -> { order(:position, :id) },
             class_name: "Maker::BomLine", foreign_key: :bom_id, dependent: :destroy

    validates :name, presence: true
    validates :revision, numericality: { only_integer: true, greater_than: 0 }
    validate :project_belongs_to_user

    private

    def project_belongs_to_user
      unless Maker::Project.exists?(id: project_id, user_id: user_id)
        errors.add(:project_id, "must reference your own project")
      end
    end
  end
end
