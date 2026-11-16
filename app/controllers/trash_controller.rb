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
  #
  # WHERE EACH ONE CAME FROM (UX audit D7, 2026-11-02): two deleted README.md files could not be told
  # apart. `@origins` is node_id => Origin, built in three queries however long the trash is
  # (#origins_for) — page_query_budget_test.rb's trash case grows the tombstones and asserts that.
  def index
    @entries = FileLayer.current.trashed(current_user)
    @origins = origins_for(@entries)
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
  #
  # IT LANDS BACK ON TRASH AND SAYS WHERE THE FILE WENT (UX audit B6, 2026-11-02). It landed on the
  # library root, which is neither the page the maker was on nor, usually, where the file is; Trash
  # is where the next restore is, and the notice names the folder so the file can be found there.
  def restore
    info = FileLayer.current.undelete(current_user, node_id: params[:id])
    redirect_to trash_index_path, notice: restored_sentence(info)
  end

  private

  # WHERE A TRASHED ROW CAME FROM, AND WHAT HAS TO COME BACK BEFORE IT CAN. `path` is the folder's
  # library path ("" for the library root) while that folder's chain is live. `restore_first`
  # answers "which folder must be restored first": nil for none, the folder's NAME, or :missing
  # when the folder's row is gone altogether.
  #
  # ONE ANSWER, READ BY THE ROW AND BY THE REFUSAL. They used to work it out separately and
  # disagreed: the refusal named the folder whose delete took the file, the row named the nearest
  # one, so two levels down in a deleted folder the row sent the maker to a folder that was
  # refused the same way. The row also said "in Trash too" of any folder it could not resolve, a
  # folder removed outside the app included, which is not in the Trash list at all.
  Origin = Data.define(:parent_node_id, :path, :restore_first)

  # AT MOST FOUR QUERIES FOR THE WHOLE LIST, never a walk per row: the rows, one pluck of the live
  # folders (Maker::LibraryTree, the walk the Library's flat view uses), the parents of the rows
  # whose chain is broken, and the trash entries those rows and parents name. `current_user.nodes`
  # is what every backend's `trashed` reads, chunk_remote's mirror included.
  def origins_for(entries)
    listed = entries.to_set(&:node_id)
    rows = current_user.nodes.where(node_id: listed.to_a).pluck(:node_id, :parent_node_id, :trash_root_node_id)
    tree = Maker::LibraryTree.new(current_user)
    paths = rows.to_h { |id, parent, _root| [ id, tree.path_for(parent) ] }
    stuck = rows.select { |id, parent, _root| parent && paths[id].nil? }
    parents = pluck_by_id(current_user.nodes, stuck.map { |_id, parent, _root| parent }, :name, :trash_root_node_id)
    named = stuck.flat_map { |_id, parent, root| [ root, parents.dig(parent, 1) ] }
    entries_in_trash = pluck_by_id(current_user.nodes.trash_entry_roots, named, :name)

    rows.to_h do |id, parent, root|
      first = restore_first(id, parent, root, parents, entries_in_trash, listed) if parent && paths[id].nil?
      [ id, Origin.new(parent_node_id: parent, path: paths[id], restore_first: first) ]
    end
  end

  def pluck_by_id(scope, ids, *columns)
    ids = ids.compact.uniq
    ids.empty? ? {} : scope.where(node_id: ids).pluck(:node_id, *columns).to_h { |id, *rest| [ id, rest ] }
  end

  # THE FOLDER WHOSE DELETE TOOK THIS ROW, where the catalog records one: share and s3 write
  # `trash_root_node_id` (FileLayer::TrashMembership). The row's own entry first, else its
  # parent's, and only one STILL IN THE TRASH (Node.trash_entry_roots). Failing that, the parent
  # itself, and only when the parent is a row of this very list: chunk_remote's mirror writes no
  # entry and lists every tombstone, so it names the parent, which is what its server checks.
  def restore_first(id, parent, own_entry, parents, entries_in_trash, listed)
    name, parents_entry = parents[parent]
    entry = [ own_entry, parents_entry ].compact.without(id).find { |root| entries_in_trash.key?(root) }
    return entries_in_trash[entry].first if entry
    return :missing if name.nil?

    name if listed.include?(parent)
  end

  # "Restored NAME to FOLDER." — the folder it is in NOW, read from the catalog the undelete just
  # revived, because that is where the maker will go looking. A broken ancestor chain names nothing
  # rather than claim the root.
  def restored_sentence(info)
    parent = current_user.nodes.where(node_id: info.node_id).pick(:parent_node_id)
    path = Maker::LibraryTree.new(current_user).path_for(parent)
    return "Restored #{info.name}." if path.nil?

    "Restored #{info.name} to #{path.presence || "the top of the Library"}."
  end

  # THE ONE THING THAT MAKES restore_refusal_message HONEST RATHER THAN A GUESS: it does not
  # infer the orphan condition from e.message (see the rescue_from comment above for why that
  # would be fragile), it RE-DERIVES it from this app's own catalog, and from the SAME lookup the
  # Trash page drew the row with, so the two cannot give different advice. Root-level, an unknown
  # node, a live folder (the occupied-destination clobber lands here): `restore_first` is nil for
  # all of them, and they get the same flattened message every other UnsupportedOperation has
  # always gotten, because naming a folder would be actively wrong advice for those cases.
  def restore_refusal_message
    first = origins_for(FileLayer.current.trashed(current_user))[params[:id]]&.restore_first
    return "Couldn't restore that item." if first.nil?

    "That file's folder was deleted too. Restore #{first == :missing ? "the folder" : first.inspect} " \
      "first, and its contents come back with it."
  end
end
