# FileLayer Port (Phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Introduce the `FileLayer` port with a `Chunk` adapter and a shared adapter-contract suite, and move `Maker::FileBytes` onto it — a pure refactor with **no behavior change**, proving the seam before share/S3 depend on it.

**Architecture:** `FileLayer.current` is a factory selected by `LIBRARY_BACKEND` (default `chunk`), mirroring the existing `Storage::ChunkStore.current`. `FileLayer::Chunk` owns today's `node → version → manifest_chunks → Storage::ChunkStore` read path, including the `fetch`/`http_get` seam and the `NotFound` vs `FetchError` distinction. `Maker::FileBytes` becomes a thin back-compat shim. A shared contract module runs against every adapter; in Phase 1 only `Chunk` includes it.

**Tech Stack:** Rails 8, Minitest (`ActiveSupport::TestCase`, parallel workers, no fixtures — tests create records directly), SQLite in test, Zeitwerk autoloading from `app/services`.

**Source spec:** `docs/superpowers/specs/2026-07-14-maker-file-layer-split-design.md` (§3.2 port, §9 phasing). Phases 2–4 (share adapter + scanner, S3, UI gating) get their own plans once this interface is real.

---

## Scope

**In:** the port module (errors, `MAX_BYTES`, factory), `FileInfo`, `Capabilities`, `FileLayer::Chunk` (`stat`, `read`, `capabilities`), the contract suite, the `Maker::FileBytes` shim, and relocating the tests that stub the moved seam.

**Out (later phases, do not build now — YAGNI):** `list`, `write`, `delete`, `move`, `download`/`Delivery`, `path` on `FileInfo`, the `nodes` migration, the scanner/reconciler, trash, the boot guard, share and S3 adapters, UI gating.

**Non-negotiable:** the full existing suite (`bin/rails test`, currently **502 runs, 0 failures, 5 skips**) must stay green at every commit. Chunk mode's behavior must not change.

## Two constraints discovered in the code (do not violate)

1. `app/jobs/maker/generate_preview_job.rb:28` does `retry_on Maker::FileBytes::FetchError` and line 64 rescues it. **`Maker::FileBytes::FetchError` and `::NotFound` must keep resolving**, or preview retries silently break.
2. `test/services/maker/file_bytes_test.rb` and `test/services/maker/file_bytes_edges_test.rb` stub `Maker::FileBytes.http_get` to inject 403/5xx/network failures. Once that seam moves to `FileLayer::Chunk`, those stubs would **silently no-op** — the tests would pass while testing nothing. Task 6 moves them; do not skip it.

## File structure

