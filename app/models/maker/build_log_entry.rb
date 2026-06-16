module Maker
  class BuildLogEntry < ApplicationRecord
    self.table_name = "maker_build_log_entries"

    belongs_to :user
    belongs_to :project, class_name: "Maker::Project"

    ENTRY_TYPES = %w[note milestone].freeze

    has_many :file_attachments, -> { order(:position) },
             as: :attachable, class_name: "Maker::FileAttachment", dependent: :destroy

    before_validation :ensure_logged_at, on: :create

    validates :body, presence: true
    validates :entry_type, inclusion: { in: ENTRY_TYPES }
    validates :logged_at, presence: true

    private

    def ensure_logged_at
      self.logged_at ||= Time.current
    end
  end
end
