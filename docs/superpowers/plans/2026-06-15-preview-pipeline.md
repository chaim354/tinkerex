# Preview Pipeline — Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Each task is TDD: write the failing test first, then the code.

**Goal:** Build the **Previews pillar** of the maker-app — a server job that turns an immutable file **version** into a stored thumbnail (and, later, a web GLB) so the catalog/web UI can show a picture of each STL/3MF/CAD/LightBurn/SVG file. Closes `feature-set-and-workflows.md` §3 item 10 ("Preview an STL/3MF/CAD file in-browser" — not built) and CLAUDE.md §4/§12-step-9 ("Preview (later) = Three.js browser + FreeCAD/CadQuery server jobs").

**Architecture:** A new `Maker::Preview` server-authoritative record (same pattern as the just-merged Library pillar — integer-PK Rails CRUD over `/v1/maker/*`, `user_id`-scoped, **referencing synced files only by their stable string `node_id` + immutable `version_id`**, never synced into the local SQLite tree). A preview is keyed per **(node_id, version_id, kind)** and carries an ActiveStorage attachment (`has_one_attached :asset` → S3/R2). Generation is an **ActiveJob** (Solid Queue in prod) that: fetches the file bytes server-side from the chunk store via the file layer's manifest, runs a **permissive-only** per-format toolchain (see `docs/research-format-processing.md`), stores the result via ActiveStorage, and flips `status` `pending→processing→ready|failed`. **Phase 1 ships the table/model/job skeleton + ONE easy format end-to-end (SVG); later phases add lbrn2, 3MF, STL/OBJ, STEP.**

**Tech Stack:** Rails 8.1, Ruby 3.4, SQLite (dev/test) + Postgres (prod) — adapter-agnostic (`t.integer :user_id`, no DB FK constraints, explicit indexes, `user_id` scoping). ActiveStorage is **already installed** (migrations `20260609200518..520_*active_storage*`; `config.active_storage.service = :test` in test). Minitest (`ActiveSupport::TestCase` models/services/jobs, `ActionDispatch::IntegrationTest` API). Solid Queue is the prod ActiveJob adapter (`config.active_job.queue_adapter = :solid_queue`); test uses the default `:test`/inline adapter.

**Recommended toolchain (from `docs/research-format-processing.md` §0/§8 — permissive only):**
- **SVG → PNG:** `resvg` CLI (MIT/Apache, pure-Rust, no system deps) → `image_processing` (~> 2.0, already in Gemfile, MIT) for the resize/encode finish. **Phase 1's only external dependency.**
- **lbrn2 → SVG → PNG:** parse the lbrn2 XML in-Ruby (Nokogiri, MIT) → SVG → reuse the SVG path.
- **3MF → PNG:** extract the embedded `Metadata/thumbnail.png` (rubyzip, BSD-2) — most slicer files carry one; F3D fallback later.
- **STL/OBJ/STEP → PNG/GLB:** `f3d` (BSD-3) headless subprocess (OCCT LGPL stays process-isolated).
- **DWG / native Fusion / SolidWorks:** **unsupported** (no permissive parser) → `status: failed`, generic icon in UI.

**Conventions to follow (from the just-merged `Maker::` code):**
- Models: `module Maker; class X < ApplicationRecord; self.table_name = "maker_xs"`; `belongs_to :user`; value-sets as frozen constants + `validates …, inclusion:`; `scope`s for filters. See `app/models/maker/item.rb`, `app/models/maker/file_attachment.rb`.
- Migrations: `t.integer :user_id, null: false` (NO `foreign_key:`), explicit `t.index`, timestamp-prefixed `YYYYMMDDHHMMSS_*`.
- Controllers: `V1::Maker::XController < V1::BaseController` (inherits device-token auth + JSON rescues); scope **everything** through `current_user.maker_…`; `render json:`. See `app/controllers/v1/maker/items_controller.rb`.
- API tests: register a device via `POST /v1/auth/register` (`register["device_token"]`) and send `Authorization: Bearer <token>` (`auth(token)` helper). See `test/integration/v1/sync_flow_test.rb`, `test/integration/v1/maker/*`.
- The server can read file bytes from `Storage::ChunkStore.current`: a `Version`'s ordered chunks come from `version.manifest_chunks` (`ManifestChunk` rows, `seq`/`offset`/`length`/`chunk_hash`); the local/memory stores expose `read(user_id, hash)` / `read_blob(user_id, hash)`; the S3 store exposes `presign_get`. See `app/models/version.rb`, `app/services/storage/*`.