| File | Responsibility |
|---|---|
| `app/services/file_layer.rb` (create) | `FileLayer` module: `NotFound`, `FetchError`, `MAX_BYTES`, factory (`current`/`build`/`reset!`) |
| `app/services/file_layer/file_info.rb` (create) | immutable value object returned by `stat` |
| `app/services/file_layer/capabilities.rb` (create) | `versioned?` / `syncable?` / `presignable?` |
| `app/services/file_layer/chunk.rb` (create) | the chunk-store adapter (today's read path) |
| `app/services/maker/file_bytes.rb` (rewrite) | back-compat shim delegating to the port |
| `test/services/file_layer/adapter_contract.rb` (create) | shared contract every adapter must pass |
| `test/services/file_layer/chunk_test.rb` (create) | `Chunk` adapter: contract + moved edge tests |
| `test/services/file_layer/factory_test.rb` (create) | backend selection |
| `test/services/maker/file_bytes_test.rb` (rewrite) | shim delegation + constants still resolve |
| `test/services/maker/file_bytes_edges_test.rb` (delete) | content moves into `chunk_test.rb` |

---

### Task 1: `FileInfo` and `Capabilities` value objects

**Files:**
- Create: `app/services/file_layer/file_info.rb`
- Create: `app/services/file_layer/capabilities.rb`
- Create: `app/services/file_layer.rb`
- Test: `test/services/file_layer/value_objects_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/services/file_layer/value_objects_test.rb`:

```ruby
require "test_helper"

module FileLayer
  class ValueObjectsTest < ActiveSupport::TestCase
    test "FileInfo carries the fields the maker layer needs" do
      info = FileLayer::FileInfo.new(
        node_id: "n1", name: "a.stl", kind: "file", size: 5, mtime: 123, content_token: "v1"
      )
      assert_equal "n1", info.node_id
      assert_equal "a.stl", info.name
      assert_equal "file", info.kind
      assert_equal 5, info.size
      assert_equal 123, info.mtime
      assert_equal "v1", info.content_token
    end

    test "FileInfo is immutable" do
      info = FileLayer::FileInfo.new(
        node_id: "n1", name: "a.stl", kind: "file", size: 5, mtime: 123, content_token: "v1"
      )
      assert_raises(NoMethodError) { info.name = "b.stl" }
    end

    test "Capabilities answers the three questions" do
      caps = FileLayer::Capabilities.new(versioned: true, syncable: true, presignable: false)
      assert caps.versioned?
      assert caps.syncable?
      assert_not caps.presignable?
    end
  end
end
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `bin/rails test test/services/file_layer/value_objects_test.rb`
Expected: FAIL — `NameError: uninitialized constant FileLayer`

- [ ] **Step 3: Implement the minimal code**

Create `app/services/file_layer.rb`:

```ruby
# The file-layer port: the seam between the maker layer (projects/inventory/BOM/previews)
# and whatever actually holds the bytes. Adapters: Chunk (the sync engine's content-addressed
# chunk store), and — in later phases — Share (a mounted directory) and S3 (the user's bucket).
#
# Selected per deployment via LIBRARY_BACKEND, mirroring Storage::ChunkStore.current.
# See docs/superpowers/specs/2026-07-14-maker-file-layer-split-design.md.
module FileLayer
  # The file/version genuinely isn't there. TERMINAL: retrying won't help, so a preview job
  # marks the preview "failed".
  NotFound = Class.new(StandardError)

  # A TRANSIENT failure reaching the bytes: a 403 (auth/creds blip), a 5xx, a network error,
  # or (later) an unmounted share. Distinct from NotFound on purpose — the bytes may well
  # exist; we just couldn't read them right now, so the caller should RETRY rather than mark
  # the file permanently broken. This distinction was written for a real production incident
  # where a 403 during a chunk-store creds outage was swallowed as "missing chunk".
  FetchError = Class.new(StandardError)

  # Cap to protect the job host when reading a whole file into memory. Port-wide: it applies
  # to any backend, not just the chunk store.
  MAX_BYTES = 256 * 1024 * 1024
end
```

Create `app/services/file_layer/file_info.rb`:

```ruby
module FileLayer
  # What the port knows about one file, independent of backend.
  #
  # `content_token` identifies the file's CURRENT CONTENT STATE. In chunk mode it is the
  # immutable version UUID (bytes are restorable); in share/S3 mode it will be the content
  # hash (identifies the bytes, does NOT imply they are recoverable). It is the value stored
  # in the `version_id` column on maker_previews / maker_file_attachments — same value,
  # backend-neutral name.
  FileInfo = Data.define(:node_id, :name, :kind, :size, :mtime, :content_token)
end
```

Create `app/services/file_layer/capabilities.rb`:

```ruby
module FileLayer
  # What this deployment's backend can actually do. The UI reads this to hide
  # Restore/History/Conflicts/Devices rather than offering buttons that fail.
  Capabilities = Data.define(:versioned, :syncable, :presignable) do
    def versioned? = versioned
    def syncable? = syncable
    def presignable? = presignable
  end
end
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `bin/rails test test/services/file_layer/value_objects_test.rb`
Expected: PASS — 3 runs, 0 failures

- [ ] **Step 5: Commit**

```bash
git add app/services/file_layer.rb app/services/file_layer/file_info.rb \
        app/services/file_layer/capabilities.rb test/services/file_layer/value_objects_test.rb
git commit -m "$(cat <<'EOF'
refactor(file-layer): add the FileLayer port's value objects and errors

FileInfo/Capabilities plus the NotFound-vs-FetchError distinction, hoisted to the port
because they apply to any backend, not just the chunk store.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: The adapter contract suite

The contract is the mechanical guard against chunk-specific assumptions leaking into the port. It asserts ONLY what every backend must satisfy — note it never reads a *stale* content token, because share/S3 have no history (spec decision 3).

**Files:**
- Create: `test/services/file_layer/adapter_contract.rb`

- [ ] **Step 1: Write the contract module**

Create `test/services/file_layer/adapter_contract.rb`:

```ruby
# Shared contract EVERY FileLayer adapter must satisfy. Include it into an adapter's test
# case and implement the hooks below. Phase 1 has one adapter (Chunk); the contract exists
# so that when Share and S3 land they cannot quietly diverge — and so chunk-specific
# assumptions can't leak into the port.
#
# Hooks the including test case must define:
#   adapter                        -> the FileLayer adapter under test
#   @user                          -> a User (set in setup)
#   create_file!(name:, bytes:)    -> node_id (String), having stored `bytes` in the backend
module FileLayerAdapterContract
  def test_contract_stat_describes_an_existing_file
    id = create_file!(name: "a.stl", bytes: "hello")
    info = adapter.stat(@user, node_id: id)
    assert_equal id, info.node_id
    assert_equal "a.stl", info.name
    assert_equal "file", info.kind
    assert_equal 5, info.size
    assert info.content_token.present?, "every backend must expose a content token"
  end

  def test_contract_stat_raises_not_found_for_an_unknown_node
    assert_raises(FileLayer::NotFound) { adapter.stat(@user, node_id: "no-such-node") }
  end

  def test_contract_read_returns_the_bytes
    id = create_file!(name: "b.stl", bytes: "hello world")
    assert_equal "hello world", adapter.read(@user, node_id: id)
  end

  def test_contract_read_at_the_current_content_token_returns_the_bytes
    id = create_file!(name: "c.stl", bytes: "tokened")
    token = adapter.stat(@user, node_id: id).content_token
    assert_equal "tokened", adapter.read(@user, node_id: id, content_token: token)
  end

  def test_contract_read_raises_not_found_for_an_unknown_node
    assert_raises(FileLayer::NotFound) { adapter.read(@user, node_id: "no-such-node") }
  end

  def test_contract_read_returns_binary_bytes
    id = create_file!(name: "d.bin", bytes: "\x00\x01\x02\xFF".b)
    assert_equal "\x00\x01\x02\xFF".b, adapter.read(@user, node_id: id)
  end

  def test_contract_capabilities_answers_all_three_questions
    caps = adapter.capabilities
    assert_includes [true, false], caps.versioned?
    assert_includes [true, false], caps.syncable?
    assert_includes [true, false], caps.presignable?
  end
end
```

- [ ] **Step 2: Commit**

The contract has no adapter to run against yet; Task 3 wires it up.

```bash
git add test/services/file_layer/adapter_contract.rb
git commit -m "$(cat <<'EOF'
test(file-layer): shared adapter contract suite

One suite every backend must satisfy, so Share/S3 can't diverge from Chunk later. It
deliberately never reads a stale content token — share/S3 keep no history (spec decision 3).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `FileLayer::Chunk#stat` + wire the contract

**Files:**
- Create: `app/services/file_layer/chunk.rb`
- Create: `test/services/file_layer/chunk_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/services/file_layer/chunk_test.rb`. The `create_file!` hook commits a real file through `Sync::Commit`, and writes the bytes into the store the way `test/services/maker/file_bytes_test.rb` does today (`MemoryChunkStore#put!`):

```ruby
require "test_helper"
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

    # Commit a real file and put its single chunk's bytes in the store.
    def create_file!(name:, bytes:)
      node_id = SecureRandom.uuid
      hash = Digest::SHA256.hexdigest(bytes)
      Storage::ChunkStore.current.put!(@user.id, hash, bytes)
      cid = SecureRandom.uuid
      Sync::Commit.begin(
        user: @user, device: @device, commit_id: cid, node_id:, parent_node_id: nil,
        name:, base_version_id: nil, size: bytes.bytesize,
        manifest: [ { "hash" => hash, "offset" => 0, "length" => bytes.bytesize } ]
      )
      Sync::Commit.finalize(user: @user, commit_id: cid)
      node_id
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/services/file_layer/chunk_test.rb`
Expected: FAIL — `NameError: uninitialized constant FileLayer::Chunk`

- [ ] **Step 3: Implement `stat` (and a stub `read` so the file loads)**

Create `app/services/file_layer/chunk.rb`:

```ruby
module FileLayer
  # The chunk-store adapter: the sync engine's content-addressed store, where a file's bytes
  # are the ordered manifest_chunks of an immutable version. This is the ONLY adapter that
  # can restore history, so its content_token is a version UUID.
  #
  # Runs server-side (preview jobs), so it reads chunks directly rather than via presigned
  # URLs where the store allows it.
  class Chunk
    def capabilities
      Capabilities.new(versioned: true, syncable: true, presignable: true)
    end

    def stat(user, node_id:)
      node = user.nodes.present.find_by(node_id:)
      raise NotFound, "no node #{node_id.inspect}" unless node

      FileInfo.new(
        node_id: node.node_id,
        name: node.name,
        kind: node.kind,
        size: node.current_version&.size.to_i,
        mtime: node.mtime,
        content_token: node.current_version_id
      )
    end

    def read(user, node_id:, content_token: nil)
      raise NotImplementedError
    end
  end
end
```

- [ ] **Step 4: Run the tests**

Run: `bin/rails test test/services/file_layer/chunk_test.rb`
Expected: the two `stat` contract tests and the capabilities test PASS; the four `read` contract tests FAIL with `NotImplementedError`. Task 4 implements `read`.

- [ ] **Step 5: Commit**

```bash
git add app/services/file_layer/chunk.rb test/services/file_layer/chunk_test.rb
git commit -m "$(cat <<'EOF'
refactor(file-layer): Chunk adapter stat + capabilities

Wires the Chunk adapter to the shared contract. read lands next.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Move the byte-read path into `FileLayer::Chunk#read`

This is the actual refactor: the logic currently in `app/services/maker/file_bytes.rb:20-77` moves here **verbatim in behavior** — same version resolution, same `fetch` normalization across stores, same `http_get` seam, same `NotFound`/`FetchError` mapping.

**Files:**
- Modify: `app/services/file_layer/chunk.rb`

- [ ] **Step 1: Replace the `read` stub with the real implementation**

In `app/services/file_layer/chunk.rb`, replace `def read(...) raise NotImplementedError end` with:

```ruby
    def read(user, node_id:, content_token: nil)
      version =
        if content_token.present?
          user.versions.find_by(node_id:, version_id: content_token)
        else
          user.nodes.find_by(node_id:)&.current_version
        end
      raise NotFound, "no version for node #{node_id.inspect}" unless version

      store = Storage::ChunkStore.current
      buf = +"".b
      version.manifest_chunks.each do |mc|
        bytes = self.class.fetch(store, user.id, mc.chunk_hash)
        raise NotFound, "missing chunk #{mc.chunk_hash}" if bytes.nil?
        buf << bytes.b
        raise NotFound, "file exceeds #{MAX_BYTES} bytes" if buf.bytesize > MAX_BYTES
      end
      buf
    end

    # Normalize over the chunk-store backends.
    #   - memory store exposes read_blob (tests/dev)
    #   - local filesystem store exposes read
    #   - S3 store exposes presign_get -> pull the bytes over the presigned GET
    #
    # Returns the bytes, or nil ONLY when the chunk is genuinely absent (a 404 from the
    # presigned GET). A non-404 HTTP error (403 auth, 5xx) or a network error is a TRANSIENT
    # failure -> raise FetchError so the caller retries instead of treating it as permanently
    # missing.
    def self.fetch(store, user_id, hash)
      if store.respond_to?(:read_blob)
        store.read_blob(user_id, hash)
      elsif store.respond_to?(:read)
        store.read(user_id, hash)
      else
        http_get(store.presign_get(user_id, hash))
      end
    rescue OpenURI::HTTPError => e
      # io.status is ["404", "Not Found"]; 404 means the object isn't there (terminal, nil ->
      # NotFound upstream). Anything else (403/5xx) is transient -> FetchError.
      status = e.io.status.first.to_i rescue 0
      return nil if status == 404
      raise FetchError, "chunk GET #{hash}: HTTP #{status} (#{e.message})"
    rescue OpenURI::HTTPError
      nil
    rescue SocketError, Errno::ECONNREFUSED, Errno::ECONNRESET, Net::OpenTimeout,
           Net::ReadTimeout, Timeout::Error => e
      raise FetchError, "chunk GET #{hash}: #{e.class} (#{e.message})"
    end

    # The HTTP fetch seam (presigned GET -> bytes). Extracted so it can be exercised/faulted
    # in isolation; the edge tests stub THIS method. open-uri raises OpenURI::HTTPError for
    # non-2xx, carrying the status.
    def self.http_get(url)
      require "open-uri"
      require "net/http"
      URI.parse(url).open(&:read)
    end
```

- [ ] **Step 2: Run the tests and make sure they pass**

Run: `bin/rails test test/services/file_layer/chunk_test.rb`
Expected: PASS — 7 runs (all contract tests), 0 failures

- [ ] **Step 3: Commit**

```bash
git add app/services/file_layer/chunk.rb
git commit -m "$(cat <<'EOF'
refactor(file-layer): move the chunk byte-read path onto the port

The node -> version -> manifest_chunks -> ChunkStore read, the store-normalizing fetch, the
http_get seam, and the NotFound-vs-FetchError mapping move from Maker::FileBytes into the
Chunk adapter unchanged. Behavior is identical; only the home changes.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: The `FileLayer.current` factory

**Files:**
- Modify: `app/services/file_layer.rb`
- Create: `test/services/file_layer/factory_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/services/file_layer/factory_test.rb`:

```ruby
require "test_helper"

module FileLayer
  class FactoryTest < ActiveSupport::TestCase
    setup { FileLayer.reset! }
    teardown { FileLayer.reset! }

    test "defaults to the chunk adapter" do
      assert_instance_of FileLayer::Chunk, FileLayer.current
    end

    test "LIBRARY_BACKEND=chunk selects the chunk adapter" do
      with_backend("chunk") { assert_instance_of FileLayer::Chunk, FileLayer.current }
    end

    test "an unknown backend refuses to build rather than silently defaulting" do
      with_backend("nope") do
        assert_raises(ArgumentError) { FileLayer.current }
      end
    end

    # share/s3 are Phases 2-3. Until then an operator setting them must get a loud error,
    # never a silent fallback to chunk mode (which would read the WRONG library).
    test "share and s3 are not yet implemented and say so" do
      %w[share s3].each do |backend|
        with_backend(backend) do
          assert_raises(NotImplementedError) { FileLayer.current }
        end
      end
    end

    test "current is memoized and reset! clears it" do
      first = FileLayer.current
      assert_same first, FileLayer.current
      FileLayer.reset!
      assert_not_same first, FileLayer.current
    end

    def with_backend(value)
      prior = ENV["LIBRARY_BACKEND"]
      ENV["LIBRARY_BACKEND"] = value
      FileLayer.reset!
      yield
    ensure
      ENV["LIBRARY_BACKEND"] = prior
      FileLayer.reset!
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/services/file_layer/factory_test.rb`
Expected: FAIL — `NoMethodError: undefined method 'reset!' for FileLayer`

- [ ] **Step 3: Add the factory**

Append inside `module FileLayer` in `app/services/file_layer.rb`, after `MAX_BYTES`:

```ruby
  class << self
    attr_writer :current

    # The adapter for THIS deployment. One backend per deployment (spec decision 1): an
    # instance is the sync product (chunk) or the web-over-your-own-storage product
    # (share/s3), never both.
    def current
      @current ||= build
    end

    def reset!
      @current = nil
    end

    def build
      case ENV.fetch("LIBRARY_BACKEND", "chunk")
      when "chunk"      then Chunk.new
      when "share", "s3"
        # Phases 2-3. Fail loudly: silently falling back to chunk mode would serve an EMPTY
        # library while the operator believes we are reading their NAS.
        raise NotImplementedError,
              "LIBRARY_BACKEND=#{ENV['LIBRARY_BACKEND']} is not implemented yet (phases 2-3)"
      else
        raise ArgumentError, "unknown LIBRARY_BACKEND #{ENV['LIBRARY_BACKEND'].inspect}"
      end
    end
  end
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `bin/rails test test/services/file_layer/factory_test.rb`
Expected: PASS — 5 runs, 0 failures

- [ ] **Step 5: Commit**

```bash
git add app/services/file_layer.rb test/services/file_layer/factory_test.rb
git commit -m "$(cat <<'EOF'
refactor(file-layer): LIBRARY_BACKEND factory

Mirrors Storage::ChunkStore.current. Defaults to chunk; share/s3 raise NotImplementedError
rather than silently falling back, which would serve an empty library while the operator
believes we're reading their NAS.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Move the edge tests onto the adapter, before touching `Maker::FileBytes`

**This must happen before Task 7.** The existing edge tests stub `Maker::FileBytes.http_get`. Once `FileBytes` becomes a shim, that stub would no-op silently and the tests would pass while exercising nothing.

**Files:**
- Modify: `test/services/file_layer/chunk_test.rb`
- Delete: `test/services/maker/file_bytes_edges_test.rb`

- [ ] **Step 1: Add the moved edge tests to the adapter test**

Append inside `class ChunkTest` in `test/services/file_layer/chunk_test.rb` (these are the cases from `file_bytes_test.rb` / `file_bytes_edges_test.rb`, re-pointed at the adapter's seam):

```ruby
    # --- moved from test/services/maker/{file_bytes_test,file_bytes_edges_test}.rb ---
    # These stub the presigned-GET seam, which now lives on the adapter. If they still stubbed
    # Maker::FileBytes.http_get they would silently no-op.

    # A presign-only store (no read_blob/read) forces the presigned-GET branch.
    class PresignOnlyStore
      def presign_get(_user_id, hash) = "https://example.invalid/#{hash}"
      def presign_put(_user_id, hash) = "https://example.invalid/#{hash}"
    end

    def with_http_get_raising(err)
      original = FileLayer::Chunk.method(:http_get)
      FileLayer::Chunk.define_singleton_method(:http_get) { |_url| raise err }
      yield
    ensure
      FileLayer::Chunk.define_singleton_method(:http_get, original)
    end

    def http_error(status)
      io = Struct.new(:status).new([ status.to_s, "Err" ])
      OpenURI::HTTPError.new("#{status} Err", io)
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
        manifest: [ { "hash" => hash, "offset" => 0, "length" => 6 } ]
      )
      Sync::Commit.finalize(user: @user, commit_id: cid)

      assert_equal "second", adapter.read(@user, node_id: id)
      # chunk mode is the versioned backend: an OLD token still resolves. (Not a contract
      # test — share/S3 keep no history.)
      assert_equal "first", adapter.read(@user, node_id: id, content_token: first_token)
    end
