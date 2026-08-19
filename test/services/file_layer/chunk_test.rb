require "test_helper"
require "open-uri"
require_relative "adapter_contract"

module FileLayer
  # The Chunk adapter over the sync engine's content-addressed store: this is today's
  # node -> version -> manifest_chunks -> Storage::ChunkStore read path, moved behind the port.
  class ChunkTest < ActiveSupport::TestCase
    include FileLayerAdapterContract

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

    # Chunk's "delete" is the tombstone the v1 API sets (Sync::Mutation op "delete"); the
    # versions stay in the DB for restore, which is exactly why read must check the node.
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

    # Chunk mutations do NOT go through this port; they are the sync engine's, and the three ops
    # use THREE DIFFERENT doors, verified against the callers:
    #   write  -> Sync::Commit's two-phase flow (a device pushes; the web UI reuses it)
    #   delete -> Sync::SubtreeDelete.call             (v1/nodes_controller.rb:46)
    #   move   -> Sync::Mutation.apply, op: "move"     (v1/nodes_controller.rb:55)
    # A server-side chunk-and-commit path does not exist and has no caller, so the port says so
    # out loud rather than answering NoMethodError.
    #
    # Asserted PER OP, never with one blanket regex. The whole deliverable is "refuse HONESTLY,
    # naming the real path", so a test that accepts /Sync::Commit/ for delete would pin, by name,
    # the wrong door as right — a green test guarding misinformation. `not_names` pins that exact
    # defect: delete/move must never cite Sync::Commit, which has no delete or move path, and it
    # also catches a regression to one shared message listing every class (which would satisfy
    # the positive regexes while leaving the caller to guess which door is theirs).
    test "the write path is not chunk mode's — each op refuses, naming its OWN real path" do
      {
        write: {
          call: -> { adapter.write(@user, parent_node_id: nil, name: "x.stl", io: StringIO.new("b")) },
          names: /Sync::Commit/
        },
        delete: {
          call: -> { adapter.delete(@user, node_id: "n1") },
          names: /Sync::SubtreeDelete/, not_names: /Sync::Commit/
        },
        move: {
          call: -> { adapter.move(@user, node_id: "n1", new_parent_node_id: nil, new_name: "y.stl") },
          names: /Sync::Mutation\.apply/, not_names: /Sync::Commit/
        }
      }.each do |op, spec|
        err = assert_raises(NotImplementedError, "#{op} must refuse, not answer") { spec[:call].call }
        assert_match(spec[:names], err.message, "#{op} must name the path a caller should use")
        next unless spec[:not_names]
        assert_no_match(spec[:not_names], err.message,
                        "#{op} must not send the caller to Sync::Commit, which has no #{op} path")
      end
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
  end
end
