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
end