```

- [ ] **Step 2: Run the adapter tests**

Run: `bin/rails test test/services/file_layer/chunk_test.rb`
Expected: PASS — 15 runs, 0 failures

- [ ] **Step 3: Delete the superseded edge test file**

```bash
git rm test/services/maker/file_bytes_edges_test.rb
```

- [ ] **Step 4: Commit**

```bash
git add test/services/file_layer/chunk_test.rb
git commit -m "$(cat <<'EOF'
test(file-layer): move the byte-read edge tests onto the Chunk adapter

The 404/403/5xx/network/timeout cases stub the presigned-GET seam, which now lives on the
adapter. Moving them BEFORE Maker::FileBytes becomes a shim, because a stub of
Maker::FileBytes.http_get would then silently no-op and the tests would pass while
exercising nothing.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: `Maker::FileBytes` becomes a shim

**Files:**
- Rewrite: `app/services/maker/file_bytes.rb`
- Rewrite: `test/services/maker/file_bytes_test.rb`

- [ ] **Step 1: Write the failing test**

Replace `test/services/maker/file_bytes_test.rb` entirely:

```ruby
require "test_helper"

module Maker
  # Maker::FileBytes is now a thin shim over the FileLayer port. What matters is that it
  # still DELEGATES and that its error constants still resolve: GeneratePreviewJob does
  # `retry_on Maker::FileBytes::FetchError` (app/jobs/maker/generate_preview_job.rb:28), so
  # if these constants ever stop resolving, preview retries break silently.
  class FileBytesTest < ActiveSupport::TestCase
    setup do
      Storage::ChunkStore.reset!
      FileLayer.reset!
      @user = User.create!(email: "shim-#{SecureRandom.hex(4)}@example.com")
      @device = Device.register!(user: @user, name: "t")
    end
    teardown { FileLayer.reset! }

    test "error constants still resolve for GeneratePreviewJob's retry_on/rescue" do
      assert_equal FileLayer::NotFound, Maker::FileBytes::NotFound
      assert_equal FileLayer::FetchError, Maker::FileBytes::FetchError
      assert_equal FileLayer::MAX_BYTES, Maker::FileBytes::MAX_BYTES
    end

    test "read delegates to the port, mapping version_id to content_token" do
      captured = nil
      fake = Object.new
      fake.define_singleton_method(:read) do |user, node_id:, content_token: nil|
        captured = { user:, node_id:, content_token: }
        "delegated"
      end
      FileLayer.current = fake

      bytes = Maker::FileBytes.read(@user, node_id: "n1", version_id: "v1")

      assert_equal "delegated", bytes
      assert_equal @user, captured[:user]
      assert_equal "n1", captured[:node_id]
      assert_equal "v1", captured[:content_token]
    end

    test "read still returns real bytes end-to-end through the chunk adapter" do
      node_id = SecureRandom.uuid
      hash = Digest::SHA256.hexdigest("real bytes")
      Storage::ChunkStore.current.put!(@user.id, hash, "real bytes")
      cid = SecureRandom.uuid
      Sync::Commit.begin(
        user: @user, device: @device, commit_id: cid, node_id:, parent_node_id: nil,
        name: "k.stl", base_version_id: nil, size: 10,
        manifest: [ { "hash" => hash, "offset" => 0, "length" => 10 } ]
      )
      Sync::Commit.finalize(user: @user, commit_id: cid)

      assert_equal "real bytes", Maker::FileBytes.read(@user, node_id:)
    end

    test "an unknown node still raises the constant callers rescue" do
      assert_raises(Maker::FileBytes::NotFound) do
        Maker::FileBytes.read(@user, node_id: "nope", version_id: "nope")
      end
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/services/maker/file_bytes_test.rb`
Expected: FAIL — `Maker::FileBytes::NotFound` is its own class, not `FileLayer::NotFound`

