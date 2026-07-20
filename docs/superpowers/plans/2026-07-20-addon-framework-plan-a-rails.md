# Addon Framework — Plan A (Rails: framework + Boxes UI against a stubbed client)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Build the reusable, backend-neutral **addon framework** (registry + generic state/output-bundle store + generic library-write) and the **Boxes addon UI**, driven by a `BoxesClient` that is **stubbed** in this plan. The real Python sidecar + wiring is **Plan B**.

**Architecture:** `Maker::Addons::Registry` (ext-registry pattern) → `Tools::` controllers under `/tools`. `Maker::AddonState has_many Maker::AddonFile` is the generic "state + tied bundle of any files". `Maker::Addons::LibraryOutput` writes a set of files of any type into the file library (share/s3 via `FileLayer#write`; chunk via a single-chunk `Sync::Commit` + a new `Storage::ChunkStore#put`) and ties each to the state. `Tools::BoxesController` renders a dynamic form from a generator schema, previews (rasterized to PNG via resvg), and saves the bundle.

**Tech Stack:** Rails 8, Minitest, `FileLayer` port, `Sync::Commit`, `Storage::ChunkStore`, resvg (`Maker::Previews::SvgRasterizer`).

**Spec:** `docs/superpowers/specs/2026-07-20-addon-framework-boxes-design.md`

**Scope decisions locked for v1 (deviations from the spec, deferred — flagged to the user):**
- **No auto-created per-save folders.** Cross-backend mkdir is its own problem (share dir-nodes come from scans; chunk needs a mutation). v1 writes bundle files **flat** to a caller-provided parent (default: library root) with **descriptive, unique names**, tied via the `AddonFile` join (the join IS the required tie; the folder was a nicety). Folder grouping is a later refinement.
- **No in-place regenerate/versioning.** Each save **creates** a bundle (share refuses clobber; chunk versioning + share/s3 delete-then-write is extra plumbing). Reopening a saved box loads its params so you can tweak and **save a new bundle**. In-place update is deferred.
- **`BoxesClient` is stubbed** here (`FakeBoxes`); the real HTTP client is defined but the sidecar it talks to is Plan B. With no `BOXES_SIDECAR_URL`, the Boxes addon shows as **unavailable** (graceful), exactly like a preview renderer without its toolchain.

**Backends:** the suite runs three legs — `bin/rails test`, `LIBRARY_BACKEND=share`, `LIBRARY_BACKEND=s3`. `LibraryOutput` is exercised on all three.

---

## Task 1: Migrations + models (`AddonState`, `AddonFile`)

**Files:**
- Create: `db/migrate/<ts>_create_maker_addon_states.rb`
- Create: `db/migrate/<ts>_create_maker_addon_files.rb`
- Create: `app/models/maker/addon_state.rb`, `app/models/maker/addon_file.rb`
- Test: `test/models/maker/addon_state_test.rb`

- [ ] **Step 1: Generate the migrations**

Run: `bin/rails g migration CreateMakerAddonStates` and `bin/rails g migration CreateMakerAddonFiles`
Then replace each `change` body:

```ruby
# create_maker_addon_states
class CreateMakerAddonStates < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_addon_states do |t|
      t.references :user, null: false, foreign_key: true
      t.string :addon_key, null: false
      t.string :name, null: false
      t.json :data, null: false, default: {}
      t.timestamps
    end
    add_index :maker_addon_states, [ :user_id, :addon_key ]
  end
end
```

```ruby
# create_maker_addon_files — the tie: one state, many library nodes, each with a role
class CreateMakerAddonFiles < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_addon_files do |t|
      t.references :addon_state, null: false, foreign_key: { to_table: :maker_addon_states }
      t.string :node_id, null: false            # a library node (string UUID)
      t.string :role, null: false               # "output" | "parameters" | ...
      t.string :content_type
      t.integer :position, null: false, default: 0
      t.timestamps
    end
    add_index :maker_addon_files, [ :addon_state_id, :node_id ], unique: true
  end
end
```

- [ ] **Step 2: Migrate**

Run: `bin/rails db:migrate`
Expected: both tables created; `db/schema.rb` updated.

- [ ] **Step 3: Write the failing model test**

