require "test_helper"

module Library
  # The matching algorithm: path first, then (content_hash, size) to recover moves. A rename
  # that loses its node_id breaks every project attachment, BOM link, tag, and preview pointing
  # at that file — so these cases ARE the product promise.
  class ReconcilerTest < ActiveSupport::TestCase
    setup { @user = User.create!(email: "rec-#{SecureRandom.hex(4)}@example.com") }

    T0 = 1_700_000_000_000_000_000

    # `mtime:` is explicit because the reconciler skips a file whose (path, mtime, size) is
    # unchanged WITHOUT hashing it — that incremental skip is required behavior (scanner_test:
    # "an unchanged file is not re-hashed"; it is what keeps a 2TB archive from being re-read
    # every pass). So a fixture that "edits" a file while holding mtime AND size fixed is not
    # an edit at all — it is a file the scan is entitled to skip. Real edits bump mtime; these
    # must too, or they test the skip instead of the thing they name.
    def obs(rel, bytes, dir: false, mtime: T0)
      Library::Scanner::Observation.new(
        rel_path: rel, size: bytes.bytesize, mtime:, dir:
      )
    end

    def dir_obs(rel)
      Library::Scanner::Observation.new(rel_path: rel, size: nil, mtime: T0, dir: true)
    end

    # The reconciler hashes on demand via an injected reader, so these tests need no filesystem.
    #
    # `max_delete_pct: 100` disables the mass-deletion guard, deliberately and out loud: these
    # are MATCHING-ALGORITHM tests, and their fixtures are two or three files, where deleting one
    # is 33-100% and would trip a threshold written for a NAS archive. The guard has its own
    # tests (below, and ScannerGuardTest) which construct the Reconciler directly and get the
    # real default. If you are reading this because a guard test went green through this helper,
    # it is not testing the guard.
    def reconcile(observations, contents)
      Library::Reconciler.new(@user, observations:, unreadable_dirs: [], max_delete_pct: 100,
                                     reader: ->(rel) { contents.fetch(rel) }).call
    end

    test "a new file becomes a node" do
      reconcile([ obs("a.stl", "aaa") ], { "a.stl" => "aaa" })
      node = @user.nodes.find_by!(storage_path: "a.stl")
      assert_equal Digest::SHA256.hexdigest("aaa"), node.content_hash
      assert_equal 3, node.size
    end

    test "a RENAME keeps the node_id — the attachment survives" do
      reconcile([ obs("old.stl", "same bytes") ], { "old.stl" => "same bytes" })
      id = @user.nodes.find_by!(storage_path: "old.stl").node_id

      reconcile([ obs("new.stl", "same bytes") ], { "new.stl" => "same bytes" })

      node = @user.nodes.find_by!(storage_path: "new.stl")
      assert_equal id, node.node_id, "a rename must keep node_id or every attachment breaks"
      assert_not node.deleted
      assert_nil @user.nodes.find_by(storage_path: "old.stl")
    end

    test "a MOVE to another directory keeps the node_id" do
      reconcile([ obs("a.stl", "payload") ], { "a.stl" => "payload" })
      id = @user.nodes.find_by!(storage_path: "a.stl").node_id

      reconcile([ obs("cad/a.stl", "payload") ], { "cad/a.stl" => "payload" })

      assert_equal id, @user.nodes.find_by!(storage_path: "cad/a.stl").node_id
    end

    test "an EDIT in place keeps the node_id and updates the hash" do
      reconcile([ obs("e.stl", "v1") ], { "e.stl" => "v1" })
      id = @user.nodes.find_by!(storage_path: "e.stl").node_id

      reconcile([ obs("e.stl", "v2", mtime: T0 + 1) ], { "e.stl" => "v2" })

      node = @user.nodes.find_by!(storage_path: "e.stl")
      assert_equal id, node.node_id
      assert_equal Digest::SHA256.hexdigest("v2"), node.content_hash
    end

    # The flip side of the incremental skip, stated as a decision rather than left implicit:
    # bytes that change while size AND mtime both stay put are invisible to a stat-based scan.
    # Every stat-based sync (rsync's default, Dropbox, Time Machine) makes this same trade —
    # the alternative is re-reading the whole library on every pass. Pinned so that a future
    # "fix" to the skip has to argue with this test rather than quietly cost a 2TB re-read.
    test "an edit that changes neither size nor mtime is deliberately not detected" do
      reconcile([ obs("s.stl", "v1") ], { "s.stl" => "v1" })

      reconcile([ obs("s.stl", "v2") ], { "s.stl" => "v2" }) # same size, same mtime

      assert_equal Digest::SHA256.hexdigest("v1"),
                   @user.nodes.find_by!(storage_path: "s.stl").content_hash,
                   "stat said nothing changed, so the file is not re-read — by design"
    end

    test "a DELETE tombstones the node rather than destroying it" do
      reconcile([ obs("d.stl", "bye") ], { "d.stl" => "bye" })
      id = @user.nodes.find_by!(storage_path: "d.stl").node_id

      reconcile([], {})

      node = @user.nodes.find_by!(node_id: id)
      assert node.deleted, "row is kept so a project shows 'file missing', not a vanished attachment"
    end

    test "a move AND edit at once degrades to delete+create — documented, not silent" do
      reconcile([ obs("x.stl", "before") ], { "x.stl" => "before" })
      id = @user.nodes.find_by!(storage_path: "x.stl").node_id

      reconcile([ obs("moved/x.stl", "after") ], { "moved/x.stl" => "after" })

      assert @user.nodes.find_by!(node_id: id).deleted
      assert_not_equal id, @user.nodes.find_by!(storage_path: "moved/x.stl").node_id
    end

    test "ambiguous identical files tie-break deterministically, never crash" do
      reconcile([ obs("dup/a.stl", "same"), obs("dup/b.stl", "same") ],
                { "dup/a.stl" => "same", "dup/b.stl" => "same" })
      assert_equal 2, @user.nodes.present.where(kind: "file").count

      # Both vanish, both reappear elsewhere: pairing is non-unique. Any deterministic answer
      # is acceptable; a crash or a lost file is not.
      reconcile([ obs("moved/a.stl", "same"), obs("moved/b.stl", "same") ],
                { "moved/a.stl" => "same", "moved/b.stl" => "same" })
      assert_equal 2, @user.nodes.present.where(kind: "file").count
    end

    # --- the tombstone revive (carried in from Task 3's partial unique index) ---------------

    # The partial unique index is (user_id, storage_path) WHERE deleted = false, so a tombstoned
    # node is invisible to the live path lookup. Without an explicit revive, a file restored at
    # that path falls through to create! with a NEW node_id and SUCCEEDS — silently orphaning
    # every attachment the old node carried. Before the index this raised RecordNotUnique and
    # killed the scan; the index is what made the data loss quiet.
    test "a file restored at a tombstoned path REVIVES the node, not a new one alongside it" do
      reconcile([ obs("r.stl", "content") ], { "r.stl" => "content" })
      id = @user.nodes.find_by!(storage_path: "r.stl").node_id

      reconcile([], {})
      assert @user.nodes.find_by!(node_id: id).deleted, "precondition: it was tombstoned"

      reconcile([ obs("r.stl", "content") ], { "r.stl" => "content" })

      node = @user.nodes.find_by!(storage_path: "r.stl")
      assert_equal id, node.node_id, "a restored file must reclaim its node_id"
      assert_not node.deleted
      assert_equal 1, @user.nodes.where(storage_path: "r.stl").count, "no orphaned row alongside"
    end

    # Ordering: move-pairing must WIN over the tombstone revive. b.stl is renamed onto a path
    # where a DIFFERENT file was tombstoned by an earlier pass. If revive ran first it would
    # reclaim a.stl's dead node for b.stl's bytes and then tombstone b.stl's live node —
    # discarding the one node_id that actually had somewhere to go, and resurrecting a node
    # whose attachments describe a file the user deleted.
    test "a move ONTO a tombstoned path pairs the move rather than reviving the tombstone" do
      reconcile([ obs("a.stl", "aaa"), obs("b.stl", "bbbb") ],
                { "a.stl" => "aaa", "b.stl" => "bbbb" })
      a_id = @user.nodes.find_by!(storage_path: "a.stl").node_id
      b_id = @user.nodes.find_by!(storage_path: "b.stl").node_id

      reconcile([ obs("b.stl", "bbbb") ], { "b.stl" => "bbbb" }) # a.stl deleted -> tombstoned
      assert @user.nodes.find_by!(node_id: a_id).deleted, "precondition: a.stl is a tombstone"

      reconcile([ obs("a.stl", "bbbb") ], { "a.stl" => "bbbb" }) # b.stl renamed onto a.stl

      # `.present` is load-bearing: the tombstone still carries storage_path "a.stl", and the
      # unique index is PARTIAL (deleted = false), so two rows legitimately share the path. An
      # unscoped find_by! returns whichever comes first.
      node = @user.nodes.present.find_by!(storage_path: "a.stl")
      assert_equal b_id, node.node_id, "the MOVE owns the path; the tombstone must not reclaim it"
      assert @user.nodes.find_by!(node_id: a_id).deleted, "the deleted file stays deleted"
    end

    # --- directories ------------------------------------------------------------------------

    test "directory nodes are synthesized and parent the tree" do
      reconcile([ dir_obs("cad"), dir_obs("cad/brackets"), obs("cad/brackets/b.stl", "x") ],
                { "cad/brackets/b.stl" => "x" })

      cad = @user.nodes.find_by!(storage_path: "cad")
      brackets = @user.nodes.find_by!(storage_path: "cad/brackets")
      file = @user.nodes.find_by!(storage_path: "cad/brackets/b.stl")
      assert_nil cad.parent_node_id
      assert_equal cad.node_id, brackets.parent_node_id
      assert_equal brackets.node_id, file.parent_node_id
    end

    # Without this, deleting `cad/` tombstones its files but leaves `cad` live forever: an empty
    # ghost folder in every browse view.
    test "a vanished directory is tombstoned too" do
      reconcile([ dir_obs("cad"), obs("cad/a.stl", "x") ], { "cad/a.stl" => "x" })
      cad_id = @user.nodes.find_by!(storage_path: "cad").node_id

      reconcile([], {})

      assert @user.nodes.find_by!(node_id: cad_id).deleted
    end

    # A path whose KIND changes cannot reuse the row: an attachment pointing at a file must not
    # silently start pointing at a directory. Both directions break cleanly instead.
    test "a path that changes kind breaks cleanly rather than mutating the node" do
      reconcile([ obs("thing", "was a file") ], { "thing" => "was a file" })
      file_id = @user.nodes.find_by!(storage_path: "thing").node_id

      reconcile([ dir_obs("thing"), obs("thing/inner.stl", "y") ], { "thing/inner.stl" => "y" })

      assert @user.nodes.find_by!(node_id: file_id).deleted, "the old FILE node is tombstoned"
      dir = @user.nodes.present.find_by!(storage_path: "thing")
      assert_equal "dir", dir.kind
      assert_not_equal file_id, dir.node_id

      # ...and back again.
      reconcile([ obs("thing", "a file once more") ], { "thing" => "a file once more" })
      assert @user.nodes.find_by!(node_id: dir.node_id).deleted, "the DIR node is tombstoned"
      assert_equal "file", @user.nodes.present.find_by!(storage_path: "thing").kind
    end

    # --- unreadable bytes are not absent bytes ----------------------------------------------

    # The one case where "I cannot read it" must never render as "it is not there". Faulted at
    # the transport (the hash read itself), not at the classification this is testing.
    test "a file whose bytes cannot be read is skipped, never tombstoned" do
      reconcile([ obs("locked.stl", "v1") ], { "locked.stl" => "v1" })
      id = @user.nodes.find_by!(storage_path: "locked.stl").node_id

      # Changed (so it needs a rehash) but unreadable.
      changed = Library::Scanner::Observation.new(
        rel_path: "locked.stl", size: 99, mtime: 1_800_000_000_000_000_000, dir: false
      )
      Library::Reconciler.new(
        @user, observations: [ changed ], unreadable_dirs: [], reader: ->(_) { raise Errno::EACCES, "simulated" }
      ).call

      node = @user.nodes.find_by!(node_id: id)
      assert_not node.deleted, "a permission error is not a deletion"
      assert_equal Digest::SHA256.hexdigest("v1"), node.content_hash, "the last known hash stands"
    end

    test "an unreadable NEW file is left for the next pass, not indexed half-formed" do
      Library::Reconciler.new(
        @user, observations: [ obs("new.stl", "x") ], unreadable_dirs: [], reader: ->(_) { raise Errno::EACCES, "x" }
      ).call

      # A node with a nil content_hash is a preview that can never be keyed, and would be
      # indistinguishable from a real file to everything downstream.
      assert_nil @user.nodes.find_by(storage_path: "new.stl")
    end

    # --- the incremental skip, pinned where it cannot rot -----------------------------------

    # scanner_test has a version of this that counts Digest::SHA256.file calls — which pins the
    # HASHING METHOD, not the behavior: swap the implementation to File.binread and it passes
    # while testing nothing. Counting the injected reader instead is implementation-independent
    # (any way of getting at the bytes must go through it) and lives beside the algorithm it
    # guards. Green-while-the-coverage-evaporates is this plan's signature failure; this is the
    # durable half of that guard.
    test "an unchanged file's bytes are never read at all" do
      reconcile([ obs("big.stl", "unchanged") ], { "big.stl" => "unchanged" })

      calls = 0
      counting = ->(rel) { calls += 1; { "big.stl" => "unchanged" }.fetch(rel) }
      Library::Reconciler.new(@user, observations: [ obs("big.stl", "unchanged") ],
                                     unreadable_dirs: [], reader: counting).call

      assert_equal 0, calls, "unchanged (path, mtime, size) must be skipped without reading bytes"
    end

    # --- vanished_paths: the seam Task 7's mass-deletion guard reads ------------------------

    # The guard must ask "how many files would this tombstone?" BEFORE anything is tombstoned,
    # and it must get the same answer #call acts on. One definition or the guard eventually
    # guards a different number than the one that gets acted on.
    test "vanished_paths reports what a scan would tombstone, and writes NOTHING" do
      reconcile([ obs("keep.stl", "k"), obs("gone.stl", "g"), obs("also.stl", "a") ],
                { "keep.stl" => "k", "gone.stl" => "g", "also.stl" => "a" })

      rec = Library::Reconciler.new(@user, observations: [ obs("keep.stl", "k") ],
                                           unreadable_dirs: [], reader: ->(_) { "k" })

      assert_equal [ "also.stl", "gone.stl" ], rec.vanished_paths
      # Purity is the whole contract: the guard runs this to DECIDE whether to reconcile, so it
      # must not have reconciled already.
      assert_equal 3, @user.nodes.present.where(kind: "file").count, "vanished_paths must not write"
      assert @user.nodes.where(storage_path: "gone.stl").none?(&:deleted)
    end

    # A rename is not a deletion. The guard reads an upper bound — the set BEFORE move-pairing
    # rescues renames — so a reorganization can legitimately show up here. Stated so Task 7
    # chooses its threshold knowing that, rather than discovering it against a real NAS.
    test "vanished_paths is an upper bound: a pure rename appears, then is rescued by pairing" do
      reconcile([ obs("old.stl", "same") ], { "old.stl" => "same" })

      rec = Library::Reconciler.new(@user, observations: [ obs("new.stl", "same") ],
                                           unreadable_dirs: [], reader: ->(_) { "same" })
      assert_equal [ "old.stl" ], rec.vanished_paths, "the old path IS missing from disk"

      rec.call
      assert_equal 1, @user.nodes.present.where(kind: "file").count
      assert_not @user.nodes.present.find_by!(storage_path: "new.stl").deleted,
                 "...but pairing rescued it, so nothing was actually tombstoned"
    end

    # --- unobserved is not absent (the seam the guard and #call SHARE) ----------------------

    # An unreadable directory's subtree is missing from the observations through no fault of the
    # filesystem's contents. Excluding it inside vanished_paths — rather than in the guard —
    # means #call cannot tombstone it EITHER. That is the correctness fix; the guard reading a
    # smaller number is a consequence. Two definitions would let the guard approve a pass that
    # then deletes files the guard never counted.
    test "vanished_paths excludes live nodes under an unreadable directory" do
      reconcile([ obs("secret/a.stl", "a"), obs("open/b.stl", "b") ],
                { "secret/a.stl" => "a", "open/b.stl" => "b" })

      rec = Library::Reconciler.new(@user, observations: [ obs("open/b.stl", "b") ],
                                           unreadable_dirs: [ "secret" ], reader: ->(_) { "b" })
      assert_empty rec.vanished_paths, "we could not list secret/ — that is not evidence of absence"

      rec.call
      assert_not @user.nodes.present.find_by!(storage_path: "secret/a.stl").deleted
    end

    # A sibling whose name merely starts with an unreadable directory's name is a different
    # directory. Prefix-matching on the bare string would silently spare (and, in the guard's
    # denominator, discount) files that really are gone.
    test "the unreadable-subtree exclusion matches a path boundary, not a string prefix" do
      reconcile([ obs("secrets/x.stl", "x") ], { "secrets/x.stl" => "x" })

      rec = Library::Reconciler.new(@user, observations: [], unreadable_dirs: [ "secret" ],
                                           reader: ->(_) { "x" })
      assert_equal [ "secrets/x.stl" ], rec.vanished_paths, "'secrets' is not inside 'secret'"
    end

    # An unreadable ROOT is reported as "."; nothing at all was observed, so nothing at all can
    # be called absent. Without this the emptiest possible observation — the mass-tombstone input
    # — would sail past a guard whose denominator it had just zeroed.
    test "an unreadable ROOT makes the whole library unobserved, not vanished" do
      reconcile([ obs("a.stl", "a") ], { "a.stl" => "a" })

      rec = Library::Reconciler.new(@user, observations: [], unreadable_dirs: [ "." ],
                                           reader: ->(_) { "a" })
      assert_empty rec.vanished_paths
      rec.call
      assert_not @user.nodes.present.find_by!(storage_path: "a.stl").deleted
    end

    # --- the guard fires on the POST-pairing set --------------------------------------------

    # vanished_paths is an upper bound that includes renames (pinned above). The guard must not
    # read it directly: here EVERY file moved, so the upper bound is 100% while the true
    # tombstone count is 0. A guard reading the upper bound refuses a scan that deletes nothing.
    test "a reorganization of the entire library does not trip the guard" do
      3.times { |i| reconcile([ obs("f#{i}.stl", "b#{i}") ], { "f#{i}.stl" => "b#{i}" }) }
      files = 3.times.map { |i| [ obs("f#{i}.stl", "b#{i}"), "b#{i}" ] }
      reconcile(files.map(&:first), files.to_h { |o, b| [ o.rel_path, b ] })

      moved = 3.times.map { |i| obs("new/f#{i}.stl", "b#{i}") }
      rec = Library::Reconciler.new(@user, observations: moved, unreadable_dirs: [],
                                           reader: ->(rel) { "b#{rel[/\d/]}" })
      assert_equal 3, rec.vanished_paths.size, "the upper bound says 100% vanished..."

      rec.call # ...and the guard must not believe it
      assert_equal 3, @user.nodes.present.where(kind: "file").count
      assert_equal 0, @user.nodes.where(kind: "file", deleted: true).count
    end

    # The guard runs after pairing but BEFORE any tombstone is written, so a refused pass leaves
    # the move it had already decided on unapplied too. All-or-nothing is the honest contract for
    # a pass we are refusing on the grounds that we do not trust its input.
    test "a refused pass writes no tombstone AND no move" do
      5.times { |i| reconcile([ obs("p#{i}.stl", "c#{i}") ], { "p#{i}.stl" => "c#{i}" }) }
      all = 5.times.map { |i| obs("p#{i}.stl", "c#{i}") }
      reconcile(all, 5.times.to_h { |i| [ "p#{i}.stl", "c#{i}" ] })

      # p0 moves; p1..p4 are simply gone -> 4/5 = 80% > 20%.
      rec = Library::Reconciler.new(@user, observations: [ obs("kept/p0.stl", "c0") ],
                                           unreadable_dirs: [], reader: ->(_) { "c0" })
      assert_raises(Library::Scanner::UnsafeScan) { rec.call }

      assert_equal 5, @user.nodes.present.where(kind: "file").count
      assert_nil @user.nodes.find_by(storage_path: "kept/p0.stl"),
                 "the move is decided before the guard, so it must be withheld when the guard fires"
      assert_not @user.nodes.present.find_by!(storage_path: "p0.stl").deleted
    end

    # --- the seam this depends on -----------------------------------------------------------

    # ensure_dirs synthesizes parents by looking them up as it goes, so the Scanner emitting a
    # parent before its children is load-bearing here, not a coincidence of its walk. It is
    # structurally guaranteed (a directory is observed before it is pushed onto the worklist)
    # but nothing else pins it — a future refactor to a different traversal could silently
    # detach every child from its parent. The Reconciler sorts defensively as well; this asserts
    # the property the sort is insurance FOR.
    test "the Scanner emits parent directories before their children" do
      root = Pathname.new(Dir.mktmpdir("rec-order"))
      FileUtils.mkdir_p(root.join("a/b/c"))
      File.binwrite(root.join("a/b/c/leaf.stl"), "L")

      paths = Library::Scanner.new(nil, root: root.to_s).observe.map(&:rel_path)
      paths.each do |rel|
        parent = File.dirname(rel)
        next if parent == "."
        assert paths.index(parent) < paths.index(rel),
               "#{parent.inspect} must be observed before #{rel.inspect}"
      end
    ensure
      FileUtils.remove_entry(root) if root&.exist?
    end

    test "a root: or a reader: is required — the root is never guessed from a global" do
      # FileLayer.current is the DEPLOYMENT's backend (Chunk by default, which has no root at
      # all). Reaching for it to resolve an observation would be a NoMethodError in every run
      # that is not a share deployment.
      #
      # `unreadable_dirs: []` is passed even though this test is not about it: it is a REQUIRED
      # kwarg, so omitting it raises ArgumentError for missing-keyword and this assertion would
      # pass without the root/reader check existing at all.
      err = assert_raises(ArgumentError) do
        Library::Reconciler.new(@user, observations: [], unreadable_dirs: [])
      end
      assert_match(/a root: or a reader: is required/, err.message,
                   "must fail on the root/reader check, not on a missing keyword")
    end

    # ...and the converse: unreadable_dirs is required, so a caller cannot silently inherit the
    # data loss it prevents (every file under a directory we could not list, tombstoned). A
    # default of [] would make forgetting it indistinguishable from claiming the walk was
    # complete.
    test "unreadable_dirs is REQUIRED — 'the walk was complete' must be said out loud" do
      err = assert_raises(ArgumentError) do
        Library::Reconciler.new(@user, observations: [], reader: ->(_) { "x" })
      end
      assert_match(/unreadable_dirs/, err.message)
    end

    # --- an observation that already KNOWS its identity ---------------------------------------

    # LANDMINE 1. An observer that already KNOWS the identity (S3 gets it free in the
    # listing) must be able to say so. Without this the Reconciler lazily hashes, which for
    # S3 means downloading the object -- a full egress of the bucket on first scan, and
    # Digest::SHA256.hexdigest(reader.call(...)) loads the whole thing into memory besides.
    test "an observation may supply its own content_hash, and the reader is never called" do
      called = false
      obs = [ Library::Observation.new(rel_path: "a.stl", size: 3, mtime: T0, dir: false,
                                       content_hash: "md5:supplied") ]
      Library::Reconciler.new(@user, observations: obs, unreadable_dirs: [],
                              reader: ->(_) { called = true; "aaa" }).call

      node = @user.nodes.find_by!(storage_path: "a.stl")
      assert_equal "md5:supplied", node.content_hash, "the supplied identity must be stored verbatim"
      assert_not called, "a supplied hash must never be recomputed -- for S3 that is an egress bill"
    end

    test "a supplied hash pairs a move exactly as a computed one does" do
      obs1 = [ Library::Observation.new(rel_path: "old.stl", size: 4, mtime: T0, dir: false,
                                        content_hash: "md5:same") ]
      Library::Reconciler.new(@user, observations: obs1, unreadable_dirs: [], reader: ->(_) { "xxxx" }).call
      id = @user.nodes.find_by!(storage_path: "old.stl").node_id

      obs2 = [ Library::Observation.new(rel_path: "new/moved.stl", size: 4, mtime: T0, dir: false,
                                        content_hash: "md5:same") ]
      Library::Reconciler.new(@user, observations: obs2, unreadable_dirs: [], reader: ->(_) { "xxxx" },
                             max_delete_pct: 100).call

      assert_equal id, @user.nodes.find_by!(storage_path: "new/moved.stl").node_id,
                   "move-pairing must not care WHERE the identity came from"
    end

    # The incremental skip compares (mtime, size). S3's last_modified is SECOND-granularity
    # (verified), so that pair is coarser there than a share's nanoseconds. When the observer
    # supplies an identity, comparing it directly is free, exact, and closes the window.
    test "a supplied hash that CHANGED is applied even when mtime and size did not" do
      obs = ->(hash) { [ Library::Observation.new(rel_path: "e.stl", size: 3, mtime: T0,
                                                  dir: false, content_hash: hash) ] }
      Library::Reconciler.new(@user, observations: obs.call("md5:v1"), unreadable_dirs: [],
                              reader: ->(_) { "aaa" }).call
      id = @user.nodes.find_by!(storage_path: "e.stl").node_id

      Library::Reconciler.new(@user, observations: obs.call("md5:v2"), unreadable_dirs: [],
                              reader: ->(_) { "bbb" }).call

      node = @user.nodes.find_by!(storage_path: "e.stl")
      assert_equal id, node.node_id, "an edit in place is not a new file"
      assert_equal "md5:v2", node.content_hash,
                   "an identical (mtime, size) must not mask a changed identity"
    end

    # The share path is UNCHANGED: no supplied hash means hash lazily, skip on (mtime, size).
    # This is the regression guard for the whole 2a design, which this task edits underneath.
    test "with no supplied hash the lazy path is untouched: unchanged means not hashed" do
      calls = 0
      reader = ->(_) { calls += 1; "aaa" }
      obs = [ Library::Observation.new(rel_path: "b.stl", size: 3, mtime: T0, dir: false) ]

      Library::Reconciler.new(@user, observations: obs, unreadable_dirs: [], reader:).call
      assert_equal 1, calls, "a new file is hashed once"

      Library::Reconciler.new(@user, observations: obs, unreadable_dirs: [], reader:).call
      assert_equal 1, calls, "unchanged (path, mtime, size) must still be skipped without hashing"
    end

    # A supplied identity that is UNCHANGED must still skip: the no-op scan is the pass that
    # runs every 15 minutes forever, and it is the one that must cost a single pluck. This is
    # the identity-carrying twin of the lazy skip above.
    test "a supplied hash that did NOT change skips: a no-op scan writes nothing" do
      obs = [ Library::Observation.new(rel_path: "c.stl", size: 3, mtime: T0, dir: false,
                                       content_hash: "md5:same") ]
      Library::Reconciler.new(@user, observations: obs, unreadable_dirs: [], reader: ->(_) { "aaa" }).call
      node = @user.nodes.find_by!(storage_path: "c.stl")
      before = node.updated_at

      travel 1.second do
        Library::Reconciler.new(@user, observations: obs, unreadable_dirs: [], reader: ->(_) { "aaa" }).call
      end
      assert_equal before, node.reload.updated_at, "an unchanged identity must not rewrite the row"
    end

    # The Scanner's four-argument call sites must keep working, and a nil content_hash must be
    # the same value as an absent one -- `==` is what group_by and the pairing buckets key on.
    test "content_hash defaults to nil, and a four-arg Observation equals the explicit-nil one" do
      four = Library::Observation.new("x.stl", 3, T0, false)
      assert_nil four.content_hash
      assert_equal four, Library::Observation.new(rel_path: "x.stl", size: 3, mtime: T0,
                                                  dir: false, content_hash: nil)
      assert_equal "md5:h", four.with(content_hash: "md5:h").content_hash,
                   "#with must survive the default -- the S3 observer builds on it"
      assert_same Library::Observation, Library::Scanner::Observation,
                  "the Scanner's constant must still resolve to the one class"
    end
  end
end
