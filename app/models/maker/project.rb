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

    # `discovered_at` / `opened_at` (stage 4, S4-6): see the migration for the full argument.
    # WRITTEN BY EXACTLY TWO PLACES AND NOWHERE ELSE — Maker::ProjectDiscovery stamps the first as
    # it creates a row, ProjectsController#show stamps the second once. Projects::AdoptionsController
    # leaves discovered_at nil ON PURPOSE and says so at its own create!: an adopted project is one
    # the maker made, so it is never "new to you" and never wears the badge.

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

    # THE PROJECT'S TYPE (stage 4, S4-7; decision D4). Suggested from what the folder holds when
    # the app creates the project (Maker::ProjectDiscovery, S4-6's adoption door), editable on the
    # edit form, and never re-derived afterwards — re-suggesting would silently rearrange a page
    # the maker may have arranged themselves, and nothing could tell the two apart.
    KINDS = %w[laser print cnc electronics mixed other].freeze

    # THE PROJECT PAGE'S PANEL LIST, AS DATA (stage 4, S4-7; story 6.5). This order IS `other`'s
    # preset, and `other` is the column default, so a migration alone changes no page (spec §4).
    #
    # ADD A PANEL HERE OR IT RENDERS FOR NOBODY. projects/show.html.erb loops over
    # `Maker::Project#visible_panels` and renders `projects/_<key>`; a tenth partial dropped into
    # the view directory with no entry here is a file no page reaches, and a `render` appended
    # under the loop is a panel the chooser cannot list — one question with two answers (§14a).
    # The key IS the partial's basename; keep them equal.
    #
    # `publish` IS THE TENTH AND LAST MEMBER because S4-4 landed `projects/_publish.html.erb`
    # (amendment 9's first branch, checked by `ls` at Task A step 1): the panel exists, so it goes
    # through the loop rather than being rendered under it.
    #
    # NOTHING OUTSIDE THIS CONSTANT MAY REACH THE LOOP. Maker::ProjectKind.layout_for intersects
    # every stored override with it and Projects::PanelsController intersects every write, so a
    # crafted request cannot put an unknown key in the `panels` column and `render` can never be
    # handed a partial name that does not exist.
    PANELS = %w[attachments photos schematics build_log tasks bom wiring releases sheets publish].freeze

    # HOW ONE PANEL DRAWS WHAT IT HOLDS (2026-09-08, folder panels; spec decision 6). Per panel and
    # persisted in `panels["views"]`, which is what retired the page-wide `project_view` cookie: a
    # maker who wants their models as tiles and their firmware checkout as the Finder browser could
    # not have both while one cookie answered for every section.
    #
    # `browser` IS THE MILLER-COLUMNS BROWSER AND IT NEEDS A SESSION (LibraryBrowseController), so
    # the visitor's page reads it as `list` (spec decision 7) rather than mounting a control that
    # would ask for a route no anonymous request may take. Maker::ProjectKind.default_view says
    # which of the three a panel opens in when the maker has not chosen; this list is the whole
    # vocabulary, and layout_for drops any value outside it.
    VIEWS = %w[tiles list browser].freeze

    # What the chooser calls each one. Its own map rather than `key.humanize`, because three of the
    # ten disagree with what humanize would say: `attachments` is "Files" (the panel has been
    # headed Files since S2-2 — the key is the partial's name, and renaming the partial would touch
    # eight call sites), `bom` is "Bill of materials", and `build_log` is "Build log", not
    # "Build Log". A chooser whose labels differ from the headings above them is a chooser nobody
    # trusts. Totality pinned in project_kind_test.rb.
    PANEL_LABELS = {
      "attachments" => "Files", "photos" => "Photos", "schematics" => "Schematics",
      "build_log" => "Build log", "tasks" => "Tasks", "bom" => "Bill of materials",
      "wiring" => "Wiring", "releases" => "Releases", "sheets" => "Sheets", "publish" => "Publish"
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
    # CONTENT BLOCKS (2026-09-09): text, link and image blocks the page editor arranges beside the
    # panels. Row order is creation order; the LAYOUT orders them on the page.
    has_many :blocks, -> { order(:id) },
             class_name: "Maker::ProjectBlock", foreign_key: :project_id, dependent: :destroy
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
    # NO VALIDATION ON `panels`, AND THAT IS DELIBERATE: the READ is what has to be safe, and
    # Maker::ProjectKind.layout_for is total (its own comment says why). A write-time validation
    # could be bypassed by the v1 API, a console or a later migration; the read cannot.
    validates :kind, inclusion: { in: KINDS }
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

    # The kind's preferred roles first, then the first attachment by position, else nil. Reads the
    # loaded/queried file_attachments; callers that render many cards should
    # include(:file_attachments).
    #
    # THE KIND ONLY REORDERS THE PREFERENCE; IT ADDS NO QUERY AND NO NEW SOURCE (stage 4, S4-7;
    # story 6.3). `hero_roles("other")` is `%w[image model]`, which is exactly what this method did
    # before — first image, else first model, else the first attachment — so every existing project
    # picks the cover it always picked. A 3D-print project prefers a model and an electronics
    # project a board.
    #
    # IT STILL READS THE RELATION, NEVER THE FOLDER, and must keep doing so: #cover_node_id is
    # called once per card on the index, and the comment above forbids a query here for that
    # reason. A discovered project's folder files ARE attachments (Maker::ProjectIntake attaches
    # everything it finds), so the preference has real material to choose from.
    #
    # A STORED `cover_node_id` STILL WINS, because #cover_node_id checks the column first: a preset
    # is a guess about a project, a chosen cover is an answer to the same question, and a guess must
    # never overrule an answer. The stored one is also stable while this one moves as attachments
    # change — which is the asymmetry the column exists to give.
    def derived_cover_node_id
      atts = file_attachments.sort_by { |a| [ a.position, a.id ] }
      pick = Maker::ProjectKind.hero_roles(kind).filter_map { |role| atts.find { |a| a.role == role } }.first
      (pick || atts.first)&.node_id
    end

    # THE BOM ON THE WEB: the latest revision, or nil if the project has none yet. ONE query
    # (`ORDER ... LIMIT 1`) -- Projects::BomLinesController#create is the only writer that MINTS
    # one, lazily, on the first line's POST; every reader (this method, ProjectsController#show,
    # Projects::BomsController#show) calls this rather than repeating the ORDER clause, so "latest
    # revision" has one definition (stage 2, S2-4).
    def current_bom
      boms.order(revision: :desc, id: :desc).first
    end

    # THE PAGE'S LAYOUT: this kind's preset with this project's own overrides on top (stage 4,
    # S4-7). ProjectsController#show, projects/_panel_slot and Maker::PublicProject all read
    # THIS, so the maker's page and a visitor's cannot disagree about what is hidden.
    #
    # NOT MEMOIZED. It is array arithmetic over ten strings, and a memo on a mutable attribute is a
    # stale read waiting for the first caller that writes `panels` and reads the layout back in the
    # same request — which is exactly what Projects::PanelsController does.
    # `folders:` IS THE PROJECT'S CURRENT DEPTH-ONE FOLDERS — Maker::ProjectFolderListing
    # #panel_folders, `[[node_id, repo?], …]` — and it DEFAULTS TO `[]` so a caller holding no
    # listing keeps the fixed-key layout it has always had. A caller that HAS one passes it: the
    # layout's totality is against the folders that exist NOW (Maker::ProjectKind's header), so a
    # page that renders folder panels and a chooser that lists them must both say which folders
    # they are, or the folder keys drop out as stale and the panels vanish.
    # `blocks:` IS THE SAME DEAL AS `folders:` (2026-09-09, content blocks): `[[key, kind], …]` for
    # this project's Maker::ProjectBlock rows, defaulting to `[]` so a caller that renders no
    # blocks keeps exactly the layout it has always had. The block keys are part of the vocabulary,
    # so a caller that does render them must say which they are or they drop out as stale — the
    # totality rule the folder keys already run on.
    def panel_layout(folders: [], blocks: []) =
      Maker::ProjectKind.layout_for(kind:, overrides: self[:panels], folders:, blocks:)

    def visible_panels(folders: [], blocks: []) = panel_layout(folders:, blocks:).visible

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

    # Return the project's library folder node, or NIL. Idempotent — Maker::LibraryFolder.ensure_path!
    # is — and called best-effort at create time (the controller rescues) and authoritatively at
    # upload time.
    #
    # IT MINTS `Projects/<slug>` ONLY WHEN `folder_node_id` IS NIL (stage 4, S4-6; decision 2), and
    # A TOMBSTONED FOLDER IS NEVER SILENTLY RE-MINTED, for any project. It used to re-mint whenever
    # the column named a missing or tombstoned node, which meant deleting a project's folder in
    # Finder — the maker's own act — was answered by a new empty `Projects/<slug>` appearing behind
    # their back on the next page view, and the files they deleted were still in the trash under the
    # OLD node_id where `undelete` could still find them (§14a's two tombstone kinds). Since S4-6 a
    # project's folder can also be a folder ANYWHERE in the library, so re-minting would additionally
    # mint a SECOND folder in a place the maker never chose.
    #
    # NIL IS PART OF THE CONTRACT, not a failure: every caller answers it as "no folder yet" —
    # ProjectsController#show renders the Files panel's "in the trash or was removed" sentence,
    # Maker::ProjectFolderListing answers `available? == false`, and an upload falls back to the
    # library root. A project whose folder_node_id was never set (the form path) still mints, which
    # is what #create depends on.
    def ensure_library_folder!(acting_user)
      return acting_user.nodes.present.find_by(node_id: folder_node_id, kind: "dir") if folder_node_id.present?

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
