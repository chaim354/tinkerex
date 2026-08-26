require "test_helper"

module Library
  # Two layers of tests, deliberately:
  #
  # ObserveTest covers what the Scanner itself does — walk a real directory and report what it
  # saw. It needs a tmpdir and nothing else, so it is GREEN now and pins this task's behavior.
  #
  # ScannerTest covers the scan end to end, through the Reconciler into `nodes`. It is RED until
  # Task 6 lands the Reconciler, by design and not stubbed. Without ObserveTest, this file would
  # assert nothing at all about the code this task adds.
  class ScannerObserveTest < ActiveSupport::TestCase
    setup { @root = Pathname.new(Dir.mktmpdir("scan-observe")) }
    teardown { FileUtils.remove_entry(@root) if @root&.exist? }

    def write!(rel, bytes)
      p = @root.join(rel)
      FileUtils.mkdir_p(p.dirname)
      File.binwrite(p, bytes)
      p
    end

    # No user needed: observation is a filesystem concern, not a database one.
    def observe = Library::Scanner.new(nil, root: @root.to_s).observe
    def by_path = observe.index_by(&:rel_path)

    test "reports a file's size and its mtime in NANOSECONDS" do
      write!("a.stl", "hello")
      obs = by_path.fetch("a.stl")

      assert_equal 5, obs.size
      assert_not obs.dir
      # nodes.mtime is a bigint of unix nanos. A seconds value is ~1.7e9; nanos are ~1.7e18.
      # Passing seconds through has shipped as a real bug twice in the mount adapters.
      assert obs.mtime > 1_000_000_000_000_000, "mtime must be nanos, got #{obs.mtime}"
      # Pin the conversion exactly, not just the magnitude: a *1_000 bug still clears the
      # threshold above, and truncating to whole seconds would silently defeat the incremental
      # (path, mtime, size) skip on sub-second edits.
      st = @root.join("a.stl").lstat
      assert_equal st.mtime.to_i * 1_000_000_000 + st.mtime.nsec, obs.mtime
    end

    test "reports directories, with nil size and a relative path" do
      write!("cad/brackets/b.stl", "x")
      found = by_path

      assert found["cad"].dir
      assert found["cad/brackets"].dir
      assert_nil found["cad"].size, "a directory's st_size is an allocation detail, not bytes"
      assert_not found["cad/brackets/b.stl"].dir
      # Paths are relative to the root and never absolute: nodes.storage_path is joined back
      # onto the root by Share#absolute_path, and an absolute value would escape it.
      assert found.keys.none? { |k| k.start_with?("/") }, found.keys.inspect
    end

    test "excludes the trash prefix and never descends into it" do
      write!(".trash/n1/old.stl", "deleted")
      write!("keep.stl", "kept")
      # Indexing .trash would resurrect deleted files as new ones on the next scan — the same
      # bug class as the pull_snapshot ghosts fixed on 2026-07-14.
      assert_equal [ "keep.stl" ], observe.map(&:rel_path).sort
    end

    # Share#write writes to a temp name and renames atomically into place. A scan landing inside
    # that window must not index the temp — unlike the trash, at ANY depth, because a write into
    # cad/ puts its temp in cad/.
    test "Share#write's in-flight temp file is never indexed, at any depth" do
      write!("#{Library::Scanner::TEMP_PREFIX}abc123", "torn, half-written bytes")
      write!("cad/#{Library::Scanner::TEMP_PREFIX}def456", "torn too")
      write!("cad/real.stl", "a real file")
      paths = observe.map(&:rel_path)

      assert_equal [ "cad", "cad/real.stl" ], paths.sort, "only real entries may be observed"
      assert paths.none? { |p| p.include?(Library::Scanner::TEMP_PREFIX) }
    end

    test "the trash exclusion is root-anchored: a user's own nested .trash is indexed" do
      write!(".trash/old.stl", "deleted")
      write!("cad/.trash/mine.stl", "the user's own folder, not ours")
      paths = observe.map(&:rel_path)

      # Task 2b puts OUR trash at <root>/.trash/<node_id>/<name> — root-anchored. Pruning
      # ".trash" at any depth would silently swallow a user's own folder that happens to share
      # the name, so the anchoring is a decision, not an oversight.
      assert_includes paths, "cad/.trash/mine.stl"
      assert_not_includes paths, ".trash/old.stl"
    end

    # OS-generated clutter is never observed, so it never becomes a node. This is the observer
    # half of the ignore-list; the write-guard half (that nothing may WRITE to these paths, or a
    # ghost wedges the scan) is pinned in the write contract. The predicate is Library::OsClutter,
    # shared verbatim with the S3 observer and both adapters' observable! guards.
    test "OS clutter is never indexed — .DS_Store, ._*, __MACOSX subtree, volume metadata" do
      write!(".DS_Store", "junk")
      write!("cad/.DS_Store", "junk at depth")
      write!("._resource", "an AppleDouble fork")
      write!("cad/._bracket.stl", "an AppleDouble fork at depth")
      write!("__MACOSX/junk.txt", "from a zip extraction")
      write!("__MACOSX/nested/more.txt", "the __MACOSX subtree nests")
      write!(".Spotlight-V100/store.db", "macOS volume metadata")
      write!("cad/bracket.stl", "a real file")
      write!("top.stl", "another real file")
      paths = observe.map(&:rel_path).sort

      assert_equal [ "cad", "cad/bracket.stl", "top.stl" ], paths
      assert paths.none? { |p| p.include?("__MACOSX") },
             "a __MACOSX directory contributes ZERO nodes — the subtree is skipped, not descended"
      assert paths.none? { |p| p.include?(".Spotlight-V100") }
    end

    # THE ONE SKIP THAT KEEPS ITS ENTRY, and the reason it is not a fifth skip-list wedge: an
    # OBSERVED node pairs normally, so nothing here manufactures a ghost. The marker dir is what
    # makes a working tree detectable (Maker::AttachToProject's :in_working_tree); what is declined
    # is the DESCENT. Library::RepoMetadata carries the argument.
    test ".git is observed as ONE dir entry and never descended into" do
      write!("firmware/.git/objects/ab/cdef", "a loose object")
      write!("firmware/.git/config", "[core]")
      write!("firmware/main.cpp", "int main(){}")
      found = by_path
      paths = found.keys

      assert_includes paths, "firmware/.git", "the MARKER must be observed — it is what makes " \
                                              "a working tree detectable"
      assert found.fetch("firmware/.git").dir, "the marker is a DIRECTORY node, never a file"
      assert_includes paths, "firmware/main.cpp"
      assert_empty paths.select { |p| p.start_with?("firmware/.git/") },
                   "nothing beneath .git may be observed"
    end

    # THE MARKER IS A DIRECTORY, NEVER A FILE, and this is the share half of a cross-backend pair
    # (Library::S3ObserverTest holds the other). A submodule or a linked worktree writes a
    # `gitdir:` POINTER FILE where a plain repo has a directory; nothing here reads that pointer,
    # so it is an ordinary file and its bytes are the point. Structurally this is why the skip
    # lives inside the `stat.directory?` arm — hoisting it would silently stop indexing this file.
    test "a .git FILE — a submodule's gitdir pointer — is indexed as an ordinary file" do
      write!("sub/.git", "gitdir: ../.git/modules/sub")
      write!("sub/main.c", "int main(){}")
      found = by_path

      assert_not found.fetch("sub/.git").dir, "a `gitdir:` pointer is a file, not the marker"
      assert_equal 27, found.fetch("sub/.git").size
      assert_includes found.keys, "sub/main.c"
    end

    # Whole segments, never prefixes. A repo's own tracked dotfiles are ordinary library files.
    test "a file merely named .gitignore is indexed normally" do
      write!(".gitignore", "tmp/")

      assert_includes observe.map(&:rel_path), ".gitignore"
    end

    test "does not index or follow symlinks" do
      write!("real/inside.stl", "y")
      File.symlink(@root.join("real").to_s, @root.join("link").to_s)
      File.symlink(@root.join("real/inside.stl").to_s, @root.join("f.stl").to_s)
      paths = observe.map(&:rel_path)

      assert_not_includes paths, "link"
      assert_not_includes paths, "f.stl"
      # Following a symlinked dir would index the same bytes twice under two paths, and a link
      # pointing OUT of the root would index files the user never put in their library.
      assert_not_includes paths, "link/inside.stl"
      assert_includes paths, "real/inside.stl"
    end

    test "a symlink loop terminates instead of hanging the scan" do
      FileUtils.mkdir_p(@root.join("d"))
      File.symlink(@root.to_s, @root.join("d/loop").to_s)

      paths = Timeout.timeout(10) { observe.map(&:rel_path) }
      assert_equal [ "d" ], paths
    end

    test "does not index special files" do
      write!("ok.stl", "z")
      system("mkfifo", @root.join("pipe").to_s, exception: true)
      # A FIFO has no bytes to serve and blocks forever on open. Consistent with the special-file
      # EPERM guardrail in the sync path.
      assert_equal [ "ok.stl" ], observe.map(&:rel_path)
    end

    test "an unreadable directory is reported as unreadable, NOT as empty" do
      write!("secret/hidden.stl", "s")
      write!("open/seen.stl", "o")
      scanner = Library::Scanner.new(nil, root: @root.to_s)
      File.chmod(0o000, @root.join("secret"))
      begin
        paths = scanner.observe.map(&:rel_path)
      ensure
        File.chmod(0o755, @root.join("secret"))
      end

      # The subtree is necessarily absent from the observations — we could not list it.
      assert_not_includes paths, "secret/hidden.stl"
      assert_includes paths, "open/seen.stl", "one bad directory must not abort the whole scan"
      # ...so the scan MUST say so out of band. This is the entire difference between "the user
      # deleted these files" and "we couldn't look". Pathname#find defaults to ignore_error:true
      # and would drop the subtree with no signal whatsoever — which is why this walk is
      # hand-rolled. Task 7's mass-deletion guard has to be able to consult this.
      assert_equal [ "secret" ], scanner.unreadable_dirs
    end

    # A real NAS holds names written by old Windows/classic-Mac clients that are not valid UTF-8.
    # They reach the Reconciler and raise ArgumentError ("invalid byte sequence") — which is NOT
    # a SystemCallError, so its rescue misses it — leaving the library half-indexed and killing
    # every later pass at the same entry.
    #
    # This stubs Dir.children rather than creating the file: macOS rejects such a name outright
    # (EILSEQ), so the fixture cannot exist on the dev box this ships from. That is exactly why
    # the bug survived to the final review.
    test "a filename that is not valid UTF-8 is skipped, not indexed and not fatal" do
      write!("good.stl", "fine")
      bad = "caf\xE9.stl".dup.force_encoding("UTF-8")
      assert_not bad.valid_encoding?, "precondition: the fixture name must be invalid UTF-8"

      scanner = Library::Scanner.new(nil, root: @root.to_s)
      original = Dir.method(:children)
      Dir.define_singleton_method(:children) { |*| [ "good.stl", bad ] }
      begin
        paths = scanner.observe.map(&:rel_path)
      ensure
        Dir.define_singleton_method(:children, original)
      end

      assert_equal [ "good.stl" ], paths, "the unencodable name must not reach the Reconciler"
      assert paths.all?(&:valid_encoding?)
      # Skipped, NOT recorded unreadable: the directory listed fine. Recording it would be a lie,
      # and would drag a healthy library toward the mass-deletion guard.
      assert_empty scanner.unreadable_dirs
    end

    test "an unreadable ROOT reports as unreadable rather than as an empty library" do
      scanner = Library::Scanner.new(nil, root: @root.to_s)
      File.chmod(0o000, @root)
      begin
        assert_empty scanner.observe
      ensure
        File.chmod(0o755, @root)
      end
      # An empty observation list from an unlistable root is the mass-tombstone input. It must
      # never be indistinguishable from a genuinely empty library.
      assert_equal [ "." ], scanner.unreadable_dirs
    end

    test "a readable file is observed even with no read permission on it" do
      p = write!("locked.stl", "secret")
      File.chmod(0o000, p)
      begin
        obs = by_path.fetch("locked.stl")
      ensure
        File.chmod(0o644, p)
      end
      # lstat needs permission on the PARENT directory, not on the file, so chmod 000 on a file
      # does not hide it from the walk. It is observed normally; the Reconciler is where its
      # unreadability surfaces (hashing it raises EACCES), and where it must be skipped rather
      # than tombstoned.
      assert_equal 6, obs.size
    end

    test "a healthy walk reports nothing unreadable" do
      write!("a/b/c.stl", "c")
      scanner = Library::Scanner.new(nil, root: @root.to_s)
      scanner.observe
      assert_empty scanner.unreadable_dirs
    end

    test "each walk reports only what THAT walk could not read" do
      write!("secret/hidden.stl", "s")
      scanner = Library::Scanner.new(nil, root: @root.to_s)
      File.chmod(0o000, @root.join("secret"))
      begin
        scanner.observe
      ensure
        File.chmod(0o755, @root.join("secret"))
      end
      assert_equal [ "secret" ], scanner.unreadable_dirs

      scanner.observe
      # Without the per-walk reset, a share that came back healthy would keep reporting the
      # directories that failed on an earlier pass — and Task 7's guard, reading a stale
      # "something was unreadable", would refuse to tombstone anything ever again.
      assert_empty scanner.unreadable_dirs
    end

    test "walks a nested tree to its leaves" do
      deep = (1..50).map { |i| "d#{i}" }.join("/")
      write!("#{deep}/leaf.stl", "L")
      assert_includes observe.map(&:rel_path), "#{deep}/leaf.stl"
    end
  end

  # End-to-end: the scan lands rows in `nodes`. RED until Task 6's Reconciler exists.
  class ScannerTest < ActiveSupport::TestCase
    setup do
      @root = Pathname.new(Dir.mktmpdir("scan-test"))
      @user = User.create!(email: "scan-#{SecureRandom.hex(4)}@example.com")
    end
    teardown { FileUtils.remove_entry(@root) if @root&.exist? }

    def write!(rel, bytes)
      p = @root.join(rel)
      FileUtils.mkdir_p(p.dirname)
      File.binwrite(p, bytes)
      p
    end

    test "indexes a new file with size, hash, and NANOSECOND mtime" do
      write!("a.stl", "hello")
      Library::Scanner.call(@user, root: @root.to_s)

      node = @user.nodes.find_by!(storage_path: "a.stl")
      assert_equal "a.stl", node.name
      assert_equal "file", node.kind
      assert_equal 5, node.size
      assert_equal Digest::SHA256.hexdigest("hello"), node.content_hash
      # mtime is unix NANOSECONDS end-to-end (nanos-as-seconds shipped as a real bug twice).
      # A seconds value would be ~1.7e9; nanos are ~1.7e18.
      assert node.mtime > 1_000_000_000_000_000, "mtime must be nanos, got #{node.mtime}"
    end

    test "synthesizes directory nodes so the tree still has parents" do
      write!("cad/brackets/b.stl", "x")
      Library::Scanner.call(@user, root: @root.to_s)

      file = @user.nodes.find_by!(storage_path: "cad/brackets/b.stl")
      brackets = @user.nodes.find_by!(storage_path: "cad/brackets")
      cad = @user.nodes.find_by!(storage_path: "cad")
      assert_equal "dir", cad.kind
      assert_equal "dir", brackets.kind
      assert_equal brackets.node_id, file.parent_node_id
      assert_equal cad.node_id, brackets.parent_node_id
      assert_nil cad.parent_node_id
    end

    test "is incremental: an unchanged file is not re-hashed" do
      write!("big.stl", "unchanged")
      Library::Scanner.call(@user, root: @root.to_s)
      before = @user.nodes.find_by!(storage_path: "big.stl")

      # If the scanner re-hashed unchanged files, a 2TB archive would be re-read every pass.
      calls = 0
      original = Digest::SHA256.method(:file)
      Digest::SHA256.define_singleton_method(:file) { |*a| calls += 1; original.call(*a) }
      begin
        Library::Scanner.call(@user, root: @root.to_s)
      ensure
        Digest::SHA256.define_singleton_method(:file, original)
      end

      assert_equal 0, calls, "unchanged (path, mtime, size) must be skipped without hashing"
      assert_equal before.content_hash, @user.nodes.find_by!(storage_path: "big.stl").content_hash
    end

    test "an edited file gets a new hash and keeps its node_id" do
      write!("e.stl", "v1")
      Library::Scanner.call(@user, root: @root.to_s)
      id = @user.nodes.find_by!(storage_path: "e.stl").node_id

      sleep 0.01
      write!("e.stl", "v2-longer")
      Library::Scanner.call(@user, root: @root.to_s)

      node = @user.nodes.find_by!(storage_path: "e.stl")
      assert_equal id, node.node_id, "an edit is not a new file"
      assert_equal Digest::SHA256.hexdigest("v2-longer"), node.content_hash
      assert_equal 9, node.size
    end

    test "excludes the trash prefix" do
      write!(".trash/n1/old.stl", "deleted")
      Library::Scanner.call(@user, root: @root.to_s)
      # Indexing .trash would resurrect deleted files as new ones on the next scan — the same
      # bug class as the pull_snapshot ghosts fixed on 2026-07-14.
      assert_nil @user.nodes.find_by(storage_path: ".trash/n1/old.stl")
      assert_equal 0, @user.nodes.where("storage_path LIKE '.trash%'").count
    end

    test "skips unreadable files rather than tombstoning them" do
      p = write!("locked.stl", "secret")
      Library::Scanner.call(@user, root: @root.to_s)
      id = @user.nodes.find_by!(storage_path: "locked.stl").node_id

      sleep 0.01
      File.write(p, "changed-so-it-needs-rehash")
      File.chmod(0o000, p)
      begin
        Library::Scanner.call(@user, root: @root.to_s)
      ensure
        File.chmod(0o644, p)
      end

      node = @user.nodes.find_by(node_id: id)
      assert node, "a permission error must never delete the node"
      assert_not node.deleted, "a permission error is not a deletion"
    end
  end

  # The mass-deletion guard, end to end through a real filesystem.
  #
  # The guard fires on what would ACTUALLY be tombstoned — the set left after move-pairing —
  # not on what merely changed path. Guarding the raw missing-path count would refuse every
  # large reorganization, which is the exact thing this phase exists to survive. The
  # "reorganization" tests below are what pin that distinction; they are not decoration.
  class ScannerGuardTest < ActiveSupport::TestCase
    setup do
      @root = Pathname.new(Dir.mktmpdir("scan-guard"))
      @user = User.create!(email: "guard-#{SecureRandom.hex(4)}@example.com")
    end
    teardown { FileUtils.remove_entry(@root) if @root&.exist? }

    def write!(rel, bytes)
      p = @root.join(rel)
      FileUtils.mkdir_p(p.dirname)
      File.binwrite(p, bytes)
      p
    end

    def scan! = Library::Scanner.call(@user, root: @root.to_s)
    def live_paths = @user.nodes.present.where(kind: "file").order(:storage_path).pluck(:storage_path)

    # --- the catastrophic cases the guard exists for -----------------------------------------

    test "an emptied root ABORTS rather than tombstoning the library" do
      write!("a.stl", "1"); write!("b.stl", "2"); write!("c.stl", "3")
      scan!
      assert_equal 3, @user.nodes.present.where(kind: "file").count

      # Simulate the NAS unmounting: the root exists but is empty.
      FileUtils.rm_f(Dir.glob(@root.join("*").to_s))
      assert_raises(Library::Scanner::UnsafeScan) { scan! }

      assert_equal 3, @user.nodes.present.where(kind: "file").count,
                   "an unmounted NAS must never read as the user deleting their library"
    end

    # A MISSING root is not caught by the percentage guard at all: Scanner#observe rescues the
    # root's ENOENT and returns [] with an EMPTY unreadable_dirs, so a missing root is
    # indistinguishable from an empty library BY OBSERVATION ALONE. The explicit directory?
    # check is therefore load-bearing, not belt-and-braces. (It happens to be redundant with the
    # 100%-vanished arithmetic while the library is non-empty — but not for a library of zero
    # live files, and not for the operator, who deserves "your root is gone" rather than a
    # percentage.)
    test "a MISSING root ABORTS — it is not an empty library" do
      write!("a.stl", "1")
      scan!
      FileUtils.remove_entry(@root)

      err = assert_raises(Library::Scanner::UnsafeScan) { scan! }
      assert_match(/missing/, err.message)
    end

    test "deleting more than the threshold ABORTS" do
      10.times { |i| write!("f#{i}.stl", "x#{i}") }
      scan!

      5.times { |i| FileUtils.rm_f(@root.join("f#{i}.stl").to_s) } # 50% > the 20% default
      assert_raises(Library::Scanner::UnsafeScan) { scan! }
      assert_equal 10, @user.nodes.present.where(kind: "file").count
    end

    test "a deletion under the threshold proceeds" do
      10.times { |i| write!("g#{i}.stl", "x#{i}") }
      scan!

      FileUtils.rm_f(@root.join("g0.stl").to_s) # 10% < 20%
      scan!
      assert_equal 9, @user.nodes.present.where(kind: "file").count
      assert @user.nodes.find_by!(storage_path: "g0.stl").deleted
    end

    # The threshold is INCLUSIVE (`pct <= max`), and nothing else pins that: the cases above
    # bracket the default at 10% and 50%, so flipping `<=` to `<` leaves them all green while
    # silently making the guard stricter than its own error message claims ("> 20%"). Exactly 20%
    # is the only input that can tell the two apart.
    test "a deletion of EXACTLY the threshold proceeds — the bound is inclusive" do
      10.times { |i| write!("b#{i}.stl", "z#{i}") }
      scan!

      2.times { |i| FileUtils.rm_f(@root.join("b#{i}.stl").to_s) } # 2/10 = exactly 20%
      scan!
      assert_equal 8, @user.nodes.present.where(kind: "file").count
    end

    # --- ...and the case a naive guard breaks ------------------------------------------------

    # THE test for this task's redesign. A guard that counts live nodes whose path is no longer
    # observed counts every rename as a deletion — so reorganizing more than the threshold in one
    # interval would refuse the scan forever. Reorganizing a NAS is the use case this whole phase
    # is built for; a guard that blocks it is worse than no guard.
    test "a large REORGANIZATION does not trip the guard — a move is not a deletion" do
      10.times { |i| write!("flat/h#{i}.stl", "payload-#{i}") }
      scan!
      ids = @user.nodes.present.where(kind: "file").to_h { |n| [ n.storage_path, n.node_id ] }
      assert_equal 10, ids.size

      # Move 6 of 10 (60% — three times the threshold) into a new tree, same bytes.
      FileUtils.mkdir_p(@root.join("cad/sorted"))
      6.times { |i| FileUtils.mv(@root.join("flat/h#{i}.stl").to_s, @root.join("cad/sorted/h#{i}.stl").to_s) }

      scan! # must NOT raise

      assert_equal 10, @user.nodes.present.where(kind: "file").count, "nothing was deleted"
      assert_equal 0, @user.nodes.where(kind: "file", deleted: true).count
      6.times do |i|
        assert_equal ids.fetch("flat/h#{i}.stl"),
                     @user.nodes.present.find_by!(storage_path: "cad/sorted/h#{i}.stl").node_id,
                     "the move must keep node_id — that is the attachment"
      end
    end

    # ...but the guard must not be blinded by the reorganization either: a mass deletion hiding
    # among a pile of moves still has to trip it.
    test "a reorganization WITH a genuine mass deletion still ABORTS" do
      10.times { |i| write!("k#{i}.stl", "body-#{i}") }
      scan!

      FileUtils.mkdir_p(@root.join("moved"))
      3.times { |i| FileUtils.mv(@root.join("k#{i}.stl").to_s, @root.join("moved/k#{i}.stl").to_s) }
      (3..7).each { |i| FileUtils.rm_f(@root.join("k#{i}.stl").to_s) } # 5/10 = 50% genuinely gone

      assert_raises(Library::Scanner::UnsafeScan) { scan! }
      assert_equal 10, @user.nodes.present.where(kind: "file").count,
                   "the whole pass is refused — moves included; a refused scan writes nothing destructive"
    end

    # --- "we could not look" is never "it is not there" --------------------------------------

    # Pathname#find SILENTLY swallows EACCES, dropping an unreadable directory's whole subtree
    # from the walk — which is why the walk is hand-rolled and reports #unreadable_dirs. Those
    # files look deleted and are not. Excluding them (rather than aborting) is deliberate: one
    # weird folder must not block every future scan of an otherwise healthy library.
    test "files under an unreadable directory are NOT tombstoned" do
      write!("secret/hidden.stl", "s")
      write!("secret/sub/deep.stl", "d")
      write!("open/seen.stl", "o")
      scan!
      assert_equal [ "open/seen.stl", "secret/hidden.stl", "secret/sub/deep.stl" ], live_paths

      File.chmod(0o000, @root.join("secret"))
      begin
        scan! # must NOT raise: 2 of 3 unobservable would be 66% if counted as deletions
      ensure
        File.chmod(0o755, @root.join("secret"))
      end

      assert_equal [ "open/seen.stl", "secret/hidden.stl", "secret/sub/deep.stl" ], live_paths,
                   "an unreadable subtree is UNOBSERVED, not absent"
      # The directory node too: `secret/sub` was never listed, so nothing observed it either.
      assert_not @user.nodes.present.find_by!(storage_path: "secret/sub").deleted,
                 "a directory inside an unreadable subtree is equally unobserved"
    end

    # The denominator is the OBSERVABLE library, not the whole one. Otherwise a large unreadable
    # region dilutes the percentage and lets a genuine mass deletion slip under the threshold:
    # 5 of the 5 readable files gone reads as 5/105 = 4.8% and proceeds.
    test "an unreadable region does not dilute the guard into letting a real deletion through" do
      100.times { |i| write!("vault/v#{i}.stl", "v#{i}") }
      5.times { |i| write!("desk/d#{i}.stl", "d#{i}") }
      scan!
      assert_equal 105, @user.nodes.present.where(kind: "file").count

      File.chmod(0o000, @root.join("vault"))
      5.times { |i| FileUtils.rm_f(@root.join("desk/d#{i}.stl").to_s) } # 100% of what we CAN see
      begin
        assert_raises(Library::Scanner::UnsafeScan) { scan! }
      ensure
        File.chmod(0o755, @root.join("vault"))
      end

      assert_equal 105, @user.nodes.present.where(kind: "file").count
    end

    # ...and when it refuses, it says so. Those subtrees are excluded from BOTH sides of the
    # fraction, so an operator reading only "5/5 observable files" has no way to know the
    # population was reduced — "vault was unreadable" is usually the whole explanation for a
    # half-mounted share. Task 9 wants this signal too.
    test "the refusal names the unreadable directories it excluded" do
      10.times { |i| write!("vault/v#{i}.stl", "v#{i}") }
      5.times { |i| write!("desk/d#{i}.stl", "d#{i}") }
      scan!

      File.chmod(0o000, @root.join("vault"))
      5.times { |i| FileUtils.rm_f(@root.join("desk/d#{i}.stl").to_s) }
      begin
        err = assert_raises(Library::Scanner::UnsafeScan) { scan! }
      ensure
        File.chmod(0o755, @root.join("vault"))
      end

      assert_match(/1 directories were unreadable and excluded/, err.message)
      assert_match(/"vault"/, err.message, "name them — that is the diagnosis")
    end

    # THE TRANSITION. A library indexed BEFORE the ignore-list existed carries a few clutter
    # nodes (the deployed share measured ~2.1% — ~9 of 427). On the first scan after the list
    # lands they are no longer OBSERVED, so they tombstone cleanly — and crucially NO ghost forms,
    # because no live node persists at a skipped path once the reconcile runs. At that fraction
    # (well under the 20% guard) the scan must proceed, not refuse, and stay stable on the next
    # pass. If the ignore-list were NOT wired, the on-disk clutter would be observed, re-pair to
    # these nodes by path, and survive — so this doubles as a guard against the skip silently
    # regressing.
    test "existing indexed clutter tombstones on the next scan, and does not trip the guard" do
      50.times { |i| write!("real#{i}.stl", "body-#{i}") }
      scan!
      assert_equal 50, @user.nodes.present.where(kind: "file").count

      # The clutter as an old scan would have left it: real files on disk AND live nodes for them.
      write!(".DS_Store", "finder junk")
      write!("._resource", "an AppleDouble fork")
      write!("__MACOSX/junk.txt", "from a zip")
      root_clutter = [ ".DS_Store", "._resource" ].map do |rel|
        @user.nodes.create!(node_id: SecureRandom.uuid, name: rel, kind: "file", deleted: false,
                            storage_path: rel, parent_node_id: nil, size: 1, mtime: 1,
                            content_hash: "deadbeef")
      end
      macosx = @user.nodes.create!(node_id: SecureRandom.uuid, name: "__MACOSX", kind: "dir",
                                   deleted: false, storage_path: "__MACOSX", parent_node_id: nil)
      macosx_child = @user.nodes.create!(node_id: SecureRandom.uuid, name: "junk.txt", kind: "file",
                                         deleted: false, storage_path: "__MACOSX/junk.txt",
                                         parent_node_id: macosx.node_id, size: 1, mtime: 1,
                                         content_hash: "deadbeef")

      # ~4% of 53 files — comfortably under the 20% guard, like the real ~2% transition.
      assert_nothing_raised { scan! }

      (root_clutter + [ macosx, macosx_child ]).each do |n|
        assert @user.nodes.find_by!(node_id: n.node_id).deleted,
               "#{n.storage_path} is now clutter and must be tombstoned, not left indexed"
      end
      assert_equal 50, @user.nodes.present.where(kind: "file").count, "no real file was touched"

      # Stable: a second pass does not re-tombstone or resurrect anything, and never wedges.
      assert_nothing_raised { scan! }
    end

    # --- the escape hatch -------------------------------------------------------------------

    # The threshold is read per call, not at class load: the raise names this variable as the
    # operator's way out, and a constant frozen at boot makes that advice a lie inside a running
    # process (and unreachable from a test, which is how an escape hatch rots shut).
    test "LIBRARY_SCAN_MAX_DELETE_PCT is the documented way out, and it works" do
      10.times { |i| write!("m#{i}.stl", "y#{i}") }
      scan!
      9.times { |i| FileUtils.rm_f(@root.join("m#{i}.stl").to_s) } # 90%

      err = assert_raises(Library::Scanner::UnsafeScan) { scan! }
      # The message must NAME the variable. Reading ENV per call instead of freezing a constant
      # is justified entirely by this raise being the operator's pointer to the way out — a
      # reword that drops the name leaves them a percentage and no exit, and every other
      # assertion here would stay green.
      assert_match(/LIBRARY_SCAN_MAX_DELETE_PCT/, err.message)

      ENV["LIBRARY_SCAN_MAX_DELETE_PCT"] = "95"
      begin
        scan!
      ensure
        ENV.delete("LIBRARY_SCAN_MAX_DELETE_PCT")
      end
      assert_equal 1, @user.nodes.present.where(kind: "file").count
    end
  end
end
