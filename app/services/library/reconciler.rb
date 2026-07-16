module Library
  # Turns "what's on disk now" into creates / updates / moves / tombstones on `nodes`.
  #
  # The matching ORDER is the product promise, and each step exists because the one before it
  # cannot answer the case:
  #
  #   1. live path match  — the same path is the same file (cheap, and the overwhelming case)
  #   2. move-pair by (content_hash, size) — recovers a rename or a move
  #   3. revive a tombstone at the path — a file restored where a deleted one used to be
  #   4. create           — genuinely new
  #
  # A rename that loses its node_id breaks every project attachment, BOM link, tag, and preview
  # pointing at that file. Users reorganize a NAS constantly, so this is not an edge case.
  #
  # Step 2 MUST come before step 3: a `b.stl -> a.stl` move where a.stl was itself deleted would
  # otherwise fight the tombstone at a.stl, and the move — the case with a live node_id to keep
  # — is the one that must win. #call runs the four steps in that order, visibly.
  #
  # The Scanner OBSERVES; this DECIDES. The split is what lets the matching algorithm be tested
  # without a filesystem (inject `reader:`) and the walk be tested without a database.
  #
  # WHY THIS WRITES `nodes` DIRECTLY, bypassing Sync::Mutation — whose header states that every
  # change to the tree funnels through it: no `next_seq!`, no changelog entry, `updated_seq`
  # stays 0. Share libraries are `syncable: false` (FileLayer::Share#capabilities), so there are
  # no devices and no changelog consumers. This is the one place a tree write legitimately
  # bypasses Mutation — routing a scan through it would mint a changelog entry per file for
  # readers that do not exist, and the changelog is an explicit tripwire for this phase
  # (spec §10). A reader who knows Mutation should read this paragraph, not a bug.
  #
  # WHY NO TRANSACTION, when every neighbor (Sync::Mutation, SubtreeDelete, Gc.prune_version!)
  # wraps its work in one: a pass hashes what may be a 2TB tree, so a transaction spanning it
  # would pin a connection and a snapshot open for hours to buy atomicity nobody needs. A scan
  # is a periodic observation, not a user's edit — and it is idempotent, so a crash mid-pass is
  # repaired by the next pass rather than by a rollback (tombstone-then-crash revives on the
  # next pass; a ghost directory survives one extra pass). Per-row `update!` is already atomic,
  # which is the only atomicity a single node's correctness needs.
  class Reconciler
    # `root` is where a rel_path resolves to real bytes; `reader` replaces reading them at all
    # (tests inject it, so the algorithm needs no filesystem). One of the two is required.
    #
    # The root is passed IN rather than taken from `FileLayer.current.root`: the Reconciler is
    # given its observations, so reaching for the global to resolve them would couple it to a
    # deployment-wide setting that is `Chunk` (which has no root at all) in most runs — a
    # NoMethodError in exactly the tests that matter. The Scanner already knows its root.
    def initialize(user, observations:, root: nil, reader: nil)
      raise ArgumentError, "a root: or a reader: is required" if root.nil? && reader.nil?
      @user = user
      @observations = observations
      @root = root && Pathname.new(root).expand_path
      @reader = reader
      @dir_ids = {} # rel_path => node_id, filled by ensure_dirs as it walks shallowest-first
    end

    # The live file nodes these observations do not account for — the set this pass would
    # tombstone, before move-pairing rescues the renames among them.
    #
    # PURE and WRITE-FREE, and public, because Task 7's mass-deletion guard has to ask "how many
    # files would this scan tombstone?" BEFORE any of them are tombstoned. Sharing this one
    # definition is the point: if the guard recomputed the missing-set on its own, any later
    # change to what counts as accounted-for (symlinks, a new skip case) would silently leave the
    # guard guarding a different number than the one #call actually acts on — a quiet failure in
    # the code whose entire job is being loud.
    def vanished_paths
      observed = @observations.reject(&:dir).map(&:rel_path).to_set
      live_file_paths.reject { |p| observed.include?(p) }
    end

    def call
      dirs, files = @observations.partition(&:dir)

      # Computed BEFORE any write, so it is the same set Task 7's guard sees when it asks the
      # question ahead of time.
      doomed = vanished_paths

      ensure_dirs(dirs)
      unmatched  = match_live_paths(files)                    # 1
      leftovers  = pair_moves(vanished_nodes(doomed), unmatched) # 2 (tombstones the unpaired)
      leftovers.each { |o, hash| create_or_revive!(o, hash) }  # 3 & 4
      tombstone_vanished_dirs(dirs)
      nil # Task 9 can define a result when it knows what it wants to read.
    end

    private

    # Step 1. Returns the observations that no live node claims — the input to step 2.
    def match_live_paths(files)
      # KNOWN LIMITATION: this loads every live node into memory (~1M AR objects on a large NAS).
      # It must be batched before a real NAS is pointed at this; Task 10's synthetic E2E will not
      # surface it, and Task 8 has not wired the backend factory yet.
      live_by_path = @user.nodes.present.where.not(storage_path: nil).index_by(&:storage_path)

      files.reject do |o|
        node = live_by_path[o.rel_path]
        next false if node.nil?

        if !node.file?
          # The path used to be a directory (or a symlink) and is now a file. Reusing the row
          # would silently change a node's kind under everything that points at it; a clean
          # break is the honest answer.
          node.update!(deleted: true)
          next false # ...and the observation still needs a node: hand it to step 2.
        end

        if node.mtime == o.mtime && node.size == o.size
          # Unchanged (path, mtime, size): skip WITHOUT hashing. This is the whole reason
          # Observation carries a stat and not a hash — it is what keeps a 2TB archive from
          # being re-read on every pass.
          next true
        end

        hash = hash_for(o)
        # A file we cannot read is NOT a file that is gone: leave the node exactly as it was.
        # It is claimed either way (its path is observed, so vanished_paths never listed it),
        # so nothing below can tombstone it. The next pass picks it up when the blip clears.
        node.update!(size: o.size, mtime: o.mtime, content_hash: hash) if hash
        true
      end
    end

    # The nodes behind vanished_paths. Re-read after step 1 so anything step 1 tombstoned (a
    # kind collision) is already gone from `present` and cannot be handled twice.
    def vanished_nodes(paths)
      return [] if paths.empty?
      # Ordered so ambiguous pairings resolve identically on every run.
      @user.nodes.present.where(kind: "file", storage_path: paths).order(:storage_path).to_a
    end

    # Step 2. Pair a vanished path with an unexplained new one by (content_hash, size) — that is
    # a move. Returns the [observation, hash] pairs nothing claimed, for steps 3-4.
    def pair_moves(vanished, unmatched)
      # filter_map: an unreadable NEW file yields no hash, so it cannot be paired and must not
      # be created half-indexed (a node with a nil content_hash is a preview that can never be
      # keyed). Leaving it out entirely means the next pass indexes it properly.
      candidates = unmatched.filter_map { |o| (h = hash_for(o)) && [ o, h ] }

      vanished.each do |node|
        idx = best_pairing(candidates, node)
        if idx
          o, hash = candidates.delete_at(idx)
          node.update!(storage_path: o.rel_path, name: File.basename(o.rel_path),
                       parent_node_id: parent_id_for(o.rel_path),
                       mtime: o.mtime, size: o.size, content_hash: hash)
        else
          # Tombstone, never destroy: a project shows "file missing" instead of an attachment
          # silently vanishing. A move AND an edit within one interval is indistinguishable
          # from delete+create — the bytes changed, so there is nothing left to pair on — and
          # degrades to exactly that. Accepted and tested, not silent.
          node.update!(deleted: true)
        end
      end

      candidates
    end

    # Several byte-identical files make pairing non-unique (a CAD library is full of them), so
    # "the right answer" does not exist. Prefer the candidate sharing the longest directory
    # prefix with the old path, then lexical: any DETERMINISTIC answer beats a crash or a lost
    # file. Returns nil when nothing matches.
    #
    # O(n*m) by design: 10k renamed files measures at ~2s of CPU, which is dwarfed by the hashing
    # those same 10k files already require. Not worth an index until that ceases to be true.
    def best_pairing(candidates, node)
      return nil if node.content_hash.blank?
      candidates.each_index
                .select { |i| candidates[i][1] == node.content_hash && candidates[i][0].size == node.size }
                .min_by { |i| [ -common_prefix_len(node.storage_path, candidates[i][0].rel_path), candidates[i][0].rel_path ] }
    end

    # Steps 3 & 4. A file reappearing where a tombstoned one used to be REVIVES that node rather
    # than creating a new one alongside it. Without this, the partial unique index on
    # (user_id, storage_path) WHERE deleted = false lets the create succeed with a NEW node_id,
    # silently orphaning every attachment the old node carried. (Before that index it raised
    # RecordNotUnique and killed the scan — loud. The index made the data loss quiet.)
    #
    # Trade-off: if the user deliberately put DIFFERENT content at that path, the attachment now
    # points at it. That is the same trade already accepted for an edit-in-place, which likewise
    # keeps its node_id when the bytes change.
    def create_or_revive!(o, hash)
      tomb = @user.nodes.where(storage_path: o.rel_path, deleted: true, kind: "file")
                  .order(id: :desc).first
      attrs = { name: File.basename(o.rel_path), kind: "file", deleted: false,
                storage_path: o.rel_path, parent_node_id: parent_id_for(o.rel_path),
                size: o.size, mtime: o.mtime, content_hash: hash }
      return tomb.update!(**attrs) if tomb
      @user.nodes.create!(node_id: SecureRandom.uuid, **attrs)
    end

    def common_prefix_len(a, b)
      x = File.dirname(a.to_s).split("/")
      y = File.dirname(b.to_s).split("/")
      i = 0
      i += 1 while i < x.length && i < y.length && x[i] == y[i]
      i
    end

    # Directory nodes are synthesized from paths so parent_node_id still forms the tree — that
    # is what keeps browse/search/tags working unmodified across backends.
    #
    # Shallowest-first is STRUCTURAL, not defensive: each directory records its node_id in
    # @dir_ids as it goes, and its children then read the parent straight out of that map. A
    # parent is therefore always in the map before any child asks for it — and that is also what
    # kills the per-file parent lookup. (The Scanner already emits parent-before-child, which
    # reconciler_test pins; this sort means the Reconciler does not depend on it.)
    def ensure_dirs(dirs)
      dirs.sort_by { |o| o.rel_path.count("/") }.each do |o|
        node = @user.nodes.present.find_by(storage_path: o.rel_path)
        if node && !node.dir?
          # The path used to be a file and is now a directory. Same reasoning as the inverse
          # case above: break cleanly rather than mutate a node's kind under its references.
          node.update!(deleted: true)
          node = nil
        end
        # Reviving a tombstoned directory is right for the same reason it is right for a file,
        # and is why this cannot simply be `present.find_or_initialize_by`: that would ignore
        # `deleted` and pick an arbitrary row when both a tombstone and a live node exist.
        node ||= @user.nodes.where(storage_path: o.rel_path, kind: "dir").order(id: :desc).first
        node ||= @user.nodes.new(node_id: SecureRandom.uuid)
        node.update!(name: File.basename(o.rel_path), kind: "dir", deleted: false,
                     storage_path: o.rel_path, parent_node_id: parent_id_for(o.rel_path),
                     mtime: o.mtime)
        @dir_ids[o.rel_path] = node.node_id
      end
    end

    # A directory that is gone is gone: without this, deleting `cad/` tombstones its files but
    # leaves `cad` itself live forever — an empty ghost folder in every browse view, and a
    # parent_node_id that resolves to a directory the user deleted.
    #
    # Deepest-first, so a child is tombstoned before its parent.
    def tombstone_vanished_dirs(dirs)
      observed = dirs.map(&:rel_path).to_set
      @user.nodes.present.where(kind: "dir").where.not(storage_path: nil)
           .order(:storage_path).to_a
           .reject { |n| observed.include?(n.storage_path) }
           .sort_by { |n| -n.storage_path.count("/") }
           .each { |n| n.update!(deleted: true) }
    end

    # A hash hit for any directory this scan observed (ensure_dirs filled the map before any
    # file could ask). The DB fallback covers a parent that is NOT among the observations — a
    # partial scan, or a caller passing files without their dirs.
    def parent_id_for(rel)
      dir = File.dirname(rel)
      return nil if dir == "."
      @dir_ids[dir] || @user.nodes.present.find_by(storage_path: dir)&.node_id
    end

    def live_file_paths
      @user.nodes.present.where(kind: "file").where.not(storage_path: nil)
           .order(:storage_path).pluck(:storage_path)
    end

    # Hash on demand — only for a file whose (path, mtime, size) says it actually changed.
    #
    # The filesystem path goes through Digest::SHA256.file (streaming: a 2GB STEP file must not
    # be read into memory to be hashed). Returns nil when the bytes cannot be read; every caller
    # treats nil as "skip this file", never as "this file is gone". A permission blip, a stale
    # NFS handle, or an unmounted subtree must never tombstone anything.
    def hash_for(o)
      return Digest::SHA256.hexdigest(@reader.call(o.rel_path)) if @reader
      Digest::SHA256.file(@root.join(o.rel_path)).hexdigest
    rescue SystemCallError => e
      Rails.logger.warn("library reconcile: cannot hash #{o.rel_path.inspect}: " \
                        "#{e.class} (#{e.message}) — skipping, not tombstoning")
      nil
    end
  end
end
