module Maker
  module Previews
    # Reaps previews whose NODE no longer exists — the second orphan class, and the one the
    # `(user_id, node_id, kind)` unique index cannot reach.
    #
    # The index removed the first class by construction: a save repoints the single row instead of
    # minting a second, so superseded-content rows can no longer accumulate. A dead node's row is
    # the ONLY row for that node, so there is no duplicate group to collapse and nothing sweeps it.
    # Measured right after that migration: **93 on the deployed share library, 3 on chunk.**
    #
    # THIS LEAK IS SHAPED DIFFERENTLY FROM THE ONE THE INDEX FIXED, and that is why it gets a job
    # rather than a constraint: it grows when files are DELETED, not when they are edited, so it
    # tracks library churn instead of editing activity. It also cannot be prevented at write time —
    # a node is deleted long after its preview was made, `Reconciler` TOMBSTONES rather than
    # destroys (so no `dependent:` callback would fire), and wiring an association from `Node` to
    # `Maker::Preview` would point the file layer at the maker layer, which is the coupling
    # CLAUDE.md §12 step 10 exists to prevent. A periodic sweep is the honest mechanism.
    #
    # THE WHOLE DESIGN QUESTION IS REVIVABILITY, and the two cases genuinely differ:
    #
    #   * NO NODE ROW AT ALL -> reaped immediately. Both ways back need the tombstone: the share
    #     Reconciler's revive-by-path looks up `deleted: true` rows BY `storage_path`, and
    #     `undelete`/`Sync::Trash.restore` reconstruct from the row. With no row, that node_id can
    #     never return, so there is nothing to protect and no grace worth serving.
    #   * A TOMBSTONE -> spared until `grace` has passed. A tombstone is a deletion that can be
    #     TAKEN BACK, and taking it back returns the same node_id — a file dragged out of a folder
    #     and back returns with its content unchanged, at which point the row would have been live
    #     again. Reaping inside the window turns an undo into a re-render. Dated from the node's
    #     `updated_at`, which is when it was tombstoned — NOT from the preview's, which records
    #     when the thumbnail was last rendered and can be months older than the deletion.
    #
    # `grace` defaults to 30 days to line up with `LIBRARY_TRASH_DAYS`'s default undo window. It is
    # deliberately NOT read from that setting: it applies to all three backends while
    # LIBRARY_TRASH_DAYS is share-only, and that setting treats 0 as "keep forever" (see
    # `Library::TrashPurgeJob`) — a meaning that would invert dangerously here, where 0 reads
    # naturally as "no grace".
    module DeadNodeReaper
      module_function

      GRACE = 30.days

      def reap_all!(grace: GRACE, dry_run: false)
        User.find_each.sum do |user|
          reap!(user, grace:, dry_run:)
        rescue StandardError => e
          # One user's failure must not stop the sweep for everyone else — the same isolation
          # Sync::ChunkReaper.reap_all! applies.
          Rails.logger.error("DeadNodeReaper: user #{user.id} failed: #{e.class}: #{e.message}")
          0
        end
      end

      def reap!(user, grace: GRACE, dry_run: false)
        previews = user.maker_previews.to_a
        return 0 if previews.empty?

        # One query for every node the previews name, live or tombstoned. `nodes` (not `present`)
        # on purpose: a tombstone is exactly what tells the two cases apart, so filtering it out
        # here would make every tombstone look like a hard-gone node and reap it with no grace.
        nodes = user.nodes.where(node_id: previews.map(&:node_id)).index_by(&:node_id)
        cutoff = grace.ago

        doomed = previews.select { |p| reapable?(nodes[p.node_id], cutoff) }
        return doomed.size if dry_run

        doomed.each do |p|
          p.asset.purge if p.asset.attached?
          p.destroy!
        end
        doomed.size
      end

      # nil node -> gone for good, reap. Live node -> never (a reaper that could touch a live
      # node's preview would be deleting the thing the page renders). Tombstone -> only once its
      # undo window has closed.
      def reapable?(node, cutoff)
        return true  if node.nil?
        return false unless node.deleted?

        node.updated_at < cutoff
      end
    end
  end
end
