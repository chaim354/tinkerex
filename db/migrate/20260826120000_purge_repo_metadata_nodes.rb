class PurgeRepoMetadataNodes < ActiveRecord::Migration[8.1]
  # DATA MIGRATION, one-time. It runs at deploy, BEFORE the new containers boot — which is the
  # whole point rather than a convenience: the observers in this same deploy stop descending into
  # `.git`, and the first Library::ScanJob tick afterwards would otherwise see every node already
  # indexed beneath one vanish at once and trip Library::Reconciler's mass-deletion guard (a
  # percentage of the observable library with no floor). The guard refuses the scan rather than
  # tombstoning, so the cost is a stalled library rather than lost data — an outage nobody needs
  # to have. A rake task would say the same thing but has to be REMEMBERED, in the window between
  # the deploy and the next scheduled scan; kamal runs migrations first, so this closes the window
  # instead of documenting it.
  #
  # A MISSING CONSTANT IS A NO-OP, ON PURPOSE. A migration is replayed on a fresh database for as
  # long as this repo exists, and Library::RepoMetadataPurge is a one-time service a future cleanup
  # may legitimately delete. On a fresh database there is nothing to purge, so its absence must not
  # break `db:setup` years from now.
  #
  # THE NameError RESCUE IS SCOPED TO THE CONSTANT LOOKUP (`safe_constantize`), NEVER WRAPPED
  # AROUND THE CALL. A `rescue NameError` around `purge.call` would ALSO swallow a NameError raised
  # from inside the purge — a renamed model, an autoload failure — and turn a real breakage into a
  # silent success on every future deploy, which is this repo's dominant failure shape (§15).
  # safe_constantize returns nil only when the message names this very constant, and re-raises
  # anything else.
  def up
    purge = "Library::RepoMetadataPurge".safe_constantize
    if purge.nil?
      say "Library::RepoMetadataPurge is gone; nothing to purge on a fresh database"
      return
    end

    result = purge.call
    say "destroyed #{result.destroyed} node(s) indexed beneath a .git directory"
    # A node carrying a maker_file_attachments row is kept, and the report is the whole value of
    # keeping it — destroying one silently orphans a project reference, and a skip nobody prints is
    # the same silence with extra steps.
    result.skipped.each do |node|
      say "KEPT #{node.node_id} (user #{node.user_id}) — a file attachment points at it", true
    end
  end

  # IRREVERSIBLE BY NATURE, not by neglect: the rows are gone and the paths they named are no
  # longer observable, so there is nothing to restore them from. A `down` that did nothing would be
  # a lie about that.
  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
