class Node < ApplicationRecord
  belongs_to :user

  KINDS = %w[file dir].freeze

  validates :node_id, presence: true, uniqueness: { scope: :user_id }
  validates :name, presence: true
  validates :kind, inclusion: { in: KINDS }

  scope :present, -> { where(deleted: false) }

  def dir? = kind == "dir"
  def file? = kind == "file"

  def children
    user.nodes.present.where(parent_node_id: node_id)
  end

  def current_version
    return nil if current_version_id.blank?
    user.versions.find_by(version_id: current_version_id)
  end
end
