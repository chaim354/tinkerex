module Maker
  class FileAttachment < ApplicationRecord
    self.table_name = "maker_file_attachments"

    belongs_to :user
    belongs_to :attachable, polymorphic: true

    ROLES = %w[model instructions image source_archive gcode other].freeze

    validates :node_id, presence: true
    validates :role, inclusion: { in: ROLES }
  end
end
