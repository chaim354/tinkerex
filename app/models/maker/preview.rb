module Maker
  # Catalog-side preview record: one per (node_id, version_id, kind). References a synced
  # file ONLY by its stable string node_id + immutable version_id (never synced into the
  # local SQLite tree). Carries a rendered thumbnail/render as an ActiveStorage attachment;
  # bytes are served via the blob URL (off Rails), consistent with CLAUDE.md §8/§15.
  class Preview < ApplicationRecord
    self.table_name = "maker_previews"

    belongs_to :user
    has_one_attached :asset

    # `geometry` is a JSON payload, not an image — the coordinates behind the .lbrn2 Measure view.
    # It is the FIRST kind to exercise the kind seam end to end: `model_glb` is declared here but
    # refused by Mesh, so nothing in production produced a second artifact until this one.
    KINDS = %w[thumbnail model_glb render geometry].freeze
    # pending → processing → ready | failed | unsupported.
    # `unsupported` = no permissive renderer for this file type (a deliberate, non-error
    # terminal state; distinct from `failed` = a real render/fetch error).
    STATUSES = %w[pending processing ready failed unsupported].freeze
    # THE TWO STATUSES THAT CLAIM A JOB IS COMING — named once, because nothing verifies the claim
    # but `Maker::Previews::Enqueue::STALLED_AFTER`, and a status added to this set later must be
    # healed by the same window.
    IN_FLIGHT = %w[pending processing].freeze

    validates :node_id, presence: true
    validates :kind,    inclusion: { in: KINDS }
    validates :status,  inclusion: { in: STATUSES }
    # ONE ROW PER (user, node, kind) — see 20260730001500_one_preview_per_node_and_kind.rb. The
    # scope used to include version_id, which is what made every save mint a row and strand its
    # predecessor. `version_id` is now a MUTABLE column recording which content the attached asset
    # was rendered from, and Enqueue repoints it.
    validates :node_id, uniqueness: { scope: %i[user_id kind] }

    scope :ready,       -> { where(status: "ready") }
    scope :of_kind,     ->(k) { where(kind: k) if k.present? }
    scope :for_node,    ->(n) { where(node_id: n) if n.present? }
    scope :for_version, ->(v) { where(version_id: v) if v.present? }
  end
end
