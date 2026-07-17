require "test_helper"
require_relative "adapter_contract"
require_relative "../../support/fake_s3"

module FileLayer
  # The S3 adapter over the user's own bucket: no chunks, no versions, no history -- the
  # object IS the truth, and content_token is its identity (FileLayer::S3::ObjectIdentity).
  #
  # Runs the SAME read contract as Chunk and Share. That is the anti-divergence mechanism,
  # and it is the reason this adapter needs so few tests of its own.
  class S3Test < ActiveSupport::TestCase
    include FileLayerAdapterContract

    PREFIX = "library".freeze

    setup do
      @fake = FakeS3.new
      @user = User.create!(email: "s3-#{SecureRandom.hex(4)}@example.com")
    end

    def adapter
      @adapter ||= FileLayer::S3.new(bucket: "b", region: "us-east-1", access_key_id: "ak",
                                     secret_access_key: "sk", prefix: PREFIX, client: @fake.client)
    end

    # Seed the object as another tool would have, then index it the way a completed scan would.
    # That is the backend's actual premise: the bucket already has the user's files in it.
    #
    # PLAN DRIFT, deliberate and reported: the plan called Library::S3Observer here and expected
    # this file to stay RED until Task 7 builds it. It indexes directly instead, mirroring
    # share_test's own `index!` — a `nodes` row IS what a completed scan produces, so the adapter
    # under test sees the identical input either way, and the contract runs GREEN now rather than
    # after a task that has nothing to do with stat/read. Task 7 owns proving the observer writes
    # these columns; this file owns the adapter's behavior given them.
    #
    # The identity goes through ObjectIdentity.for — the same call the observer will make — so
    # this fixture cannot quietly disagree with the thing it stands in for. Computing an md5 by
    # hand here is exactly how a helper drifts from production.
    #
    # mtime is converted to unix NANOSECONDS here (FileInfo: adapters CONVERT). S3's
    # last_modified is a second-granularity Time, so this is where the seconds-as-nanos bug the
    # contract's NANOS_FLOOR pins would enter if it entered at all.
    def create_file!(name:, bytes:)
      key = "#{PREFIX}/#{name}"
      @fake.seed!(key, bytes, last_modified: Time.now)
      obj = @fake.objects.fetch(key)
      @user.nodes.create!(
        node_id: SecureRandom.uuid, name: File.basename(name), kind: "file", deleted: false,
        storage_path: name, size: bytes.bytesize,
        content_hash: FileLayer::S3::ObjectIdentity.for(etag: obj.etag),
        mtime: obj.last_modified.to_i * 1_000_000_000 + obj.last_modified.nsec
      ).node_id
    end

    # S3's "delete" as a USER would do it: the object leaves the bucket (deleted in the console,
    # by another tool), and the next scan tombstones the node. NOT the port's delete -- that is
    # the adapter under test, and it does not exist until Task 6.
    def delete_file!(node_id)
      node = @user.nodes.find_by!(node_id:)
      @fake.objects.delete("#{PREFIX}/#{node.storage_path}")
      node.update!(deleted: true)
    end

    # S3's transient failure: the bytes are there, we cannot read them right now -- an expired
    # credential, a 5xx, a network blip. Must NOT read as "the user deleted it". Faults the
    # TRANSPORT (the client), never the adapter's own classification -- stubbing that is what the
    # contract's test exists to catch.
    #
    # get_object only: the WRITE contract (Task 5) has its own hook, with_transient_write_failure,
    # for the reason share_test gives -- the read contract's test ends by re-reading the file to
    # prove the fault was transient, and a hook that broke both transports would stop that
    # assertion isolating the read path. (The plan faulted put_object here too, from before 2b's
    # note added the second hook.)
    def with_transient_backend_failure
      @fake.fault!(:get_object, "InternalError")
      yield
    ensure
      @fake.clear_faults!
    end

    # --- S3-specific --------------------------------------------------------------

    test "stat reports the identity as the content token" do
      id = create_file!(name: "a.stl", bytes: "hello")
      info = adapter.stat(@user, node_id: id)
      assert_equal "md5:#{Digest::MD5.hexdigest('hello')}", info.content_token
      assert_equal 5, info.size
    end

    # The prefix is what lets a bucket hold a library WITHOUT owning the whole bucket.
    # A node's storage_path is relative to it; the key is prefix + path. Getting this
    # wrong reads and writes the wrong keyspace -- silently, on someone else's data.
    test "the prefix scopes the keyspace and never leaks into storage_path" do
      id = create_file!(name: "cad/gear.stl", bytes: "g")
      assert_equal "cad/gear.stl", @user.nodes.find_by!(node_id: id).storage_path
      assert @fake.objects.key?("#{PREFIX}/cad/gear.stl"), "the key is prefix + storage_path"
      assert_equal "g", adapter.read(@user, node_id: id)
    end

    # The mirror of Share#library_present?. An empty/wrong bucket makes EVERY object 404
    # at once -- indistinguishable from "this one was deleted" if we only look at the key.
    # NotFound is terminal (a preview burns to permanently failed), so when the whole
    # library appears to have evaporated, prefer the retryable answer. Same trade, same
    # reasoning, same direction as the share (spec 6).
    test "a missing object in an EMPTY library reads as transient, not as a deletion" do
      id = create_file!(name: "vanish.stl", bytes: "b")
      @fake.objects.clear # the bucket is gone/wrong/empty, not "one file deleted"
      assert_raises(FileLayer::FetchError) { adapter.read(@user, node_id: id) }
    end

    test "a missing object in a POPULATED library is genuinely gone: terminal" do
      id = create_file!(name: "vanish.stl", bytes: "b")
      create_file!(name: "other.stl", bytes: "still here")
      @fake.objects.delete("#{PREFIX}/vanish.stl")
      assert_raises(FileLayer::NotFound) { adapter.read(@user, node_id: id) }
    end

    # AccessDenied is the credentials-outage shape that caused the original production
    # incident. It is NOT NoSuchKey, so it must never read as absence.
    test "AccessDenied is transient, never NotFound" do
      id = create_file!(name: "denied.stl", bytes: "b")
      @fake.fault!(:get_object, "AccessDenied")
      err = assert_raises(FileLayer::FetchError) { adapter.read(@user, node_id: id) }
      assert_match(/AccessDenied/, err.message, "the operator needs to know WHICH failure")
    end

    test "a networking error is transient, never NotFound" do
      id = create_file!(name: "net.stl", bytes: "b")
      @fake.fault!(:get_object, Seahorse::Client::NetworkingError.new(Errno::ECONNREFUSED.new))
      assert_raises(FileLayer::FetchError) { adapter.read(@user, node_id: id) }
    end

    # The library_present? probe is itself I/O against the same store that just failed, so it
    # fails too during a real outage. It must not turn a transient answer terminal on its way
    # out -- and an `.any?` on a raised list is a NoMethodError, not a FetchError. Same as Share,
    # where an unlistable root answers "not present".
    test "a NoSuchKey whose library probe ALSO fails stays transient" do
      id = create_file!(name: "probe.stl", bytes: "b")
      @fake.fault!(:get_object, "NoSuchKey")
      @fake.fault!(:list_objects_v2, "InternalError")
      assert_raises(FileLayer::FetchError) { adapter.read(@user, node_id: id) }
    end

    # The escape guard, at the key layer. A storage_path is written by our own observer, but
    # the audit that preceded this work found exactly this bug class in client-supplied
    # values used as storage keys. update_column bypasses validation -- a poisoned row.
    test "a storage_path that escapes the prefix is refused" do
      id = create_file!(name: "a.stl", bytes: "b")
      @user.nodes.find_by!(node_id: id).update_column(:storage_path, "../../etc/passwd")
      assert_raises(FileLayer::NotFound) { adapter.read(@user, node_id: id) }
      assert_equal 0, @fake.calls[:get_object], "refused BEFORE any request left the process"
    end

    # A leading slash escapes by another road -- and a `..`-only check misses it entirely, which
    # is precisely why the guard names it separately.
    #
    # The calls assertion is the ENTIRE test, and it was decoration without it: with the guard
    # deleted, "/etc/passwd" merely composes a key that happens not to exist, so the read raises
    # NotFound anyway and the assert_raises above passes while the request goes out over the
    # wire. Proven by mutation, not by reading it. What is being pinned is that the path is
    # refused BEFORE we ask the store — the same reason the `..` test carries it.
    test "a storage_path with a leading slash is refused" do
      id = create_file!(name: "a.stl", bytes: "b")
      @user.nodes.find_by!(node_id: id).update_column(:storage_path, "/etc/passwd")
      assert_raises(FileLayer::NotFound) { adapter.read(@user, node_id: id) }
      assert_equal 0, @fake.calls[:get_object], "refused BEFORE any request left the process"
    end

    # The guard REJECTS rather than normalizes, and this is the test that says so: an
    # expand_path-shaped fix would resolve this to the perfectly valid key "library/b.stl" and
    # serve b's bytes for a's node -- silently, which is the whole objection to normalizing.
    test "the escape guard refuses rather than normalizing away the .." do
      id = create_file!(name: "a.stl", bytes: "a bytes")
      create_file!(name: "b.stl", bytes: "b bytes")
      @user.nodes.find_by!(node_id: id).update_column(:storage_path, "cad/../b.stl")
      assert_raises(FileLayer::NotFound) { adapter.read(@user, node_id: id) }
    end

    # The mirror image of the guard: ".." as a SUBSTRING is an ordinary filename, and a guard
    # that refused it would make a real object permanently unreadable -- NotFound is terminal.
    test "a filename merely CONTAINING dots is not an escape" do
      id = create_file!(name: "v1..2.stl", bytes: "dots")
      assert_equal "dots", adapter.read(@user, node_id: id)
    end

    # MAX_BYTES is port-wide (FileLayer::MAX_BYTES), and NotFound for "too big" matches Share --
    # a shared wart (the port has no terminal-but-present error), not a local choice. Shrinking
    # the constant rather than seeding 256MB, exactly as share_test's write-cap test does.
    test "exceeding MAX_BYTES raises NotFound (host-protection cap)" do
      id = create_file!(name: "big.stl", bytes: "hello")
      original = FileLayer::MAX_BYTES
      FileLayer.send(:remove_const, :MAX_BYTES)
      FileLayer.const_set(:MAX_BYTES, 4)
      err = assert_raises(FileLayer::NotFound) { adapter.read(@user, node_id: id) }
      assert_match(/exceeds/, err.message)
    ensure
      FileLayer.send(:remove_const, :MAX_BYTES)
      FileLayer.const_set(:MAX_BYTES, original)
    end

    # The cap is enforced by a RANGED get, which is the only thing that actually bounds memory:
    # get_object buffers the whole body into a StringIO before it returns, so reading first and
    # checking content_length after would already be holding the 2GB it means to refuse.
    test "read bounds the transfer with a range rather than pulling the whole object" do
      id = create_file!(name: "ranged.stl", bytes: "hello")
      seen = nil
      @fake.client.stub_responses(:get_object, lambda { |ctx|
        seen = ctx.params[:range]
        { body: "hello", content_length: 5 }
      })
      adapter.read(@user, node_id: id)
      assert_equal "bytes=0-#{FileLayer::MAX_BYTES}", seen,
                   "the GET must cap at MAX_BYTES + 1 bytes, not fetch an unbounded object"
    end

    test "a user cannot read ANOTHER user's file by node_id" do
      id = create_file!(name: "mine.stl", bytes: "my bytes")
      other = User.create!(email: "s3-other-#{SecureRandom.hex(4)}@example.com")
      # The object is right there in the bucket and the key resolves — only the user-scoped node
      # lookup (CLAUDE.md §8's whole tenancy mechanism) stands between them and the file.
      assert_raises(FileLayer::NotFound) { adapter.read(other, node_id: id) }
      assert_raises(FileLayer::NotFound) { adapter.stat(other, node_id: id) }
    end

    test "s3 is the unversioned, unsyncable, PRESIGNABLE backend" do
      caps = adapter.capabilities
      refute caps.versioned?, "the object IS the truth — restore is a chunk-mode feature"
      refute caps.syncable?
      assert caps.presignable?, "a bucket has a URL signer — §15 survives here"
    end
  end
end
