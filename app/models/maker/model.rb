module Maker
  # A 3D-print model in the catalog: a cover, metadata, its files (via the polymorphic
  # FileAttachment), tags, and a print log. Distinct from Maker::Project (a build). Its files
  # live at Models/<slug>/ in the ordinary file library — this record is a curated view over
  # them, so nothing here touches sync/changelog/mounts (§10).
  #
  # THE WEB APP'S CATALOG, and narrower than Maker::Item, which is the desktop client's. A Model
  # is a 3D-print model specifically — swept in by Maker::ModelIntake, shelf-scoped, dismissible;
  # an Item is any maker artefact and exists only if something POSTs /v1/maker/items. tinkerex#153
  # settled that both survive; the split is written down in docs/invariants/model-intake.md.
  class Model < ApplicationRecord
    self.table_name = "maker_models"

    PRINT_STATUSES = %w[want_to_print printed failed].freeze

    # WHICH DOOR WROTE THE ROW. "import" is models#new; "auto" is Maker::ModelIntake's sweep over
    # the library. The two differ in exactly one user-visible way -- see ModelsController#destroy.
    # Named for that question, not for its `origin` column, because Maker::Item's origin answers a
    # different one (how the thing was obtained) — see Maker::Item::ACQUISITION_ORIGINS.
    ROW_ORIGINS = %w[import auto].freeze

    belongs_to :user

    has_many :file_attachments, -> { order(:position) },
             as: :attachable, class_name: "Maker::FileAttachment", dependent: :destroy
    has_many :taggings, as: :taggable, class_name: "Maker::Tagging", dependent: :destroy
    has_many :tags, through: :taggings, class_name: "Maker::Tag"
    has_many :print_runs, -> { order(:printed_on, :id) },
             class_name: "Maker::PrintRun", dependent: :destroy

    before_validation :ensure_slug
    after_save :apply_pending_tag_list

    validates :title, presence: true
    validates :slug, presence: true, uniqueness: { scope: :user_id }
    validates :print_status, inclusion: { in: PRINT_STATUSES }
    validates :origin, inclusion: { in: ROW_ORIGINS }

    scope :by_status, ->(s) { where(print_status: s) if s.present? }

    # WHAT /models SHOWS. A dismissed auto model is the user's "I do not want this" and is
    # permanent; the row survives only so the next sweep does not recreate it.
    scope :catalogued, -> { where(dismissed_at: nil) }

    def auto? = origin == "auto"

    def to_param = slug

    # The node representing this model: explicit override, else first image, else first model file
    # (its rendered 3D thumbnail via Maker::Previews), else the first attachment by position, else
    # nil. Reads loaded file_attachments; callers rendering many cards should include(:file_attachments).
    def cover_node_id
      self[:cover_node_id].presence || derived_cover_node_id
    end

    # Comma-separated tag names, for the edit form. Writing find-or-creates the user's tags and
    # replaces the set (Maker::Tag normalizes name to stripped-downcase and is unique per user).
    def tag_list
      tags.map(&:name).sort.join(", ")
    end

    # Comma-separated tag names, for the edit form. Writing find-or-creates the user's tags and
    # REPLACES the set on the next save (deferred so it's safe on a new, unsaved record too).
    def tag_list=(str)
      @tag_list_pending = str
    end

    # Return the model's library folder node, (re)creating `Models/<slug>` if folder_node_id is
    # nil or points at a tombstoned/missing node (the user deleted it in the Files browser). Called
    # best-effort at create time (the controller rescues) and authoritatively at upload time, so it
    # must be idempotent — Maker::LibraryFolder.ensure_path! is.
    def ensure_library_folder!(acting_user)
      if folder_node_id.present?
        live = acting_user.nodes.present.find_by(node_id: folder_node_id, kind: "dir")
        return live if live
      end
      folder = Maker::LibraryFolder.ensure_path!(acting_user, [ "Models", slug ])
      update_column(:folder_node_id, folder.node_id)
      folder
    end

    private

    # Friendly URLs + collision-proof: two "Benchy" imports must both succeed, so a taken slug
    # gets -2, -3, ... (Project fails validation on collision; import can't afford that).
    def ensure_slug
      base = (slug.presence || title).to_s.strip.downcase
               .gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
      base = "model" if base.blank?
      candidate = base
      n = 2
      while user && user.maker_models.where.not(id: id).exists?(slug: candidate)
        candidate = "#{base}-#{n}"
        n += 1
      end
      self.slug = candidate
    end

    def derived_cover_node_id
      atts = file_attachments.sort_by { |a| [ a.position, a.id ] }
      pick = atts.find { |a| a.role == "image" } ||
             atts.find { |a| a.role == "model" } ||
             atts.first
      pick&.node_id
    end

    def apply_pending_tag_list
      return unless defined?(@tag_list_pending)
      names = @tag_list_pending.to_s.split(",").map { |n| n.strip.downcase }.reject(&:blank?).uniq
      wanted = names.map { |n| user.maker_tags.find_or_create_by!(name: n) }
      transaction do
        taggings.where.not(tag_id: wanted.map(&:id)).destroy_all
        wanted.each { |t| taggings.find_or_create_by!(user: user, tag: t) }
      end
      remove_instance_variable(:@tag_list_pending)
    end
  end
end