**Routes:** add inside the existing `namespace :maker do … end` block in `config/routes.rb` (only what each task needs):
```ruby
resources :previews, only: %i[index create]
```
(`index` = list previews for a node/version; `create` = enqueue generation. Read of the asset bytes is via the ActiveStorage blob URL returned in the JSON, off Rails — consistent with "keep bytes out of Rails".)

---

## File Structure

**Migration** (`db/migrate/`): `*_create_maker_previews.rb`.

**Model** (`app/models/maker/`): `preview.rb` (`Maker::Preview < ApplicationRecord`, `has_one_attached :asset`). Plus one `has_many :maker_previews` line on `app/models/user.rb`.

**Services** (`app/services/maker/`):
- `file_bytes.rb` — `Maker::FileBytes.read(user, node_id:, version_id:)` → assembles the file's bytes from its version manifest + the chunk store (the file-layer seam).
- `previews/svg.rb` — `Maker::Previews::Svg` the Phase-1 renderer (SVG bytes → PNG via resvg + image_processing).
- (later) `previews/lbrn2.rb`, `previews/three_mf.rb`, `previews/mesh.rb` (F3D), `previews/registry.rb` (extension → renderer).

**Job** (`app/jobs/maker/`): `generate_preview_job.rb` — `Maker::GeneratePreviewJob.perform(preview_id)`.

**Controller** (`app/controllers/v1/maker/`): `previews_controller.rb`.

**Tests:** `test/models/maker/preview_test.rb`, `test/services/maker/file_bytes_test.rb`, `test/services/maker/previews/svg_test.rb`, `test/jobs/maker/generate_preview_job_test.rb`, `test/integration/v1/maker/previews_test.rb`. Fixtures under `test/fixtures/files/` (a tiny `square.svg`).

Responsibilities: `Maker::Preview` = the catalog-side preview record (one per node/version/kind). `Maker::FileBytes` = the read-only file-layer seam (version → manifest → chunk bytes). `Maker::Previews::*` = pure per-format renderers (bytes in → PNG/GLB bytes out; no DB/AS). `Maker::GeneratePreviewJob` = the orchestrator (fetch bytes → pick renderer → attach → flip status). The controller is thin CRUD + enqueue, `current_user`-scoped.

---

## Phase 1 — table/model/job skeleton + SVG end-to-end

### Task 1: `Maker::Preview` model + migration

**Files:**
- Create: `db/migrate/20260615010001_create_maker_previews.rb`
- Create: `app/models/maker/preview.rb`
- Modify: `app/models/user.rb` (add `has_many :maker_previews`)
- Test: `test/models/maker/preview_test.rb`

- [ ] **Step 1: Write the migration**

Create `db/migrate/20260615010001_create_maker_previews.rb`:
```ruby
class CreateMakerPreviews < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_previews do |t|
      t.integer :user_id,    null: false
      t.string  :node_id,    null: false
      t.string  :version_id
      t.string  :kind,       null: false, default: "thumbnail"
      t.string  :status,     null: false, default: "pending"
      t.text    :error
      t.integer :width
      t.integer :height
      t.timestamps
    end
    # One preview per (user, node, version, kind) — regenerating updates in place.
    add_index :maker_previews, [ :user_id, :node_id, :version_id, :kind ],
              unique: true, name: "idx_maker_previews_unique"
    add_index :maker_previews, [ :user_id, :status ]
  end
end
```
Run `bin/rails db:migrate`. Expected: `db/schema.rb` gains `maker_previews`.

- [ ] **Step 2: Write the failing model test**