- [ ] **Step 3: Replace the implementation with the shim**

Replace `app/services/maker/file_bytes.rb` entirely:

```ruby
module Maker
  # Back-compat shim over the FileLayer port.
  #
  # The maker layer's byte access used to reach through version.manifest_chunks into
  # Storage::ChunkStore — the one place the maker layer knew the file layer's internals. That
  # logic now lives in FileLayer::Chunk, so the maker layer works over ANY backend (share,
  # S3) without change.
  #
  # This shim stays because GeneratePreviewJob does `retry_on Maker::FileBytes::FetchError`
  # and rescues these constants. Prefer FileLayer.current.read in new code.
  class FileBytes
    NotFound   = FileLayer::NotFound
    FetchError = FileLayer::FetchError
    MAX_BYTES  = FileLayer::MAX_BYTES

    # `version_id` is the caller-facing name for what the port calls a content_token: in chunk
    # mode a version UUID, in share/S3 mode a content hash.
    def self.read(user, node_id:, version_id: nil)
      FileLayer.current.read(user, node_id:, content_token: version_id)
    end
  end
end
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `bin/rails test test/services/maker/file_bytes_test.rb`
Expected: PASS — 4 runs, 0 failures

- [ ] **Step 5: Run the preview job tests (the real consumer)**

Run: `bin/rails test test/jobs/maker/generate_preview_job_test.rb`
Expected: PASS. This suite stubs `Maker::FileBytes.read` and raises `Maker::FileBytes::FetchError`; both still work through the shim.

- [ ] **Step 6: Commit**

```bash
git add app/services/maker/file_bytes.rb test/services/maker/file_bytes_test.rb
git commit -m "$(cat <<'EOF'
refactor(maker): FileBytes becomes a shim over the FileLayer port