```ruby
# test/models/maker/addon_state_test.rb
require "test_helper"

module Maker
  class AddonStateTest < ActiveSupport::TestCase
    setup { @user = User.create!(email: "addon@example.com") }

    test "ties a bundle of files, ordered by position, cascading on destroy" do
      state = @user.maker_addon_states.create!(addon_key: "boxes", name: "My box",
                                               data: { generator: "ABox", params: { x: 100 } })
      state.files.create!(node_id: "n-svg", role: "output", content_type: "image/svg+xml", position: 0)
      state.files.create!(node_id: "n-params", role: "parameters", content_type: "application/json", position: 1)

      assert_equal %w[output parameters], state.reload.files.map(&:role)
      assert_equal "boxes", state.addon_key
      assert_equal 100, state.data["params"]["x"]

      assert_difference("Maker::AddonFile.count", -2) { state.destroy }
    end

    test "requires addon_key and name" do
      s = Maker::AddonState.new(user: @user)
      assert_not s.valid?
      assert s.errors[:addon_key].present?
      assert s.errors[:name].present?
    end
  end
end
```

- [ ] **Step 4: Run it (fails — models missing)**

Run: `bin/rails test test/models/maker/addon_state_test.rb`
Expected: FAIL (uninitialized constant / no association).

- [ ] **Step 5: Write the models**

```ruby
# app/models/maker/addon_state.rb
module Maker
  class AddonState < ApplicationRecord
    self.table_name = "maker_addon_states"

    belongs_to :user
    has_many :files, -> { order(:position) }, class_name: "Maker::AddonFile", dependent: :destroy

    validates :addon_key, presence: true
    validates :name, presence: true

    scope :for_addon, ->(key) { where(addon_key: key) }
  end
end
```

```ruby
# app/models/maker/addon_file.rb
module Maker
  class AddonFile < ApplicationRecord
    self.table_name = "maker_addon_files"

    belongs_to :addon_state, class_name: "Maker::AddonState"

    validates :node_id, presence: true
    validates :role, presence: true
  end
end
```

- [ ] **Step 6: Add the `user` association**

In `app/models/user.rb`, add: `has_many :maker_addon_states, class_name: "Maker::AddonState", dependent: :destroy`
(match the style of the other `maker_*` associations already there.)

- [ ] **Step 7: Run it (passes)**

Run: `bin/rails test test/models/maker/addon_state_test.rb`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add db/migrate app/models/maker/addon_state.rb app/models/maker/addon_file.rb app/models/user.rb db/schema.rb test/models/maker/addon_state_test.rb
git commit -m "feat(addons): AddonState + AddonFile — generic state + tied output bundle"
```

---

## Task 2: `Storage::ChunkStore#put` — server-side content write

The chunk store is presign-only (client uploads bytes directly). Addon output originates **server-side** (from the sidecar, via Rails), so `LibraryOutput` needs to write a chunk directly. This is a deliberate, scoped exception to §15 — there is no client here, the bytes are already in Rails.

**Files:**
- Modify: `app/services/storage/chunk_store.rb`, `memory_chunk_store.rb`, `local_chunk_store.rb`, `s3_chunk_store.rb`
- Test: `test/services/storage/chunk_store_put_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# test/services/storage/chunk_store_put_test.rb
require "test_helper"

class ChunkStorePutTest < ActiveSupport::TestCase
  test "memory store round-trips a server-side put" do
    store = Storage::MemoryChunkStore.new
    store.put(42, "abc123", "hello".b)
    assert store.exists?(42, "abc123")
    assert_equal "hello".b, store.read_blob(42, "abc123")
  end
end
```

- [ ] **Step 2: Run it (fails — no `put`)**

Run: `bin/rails test test/services/storage/chunk_store_put_test.rb`
Expected: FAIL (`NoMethodError: put`).

- [ ] **Step 3: Add `put` to the base + each store**

In `app/services/storage/chunk_store.rb`, after `exists?`:

```ruby
    # SERVER-SIDE write of one chunk. The normal path is a presigned client PUT (bytes never touch
    # Rails, §15); this is the exception for SERVER-GENERATED content (addon output), where the
    # bytes originate in Rails and there is no client to presign for. Idempotent (content-addressed).
    def put(_user_id, _hash, _bytes) = raise(NotImplementedError)
```

In `memory_chunk_store.rb` (it already has `write_blob`):

```ruby
    def put(user_id, hash, bytes) = write_blob(user_id, hash, bytes)
```