Create `test/models/maker/preview_test.rb`:
```ruby
require "test_helper"

module Maker
  class PreviewTest < ActiveSupport::TestCase
    setup { @user = User.create!(email: "prev@example.com") }

    test "valid with node_id + defaults" do
      p = @user.maker_previews.build(node_id: "n1")
      assert p.valid?
      assert_equal "thumbnail", p.kind
      assert_equal "pending",   p.status
    end

    test "node_id is required" do
      assert_not @user.maker_previews.build(node_id: nil).valid?
    end

    test "kind and status must be in the allowed sets" do
      assert_not @user.maker_previews.build(node_id: "n", kind: "bogus").valid?
      assert_not @user.maker_previews.build(node_id: "n", status: "bogus").valid?
    end

    test "uniqueness on node_id+version_id+kind, scoped to user" do
      @user.maker_previews.create!(node_id: "n", version_id: "v", kind: "thumbnail")
      dup = @user.maker_previews.build(node_id: "n", version_id: "v", kind: "thumbnail")
      assert_not dup.valid?
    end

    test "can attach an asset" do
      p = @user.maker_previews.create!(node_id: "n")
      p.asset.attach(io: StringIO.new("PNGDATA"), filename: "t.png", content_type: "image/png")
      assert p.asset.attached?
    end
  end
end
```
Run `bin/rails test test/models/maker/preview_test.rb` → fails (no model).

- [ ] **Step 3: Write the model**

Create `app/models/maker/preview.rb`:
```ruby
module Maker
  class Preview < ApplicationRecord
    self.table_name = "maker_previews"

    belongs_to :user
    has_one_attached :asset

    KINDS    = %w[thumbnail model_glb render].freeze
    STATUSES = %w[pending processing ready failed].freeze

    validates :node_id, presence: true
    validates :kind,    inclusion: { in: KINDS }
    validates :status,  inclusion: { in: STATUSES }
    validates :node_id, uniqueness: { scope: %i[user_id version_id kind] }

    scope :ready,   -> { where(status: "ready") }
    scope :of_kind, ->(k) { where(kind: k) if k.present? }
    scope :for_node, ->(n) { where(node_id: n) if n.present? }
    scope :for_version, ->(v) { where(version_id: v) if v.present? }
  end
end
```

- [ ] **Step 4: Wire `User`**

Add to `app/models/user.rb` (next to the other `has_many :maker_*` lines):
```ruby
has_many :maker_previews, class_name: "Maker::Preview", dependent: :destroy
```

- [ ] **Step 5: Run** `bin/rails test test/models/maker/preview_test.rb` → green.

---

### Task 2: `Maker::FileBytes` — read file bytes from the version manifest

The job needs the raw file bytes server-side. A version's content is the concatenation of its manifest chunks (ordered by `seq`), each fetched from the chunk store by hash. This service is the read-only file-layer seam.

**Files:**
- Create: `app/services/maker/file_bytes.rb`
- Test: `test/services/maker/file_bytes_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/services/maker/file_bytes_test.rb`:
```ruby
require "test_helper"

module Maker
  class FileBytesTest < ActiveSupport::TestCase
    setup do
      Storage::ChunkStore.reset!
      @store = Storage::ChunkStore.current   # memory store in test
      @user  = User.create!(email: "fb@example.com")
    end

    test "assembles bytes from a version's ordered manifest chunks" do
      # two chunks "AAA" + "BB" -> "AAABB"
      h1, h2 = "hash1", "hash2"
      @store.write_blob(@user.id, h1, "AAA")
      @store.write_blob(@user.id, h2, "BB")
      manifest_id = "m1"
      ManifestChunk.create!(user_id: @user.id, manifest_id:, chunk_hash: h1, seq: 0, offset: 0, length: 3)
      ManifestChunk.create!(user_id: @user.id, manifest_id:, chunk_hash: h2, seq: 1, offset: 3, length: 2)
      v = Version.create!(user_id: @user.id, version_id: "v1", node_id: "n1", manifest_id:)

      bytes = Maker::FileBytes.read(@user, node_id: "n1", version_id: "v1")
      assert_equal "AAABB", bytes
    end

    test "raises when the version is unknown" do
      assert_raises(Maker::FileBytes::NotFound) do
        Maker::FileBytes.read(@user, node_id: "nope", version_id: "nope")
      end
    end
  end
end
```
Run → fails.

