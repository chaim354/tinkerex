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
  # DESTROY, NOT TOMBSTONE. These paths will never be observed again, so a tombstone would sit
  # there forever as a revivable row for a file that cannot come back — and §14a's
  # two-tombstone-kinds rule makes a lingering trash-kind row actively worse than no row:
  # Reconciler#create_or_revive! could hand a new, unrelated file that node_id along with every
  # attachment, BOM link and tag pointing at it.
  #
  # TOMBSTONES GO TOO, not just live rows, and the criterion is why: this asks "will this path ever
  # be observed again", which the `deleted` flag does not bear on. A row left behind could only be
  # revived by an observation at its exact storage_path (#create_or_revive! matches nothing else),
  # and there will never be one — so it is inert, permanently, while still claiming a place in the
  # catalog. The bytes of a trash-kind tombstone are collected by the ordinary `.trash` sweep,
  # which reads entry-dir mtimes and never a row; restoring one was already impossible, since
  # undelete goes through FileLayer::Share#observable!, which refuses at-or-beneath the marker.
  #
  # RESOLVED BY THE PARENT CHAIN, NOT BY storage_path. On chunk_remote storage_path is NULL for
  # every node (§14a), so a purge reading only that column would do nothing at all on the product's
  # main deployment while every test built on share fixtures stayed green — this repo's signature
  # failure shape. Share and s3 populate BOTH columns (Reconciler#create_or_revive! and
  # #ensure_dirs each set parent_node_id), so the chain alone answers on all three backends and
  # there is no second mechanism to disagree with.
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
    # real library depth. A walk that hits the cap yields a partial path, which answers `false` and
    # therefore SKIPS the node — the safe direction.
    MAX_ANCESTOR_WALK = 64

    # How many ids one destroy statement carries. The decision pass holds ids rather than rows, so
    # the whole run is bounded by an Integer array however large the repository is.
    DESTROY_BATCH = 500

    Result = Data.define(:destroyed, :skipped)

    def self.call
      cache = {}
      keep = Set.new
      skipped = pin_attached(cache, keep)

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
      Result.new(destroyed: doomed.size, skipped:)
    end

    # A node carrying a maker_file_attachments row is REPORTED and SKIPPED, never destroyed —
    # destroying it silently orphans a project reference, which is this repo's signature failure
    # mode, and a scan tombstoning it later at least leaves Maker::AttachmentReaper's grace window
    # for someone to notice. Loud beats clever.
    #
    # ITS ANCESTORS ARE KEPT WITH IT. Destroying the directories a skipped node hangs off leaves a
    # live row whose parent_node_id resolves to nothing — an orphan of a different kind, and one
    # that goes silent: the next run cannot rebuild the path, so the node it refused to destroy
    # stops being reported at all. A skip that reports once and then forgets is not loud.
    #
    # DRIVEN FROM THE ATTACHMENTS, not from a per-node exists? inside the sweep. Attachments are
    # few and nodes are many; the other direction is one query per node beneath a marker, which on
    # a real repo is tens of thousands of queries inside a deploy.
    def self.pin_attached(cache, keep)
      Maker::FileAttachment.distinct.pluck(:user_id, :node_id).filter_map do |user_id, node_id|
        node = Node.find_by(user_id:, node_id:)
        next if node.nil? || !beneath_marker?(node, cache)

        keep << key(node)
        ancestors(node, cache).each { |a| keep << key(a) if beneath_marker?(a, cache) }
        node
      end
    end
    private_class_method :pin_attached

    # Is this node STRICTLY BENEATH a `.git` directory? See the header for why the question is
    # asked of a rebuilt path rather than of an ancestor's name.
    def self.beneath_marker?(node, cache)
      RepoMetadata.internal?(path_for(node, cache))
    end
    private_class_method :beneath_marker?

    # The node's path, rebuilt by walking parent_node_id. A library ROOT that is itself a node
    # would contribute a leading segment, and a broken chain drops the segments above the break —
    # neither changes internal?'s answer, which asks only whether a `.git` segment appears with
    # something under it.
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
    # from rows the first run destroyed — and this is deliberately re-runnable by hand.
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
