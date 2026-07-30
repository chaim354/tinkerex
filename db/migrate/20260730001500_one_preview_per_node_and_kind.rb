# ONE PREVIEW ROW PER (user, node, kind), replacing one row per CONTENT VERSION.
#
# The old key included `version_id`, so every save of a file minted a NEW row and stranded the
# previous one: nothing reads a superseded preview (every surface resolves by the node's CURRENT
# content_token) and nothing deleted it either. Measured on the deployed share library before this
# ran: 160 of 1334 rows orphaned, 3.1 MB of blobs, growing ~17.6 rows/day with editing activity.
#
# The fix is to stop minting them rather than to sweep them up — `Previews::Enqueue` now repoints
# the single row's `version_id` and re-renders into it, and ActiveStorage purges the replaced blob
# on its own (verified: attaching over a `has_one_attached` enqueues ActiveStorage::PurgeJob).
#
# THIS MIGRATION IS ALSO THE CLEANUP. The new index cannot be added while duplicates exist, so the
# collapse has to happen here — which is why no separate reaper job is needed for the backlog.
#
# SELF-CONTAINED, following 20260729035422_rederive_document_roles.rb: a local model class rather
# than Maker::Preview, because a data migration runs against whatever the app looks like months
# from now. The one exception is ActiveStorage::Attachment#purge, which is FRAMEWORK API, not app
# code — and it is needed, because deleting the rows without it would trade a database leak for a
# stored-file leak, which is the very thing this change exists to stop.
class OnePreviewPerNodeAndKind < ActiveRecord::Migration[8.1]
  class MigrationPreview < ActiveRecord::Base
    self.table_name = "maker_previews"
  end

  def up
    remove_index :maker_previews, name: "idx_maker_previews_unique"

    # KEEP THE MOST RECENTLY UPDATED ROW of each group. That is the last render, which is the
    # current content in every ordinary case — and where it is not, the row is self-healing:
    # `Enqueue` repoints any row whose version_id does not match the node's current token on the
    # next scan or folder view. Ordered by id as the tie-break so the choice is deterministic.
    doomed = MigrationPreview
               .select(:id, :user_id, :node_id, :kind, :updated_at)
               .order(updated_at: :desc, id: :desc)
               .group_by { |p| [ p.user_id, p.node_id, p.kind ] }
               .flat_map { |_key, rows| rows.drop(1) }
               .map(&:id)

    if doomed.any?
      # purge (not purge_later): this runs once, over a small set, and a background purge that
      # failed would leak the stored file invisibly — which is the failure mode being closed.
      ActiveStorage::Attachment
        .where(record_type: "Maker::Preview", record_id: doomed)
        .find_each(&:purge)
      MigrationPreview.where(id: doomed).delete_all
    end
    say "collapsed #{doomed.size} superseded preview row#{"s" unless doomed.size == 1}"

    add_index :maker_previews, %i[user_id node_id kind],
              unique: true, name: "idx_maker_previews_unique"
  end

  # Reversible in SHAPE only — the collapsed rows are gone, and they are meant to be. Restoring the
  # old index is what lets a downgraded app write per-version rows again.
  def down
    remove_index :maker_previews, name: "idx_maker_previews_unique"
    add_index :maker_previews, %i[user_id node_id version_id kind],
              unique: true, name: "idx_maker_previews_unique"
  end
end
