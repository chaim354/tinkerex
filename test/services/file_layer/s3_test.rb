require "test_helper"
require_relative "adapter_contract"
require_relative "adapter_write_contract"
require_relative "../../support/fake_s3"

module FileLayer
  # The S3 adapter over the user's own bucket: no chunks, no versions, no history -- the
  # object IS the truth, and content_token is its identity (FileLayer::S3::ObjectIdentity).
  #
  # Runs the SAME read contract as Chunk and Share. That is the anti-divergence mechanism,
  # and it is the reason this adapter needs so few tests of its own.
  class S3Test < ActiveSupport::TestCase
    include FileLayerAdapterContract
    # THE POINT OF THE MODULE. It was written in 2b as a SECOND contract, separate from the read
    # one, with exactly this adapter named as the reason: "Share includes it now; S3 in Phase 3 —
    # that is the point." It is satisfied UNMODIFIED here; if it ever needs editing to accommodate
    # a backend, that is a finding, not a licence.
    #
    # It earned its keep before this line existed: during 2b it caught that Phase 3's plan let
    # S3#write put_object straight over the user's file while Share, three feet away, refuses.
    include FileLayerWritableContract

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

    # S3's transient WRITE failure: a 5xx, a throttle, an expired credential on the PUT. Separate
    # from with_transient_backend_failure by the write contract's own instruction, and the reason
    # is not symmetry: the READ hook's contract test ends by re-reading the file to prove the fault
    # was transient, so one hook faulting both transports would stop that assertion isolating the
    # read path. Faults the TRANSPORT (put_object), never the adapter's own classification.
    def with_transient_write_failure
      @fake.fault!(:put_object, "InternalError")
      yield
    ensure
      @fake.clear_faults!
    end

    # --- S3-specific --------------------------------------------------------------

    test "write puts the object under the prefix and indexes it" do
      info = adapter.write(@user, parent_node_id: nil, name: "new.stl", io: StringIO.new("fresh"))

      assert_equal "fresh", @fake.objects["#{PREFIX}/new.stl"].body
      node = @user.nodes.find_by!(node_id: info.node_id)
      assert_equal "new.stl", node.storage_path
      assert_equal "md5:#{Digest::MD5.hexdigest('fresh')}", node.content_hash
      assert_equal 5, node.size
      assert node.mtime > 1_000_000_000_000_000, "mtime must be nanos, got #{node.mtime}"
    end

    # mtime comes from the STORE, never from Time.now — the next scan compares the node against
    # what the store reports, so a clock we guessed makes every written file look changed on the
    # very next pass. Pinned by moving the store's clock somewhere Time.now could not be: a real
    # last_modified is what write must record, whatever our own clock says.
    test "write records the STORE's mtime, not our clock" do
      stored = Time.at(1_600_000_000)
      @fake.client.stub_responses(:head_object, ->(ctx) {
        @fake.objects.key?(ctx.params[:key]) ? { content_length: 5, last_modified: stored } : "NotFound"
      })
      info = adapter.write(@user, parent_node_id: nil, name: "clock.stl", io: StringIO.new("fresh"))

      assert_equal 1_600_000_000_000_000_000, @user.nodes.find_by!(node_id: info.node_id).mtime,
                   "the mtime must be the store's last_modified in nanos, not Time.now"
    end

    # LANDMINE 2, on the write side. put_object's response ETag is quoted exactly like the
    # listing's. If write stored the quoted form and the observer stored the stripped one, one
    # object would have two identities: every written file reads as changed on the very next scan,
    # and move-pairing never pairs. One normalizer, or the phase's promise inverts.
    #
    # PLAN DRIFT, deliberate and reported (the same drift Task 4's create_file! already took, and
    # for the same reason): the plan compares write's identity against Library::S3Observer's, which
    # is Task 7's and does not exist. ObjectIdentity.for is the call the observer WILL make — it is
    # named as the one normalizer — so comparing against it is the same assertion a task earlier,
    # and it cannot quietly disagree with the thing it stands in for. Task 7 owns proving the
    # observer routes through it too.
    test "write and the observer agree on the identity, byte for byte" do
      info = adapter.write(@user, parent_node_id: nil, name: "agree.stl", io: StringIO.new("x"))
      written = @user.nodes.find_by!(node_id: info.node_id).content_hash
      observed = FileLayer::S3::ObjectIdentity.for(etag: @fake.objects["#{PREFIX}/agree.stl"].etag)

      assert_equal observed, written, "write and the scan must produce the SAME identity"
      assert_not_includes written, '"', "the quotes S3 wraps ETags in must never reach the DB"
    end

    test "write into a subdirectory addressed by parent_node_id" do
      parent = @user.nodes.create!(node_id: SecureRandom.uuid, name: "cad", kind: "dir",
                                   deleted: false, storage_path: "cad", mtime: 1)
      info = adapter.write(@user, parent_node_id: parent.node_id, name: "gear.stl",
                           io: StringIO.new("g"))

      assert_equal "g", @fake.objects["#{PREFIX}/cad/gear.stl"].body
      node = @user.nodes.find_by!(node_id: info.node_id)
      assert_equal "cad/gear.stl", node.storage_path
      assert_equal parent.node_id, node.parent_node_id
    end

    # Assert the MESSAGE, not just the class. Every fixture below contains a separator, so it is
    # the LEAF check that refuses them — the escape guard is never reached. 2b shipped exactly this
    # test asserting NotFound by class alone and it pinned nothing: NotFound was reachable two ways
    # and the guard it named was dead code as far as the test was concerned.
    #
    # The call counts are what stop this being decoration in the OTHER direction: a refused write
    # and a write to a nonexistent-but-composed key both end in an exception, so "it raised" proves
    # nothing about WHERE. Zero requests = refused before anything left the process.
    test "write rejects a name that is not a leaf" do
      [ "cad/gear.stl", "../outside.stl", "/etc/passwd", "a/../../outside.stl", ".", "..", "" ].each do |bad|
        err = assert_raises(FileLayer::NotFound, "#{bad.inspect} must be refused") do
          adapter.write(@user, parent_node_id: nil, name: bad, io: StringIO.new("x"))
        end
        assert_match(/leaf name/, err.message, bad.inspect)
      end
      assert_equal 0, @fake.calls[:put_object], "refused BEFORE any request left the process"
      assert_equal 0, @fake.calls[:head_object]
      assert_empty @fake.objects
    end

    # THE escape guard, reached the only way it can be: through the PARENT. A separator-free leaf
    # cannot escape once `.`/`..` are refused above, so `name` never gets here.
    #
    # THE WRITE PATH IS NOT THE READ PATH HERE, and the difference was established by mutation
    # rather than assumed. On the READ side, deleting the guard leaves "/etc/passwd" merely
    # composing a key that does not exist, so the read raises NotFound ANYWAY and assert_raises
    # passes while the request goes out over the wire — which is why those tests carry a call
    # count as their entire load. A WRITE to a bogus key SUCCEEDS: with the guard deleted this
    # composes "library/../escaped/pwned.stl", the store accepts it, nothing raises, and the
    # assert_raises above is what fails (verified: it does).
    #
    # The call counts stay regardless, as the stronger claim: refused BEFORE anything left the
    # process. They are what would catch the clobber-check HEAD being ordered ahead of the guard —
    # a request against an escaped key, sent, and no assertion above would notice.
    test "write through a parent whose storage_path escapes the prefix is refused" do
      evil = @user.nodes.create!(node_id: SecureRandom.uuid, name: "evil", kind: "dir",
                                 deleted: false, storage_path: "../escaped", mtime: 1)
      err = assert_raises(FileLayer::NotFound) do
        adapter.write(@user, parent_node_id: evil.node_id, name: "pwned.stl", io: StringIO.new("x"))
      end
      assert_match(/escapes/, err.message)
      assert_equal 0, @fake.calls[:put_object], "refused BEFORE any request left the process"
      assert_equal 0, @fake.calls[:head_object]
      assert_equal 0, @fake.objects.keys.count { |k| !k.start_with?("#{PREFIX}/") },
                   "nothing may be written outside the prefix"
    end

    # NOT IN THE PLAN — added because 2b's structural finding transfers, with one half amputated.
    # S3 has no directories, so a `.trash` object cannot collide with the `.trash/<id>/<name>` keys
    # Task 6's delete writes (Share's EEXIST half does not apply). But Task 7's observer skips the
    # `.trash` prefix, so this upload would leave a live node at a key the scan NEVER observes ->
    # unpairable ghost -> tombstone -> the mass-deletion guard refuses that scan and every scan
    # after it, permanently. One ordinary-looking upload. The lesson 2b paid for four times:
    # assume every path that writes is exposed until you have checked it.
    test "write refuses a reserved path the scan does not index" do
      err = assert_raises(FileLayer::NotFound) do
        adapter.write(@user, parent_node_id: nil, name: Library::Scanner::TRASH_PREFIX,
                      io: StringIO.new("x"))
      end
      assert_match(/reserved/, err.message)
      assert_equal 0, @fake.calls[:put_object]

      # ...and a NESTED .trash is the user's own folder: observed, indexed, none of our business.
      parent = @user.nodes.create!(node_id: SecureRandom.uuid, name: "cad", kind: "dir",
                                   deleted: false, storage_path: "cad", mtime: 1)
      assert_nothing_raised do
        adapter.write(@user, parent_node_id: parent.node_id,
                      name: Library::Scanner::TRASH_PREFIX, io: StringIO.new("mine"))
      end
    end

    # The clobber guard's SECOND half, and the one the fail-safe direction turns on: a HEAD that
    # fails for a reason other than absence must never read as "vacant" and put over the user's
    # file. AccessDenied is the credentials-outage shape that caused the original incident.
    test "a clobber check that fails transiently refuses the write rather than assuming vacant" do
      @fake.fault!(:head_object, "AccessDenied")
      assert_raises(FileLayer::FetchError) do
        adapter.write(@user, parent_node_id: nil, name: "risky.stl", io: StringIO.new("x"))
      end
      assert_equal 0, @fake.calls[:put_object], "a HEAD we could not trust must not be read as vacant"
    end

    test "write refuses an object larger than MAX_BYTES" do
      original = FileLayer::MAX_BYTES
      FileLayer.send(:remove_const, :MAX_BYTES)
      FileLayer.const_set(:MAX_BYTES, 4)
      err = assert_raises(FileLayer::NotFound) do
        adapter.write(@user, parent_node_id: nil, name: "big.stl", io: StringIO.new("hello"))
      end
      assert_match(/exceeds/, err.message)
      assert_equal 0, @fake.calls[:put_object]
    ensure
      FileLayer.send(:remove_const, :MAX_BYTES)
      FileLayer.const_set(:MAX_BYTES, original)
    end

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