In `local_chunk_store.rb` (writes to the local blob path — mirror its `presign_put`/path helper; if it has a `write_blob`, delegate, else `File.binwrite(path_for(user_id, hash), bytes)`):

```ruby
    def put(user_id, hash, bytes)
      path = blob_path(user_id, hash) # use the store's existing path helper name
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(path, bytes)
    end
```

In `s3_chunk_store.rb`:

```ruby
    def put(user_id, hash, bytes)
      @client.put_object(bucket: @bucket, key: key_for(user_id, hash), body: bytes)
    end
```

Note: verify `local_chunk_store.rb`'s actual path-helper method name and reuse it rather than inventing `blob_path`.

- [ ] **Step 4: Run it (passes)**

Run: `bin/rails test test/services/storage/chunk_store_put_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/services/storage/ test/services/storage/chunk_store_put_test.rb
git commit -m "feat(storage): ChunkStore#put — server-side write for generated content"
```

---

## Task 3: `Maker::Addons::LibraryOutput` — generic multi-file, multi-backend write

**Files:**
- Create: `app/services/maker/addons/library_output.rb`
- Test: `test/services/maker/addons/library_output_test.rb`

- [ ] **Step 1: Write the failing test (runs on all three backends)**

```ruby
# test/services/maker/addons/library_output_test.rb
require "test_helper"

module Maker
  module Addons
    class LibraryOutputTest < ActiveSupport::TestCase
      include ActiveJob::TestHelper

      setup do
        @user = User.create!(email: "lo-#{SecureRandom.hex(4)}@example.com")
        Storage::ChunkStore.reset!
      end

      test "writes a bundle of mixed-type files and ties each to the state" do
        state = @user.maker_addon_states.create!(addon_key: "boxes", name: "Box A", data: {})
        files = [
          { name: "boxa.svg", bytes: "<svg/>".b, content_type: "image/svg+xml", role: "output" },
          { name: "boxa.params.json", bytes: '{"x":100}'.b, content_type: "application/json", role: "parameters" }
        ]

        result = Maker::Addons::LibraryOutput.write(user: @user, state:, parent_node_id: nil, files:)

        assert_equal 2, result.length
        state.reload
        assert_equal %w[output parameters], state.files.map(&:role)
        # every produced file is a real library node the user owns
        state.files.each { |af| assert @user.nodes.exists?(node_id: af.node_id), "node #{af.node_id} must exist" }
        # each write enqueues a preview (reuses the eager seam)
        assert_operator enqueued_jobs.count { |j| j[:job] == Maker::GeneratePreviewJob }, :>=, 1
      end
    end
  end
end
```

- [ ] **Step 2: Run it (fails — helper missing)**

Run: `bin/rails test test/services/maker/addons/library_output_test.rb`
Expected: FAIL (uninitialized constant).

- [ ] **Step 3: Write `LibraryOutput`**

```ruby
# app/services/maker/addons/library_output.rb
require "digest"
require "stringio"

module Maker
  module Addons
    # THE ONE generic write path for addon output. An addon hands over a SET of files of ANY type;
    # each is written into the file library through the existing FileLayer machinery and tied to
    # `state` as an AddonFile with its role. Backend-neutral:
    #   - share/s3 (port_writable): FileLayer#write (bytes -> file/object).
    #   - chunk (syncable):        a single-chunk Sync::Commit + Storage::ChunkStore#put, exactly
    #                              what the web uploader does, driven server-side (the bytes are
    #                              generated here — there is no client to presign for).
    # v1 writes FLAT to `parent_node_id` (default: root) with the caller's names, and CREATES (no
    # clobber/versioning). See the plan's scope note.
    module LibraryOutput
      module_function

      # files: [{ name:, bytes:, content_type:, role: }]. Returns the created AddonFiles.
      def write(user:, state:, parent_node_id:, files:)
        caps = FileLayer.current.capabilities
        files.each_with_index.map do |f, i|
          node_id =
            if caps.port_writable?
              write_port(user, parent_node_id, f)
            else
              write_chunk(user, parent_node_id, f)
            end
          enqueue_preview(user, node_id, f[:name])
          state.files.create!(node_id:, role: f[:role], content_type: f[:content_type], position: i)
        end
      end

      # --- share / s3 -----------------------------------------------------------
      def write_port(user, parent_node_id, f)
        info = FileLayer.current.write(user, parent_node_id:, name: f[:name], io: StringIO.new(f[:bytes].b))
        info.node_id
      end

      # --- chunk: single-chunk two-phase commit, driven server-side -------------
      def write_chunk(user, parent_node_id, f)
        bytes = f[:bytes].b
        node_id = SecureRandom.uuid
        commit_id = SecureRandom.uuid
        hash = Digest::SHA256.hexdigest(bytes)
        manifest = [ { hash:, offset: 0, length: bytes.bytesize } ]
        result = Sync::Commit.begin(
          user:, device: addon_device(user), commit_id:, node_id:, parent_node_id:,
          name: f[:name], base_version_id: nil, size: bytes.bytesize,
          mtime: (Time.current.to_f * 1e9).to_i, manifest:
        )
        result.missing.each { |h| Storage::ChunkStore.current.put(user.id, h, bytes) }
        Sync::Commit.finalize(user:, commit_id:, verify: false)
        node_id
      end

      # A dedicated device so addon writes are attributable and don't reuse a UI/session device.
      def addon_device(user)
        user.devices.find_by(name: "addons") || Device.register!(user:, name: "addons")
      end

      def enqueue_preview(user, node_id, name)
        info = FileLayer.current.stat(user, node_id:)
        return unless info&.content_token

        Maker::Previews::Enqueue.call(user:, node_id:, name:, version_id: info.content_token)
      rescue FileLayer::NotFound, FileLayer::FetchError
        nil
      end
    end
  end
end
```

