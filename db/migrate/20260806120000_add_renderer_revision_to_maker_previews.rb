class AddRendererRevisionToMakerPreviews < ActiveRecord::Migration[8.1]
  # WHICH BUILD OF THE RENDERER PRODUCED THE STORED ARTIFACT — as opposed to `version_id`, which
  # records which FILE CONTENT it was produced from. Nothing tracked the first of those, so a code
  # change that altered a payload invalidated nothing: every cached preview kept serving output
  # from the old code until its file happened to change, which for a finished design is never.
  #
  # Not hypothetical. The .lbrn2 Measure view shipped with a thinning bug that mangled any contour
  # mixing straight and curved edges. After the fix deployed, four already-measured files went on
  # serving the mangled geometry and had to be found and destroyed by hand, on the one backend of
  # three that happened to have them.
  #
  # NOT NULL WITH DEFAULT 1, rather than a nullable column, and that is the part worth pausing on:
  #
  #   * Existing rows become 1, which says what is actually true of them — they were made by the
  #     renderers as they stood. A NULL would instead differ from every declared revision, so the
  #     first request for each of the ~1400 live thumbnails would find itself stale and re-render:
  #     an unannounced full-library rebuild as the side effect of adding a column.
  #   * NOT NULL means no creator can leave it unset. `Maker::Previews::Enqueue` is not the only
  #     one — `V1::Maker::PreviewsController` builds rows through `find_or_initialize_by` — and a
  #     row with no revision would read as stale forever, re-enqueueing on every single request.
  #     A default removes that failure mode structurally instead of asking each caller to remember.
  #
  # A renderer therefore invalidates its own cache only by declaring a revision PAST 1; silence
  # changes nothing.
  def change
    add_column :maker_previews, :renderer_revision, :integer, null: false, default: 1
  end
end
