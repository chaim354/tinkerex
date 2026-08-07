module Maker
  # WHEN A MAKER-LAYER ROW POINTING AT A NODE MAY BE DESTROYED. One definition, shared by
  # `Maker::Previews::DeadNodeReaper` (thumbnails) and `Maker::AttachmentReaper` (project/model
  # attachments and project covers), because they ask exactly the same question about exactly the
  # same `nodes` rows and a second copy would answer it differently the first time either changed.
  #
  # THE WHOLE DESIGN QUESTION IS REVIVABILITY, and the two cases genuinely differ:
  #
  #   * NO NODE ROW AT ALL -> reapable immediately. Both ways back need the tombstone: the share
  #     `Library::Reconciler`'s revive-by-path looks up `deleted: true` rows BY `storage_path`, and
  #     `undelete`/`Sync::Trash.restore` reconstruct from the row. With no row that node_id can
  #     never return, so there is nothing to protect and no grace worth serving.
  #   * A TOMBSTONE -> spared until `grace` has passed. A tombstone is a deletion that can be TAKEN
  #     BACK, and taking it back returns the SAME node_id — which is the whole point, because
  #     attachments, BOM links and tags are all keyed on it. Reaping inside the window turns an undo
  #     into permanent loss of everything the file was filed under. Dated from the NODE's
  #     `updated_at`, which is when it was tombstoned, never from the maker row's, which records
  #     something else entirely and can be months older.
  #
  # `GRACE` lines up with `LIBRARY_TRASH_DAYS`'s default undo window and is deliberately NOT read
  # from that setting: it applies to all three backends while LIBRARY_TRASH_DAYS is share-only, and
  # that setting treats 0 as "keep forever" (see `Library::TrashPurgeJob`) — a meaning that would
  # invert dangerously here, where 0 reads naturally as "no grace".
  module DeadNodes
    module_function

    GRACE = 30.days

    # nil node -> gone for good, reap. Live node -> NEVER (a reaper that could touch a live node's
    # rows would be deleting the thing the page renders). Tombstone -> only once its undo window
    # has closed.
    def reapable?(node, cutoff)
      return true  if node.nil?
      return false unless node.deleted?

      node.updated_at < cutoff
    end

    # The nodes a set of node_ids resolves to, LIVE OR TOMBSTONED, keyed by node_id.
    #
    # `nodes`, NOT `nodes.present`, and the distinction is the entire mechanism: a tombstone is
    # exactly what tells the two cases above apart, so filtering it out here would make every
    # tombstone look like a hard-gone node and reap it with no grace at all.
    def index(user, node_ids)
      user.nodes.where(node_id: node_ids).index_by(&:node_id)
    end
  end
end
