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

    # ONE LABEL PER STATUS, READ BY BOTH THE FILTER AND THE BADGE — and the pair is the whole point.
    # Until 2026-09-10 the /models toolbar chip said "Wanted" while the badge on the card beside it
    # said "Want To Print": the chip's label was a literal in the view, the badge rendered
    # `print_status.tr("_", " ")`, and `.badge { text-transform: capitalize }` title-cased the
    # result. Same state, two words, one screen. `capitalize` is gone from the badge (decision 5 of
    # the UI-cohesion spec: a text-transform cannot know that `want_to_print` reads "Wanted"), so a
    # label MUST come from here. Same shape as Maker::ProjectKind::LABELS, for the same reason.
    #
    # "WANT TO PRINT", NOT "WANTED" (UX audit 2026-11-01, E2): the chip said "Wanted" while the edit
    # form, building its own options, said "Want to print". The form reads this hash now, and the
    # label is the form's longer phrase, because "Wanted" on a model nobody chose read as a claim.
    PRINT_STATUS_LABELS = {
      "want_to_print" => "Want to print", "printed" => "Printed", "failed" => "Failed"
    }.freeze

    # Falls back to the humanised status rather than raising: `print_status` is validated, so an
    # unknown value means a migration added one and forgot this hash — a readable word beats a 500,
    # and cohesion_vocabulary_test.rb pins that every PRINT_STATUSES member has a label so the fallback is
    # not load-bearing.
    def self.print_status_label(status) =
      PRINT_STATUS_LABELS.fetch(status.to_s) { status.to_s.tr("_", " ").upcase_first }

    def print_status_label = self.class.print_status_label(print_status)

    # THE COLUMN'S DEFAULT IS NOT NEWS, SO IT WEARS NO BADGE (E2). Every model the sweep finds starts
    # at it, so a badge saying so sat on every one of them and said nothing; a status somebody or a
    # logged print SET is the one worth a badge. Read from the schema, so the two cannot disagree.
    def default_print_status? = print_status == self.class.column_defaults["print_status"]

    # WHICH DOOR WROTE THE ROW. "import" is models#new; "auto" is Maker::ModelIntake's sweep over
    # the library. The two differ in exactly one user-visible way -- see ModelsController#destroy.
    # Named for that question, not for its `origin` column, because Maker::Item's origin answers a
    # different one (how the thing was obtained) — see Maker::Item::ACQUISITION_ORIGINS.
    ROW_ORIGINS = %w[import auto].freeze

    belongs_to :user

    has_many :file_attachments, -> { order(:position) },
             as: :attachable, class_name: "Maker::FileAttachment", dependent: :destroy
    # Tags (taggings/tags, tag_list, tag_list=, apply_pending_tag_list, tagged_with) are
    # Maker::Taggable now (stage 2, S2-5) -- lifted verbatim out of here, since Project and
    # InventoryItem need the identical behaviour and this is where it shipped first.
    include Maker::Taggable
    has_many :print_runs, -> { order(:printed_on, :id) },
             class_name: "Maker::PrintRun", dependent: :destroy

    before_validation :ensure_slug

    validates :title, presence: true
    validates :slug, presence: true, uniqueness: { scope: :user_id }
    validates :print_status, inclusion: { in: PRINT_STATUSES }
    validates :origin, inclusion: { in: ROW_ORIGINS }

    scope :by_status, ->(s) { where(print_status: s) if s.present? }

    # WHAT THE 3D MODELS VIEW (/files/models) AND A FOLDER'S MODEL STRIP SHOW (Maker::ModelFolder).
    # A dismissed auto model is the user's "I do not want this" and is
    # permanent; the row survives only so the next sweep does not recreate it.
    scope :catalogued, -> { where(dismissed_at: nil) }

    def auto? = origin == "auto"

    # A SWEEP-MADE MODEL WHOSE FILES ARE ALL GONE — an emptied folder. The catalog HIDES it rather
    # than dismissing or destroying it (docs/invariants/model-intake.md: the row keeps the title and
    # tags and returns the moment a file does), so every place that lists models must hide it the
    # same way: the 3D models view, a folder's model strip (Maker::ModelFolder), a project's Models
    # panel (Maker::ProjectModels) and the Add-model picker (Projects::ModelsController#new). ONE
    # predicate, because copies of the rule are chances to disagree — the picker's is the one copy,
    # in SQL because it must filter before its LIMIT, and it says so. Reads the loaded
    # :file_attachments when the caller included them.
    def hollow? = auto? && file_attachments.empty?

    def to_param = slug

    # The node representing this model: explicit override, else first image, else first model file
    # (its rendered 3D thumbnail via Maker::Previews), else the first attachment by position, else
    # nil. Reads loaded file_attachments; callers rendering many cards should include(:file_attachments).
    def cover_node_id
      self[:cover_node_id].presence || derived_cover_node_id
    end

    # WHAT TELLS ONE CARD FROM ANOTHER ON THE 3D MODELS VIEW (UX audit 2026-11-01, E1): the formats
    # of the model's own meshes and the folder it sits in. The sweep makes one model per file on a
    # shelf (docs/invariants/model-intake.md), so `tetra.stl`, `tetra.obj` and `tetra.off` side by
    # side are three models titled "tetra", and the cards were identical. `folder` is the model's own
    # folder when it has one, else its first mesh's folder; "" is the library root, and nil means the
    # chain could not be resolved (a tombstoned ancestor), which the card leaves out.
    #
    # CONSTANT IN QUERIES, whatever the number of models: one pluck of the meshes' names and parents,
    # and Maker::LibraryTree's one pluck of the dirs (path_for is its in-memory walk, the one ancestry
    # definition). Reads the LOADED :file_attachments, as `hollow?` and the cover do.
    CardFacts = Data.define(:extensions, :folder)

    def self.card_facts(user, models)
      return {} if models.empty?

      meshes = models.to_h { |m| [ m.id, m.file_attachments.select { |a| a.role == "model" }.map(&:node_id) ] }
      ids = meshes.values.flatten.uniq
      nodes = ids.empty? ? {} : user.nodes.present.where(node_id: ids).pluck(:node_id, :name, :parent_node_id)
                                    .to_h { |id, name, parent| [ id, [ name, parent ] ] }
      tree = Maker::LibraryTree.new(user)
      models.to_h do |m|
        live = meshes[m.id].filter_map { |id| nodes[id] }
        extensions = live.map { |name, _| File.extname(name).delete(".").upcase }.reject(&:empty?).uniq.sort
        dir = m.folder_node_id.presence || (live.first.last if live.any?)
        folder = tree.path_for(dir) if m.folder_node_id.present? || live.any?
        [ m.id, CardFacts.new(extensions:, folder:) ]
      end
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
  end
end
