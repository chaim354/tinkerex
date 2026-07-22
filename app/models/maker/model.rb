module Maker
  # A 3D-print model in the catalog: a cover, metadata, its files (via the polymorphic
  # FileAttachment), tags, and a print log. Distinct from Maker::Project (a build). Its files
  # live at Models/<slug>/ in the ordinary file library — this record is a curated view over
  # them, so nothing here touches sync/changelog/mounts (§10).
  class Model < ApplicationRecord
    self.table_name = "maker_models"

    PRINT_STATUSES = %w[want_to_print printed failed].freeze

    belongs_to :user

    has_many :file_attachments, -> { order(:position) },
             as: :attachable, class_name: "Maker::FileAttachment", dependent: :destroy
    has_many :taggings, as: :taggable, class_name: "Maker::Tagging", dependent: :destroy
    has_many :tags, through: :taggings, class_name: "Maker::Tag"
    # NOTE: no `dependent: :destroy` yet — Maker::PrintRun doesn't exist until Task 2, and
    # a has_many's dependent-destroy callback resolves its class_name eagerly (even with zero
    # rows), so declaring it now would raise NameError on every Maker::Model#destroy. Task 2
    # should add `dependent: :destroy` back once Maker::PrintRun exists.
    has_many :print_runs, -> { order(:printed_on, :id) },
             class_name: "Maker::PrintRun"

    before_validation :ensure_slug

    validates :title, presence: true
    validates :slug, presence: true, uniqueness: { scope: :user_id }
    validates :print_status, inclusion: { in: PRINT_STATUSES }

    scope :by_status, ->(s) { where(print_status: s) if s.present? }

    def to_param = slug

    # Friendly URLs + collision-proof: two "Benchy" imports must both succeed, so a taken slug
    # gets -2, -3, ... (Project fails validation on collision; import can't afford that).
    def ensure_slug
      base = (slug.presence || title).to_s.strip.downcase
               .gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
      return if base.blank?
      candidate = base
      n = 2
      while user && user.maker_models.where.not(id: id).exists?(slug: candidate)
        candidate = "#{base}-#{n}"
        n += 1
      end
      self.slug = candidate
    end
  end
end
