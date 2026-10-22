# THE VIEWER ONE FILE GETS ON A MAKER'S PAGE (2026-10-21): the file page (FilesController#show) and
# the model page's pane (ModelsController#show, models/_stage) both ask `viewer_state_for` and both
# render files/_viewer from what it answers, so the two cannot disagree about which viewer a file
# gets or what that viewer is handed.
#
# MAKER-ONLY, WHICH IS WHY IT IS NOT FilePreview. This reads `current_user` (the stat, the thumbnail
# enqueue, the 3MF manifest); FilePreview is included by a VISITOR's page too and never reads the
# session (§14d). FilePreview#viewer_for stays the one answer to the KIND; this adds what a maker's
# page wraps around it.
module FileViewer
  extend ActiveSupport::Concern
  include FilePreview

  # Everything files/_viewer reads, one value per file. `info` is the port's stat; `kind`,
  # `gerber_layers` and `gerber_single` are viewer_for's three facts; `manifest` is
  # Maker::ThreeMfManifest's answer (nil for anything that is not a 3MF).
  Viewer = Data.define(:node, :info, :kind, :gerber_layers, :gerber_single, :thumbnail, :manifest)

  private

  def viewer_state_for(node)
    info = FileLayer.current.stat(current_user, node_id: node.node_id)
    # WHICH VIEWER, AND THE BOARD IF THIS IS ONE: FilePreview#viewer_for, the ONE answer a visitor's
    # page asks too (F-S10-2) — the zip read, the layer list and the stackup choice live there, and
    # the kind is final when it returns, before a caller's `@editable` reads it. Only the URL is this
    # page's, and the lambda never answers nil here: every live node of current_user has a private
    # byte route.
    kind, layers, single =
      viewer_for(user: current_user, node:, url: ->(n) { named_blob_file_path(n.node_id, filename: n.name) })
    token = info&.content_token
    Viewer.new(node:, info:, kind:, gerber_layers: layers, gerber_single: single,
               thumbnail: token && current_thumbnail(node, token),
               # WHAT THE 3D VIEWER'S IMPORTER CANNOT KNOW — the slicer's per-object filament colours
               # and the model's declared unit, which three.js's 3MFLoader ignores. nil for everything
               # that is not a 3MF (`for` refuses by NAME before it looks at anything else), so this
               # is safe to call for any file and costs a non-3MF nothing. On a 3MF it is the second
               # read this can make, beside the zip one `viewer_for` makes: ONE port read, bounded on
               # the catalog's size column and cached by content token, so it is one query per view of
               # one file and nothing after the first. A read with no decision in it, so it stays a
               # line here (and one in Public::FilesController#view) rather than joining `viewer_for`.
               manifest: Maker::ThreeMfManifest.for(user: current_user, node:))
  end

  # The thumbnail for THIS content AND this build of its renderer, enqueueing when there is none.
  #
  # #show USED TO ONLY READ, and that is why a bumped revision never reached the detail page: the
  # only thing enqueueing thumbnails is the index's backfill, so a file whose page you opened
  # directly kept rendering an older build's metadata until you happened to visit the list. The
  # Laser Settings panel is drawn from that metadata, which is how a deploy that added layer
  # colours left them invisible on 172 of 174 files.
  #
  # A CURRENT ROW IS ASKED `Enqueue.needs_job?` BEFORE IT IS RETURNED: one whose job was lost (in
  # flight past STALLED_AFTER) is healed here, and a `failed` one never is (`retry_failed: false`) —
  # the file page and the inspector are opened again and again (files-preview.md).
  #
  # Enqueue returns the repointed row — `pending` after a content change, so the view shows
  # "Generating preview…" rather than an older artifact labelled as current; `rebuilding` after a
  # renderer bump, which keeps its picture of this same content up — or nil when nothing can render
  # this name.
  def current_thumbnail(node, token)
    row = Maker::Previews::Enqueue.current_preview(user: current_user, node_id: node.node_id,
                                                   name: node.name, version_id: token,
                                                   kind: "thumbnail")
    revision = row && Maker::Previews::Enqueue.revision_for_name(node.name, row.kind)
    return row if row && !Maker::Previews::Enqueue.needs_job?(row, version_id: token, revision:,
                                                              retry_failed: false)

    Maker::Previews::Enqueue.call(user: current_user, node_id: node.node_id,
                                  name: node.name, version_id: token, kind: "thumbnail")
  end
end