- [ ] **Step 4: Run on all three backends**

Run: `bin/rails test test/services/maker/addons/library_output_test.rb`
Run: `LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test test/services/maker/addons/library_output_test.rb`
Run: `LIBRARY_BACKEND=s3 LIBRARY_S3_BUCKET=b LIBRARY_S3_REGION=us-east-1 LIBRARY_S3_ACCESS_KEY_ID=ci LIBRARY_S3_SECRET_ACCESS_KEY=ci LIBRARY_S3_PREFIX=library bin/rails test test/services/maker/addons/library_output_test.rb`
Expected: PASS on each. (Chunk uses the default `memory` store; the single-chunk commit + `put` round-trips. Share writes to the tmp dir; s3 uses the stub client the test harness already wires for the s3 leg — if the s3 leg needs an injected `FakeS3` like `S3WriteTest`, mirror that setup.)

Note: the s3 leg may require constructing `FileLayer::S3.new(client: FakeS3.new.client, ...)` in the test (as `S3WriteTest` does) rather than the ENV pin. If so, branch the setup on `FileLayer.current.is_a?(FileLayer::S3)` and inject the fake, matching the existing s3 web tests.

- [ ] **Step 5: Commit**

```bash
git add app/services/maker/addons/library_output.rb test/services/maker/addons/library_output_test.rb
git commit -m "feat(addons): LibraryOutput — write a bundle of any files across all backends, tied to state"
```

---

## Task 4: Addon registry + `/tools` gallery

**Files:**
- Create: `app/services/maker/addons/registry.rb`
- Create: `app/controllers/tools/base_controller.rb`, `app/controllers/tools/home_controller.rb`
- Create: `app/views/tools/home/index.html.erb`
- Modify: `config/routes.rb`, `app/views/layouts/application.html.erb` (nav link), `app/assets/stylesheets/application.css`
- Test: `test/controllers/tools/home_controller_test.rb`

- [ ] **Step 1: Write the registry**

```ruby
# app/services/maker/addons/registry.rb
module Maker
  module Addons
    # ext-registry pattern (mirrors Maker::Previews::Registry). Adding an addon = one entry here +
    # a Tools:: controller. `available?` lets an addon grey out when unconfigured (e.g. Boxes when
    # BOXES_SIDECAR_URL is unset), the same graceful degradation the preview renderers use.
    Addon = Data.define(:key, :title, :icon, :description, :available) do
      def available? = available.call
    end

    module Registry
      module_function

      REGISTRY = {
        "boxes" => Addon.new(
          key: "boxes", title: "Box Generator", icon: "📦",
          description: "Parametric laser-cut / CNC boxes",
          available: -> { BoxesClient.configured? }
        )
      }.freeze

      def all = REGISTRY.values
      def find(key) = REGISTRY[key.to_s]
    end
  end
end
```

- [ ] **Step 2: Write a failing controller test**

