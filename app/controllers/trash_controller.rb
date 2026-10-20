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
# definition of the trash rather than two), and `restore` is one call to the port's `undelete` on
# every backend since Stage 2 (no more branch here than in #destroy). Deletes are versioned
# tombstones in chunk mode and moved bytes on share/s3 — what "restore" MEANS differs, which is
# why the port answers it and this controller does not.
class TrashController < ApplicationController
  # Deliberately the same shape as FilesController's, and the same argument: from the browser's
  # side "no such node" and "not in the trash" are one condition — the user cannot act on the
  # difference, and neither means the restore happened. The message promises nothing it cannot
  # keep.
  #
  # UnsupportedOperation USED TO SHARE THIS FLATTENING AND NO LONGER DOES — see the rescue below.
  # It was here because an occupied-destination clobber ("something is already at that path") is
  # the SAME kind of condition as the two above: the user cannot act on the difference, and
  # `undelete` raised NotFound for it until the clobber fix moved the class, so leaving it out
  # made an ordinary "something is at that path now" restore a 500 rather than the alert this line
  # was written to give it (caught by s3_write_test.rb, not by reading). That case still gets this
  # flattened message — it moved, not disappeared.
  rescue_from ActiveRecord::RecordNotFound, FileLayer::NotFound do
    redirect_to trash_index_path, alert: "Couldn't restore that item."
  end

  # SPLIT OUT OF THE RESCUE ABOVE BECAUSE UnsupportedOperation NOW NAMES TWO CONDITIONS AND ONLY
  # ONE OF THEM FITS "the user cannot act on the difference." The occupied-destination clobber
  # (still true, see above) genuinely has nothing more to say than "it failed." The orphaned
  # restore does: since the reversal recorded in CLAUDE.md 14a, restoring a node whose own FOLDER
  # was tombstoned by the same cascading delete raises this rather than scattering the node to the
  # root — and "restore the folder first" is something a person reading a flash message can
  # actually go and do, unlike any of the other conditions this controller rescues.
  #
  # NOT TOLD APART BY e.message, WHICH IS WHY THIS DOES NOT MAP e.message THE WAY FilesController
  # DOES FOR ITS OWN UnsupportedOperation. FileLayer::Chunk raises a hand-written sentence for the
  # orphan case; FileLayer::ChunkRemote's message is the WIRE's own "<path>: parent_deleted"
  # (Transport#interpret echoes the server's JSON `error` field verbatim, and that field is a
  # machine code, not prose meant for a screen — CLAUDE.md 14c's "branch on the code, never the
  # prose" rule, one door over). Pattern-matching either shape here would couple a web flash
  # message to wording a gem or a standalone server can reword without this file ever noticing.
  # So `restore_refusal_message` asks the CATALOG instead — `current_user.nodes`, which every
  # backend populates identically — the same question `Sync::Trash.parent_deleted?` answers
  # server-side: is the tombstoned node's own parent ALSO gone? That is correct regardless of
  # which backend, or which of the two conditions, actually raised.
  rescue_from FileLayer::UnsupportedOperation do
    redirect_to trash_index_path, alert: restore_refusal_message
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
  # ONE DOOR since Stage 2 -- the fourth of CLAUDE.md 14d's five port_writable? copies to go. This
  # branched on port_writable? because the port refused undelete in chunk mode; Chunk#undelete now
  # goes through the sync engine itself (Sync::Trash.restore, under Chunk#undelete), so every
  # backend answers this ONE call to FileLayer.current.undelete, the same as mkdir/move/delete
  # before it.
  #
  # RUNNING Sync::Trash.restore DIRECTLY AGAINST A SHARE LIBRARY IS NOT A RECOVERY -- IT IS WORSE
  # THAN DOING NOTHING, which is exactly why this action never called it on that leg and must not
  # start now: it would clear the tombstone while the bytes stay in `.trash`, leaving a live node
  # with a NULL storage_path — invisible to the scan (which only reads nodes that have one),
  # unreadable through the port, and its bytes purged after LIBRARY_TRASH_DAYS. Share/S3#undelete
  # are the real inverse — bytes back to an observable path FIRST, then revive — which only the
  # port can drive.
  #
  # THE PORT ANSWERS A FileInfo ON EVERY BACKEND, so the flash reads one field regardless of which
  # adapter served it. An orphaned restore — its own folder tombstoned by the same cascading
  # delete — no longer reaches this line at all: it raises UnsupportedOperation instead, rescued
  # above. That reversal, and why, live in Chunk#undelete's own comment (the sync-engine gem) and
  # CLAUDE.md 14a, not here.
  def restore
    info = FileLayer.current.undelete(current_user, node_id: params[:id])
    redirect_to files_path, notice: "Restored #{info.name}."
  end

  private

  # THE ONE THING THAT MAKES restore_refusal_message HONEST RATHER THAN A GUESS: it does not
  # infer the orphan condition from e.message (see the rescue_from comment above for why that
  # would be fragile), it RE-DERIVES it from this app's own catalog, mirroring
  # Sync::Trash.parent_deleted? exactly — a blank parent_node_id means root-level, never an
  # orphan; otherwise the parent must be MISSING or ITSELF tombstoned. Anything else (an unknown
  # node, a live parent — the occupied-destination clobber lands here) falls through to the same
  # flattened message every other UnsupportedOperation has always gotten, because naming a folder
  # would be actively wrong advice for that case.
  def restore_refusal_message
    node = current_user.nodes.find_by(node_id: params[:id])
    return "Couldn't restore that item." if node&.parent_node_id.blank?

    parent = current_user.nodes.find_by(node_id: node.parent_node_id)
    return "Couldn't restore that item." unless parent.nil? || parent.deleted

    folder = trashed_entry_root(node, parent) || parent
    "That file's folder was deleted too. Restore #{folder ? folder.name.inspect : "the folder"} " \
      "first, and its contents come back with it."
  end

  # THE FOLDER WHOSE DELETE TOOK THIS ROW, where the catalog records one — share and s3 write
  # `trash_root_node_id` (FileLayer::TrashMembership); chunk_remote's mirror writes none and keeps the
  # parent above. The row's own entry root first, else its parent's, and only one STILL IN THE TRASH.
  # Naming the parent instead sent the maker to a folder refused the same way, one level at a time
  # up a nested delete.
  def trashed_entry_root(node, parent)
    [ node.trash_root_node_id, parent&.trash_root_node_id ].compact.without(node.node_id).each do |id|
      root = current_user.nodes.find_by(node_id: id, trash_root_node_id: id)
      return root if root
    end
    nil
  end
end
