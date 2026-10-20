module Maker
  # Catalog-side preview record: ONE PER (user, node_id, kind), repointed as the file's content and
  # renderer move (§14b) — `version_id` records which content the attached asset was rendered from,
  # it is not part of the key. References a file ONLY by its stable string node_id. Carries a
  # rendered thumbnail/render as an ActiveStorage attachment; bytes are served via the blob URL
  # (off Rails), consistent with CLAUDE.md §8/§15.
  class Preview < ApplicationRecord
    self.table_name = "maker_previews"

    belongs_to :user
    has_one_attached :asset

    # `geometry` is a JSON payload, not an image — the coordinates behind the .lbrn2 Measure view.
    # It is the FIRST kind to exercise the kind seam end to end: `model_glb` is declared here but
    # refused by Mesh, so nothing in production produced a second artifact until this one.
    KINDS = %w[thumbnail model_glb render geometry].freeze
    # THE KIND WHOSE ARTIFACT IS DATA, MEASURED FROM RATHER THAN LOOKED AT: an older build of it is
    # wrong, not merely old (§14h). Every other kind is a picture of the file.
    MEASURED_KINDS = %w[geometry].freeze
    # pending → processing → ready | failed | unsupported, and ready → rebuilding → ready when only
    # the RENDERER moved. `unsupported` = no permissive renderer for this file type (a deliberate,
    # non-error terminal state; distinct from `failed` = a real render/fetch error).
    #
    # `rebuilding` IS A READY ROW WHOSE NEXT BUILD IS QUEUED (F-S08-2, 2026-10-20). Its asset is a
    # picture of THIS content made by older code, so it stays on screen; it is still not the build
    # its coordinates name, so nothing that measures from it may read it as ready. Before this
    # value existed both facts were spelled `ready`, and the Measure poll served an older build's
    # payload for as long as the rebuild sat in the queue.
    STATUSES = %w[pending processing rebuilding ready failed unsupported].freeze
    # THE STATUSES THAT CLAIM A JOB IS COMING — named once, because nothing verifies the claim but
    # `Maker::Previews::Enqueue::STALLED_AFTER`, and a status added to this set must be healed by
    # the same window. `rebuilding` is in it: a rebuild whose job was lost would otherwise show an
    # older build for good.
    IN_FLIGHT = %w[pending processing rebuilding].freeze

    validates :node_id, presence: true
    validates :kind,    inclusion: { in: KINDS }
    validates :status,  inclusion: { in: STATUSES }
    # ONE ROW PER (user, node, kind) — see 20260730001500_one_preview_per_node_and_kind.rb. The
    # scope used to include version_id, which is what made every save mint a row and strand its
    # predecessor. `version_id` is now a MUTABLE column recording which content the attached asset
    # was rendered from, and Enqueue repoints it.
    validates :node_id, uniqueness: { scope: %i[user_id kind] }

    scope :of_kind,     ->(k) { where(kind: k) if k.present? }
    scope :for_node,    ->(n) { where(node_id: n) if n.present? }
    scope :for_version, ->(v) { where(version_id: v) if v.present? }

    # THE STATUS CLASSES, NAMED ONCE. A consumer asks one of these instead of comparing `status` to
    # a literal: the comparison was hand-spelled at a dozen sites, and `rebuilding` makes a bare
    # `== "ready"` wrong at every one of them in a different way (a picture surface would blank a
    # correct picture; nothing would refuse an older build). test/architecture_invariants_test.rb
    # refuses that literal outside this file. Each reads `status` before `asset`, so a row with
    # nothing to show costs no attachment query.

    # A job is believed to be coming for this row — the set `Enqueue.stalled?` stops believing
    # after STALLED_AFTER.
    def in_flight? = IN_FLIGHT.include?(status)

    # There is a PICTURE OF THIS CONTENT to put on screen: the current build, or an older build's
    # asset while its rebuild is queued. What every surface that SHOWS an artifact asks — the
    # thumbnails, the posters, a public cover.
    def showable? = (status == "ready" || status == "rebuilding") && asset.attached?

    # The attached asset IS the build these coordinates name. What a surface that MEASURES from
    # the artifact asks: an older build's Measure payload is wrong, not merely old (§14h), so a
    # row mid-rebuild is not one.
    def current_build? = status == "ready" && asset.attached?

    # A real render or fetch error — the one terminal state an eager seam retries.
    def failed? = status == "failed"

    # This row's artifact is data a surface measures from (`MEASURED_KINDS`), not a picture.
    def measured? = MEASURED_KINDS.include?(kind)

    # WHAT A DOOR THAT HANDS THIS ROW'S ASSET OUT MAY CALL READY, BY KIND: a picture while it is
    # `showable?` (an older build of this content is still a correct picture), measured data only as
    # the `current_build?`. `Public::FilesController#preview` and the v1 API serve rows of either
    # kind and answer by this one predicate, so they cannot disagree about a row.
    def servable? = measured? ? current_build? : showable?

    # THE STATUS A WIRE THAT PREDATES `rebuilding` IS TOLD — the v1 API, whose client documents "url
    # is null until status == ready". `ready` exactly when `servable?`; a rebuild that is not (measured
    # data mid-rebuild) is a job still coming, which that vocabulary calls `pending` — the answer the
    # web Measure poll gives for the same row. Every other status is already a word that wire knows.
    def wire_status
      return "ready" if servable?

      status == "rebuilding" ? "pending" : status
    end
  end
end