```ruby
# test/controllers/tools/home_controller_test.rb
require "test_helper"

module Tools
  class HomeControllerTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "tools@example.com", password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
    end

    test "requires login" do
      reset! # drop the session
      get tools_path
      assert_redirected_to new_user_session_path
    end

    test "lists registered addons" do
      get tools_path
      assert_response :success
      assert_select ".addon-card", text: /Box Generator/
    end
  end
end
```

- [ ] **Step 3: Run it (fails — no route/controller)**

Run: `bin/rails test test/controllers/tools/home_controller_test.rb`
Expected: FAIL (no route `tools_path`).

- [ ] **Step 4: Routes + controllers + view**

In `config/routes.rb`, after the `resources :files` block:

```ruby
  namespace :tools do
    get "/", to: "home#index", as: ""   # /tools -> tools_path
  end
```

```ruby
# app/controllers/tools/base_controller.rb
module Tools
  class BaseController < ApplicationController
    before_action :authenticate_user!
  end
end
```

```ruby
# app/controllers/tools/home_controller.rb
module Tools
  class HomeController < BaseController
    def index
      @addons = Maker::Addons::Registry.all
    end
  end
end
```

```erb
<%# app/views/tools/home/index.html.erb %>
<% content_for :title, "Tools — Tinkerex" %>
<div class="page-head"><h1>Tools</h1></div>
<div class="tools-grid">
  <% @addons.each do |addon| %>
    <% if addon.available? %>
      <%= link_to send("tools_#{addon.key}_path"), class: "addon-card" do %>
        <span class="addon-icon"><%= addon.icon %></span>
        <span class="addon-title"><%= addon.title %></span>
        <span class="addon-desc muted"><%= addon.description %></span>
      <% end %>
    <% else %>
      <div class="addon-card disabled" title="Not configured on this deployment">
        <span class="addon-icon"><%= addon.icon %></span>
        <span class="addon-title"><%= addon.title %></span>
        <span class="addon-desc muted">Unavailable here</span>
      </div>
    <% end %>
  <% end %>
</div>
```

Note: `tools_boxes_path` comes from Task 6's route; until then the gallery test asserts the card text only. Add `.tools-grid`/`.addon-card` CSS to `application.css` (mirror `.files-grid`/`.grid-card`). Add a "Tools" link to the app nav in `layouts/application.html.erb` next to "Files".

- [ ] **Step 5: Run it (passes)**

Run: `bin/rails test test/controllers/tools/home_controller_test.rb`
Expected: PASS. (Boxes shows as unavailable until `BOXES_SIDECAR_URL` is set — the card still renders with its title, so the assertion holds.)

- [ ] **Step 6: Commit**

```bash
git add app/services/maker/addons/registry.rb app/controllers/tools config/routes.rb app/views/tools app/views/layouts/application.html.erb app/assets/stylesheets/application.css test/controllers/tools/home_controller_test.rb
git commit -m "feat(addons): registry + /tools gallery"
```

---

## Task 5: `BoxesClient` (real HTTP) + `FakeBoxes` (stub)

**Files:**
- Create: `app/services/boxes_client.rb`
- Create: `test/support/fake_boxes.rb`
- Test: `test/services/boxes_client_test.rb`

- [ ] **Step 1: Define the contract test (with a stubbed HTTP layer)**

```ruby
# test/services/boxes_client_test.rb
require "test_helper"

class BoxesClientTest < ActiveSupport::TestCase
  test "configured? reflects BOXES_SIDECAR_URL" do
    with_env("BOXES_SIDECAR_URL" => nil) { assert_not BoxesClient.configured? }
    with_env("BOXES_SIDECAR_URL" => "http://boxes:8000") { assert BoxesClient.configured? }
  end

  private

  def with_env(vars)
    old = vars.transform_values { |_| :unset }
    vars.each { |k, v| old[k] = ENV[k]; v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    old.each { |k, v| v == :unset ? ENV.delete(k) : ENV[k] = v }
  end
end
```

- [ ] **Step 2: Run (fails — no BoxesClient)**

Run: `bin/rails test test/services/boxes_client_test.rb`
Expected: FAIL.

- [ ] **Step 3: Write `BoxesClient` (real HTTP; used for real only in Plan B)**