This was the ONE place the maker layer knew the file layer's internals (version ->
manifest_chunks -> ChunkStore). With it delegating to the port, the maker layer works over
any backend without change — the whole point of the split.

The shim stays because GeneratePreviewJob does retry_on Maker::FileBytes::FetchError; the
constants are aliases so existing rescues keep working.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Prove no behavior changed

**Files:** none (verification only)

- [ ] **Step 1: Run the full suite**

Run: `bin/rails test`
Expected: **502 runs, 0 failures, 0 errors, 5 skips** — the same counts as before this plan, plus the new tests. A drop in runs means a test file was lost; investigate rather than proceeding.

- [ ] **Step 2: Confirm the maker layer no longer reaches into the file layer**

Run: `grep -rn "manifest_chunks\|ChunkStore" app/services/maker/ app/models/maker/ app/jobs/maker/`
Expected: **no output.** Any hit means a leak survived and Phase 2's share adapter will break on it.

- [ ] **Step 3: Confirm the port is the only new coupling**

Run: `grep -rln "FileLayer" app/`
Expected: exactly `app/services/file_layer.rb`, `app/services/file_layer/*.rb`, `app/services/maker/file_bytes.rb`.

- [ ] **Step 4: Commit (docs only, if anything changed)**

If steps 1-3 are clean there is nothing to commit; Phase 1 is done.

---

## Definition of done

- [ ] `bin/rails test` green with the same run count as before, plus the new tests
- [ ] `grep -rn "manifest_chunks\|ChunkStore" app/services/maker/ app/models/maker/ app/jobs/maker/` returns nothing
- [ ] `FileLayer::Chunk` passes the shared contract
- [ ] `LIBRARY_BACKEND=share` / `=s3` raise `NotImplementedError` (loudly, no silent fallback)
- [ ] No change to chunk mode behavior: no migration, no route change, no sync/changelog/conflict/lock/mount edits (spec §10 tripwire)

## Next

Phase 2 (`Share` adapter + scanner/reconciler + trash + boot guard + `nodes` migration) gets its own plan, written against the now-real port interface.
