require "test_helper"
require "open-uri"
require_relative "adapter_contract"

module FileLayer
  # The Chunk adapter over the sync engine's content-addressed store: this is today's
  # node -> version -> manifest_chunks -> Storage::ChunkStore read path, moved behind the port.
  class ChunkTest < ActiveSupport::TestCase
    include FileLayerAdapterContract
    # For the mkdir broadcast test below -- same include LibraryChannelTest and
    # ProjectIntakeTest use for assert_broadcast_on/assert_broadcasts.
    include ActionCable::TestHelper

    setup do
      Storage::ChunkStore.reset!
      @user = User.create!(email: "chunk-adapter-#{SecureRandom.hex(4)}@example.com")
      @device = Device.register!(user: @user, name: "t")
    end

    # Instantiated directly, never via FileLayer.current — the adapter is tested in isolation
    # from backend selection (that's factory_test.rb's job), so this suite has no dependency
    # on the factory and can be written before it exists.
    def adapter = FileLayer::Chunk.new

    # The shared contract can only assert these are booleans — every backend answers
    # differently. Chunk's actual values matter: the UI reads them to decide whether to offer
    # Restore/History, so a flipped flag here silently removes a working feature rather than
    # failing loudly.
    test "chunk is the versioned, syncable, presignable backend" do
      caps = adapter.capabilities
      assert caps.versioned?, "chunk mode restores old versions — that's its whole point"
      assert caps.syncable?
      assert caps.presignable?
    end

    # Commit a real file and put its single chunk's bytes in the store. The contract requires
    # the created file to carry a REAL current modification time, so mtime is passed through
    # to the commit in unix NANOSECONDS (the sync engine's convention; nodes.mtime is a bigint
    # of nanos).
    def create_file!(name:, bytes:)
      node_id = SecureRandom.uuid
      hash = Digest::SHA256.hexdigest(bytes)
      Storage::ChunkStore.current.put!(@user.id, hash, bytes)
      cid = SecureRandom.uuid
      Sync::Commit.begin(
        user: @user, device: @device, commit_id: cid, node_id:, parent_node_id: nil,
        name:, base_version_id: nil, size: bytes.bytesize,
        mtime: Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond),
        manifest: [ { "hash" => hash, "offset" => 0, "length" => bytes.bytesize } ]
      )
      Sync::Commit.finalize(user: @user, commit_id: cid)
      node_id
    end

    # A DIRECT-DB FIXTURE FOR "already tombstoned", NOT A MODEL OF ANY DOOR -- and the difference
    # matters more since Task 5. This comment used to say the v1 API sets this tombstone via
    # `Sync::Mutation op "delete"`. It does not, and has not since 50e1193:
    # V1::NodesController#destroy calls Sync::SubtreeDelete.call, and so does FileLayer::Chunk#delete
    # now. Naming the wrong mechanism here was harmless while nothing nearby cared; it is actively
    # misleading now that six tests below exist to enforce SubtreeDelete-never-Mutation as the
    # correct one.
    #
    # The HELPER is still right: it stages tombstoned state cheaply for tests about OTHER verbs
    # (download, and delete-on-an-already-deleted-node). `trash_file!` beside it is the one that
    # goes through a real mutation, for its own stated reason. Versions stay in the DB for restore,
    # which is why read must check the node.
    def delete_file!(node_id)
      @user.nodes.find_by!(node_id:).update!(deleted: true)
    end

    # In chunk mode the web UI's delete and the out-of-band one ARE the same event: both are the
    # tombstone, because the bytes belong to the sync engine and versions are kept regardless
    # (§5). That is why every tombstone here is restorable and #trashed filters nothing —
    # the two hooks coincide on this backend alone, and they must not be collapsed for it.
    def trash_file!(node_id)
      Sync::Mutation.apply(user: @user, node: @user.nodes.find_by!(node_id:),
                           op: "delete") { |n| n.deleted = true }
    end

    # The read path's core loop walks Version#manifest_chunks, which is `.order(:seq)`
    # (app/models/version.rb). NOTHING else asserts that ordering, and getting it wrong corrupts
    # the bytes of EVERY file larger than one chunk — silently, since each chunk is individually
    # valid and hashes fine on its own. Proven by mutation: flipping to `.order(seq: :desc)`
    # passed the entire suite. Chunk-specific rather than a shared-contract test because a
    # manifest is an internal detail of the chunk store — a plain-directory Share adapter has no
    # manifest to order. create_file! always builds a SINGLE-chunk manifest, so this test builds
    # its own two-chunk one with distinct bytes.
    test "read assembles a multi-chunk manifest in seq order" do
      node_id = SecureRandom.uuid
      store = Storage::ChunkStore.current
      first, second = "AAA", "BB"
      h1 = Digest::SHA256.hexdigest(first)
      h2 = Digest::SHA256.hexdigest(second)
      store.put!(@user.id, h1, first)
      store.put!(@user.id, h2, second)
      cid = SecureRandom.uuid
      Sync::Commit.begin(
        user: @user, device: @device, commit_id: cid, node_id:, parent_node_id: nil,
        name: "multi.stl", base_version_id: nil, size: 5,
        mtime: Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond),
        manifest: [
          { "hash" => h1, "offset" => 0, "length" => 3 },
          { "hash" => h2, "offset" => 3, "length" => 2 }
        ]
      )
      Sync::Commit.finalize(user: @user, commit_id: cid)

      # Ordered concatenation, not just "contains both": "AAABB", never "BBAAA".
      assert_equal "AAABB", adapter.read(@user, node_id:)
    end

    # THE ONE CHUNK MUTATION THAT STILL REFUSES OUTRIGHT, AND WHY IT ALWAYS WILL: write does NOT
    # go through this port. Chunk-mode writes are Sync::Commit's two-phase presigned flow (a
    # device pushes; the web UI reuses it), and implementing write here would mean a server-side
    # chunk-and-commit path that duplicates Sync::Commit, has no caller, and reaches into the sync
    # engine this port exists to stay out of (spec §10) -- unlike mkdir/move/delete/undelete,
    # which move no bytes and so have no such argument against them.
    #
    # mkdir (Task 3), move (Task 4), delete (Task 5) and undelete (Task 6) are gone from this test
    # -- the port is their door now, the same as share/s3, and none of the four raises any more.
    test "write is not chunk mode's — it refuses, naming its OWN real path" do
      err = assert_raises(NotImplementedError) do
        adapter.write(@user, parent_node_id: nil, name: "x.stl", io: StringIO.new("b"))
      end
      assert_match(/Sync::Commit/, err.message, "write must name the path a caller should use")
    end

    # --- moved from test/services/maker/{file_bytes_test,file_bytes_edges_test}.rb ---
    # These stub the presigned-GET seam, which now lives on the adapter. If they still stubbed
    # Maker::FileBytes.http_get they would silently no-op once FileBytes becomes a shim.

    # A presign-only store (no read_blob/read) forces the presigned-GET branch.
    class PresignOnlyStore
      def presign_get(_user_id, hash) = "https://example.invalid/#{hash}"
      def presign_put(_user_id, hash) = "https://example.invalid/#{hash}"
    end

    # Swap the HTTP seam for an arbitrary implementation. `with_http_get_raising` is the
    # unconditional case; the download drain tests need a SELECTIVE fault (first chunk fine,
    # second missing) so they can prove the raise happens with bytes already yielded.
    def with_http_get(impl)
      original = FileLayer::Chunk.method(:http_get)
      FileLayer::Chunk.define_singleton_method(:http_get, &impl)
      yield
    ensure
      FileLayer::Chunk.define_singleton_method(:http_get, original)
    end

    def with_http_get_raising(err, &block)
      with_http_get(->(_url) { raise err }, &block)
    end

    def http_error(status)
      io = Struct.new(:status).new([ status.to_s, "Err" ])
      OpenURI::HTTPError.new("#{status} Err", io)
    end

    # Contract hook. Chunk's transient failure: a presign-only store whose GET returns 403 —
    # the exact credentials-outage shape that caused the original incident.
    #
    # `current=` is a global, so it's reset on the way out rather than left for the next
    # test's setup to mop up: the contract calls this hook, and a leaked PresignOnlyStore
    # would surface as an unrelated failure elsewhere in the worker.
    def with_transient_backend_failure(&block)
      Storage::ChunkStore.current = PresignOnlyStore.new
      with_http_get_raising(http_error(403), &block)
    ensure
      Storage::ChunkStore.reset!
    end

    # A REAL Storage::S3ChunkStore — the only store whose presigned URL points OFF-BOX, which is
    # the condition #blob redirects on and #download preserves.
    #
    # REAL rather than a double, and not for purity: the condition under test is literally
    # `store.is_a?(Storage::S3ChunkStore)`, so a stand-in would have to BE one to exercise it.
    #
    # NO NETWORK, and that is a property of the class rather than luck: Aws::S3::Client.new is
    # lazy (it does not connect) and presigning is local HMAC — CLAUDE.md §14, "server presigning
    # is local (HMAC): you can verify chunk URLs are correct without the storage being
    # reachable". Verified against the real SDK, and the endpoint below is unroutable on purpose
    # so a regression that tried to FETCH through it would fail loudly rather than quietly go out
    # to the internet from the suite.
    #
    # NOTE FOR CALLERS: seed the file BEFORE entering this block. S3ChunkStore has no `put!` (only
    # the memory and local stores do — it is a presign-only store by design), so create_file!
    # inside here raises NoMethodError.
    #
    # `current=` is a global, so it is reset on the way out exactly as with_transient_backend_failure
    # does: a leaked S3ChunkStore would surface as an unrelated failure elsewhere in the worker.
    def with_s3_chunk_store
      Storage::ChunkStore.current = Storage::S3ChunkStore.new(
        bucket: "b", region: "us-east-1", access_key_id: "ak", secret_access_key: "sk",
        endpoint: "https://s3.example.invalid"
      )
      yield
    ensure
      Storage::ChunkStore.reset!
    end

    # Contract hook. Chunk presigns on ALL THREE stores, so "give this backend every chance to
    # mint an off-box URL" means handing it the one store whose URLs are not served by Rails.
    alias_method :with_off_box_presigning, :with_s3_chunk_store

    # --- download: #blob's behavior, moved behind the port (Task 2) ------------------------

    # Chunk's delivery is today's stitched-chunk enumerator, unchanged: the bytes come from a
    # presigned GET per chunk (Chunk.fetch), so Rails stitches but never holds the whole file.
    test "download streams the stitched chunks" do
      id = create_file!(name: "s.stl", bytes: "streamed")
      d = adapter.download(@user, node_id: id, disposition: "attachment")
      assert_kind_of FileLayer::Delivery::Stream, d
      assert_equal "streamed", d.enum.to_a.join
    end

    # PRESERVED FROM #blob, exactly. This is NOT the presignable? question — the memory and local
    # stores presign too, but to URLs RAILS ITSELF SERVES, so redirecting to them would move the
    # bytes through Rails via an extra hop. The condition is "does the presigned URL point
    # OFF-BOX", which is a THIRD question, and today only S3ChunkStore answers it yes.
    test "a single-chunk file on real object storage redirects, as blob already did" do
      id = create_file!(name: "one.stl", bytes: "single") # seeded first — see with_s3_chunk_store
      with_s3_chunk_store do
        d = adapter.download(@user, node_id: id, disposition: "attachment")
        assert_kind_of FileLayer::Delivery::Redirect, d
        assert_includes d.url, "X-Amz-Signature", "a signed URL, not a bare object URL"
      end
    end

    # THE OTHER HALF OF THE SAME CONDITION, and it is NOT in the plan — which pinned only the
    # `store.is_a?(S3ChunkStore)` half, leaving `chunks.size == 1` free to be deleted with the
    # whole suite green.
    #
    # What that costs is not a style regression: a multi-chunk file whose download redirects
    # sends the browser to the presigned URL of its FIRST CHUNK ONLY. The user saves a 2GB CAD
    # file and gets the first 4MB of it, named correctly, with a 200 — SILENT TRUNCATION, and on
    # the backend §15 exists for. Verified by mutation: dropping `chunks.size == 1` passes every
    # other test in this file.
    test "a MULTI-chunk file on real object storage streams — it must not redirect to chunk one" do
      node_id = SecureRandom.uuid
      store = Storage::ChunkStore.current
      h1 = Digest::SHA256.hexdigest("AAA")
      h2 = Digest::SHA256.hexdigest("BB")
      store.put!(@user.id, h1, "AAA")
      store.put!(@user.id, h2, "BB")
      cid = SecureRandom.uuid
      Sync::Commit.begin(
        user: @user, device: @device, commit_id: cid, node_id:, parent_node_id: nil,
        name: "multi.stl", base_version_id: nil, size: 5,
        mtime: Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond),
        manifest: [
          { "hash" => h1, "offset" => 0, "length" => 3 },
          { "hash" => h2, "offset" => 3, "length" => 2 }
        ]
      )
      Sync::Commit.finalize(user: @user, commit_id: cid)

      with_s3_chunk_store do
        d = adapter.download(@user, node_id:, disposition: "attachment")
        assert_kind_of FileLayer::Delivery::Stream, d,
                       "redirecting a multi-chunk file serves ONLY its first chunk"
      end
    end

    test "download raises NotFound for a deleted node, exactly as read does" do
      id = create_file!(name: "gone.stl", bytes: "b")
      delete_file!(id)
      assert_raises(FileLayer::NotFound) do
        adapter.download(@user, node_id: id, disposition: "attachment")
      end
    end

    # --- download's FAULT behaviour (D-01) -------------------------------------------------
    #
    # A VALIDATION GAP, NOT A REFACTOR: download's answers to a missing chunk and to a
    # credentials outage were already correct, and entirely unasserted. All five fault tests
    # below, and the shared adapter contract's transient-failure hook, call `read` — `download`
    # was drained only on the happy path, so nothing anywhere pinned what a fault does to a
    # stream that has already started.
    #
    # THE TRAP, and it is the reason these two tests look the way they do: `download` captures
    # `store = Storage::ChunkStore.current` EAGERLY, at the top of the method, OUTSIDE the
    # Enumerator. Install THE STORE after calling `adapter.download` and the enumerator has
    # already closed over the ORIGINAL — it drains clean and nothing raises (probed exactly
    # that way first: the drain returned "streamed" with an http_get stubbed to raise
    # unconditionally, which was never reached). SO THE STORE MUST BE SWAPPED BEFORE
    # `adapter.download` IS CALLED. §14e's "the suite being green is not evidence a guard
    # works if the guard's precondition is never established in test", one layer down.
    #
    # PRECISELY THE STORE, AND ONLY THE STORE. An earlier version of this comment said "the
    # fault", which bundles two things that do not behave alike: `http_get` is a class method
    # RESOLVED AT CALL TIME inside the enumerator, so stubbing it afterwards still fires —
    # verified in review by driving both halves separately. Only the eager capture is
    # order-sensitive. The imperative was on the right line; the sentence was wider than the
    # mechanism, which is how a reader ends up defending against the wrong thing.
    #
    # These live here and NOT in adapter_contract.rb: `Delivery::Stream` is chunk-only (share
    # answers `SendFile`, s3 answers `Redirect`), so there is no cross-backend drain to share.

    # Two chunks, and the SECOND one is the one that vanishes — so the raise happens with the
    # first chunk's bytes already yielded, which is the condition download's own comment names:
    # "by here the response has already begun, so quiet corruption is the one outcome worth
    # refusing". Without the raise, `y << nil` yields nil into the stream and the drain joins to
    # a SHORT FILE with a hole in it, 200 and correctly named.
    test "a chunk that vanishes MID-DRAIN raises NotFound rather than streaming a hole" do
      node_id = SecureRandom.uuid
      store = Storage::ChunkStore.current
      h1 = Digest::SHA256.hexdigest("AAA")
      h2 = Digest::SHA256.hexdigest("BB")
      store.put!(@user.id, h1, "AAA")
      store.put!(@user.id, h2, "BB")
      cid = SecureRandom.uuid
      Sync::Commit.begin(
        user: @user, device: @device, commit_id: cid, node_id:, parent_node_id: nil,
        name: "holed.stl", base_version_id: nil, size: 5,
        mtime: Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond),
        manifest: [
          { "hash" => h1, "offset" => 0, "length" => 3 },
          { "hash" => h2, "offset" => 3, "length" => 2 }
        ]
      )
      Sync::Commit.finalize(user: @user, commit_id: cid)

      # BEFORE the download call — see THE TRAP above.
      Storage::ChunkStore.current = PresignOnlyStore.new
      # PresignOnlyStore signs "https://example.invalid/<hash>", so the URL names the chunk.
      # The error is built HERE, not inside the lambda: define_singleton_method rebinds `self`
      # to FileLayer::Chunk, so a test helper called from inside the body is a NoMethodError.
      # Closed-over locals are unaffected, which is how `with_http_get_raising` gets away with it.
      missing = http_error(404)
      serve = ->(url) { url.end_with?(h2) ? raise(missing) : "AAA" }
      with_http_get(serve) do
        d = adapter.download(@user, node_id:, disposition: "attachment")
        assert_kind_of FileLayer::Delivery::Stream, d
        assert_raises(FileLayer::NotFound) { d.enum.to_a }
      end
    end

    # The terminal/retryable split §14a draws for `read` binds on `download` too, and for the
    # same reason: a credentials outage is a 503 the user retries, not a 404 that says their
    # file is permanently gone. 403 is the exact shape of the original incident.
    test "a 403 mid-drain is TRANSIENT on download too (FetchError, not NotFound)" do
      id = create_file!(name: "creds.stl", bytes: "secret")
      Storage::ChunkStore.current = PresignOnlyStore.new # BEFORE the download call
      with_http_get_raising(http_error(403)) do
        d = adapter.download(@user, node_id: id, disposition: "attachment")
        assert_raises(FileLayer::FetchError) { d.enum.to_a }
      end
    end

    test "a 404 on the presigned GET is a missing chunk (terminal NotFound)" do
      id = create_file!(name: "e.stl", bytes: "gone")
      Storage::ChunkStore.current = PresignOnlyStore.new
      with_http_get_raising(http_error(404)) do
        assert_raises(FileLayer::NotFound) { adapter.read(@user, node_id: id) }
      end
    end

    test "a 403 on the presigned GET is TRANSIENT (FetchError, not NotFound)" do
      id = create_file!(name: "f.stl", bytes: "creds")
      Storage::ChunkStore.current = PresignOnlyStore.new
      with_http_get_raising(http_error(403)) do
        assert_raises(FileLayer::FetchError) { adapter.read(@user, node_id: id) }
      end
    end

    test "a 5xx on the presigned GET is TRANSIENT" do
      id = create_file!(name: "g.stl", bytes: "boom")
      Storage::ChunkStore.current = PresignOnlyStore.new
      with_http_get_raising(http_error(500)) do
        assert_raises(FileLayer::FetchError) { adapter.read(@user, node_id: id) }
      end
    end

    test "a network error on the presigned GET is TRANSIENT" do
      id = create_file!(name: "h.stl", bytes: "net")
      Storage::ChunkStore.current = PresignOnlyStore.new
      with_http_get_raising(SocketError.new("no dns")) do
        assert_raises(FileLayer::FetchError) { adapter.read(@user, node_id: id) }
      end
    end

    test "a timeout on the presigned GET is TRANSIENT" do
      id = create_file!(name: "i.stl", bytes: "slow")
      Storage::ChunkStore.current = PresignOnlyStore.new
      with_http_get_raising(Net::ReadTimeout.new) do
        assert_raises(FileLayer::FetchError) { adapter.read(@user, node_id: id) }
      end
    end

    test "a committed version whose chunk bytes were never stored is NotFound" do
      node_id = SecureRandom.uuid
      hash = Digest::SHA256.hexdigest("never-stored")
      cid = SecureRandom.uuid
      Sync::Commit.begin(
        user: @user, device: @device, commit_id: cid, node_id:, parent_node_id: nil,
        name: "phantom.stl", base_version_id: nil, size: 12,
        mtime: Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond),
        manifest: [ { "hash" => hash, "offset" => 0, "length" => 12 } ]
      )
      Sync::Commit.finalize(user: @user, commit_id: cid)
      assert_raises(FileLayer::NotFound) { adapter.read(@user, node_id:) }
    end

    test "reading with no content_token returns the CURRENT version" do
      id = create_file!(name: "j.stl", bytes: "first")
      first_token = adapter.stat(@user, node_id: id).content_token

      hash = Digest::SHA256.hexdigest("second")
      Storage::ChunkStore.current.put!(@user.id, hash, "second")
      cid = SecureRandom.uuid
      Sync::Commit.begin(
        user: @user, device: @device, commit_id: cid, node_id: id, parent_node_id: nil,
        name: "j.stl", base_version_id: first_token, size: 6,
        mtime: Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond),
        manifest: [ { "hash" => hash, "offset" => 0, "length" => 6 } ]
      )
      Sync::Commit.finalize(user: @user, commit_id: cid)

      assert_equal "second", adapter.read(@user, node_id: id)
      # chunk mode is the versioned backend: an OLD token still resolves. (Not a contract
      # test — share/S3 keep no history.)
      assert_equal "first", adapter.read(@user, node_id: id, content_token: first_token)
    end

    # --- additional coverage found while auditing file_bytes_edges_test.rb for completeness ---
    # These two cases (MAX_BYTES cap, cross-user isolation) are real behavior in
    # FileLayer::Chunk#read (MAX_BYTES is a FileLayer-module-level constant used identically to
    # Maker::FileBytes::MAX_BYTES; user-scoped `user.versions`/`user.nodes` lookups are the whole
    # tenant-isolation mechanism per CLAUDE.md §8) but were NOT in the task's given list of 7
    # tests to move. Dropping them when file_bytes_edges_test.rb is deleted would silently lose
    # coverage of a host-protection cap and a cross-tenant-read guard, so they're ported here too.

    test "exceeding MAX_BYTES raises NotFound (host-protection cap)" do
      # Two oversized chunks so the running buffer trips MAX_BYTES on the second.
      half = FileLayer::MAX_BYTES / 2 + 1
      store = Storage::ChunkStore.current
      hash1 = SecureRandom.hex(32)
      hash2 = SecureRandom.hex(32)
      store.put!(@user.id, hash1, "a" * half)
      store.put!(@user.id, hash2, "b" * half)
      node_id = SecureRandom.uuid
      cid = SecureRandom.uuid
      Sync::Commit.begin(
        user: @user, device: @device, commit_id: cid, node_id:, parent_node_id: nil,
        name: "big.stl", base_version_id: nil, size: half * 2,
        mtime: Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond),
        manifest: [
          { "hash" => hash1, "offset" => 0, "length" => half },
          { "hash" => hash2, "offset" => half, "length" => half }
        ]
      )
      Sync::Commit.finalize(user: @user, commit_id: cid)

      assert_raises(FileLayer::NotFound) { adapter.read(@user, node_id:) }
    end

    test "a user cannot read ANOTHER user's version by node_id+content_token" do
      other = User.create!(email: "chunk-adapter-other-#{SecureRandom.hex(4)}@example.com")
      other_device = Device.register!(user: other, name: "t2")
      node_id = SecureRandom.uuid
      hash = Digest::SHA256.hexdigest("secret")
      Storage::ChunkStore.current.put!(other.id, hash, "secret")
      cid = SecureRandom.uuid
      Sync::Commit.begin(
        user: other, device: other_device, commit_id: cid, node_id:, parent_node_id: nil,
        name: "secret.stl", base_version_id: nil, size: 6,
        mtime: Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond),
        manifest: [ { "hash" => hash, "offset" => 0, "length" => 6 } ]
      )
      other_version, = Sync::Commit.finalize(user: other, commit_id: cid)

      # @user owns a LIVE node with the SAME node_id. `node_id` uniqueness is scoped to
      # :user_id and node_id is client-supplied, so a user genuinely CAN hold a node carrying
      # another user's node_id — this is the real attack shape. It is also what gets the
      # request PAST read's liveness guard and into the version lookup, which is the line
      # under test: without it, live_node! short-circuits and this test proves nothing about
      # tenant scoping (verified by mutation — see below).
      own_hash = Digest::SHA256.hexdigest("mine")
      Storage::ChunkStore.current.put!(@user.id, own_hash, "mine")
      own_cid = SecureRandom.uuid
      Sync::Commit.begin(
        user: @user, device: @device, commit_id: own_cid, node_id:, parent_node_id: nil,
        name: "mine.stl", base_version_id: nil, size: 4,
        mtime: Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond),
        manifest: [ { "hash" => own_hash, "offset" => 0, "length" => 4 } ]
      )
      Sync::Commit.finalize(user: @user, commit_id: own_cid)

      # @user asking for other's node_id+content_token => no row in @user's scope => NotFound,
      # no bytes leak.
      #
      # Assert the MESSAGE, not just the class — this is the part that actually bites. Drop the
      # `user.` scope and read resolves OTHER's version, then fails a step later anyway with
      # NotFound "missing chunk", because the chunk store is namespaced per user
      # (chunks/<user_id>/<hash>) and the bytes aren't in @user's keyspace. Same exception class,
      # entirely different reason, tenant scoping gone. assert_raises alone cannot tell those
      # apart and stays green on the unscoped mutant; only the message does.
      err = assert_raises(FileLayer::NotFound) do
        adapter.read(@user, node_id:, content_token: other_version.version_id)
      end
      assert_match(/no version/, err.message,
                   "must fail because the version isn't in @user's scope, not incidentally")
      # And @user's OWN bytes at that node are still readable — the guard rejects the foreign
      # token, not the node.
      assert_equal "mine", adapter.read(@user, node_id:)
    end

    # The port is now the door for chunk-mode mkdir, not a refusal that names another door.
    # Maker::LibraryFolder used to branch around it into Sync::Mutation; it no longer can,
    # because in remote mode there is no Sync::Mutation in the process to branch into.
    test "mkdir creates a dir node through the sync engine and returns its FileInfo" do
      info = adapter.mkdir(@user, parent_node_id: nil, name: "cad")
      assert_equal "dir",  info.kind
      assert_equal "cad",  info.name
      node = @user.nodes.present.find_by(node_id: info.node_id)
      assert_equal "dir", node.kind
    end

    # A mutation that does not broadcast leaves every device's tree diverged from the server's,
    # silently -- pull is incremental, so nothing anywhere reports it. Asserted on the CHANGELOG
    # rather than by stubbing the broadcast: the changelog entry is what a device actually reads,
    # and a test that stubs LibraryChannel proves only that we called our own method.
    #
    # THE head_seq ASSERTION ALONE CANNOT CATCH A MISSING BROADCAST, AND IT DID NOT: mutation-
    # checked by deleting Chunk#mkdir's `LibraryChannel.broadcast_change(user, seq)` line, this
    # test (with only the assert_operator below) stayed GREEN -- head_seq is advanced by
    # Sync::Mutation.apply, not by the broadcast, so the two facts are independent and asserting
    # one says nothing about the other. That is a guard that cannot fail for the reason it
    # exists, which CLAUDE.md 15 says is no guard at all. assert_broadcast_on is what closes it:
    # it listens on the real stream a device subscribes to (LibraryChannel.broadcasting_for),
    # the same helper LibraryChannelTest and ProjectIntakeTest already use, so this is the
    # established idiom here rather than a one-off. The exact payload is asserted, not just a
    # count -- User#next_seq! is `head_seq + 1` under a row lock (app/models/user.rb), so a
    # single mkdir on a fresh @user with no concurrent activity must broadcast EXACTLY
    # `head_seq: before + 1`; a broadcast carrying a stale or fabricated seq would pass a bare
    # count check and still diverge a device.
    test "mkdir appends a changelog entry so devices converge" do
      before = @user.reload.head_seq
      assert_broadcast_on(LibraryChannel.broadcasting_for(@user), head_seq: before + 1) do
        adapter.mkdir(@user, parent_node_id: nil, name: "cad")
      end
      assert_operator @user.reload.head_seq, :>, before, "mkdir must advance head_seq"
    end

    test "mkdir is idempotent -- LibraryFolder walks each path segment on every call" do
      first  = adapter.mkdir(@user, parent_node_id: nil, name: "cad")
      second = adapter.mkdir(@user, parent_node_id: nil, name: "cad")
      assert_equal first.node_id, second.node_id
    end

    # A DIRECT TEST HERE, NOT ONLY THE CONTRACT VERSION, because ChunkTest does not include
    # FileLayerMutationContract yet -- Task 7 wires it in, and until then a contract-only test
    # would prove nothing about this adapter. Same case as adapter_mutation_contract.rb's
    # test_mutation_contract_mkdir_refuses_a_cross_kind_collision, which passes unmodified against
    # Share and S3 (both already refuse, independently -- verified before writing this).
    #
    # mkdir's own idempotence check above is scoped `kind: "dir"`, so it is BLIND to a live FILE
    # at this exact (parent_node_id, name) -- without this refusal, chunk mode would silently mint
    # a dir node and a file node sharing one identity, and no real filesystem can represent that as
    # a single directory entry: every mount (FUSE/CfAPI/WebDAV) eventually hits it as an
    # unrepresentable collision. This is CLAUDE.md 14a's one-condition-two-answers shape --
    # "the destination is taken" must mean the same thing on every backend behind one port call --
    # and it was reachable through the exact call the New Folder chooser makes
    # (Maker::LibraryFolder.create_child!), not just a hypothetical.
    test "mkdir refuses a cross-kind collision -- a live FILE at the same (parent, name)" do
      create_file!(name: "mover.stl", bytes: "b")
      err = assert_raises(FileLayer::UnsupportedOperation) do
        adapter.mkdir(@user, parent_node_id: nil, name: "mover.stl")
      end
      assert_match(/mover\.stl/, err.message, "the message should name the colliding file")

      # THE FILE MUST SURVIVE THE REFUSAL, untouched -- a refused mkdir is not a partial write.
      # Two live nodes at one (parent, name) is exactly the corruption this test exists to
      # prevent, so it must not exist on EITHER side of the raise.
      file_node = @user.nodes.present.find_by!(parent_node_id: nil, name: "mover.stl")
      assert_equal "file", file_node.kind
      assert_equal 1, @user.nodes.present.where(parent_node_id: nil, name: "mover.stl").count,
                   "the refusal must not have created a second, colliding node"
    end

    # PINS THE SCOPE OF THAT REFUSAL, WHICH THE TEST ABOVE DOES NOT. The lookup is deliberately
    # written WITHOUT a `kind:` -- it refuses ANY live node at that (parent_node_id, name) -- but
    # every test of it seeded a FILE, so narrowing it to `kind: "file"` was a mutation the whole
    # suite waved through: 1056 runs, 0 failures. The code was more correct than its coverage
    # proved, which is the §15 shape ("a guard that has never failed has not been shown to work")
    # and exactly how a scope silently shrinks back during a later tidy-up.
    #
    # SYMLINK is the third of Node::KINDS and is not hypothetical: `client/fs-provider` syncs
    # symlink targets so git-on-mount works (docs/git-on-mount.md), and V1::NodesController#symlink
    # mints these through the real device API. A dir node sharing one identity with a symlink node
    # is the same unrepresentable collision as with a file, one kind over.
    #
    # Built with nodes.create! rather than through a door, because there is no PORT verb that
    # makes a symlink -- the sync engine's own #symlink is the only maker, and this test is about
    # what mkdir REFUSES, not about how the occupant arrived.
    # CHUNK ALLOWS A DIRECTORY MOVE, AND THIS IS WHAT EARNS THAT CLAIM. Share earns its own with
    # an explicit probe ("2/2 children re-homed, no ghosts"); chunk asserted it only by having no
    # kind check at all, which is a claim nothing exercised.
    #
    # WHY A SINGLE-ROW Sync::Mutation IS ENOUGH HERE, WHEN delete NEEDS SubtreeDelete'S CASCADE:
    # a node's POSITION is defined by descendants POINTING AT its node_id, which the move does not
    # touch -- there is no redundant path string on a child to go stale (chunk nodes carry a NULL
    # storage_path; that column is share/s3's). `deleted` is the opposite: a per-row FLAG that the
    # graph does not imply, so it has to be written onto every descendant explicitly. Same tree,
    # two different kinds of fact, which is why the two verbs delegate to two different services.
    # Get this backwards and a dir delete orphans its subtree -- §14a's sharpest recorded trap.
    test "move re-homes a DIRECTORY without disturbing its subtree" do
      dir   = @user.nodes.create!(node_id: SecureRandom.uuid, parent_node_id: nil, name: "old",
                                  kind: "dir", deleted: false, mtime: 0)
      child = @user.nodes.create!(node_id: SecureRandom.uuid, parent_node_id: dir.node_id,
                                  name: "kid.stl", kind: "file", deleted: false, mtime: 0)
      grandkid_dir = @user.nodes.create!(node_id: SecureRandom.uuid, parent_node_id: dir.node_id,
                                         name: "nested", kind: "dir", deleted: false, mtime: 0)
      grandkid = @user.nodes.create!(node_id: SecureRandom.uuid, parent_node_id: grandkid_dir.node_id,
                                     name: "deep.stl", kind: "file", deleted: false, mtime: 0)

      info = adapter.move(@user, node_id: dir.node_id, new_parent_node_id: nil, new_name: "new")

      assert_equal "new", info.name
      assert_equal "dir", info.kind
      # EVERY DESCENDANT STILL LIVE AND STILL POINTING WHERE IT WAS. A cascade that re-wrote them
      # would be the bug, not the fix: their parent pointers are already correct by construction.
      [ child, grandkid_dir, grandkid ].each do |n|
        assert_not n.reload.deleted, "#{n.name} must survive its ancestor's move"
      end
      assert_equal dir.node_id,          child.reload.parent_node_id
      assert_equal dir.node_id,          grandkid_dir.reload.parent_node_id
      assert_equal grandkid_dir.node_id, grandkid.reload.parent_node_id
    end

    test "mkdir refuses a cross-kind collision -- a live SYMLINK too, not just a file" do
      @user.nodes.create!(node_id: SecureRandom.uuid, parent_node_id: nil, name: "link",
                          kind: "symlink", deleted: false, mtime: 0,
                          symlink_target: "target.stl")
      err = assert_raises(FileLayer::UnsupportedOperation) do
        adapter.mkdir(@user, parent_node_id: nil, name: "link")
      end
      assert_match(/symlink/, err.message,
                   "the message must name the colliding KIND, so a caller is not told 'file'")
      assert_equal 1, @user.nodes.present.where(parent_node_id: nil, name: "link").count
    end

    # The port is now the door for chunk-mode move too (Task 4). Maker::MoveNode used to branch
    # around it into Sync::Mutation directly; it no longer can, for the same reason mkdir's own
    # comment gives -- in remote mode there is no Sync::Mutation in this process to branch into.
    test "move renames a node through the sync engine and returns its post-move FileInfo" do
      node = @user.nodes.create!(node_id: SecureRandom.uuid, name: "before.stl", kind: "file",
                                 deleted: false, mtime: 0)
      info = adapter.move(@user, node_id: node.node_id, new_parent_node_id: nil,
                          new_name: "after.stl")
      assert_equal "after.stl",  info.name
      assert_equal node.node_id, info.node_id, "a move must preserve node_id"
      assert_equal "after.stl",  node.reload.name
    end

    # ASSERTED ON THE BROADCAST ITSELF, not on head_seq -- Task 3 proved the head_seq spelling
    # cannot fail for the reason it exists: Sync::Mutation advances head_seq whether or not
    # anything broadcasts, so the head_seq spelling alone stays GREEN when the broadcast is
    # deleted. The EXACT payload also catches a broadcast carrying a stale seq, which a bare
    # count would not.
    test "move broadcasts the new head_seq so devices converge" do
      node = @user.nodes.create!(node_id: SecureRandom.uuid, name: "before.stl", kind: "file",
                                 deleted: false, mtime: 0)
      expected = @user.reload.head_seq + 1
      assert_broadcast_on(LibraryChannel.broadcasting_for(@user), head_seq: expected) do
        adapter.move(@user, node_id: node.node_id, new_parent_node_id: nil, new_name: "after.stl")
      end
    end

    # A DIRECT TEST HERE, NOT ONLY THE CONTRACT VERSION, because ChunkTest does not include
    # FileLayerMutationContract yet -- Task 7 wires it in, and until then a contract-only test
    # would prove nothing about this adapter. Same precedent as the mkdir cross-kind tests above,
    # and the same reason: Sync::Mutation performs no name check at all, so without this refusal
    # chunk would silently produce two live nodes sharing one (parent_node_id, name) -- the same
    # collision mkdir already refuses, one verb over.
    test "move refuses a taken destination -- a live node already at (parent, name)" do
      a = create_file!(name: "a.stl", bytes: "aaa")
      create_file!(name: "b.stl", bytes: "bbb")

      err = assert_raises(FileLayer::UnsupportedOperation) do
        adapter.move(@user, node_id: a, new_parent_node_id: nil, new_name: "b.stl")
      end
      assert_match(/b\.stl/, err.message, "the message should name the colliding file")

      # Neither file may have moved -- a refused move must not be a partial write.
      assert_equal "aaa", adapter.read(@user, node_id: a)
    end

    # PINS THE SCOPE OF THAT REFUSAL, WHICH THE TEST ABOVE DOES NOT: the clobber lookup must
    # EXCLUDE the node being moved itself, or a no-op move (same folder, same name -- the common
    # case of re-submitting an unchanged rename form) collides with its own destination. Mirrors
    # Maker::MoveNode.collision?'s except_node_id: parameter and the "moving a node onto its own
    # current name in its own folder is not a collision" case in move_node_test.rb.
    test "moving a node onto its own current name is not a collision" do
      id = create_file!(name: "a.stl", bytes: "aaa")

      info = adapter.move(@user, node_id: id, new_parent_node_id: nil, new_name: "a.stl")

      assert_equal "a.stl", info.name
      assert_equal "aaa", adapter.read(@user, node_id: id)
    end

    # --- delete (Task 5): the port is now the door for chunk-mode delete too -------------------
    # FilesController#destroy used to branch around the port straight into Sync::SubtreeDelete.call
    # for chunk mode; it no longer can, same reason mkdir's and move's own comments give -- in
    # remote mode there is no Sync::SubtreeDelete in this process to branch into.
    #
    # A DIRECT TEST HERE, NOT ONLY THE CONTRACT VERSION, because ChunkTest does not include
    # FileLayerMutationContract yet -- Task 7 wires it in, and until then a contract-only test would
    # prove nothing about this adapter. Same precedent as the mkdir/move tests above.
    #
    # THIS ALSO SUBSUMES adapter_mutation_contract.rb's
    # test_mutation_contract_delete_tombstones_rather_than_destroying, whose two assertions --
    # the row survives tombstoned, and read raises NotFound afterward -- are exactly the two lines
    # below. No separate chunk-specific copy of that fact is added for it; when Task 7 wires the
    # shared module in, it will simply re-confirm the same thing through the shared helpers.
    test "delete tombstones the node through the sync engine" do
      node = @user.nodes.create!(node_id: SecureRandom.uuid, name: "gone.stl", kind: "file",
                                 deleted: false, mtime: 0)
      adapter.delete(@user, node_id: node.node_id)
      assert_predicate node.reload, :deleted?
      assert_raises(FileLayer::NotFound) { adapter.read(@user, node_id: node.node_id) }
    end

    # SubtreeDelete, NEVER Sync::Mutation.apply(op: "delete"). The latter tombstones only the node
    # it is handed, so on a directory it orphans every descendant: /v1/tree serves children
    # pointing at a deleted parent while changelog-following devices drop the whole subtree. This
    # is the sharpest trap in CLAUDE.md 14a and the reason chunk answers dir_deletable true.
    #
    # ALSO SUBSUMES the dir_deletable-true half of
    # test_mutation_contract_delete_refuses_a_directory_unless_dir_deletable, which only checks
    # that the directory ITSELF tombstones -- it seeds no child, so it cannot see a cascade bug
    # (or its absence). This is the stronger claim, and the one this task is actually about, so no
    # separate weaker copy is added beside it.
    test "delete CASCADES to the subtree -- the reason chunk is dir_deletable" do
      dir   = @user.nodes.create!(node_id: SecureRandom.uuid, name: "adir", kind: "dir",
                                  deleted: false, mtime: 0)
      child = @user.nodes.create!(node_id: SecureRandom.uuid, parent_node_id: dir.node_id,
                                  name: "kid.stl", kind: "file", deleted: false, mtime: 0)
      adapter.delete(@user, node_id: dir.node_id)
      assert_predicate dir.reload,   :deleted?
      assert_predicate child.reload, :deleted?, "a dir delete must cascade, never orphan children"
    end

    # A ONE-LEVEL CASCADE CAN BE SATISFIED BY AN IMPLEMENTATION THAT ONLY WALKS ONE LEVEL DEEP --
    # the test above alone cannot tell "recurses fully" from "tombstones its immediate children
    # only". Same shape as Task 4's dir-move test, which used a grandchild for the identical
    # reason. Nesting a DIRECTORY (not just a file) one level down also proves SubtreeDelete
    # cascades through an intermediate directory, not only into leaf files.
    test "delete cascades through a NESTED directory, not just one level" do
      dir          = @user.nodes.create!(node_id: SecureRandom.uuid, name: "top", kind: "dir",
                                         deleted: false, mtime: 0)
      child        = @user.nodes.create!(node_id: SecureRandom.uuid, parent_node_id: dir.node_id,
                                         name: "kid.stl", kind: "file", deleted: false, mtime: 0)
      grandkid_dir = @user.nodes.create!(node_id: SecureRandom.uuid, parent_node_id: dir.node_id,
                                         name: "nested", kind: "dir", deleted: false, mtime: 0)
      grandkid     = @user.nodes.create!(node_id: SecureRandom.uuid,
                                         parent_node_id: grandkid_dir.node_id,
                                         name: "deep.stl", kind: "file", deleted: false, mtime: 0)

      adapter.delete(@user, node_id: dir.node_id)

      [ dir, child, grandkid_dir, grandkid ].each do |n|
        assert_predicate n.reload, :deleted?, "#{n.name} must not survive its ancestor's delete"
      end
    end

    # ASSERTED ON THE BROADCAST ITSELF, not on head_seq -- same reasoning as mkdir's and move's
    # broadcast tests above: Sync::SubtreeDelete advances head_seq under next_seq! regardless of
    # whether anything broadcasts, so a head_seq-only assertion cannot fail for the reason it
    # exists (mutation-checked -- see the task report).
    test "delete broadcasts the new head_seq for a childless file" do
      node = @user.nodes.create!(node_id: SecureRandom.uuid, name: "solo.stl", kind: "file",
                                 deleted: false, mtime: 0)
      expected = @user.reload.head_seq + 1
      assert_broadcast_on(LibraryChannel.broadcasting_for(@user), head_seq: expected) do
        adapter.delete(@user, node_id: node.node_id)
      end
    end

    # THE CASCADE'S SEQ COST IS ONE PER NODE, NOT ONE FOR THE WHOLE SUBTREE -- read from
    # Sync::SubtreeDelete.call rather than assumed. It takes `first_seq = user.next_seq!` once,
    # then calls `next_seq!` again for every subsequent target, writing one changelog `delete`
    # entry per node, and returns the LAST seq it minted. A dir plus one child therefore consumes
    # TWO seqs, and the broadcast must carry the SECOND (last) one -- a nudge with the wrong seq
    # would under- or over-state head_seq to a device pulling since its own cursor.
    test "delete of a directory with one child broadcasts the LAST of the two seqs it mints" do
      dir   = @user.nodes.create!(node_id: SecureRandom.uuid, name: "bdir", kind: "dir",
                                  deleted: false, mtime: 0)
      child = @user.nodes.create!(node_id: SecureRandom.uuid, parent_node_id: dir.node_id,
                                  name: "kid.stl", kind: "file", deleted: false, mtime: 0)
      before = @user.reload.head_seq
      assert_broadcast_on(LibraryChannel.broadcasting_for(@user), head_seq: before + 2) do
        adapter.delete(@user, node_id: dir.node_id)
      end
      assert_equal before + 2, @user.reload.head_seq, "one seq per node -- dir plus one child"
    end

    # THE LIVENESS GUARD delete MUST APPLY, MATCHING read/download/stat (see "download raises
    # NotFound for a deleted node, exactly as read does" above). Without it, a caller could hand
    # delete a node_id that is ALREADY tombstoned and it would silently re-tombstone -- a second
    # changelog `delete` entry and a second broadcast, for a node already gone -- rather than
    # reporting the honest "it's already gone". Mutation-checked: this is the one assertion in the
    # file that catches live_node! being skipped in favor of a bare find (see the task report).
    test "delete on an already-deleted node raises NotFound, matching read and download" do
      id = create_file!(name: "twice.stl", bytes: "b")
      delete_file!(id)
      assert_raises(FileLayer::NotFound) { adapter.delete(@user, node_id: id) }
    end

    # --- undelete (Task 6): the port is now the door for chunk-mode undelete too, the fourth and
    # last metadata verb. TrashController used to branch on port_writable? and call
    # Sync::Trash.restore directly for chunk mode; it no longer can, same reason mkdir/move/
    # delete's own comments give -- in remote mode there is no Sync::Trash in this process to
    # branch into. --------------------------------------------------------------------------

    # NODE_ID SURVIVES THE REVIVE -- every attachment, BOM link and tag is keyed on it, so a
    # revive that minted a new identity would silently orphan all three. Sync::Trash.restore never
    # creates a new row (it un-tombstones the existing one), so this really pins that undelete
    # does not wrap it in anything that does.
    #
    # THE RETURNED FileInfo IS THE PORT'S CONTRACT HERE, NOT delete's nil -- delete changes no
    # field FileInfo exposes, so its nil costs nothing; undelete can silently reparent a node to
    # the root (see the orphan test below), and TrashController's flash reads info.name straight
    # off this return value. Asserting node_id AND name means a stub returning nil would
    # NoMethodError the moment either is touched -- the return value is pinned, not just produced.
    test "undelete revives a tombstoned node, keeps its node_id, and returns its FileInfo" do
      id = create_file!(name: "revive.stl", bytes: "b")
      delete_file!(id)

      info = adapter.undelete(@user, node_id: id)

      assert_equal id,           info.node_id, "node_id must survive -- everything keys on it"
      assert_equal "revive.stl", info.name
      node = @user.nodes.present.find_by(node_id: id)
      assert node, "the node must be present (live) again"
      assert_not node.deleted
    end

    # AN ORPHAN COMES BACK AT THE ROOT RATHER THAN RAISING -- to_root: true, matching what
    # TrashController has always passed on the chunk branch. Built the way a user actually reaches
    # this now that Task 5 landed cascading delete, NOT by hand-tombstoning a parent: a directory
    # delete tombstones its whole subtree (Sync::SubtreeDelete), so a child's PARENT ends up ALSO
    # tombstoned as a side effect of one ordinary folder delete.
    test "an orphan, its parent tombstoned by a cascading delete, comes back at the root" do
      dir   = @user.nodes.create!(node_id: SecureRandom.uuid, name: "adir", kind: "dir",
                                  deleted: false, mtime: 0)
      child = @user.nodes.create!(node_id: SecureRandom.uuid, parent_node_id: dir.node_id,
                                  name: "kid.stl", kind: "file", deleted: false, mtime: 0)
      adapter.delete(@user, node_id: dir.node_id) # cascades -- dir AND child are now tombstoned

      info = adapter.undelete(@user, node_id: child.node_id)

      assert_equal "kid.stl", info.name
      assert_nil child.reload.parent_node_id, "an orphan is reparented to the root, not raised on"
      assert_not child.deleted
    end

    # RESTORE ORDER IS NOT COMMUTATIVE, AND TASK 5'S CASCADE MADE THAT MAINLINE RATHER THAN A RARE
    # HAND-CRAFTED EDGE CASE -- see the orphan test above and Chunk#undelete's own comment for the
    # full argument. Restoring the CHILD first permanently nulls its parent_node_id; restoring the
    # PARENT afterward does not reunite them, because nothing about reviving the parent touches a
    # child it no longer points at. THIS IS THE DOCUMENTED BEHAVIOUR, NOT A BUG: top-down restore
    # (parent, then children) preserves structure, and V1::TrashController deliberately exposes
    # to_root as a caller choice (defaulting to a 409) for exactly this reason. Named so a future
    # reader sees a scattered folder as the known trade-off it is, not a regression to "fix" by
    # teaching undelete to re-parent a revived child onto a since-revived parent.
    test "restoring a child before its tombstoned parent scatters it -- documented, not a bug" do
      dir   = @user.nodes.create!(node_id: SecureRandom.uuid, name: "bdir", kind: "dir",
                                  deleted: false, mtime: 0)
      child = @user.nodes.create!(node_id: SecureRandom.uuid, parent_node_id: dir.node_id,
                                  name: "kid.stl", kind: "file", deleted: false, mtime: 0)
      adapter.delete(@user, node_id: dir.node_id) # cascades

      adapter.undelete(@user, node_id: child.node_id) # child first -- reparented to root
      adapter.undelete(@user, node_id: dir.node_id)   # parent second -- back, but too late to help

      assert_nil dir.reload.parent_node_id # was already root-level -- unaffected either way
      assert_nil child.reload.parent_node_id,
                 "restoring the parent after must not reunite them -- order is not commutative"
    end

    # ASSERTED ON THE BROADCAST ITSELF, not on head_seq -- same reasoning as mkdir/move/delete's
    # own broadcast tests above: Sync::Mutation.apply advances head_seq under next_seq! whether or
    # not anything broadcasts, so a head_seq-only assertion cannot fail for the reason it exists.
    #
    # THE EXPECTED SEQ, READ FROM Sync::Trash.restore RATHER THAN ASSUMED: for a node whose parent
    # is not itself deleted (this one has none), `orphaned` is false, so restore calls
    # Sync::Mutation.apply(op: "put", ...) EXACTLY ONCE -- the same single-mutation shape as mkdir
    # and move, not delete's per-node cascade. One call means one next_seq!, so a lone undelete on
    # a fresh @user must broadcast exactly `head_seq: before + 1`.
    test "undelete broadcasts the new head_seq so devices converge" do
      id = create_file!(name: "bcast.stl", bytes: "b")
      delete_file!(id)
      expected = @user.reload.head_seq + 1
      assert_broadcast_on(LibraryChannel.broadcasting_for(@user), head_seq: expected) do
        adapter.undelete(@user, node_id: id)
      end
    end

    # THE `if seq` GUARD IN Chunk#undelete, PINNED DIRECTLY: Sync::Trash.restore returns
    # [node, nil] for a node that is not actually deleted (an early return -- no mutation, no
    # changelog entry), and broadcasting that nil would tell every device to pull for a change
    # that never happened. Not purely hypothetical: nothing stops a stale or double-submitted
    # Restore request from naming a node_id that has already come back.
    test "undelete on an already-live node is a no-op that does not broadcast" do
      id = create_file!(name: "already-live.stl", bytes: "b")
      before = @user.reload.head_seq
      assert_no_broadcasts(LibraryChannel.broadcasting_for(@user)) do
        info = adapter.undelete(@user, node_id: id)
        assert_equal id, info.node_id
      end
      assert_equal before, @user.reload.head_seq, "no mutation happened, so head_seq must not move"
    end
  end
end