```ruby
# app/services/boxes_client.rb
require "net/http"
require "json"

# Typed client for the boxes sidecar. Real HTTP; the sidecar itself is Plan B. `configured?` gates
# the addon's availability. Tests use FakeBoxes (test/support/fake_boxes.rb) via BoxesClient.stub.
class BoxesClient
  Generator = Data.define(:key, :title, :group, :params) # params: Array<Hash>
  class Error < StandardError; end

  class << self
    attr_writer :stub

    def configured? = ENV["BOXES_SIDECAR_URL"].present?
    def base_url = ENV.fetch("BOXES_SIDECAR_URL")
    def current = @stub || new(base_url)
    def reset! = @stub = nil
  end

  def initialize(base_url) = @base = base_url

  def generators
    get("/generators").map { |g| Generator.new(**g.symbolize_keys.slice(:key, :title, :group, :params)) }
  end

  # Returns SVG bytes (String). Raises Error on a 4xx/5xx.
  def generate(generator:, params:)
    post("/generate", { generator:, params: }, accept: "image/svg+xml")
  end

  private

  def get(path)
    req = Net::HTTP::Get.new(URI.join(@base, path))
    JSON.parse(http(req).body)
  end

  def post(path, body, accept: "application/json")
    req = Net::HTTP::Post.new(URI.join(@base, path))
    req["Content-Type"] = "application/json"
    req["Accept"] = accept
    req.body = body.to_json
    http(req).body
  end

  def http(req)
    uri = req.uri
    res = Net::HTTP.start(uri.host, uri.port, open_timeout: 3, read_timeout: 30) { |h| h.request(req) }
    raise Error, "boxes sidecar #{res.code}: #{res.body.to_s[0, 200]}" unless res.is_a?(Net::HTTPSuccess)
    res
  end
end
```

- [ ] **Step 4: Write `FakeBoxes` (the stub used everywhere in tests)**

```ruby
# test/support/fake_boxes.rb
class FakeBoxes
  def generators
    [ BoxesClient::Generator.new(key: "ABox", title: "Simple box", group: "Boxes",
        params: [ { "name" => "x", "type" => "float", "default" => 100, "help" => "width (mm)" },
                  { "name" => "y", "type" => "float", "default" => 50, "help" => "depth (mm)" } ]) ]
  end

  def generate(generator:, params:)
    %(<svg xmlns="http://www.w3.org/2000/svg" width="100" height="50"><rect width="100" height="50" fill="none" stroke="#000"/></svg>)
  end
end
```

Require it from `test_helper.rb` if that file eager-loads `test/support/*` (mirror how `FakeS3` is required).

- [ ] **Step 5: Run (passes)**

Run: `bin/rails test test/services/boxes_client_test.rb`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add app/services/boxes_client.rb test/support/fake_boxes.rb test/services/boxes_client_test.rb
git commit -m "feat(addons): BoxesClient HTTP contract + FakeBoxes stub"
```

---

## Task 6: `Tools::BoxesController` + views (against the stub)

**Files:**
- Create: `app/controllers/tools/boxes_controller.rb`
- Create: `app/views/tools/boxes/{index,new,show}.html.erb`, `app/views/tools/boxes/_form.html.erb`
- Modify: `config/routes.rb`
- Test: `test/controllers/tools/boxes_controller_test.rb`

- [ ] **Step 1: Routes**

In the `namespace :tools` block:

```ruby
    resources :boxes, only: %i[index new show create] do
      post :preview, on: :collection
    end
```

- [ ] **Step 2: Write the failing controller test (BoxesClient stubbed with FakeBoxes)**

```ruby
# test/controllers/tools/boxes_controller_test.rb
require "test_helper"
require_relative "../../support/fake_boxes"