> Note: the memory chunk store exposes `write_blob`/`read_blob`; local exposes `write`/`read`; S3 exposes `presign_get`. The service normalizes over these. In test the store is the memory store.

- [ ] **Step 2: Write the service**

Create `app/services/maker/file_bytes.rb`:
```ruby
module Maker
  # Read-only file-layer seam: assemble a file VERSION's bytes from its manifest chunks.
  # Bytes come from the same content-addressed chunk store the sync engine uses; this runs
  # server-side (a preview job), so it reads chunks directly rather than via presigned URLs.
  class FileBytes
    NotFound = Class.new(StandardError)

    # Cap to protect the job host; large CAD/mesh files stream to disk in later phases.
    MAX_BYTES = 256 * 1024 * 1024

    def self.read(user, node_id:, version_id: nil)
      version =
        if version_id.present?
          user.versions.find_by(node_id:, version_id:)
        else
          node = user.nodes.find_by(node_id:)
          node&.current_version
        end
      raise NotFound, "no version for node #{node_id.inspect}" unless version

      store = Storage::ChunkStore.current
      buf = +"".b
      version.manifest_chunks.each do |mc|
        bytes = fetch(store, user.id, mc.chunk_hash)
        raise NotFound, "missing chunk #{mc.chunk_hash}" if bytes.nil?
        buf << bytes
        raise NotFound, "file exceeds #{MAX_BYTES} bytes" if buf.bytesize > MAX_BYTES
      end
      buf
    end

    # Normalize over the three store backends.
    def self.fetch(store, user_id, hash)
      if store.respond_to?(:read_blob)      # memory store
        store.read_blob(user_id, hash)
      elsif store.respond_to?(:read)        # local filesystem store
        store.read(user_id, hash)
      else                                  # S3: pull via the presigned GET
        url = store.presign_get(user_id, hash)
        require "open-uri"
        URI.parse(url).open(&:read)
      rescue OpenURI::HTTPError
        nil
      end
    end
  end
end
```
Run → green.

> `user.versions` / `user.nodes` already exist (the existing models scope by user). Verify the association names with `grep "has_many :versions\|has_many :nodes" app/models/user.rb`; if absent, use `Version.find_by(user_id: user.id, …)` / `Node.find_by(user_id: user.id, …)` instead.

---

### Task 3: `Maker::Previews::Svg` — SVG bytes → PNG (the Phase-1 renderer)

Pure renderer: bytes in → PNG bytes out. No DB, no ActiveStorage. SVG→PNG uses the **resvg** CLI (permissive, `docs/research-format-processing.md` §4); then `image_processing` (already in the Gemfile) downsizes to a square thumbnail.

**Files:**
- Create: `app/services/maker/previews/svg.rb`
- Create: `test/fixtures/files/square.svg`
- Test: `test/services/maker/previews/svg_test.rb`

- [ ] **Step 1: Add the fixture**

Create `test/fixtures/files/square.svg`:
```xml
<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100" viewBox="0 0 100 100">
  <rect x="10" y="10" width="80" height="80" fill="#3366cc"/>
</svg>
```

- [ ] **Step 2: Write the failing test**

Create `test/services/maker/previews/svg_test.rb`:
```ruby
require "test_helper"

module Maker
  module Previews
    class SvgTest < ActiveSupport::TestCase
      setup { @svg = File.binread(Rails.root.join("test/fixtures/files/square.svg")) }

      test "renders SVG bytes to a PNG" do
        skip "resvg not installed" unless Maker::Previews::Svg.available?
        result = Maker::Previews::Svg.render(@svg, size: 64)
        assert_equal "image/png", result[:content_type]
        assert_equal 64, result[:width]
        assert_equal 64, result[:height]
        # PNG magic number
        assert_equal "\x89PNG".b, result[:bytes][0, 4].b
      end

      test "available? reflects whether the resvg binary is on PATH" do
        assert_includes [ true, false ], Maker::Previews::Svg.available?
      end
    end
  end
end
```
Run → fails.

> The test `skip`s when `resvg` isn't installed so the suite stays green on a bare box — but it runs (and asserts a real PNG) wherever resvg is present (CI installs it). This matches `docs/research-format-processing.md` §8 point 6 (tools are optional; detect absence).

