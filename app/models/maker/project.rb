module Maker
  class Project < ApplicationRecord
    self.table_name = "maker_projects"

    belongs_to :user

    STATUSES = %w[planning active paused done archived].freeze

    has_many :build_log_entries, -> { order(:logged_at) },
             class_name: "Maker::BuildLogEntry", dependent: :destroy
    has_many :file_attachments, -> { order(:position) },
             as: :attachable, class_name: "Maker::FileAttachment", dependent: :destroy
    # Tags (stage 2, S2-5): taggings/tags, tag_list, tag_list=, tagged_with -- Maker::Taggable,
    # shared with Maker::Model (where it shipped first) and Maker::InventoryItem.
    include Maker::Taggable
    has_many :tasks, as: :taskable, class_name: "Maker::Task", dependent: :destroy
    has_many :boms, class_name: "Maker::Bom", foreign_key: :project_id, dependent: :destroy
    has_many :sheets, -> { order(:position, :id) },
             class_name: "Maker::Sheet", foreign_key: :project_id, dependent: :destroy
    # `:nullify`, AND IT IS THE ONLY OPTION THAT WORKS — do not "normalise" it onto the
    # `:destroy` lines above. The ledger outlives the project on purpose: a transaction records
    # that stock actually moved, and `InventoryItem#quantity_cached` was computed from it, so
    # destroying the rows would silently desynchronise every item the project ever consumed.
    # `:destroy` is not merely wrong here, it RAISES — Maker::InventoryTransaction's unconditional
    # `before_destroy` refuses any record-level delete, which would take the whole project
    # deletion down with it (mutation-checked). `:nullify` writes through `update_all`, below the
    # `before_update` guard, and touches only the provenance pointer; delta and reason are
    # untouched.
    #
    # WITHOUT THIS LINE, DESTROYING A PROJECT LEFT ITS TRANSACTIONS POINTING AT NOTHING —
    # tinkerex#152 part (b) predicted an orphan of exactly this shape and
    # test/models/structural_orphan_test.rb found it. Neither side declared an association at all,
    # which is why nothing anywhere went red for it.
    has_many :inventory_transactions, class_name: "Maker::InventoryTransaction",
             foreign_key: :project_id, dependent: :nullify

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

    # THE BOM ON THE WEB: the latest revision, or nil if the project has none yet. ONE query
    # (`ORDER ... LIMIT 1`) -- Projects::BomLinesController#create is the only writer that MINTS
    # one, lazily, on the first line's POST; every reader (this method, ProjectsController#show,
    # Projects::BomsController#show) calls this rather than repeating the ORDER clause, so "latest
    # revision" has one definition (stage 2, S2-4).
    def current_bom
      boms.order(revision: :desc, id: :desc).first
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

    # THE ONE NORMALIZATION. Extracted from #ensure_slug so Maker::ProjectDiscovery can reuse it
    # without a second copy of the regex.
    def self.slugify(str)
      str.to_s.strip.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
    end

    # A SLUG AN UNATTENDED RUN CANNOT FAIL ON — the treatment Maker::Model#ensure_slug already gives
    # import, for the reason its own comment states: "Project fails validation on collision; import
    # can't afford that." A sweep can't afford it either, because nobody is there to read the error.
    #
    # TWO REACHABLE FAILURES, both of which raise inside a recurring job:
    #   * COLLISION — `Projects/desk-lamp` (a project's own folder) beside `Projects/Desk Lamp`
    #     (one the user made by hand). Both slugify to `desk-lamp`.
    #   * BLANK — slugify keeps only [a-z0-9], so ANY purely non-Latin name reduces to "":
    #     プロジェクト, Проект, 模型. `validates :slug, presence: true` then raises.
    #
    # #ensure_slug IS DELIBERATELY LEFT ALONE. A human typing a duplicate name into the web form
    # SHOULD be told; only the sweep gets the import treatment.
    def self.available_slug(user, from:)
      base = slugify(from)
      base = "project" if base.blank?
      candidate = base
      n = 2
      while user.maker_projects.exists?(slug: candidate)
        candidate = "#{base}-#{n}"
        n += 1
      end
      candidate
    end

    private

    def ensure_slug
      source = slug.presence || name
      return if source.blank?
      self.slug = self.class.slugify(source)
    end
  end
end
