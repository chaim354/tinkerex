module Maker
  class Project < ApplicationRecord
    self.table_name = "maker_projects"

    belongs_to :user

    STATUSES = %w[planning active paused done archived].freeze

    has_many :build_log_entries, -> { order(:logged_at) },
             class_name: "Maker::BuildLogEntry", dependent: :destroy
    has_many :file_attachments, -> { order(:position) },
             as: :attachable, class_name: "Maker::FileAttachment", dependent: :destroy
    has_many :tasks, as: :taskable, class_name: "Maker::Task", dependent: :destroy
    has_many :boms, class_name: "Maker::Bom", foreign_key: :project_id, dependent: :destroy
    has_many :sheets, -> { order(:position, :id) },
             class_name: "Maker::Sheet", foreign_key: :project_id, dependent: :destroy

    before_validation :ensure_slug

    validates :name, presence: true
    validates :slug, presence: true, uniqueness: { scope: :user_id }
    validates :status, inclusion: { in: STATUSES }

    scope :by_status, ->(s) { where(status: s) if s.present? }
    scope :active, -> { where(status: "active") }

    # Friendly, user-scoped URLs (/projects/desk-lamp). Slugs are unique per user, so a
    # current_user-scoped find_by(slug:) is unambiguous. Does NOT change JSON `id` (the v1 API
    # serializes explicit fields / #id), only URL generation.
    def to_param = slug

    # The node_id whose thumbnail represents this project on the list.
    #
    # THE USER'S CHOICE WINS; THE DERIVED PICK IS THE FALLBACK. The column is nullable and a blank
    # value means "nobody has chosen", which is the state every project was in before the column
    # existed — so adding it changed no project's appearance, it only made the choice expressible.
    # Overriding the generated attribute reader (rather than naming the method something else) is
    # what keeps `ProjectsController#index`, `ThumbnailMap` and every view working unchanged.
    #
    # A CHOSEN COVER WHOSE NODE HAS SINCE BEEN DELETED IS NOT CHECKED HERE, deliberately: liveness
    # is a query, and this is called once per card on the index, so asking would turn one page into
    # an N+1. It degrades honestly instead — `Maker::Previews::ThumbnailMap` is best-effort and a
    # dead node simply yields no thumbnail, so the card falls back to its placeholder — and
    # `Maker::AttachmentReaper` NULLs the column once the node's undo window has closed, at which
    # point the derived pick takes over again.
    def cover_node_id
      self[:cover_node_id].presence || derived_cover_node_id
    end

    # First image, else first model, else the first attachment by position, else nil. Reads the
    # loaded/queried file_attachments; callers that render many cards should
    # include(:file_attachments).
    def derived_cover_node_id
      atts = file_attachments.sort_by { |a| [ a.position, a.id ] }
      pick = atts.find { |a| a.role == "image" } ||
             atts.find { |a| a.role == "model" } ||
             atts.first
      pick&.node_id
    end

    def archive!
      update!(status: "archived", archived_at: Time.current)
    end

    # The inverse of archive!. "active" rather than the "planning" column default: a project you
    # deliberately pull back out of the archive is one you are working on again. The web UI shows
    # neither value — it reads status as archived-or-not (spec decision #1) — but the v1 API and
    # the desktop app still see the full vocabulary, so this has to name a real member of STATUSES.
    def unarchive!
      update!(status: "active", archived_at: nil)
    end

    # Return the project's library folder node, (re)creating `Projects/<slug>` if folder_node_id is
    # nil or points at a tombstoned/missing node (the user deleted it in the Files browser). Called
    # best-effort at create time (the controller rescues) and authoritatively at upload time, so it
    # must be idempotent — Maker::LibraryFolder.ensure_path! is.
    def ensure_library_folder!(acting_user)
      if folder_node_id.present?
        live = acting_user.nodes.present.find_by(node_id: folder_node_id, kind: "dir")
        return live if live
      end
      folder = Maker::LibraryFolder.ensure_path!(acting_user, [ Maker::ProjectFolders::ROOT, slug ])
      update_column(:folder_node_id, folder.node_id)
      folder
    end

    private

    def ensure_slug
      source = slug.presence || name
      return if source.blank?
      self.slug = source.to_s.strip.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
    end
  end
end
