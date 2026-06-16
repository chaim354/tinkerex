module Maker
  # Catalog-side preview record: one per (node_id, version_id, kind). References a synced
  # file ONLY by its stable string node_id + immutable version_id (never synced into the
  # local SQLite tree). Carries a rendered thumbnail/render as an ActiveStorage attachment;
  # bytes are served via the blob URL (off Rails), consistent with CLAUDE.md §8/§15.
  class Preview < ApplicationRecord
    self.table_name = "maker_previews"

    belongs_to :user
    has_one_attached :asset

    KINDS = %w[thumbnail model_glb render].freeze
    # pending → processing → ready | failed | unsupported.
    # `unsupported` = no permissive renderer for this file type (a deliberate, non-error
    # terminal state; distinct from `failed` = a real render/fetch error).
    STATUSES = %w[pending processing ready failed unsupported].freeze

    validates :node_id, presence: true
    validates :kind,    inclusion: { in: KINDS }
    validates :status,  inclusion: { in: STATUSES }
    validates :node_id, uniqueness: { scope: %i[user_id version_id kind] }

    scope :ready,       -> { where(status: "ready") }
    scope :of_kind,     ->(k) { where(kind: k) if k.present? }
    scope :for_node,    ->(n) { where(node_id: n) if n.present? }
    scope :for_version, ->(v) { where(version_id: v) if v.present? }
  end
end
