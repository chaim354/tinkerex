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
  # WHERE THE IDENTITY COMES FROM, and why this is asymmetric. Steps 1 and 2 both turn on
  # content_hash, and this class was built to compute it LAZILY — `reader:`/`root:`, on demand,
  # only for a file the (mtime, size) skip says actually changed. That is right when identity
  # costs a read of the bytes, which on a mounted share it does: it is what keeps a 2TB archive
  # from being re-read every pass.
  #
  # It is exactly wrong for an observer that gets identity FREE. S3 hands the ETag over in the
  # listing, so lazily "saving" a read would mean downloading the object to recompute a value we
  # were already given — a full egress of the bucket to index a library the user already has.
  # So an Observation MAY carry its own content_hash (Library::Observation), and when it does
  # this class takes it verbatim: hash_for never calls the reader, and the skip compares the
  # identity rather than inferring change from a coarser (mtime, size). An observer that cannot
  # know it leaves the field nil and gets the lazy path, unchanged.
  #
  # The rule underneath both: an observer is never made to pay twice for something it already
  # knows, and never made to claim something it does not.
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
    # How much of the observable library one pass may tombstone before we assume the input is a
    # lie rather than the user's intent.
    DEFAULT_MAX_DELETE_PCT = 20

    # `root` is where a rel_path resolves to real bytes; `reader` replaces reading them at all
    # (tests inject it, so the algorithm needs no filesystem). One of the two is required.
    #
    # The root is passed IN rather than taken from `FileLayer.current.root`: the Reconciler is
    # given its observations, so reaching for the global to resolve them would couple it to a
    # deployment-wide setting that is `Chunk` (which has no root at all) in most runs — a
    # NoMethodError in exactly the tests that matter. The Scanner already knows its root.
    #
    # `unreadable_dirs` is part of the observation, not a separate concern: it is the Scanner
    # saying "and here is what I could not see." A pass that tombstones on absence is only
    # entitled to do so where it actually looked, so the two must arrive together — which is why
    # it is REQUIRED rather than defaulted to []. A caller who forgets it would get, silently,
    # the exact data loss this argument exists to prevent: every file under an unreadable
    # directory tombstoned because we could not look. `unreadable_dirs: []` at a call site is a
    # claim ("the walk was complete"), and it should have to be made out loud.
    # (A `Scanner::Report = Data.define(:observations, :unreadable_dirs)` would make "arrive
    # together" a type rather than a promise. Not worth the restructure at this signature size.)
    #
    # `max_delete_pct` overrides the mass-deletion threshold. It exists so a test can say "this
    # fixture is not about the guard" in one visible keyword (100 = never refuse) instead of
    # every two-file fixture tripping a percentage written for a NAS. Nil means the deployment's
    # setting, which is the only thing production ever passes.
    def initialize(user, observations:, unreadable_dirs:, max_delete_pct: nil,
                   root: nil, reader: nil)
      raise ArgumentError, "a root: or a reader: is required" if root.nil? && reader.nil?
      @user = user
      @observations = observations
      @unreadable_dirs = unreadable_dirs
      @max_delete_pct = max_delete_pct
      @root = root && Pathname.new(root).expand_path
      @reader = reader
      @dir_ids = {} # rel_path => node_id, filled by ensure_dirs as it walks shallowest-first
    end

    # The live file nodes these observations do not account for — the set this pass would
    # tombstone, before move-pairing rescues the renames among them.
    #
    # PURE and WRITE-FREE, and public, because the mass-deletion guard has to ask "how many files
    # would this scan tombstone?" BEFORE any of them are tombstoned. Sharing this one definition
    # is the point: if the guard recomputed the missing-set on its own, any later change to what
    # counts as accounted-for (symlinks, a new skip case) would silently leave the guard guarding
    # a different number than the one #call actually acts on — a quiet failure in the code whose
    # entire job is being loud.
    #
    # It remains an UPPER BOUND on the tombstones: a renamed file's old path is genuinely missing
    # from disk and appears here, and only move-pairing later rescues it. The guard must NOT read
    # this number directly — see #guard_mass_deletion!.
    def vanished_paths
      observed = @observations.reject(&:dir).map(&:rel_path).to_set
      observable_live_paths.reject { |p| observed.include?(p) }
    end

    def call
      dirs, files = @observations.partition(&:dir)

      # Both read the memoized observable set, so the guard's numerator and its denominator are
      # drawn from one pluck — and both are computed BEFORE any write.
      #
      # `vanished` is the UPPER BOUND, not the tombstone set: it still contains every renamed
      # file's old path. Only `doomed` below — what pairing could not explain — is what would
      # actually be tombstoned, and it is the only one the guard may read. Conflating the two is
      # precisely the bug this design exists to avoid, so the names are kept apart.
      vanished         = vanished_paths
      observable_count = observable_live_paths.size

      ensure_dirs(dirs)
      unmatched = match_live_paths(files)                                      # 1
      moves, doomed, leftovers = plan_moves(vanished_nodes(vanished), unmatched) # 2 (decide)

      # The guard sits HERE — after pairing has settled which of the vanished are merely moved,
      # and before the first destructive write. Earlier is not possible (pairing is what turns
      # the upper bound into the real tombstone set) and later is not safe.
      #
      # Steps 1 and ensure_dirs have already written by now, which is deliberate and not a
      # partial-apply hazard: both only write nodes for paths this pass actually OBSERVED —
      # including, on a kind collision, tombstoning the node whose kind changed. That tombstone
      # rests on positive evidence (a path observed with a different kind), not on absence, so it
      # is correct whether or not the guard fires, and it is revivable. And in the case the guard
      # exists for — an unmounted NAS, zero observations — both are handed empty lists and write
      # nothing at all before the raise.
      guard_mass_deletion!(doomed.size, observable_count)

      apply_moves!(moves)                                      # 2 (apply)
      doomed.each { |node| node.update!(deleted: true) }
      leftovers.each do |o, hash|                                # 3 & 4
        node = create_or_revive!(o, hash)
        # Eagerly render a thumbnail for a file the scan just brought into the catalog. Best-effort:
        # a render enqueue must NEVER fail the scan (which is tombstoning/reviving the whole
        # library). Enqueue self-guards on renderer presence (nil for non-renderable names), and
        # `hash` is the content_token for the share/s3 port -- the same value stat returns.
        begin
          Maker::Previews::Enqueue.call(user: @user, node_id: node.node_id,
                                        name: File.basename(o.rel_path), version_id: hash)
        rescue StandardError
          nil
        end
      end
      tombstone_vanished_dirs(dirs)
      # nil on purpose. Task 9's ScanJob reads #unreadable_dirs off the Scanner instance and
      # wants nothing from this return value, so there is still no caller to design a result for.
      nil
    end

    private

    # Refuse to reconcile a pass that would tombstone an implausible share of the library. An
    # unmounted NAS, a wrong LIBRARY_PATH, and a half-mounted share all look identical to "the
    # user deleted everything" — and those tombstones propagate to every project attachment.
    # Immich, Photoprism and Plex each learned this one the hard way (spec §6).
    #
    # `doomed_count` is the POST-pairing count — what would actually be tombstoned — never
    # vanished_paths. Guarding the upper bound would count every rename as a deletion and refuse
    # any reorganization above the threshold, which is precisely the thing this phase exists to
    # survive: the headline case (one file moved to a new folder) is a 100% "vanish" and a 0%
    # deletion.
    #
    # The denominator is the OBSERVABLE library, not the whole of it. A large unreadable region
    # would otherwise dilute the percentage until a genuine mass deletion slipped under it (5 of
    # the only 5 readable files gone reading as 4.8% of 105).
    #
    # KNOWN TRADE: a percentage has no floor, so a 3-file library loses a file at 33% and the
    # scan refuses until the operator raises the threshold. Small libraries are not the use case
    # this backend is for (a NAS archive is), and an absolute floor would blind the guard to the
    # unmount of a small library — which is the one thing it is here to stop. Stated so a future
    # floor has to argue with this paragraph rather than quietly widen the hole.
    #
    # SCOPE: this guards FILES only — tombstone_vanished_dirs is in neither the numerator nor the
    # denominator, even though #call tombstones directories too. Deliberate, and the window is
    # narrow and self-healing: reaching a dir-only tombstone requires observable_count to be zero
    # (a library of directories and no files) with the root present but empty, and ensure_dirs
    # revives a tombstoned directory by storage_path with its original node_id on the next pass.
    # No attachment points at a dir node. Threading dirs into both sides would disturb the
    # numerator/denominator symmetry for a low payoff; it belongs with Phase 2b, whose write path
    # would add a second producer of observations. Stated so that work argues with this position
    # rather than discovering the gap.
    def guard_mass_deletion!(doomed_count, observable_count)
      return if doomed_count.zero? || observable_count.zero?

      pct = (doomed_count.to_f / observable_count) * 100
      return if pct <= max_delete_pct

      raise Library::Scanner::UnsafeScan,
            "scan would tombstone #{doomed_count}/#{observable_count} observable files " \
            "(#{pct.round(1)}% > #{max_delete_pct}%).#{unreadable_note} Refusing — is the share " \
            "mounted? Set LIBRARY_SCAN_MAX_DELETE_PCT to override."
    end

    # A refusal should diagnose itself. "N directories were unreadable" is usually the whole
    # explanation for a half-mounted share, and those subtrees are excluded from BOTH sides of
    # the fraction above — so without this the operator sees a percentage computed over a
    # population they have no way to know was reduced.
    def unreadable_note
      return "" if @unreadable_dirs.empty?
      " #{@unreadable_dirs.size} directories were unreadable and excluded " \
        "(#{@unreadable_dirs.first(3).map(&:inspect).join(', ')}#{'...' if @unreadable_dirs.size > 3})."
    end

    # Read PER CALL, not frozen into a constant at class load: the raise above names this
    # variable as the operator's way out, and a value fixed at boot makes that advice false
    # inside a running process (and unreachable from a test, which is how an escape hatch rots
    # shut). One ENV fetch per scan — not per file — costs nothing.
    def max_delete_pct
      @max_delete_pct ||
        Integer(ENV.fetch("LIBRARY_SCAN_MAX_DELETE_PCT", DEFAULT_MAX_DELETE_PCT.to_s))
    end

    # Live file paths this pass was actually in a position to see. An unreadable directory's
    # subtree is absent from the observations through no fault of the filesystem's CONTENTS —
    # Dir.children raised, so we never looked. Excluding it here rather than in the guard is the
    # whole point: #call reads the same method, so it cannot tombstone what the guard never
    # counted. Two definitions and the guard approves a pass that then deletes files it did not
    # know about.
    #
    # MEMOIZED so the guard's numerator and denominator are literally one snapshot rather than
    # two independent plucks that merely happen to agree (there is no transaction — see the class
    # header — so 2b's write path could otherwise slip between them). A Reconciler is already
    # single-use: @dir_ids accumulates across #call, so caching the pre-write tree here is
    # consistent with what the object already is. It also halves the pluck of the whole live-file
    # path set.
    def observable_live_paths
      @observable_live_paths ||=
        @unreadable_dirs.empty? ? live_file_paths : live_file_paths.reject { |p| unobserved?(p) }
    end

    # Path-boundary matching, never a bare string prefix: "secrets/x.stl" is not inside "secret".
    # "." is the Scanner's report that the ROOT itself could not be listed — nothing was observed,
    # so nothing can be called absent.
    def unobserved?(path)
      @unreadable_dirs.any? { |d| d == "." || path == d || path.start_with?("#{d}/") }
    end

    # Step 1. Returns the observations that no live node claims — the input to step 2.
    def match_live_paths(files)
      # PLUCKED, not loaded: the decisions below read exactly four columns (kind, mtime, size,
      # content_hash) and in the common case write NOTHING, so instantiating an AR object per live
      # node buys nothing and costs the whole tree's worth of memory.
      #
      # THE COMMON CASE IS A NO-OP SCAN — every 15 minutes, forever, with nothing changed. The
      # previous `index_by(&:storage_path)` loaded a full AR object per live node to discover
      # precisely that. Plucking the columns it actually reads, and materializing a node ONLY in
      # the two branches that write, leaves a no-op pass loading zero AR objects. Measured:
      #
      #   20k-file no-op scan   0.159s / 552k objects (27.6/file)  ->  0.061s / 311k (15.6/file)
      #   50k-node no-op scan   +67.1 MB RSS                        ->  +22.7 MB RSS
      #
      # The allocations that remain are the pluck's own rows and the Observations, not the tree.
      #
      # The `id` is plucked solely so a branch that DOES write can load its row. That costs one
      # SELECT per written node — a real regression against the single query this used to do —
      # and it is the right trade: a node only reaches those branches if its bytes are being
      # hashed (a file read that dwarfs a primary-key lookup) or its kind changed (rare), while
      # the pass that pays nothing is the one that runs every quarter hour.
      # `content_hash` is plucked for the identity skip below — a sixth value out of the query
      # that was already reading the row, not a sixth query. It is NOT free, and the number is
      # here so the next person does not have to re-derive it: one more string materialized per
      # live node. A/B'd on one machine, 20k-file no-op scan, 5 columns -> 6:
      #
      #   0.024s / 160k objects (8.0/file)  ->  0.028s / 180k objects (9.0/file)
      #
      # +1 object/file exactly, ~17% on a pass that is pluck-bound by construction. Paid because
      # the skip cannot compare an identity it did not read, and (mtime, size) alone is provably
      # too coarse for S3 (see #unchanged?). It does not scale with library SIZE any differently
      # than the five columns already did.
      live = @user.nodes.present.where.not(storage_path: nil)
                  .pluck(:storage_path, :id, :kind, :mtime, :size, :content_hash)
                  .to_h { |path, id, kind, mtime, size, hash| [ path, [ id, kind, mtime, size, hash ] ] }

      files.reject do |o|
        row = live[o.rel_path]
        next false if row.nil?
        id, kind, mtime, size, content_hash = row

        # NOTE: `kind` is the RAW DB value here (pluck bypasses the model), not `node.file?`.
        # Identical today — kind is a plain string column. But if it ever became an AR enum,
        # pluck would hand back the integer and this branch would fire for EVERY node,
        # tombstoning the whole library on the next scan. Remote; cheap to say; and this file
        # has punished exactly this shape of assumption before.
        if kind != "file"
          # The path used to be a directory (or a symlink) and is now a file. Reusing the row
          # would silently change a node's kind under everything that points at it; a clean
          # break is the honest answer.
          @user.nodes.find(id).update!(deleted: true)
          next false # ...and the observation still needs a node: hand it to step 2.
        end

        if unchanged?(o, mtime, size, content_hash)
          # Skip WITHOUT hashing, and — note the early return — without ever loading the row. In
          # a no-op scan every file lands here, which is what makes that pass cost a single
          # pluck, and the no-op scan is the one that runs every 15 minutes forever.
          next true
        end

        hash = hash_for(o)
        # A file we cannot read is NOT a file that is gone: leave the node exactly as it was.
        # It is claimed either way (its path is observed, so vanished_paths never listed it),
        # so nothing below can tombstone it. The next pass picks it up when the blip clears.
        # The row is loaded only once `hash` proves there is something to write.
        @user.nodes.find(id).update!(size: o.size, mtime: o.mtime, content_hash: hash) if hash
        true
      end
    end

    # "This observation says nothing the node does not already record" — the incremental skip,
    # and the reason a 2TB archive is not re-read every pass. `mtime`/`size`/`content_hash` are
    # the node's plucked values; `o` is what the observer just saw.
    #
    # NO SUPPLIED IDENTITY (every share scan today): (mtime, size), exactly as before. A stat is
    # all the Scanner has, and asking for more would mean reading the bytes — which is the cost
    # this skip exists to avoid. Bit-for-bit the 2a behavior, and pinned as such by a test.
    #
    # A SUPPLIED IDENTITY additionally has to match. The observer already knows it and comparing
    # it costs nothing (no read, no reader), so refusing to look at it would be a choice to be
    # wrong for free — and on S3 it is the difference that matters: `last_modified` is
    # SECOND-granularity, so an edit landing inside the same second as the last one, at the same
    # size, is invisible to (mtime, size) and would be skipped forever. Comparing the identity
    # closes that window exactly.
    #
    # Why the (mtime, size) half still applies when an identity IS supplied — a deliberate
    # departure from the plan, which said the skip should compare identity INSTEAD. Identical
    # bytes re-uploaded under a new `last_modified` (a copy, a re-sync, a lifecycle transition)
    # change the mtime and nothing else. Comparing identity alone would skip that and leave
    # nodes.mtime stale forever — the UI's date, permanently wrong, for no gain. Falling through
    # costs one SELECT and one UPDATE for an event that is rare, and costs the no-op scan nothing
    # at all: unchanged bytes at an unchanged mtime still skip here, before the row is loaded.
    # This can never skip something the plan's version would have applied — it only applies more.
    # (It does assume an observer's mtime is STABLE for an unmodified entry. One that stamped the
    # clock instead would turn every no-op scan into a full write pass — slow, not wrong, and it
    # would be a broken observer either way. S3's last_modified is stable.)
    def unchanged?(o, mtime, size, content_hash)
      return false if o.content_hash && o.content_hash != content_hash
      mtime == o.mtime && size == o.size
    end

    # The nodes behind vanished_paths. Re-read after step 1 so anything step 1 tombstoned (a
    # kind collision) is already gone from `present` and cannot be handled twice.
    def vanished_nodes(paths)
      return [] if paths.empty?
      # Ordered so ambiguous pairings resolve identically on every run.
      @user.nodes.present.where(kind: "file", storage_path: paths).order(:storage_path).to_a
    end

    # Step 2, DECIDE. Pair a vanished path with an unexplained new one by (content_hash, size) —
    # that is a move. Returns [moves, doomed, leftovers]: the pairings, the vanished nodes nothing
    # explained, and the [observation, hash] pairs nothing claimed (for steps 3-4).
    #
    # Deciding and applying are split so the guard can read the real tombstone count — `doomed` —
    # while every one of those nodes is still live. Fused, the only number available before the
    # first tombstone is the rename-inflated upper bound.
    def plan_moves(vanished, unmatched)
      # filter_map: an unreadable NEW file yields no hash, so it cannot be paired and must not
      # be created half-indexed (a node with a nil content_hash is a preview that can never be
      # keyed). Leaving it out entirely means the next pass indexes it properly.
      #
      # READ THIS BEFORE "FIXING" IT. Dropping an observation here does not skip a step for it —
      # `candidates` is what becomes `leftovers`, which is what create_or_revive! indexes, so a
      # dropped observation is NEVER INDEXED AT ALL. No error, no log, no node. The comment above
      # is what makes that acceptable, and it rests entirely on hash_for's nil being TRANSIENT:
      # its only nil comes from `rescue SystemCallError`, i.e. an EACCES/ENOENT blip on a share,
      # which clears and the next pass indexes the file. An observer whose identity could be
      # PERMANENTLY underivable would be invisible here forever instead — a file in the library
      # that simply never appears. That is why FileLayer::S3::ObjectIdentity is TOTAL (md5: /
      # sha256: / etag:, never nil): nothing from S3 can reach this branch, so the assumption
      # above stays true and this line stays as it is. Weakening either half re-arms it.
      candidates = unmatched.filter_map { |o| (h = hash_for(o)) && [ o, h ] }
      # Bucketed by the pairing key, so a vanished node probes only the byte-identical
      # candidates instead of scanning all of them. `group_by` preserves each bucket's original
      # order, and a missing key reads as nil rather than mutating the hash.
      by_key = candidates.group_by { |o, h| [ h, o.size ] }
      moves = []
      doomed = []
      claimed = {}.compare_by_identity

      vanished.each do |node|
        pair = best_pairing(by_key, node)
        if pair
          # Consumed as we go — from the bucket, so no later node can pair with it, and from
          # `claimed`, so it is excluded from the leftovers handed to steps 3 & 4. Both are
          # keyed by object identity: two candidates are `==` if their observation and hash
          # match, and `delete`/`reject` would then drop the wrong one.
          o, hash = pair
          by_key[[ hash, o.size ]].delete_if { |c| c.equal?(pair) }
          claimed[pair] = true
          moves << [ node, o, hash ]
        else
          # Tombstone, never destroy: a project shows "file missing" instead of an attachment
          # silently vanishing. A move AND an edit within one interval is indistinguishable
          # from delete+create — the bytes changed, so there is nothing left to pair on — and
          # degrades to exactly that. Accepted and tested, not silent.
          doomed << node
        end
      end

      # `candidates`, minus what pairing consumed, in its original order.
      [ moves, doomed, candidates.reject { |p| claimed.key?(p) } ]
    end

    # Step 2, APPLY.
    def apply_moves!(moves)
      moves.each do |node, o, hash|
        node.update!(storage_path: o.rel_path, name: File.basename(o.rel_path),
                     parent_node_id: parent_id_for(o.rel_path),
                     mtime: o.mtime, size: o.size, content_hash: hash)
      end
    end

    # Several byte-identical files make pairing non-unique (a CAD library is full of them), so
    # "the right answer" does not exist. Prefer the candidate sharing the longest directory
    # prefix with the old path, then lexical: any DETERMINISTIC answer beats a crash or a lost
    # file. Returns the [observation, hash] pair, or nil when nothing matches.
    #
    # Why bucketing gives the SAME answer the old full scan gave — and the argument matters,
    # because the obvious one is wrong. It is NOT "the tie-break key is unique so min_by cannot
    # tie": that leans on rel_path uniqueness, a property of the INPUT that nothing here
    # enforces, so a future second observation source would appear to invalidate this code when
    # it in fact would not.
    #
    # The real guarantee is order, and it holds even when the key ties: `group_by` preserves
    # array order, so a bucket IS exactly the subsequence the old `each_index.select` walked, in
    # the same order — and `min_by` returns the FIRST minimum. Same sequence, same rule, same
    # element.
    #
    # Do not weaken the key to just the prefix length. That is not a correctness argument (the
    # above still holds) but a legibility one: a key that ties often makes the answer depend on
    # an ordering nobody reading this would think to check.
    #
    # This used to scan every candidate per vanished node, under a comment claiming "O(n*m) by
    # design: 10k renamed files measures at ~2s of CPU, which is dwarfed by the hashing those
    # same 10k files already require." BOTH halves were wrong, which is why it survived:
    #
    #   - the number was off by ~4.5x. A full 10k all-renamed reconcile measured 8.88s, not ~2s,
    #     and the shape was plainly super-linear: 2k/5k/10k = 0.93s / 3.09s / 8.88s.
    #   - "dwarfed by the hashing" cannot hold, because hashing is LINEAR and this was QUADRATIC.
    #     A crossover is built into the claim: it stops being true exactly when the library grows
    #     big enough for it to matter. Extrapolated, 100k renames ran ~15 min — and ScanJob fires
    #     every 15 minutes, so a large reorganization was on course to overlap itself.
    #
    # Bucketing by the pairing key makes the common case (distinct bytes -> buckets of 1) a hash
    # lookup. Measured, all-files-renamed, distinct bytes:
    #
    #    2k   0.93s -> 0.64s     10k   8.88s -> 3.09s
    #    5k   3.09s -> 1.52s     50k   (not attempted before) -> 19.05s
    #
    # What remains at 10k+ is the per-move UPDATE and the hashing, which are linear and real; the
    # quadratic term is gone from the distinct-bytes case.
    #
    # HONEST REMAINING BOUND: a bucket of N byte-identical files still costs O(N) per probe, so a
    # library that is one file duplicated N times stays quadratic — measured all-identical, 2k
    # 2.36s -> 2.01s and 5k 12.59s -> 10.64s, i.e. barely improved. That is INHERENT to the
    # tie-break above, which must compare the old path against every identical candidate in order
    # to be deterministic; it is not an oversight, and removing it would trade a crash-free
    # guarantee for speed. The realistic shape is many small buckets, not one enormous one.
    def best_pairing(by_key, node)
      return nil if node.content_hash.blank?
      bucket = by_key[[ node.content_hash, node.size ]]
      return nil if bucket.nil? || bucket.empty?
      bucket.min_by { |o, _h| [ -common_prefix_len(node.storage_path, o.rel_path), o.rel_path ] }
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
      # Return the NODE in both branches (update! returns true, so we can't return it directly) —
      # the caller enqueues an eager thumbnail for the file the scan just brought in.
      if tomb
        tomb.update!(**attrs)
        return tomb
      end
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
    #
    # `unobserved?` applies here exactly as it does to files: an unreadable directory is itself
    # observed (its parent listed it) but everything BENEATH it is not, so `secret/sub` is
    # missing from the observations only because Dir.children(secret) raised. Tombstoning it
    # would delete a directory we were never able to look inside.
    def tombstone_vanished_dirs(dirs)
      observed = dirs.map(&:rel_path).to_set
      @user.nodes.present.where(kind: "dir").where.not(storage_path: nil)
           .order(:storage_path).to_a
           .reject { |n| observed.include?(n.storage_path) || unobserved?(n.storage_path) }
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

    # Hash on demand — only for a file whose (path, mtime, size) says it actually changed, and
    # only for an observer that does not already know the answer.
    #
    # An observation that CARRIES its identity is taken verbatim and the reader is never called.
    # That is not an optimization: an S3 lister gets the identity free in the listing, so "saving"
    # a read here would mean downloading the object to recompute something we were handed — a full
    # egress of the bucket on first scan. The value is opaque (a share's bare SHA-256 hex; S3's
    # namespaced md5:/sha256:/etag:) and only ever compared for equality — see Library::Observation.
    #
    # The filesystem path goes through Digest::SHA256.file (streaming: a 2GB STEP file must not
    # be read into memory to be hashed). Returns nil when the bytes cannot be read; every caller
    # treats nil as "skip this file", never as "this file is gone". A permission blip, a stale
    # NFS handle, or an unmounted subtree must never tombstone anything.
    def hash_for(o)
      return o.content_hash if o.content_hash
      return Digest::SHA256.hexdigest(@reader.call(o.rel_path)) if @reader
      Digest::SHA256.file(@root.join(o.rel_path)).hexdigest
    rescue SystemCallError => e
      Rails.logger.warn("library reconcile: cannot hash #{o.rel_path.inspect}: " \
                        "#{e.class} (#{e.message}) — skipping, not tombstoning")
      nil
    end
  end
end
