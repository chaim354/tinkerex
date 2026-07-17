require "test_helper"
require_relative "adapter_contract"
require_relative "adapter_write_contract"

module FileLayer
  # The Share adapter over a plain mounted directory: no chunks, no versions, no history —
  # the file on disk IS the truth, and content_token is its content hash.
  class ShareTest < ActiveSupport::TestCase
    include FileLayerAdapterContract
    # Share implements the port's write path, so it answers the write contract too. Chunk does
    # not include this — its write/delete/move raise, by design (Task 1). That split IS the
    # module: Phase 3's S3 adapter includes it, and so cannot answer these differently.
    include FileLayerWritableContract

    setup do
      @root = Pathname.new(Dir.mktmpdir("share-test"))
      @user = User.create!(email: "share-#{SecureRandom.hex(4)}@example.com")
    end
    teardown { FileUtils.remove_entry(@root) if @root&.exist? }

    def adapter = FileLayer::Share.new(root: @root.to_s)

    # Write a real file, then index it the way a scan would. The contract requires a real
    # current mtime; the filesystem provides it.
    def create_file!(name:, bytes:)
      path = @root.join(name)
      FileUtils.mkdir_p(path.dirname)
      File.binwrite(path, bytes)
      Library::Scanner.call(@user, root: @root.to_s)
      @user.nodes.find_by!(storage_path: name).node_id
    end

    # Share's "delete" is the user removing the file from the indexed tree; the next scan
    # tombstones the node.
    #
    # `max_delete_pct: 100` disables the mass-deletion guard, deliberately: the contract's
    # fixtures are one file, so deleting it is a 100% deletion and the guard — a percentage
    # written for a NAS archive — would refuse the scan and this helper would tombstone nothing.
    # The guard has its own tests (ScannerGuardTest); these are the adapter's tombstone
    # semantics, which is a different question.
    def delete_file!(node_id)
      node = @user.nodes.find_by!(node_id:)
      FileUtils.rm_f(@root.join(node.storage_path))
      Library::Scanner.call(@user, root: @root.to_s, max_delete_pct: 100)
    end

    # Share's transient failure: the bytes are there, we just can't read them right now —
    # an unmounted NAS, a permissions blip. Must NOT read as "the user deleted the file".
    def with_transient_backend_failure
      original = File.method(:binread)
      File.define_singleton_method(:binread) { |*| raise Errno::EACCES, "simulated" }
      yield
    ensure
      File.define_singleton_method(:binread, original)
    end

    # Share's transient WRITE failure. A separate hook from with_transient_backend_failure on
    # purpose: read and write are different transports (binread vs binwrite), and the read
    # contract's test ends by re-reading the file to prove the fault was transient — a hook that
    # broke both would make that assertion stop isolating the read path. S3 will do the same
    # (a GET 5xx and a PUT 5xx are not the same fault).
    def with_transient_write_failure
      original = File.method(:binwrite)
      File.define_singleton_method(:binwrite) { |*| raise Errno::EACCES, "simulated" }
      yield
    ensure
      File.define_singleton_method(:binwrite, original)
    end

    # Contract hook, and a BARE YIELD is the honest implementation rather than a stub-out. A
    # mounted directory has no URL signer — that is the whole reason presignable is false here —
    # so there is nothing to configure. Installing one would fake the capability into existence
    # and make the contract's presignable test pin this fixture instead of the adapter.
    def with_off_box_presigning = yield

    # --- download (Task 2) ----------------------------------------------------------------

    # Share is the backend where §15 cannot hold: a directory has nothing to presign, so Rails
    # serves the bytes. SendFile carries the path rather than the bytes, which is what lets the
    # controller hand it to send_file and keep a 2GB file off the Rails heap.
    test "download hands back the absolute path, resolved through the escape guard" do
      id = create_file!(name: "d.stl", bytes: "bytes")
      d = adapter.download(@user, node_id: id, disposition: "attachment")
      assert_kind_of FileLayer::Delivery::SendFile, d
      assert_equal @root.join("d.stl").to_s, d.path
      assert File.exist?(d.path)
    end

    # LANDMINE 2. Delivery::SendFile is a Data object anyone can construct with any path, so the
    # TYPE carries no guarantee whatsoever — the guard has to live at the only place that
    # PRODUCES one, which is why #download resolves through the same #absolute_path #read uses
    # rather than reaching for node.storage_path itself.
    #
    # update_column bypasses validation: a poisoned row of the shape a future bug could produce.
    # storage_path is written by our own scanner today, but it is a plain DB column and 2b's
    # `write` already takes a name from the UI — "no caller passes anything bad today" is exactly
    # the assumption that ages badly. download must refuse rather than hand a controller a path
    # outside the root, because the controller's job is to send_file whatever it is given.
    test "download refuses a storage_path that escapes the root" do
      id = create_file!(name: "d.stl", bytes: "bytes")
      @user.nodes.find_by!(node_id: id).update_column(:storage_path, "../../../etc/passwd")
      err = assert_raises(FileLayer::NotFound) do
        adapter.download(@user, node_id: id, disposition: "attachment")
      end
      # Assert the MESSAGE: NotFound is reachable from live_node! too, so the class alone would be
      # satisfied by an adapter that never resolved the path at all.
      assert_match(/escapes the library root/, err.message)
    end

    test "download raises NotFound for a deleted node" do
      id = create_file!(name: "gone.stl", bytes: "b")
      delete_file!(id)
      assert_raises(FileLayer::NotFound) do
        adapter.download(@user, node_id: id, disposition: "attachment")
      end
    end

    # --- Share-specific tests -------------------------------------------------------------
    # The contract above is RED until the scanner lands (create_file! indexes a real file), but
    # the load-bearing parts of this adapter — the errno mapping, the path-escape guard,
    # MAX_BYTES, tenant scoping — are exactly the parts the contract does NOT reach, and they
    # need no scanner: a `nodes` row is what the scan would produce, so these build it directly
    # and are green NOW. Without them the whole point of the adapter ships unpinned.

    # Index a file the way a completed scan would, without the scanner. `bytes: nil` indexes a
    # path with NO file behind it (the row outlives the file — a deletion or an unmount).
    def index!(name, bytes: nil, path: name)
      if bytes
        p = @root.join(name)
        FileUtils.mkdir_p(p.dirname)
        File.binwrite(p, bytes)
      end
      @user.nodes.create!(
        node_id: SecureRandom.uuid, name: File.basename(name), kind: "file",
        size: bytes&.bytesize || 0, content_hash: Digest::SHA256.hexdigest(bytes.to_s),
        storage_path: path,
        mtime: Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)
      ).node_id
    end

    test "share is the unversioned, unsyncable, unpresignable backend" do
      caps = adapter.capabilities
      refute caps.versioned?, "share keeps no history — restore is a chunk-mode feature"
      refute caps.syncable?
      refute caps.presignable?, "a mounted directory has no URL signer"
    end

    # --- the errno mapping: the load-bearing part -----------------------------------------

    # The library is mounted (other files are there) and THIS file is gone. Only in this case
    # is "missing" terminal.
    test "ENOENT with the library mounted is terminal NotFound" do
      index!("sibling.stl", bytes: "still here") # the root is non-empty => mounted
      id = index!("vanished.stl", bytes: "gone")
      FileUtils.rm_f(@root.join("vanished.stl"))
      assert_raises(FileLayer::NotFound) { adapter.read(@user, node_id: id) }
    end

    # THE headline case (spec §6). An unmounted share is a real, readable, EMPTY directory, so
    # every file raises ENOENT at once. Answering NotFound burns every preview in the library
    # to a permanent "failed" — the exact prod incident FetchError exists for.
    test "ENOENT with an EMPTY library root is TRANSIENT (unmounted, not deleted)" do
      id = index!("nas.stl", bytes: "on the nas")
      FileUtils.rm_f(@root.join("nas.stl")) # root now empty == the unmount shape
      assert_empty Dir.children(@root), "precondition: an unmounted root exists but is empty"
      assert File.exist?(@root), "precondition: File.exist? is TRUE => it cannot be the check"

      assert_raises(FileLayer::FetchError) { adapter.read(@user, node_id: id) }
    end

    # The root removed entirely (rather than emptied) is likewise not the user deleting a file.
    test "ENOENT with a missing library root is TRANSIENT" do
      id = index!("x.stl", bytes: "bytes")
      FileUtils.remove_entry(@root)
      assert_raises(FileLayer::FetchError) { adapter.read(@user, node_id: id) }
    ensure
      FileUtils.mkdir_p(@root) # so teardown's remove_entry finds it
    end

    # A non-ENOENT errno must be FetchError. These three need no chmod, so they hold when the
    # suite runs as root (CI containers do) — and none of them was in this adapter's original
    # errno whitelist, which is why the whitelist became `rescue SystemCallError`.
    test "a non-ENOENT errno is TRANSIENT: ENOTDIR (a path component is a file)" do
      index!("blocker.stl", bytes: "i am a file, not a dir")
      id = index!("blocker.stl/child.stl", path: "blocker.stl/child.stl")
      err = assert_raises(FileLayer::FetchError) { adapter.read(@user, node_id: id) }
      assert_match(/ENOTDIR/, err.message)
    end

    test "a non-ENOENT errno is TRANSIENT: ELOOP (a symlink cycle)" do
      File.symlink(@root.join("loop"), @root.join("loop"))
      id = index!("loop", path: "loop")
      err = assert_raises(FileLayer::FetchError) { adapter.read(@user, node_id: id) }
      assert_match(/ELOOP/, err.message)
    end

    test "a non-ENOENT errno is TRANSIENT: EISDIR (indexed a file, found a directory)" do
      FileUtils.mkdir_p(@root.join("adir"))
      id = index!("adir", path: "adir")
      err = assert_raises(FileLayer::FetchError) { adapter.read(@user, node_id: id) }
      assert_match(/EISDIR/, err.message)
    end

    # A REAL permissions failure, faulted at the transport rather than stubbed. root bypasses
    # permission bits entirely, so this cannot work there — skip rather than ship a test that
    # silently passes for the wrong reason (the ENOTDIR/ELOOP/EISDIR cases above keep the
    # non-ENOENT rule covered when it skips).
    test "a real EACCES on the file is TRANSIENT, not NotFound" do
      skip "root bypasses permission bits" if Process.uid.zero?
      id = index!("locked.stl", bytes: "secret")
      File.chmod(0o000, @root.join("locked.stl"))
      assert_raises(FileLayer::FetchError) { adapter.read(@user, node_id: id) }
    ensure
      FileUtils.chmod(0o644, @root.join("locked.stl")) if @root.join("locked.stl").exist?
    end

    # An unreadable PARENT faults File.size, which runs BEFORE File.binread — so this pins that
    # the rescue covers the whole method body, not just the read call.
    test "an unreadable parent dir is TRANSIENT (proves File.size is covered too)" do
      skip "root bypasses permission bits" if Process.uid.zero?
      id = index!("shut/inner.stl", bytes: "nas bytes")
      File.chmod(0o000, @root.join("shut"))
      assert_raises(FileLayer::FetchError) { adapter.read(@user, node_id: id) }
      FileUtils.chmod(0o755, @root.join("shut"))
      # ...and it was TRANSIENT: healthy the moment the share comes back.
      assert_equal "nas bytes", adapter.read(@user, node_id: id)
    ensure
      FileUtils.chmod(0o755, @root.join("shut")) if @root.join("shut").exist?
    end

    # --- the path-escape guard ------------------------------------------------------------

    test "a storage_path escaping the root is refused" do
      outside = Pathname.new(Dir.mktmpdir("outside"))
      File.write(outside.join("secret.txt"), "TOP SECRET")
      escapes = {
        "parent traversal"    => "../#{outside.basename}/secret.txt",
        "through a subdir"    => "a/b/../../../#{outside.basename}/secret.txt",
        "absolute path"       => "/etc/passwd"
      }
      escapes.each do |label, path|
        id = index!("escape", path:)
        err = assert_raises(FileLayer::NotFound, "#{label} must be refused") do
          adapter.read(@user, node_id: id)
        end
        assert_match(/escapes the library root/, err.message, label)
      end
    ensure
      FileUtils.remove_entry(outside) if outside&.exist?
    end

    # The guard is `start_with?("#{root}/")`, not `start_with?(root)`, precisely so a SIBLING
    # directory whose name merely has the root as a prefix cannot pass. Dropping the trailing
    # slash leaks this and nothing else catches it.
    test "a sibling dir merely PREFIXED by the root is refused" do
      evil = Pathname.new("#{@root}-evil")
      FileUtils.mkdir_p(evil)
      File.write(evil.join("e.txt"), "evil")
      id = index!("e.txt", path: "../#{evil.basename}/e.txt")
      err = assert_raises(FileLayer::NotFound) { adapter.read(@user, node_id: id) }
      assert_match(/escapes the library root/, err.message)
    ensure
      FileUtils.remove_entry(evil) if evil&.exist?
    end

    # --- the rest of the surface the contract doesn't reach -------------------------------

    test "exceeding MAX_BYTES raises NotFound (host-protection cap)" do
      id = index!("big.stl", bytes: "small on disk")
      original = File.method(:size)
      File.define_singleton_method(:size) { |*| FileLayer::MAX_BYTES + 1 }
      err = assert_raises(FileLayer::NotFound) { adapter.read(@user, node_id: id) }
      assert_match(/exceeds/, err.message)
    ensure
      File.define_singleton_method(:size, original)
    end

    test "a user cannot read ANOTHER user's file by node_id" do
      id = index!("mine.stl", bytes: "my bytes")
      other = User.create!(email: "share-other-#{SecureRandom.hex(4)}@example.com")
      # The bytes are right there on disk and the path resolves — only the user-scoped node
      # lookup (CLAUDE.md §8's whole tenancy mechanism) stands between them and the file.
      assert_raises(FileLayer::NotFound) { adapter.read(other, node_id: id) }
      assert_raises(FileLayer::NotFound) { adapter.stat(other, node_id: id) }
    end

    test "reading a stale content_token raises rather than serving current bytes" do
      id = index!("edited.stl", bytes: "v2 content")
      stale = Digest::SHA256.hexdigest("v1 content")
      err = assert_raises(FileLayer::NotFound) do
        adapter.read(@user, node_id: id, content_token: stale)
      end
      assert_match(/not current/, err.message,
                   "must refuse the token, not incidentally fail to find the file")
    end

    test "root defaults to ENV['LIBRARY_PATH']" do
      prev = ENV["LIBRARY_PATH"]
      ENV["LIBRARY_PATH"] = @root.to_s
      assert_equal @root.expand_path, FileLayer::Share.new.root
    ensure
      # Restore rather than delete: Share.new defaults to ENV.fetch("LIBRARY_PATH"), which
      # RAISES KeyError when unset, so clobbering a value another test set would break it
      # rather than merely leak. Task 8's boot guard is exactly the code that sets this.
      prev.nil? ? ENV.delete("LIBRARY_PATH") : ENV["LIBRARY_PATH"] = prev
    end

    # --- the write path (phase 2b) ---------------------------------------------------------

    # THE WEDGE, reproduced end to end. This is not a restatement of the Scanner's skip test — it
    # drives the actual failure that skip exists to stop, so that removing the skip fails HERE,
    # in the write path that caused it, and not only in a scanner unit test someone might read as
    # cosmetic.
    #
    # Before the skip existed this reproduced exactly: three consecutive scans each raised
    # `UnsafeScan 1/1 (100.0% > 20%)`. Neither half was wrong alone — write's temp file is right,
    # and the guard refusing to tombstone 100% of a library is right — but together they wedge it
    # permanently, from a sub-second race, with no operator recourse short of raising the
    # threshold on a library that is not actually being deleted.
    test "a scan racing write's temp file does not wedge the library forever" do
      # The scan lands mid-binwrite and sees the temp TORN — so its hash can never match the
      # finished file, which is what makes the ghost unpairable and therefore fatal.
      torn = @root.join("#{Library::Scanner::TEMP_PREFIX}deadbeef")
      File.binwrite(torn, "torn-half")
      Library::Scanner.call(@user, root: @root.to_s)
      assert_equal 0, @user.nodes.where("storage_path LIKE ?", "#{Library::Scanner::TEMP_PREFIX}%").count,
                   "the in-flight temp must never become a node — that ghost is what wedges the scan"

      # write finishes: different (complete) bytes, renamed into place.
      File.binwrite(torn, "the-complete-file-bytes")
      File.rename(torn, @root.join("done.stl"))

      # Three passes, not one: the wedge is defined by never clearing, so a single green scan
      # would not distinguish "fixed" from "not yet refused".
      3.times do
        # assert_nothing_raised takes no message arg; the rescue names the scan that refused.
        begin
          Library::Scanner.call(@user, root: @root.to_s)
        rescue Library::Scanner::UnsafeScan => e
          flunk "the scan refused itself — the library is wedged: #{e.message}"
        end
      end
      assert_equal [ "done.stl" ], @user.nodes.present.where(kind: "file").pluck(:storage_path)
    end

    test "write stores the bytes and indexes a node the scan agrees with" do
      info = adapter.write(@user, parent_node_id: nil, name: "new.stl", io: StringIO.new("fresh"))

      assert_equal "fresh", File.binread(@root.join("new.stl")), "the bytes must be on disk"
      node = @user.nodes.find_by!(node_id: info.node_id)
      assert_equal "new.stl", node.storage_path
      assert_equal Digest::SHA256.hexdigest("fresh"), node.content_hash
      assert_equal 5, node.size
      assert node.mtime > 1_000_000_000_000_000, "mtime must be nanos, got #{node.mtime}"

      # ...and it is the FILE's mtime, not the clock's. `assert mtime > 1e15` above passes for
      # Time.now-in-nanos, and so does everything below it (the scan re-matches by PATH and keeps
      # the node_id either way) — so without this line the incremental-skip property is unpinned,
      # and that property is the only reason a 2TB archive is not re-hashed on every pass.
      st = File.stat(@root.join("new.stl"))
      assert_equal st.mtime.to_i * 1_000_000_000 + st.mtime.nsec, node.mtime,
                   "write must record the file's own stat — Scanner#nanos compares against it"

      # The scan must AGREE with what write recorded — same node_id, no duplicate, no churn.
      # A write that the next scan treats as a new file would orphan the attachment the caller
      # just made.
      Library::Scanner.call(@user, root: @root.to_s)
      assert_equal 1, @user.nodes.present.where(kind: "file").count
      assert_equal info.node_id, @user.nodes.find_by!(storage_path: "new.stl").node_id
    end

    # `name` is a LEAF; the directory is addressed by parent_node_id. So a write into `cad/`
    # requires cad's node to exist — which a scan produces. This is the maker layer's actual
    # shape: the UI uploads into a folder it is already browsing, so it holds that node_id.
    test "write into a subdirectory addressed by parent_node_id" do
      FileUtils.mkdir_p(@root.join("cad"))
      Library::Scanner.call(@user, root: @root.to_s)
      parent = @user.nodes.find_by!(storage_path: "cad", kind: "dir")

      info = adapter.write(@user, parent_node_id: parent.node_id, name: "gear.stl", io: StringIO.new("g"))

      assert_equal "g", File.binread(@root.join("cad/gear.stl"))
      node = @user.nodes.find_by!(node_id: info.node_id)
      assert_equal "cad/gear.stl", node.storage_path
      assert_equal parent.node_id, node.parent_node_id
    end

    # A leaf name is a leaf: the directory is parent_node_id's job. `.` and `..` are separator-FREE
    # and are the only names that could otherwise reach the root or its parent, so they belong to
    # this check and not to the escape guard. The MESSAGE is asserted because NotFound is reachable
    # from both, and a class-only assertion is how the first draft of this test came to pin nothing.
    # A RESERVED name is a perfectly good leaf, which is exactly why `leaf!` does not catch it.
    # Both entry points, both prefixes: `move` inherited `leaf!` unexamined, so it had the bug too.
    test "write and move refuse a path the scan would skip" do
      %w[.trash .maker-tmp-abc].each do |reserved|
        err = assert_raises(FileLayer::NotFound, "write(#{reserved.inspect}) must be refused") do
          adapter.write(@user, parent_node_id: nil, name: reserved, io: StringIO.new("x"))
        end
        assert_match(/reserved path/, err.message, reserved)

        id = index!("mv-#{reserved.delete('.')}.stl", bytes: "b")
        err = assert_raises(FileLayer::NotFound, "move to #{reserved.inspect} must be refused") do
          adapter.move(@user, node_id: id, new_parent_node_id: nil, new_name: reserved)
        end
        assert_match(/reserved path/, err.message, reserved)
      end
      assert_not File.exist?(@root.join(".trash")), "nothing may be created at a reserved path"
    end

    # THE WEDGE this guard exists for, driven end to end. It wedges TWICE, and the second half is
    # the one a scanner-only test would miss entirely: `.trash` becomes a FILE, so delete's
    # mkdir_p raises EEXIST and EVERY delete in the library breaks — permanently, and not fixed by
    # clearing the ghost.
    test "an upload named .trash does not wedge the scan or break delete library-wide" do
      real = index!("real.stl", bytes: "a real file")
      assert_raises(FileLayer::NotFound) do
        adapter.write(@user, parent_node_id: nil, name: ".trash", io: StringIO.new("evil"))
      end

      3.times do
        begin
          Library::Scanner.call(@user, root: @root.to_s)
        rescue Library::Scanner::UnsafeScan => e
          flunk "the scan refused itself — a ghost at an unobservable path wedged it: #{e.message}"
        end
      end
      # The second wedge: delete must still work for every OTHER file in the library.
      assert_nothing_raised { adapter.delete(@user, node_id: real) }
    end

    test "write rejects a name that is not a leaf" do
      [ "cad/gear.stl", "/etc/passwd", "../outside.stl", "a/../../outside.stl", ".", "..", "" ].each do |bad|
        err = assert_raises(FileLayer::NotFound, "#{bad.inspect} must be refused") do
          adapter.write(@user, parent_node_id: nil, name: bad, io: StringIO.new("x"))
        end
        assert_match(/leaf name/, err.message, bad.inspect)
      end
      assert_equal [], Dir.children(@root), "nothing may be created for a refused name"
    end

    # THE escape guard, reached the only way it can be: through the PARENT. A separator-free leaf
    # cannot escape once `.`/`..` are refused above, so `name` never gets here — but a `dir` node
    # carrying a poisoned storage_path resolves the destination outside the root, which is exactly
    # the bug class the audit preceding this work found (and the same route share_test.rb's
    # read-side escape test uses).
    test "write through a parent whose storage_path escapes the root is refused" do
      outside = Pathname.new(Dir.mktmpdir("outside"))
      evil = @user.nodes.create!(node_id: SecureRandom.uuid, name: "evil", kind: "dir",
                                 storage_path: "../#{outside.basename}", mtime: 1)

      err = assert_raises(FileLayer::NotFound) do
        adapter.write(@user, parent_node_id: evil.node_id, name: "pwned.stl", io: StringIO.new("x"))
      end
      assert_match(/escapes the library root/, err.message)
      assert_equal [], Dir.children(outside), "nothing may be written outside the root"
    ensure
      FileUtils.remove_entry(outside) if outside&.exist?
    end

    # A 256MB fixture is not the way to pin a 256MB cap. Stub the constant instead — the cap's
    # BEHAVIOR is what matters, and it is identical at 4 bytes. (share_test.rb already stubs the
    # read side's File.size for the same reason; this stubs one layer up because `write` is handed
    # an io, not a path, so there is no File.size call to fault.)
    test "write refuses bytes over MAX_BYTES rather than filling the NAS" do
      original = FileLayer::MAX_BYTES
      FileLayer.send(:remove_const, :MAX_BYTES)
      FileLayer.const_set(:MAX_BYTES, 4)

      err = assert_raises(FileLayer::NotFound) do
        adapter.write(@user, parent_node_id: nil, name: "big.stl", io: StringIO.new("12345"))
      end
      assert_match(/exceeds/, err.message)
      assert_not File.exist?(@root.join("big.stl")), "a refused write leaves no partial file"
      assert_nil @user.nodes.find_by(storage_path: "big.stl"), "and no node"
    ensure
      FileLayer.send(:remove_const, :MAX_BYTES)
      FileLayer.const_set(:MAX_BYTES, original)
    end

    # --- delete -> trash (phase 2b) --------------------------------------------------------

    test "delete moves the file to trash keyed by node_id and tombstones the node" do
      id = index!("bracket.stl", bytes: "solid")
      adapter.delete(@user, node_id: id)

      assert_not File.exist?(@root.join("bracket.stl")), "the file leaves the indexed tree"
      assert_equal "solid", File.binread(@root.join(".trash/#{id}/bracket.stl"))
      assert @user.nodes.find_by!(node_id: id).deleted, "the node is tombstoned, never destroyed"
    end

    test "two deleted files of the SAME NAME do not collide in the trash" do
      a = index!("a/bracket.stl", bytes: "one")
      b = index!("b/bracket.stl", bytes: "two")
      adapter.delete(@user, node_id: a)
      adapter.delete(@user, node_id: b)

      # Keyed by node_id, which is exactly why the trash is <node_id>/<name> and not <name>.
      assert_equal "one", File.binread(@root.join(".trash/#{a}/bracket.stl"))
      assert_equal "two", File.binread(@root.join(".trash/#{b}/bracket.stl"))
    end

    # LANDMINE 1. delete tombstones in the same breath as the move, so vanished_paths (which
    # reads the `present` scope) never sees it. Without that, deleting a third of a library
    # through the UI would make the very next scan refuse itself with UnsafeScan — the
    # mass-deletion guard firing on the app's own deliberate action, and never clearing.
    test "deleting most of the library does NOT trip the mass-deletion guard on the next scan" do
      ids = 5.times.map { |i| index!("f#{i}.stl", bytes: "x#{i}") }
      ids.first(4).each { |id| adapter.delete(@user, node_id: id) } # 80% >> the 20% threshold

      assert_nothing_raised { Library::Scanner.call(@user, root: @root.to_s) }
      assert_equal 1, @user.nodes.present.where(kind: "file").count
    end

    # LANDMINE 2. A trash tombstone nulls storage_path, so the reconciler's revive-by-path
    # cannot fire for it. Otherwise a NEW file at that path would inherit the trashed node's
    # node_id — and with it every project attachment, BOM link and tag — while the old bytes
    # still sat in .trash waiting for an undelete that would then collide.
    test "a NEW file at a trashed path is a NEW node, not the trashed one revived" do
      old = index!("bracket.stl", bytes: "original")
      adapter.delete(@user, node_id: old)
      assert_nil @user.nodes.find_by!(node_id: old).storage_path,
                 "a trash tombstone must release its path"

      File.binwrite(@root.join("bracket.stl"), "a completely different file")
      Library::Scanner.call(@user, root: @root.to_s)

      fresh = @user.nodes.find_by!(storage_path: "bracket.stl")
      assert_not_equal old, fresh.node_id, "the new file must not inherit the trashed identity"
      assert @user.nodes.find_by!(node_id: old).deleted, "and the trashed node stays trashed"
    end

    # LANDMINE 3. Do not paper over EXDEV with copy+delete: that makes delete non-atomic and
    # invents a half-state. Spec §6 reserves copy-then-tombstone for S3, which has no rename.
    test "a cross-filesystem trash is a clear error, not a silent half-delete" do
      id = index!("x.stl", bytes: "b")
      original = File.method(:rename)
      File.define_singleton_method(:rename) { |*| raise Errno::EXDEV, "simulated" }
      begin
        err = assert_raises(FileLayer::FetchError) { adapter.delete(@user, node_id: id) }
        assert_match(/EXDEV|filesystem/i, err.message)
      ensure
        File.define_singleton_method(:rename, original)
      end
      assert_not @user.nodes.find_by!(node_id: id).deleted, "a failed move must not tombstone"
      assert File.exist?(@root.join("x.stl")), "and must not lose the file"
      assert_not File.exist?(@root.join(".trash/#{id}")),
                 "and must not leave the empty entry dir it made for a move that never landed"
    end

    test "the scan never indexes the trash" do
      id = index!("t.stl", bytes: "b")
      adapter.delete(@user, node_id: id)
      Library::Scanner.call(@user, root: @root.to_s)
      assert_equal 0, @user.nodes.where("storage_path LIKE '.trash%'").count
    end

    # NOT IN THE PLAN — the gap it left. Why a dir delete wedges the library permanently, and why
    # a cascade is not the answer: see Share#deletable_file!. UnsupportedOperation (a client condition, a
    # StandardError) rather than NotImplementedError (a mis-wired deployment, a ScriptError).
    test "deleting a DIRECTORY is refused, not silently cascaded into a wedge" do
      FileUtils.mkdir_p(@root.join("cad"))
      File.binwrite(@root.join("cad/gear.stl"), "g")
      Library::Scanner.call(@user, root: @root.to_s)
      dir = @user.nodes.find_by!(storage_path: "cad", kind: "dir")

      err = assert_raises(FileLayer::UnsupportedOperation) { adapter.delete(@user, node_id: dir.node_id) }
      assert_match(/director/i, err.message)
      assert_equal "g", File.binread(@root.join("cad/gear.stl")), "the subtree is untouched"
      assert_not @user.nodes.find_by!(node_id: dir.node_id).deleted
      assert_not File.exist?(@root.join(".trash")), "and nothing was moved"
    end

    # mkdir_p is I/O against the same share as the rename and fails for the same transient
    # reasons (a read-only mount, a full disk, an NFS perms blip). Outside the begin its raw
    # Errno escaped the SystemCallError -> FetchError mapping — and a bare Errno IS a
    # StandardError, so it burns a preview to a permanent "failed" instead of retrying: the exact
    # bug class this file's longest comment (read's rescue) exists to prevent.
    #
    # The fixture is junk AT the trash path rather than a chmod, so it holds when the suite runs
    # as root (CI containers do) — root bypasses permission bits, but a file is still not a
    # directory.
    test "a trash dir that cannot be created is TRANSIENT, not a raw errno" do
      id = index!("x.stl", bytes: "b")
      File.binwrite(@root.join(".trash"), "something is already here, and it is not a directory")

      err = assert_raises(FileLayer::FetchError) { adapter.delete(@user, node_id: id) }
      assert_match(/EEXIST/, err.message)
      assert_not @user.nodes.find_by!(node_id: id).deleted, "a failed move must not tombstone"
      assert File.exist?(@root.join("x.stl")), "and must not lose the file"
    end

    # The TAXONOMY, which is the whole point of the class and not its name: a caller's
    # `rescue StandardError` — GeneratePreviewJob's shape, cited throughout this adapter — must
    # catch a folder-delete refusal. NotImplementedError is a ScriptError and would sail straight
    # through it: uncaught out of a job, and once Phase 4 maps NotImplementedError to 501, a 5xx
    # and an on-call page because a user clicked delete on a folder.
    test "a refused directory delete is a client condition, catchable by rescue StandardError" do
      FileUtils.mkdir_p(@root.join("cad"))
      Library::Scanner.call(@user, root: @root.to_s)
      dir = @user.nodes.find_by!(storage_path: "cad", kind: "dir")

      caught = begin
        adapter.delete(@user, node_id: dir.node_id)
        :nothing_was_raised
      rescue StandardError => e
        e.class
      end
      assert_equal FileLayer::UnsupportedOperation, caught,
                   "a ScriptError here escapes every ordinary caller's rescue"
    end

    # The second delete of a node is NOT idempotent-and-silent: live_node! refuses it. That is
    # the right answer — the bytes it would move are already in the trash, and a delete that
    # "succeeded" here would rename the trashed file onto itself for a node that is already gone.
    test "deleting an already-trashed node is refused and leaves the trashed bytes alone" do
      id = index!("once.stl", bytes: "b")
      adapter.delete(@user, node_id: id)

      assert_raises(FileLayer::NotFound) { adapter.delete(@user, node_id: id) }
      assert_equal "b", File.binread(@root.join(".trash/#{id}/once.stl"))
    end

    # --- move (phase 2b) -------------------------------------------------------------------

    test "move renames on disk and keeps the node_id — the attachment survives" do
      id = index!("old.stl", bytes: "same")
      adapter.move(@user, node_id: id, new_parent_node_id: nil, new_name: "new.stl")

      node = @user.nodes.find_by!(node_id: id)
      assert_equal "new.stl", node.storage_path
      assert_equal "same", File.binread(@root.join("new.stl"))
      assert_not File.exist?(@root.join("old.stl"))
      # The scan must agree rather than seeing a delete+create.
      Library::Scanner.call(@user, root: @root.to_s)
      assert_equal id, @user.nodes.find_by!(storage_path: "new.stl").node_id
    end

    test "move refuses to overwrite an existing file" do
      a = index!("a.stl", bytes: "aaa")
      index!("b.stl", bytes: "bbb")
      assert_raises(FileLayer::NotFound) do
        adapter.move(@user, node_id: a, new_parent_node_id: nil, new_name: "b.stl")
      end
      assert_equal "bbb", File.binread(@root.join("b.stl")), "the destination is untouched"
    end

    # Same correction as write's: "../escaped.stl" contains a separator, so it is the LEAF check
    # that refuses it, not the escape guard — assert the message so this test names what it pins.
    test "move refuses a new_name that is not a leaf" do
      id = index!("a.stl", bytes: "aaa")
      err = assert_raises(FileLayer::NotFound) do
        adapter.move(@user, node_id: id, new_parent_node_id: nil, new_name: "../escaped.stl")
      end
      assert_match(/leaf name/, err.message)
      assert File.exist?(@root.join("a.stl")), "a refused move must not move anything"
    end

    # And the escape guard on move's destination, reached the only way it can be — through a
    # poisoned parent, exactly as in write.
    test "move into a parent whose storage_path escapes the root is refused" do
      id = index!("a.stl", bytes: "aaa")
      evil = @user.nodes.create!(node_id: SecureRandom.uuid, name: "evil", kind: "dir",
                                 storage_path: "../evil-#{SecureRandom.hex(4)}", mtime: 1)
      err = assert_raises(FileLayer::NotFound) do
        adapter.move(@user, node_id: id, new_parent_node_id: evil.node_id, new_name: "a.stl")
      end
      assert_match(/escapes the library root/, err.message)
      assert File.exist?(@root.join("a.stl")), "the file stays put"
    end

    # move OUT of a subdirectory to the root. `new_parent_node_id: nil` is the root — the same
    # "blank means root" join_rel/parent_dir_rel! convention `write` already uses — and this is
    # the only test that exercises the nil branch as a DESTINATION rather than as "the caller
    # didn't say", which is the ambiguity documented on #move.
    test "move to the root clears parent_node_id and lands the bytes at the top level" do
      FileUtils.mkdir_p(@root.join("cad"))
      Library::Scanner.call(@user, root: @root.to_s)
      parent = @user.nodes.find_by!(storage_path: "cad", kind: "dir")
      info = adapter.write(@user, parent_node_id: parent.node_id, name: "gear.stl", io: StringIO.new("gg"))

      adapter.move(@user, node_id: info.node_id, new_parent_node_id: nil, new_name: "gear.stl")

      node = @user.nodes.find_by!(node_id: info.node_id)
      assert_equal "gear.stl", node.storage_path
      assert_nil node.parent_node_id
      assert_equal "gg", File.binread(@root.join("gear.stl"))
      assert_not File.exist?(@root.join("cad/gear.stl"))
    end

    # NOT IN THE PLAN, and the asymmetry with delete is the point. Share#deletable_file! refuses a
    # directory DELETE because it strands the children's nodes at paths the scan refuses to look
    # behind (.trash) — a permanent wedge. It predicted move's answer would be different; it is,
    # and this pins WHY: a moved directory leaves its children's bytes OBSERVABLE at the new path,
    # so the Reconciler's move-pairing re-homes them on the next pass with their node_ids intact.
    # Self-healing, not a wedge — so move allows what delete refuses. See #move's comment for the
    # two residuals this accepts (both identical to the user renaming the folder in Finder).
    test "moving a DIRECTORY is allowed: the next scan re-homes the children, node_ids intact" do
      FileUtils.mkdir_p(@root.join("cad"))
      Library::Scanner.call(@user, root: @root.to_s)
      dir = @user.nodes.find_by!(storage_path: "cad", kind: "dir")
      gear = adapter.write(@user, parent_node_id: dir.node_id, name: "gear.stl", io: StringIO.new("gg"))
      brk  = adapter.write(@user, parent_node_id: dir.node_id, name: "brk.stl", io: StringIO.new("bb"))

      adapter.move(@user, node_id: dir.node_id, new_parent_node_id: nil, new_name: "cad2")

      assert_equal "gg", File.binread(@root.join("cad2/gear.stl")), "the subtree moved with it"
      # The children's storage_path is STALE until the next scan — the accepted window, identical
      # to a Finder rename. Their parent_node_id is not stale (the dir kept its node_id), so
      # browse-by-parent never breaks; only byte reads do, and only until the scan.
      assert_equal "cad/gear.stl", @user.nodes.find_by!(node_id: gear.node_id).storage_path

      # 2/2 files "vanish" from their old paths, which is 100% — far over the 20% guard. It does
      # NOT refuse, because the guard counts the POST-pairing tombstone set and pairing explains
      # both. A dir move being mistaken for a mass deletion is exactly what that design prevents.
      assert_nothing_raised { Library::Scanner.call(@user, root: @root.to_s) }

      assert_equal gear.node_id, @user.nodes.find_by!(storage_path: "cad2/gear.stl").node_id,
                   "the attachment survives the folder move — the phase's headline promise"
      assert_equal brk.node_id, @user.nodes.find_by!(storage_path: "cad2/brk.stl").node_id
      assert_equal 2, @user.nodes.present.where(kind: "file").count, "no duplicates, no ghosts"
    end

    # --- undelete (phase 2b) ---------------------------------------------------------------

    test "undelete moves the bytes back and revives the node with its node_id" do
      id = index!("bracket.stl", bytes: "solid")
      adapter.delete(@user, node_id: id)
      adapter.undelete(@user, node_id: id)

      node = @user.nodes.find_by!(node_id: id)
      assert_not node.deleted
      assert_equal "bracket.stl", node.storage_path
      assert_equal "solid", File.binread(@root.join("bracket.stl"))
      assert_not File.exist?(@root.join(".trash/#{id}")), "the trash entry is consumed"
    end

    test "undelete refuses when something else now occupies the path" do
      id = index!("bracket.stl", bytes: "solid")
      adapter.delete(@user, node_id: id)
      File.binwrite(@root.join("bracket.stl"), "someone else's file")

      assert_raises(FileLayer::NotFound) { adapter.undelete(@user, node_id: id) }
      assert_equal "someone else's file", File.binread(@root.join("bracket.stl")),
                   "undelete must never clobber a live file"
      assert File.exist?(@root.join(".trash/#{id}/bracket.stl")), "the trashed bytes survive"
    end

    # A trash tombstone has a NULL storage_path (Landmine 2), so undelete must RECONSTRUCT the
    # destination from parent_node_id + name. Every other test here deletes a root-level file,
    # where that reconstruction is indistinguishable from "just use the name" — so without this
    # case the parent leg is unpinned and a file deleted out of cad/ would be restored to the root.
    test "undelete restores into the original subdirectory, not the root" do
      FileUtils.mkdir_p(@root.join("cad"))
      Library::Scanner.call(@user, root: @root.to_s)
      parent = @user.nodes.find_by!(storage_path: "cad", kind: "dir")
      info = adapter.write(@user, parent_node_id: parent.node_id, name: "gear.stl", io: StringIO.new("gg"))

      adapter.delete(@user, node_id: info.node_id)
      adapter.undelete(@user, node_id: info.node_id)

      assert_equal "gg", File.binread(@root.join("cad/gear.stl"))
      assert_equal "cad/gear.stl", @user.nodes.find_by!(node_id: info.node_id).storage_path
    end

    # THE test the `live: false` kwarg exists for, and the ONLY one that fails without it.
    #
    # The plan justified `live: false` with "the parent may have been tombstoned by a scan once
    # this file left it (tombstone_vanished_dirs)". That reason is FALSE — probed: an emptied
    # directory still EXISTS on disk, so the scan observes it and never tombstones it. The real
    # route is one step further along: the user deletes the last file through the UI and then
    # removes the now-empty folder in Finder. THAT scan tombstones the dir (keeping its
    # storage_path), and undelete must still be able to put the file back.
    #
    # `present`-scoping the parent lookup here would answer "parent ... is not a live directory"
    # — a dead end the user can neither see nor fix, for a folder they are in the middle of
    # restoring a file into. Restoring is self-healing instead: mkdir_p recreates the folder, and
    # because a recreated folder is POSITIVE EVIDENCE (an observation), the next scan revives the
    # very same dir node by storage_path — original node_id and all. Pinned below, because a
    # transiently-tombstoned parent would otherwise be a silent gap.
    test "undelete restores into a parent the scan tombstoned after the folder was removed" do
      FileUtils.mkdir_p(@root.join("cad"))
      Library::Scanner.call(@user, root: @root.to_s)
      parent = @user.nodes.find_by!(storage_path: "cad", kind: "dir")
      info = adapter.write(@user, parent_node_id: parent.node_id, name: "gear.stl", io: StringIO.new("gg"))
      adapter.delete(@user, node_id: info.node_id)

      # The user removes the emptied folder in Finder; the scan tombstones the dir node.
      FileUtils.rmdir(@root.join("cad"))
      Library::Scanner.call(@user, root: @root.to_s, max_delete_pct: 100)
      assert parent.reload.deleted, "precondition: the parent dir node is a tombstone"
      assert_equal "cad", parent.storage_path, "precondition: a scan tombstone KEEPS its path"

      adapter.undelete(@user, node_id: info.node_id)

      assert_equal "gg", File.binread(@root.join("cad/gear.stl")), "the folder is recreated for it"
      assert_equal "cad/gear.stl", @user.nodes.find_by!(node_id: info.node_id).storage_path

      # ...and the transient inconsistency (a live node under a tombstoned parent) heals on the
      # next pass, with the ORIGINAL dir node_id — so nothing pointing at that folder is orphaned.
      Library::Scanner.call(@user, root: @root.to_s)
      assert_not parent.reload.deleted
      assert_equal parent.node_id, @user.nodes.find_by!(storage_path: "cad", kind: "dir").node_id
    end

    # NOT IN THE PLAN. A tombstoned dir keeps its storage_path today, so dropping `present` from
    # the parent lookup cannot currently return a path-less row — but "cannot currently" is the
    # whole reason to say it out loud: join_rel(nil, name) means THE ROOT, so a parent that ever
    # loses its path would silently restore the file to the top of the library instead of failing.
    # A silent misplacement is the failure this adapter is least able to detect later.
    test "undelete refuses a parent with no storage_path rather than silently restoring to the root" do
      pathless = @user.nodes.create!(node_id: SecureRandom.uuid, name: "ghost", kind: "dir",
                                     storage_path: nil, mtime: 1)
      id = index!("gear.stl", bytes: "gg")
      @user.nodes.find_by!(node_id: id).update!(parent_node_id: pathless.node_id)
      adapter.delete(@user, node_id: id)

      err = assert_raises(FileLayer::NotFound) { adapter.undelete(@user, node_id: id) }
      assert_match(/has no storage_path/, err.message)
      assert_not File.exist?(@root.join("gear.stl")), "and it did NOT land in the root"
      assert File.exist?(@root.join(".trash/#{id}/gear.stl")), "the trashed bytes are untouched"
    end

    # The purge job (Task 6) may have taken the bytes, and a SCAN tombstone never had any in
    # .trash to begin with. Both are terminal and both are the user's answer: it is gone.
    test "undelete of a node whose trashed bytes are gone is terminal NotFound" do
      index!("sibling.stl", bytes: "the library is mounted") # a non-empty root == mounted
      id = index!("purged.stl", bytes: "b")
      adapter.delete(@user, node_id: id)
      FileUtils.remove_entry(@root.join(".trash/#{id}"))

      err = assert_raises(FileLayer::NotFound) { adapter.undelete(@user, node_id: id) }
      assert_match(/purged/, err.message)
    end

    # NOT IN THE PLAN, and the correction it needed. The plan raised a bare NotFound whenever the
    # trashed bytes were absent — but an UNMOUNTED share makes them absent too, and NotFound is
    # TERMINAL: it tells the user their file is permanently gone (and, once Phase 4 maps it, 404s)
    # when the NAS is merely down and the bytes are sitting safely on it. That is precisely the
    # verdict `read`'s longest comment refuses to make, for precisely this reason — so undelete,
    # the only OTHER place this adapter mints a "your file is gone", asks the same question.
    test "undelete with the library unmounted is TRANSIENT, not a false 'purged'" do
      id = index!("nas.stl", bytes: "on the nas")
      adapter.delete(@user, node_id: id)
      FileUtils.remove_entry(@root.join(".trash")) # the unmount shape: the root exists, and is empty

      assert_empty Dir.children(@root), "precondition: an unmounted root exists but is empty"
      err = assert_raises(FileLayer::FetchError) { adapter.undelete(@user, node_id: id) }
      assert_match(/unmounted/, err.message)
      assert @user.nodes.find_by!(node_id: id).deleted, "and the node stays trashed, undeletable later"
    end

    test "undeleting a LIVE node is a clean NotFound, not a confusing rename" do
      id = index!("live.stl", bytes: "here")
      err = assert_raises(FileLayer::NotFound) { adapter.undelete(@user, node_id: id) }
      assert_match(/not in the trash/, err.message)
      assert_equal "here", File.binread(@root.join("live.stl"))
    end

    test "a user cannot undelete ANOTHER user's trashed node" do
      id = index!("mine.stl", bytes: "my bytes")
      adapter.delete(@user, node_id: id)
      other = User.create!(email: "share-other-#{SecureRandom.hex(4)}@example.com")

      assert_raises(FileLayer::NotFound) { adapter.undelete(other, node_id: id) }
      assert_equal "my bytes", File.binread(@root.join(".trash/#{id}/mine.stl"))
    end

    # undelete re-stats rather than trusting the size/mtime the node carried when it was trashed.
    # Those are what the next scan's (path, mtime, size) skip-check compares against, and a stale
    # pair makes it re-hash the file for nothing — the incremental-skip property `write` pins for
    # the same reason. The mtime is preserved by rename, so this asserts AGREEMENT with the file.
    test "undelete records the restored file's own stat, so the next scan skips it" do
      id = index!("bracket.stl", bytes: "solid")
      @user.nodes.find_by!(node_id: id).update!(size: 999, mtime: 1) # a stale pair, as a purge would leave
      adapter.delete(@user, node_id: id)
      adapter.undelete(@user, node_id: id)

      st = File.stat(@root.join("bracket.stl"))
      node = @user.nodes.find_by!(node_id: id)
      assert_equal st.size, node.size
      assert_equal st.mtime.to_i * 1_000_000_000 + st.mtime.nsec, node.mtime
    end

    # The mirror of delete's Landmine 1, and the structural finding behind it: delete moves bytes
    # INTO a region the Scanner skips, undelete moves them OUT. Out is the safe direction — the
    # path becomes observable and the node becomes live in the same breath — so the scan simply
    # matches it by path. Pinned because "it works out" is not the same as "nobody checked".
    test "undelete leaves no ghost for the next scan: no tombstone, no duplicate, no re-create" do
      ids = 5.times.map { |i| index!("f#{i}.stl", bytes: "x#{i}") }
      ids.first(4).each { |id| adapter.delete(@user, node_id: id) }
      ids.first(4).each { |id| adapter.undelete(@user, node_id: id) }

      assert_nothing_raised { Library::Scanner.call(@user, root: @root.to_s) }
      assert_equal 5, @user.nodes.present.where(kind: "file").count
      assert_equal ids.sort, @user.nodes.present.where(kind: "file").pluck(:node_id).sort,
                   "every file kept its ORIGINAL node_id through delete -> undelete -> scan"
      assert_equal 0, @user.nodes.where("storage_path LIKE '.trash%'").count
    end

    # mkdir_p is I/O against the same share as the rename and fails for the same transient
    # reasons — the same bug Task 3's delete had to fix, in the two methods that copied its shape.
    # Junk AT the destination's parent path rather than a chmod, so it holds when the suite runs
    # as root (CI containers do): root bypasses permission bits, but a file is still not a
    # directory.
    test "move: a destination dir that cannot be created is TRANSIENT, not a raw errno" do
      id = index!("a.stl", bytes: "aaa")
      File.binwrite(@root.join("blocker"), "not a directory")
      evil = @user.nodes.create!(node_id: SecureRandom.uuid, name: "blocker", kind: "dir",
                                 storage_path: "blocker/deep", mtime: 1)

      err = assert_raises(FileLayer::FetchError) do
        adapter.move(@user, node_id: id, new_parent_node_id: evil.node_id, new_name: "a.stl")
      end
      assert_match(/ENOTDIR|EEXIST/, err.message)
      assert File.exist?(@root.join("a.stl")), "a failed move must not lose the file"
      assert_equal "a.stl", @user.nodes.find_by!(node_id: id).storage_path, "and must not re-path it"
    end

    test "undelete: a destination dir that cannot be created is TRANSIENT, not a raw errno" do
      dir = @user.nodes.create!(node_id: SecureRandom.uuid, name: "blocker", kind: "dir",
                                storage_path: "blocker/deep", mtime: 1)
      id = index!("a.stl", bytes: "aaa")
      @user.nodes.find_by!(node_id: id).update!(parent_node_id: dir.node_id)
      adapter.delete(@user, node_id: id)
      File.binwrite(@root.join("blocker"), "not a directory")

      err = assert_raises(FileLayer::FetchError) { adapter.undelete(@user, node_id: id) }
      assert_match(/ENOTDIR|EEXIST/, err.message)
      assert @user.nodes.find_by!(node_id: id).deleted, "a failed restore must stay trashed"
      assert File.exist?(@root.join(".trash/#{id}/a.stl")), "and must not lose the bytes"
    end
  end
end
