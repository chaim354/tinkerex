module Maker
  class Project < ApplicationRecord
    self.table_name = "maker_projects"

    belongs_to :user

    STATUSES = %w[planning active paused done archived].freeze

    # `autofile` (stage 4, S4-2; story 4.3): may Maker::ProjectIntake MOVE files inside this
    # project's folder? Default true — every project did this before the column existed. Off, the
    # sweep still ATTACHES what it finds; see ProjectIntake#call for why those two halves split.
    #
    # `last_swept_at` / `last_sweep_moves` are what the LAST sweep did, written by
    # ProjectIntake#record_sweep! and read by the Files panel. `last_sweep_moves` is nil until a
    # sweep that was allowed to file has finished once — nil and 0 are different facts.

    # PUBLISHING (stage 3, S3-4; spec §2.5). private is the default and the only state with no
    # public URL; unlisted needs the token; public is listed on /u/:handle and /explore.
    VISIBILITIES = %w[private unlisted public].freeze
    # SPDX ids → labels. Hardware-first: the three CERN OHL v2 flavours, then the usual suspects.
    LICENSES = {
      "CERN-OHL-P-2.0" => "CERN OHL v2 Permissive",
      "CERN-OHL-W-2.0" => "CERN OHL v2 Weakly Reciprocal",
      "CERN-OHL-S-2.0" => "CERN OHL v2 Strongly Reciprocal",
      "TAPR-OHL-1.0"   => "TAPR Open Hardware License",
      "CC-BY-4.0"      => "Creative Commons Attribution 4.0",
      "CC-BY-SA-4.0"   => "Creative Commons Attribution-ShareAlike 4.0",
      "CC0-1.0"        => "CC0 1.0 (public domain)",
      "MIT"            => "MIT",
      "Apache-2.0"     => "Apache 2.0",
      "GPL-3.0-or-later" => "GNU GPL v3 or later"
    }.freeze

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
    # THE WIRING TABLE (stage 3, S3-3): connections between two labelled ends, in position order.
    has_many :connections, -> { order(:position, :id) },
             class_name: "Maker::Connection", foreign_key: :project_id, dependent: :destroy
    # RELEASES (stage 3, S3-5), newest first — the order both panels read, stated once here rather
    # than in each. `:destroy` rather than `:nullify`: a release names the project in its own
    # `project_belongs_to_user` validation, so a nulled pointer would be an unsaveable row (§14d).
    has_many :releases, -> { order(published_at: :desc, id: :desc) },
             class_name: "Maker::Release", foreign_key: :project_id, dependent: :destroy
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
    before_validation :mint_unlisted_token

    normalizes :license, with: ->(l) { l.to_s.strip.presence }

    validates :name, presence: true
    validates :slug, presence: true, uniqueness: { scope: :user_id }
    validates :status, inclusion: { in: STATUSES }
    validates :visibility, inclusion: { in: VISIBILITIES }
    validates :license, inclusion: { in: LICENSES.keys }, allow_nil: true
    validate :publishing_needs_a_handle

    scope :by_status, ->(s) { where(status: s) if s.present? }
    scope :active, -> { where(status: "active") }
    # What User#handle_locked? reads: anything with a public URL to break.
    scope :published,       -> { where.not(visibility: "private") }
    scope :publicly_listed, -> { where(visibility: "public") }

    def published?       = visibility != "private"
    def unlisted?        = visibility == "unlisted"
    def publicly_listed? = visibility == "public"
    def license_label    = LICENSES[license]

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

    # A HANDLE BEFORE A URL. The public URL is /u/<handle>/<slug>; with no handle there is no URL,
    # so the switch away from private refuses rather than minting a page nobody can reach.
    def publishing_needs_a_handle
      return unless published? && user&.handle.blank?

      errors.add(:visibility, "needs a handle first — choose one under Settings → Account")
    end

    # MINTED THE FIRST TIME A PROJECT LEAVES private AND NEVER CLEARED OR ROTATED: an unlisted link
    # someone was given keeps working across unlisted → public → unlisted. 32 hex = 128 bits.
    # `||=`, NOT `=` -- reminting on every save would silently invalidate a link already handed out.
    def mint_unlisted_token
      self.unlisted_token ||= SecureRandom.hex(16) if published?
    end

    def ensure_slug
      source = slug.presence || name
      return if source.blank?
      self.slug = self.class.slugify(source)
    end
  end
end
