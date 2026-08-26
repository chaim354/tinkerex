module Library
  # Remove nodes already indexed BENEATH a `.git` directory, keeping the marker itself.
  #
  # RUN ONCE, AT DEPLOY, BY A MIGRATION — see db/migrate/*_purge_repo_metadata_nodes.rb. The reason
  # is arithmetic, not tidiness: the observers stop descending into `.git` in the same deploy, so
  # the first Library::ScanJob tick afterwards sees every node already indexed beneath one vanish
  # at once. Library::Reconciler's mass-deletion guard is a percentage of the observable library
  # with NO FLOOR, so a repo-heavy library trips it — Library::Scanner::UnsafeScan — and the
  # library stops scanning, that pass and every pass after it, until an operator overrides
  # LIBRARY_SCAN_MAX_DELETE_PCT. The guard raises BEFORE tombstoning, so the cost is an outage
  # rather than lost data; it is still an outage nobody needs to have.
  #
  # IDEMPOTENT, so a re-run costs a pass over the table and destroys nothing. It stays callable by
  # hand for exactly that reason — a library scanned by the new code before the migration ran needs
  # this, not a raised threshold (docs/DEPLOY.md).
  #
  # SCANNABLE BACKENDS ONLY, AND THE GATE IS THE SAME ONE Library::ScanJob ASKS. Three reasons, and
  # the first alone is sufficient: the guard this exists to keep from tripping runs from
  # Library::ScanJob, which gates on `scannable?`, so on `chunk_remote` it never runs and there is
  # nothing to prevent. Second, that backend's `nodes` table is a MIRROR of the sync server's tree
  # and §14a makes every metadata read answer from it — destroying rows makes the mirror LIE until
  # some later gapped `full_resync` happens to re-write them, which is destructive work against a
  # structure this app's whole job is to keep faithful. Third, `app/models/node.rb` records, as a
  # decision of this same arc, that the files inside `.git` DO exist as rows on chunk_remote and are
  # HIDDEN rather than removed; a purge that destroyed them would make that statement false. The
  # gate keeps the three consistent. (Unset LIBRARY_BACKEND defaults to `share`, which is scannable,
  # so a missing env fails toward running the purge rather than silently skipping it — and every
  # Kamal destination sets it explicitly anyway, §7.)
  #
  # DESTROY, NOT TOMBSTONE. These paths will never be observed again, so a tombstone would sit
  # there forever as a revivable row for a file that cannot come back — and §14a's
  # two-tombstone-kinds rule makes a lingering trash-kind row actively worse than no row:
  # Reconciler#create_or_revive! could hand a new, unrelated file that node_id along with every
  # attachment, BOM link and tag pointing at it.
  #
  # TOMBSTONES GO TOO, not just live rows, and the criterion is why: this asks "will this path ever
  # be observed again", which the `deleted` flag does not bear on. There are TWO tombstone-revival
  # routes and both are keyed on an exact `storage_path` — Reconciler#create_or_revive! for files
  # and #ensure_dirs for directories — so a row left behind could only come back if an observation
  # arrived at its exact path, and neither observer will ever produce one there again. (Checked,
  # rather than asserted: the file route was the obvious one and the directory route was found by
  # looking.) The bytes of a trash-kind tombstone are collected by the ordinary `.trash` sweep,
  # which reads entry-dir mtimes and never a row; restoring one was already impossible, since
  # undelete goes through FileLayer::Share#observable!, which refuses at-or-beneath the marker.
  #
  # RESOLVED BY THE PARENT CHAIN, NOT BY storage_path, AND THAT SURVIVES THE SCANNABLE GATE ABOVE
  # ON ITS OWN BACKEND. The original argument was chunk_remote's — storage_path is NULL for every
  # mirror row (§14a) — and the gate retires it, since those rows are no longer looked at. What
  # replaces it is native to share and s3: **a trash-kind tombstone has a NULL storage_path and an
  # intact parent chain** (`FileLayer::Share#delete` ends `update!(deleted: true, storage_path:
  # nil)`, and it nulls the column deliberately, so a revive cannot fire on it). A file trashed out
  # of a `.git` before this arc landed is exactly that row, and a purge reading only the column
  # would leave every one of them behind on the deployments the gate DOES cover. The chain answers
  # for both shapes and needs no second mechanism to disagree with.
  #
  # AND IT ASKS Library::RepoMetadata.internal?, rather than testing an ancestor's name here. That
  # predicate is the OBSERVERS' question, derived from marker_prefix, and the observers are what
  # decide which nodes stop being observed — the population this purge has to match exactly. A
  # local `name == DIR_NAME` comparison would be a third spelling of one question, free to drift
  # from the two that already agree by construction. It also inherits internal?'s hard-won corners
  # for nothing: whole segments (so `.gitignore` and `notes/git/` survive), outermost-wins (so a
  # submodule's inner marker is itself beneath the outer one and goes), and false for the marker's
  # own path (so the marker survives).
  module RepoMetadataPurge
    # A cap on the ancestor walk, for the same reason Maker::AttachToProject::MAX_ANCESTOR_WALK
    # exists: `parent_node_id` is a plain string column with no foreign key, so a cycle is
    # representable, and an uncapped walk is an infinite loop inside a deploy. 64 is far past any
    # real library depth.
    #
    # A TRUNCATED WALK IS NOT "THE SAFE DIRECTION", AND SAYING SO WOULD BE WRONG TWICE. The cap
    # drops the TOP of the path, and `marker_prefix` scans what survives from the LEFT — so a
    # truncated path answers whatever its own suffix says: `true` if a `.git` segment is still in
    # it, `false` if the marker was among the segments dropped. And a `false` there is not safe: it
    # leaves a live node beneath a marker at a path no observer will ever produce, which is
    # precisely the ghost that re-arms the guard trip this service exists to prevent. Nothing
    # below 64 levels deep can reach either case, which is why the cap is set where it is rather
    # than defended as harmless.
    MAX_ANCESTOR_WALK = 64

    # How many ids one destroy statement carries. The decision pass holds ids rather than rows, so
    # the whole run is bounded by an Integer array however large the repository is.
    DESTROY_BATCH = 500

    # `declined` is what makes the scannable gate honest at the call site: an operator who runs
    # this by hand on the wrong deployment must not read "destroyed 0" as "there was nothing to
    # do". One gate, asked once, reported rather than re-derived by the caller.
    Result = Data.define(:destroyed, :skipped, :declined)

    def self.call
      return Result.new(destroyed: 0, skipped: [], declined: true) unless scannable?

      cache = {}
      keep = Set.new
      skipped = pin_referenced(cache, keep)

      # DECIDE, THEN APPLY, and the split is a correctness constraint rather than a style — the
      # same shape Library::Reconciler#plan_moves takes, for a related reason. Destroying inside
      # the sweep removes the very rows the walk still needs: a node whose ancestor directory was
      # already destroyed this pass has no chain left to rebuild, so it answers `false` and
      # SURVIVES as a live orphan beneath a marker — which is exactly the node that then trips the
      # mass-deletion guard this service exists to keep from tripping. Order-dependent, silent, and
      # found by driving it: the first draft left 20 of 21 objects behind and the scan still
      # refused.
      doomed = []
      Node.find_each do |node|
        doomed << node.id if beneath_marker?(node, cache) && !keep.include?(key(node))
      end

      doomed.each_slice(DESTROY_BATCH) { |ids| Node.where(id: ids).destroy_all }
      Result.new(destroyed: doomed.size, skipped:, declined: false)
    end

    def self.scannable? = FileLayer.current.capabilities.scannable?
    private_class_method :scannable?

    # A node something ELSE points at is REPORTED and SKIPPED, never destroyed — destroying it
    # silently orphans that reference, which is this repo's signature failure mode, and a scan
    # tombstoning it later at least leaves Maker::AttachmentReaper's grace window for someone to
    # notice. Loud beats clever.
    #
    # THREE POINTERS, NOT ONE. `maker_file_attachments.node_id` is the obvious one; the two
    # `cover_node_id` columns are not, and they are the WORSE case rather than a lesser one:
    # Maker::DeadNodes.reapable? returns true for a nil node, so a destroyed cover is reapable
    # IMMEDIATELY, with none of the grace a tombstone would have bought — the chosen cover is
    # cleared and nothing anywhere says why. Practically unreachable, since covers are images and
    # these are a repo's internals, but it is the same silent-orphan class this method exists for
    # and it costs one pluck each.
    #
    # ITS ANCESTORS ARE KEPT WITH IT. Destroying the directories a skipped node hangs off leaves a
    # live row whose parent_node_id resolves to nothing — an orphan of a different kind, and one
    # that goes silent: the next run cannot rebuild the path, so the node it refused to destroy
    # stops being reported at all. A skip that reports once and then forgets is not loud.
    #
    # DRIVEN FROM THE REFERENCES, not from a per-node exists? inside the sweep. References are few
    # and nodes are many; the other direction is one query per node beneath a marker, which on a
    # real repo is tens of thousands of queries inside a deploy.
    def self.pin_referenced(cache, keep)
      referenced.filter_map do |user_id, node_id|
        node = Node.find_by(user_id:, node_id:)
        next if node.nil? || !beneath_marker?(node, cache)

        keep << key(node)
        ancestors(node, cache).each { |a| keep << key(a) if beneath_marker?(a, cache) }
        node
      end
    end
    private_class_method :pin_referenced

    # Every (user_id, node_id) the maker layer points at, deduplicated. `where.not(nil)` on the
    # cover columns because most rows have none.
    def self.referenced
      (Maker::FileAttachment.distinct.pluck(:user_id, :node_id) +
        Maker::Project.where.not(cover_node_id: nil).distinct.pluck(:user_id, :cover_node_id) +
        Maker::Model.where.not(cover_node_id: nil).distinct.pluck(:user_id, :cover_node_id)).uniq
    end
    private_class_method :referenced

    # Is this node STRICTLY BENEATH a `.git` directory? See the header for why the question is
    # asked of a rebuilt path rather than of an ancestor's name.
    def self.beneath_marker?(node, cache)
      RepoMetadata.internal?(path_for(node, cache))
    end
    private_class_method :beneath_marker?

    # The node's path, rebuilt by walking parent_node_id. A library ROOT that is itself a node
    # would contribute a leading segment, which does not change internal?'s answer — it asks only
    # whether a `.git` segment appears with something under it. A walk stopped by the cap is a
    # different matter; see MAX_ANCESTOR_WALK.
    def self.path_for(node, cache)
      ancestors(node, cache).reverse.map(&:name).push(node.name).join("/")
    end
    private_class_method :path_for

    # The chain above `node`, nearest first.
    def self.ancestors(node, cache)
      out = []
      id = node.parent_node_id
      MAX_ANCESTOR_WALK.times do
        break if id.nil?

        parent = lookup(cache, node.user_id, id)
        break if parent.nil?

        out << parent
        id = parent.parent_node_id
      end
      out
    end
    private_class_method :ancestors

    # The cache is a LOCAL built per #call and threaded through, never module state. A memo on the
    # module would outlive the call that filled it, so a second run in one process would answer
    # from rows the first run destroyed — and this is deliberately re-runnable by hand. That is not
    # a theoretical tidiness: with a module memo, a marker RENAMED between two runs still reads as
    # `.git` from the stale row, and the second run destroys files beneath no marker at all.
    def self.lookup(cache, user_id, node_id)
      key = [ user_id, node_id ]
      return cache[key] if cache.key?(key)

      cache[key] = Node.select(:node_id, :name, :kind, :parent_node_id, :user_id)
                       .find_by(user_id:, node_id:)
    end
    private_class_method :lookup

    def self.key(node) = [ node.user_id, node.node_id ]
    private_class_method :key
  end
end