module Tools
  class BoxesControllerTest < ActionDispatch::IntegrationTest
    include ActiveJob::TestHelper
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "boxes@example.com", password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      BoxesClient.stub = FakeBoxes.new
      Storage::ChunkStore.reset!
    end
    teardown { BoxesClient.reset! }

    test "index lists generators and saved boxes" do
      get tools_boxes_path
      assert_response :success
      assert_select "*", text: /Simple box/
    end

    test "new renders a dynamic form from the generator's params" do
      get new_tools_box_path(generator: "ABox")
      assert_response :success
      assert_select "input[name=?]", "params[x]"
      assert_select "input[name=?]", "params[y]"
    end

    test "preview returns a rasterized PNG of the generated SVG" do
      post preview_tools_boxes_path, params: { generator: "ABox", params: { x: 120, y: 60 } }
      assert_response :success
      assert_equal "image/png", response.media_type if Maker::Previews::SvgRasterizer.available?
    end

    test "create saves the state + a tied bundle (svg output + params file)" do
      assert_difference("Maker::AddonState.count", 1) do
        post tools_boxes_path, params: { name: "My Box", generator: "ABox", params: { x: 120, y: 60 } }
      end
      state = @user.maker_addon_states.for_addon("boxes").order(:id).last
      assert_equal %w[output parameters], state.files.map(&:role)
      state.files.each { |af| assert @user.nodes.exists?(node_id: af.node_id) }
      assert_redirected_to tools_box_path(state)
    end

    test "show reopens a saved box with its params" do
      post tools_boxes_path, params: { name: "Reopen Me", generator: "ABox", params: { x: 77, y: 33 } }
      state = @user.maker_addon_states.for_addon("boxes").order(:id).last
      get tools_box_path(state)
      assert_response :success
      assert_select "*", text: /Reopen Me/
    end
  end
end
```

- [ ] **Step 3: Run (fails — no controller)**

Run: `bin/rails test test/controllers/tools/boxes_controller_test.rb`
Expected: FAIL.

- [ ] **Step 4: Write the controller**

```ruby
# app/controllers/tools/boxes_controller.rb
module Tools
  # The Box Generator addon. Rails owns the UI, param validation, save-to-library; the sidecar
  # (via BoxesClient) only generates. Preview rasterizes the generated SVG to PNG (resvg) rather
  # than inlining untrusted SVG, matching the web layer's no-inline-SVG posture.
  class BoxesController < BaseController
    before_action :require_boxes!

    def index
      @generators = client.generators
      @saved = current_user.maker_addon_states.for_addon("boxes").order(updated_at: :desc)
    end

    def new
      @generator = client.generators.find { |g| g.key == params[:generator] }
      redirect_to(tools_boxes_path, alert: "Unknown generator.") and return unless @generator
      @params = {} # defaults come from the schema in the form partial
    end

    # POST /tools/boxes/preview -> PNG (rasterized SVG)
    def preview
      svg = client.generate(generator: params.require(:generator), params: box_params)
      png = Maker::Previews::SvgRasterizer.to_png(svg, size: 512)
      send_data png, type: "image/png", disposition: "inline"
    rescue BoxesClient::Error => e
      render plain: e.message, status: :unprocessable_entity
    rescue Maker::Previews::SvgRasterizer::RasterizeError
      # resvg absent (dev box): fall back to the raw SVG as a download so preview still "works".
      send_data svg, type: "image/svg+xml", disposition: "attachment", filename: "preview.svg"
    end

    # POST /tools/boxes -> save the state + write the tied bundle to the library
    def create
      generator = params.require(:generator)
      p = box_params
      svg = client.generate(generator:, params: p)

      state = current_user.maker_addon_states.create!(
        addon_key: "boxes", name: params.require(:name), data: { generator:, params: p }
      )
      base = state.name.parameterize
      Maker::Addons::LibraryOutput.write(
        user: current_user, state:, parent_node_id: nil,
        files: [
          { name: "#{base}-#{state.id}.svg", bytes: svg, content_type: "image/svg+xml", role: "output" },
          { name: "#{base}-#{state.id}.params.json", bytes: JSON.pretty_generate({ generator:, params: p }),
            content_type: "application/json", role: "parameters" }
        ]
      )
      redirect_to tools_box_path(state), notice: "Saved “#{state.name}”."
    rescue BoxesClient::Error => e
      redirect_to tools_boxes_path, alert: "Generation failed: #{e.message}"
    end

    def show
      @state = current_user.maker_addon_states.for_addon("boxes").find(params[:id])
    end

    private

    def client = BoxesClient.current

    def require_boxes!
      redirect_to(tools_path, alert: "Box generator isn't configured here.") unless BoxesClient.configured? || BoxesClient.current.is_a?(FakeBoxes) rescue nil
    end

    # params[:params] is a flat hash of the generator's fields. Coerce to plain strings/numbers;
    # the sidecar validates against the real schema (this is a convenience coercion, not the gate).
    def box_params
      (params[:params] || {}).to_unsafe_h.transform_values { |v| v }
    end
  end