- [ ] **Step 3: Write the renderer**

Create `app/services/maker/previews/svg.rb`:
```ruby
require "open3"
require "tempfile"

module Maker
  module Previews
    # SVG -> PNG thumbnail. resvg (MIT/Apache, pure-Rust, no system deps) rasterizes the SVG;
    # image_processing (~> 2.0, already in the Gemfile) squares + encodes the thumbnail.
    # See docs/research-format-processing.md §4.
    module Svg
      module_function

      RESVG = ENV.fetch("RESVG_BIN", "resvg")

      def available? = system("#{RESVG} --version", out: File::NULL, err: File::NULL)

      # Returns { bytes:, content_type:, width:, height: }.
      def render(svg_bytes, size: 512)
        png = resvg_to_png(svg_bytes, size)
        thumb = ImageProcessing::Vips
                  .source(StringIO.new(png))
                  .resize_to_fit(size, size)
                  .convert("png")
                  .call
        bytes = File.binread(thumb.path)
        { bytes:, content_type: "image/png", width: size, height: size }
      ensure
        thumb&.close! if defined?(thumb) && thumb
      end

      def resvg_to_png(svg_bytes, size)
        Tempfile.create([ "in", ".svg" ]) do |fin|
          fin.binwrite(svg_bytes); fin.flush
          out = "#{fin.path}.png"
          ok = system(RESVG, "--width", size.to_s, "--height", size.to_s, fin.path, out,
                      out: File::NULL, err: File::NULL)
          raise "resvg failed" unless ok && File.exist?(out)
          png = File.binread(out)
          File.delete(out)
          return png
        end
      end
    end
  end
end
```

> If `image_processing` is configured for ImageMagick (`MiniMagick`) rather than Vips in this app, swap `ImageProcessing::Vips` for `ImageProcessing::MiniMagick`. Both are MIT (the gem) — confirm with `grep -rn "ImageProcessing\|MiniMagick\|Vips" app config`.

- [ ] **Step 4: Run** `bin/rails test test/services/maker/previews/svg_test.rb` → green (or `skip` if resvg absent locally).

---

### Task 4: `Maker::GeneratePreviewJob` — orchestrate fetch → render → attach → status

**Files:**
- Create: `app/jobs/maker/generate_preview_job.rb`
- Test: `test/jobs/maker/generate_preview_job_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/jobs/maker/generate_preview_job_test.rb`:
```ruby
require "test_helper"

module Maker
  class GeneratePreviewJobTest < ActiveSupport::TestCase
    setup do
      Storage::ChunkStore.reset!
      @store = Storage::ChunkStore.current
      @user  = User.create!(email: "job@example.com")
      svg = File.binread(Rails.root.join("test/fixtures/files/square.svg"))
      @store.write_blob(@user.id, "svghash", svg)
      ManifestChunk.create!(user_id: @user.id, manifest_id: "m", chunk_hash: "svghash",
                            seq: 0, offset: 0, length: svg.bytesize)
      Version.create!(user_id: @user.id, version_id: "v1", node_id: "n1.svg", manifest_id: "m")
      @preview = @user.maker_previews.create!(node_id: "n1.svg", version_id: "v1", kind: "thumbnail")
    end

    test "renders SVG, attaches asset, flips status to ready" do
      skip "resvg not installed" unless Maker::Previews::Svg.available?
      Maker::GeneratePreviewJob.perform_now(@preview.id, filename: "drawing.svg")
      @preview.reload
      assert_equal "ready", @preview.status
      assert @preview.asset.attached?
      assert_equal 512, @preview.width
    end

    test "unsupported extension flips status to failed with an error" do
      @preview.update!(node_id: "weird.sldprt")
      Version.create!(user_id: @user.id, version_id: "v2", node_id: "weird.sldprt", manifest_id: "m")
      @preview.update!(version_id: "v2")
      Maker::GeneratePreviewJob.perform_now(@preview.id, filename: "weird.sldprt")
      @preview.reload
      assert_equal "failed", @preview.status
      assert @preview.error.present?
      assert_not @preview.asset.attached?
    end
  end
end
```
Run → fails.

