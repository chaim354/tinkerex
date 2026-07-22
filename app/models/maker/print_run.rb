module Maker
  # One logged print of a Model. On every save/destroy it recomputes the parent model's
  # print_status from the MOST RECENT run (latest printed_on, tie-break id): success -> printed,
  # failed -> failed. If no runs remain, the status is left untouched (never reset) — it may have
  # been set manually. The pill stays manually editable, so this is a convenience default.
  class PrintRun < ApplicationRecord
    self.table_name = "maker_print_runs"

    OUTCOMES = %w[success failed].freeze

    belongs_to :user
    belongs_to :model, class_name: "Maker::Model"

    before_validation { self.user ||= model&.user }

    validates :printed_on, presence: true
    validates :outcome, inclusion: { in: OUTCOMES }

    after_save    :sync_model_status
    after_destroy :sync_model_status

    private

    def sync_model_status
      latest = Maker::PrintRun.where(model_id: model_id).order(:printed_on, :id).last
      return unless latest
      model.update_column(:print_status, latest.outcome == "success" ? "printed" : "failed")
    end
  end
end
