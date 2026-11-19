module Maker
  class Bom < ApplicationRecord
    self.table_name = "maker_boms"

    belongs_to :user
    belongs_to :project, class_name: "Maker::Project"
    has_many :lines, -> { order(:position, :id) },
             class_name: "Maker::BomLine", foreign_key: :bom_id, dependent: :destroy
    # `:nullify`, AND IT IS THE ONLY OPTION THAT WORKS. A release OUTLIVES the BOM it recorded:
    # `bom_revision` is a plain integer copied at release time, so "revision 3 was current" stays
    # true after revision 3 is deleted. `:destroy` would delete published releases as a side effect
    # of tidying a BOM; leaving it off leaves `bom_id` dangling, which structural_orphan_test.rb
    # names as the defect a foreign key would have caught (§14d — every referenced model needs one).
    has_many :releases, class_name: "Maker::Release", foreign_key: :bom_id, dependent: :nullify

    # Latest revision first: the one ORDER behind Maker::Project#current_bom and .current_ids_for.
    scope :latest_first, -> { order(revision: :desc, id: :desc) }

    # Maker::Project#current_bom for a SET of projects, in ONE query: { bom_id => project_id } for
    # each project's latest revision; a project with no BOM is absent. Plucks every revision's two
    # ids and keeps the first per project in Ruby, under the very scope current_bom reads, so the two
    # cannot disagree about which revision is current. A project holds a handful of revisions, so
    # the rows grow with revisions, never the statements.
    def self.current_ids_for(projects)
      projects = projects.to_a
      return {} if projects.empty?

      where(user_id: projects.map(&:user_id).uniq, project_id: projects.map(&:id))
        .latest_first.pluck(:id, :project_id)
        .uniq { |_, project_id| project_id }.to_h
    end

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
