# Server-rendered web Trash view: list deleted files and restore them.
#
# THROUGH THE PORT, BECAUSE EVERY BACKEND HAS A TRASH — the decision this file records, since
# Phase 4 offered three answers and only one of them is honest here:
#
#   - 501 it. That is what V1::TrashController does, and it is right THERE: the v1 trash is the
#     chunk one (tombstones + kept versions), a share library's is a different mechanism, and no
#     API exists for the second. But this page is not that API. "This deployment has no trash"
#     would be false — a share/s3 library has `.trash/<node_id>/<name>` and FileLayer#undelete,
#     both built in 2b — and a 501 rendered as an HTML page to a human is a strange artifact of
#     an API decision leaking into a UI.
#   - Hide the nav link + gate the route. Same false claim, told by omission instead of status
#     code, and hiding a link while leaving the URL live is the half-truth this phase exists to
#     kill.
#   - Make it work. FilesController#destroy now puts share/s3 bytes in `.trash`; without this
#     page that is a delete with no undo, while `undelete` sits unused three files away.
#
# So `trashed` is a READ verb every adapter answers (chunk delegates to Sync::Trash, keeping one
# definition of the trash rather than two), and restore branches on port_writable exactly as
# #destroy does. Deletes are versioned tombstones in chunk mode and moved bytes on share/s3 —
# what "restore" MEANS differs, which is why the port answers it and this controller does not.
class TrashController < ApplicationController
  before_action :authenticate_user!

  include LibraryCapabilities

  # Deliberately the same shape as FilesController's, and the same argument: from the browser's
  # side "no such node", "not in the trash", "its bytes were purged" and "something is already at
  # that path" are one condition — the user cannot act on the difference, and none of them means
  # the restore happened. The message promises nothing it cannot keep: notably NOT "it's gone",
  # which is false for the occupied-destination case.
  rescue_from ActiveRecord::RecordNotFound, FileLayer::NotFound do
    redirect_to trash_index_path, alert: "Couldn't restore that item."
  end

  # NOT the alert above, and the distinction is the port's most consequential one: an unmounted
  # NAS or a credentials blip must never read as "your file is permanently gone". Retryable.
  rescue_from FileLayer::FetchError do
    redirect_to trash_index_path, alert: "Couldn't reach your library. Try again."
  end

  # GET /trash — what this deployment can bring back, newest-deleted first.
  #
  # The Size column used to come from current_user.versions, which is EMPTY on share and s3 — the
  # same lie #index and #show told before Task 6, in a third spelling. TrashEntry is
  # backend-neutral by construction, which is the port's whole job.
  def index
    @entries = FileLayer.current.trashed(current_user)
  end

  # POST /trash/:id/restore — bring it back to the normal listing.
  #
  # THE BRANCH #destroy MAKES, ON THE SAME CAPABILITY. Running Sync::Trash.restore against a share
  # library is not a recovery and is worse than doing nothing: it clears the tombstone while the
  # bytes stay in `.trash`, leaving a live node with a NULL storage_path — invisible to the scan
  # (which only reads nodes that have one), unreadable through the port, and its bytes purged
  # after LIBRARY_TRASH_DAYS. A file the UI shows and nothing can open. FileLayer#undelete is the
  # real inverse: bytes back to an observable path FIRST, then revive.
  #
  # to_root: true is chunk mode's answer to a deleted parent. Share/s3 answer it differently
  # (undelete recreates the folder, so the next scan revives that dir node by path) — one more
  # reason the port owns this rather than the caller.
  def restore
    if capabilities.port_writable?
      info = FileLayer.current.undelete(current_user, node_id: params[:id])
      name = info.name
    else
      node, = Sync::Trash.restore(user: current_user, node_id: params[:id], to_root: true)
      LibraryChannel.broadcast_change(current_user, current_user.reload.head_seq)
      name = node.name
    end
    redirect_to files_path, notice: "Restored #{name}."
  end
end