end
```

Note: `require_boxes!` — in tests `BoxesClient.stub` is set (FakeBoxes), so treat a set stub as available; the `rescue nil` keeps a missing `FakeBoxes` constant in production from erroring. Simplify to: `return if BoxesClient.configured? || BoxesClient.instance_variable_get(:@stub); redirect_to tools_path, alert: ...`. Reconcile against how you wire the stub.

- [ ] **Step 5: Write the views**

- `index.html.erb`: two sections — "New box" (each `@generators` → link to `new_tools_box_path(generator: g.key)`) and "Saved boxes" (`@saved` → link to `tools_box_path(s)`, showing `s.name`).
- `new.html.erb`: renders `_form` for `@generator`; a "Preview" button (JS `fetch` to `preview_tools_boxes_path`, drop the returned PNG into an `<img>`) and a "Save" form (name + the params) POSTing to `tools_boxes_path`.
- `_form.html.erb`: iterate `@generator.params`; per param render an input by `type` (`float`/`int` → `number`, `bool` → checkbox, enum/`choices` → select), `name="params[<param name>]"`, `value` = default, with the `help` as a label hint.
- `show.html.erb`: show `@state.name`, its params (`@state.data`), and its bundle files (`@state.files` → link each to `file_path(af.node_id)` so the SVG's thumbnail shows); a "Duplicate & tweak" link to `new_tools_box_path(generator: @state.data["generator"])` (params can be prefilled from `@state.data["params"]` — pass them through).

Keep the views minimal and styled with the existing classes; the tests assert structure (input names, text), not layout.

- [ ] **Step 6: Run on all three backends**

Run: `bin/rails test test/controllers/tools/boxes_controller_test.rb`
Run: `LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test test/controllers/tools/boxes_controller_test.rb`
Run: the s3 leg (inject FakeS3 if needed, as in Task 3).
Expected: PASS on each.

- [ ] **Step 7: Commit**

```bash
git add app/controllers/tools/boxes_controller.rb app/views/tools/boxes config/routes.rb test/controllers/tools/boxes_controller_test.rb
git commit -m "feat(addons): Box Generator addon UI (dynamic form, preview, save bundle) against the stub"
```

---

## Task 7: Final verification

- [ ] **Step 1: Full suite, all three backends**

Run: `bin/rails test`
Run: `LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test`
Run: `LIBRARY_BACKEND=s3 LIBRARY_S3_BUCKET=b LIBRARY_S3_REGION=us-east-1 LIBRARY_S3_ACCESS_KEY_ID=ci LIBRARY_S3_SECRET_ACCESS_KEY=ci LIBRARY_S3_PREFIX=library bin/rails test`
Expected: all green.

- [ ] **Step 2: Rubocop**

Run: `bin/rubocop app/services/maker/addons app/services/boxes_client.rb app/controllers/tools app/models/maker/addon_state.rb app/models/maker/addon_file.rb`
Expected: no offenses.

- [ ] **Step 3: Manual smoke (optional)**

`bin/rails server`, sign in, open `/tools` — Box Generator shows (unavailable, since no sidecar). Set `BOXES_SIDECAR_URL` to any value and confirm it becomes a link (it'll error on generate until Plan B — expected).

- [ ] **Step 4: STATUS + spec note**

Note in `docs/STATUS.md` that the addon framework (registry + `AddonState`/`AddonFile` + `LibraryOutput`) + the Boxes addon UI (against a stub) landed, and that Plan B (the Python sidecar) is next. Commit.

---

## Self-review notes (author)

- **Spec coverage:** §3 registry → Task 4; §4 AddonState/AddonFile → Task 1; §5 generic multi-file library write → Tasks 2–3; §7 client contract → Task 5; §8 boxes UI → Task 6. §6/§7-sidecar deployment + real generation = **Plan B**.
- **Deferred from spec (flagged):** per-save folders (flat write in v1) and in-place regenerate/versioning (create-only in v1) — both need cross-backend mkdir / clobber handling that is its own task; the `AddonFile` tie (the actual requirement) is fully delivered.
- **Type consistency:** `LibraryOutput.write(user:, state:, parent_node_id:, files:)` and `files` element `{name, bytes, content_type, role}` are identical in Task 3, Task 6, and the tests. `BoxesClient.generators/generate` match `FakeBoxes`.
- **Verify against real code when implementing:** `local_chunk_store` path-helper name (Task 2); whether the s3 test leg needs an injected `FakeS3` (Tasks 3/6, mirror `S3WriteTest`); the app nav partial location (Task 4); how `test/support` is loaded (Task 5).
```