- [ ] **Step 2: Write the job**

Create `app/jobs/maker/generate_preview_job.rb`:
```ruby
module Maker
  class GeneratePreviewJob < ApplicationJob
    queue_as :default

    # Phase 1: SVG only. Later phases register more renderers here (lbrn2/3mf/stl/step).
    def perform(preview_id, filename: nil)
      preview = Maker::Preview.find(preview_id)
      preview.update!(status: "processing", error: nil)

      ext = File.extname(filename.to_s.presence || preview.node_id).downcase.delete_prefix(".")
      renderer = renderer_for(ext)
      raise Unsupported, "no preview renderer for .#{ext}" unless renderer
      raise ToolMissing, "renderer tool unavailable for .#{ext}" unless renderer.available?

      bytes = Maker::FileBytes.read(preview.user, node_id: preview.node_id, version_id: preview.version_id)
      result = renderer.render(bytes, size: 512)

      preview.asset.attach(
        io: StringIO.new(result[:bytes]),
        filename: "#{preview.kind}-#{preview.id}.png",
        content_type: result[:content_type]
      )
      preview.update!(status: "ready", width: result[:width], height: result[:height], error: nil)
    rescue StandardError => e
      preview&.update!(status: "failed", error: "#{e.class}: #{e.message}")
      raise if e.is_a?(ToolMissing) && ENV["PREVIEW_RAISE_ON_TOOL_MISSING"] # let retries kick in if desired
    end

    Unsupported = Class.new(StandardError)
    ToolMissing = Class.new(StandardError)

    private

    # Phase-1 registry. Phase 2+: add "lbrn2" => Previews::Lbrn2, "3mf" => Previews::ThreeMf,
    # %w[stl obj step] => Previews::Mesh.
    def renderer_for(ext)
      { "svg" => Maker::Previews::Svg }[ext]
    end
  end
end
```

> `ApplicationJob` already exists (`app/jobs/application_job.rb`). In test the adapter is inline (`perform_now`); prod uses Solid Queue (`config.active_job.queue_adapter = :solid_queue`).

- [ ] **Step 3: Run** `bin/rails test test/jobs/maker/generate_preview_job_test.rb` → green (SVG test `skip`s without resvg; the `failed`-path test runs everywhere since `.sldprt` has no renderer, no tool needed).

---

### Task 5: API — `GET /v1/maker/previews` + `POST /v1/maker/previews` (enqueue)

**Files:**
- Modify: `config/routes.rb` (add `resources :previews, only: %i[index create]` in the `:maker` namespace)
- Create: `app/controllers/v1/maker/previews_controller.rb`
- Test: `test/integration/v1/maker/previews_test.rb`

- [ ] **Step 1: Add the route**

In `config/routes.rb`, inside `namespace :maker do … end`:
```ruby
resources :previews, only: %i[index create]
```

- [ ] **Step 2: Write the failing API test**

Create `test/integration/v1/maker/previews_test.rb`:
```ruby
require "test_helper"

module V1
  module Maker
    class PreviewsTest < ActionDispatch::IntegrationTest
      setup { Storage::ChunkStore.reset! }

      def register
        post "/v1/auth/register", params: { email: "p@example.com", device_name: "laptop" }, as: :json
        assert_response :created
        JSON.parse(response.body)["device_token"]
      end
      def auth(t) = { "Authorization" => "Bearer #{t}" }

      test "create enqueues a preview (pending) and is idempotent per node/version/kind" do
        token = register
        assert_enqueued_with(job: ::Maker::GeneratePreviewJob) do
          post "/v1/maker/previews",
               params: { preview: { node_id: "n1.svg", version_id: "v1" } },
               as: :json, headers: auth(token)
        end
        assert_response :created
        body = JSON.parse(response.body)
        assert_equal "pending", body["status"]
        assert_equal "thumbnail", body["kind"]

        # second call returns the same record, doesn't duplicate
        post "/v1/maker/previews",
             params: { preview: { node_id: "n1.svg", version_id: "v1" } },
             as: :json, headers: auth(token)
        assert_response :success
        assert_equal 1, ::Maker::Preview.where(node_id: "n1.svg").count
      end

      test "index filters by node_id and version_id, scoped to the user" do
        token = register
        post "/v1/maker/previews", params: { preview: { node_id: "a", version_id: "v" } },
             as: :json, headers: auth(token)
        get "/v1/maker/previews?node_id=a&version_id=v", headers: auth(token)
        assert_response :success
        items = JSON.parse(response.body)["previews"]
        assert_equal 1, items.size
        assert_equal "a", items.first["node_id"]
      end

      test "requires auth" do
        get "/v1/maker/previews?node_id=a"
        assert_response :unauthorized
      end
    end
  end
end
```
Run → fails.

