require "test_helper"
require_relative "adapter_contract"

module FileLayer
  # The Share adapter over a plain mounted directory: no chunks, no versions, no history —
  # the file on disk IS the truth, and content_token is its content hash.
  class ShareTest < ActiveSupport::TestCase
    include FileLayerAdapterContract

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
  end
end
