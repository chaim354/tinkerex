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
    # WHEN A ROW MAY GO — including why a tombstone gets a grace window and a hard-gone node does
    # not — lives in `Maker::DeadNodes`, shared with `Maker::AttachmentReaper`. The two reapers ask
    # the identical question about the identical rows; keeping two copies of the answer is how they
    # would come to disagree. What is specific to previews stays here: reaping a preview costs a
    # re-render, where reaping an attachment costs the user's own filing, so the shared window is
    # the CONSERVATIVE one of the two by construction.
    module DeadNodeReaper
      module_function

      GRACE = Maker::DeadNodes::GRACE

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

        # One query for every node the previews name, live or tombstoned — see DeadNodes.index for
        # why `present` would be wrong here.
        nodes = Maker::DeadNodes.index(user, previews.map(&:node_id))
        cutoff = grace.ago

        doomed = previews.select { |p| Maker::DeadNodes.reapable?(nodes[p.node_id], cutoff) }
        return doomed.size if dry_run

        doomed.each do |p|
          p.asset.purge if p.asset.attached?
          p.destroy!
        end
        doomed.size
      end
    end
  end
end