- [ ] **Step 3: Write the controller**

Create `app/controllers/v1/maker/previews_controller.rb`:
```ruby
module V1
  module Maker
    class PreviewsController < V1::BaseController
      def index
        previews = current_user.maker_previews
                     .for_node(params[:node_id])
                     .for_version(params[:version_id])
                     .of_kind(params[:kind])
                     .order(updated_at: :desc)
        render json: { previews: previews.map { |p| preview_json(p) } }
      end

      # Enqueue (or return the existing) preview for a node/version/kind.
      def create
        attrs = preview_params
        preview = current_user.maker_previews
                    .find_or_initialize_by(node_id: attrs[:node_id],
                                           version_id: attrs[:version_id],
                                           kind: attrs.fetch(:kind, "thumbnail"))
        new_record = preview.new_record?
        preview.status = "pending" if new_record || preview.status == "failed"
        preview.save!
        if new_record || preview.status == "pending"
          ::Maker::GeneratePreviewJob.perform_later(preview.id, filename: attrs[:filename])
        end
        render json: preview_json(preview), status: (new_record ? :created : :ok)
      end

      private

      def preview_params
        params.require(:preview).permit(:node_id, :version_id, :kind, :filename)
      end

      def preview_json(p)
        {
          id: p.id, node_id: p.node_id, version_id: p.version_id, kind: p.kind,
          status: p.status, error: p.error, width: p.width, height: p.height,
          url: (p.asset.attached? ? url_for(p.asset) : nil),
          created_at: p.created_at, updated_at: p.updated_at
        }
      end
    end
  end
end
```

> `url_for(p.asset)` returns the ActiveStorage blob URL (a redirect to the presigned S3/R2 object in prod) — the bytes are served by storage, not streamed through Rails, consistent with CLAUDE.md §8/§15.

- [ ] **Step 4: Run** `bin/rails test test/integration/v1/maker/previews_test.rb` → green.

- [ ] **Step 5: Full suite** `bin/rails test` → all green. Phase 1 complete: a node/version → enqueued job → SVG rendered → PNG attached → `ready`, listable via the API with a blob URL.

---

### Task 6: Expose preview status on the items API (the catalog seam)

So the file browser / item view can show a thumbnail without a second round-trip per file.

**Files:**
- Modify: `app/controllers/v1/maker/items_controller.rb` (enrich `attachment_json` with the ready thumbnail URL)
- Test: extend `test/integration/v1/maker/items_test.rb` (or add `previews_on_items_test.rb`)

- [ ] **Step 1: Failing test** — create an item with a `model` file attachment whose `node_id`/`version_id` has a `ready` thumbnail preview; assert `GET /v1/maker/items/:id` returns the file attachment with a `thumbnail_url`.

- [ ] **Step 2:** In `attachment_json` (items_controller), look up the user's `ready` `thumbnail` preview for `(att.node_id, att.version_id)` and add `thumbnail_url:`. Batch-load to avoid N+1: in `item_json(full:)`, preload `current_user.maker_previews.ready.of_kind("thumbnail").where(node_id: item.file_attachments.map(&:node_id))` into a hash keyed by `[node_id, version_id]`.

- [ ] **Step 3:** Run the items API tests → green; check no N+1 (one preview query per item, not per attachment).

---

## Phase 2 — more formats (each task independent, same job seam)

Each adds a `Maker::Previews::*` renderer + a registry entry in `GeneratePreviewJob#renderer_for`, with its own fixture + `skip "tool not installed"`-guarded test. No schema or API changes.

