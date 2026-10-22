module Maker
  # A CALCULATOR RESULT SAVED ONTO A PROJECT (2026-10-21; docs/superpowers/plans/2026-10-21-calculator-modal.md):
  # the expression the modal evaluated, the number it showed and that number's unit, under a label
  # the maker chose ("Shelf depth"). The project page's Calculations panel lists them; "Open in
  # calculator" puts the expression back in the modal.
  #
  # THE SERVER STORES WHAT THE BROWSER COMPUTED AND NEVER RE-EVALUATES IT. The engine is
  # lib/calc.js, which exists only in the browser, and a second evaluator here would be a second
  # definition of what `1/4in` means that the two could disagree about. A row is a record of what
  # the maker saw, so `result` and `unit` are validated for SHAPE (a finite number, a unit the
  # engine can produce) and not recomputed.
  class Calculation < ApplicationRecord
    self.table_name = "maker_calculations"

    # THE PANEL HAS NO PAGINATION, so a project holds at most this many. It also stands in for a rate
    # limit: this is a per-user write door a person drives by hand, like tasks and connections.
    CAP = 100
    LABEL_MAX = 120
    EXPRESSION_MAX = 500
    # The nearest 1/16 or 1/32 inch the modal offers for an inch result. NULL is decimal.
    INCH_FRACTIONS = [ 16, 32 ].freeze
    # EVERY UNIT lib/calc.js CAN ANSWER WITH: a length, its square or cube, an inverse, degrees, or
    # nothing. Anything else did not come from the modal.
    LENGTHS = %w[mm cm m in ft].freeze
    UNITS = ([ "", "°" ] + LENGTHS.flat_map { |u| [ u, "#{u}²", "#{u}³", "1/#{u}", "1/#{u}²", "1/#{u}³" ] }).freeze

    belongs_to :user
    belongs_to :project, class_name: "Maker::Project"

    normalizes :label, with: ->(s) { s.to_s.squish }
    normalizes :expression, with: ->(s) { s.to_s.strip }
    normalizes :unit, with: ->(s) { s.to_s.strip }

    validates :label, presence: { message: "can't be blank — name it, like “Shelf depth”" },
                      length: { maximum: LABEL_MAX }
    validates :expression, presence: true, length: { maximum: EXPRESSION_MAX }
    validates :result, numericality: true
    validates :unit, inclusion: { in: UNITS, message: "isn't one the calculator uses" }
    validates :inch_fraction, inclusion: { in: INCH_FRACTIONS }, allow_nil: true
    validate :finite_result
    validate :fraction_only_for_inches
    validate :project_belongs_to_user
    validate :under_the_cap, on: :create

    # Oldest first, the order a maker worked them out in.
    scope :ordered, -> { order(:created_at, :id) }

    private

    # `numericality` accepts Infinity and NaN (both are Floats), and neither is anything the panel
    # could show.
    def finite_result
      errors.add(:result, "must be a finite number") if result.is_a?(Float) && !result.finite?
    end

    def fraction_only_for_inches
      errors.add(:inch_fraction, "applies to an inch result only") if inch_fraction && unit != "in"
    end

    # The *_belongs_to_user rule (CLAUDE.md §14d). UNCONDITIONAL, not `if: project_id.present?`:
    # `project_id` is NOT NULL and there is no other target, so an absent or dangling id is simply
    # refused — never a row locked by a pointer that later went missing, because a project's
    # `dependent: :destroy` takes its calculations with it.
    def project_belongs_to_user
      return if Maker::Project.exists?(id: project_id, user_id: user_id)

      errors.add(:project_id, "must reference your own project")
    end

    def under_the_cap
      return if project_id.nil? || Maker::Calculation.where(project_id:).count < CAP

      errors.add(:base, "A project holds #{CAP} saved calculations. Delete one first.")
    end
  end
end