- [ ] **Task 7 — lbrn2:** `Maker::Previews::Lbrn2` parses the lbrn2 XML in-Ruby (Nokogiri, MIT) → SVG → delegate to `Previews::Svg`. Fixture: a tiny hand-written `.lbrn2` with one `<Shape>`. Map CutSetting stroke colors + rect/ellipse/path per `docs/research-format-processing.md` §1 (port from jlucaso1/lbrn2-to-svg). Registry: `"lbrn2" => Previews::Lbrn2`. No external binary beyond resvg.
- [ ] **Task 8 — 3MF (embedded thumbnail):** `Maker::Previews::ThreeMf` opens the 3MF as a zip (rubyzip, BSD-2), reads `Metadata/thumbnail.png` (or resolves the OPC thumbnail relationship), and if present returns it (resized via image_processing). Fixture: a minimal 3MF zip with a `Metadata/thumbnail.png`. Registry: `"3mf" => Previews::ThreeMf`. **No render needed for the common case** (`docs/research-format-processing.md` §2).
- [ ] **Task 9 — STL/OBJ (F3D):** `Maker::Previews::Mesh` writes the bytes to a tempfile and shells `f3d <in> --output <out.png> --resolution 512,512` headless (BSD-3; OSMesa/EGL offscreen). `available?` checks the `f3d` binary. Fixture: a tiny ASCII-STL cube. Registry: `%w[stl obj] => Previews::Mesh`. (Document the headless-GL env in `docs/` / CI.)
- [ ] **Task 10 — STEP/IGES (F3D subprocess) + 3MF render fallback:** extend `Previews::Mesh` to also accept `step`/`iges` (F3D links OCCT — LGPL stays in the subprocess, `docs/research-format-processing.md` §6/§7), and make `Previews::ThreeMf` fall back to `Previews::Mesh` when no embedded thumbnail exists. Registry: `%w[step stp iges igs] => Previews::Mesh`.
- [ ] **Task 11 (optional) — DXF:** `Maker::Previews::Dxf` shells a tiny `ezdxf` Python script that emits **SVG via the matplotlib backend** (NOT the PyMuPDF/PNG backend — AGPL, `docs/research-format-processing.md` §5/§7) → delegate to `Previews::Svg`. Registry: `"dxf" => Previews::Dxf`.

**Explicitly unsupported (store `failed`, generic icon):** DWG (LibreDWG is GPL), native Fusion `.f3d`, SolidWorks `.sldprt/.sldasm` — no permissive parser. The job already does the right thing (no renderer → `Unsupported` → `status: failed`).

---

## Phase 3 — interactive 3D (later)

- [ ] **Task 12 — `model_glb` kind:** generate a web-friendly **GLB** for true 3D/CAD formats (F3D `--output model.glb`, or occt-import-js→GLB for STEP). Store as a second `Maker::Preview` row with `kind: "model_glb"`.
- [ ] **Task 13 — Three.js viewer (client):** the web/Tauri UI loads the GLB into a **Three.js** viewer (MIT, client-side only — the server never runs WebGL; `docs/research-format-processing.md` §8). Falls back to the `thumbnail` PNG when no GLB exists.

---

## Verification checklist (Phase 1)

- [ ] `bin/rails db:migrate` then `bin/rails test` → all green (existing suite still passes; CLAUDE.md says ~144/0 server tests — don't regress).
- [ ] On a box with `resvg` installed (CI): the SVG job test renders a real PNG (magic bytes asserted) and flips `ready`.
- [ ] `POST /v1/maker/previews` enqueues exactly one job per (node, version, kind); re-POST is idempotent.
- [ ] `GET /v1/maker/previews?node_id=&version_id=` returns the record + a blob `url` when ready; unauthorized without a token.
- [ ] Unsupported extension → `status: failed` + `error`, no crash, no attachment.
- [ ] Tenant isolation: a second user can't see another user's previews (scoped through `current_user.maker_previews`).
- [ ] **Licensing:** no new GPL/AGPL dep (resvg MIT/Apache, rubyzip BSD, Nokogiri MIT, `image_processing` already present, F3D BSD subprocess). Confirm CI installs `resvg` (and later `f3d`) as external binaries, not Ruby gems pulling copyleft.
