# Addon host surface + `generators` as a runtime bundle — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the generic addon host surface — manifest-driven registry, shell page, asset proxy, save endpoint — and migrate `generators` onto it as a runtime-loaded manifest + plain-ESM bundle, deleting its per-addon Ruby.

**Architecture:** `Maker::Addons::Source` fetches an addon index and assets over HTTP from `ADDON_SOURCE_URL`. `Registry` is populated from those manifests and cached, degrading to "no addons" rather than 500ing. One `Tools::AddonsController` serves every addon: a shell page that mounts the bundle, a same-origin asset proxy, and a save endpoint onto the existing `Maker::Addons::LibraryOutput`. An addon bundle exports `mount(element, context)` — no Stimulus dependency, no host framework coupling.

**Tech Stack:** Rails 8.1, Ruby 3.4.7, Zeitwerk, importmap-rails 2.2.3, propshaft, Minitest, Capybara + headless Chrome.

---

## Scope

Phase A of `docs/superpowers/specs/2026-08-02-addons-runtime-bundle-design.md`: the host surface (§3.1-3.3) plus migration step 1 (`generators`, spec §7).

**Deliberately NOT in this plan:**

- **The service proxy** (`POST /tools/:key/service/:name/*path`). `generators` is client-only with no sidecar, so building the proxy here would be untested speculation. It lands with `openscad`, which needs it.
- **The addons repo and its static container.** During this phase `ADDON_SOURCE_URL` points at the host's own `public/addons/`, served over real HTTP so the proxy path is genuinely exercised. Phase B creates the repo, moves the bundle, and repoints the env var — that is when independent deploy actually turns on. Building infrastructure before the mechanism is proven repeats the mistake this repo's own §15 warns about.
- **`openscad` and `boxes`.** Their plans get written once a working example exists.
- **Asset caching.** The proxy fetches from the source on every request. That is a performance
  concern, not a correctness one, and spec §8 risk 3 warns that a *stale* cached bundle reads as "my
  fix didn't deploy" — which is worse than a slow one. Phase A leaves it uncached deliberately, so
  the caching design can be made against a working pipeline with a real content hash to key on
  rather than guessed at now. The manifest index *is* cached (5-minute TTL), because that is what
  makes republishing a bundle the deploy.

**Baseline:** branch `claude/addons-runtime-bundles` off `main` at `9b1ddb6`. Nothing from the abandoned engine-gem attempt (PR #115) is present; do not expect `Tools::BoxesClient`, `SDK_VERSION`, or `Registry.register` to exist.

---

## File Structure

**Created:**

| Path | Responsibility |
|---|---|
| `app/services/maker/addons/source.rb` | HTTP client for the addon source: the manifest index and raw assets. Rejects traversal in asset paths. Nothing else. |
| `app/controllers/tools/addons_controller.rb` | The whole generic addon surface: `show` (shell), `asset` (proxy, **uncached in Phase A** — see below), `create` (save). |
| `app/views/tools/addons/show.html.erb` | The shell page — a mount point plus the host context as data attributes. |
| `app/javascript/controllers/addon_controller.js` | Loads the addon bundle, calls its `mount(el, ctx)`, nothing addon-specific. |
| `public/addons/manifests.json` | **Transitional** (Phase B deletes it): the addon index. |
| `public/addons/generators/{manifest fields inline, generators.js, makerjs.js, …}` | **Transitional:** the `generators` bundle and its vendored deps. |
| `test/support/fake_addon_source.rb` | Test double for `Source`, mirroring `test/support/fake_boxes.rb`. |
| `test/services/maker/addons/source_test.rb` | Source fetching + traversal rejection. |
| `test/services/maker/addons/registry_test.rb` | Manifest-driven registration, caching, degradation, api_version filtering. |
| `test/controllers/tools/addons_controller_test.rb` | Shell, asset proxy, save. |
| `test/system/addon_bundle_test.rb` | The bundle actually mounts and renders in a real browser. |

**Modified:**

| Path | Change |
|---|---|
| `app/services/maker/addons/registry.rb` | Frozen `REGISTRY` hash → manifest-driven, cached, degrading. `Addon` gains `pins` + `entry`. |
| `config/routes.rb` | Add the three generic addon routes; delete the `generators` routes. **Ordering matters — see Task 4.** |
| `app/views/tools/home/index.html.erb` | `send("tools_#{addon.key}_path")` → `tools_addon_path(addon.key)`. |
| `app/views/layouts/application.html.erb` | `javascript_importmap_tags` renders `@importmap` when set. |
| `config/environments/{development,test}.rb` or `config/initializers` | `ADDON_SOURCE_URL` default for local/dev. |

**Deleted (Task 7):** `app/controllers/tools/generators_controller.rb`, `app/views/tools/generators/`, `app/javascript/controllers/generator_controller.js`, `app/javascript/generators/`, and the `makerjs`/`bezier-js`/`clone`/`graham_scan`/`kdbush` pins from `config/importmap.rb`.

---

## Task 0: Spike — per-page merged importmap (GO/NO-GO)

Not TDD. One falsifiable question: **can a page render an importmap merged from the host's pins plus addon-supplied pins, such that a proxied module importing a bare specifier resolves?**

This matters because `vendor/javascript/makerjs.js` imports its four dependencies by bare specifier — verified: `from"bezier-js"`, `from"clone"`, `from"graham_scan"`, `from"kdbush"`. Relative URLs cannot resolve those, and a document may have only one importmap. If merging doesn't work cleanly, the manifest's `pins` concept is not viable and the fallback is that Phase A addons use host-pinned libraries (with pins deferred to Phase B).

`bin/rails test:system TEST=…` does **not** work on this Rails version — use `bin/rails test <path>`.

**Files:** all temporary, reverted in step 6.

- [ ] **Step 1: Add a throwaway probe route and controller action**

In `config/routes.rb`, immediately before the `# --- Addons (Tools)` comment block, add:

```ruby
  get "spike/importmap", to: "spike#show" unless Rails.env.production?
```

Create `app/controllers/spike_controller.rb`:

```ruby
class SpikeController < ApplicationController
  before_action :authenticate_user!

  def show
    @importmap = Importmap::Map.new
    Rails.application.config.importmap.paths.each { |path| @importmap.draw(path) }
    @importmap.pin "spikelib", to: "/spike/asset/spikelib.js"
    render layout: "application"
  end
end
```

- [ ] **Step 2: Make the layout able to render a per-page importmap**

In `app/views/layouts/application.html.erb`, replace the `javascript_importmap_tags` line with:

```erb
    <%= javascript_importmap_tags "application", importmap: (@importmap || Rails.application.importmap) %>
```

- [ ] **Step 3: Serve the probe module and a view**

Create `public/spike/asset/spikelib.js` (Rails serves `public/` directly):

```javascript
import makerjs from "makerjs"
export default function spikelib() {
  return `lib-ok:${typeof makerjs.model.addCaption}`
}
```

The `makerjs` import is the point: it is a **bare specifier inside a module served from a non-asset path**, and makerjs in turn bare-imports its own four deps. If this resolves, the whole chain resolves.

Create `app/views/spike/show.html.erb`:

```erb
<div id="spike-probe">pending</div>
<script type="module">
  import spikelib from "spikelib"
  document.getElementById("spike-probe").textContent = `spike-ok:${spikelib()}`
</script>
```

- [ ] **Step 4: Write the spike system test**

Create `test/system/importmap_merge_spike_test.rb`:

```ruby
require "application_system_test_case"

# THROWAWAY (plan Task 0). Asserted in a real browser, not by reading the rendered importmap —
# a rendered importmap that parses is not one that resolves (CLAUDE.md §14e).
class ImportmapMergeSpikeTest < ApplicationSystemTestCase
  setup { sign_in_as "spike@example.com" }

  test "a page-level merged importmap resolves an addon pin and its transitive bare imports" do
    visit "/spike/importmap"
    assert_selector "#spike-probe", text: /\Aspike-ok:lib-ok:function\z/
    assert_no_console_errors
  end
end
```

- [ ] **Step 5: Run it — this is the GO/NO-GO**

Run: `bin/rails test test/system/importmap_merge_spike_test.rb`

| Outcome | Meaning | Consequence |
|---|---|---|
| PASS | Merged per-page importmap works, and bare specifiers resolve transitively | **GO** — manifest `pins` are viable, build Tasks 1-7 as written |
| `#spike-probe` still `pending`, console shows a module-resolution error for `spikelib` | The merged map didn't render or didn't take | **NO-GO on pins** — Phase A addons use host-pinned libraries; drop `pins` from the manifest and from Tasks 2/3, and defer to Phase B |
| Resolves `spikelib` but fails on `bezier-js` etc. | Page-level pins work; transitive bare imports don't | **PARTIAL** — the addon must ship deps it can reference itself; report and stop |

- [ ] **Step 6: Tear down completely**

```bash
git checkout -- config/routes.rb app/views/layouts/application.html.erb
rm -rf app/controllers/spike_controller.rb app/views/spike public/spike test/system/importmap_merge_spike_test.rb
git status --short
```

Expected: no output. Nothing from this task is committed.

- [ ] **Step 7: Report the outcome before continuing**

State which outcome occurred. On NO-GO or PARTIAL, **stop and report** — Tasks 2 and 3 change shape, and that is a decision for the plan's author, not a workaround to invent.

---

## Task 1: `Maker::Addons::Source`

**Files:**
- Create: `app/services/maker/addons/source.rb`
- Create: `test/support/fake_addon_source.rb`
- Test: `test/services/maker/addons/source_test.rb`

- [ ] **Step 1: Write the failing test**

`test/services/maker/addons/source_test.rb`:

```ruby
require "test_helper"

module Maker
  module Addons
    class SourceTest < ActiveSupport::TestCase
      setup do
        @prior = ENV["ADDON_SOURCE_URL"]
        ENV["ADDON_SOURCE_URL"] = "http://addons.test"
      end

      teardown do
        ENV["ADDON_SOURCE_URL"] = @prior
        Source.reset!
      end

      test "configured? follows ADDON_SOURCE_URL" do
        assert Source.configured?
        ENV.delete("ADDON_SOURCE_URL")
        assert_not Source.configured?
      end

      test "asset_path! rejects traversal instead of normalizing it" do
        # REJECTS, never normalizes — the same rule as FileLayer::S3#key_for (§14a). expand_path
        # would turn "a/../../b" into a VALID path and silently fetch the wrong object.
        %w[../secret a/../../etc/passwd /abs .. a/./b].each do |bad|
          assert_raises(Source::Error, "expected #{bad.inspect} to be refused") do
            Source.new("http://addons.test").asset_path!(bad)
          end
        end
      end

      test "asset_path! accepts an ordinary nested path" do
        source = Source.new("http://addons.test")
        assert_equal "generators/makerjs.js", source.asset_path!("generators/makerjs.js")
      end

      test "a malformed manifest index raises Source::Error, not a JSON error" do
        source = Source.new("http://addons.test")
        source.stub(:get, "not json at all") do
          assert_raises(Source::Error) { source.manifests }
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/services/maker/addons/source_test.rb`

Expected: `NameError: uninitialized constant Maker::Addons::Source`

- [ ] **Step 3: Write the implementation**

`app/services/maker/addons/source.rb`:

```ruby
require "net/http"
require "json"

module Maker
  module Addons
    # Fetches the addon index and addon assets from the configured source over HTTP. Mirrors the
    # shape of the sidecar clients (`configured?` gates availability; a `stub` seam for tests) so it
    # reads like the rest of this layer.
    #
    # The source is a dumb static host. It is NOT trusted to name its own location: `ADDON_SOURCE_URL`
    # is the host's own config, never anything a manifest supplies — a manifest-supplied URL would be
    # an SSRF primitive pointed at the internal network (spec §4.1).
    class Source
      class Error < StandardError; end

      READ_TIMEOUT = 5
      OPEN_TIMEOUT = 2

      class << self
        attr_writer :stub

        def configured? = ENV["ADDON_SOURCE_URL"].present?
        def base_url = ENV.fetch("ADDON_SOURCE_URL")
        def current = @stub || new(base_url)
        def reset! = @stub = nil
      end

      def initialize(base_url) = @base = base_url.to_s.chomp("/")

      # The index: an Array of manifest Hashes. Anything else is a malformed source.
      def manifests
        parsed = JSON.parse(get("/manifests.json"))
        raise Error, "manifests.json must be an array, got #{parsed.class}" unless parsed.is_a?(Array)

        parsed
      rescue JSON::ParserError => e
        raise Error, "malformed manifests.json: #{e.message}"
      end

      # Raw bytes for one addon asset. `path` is attacker-influenced (it comes off the URL), so it is
      # REJECTED, never normalized — expand_path would turn "a/../../b" into a *valid* path and
      # silently fetch the wrong file. Same rule, same reason, as FileLayer::S3#key_for (§14a).
      def asset(key, path) = get("/#{key}/#{asset_path!(path)}")

      def asset_path!(path)
        p = path.to_s
        raise Error, "empty asset path" if p.empty?
        raise Error, "absolute asset path refused: #{p.inspect}" if p.start_with?("/")
        raise Error, "traversal refused: #{p.inspect}" if p.split("/").any? { |seg| seg == ".." || seg == "." || seg.empty? }

        p
      end

      private

      def get(path)
        uri = URI.parse("#{@base}#{path}")
        res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                              open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
          http.get(uri.request_uri)
        end
        raise Error, "#{path} -> HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)

        res.body
      rescue SystemCallError, Net::OpenTimeout, Net::ReadTimeout, SocketError => e
        raise Error, "#{path} -> #{e.class}: #{e.message}"
      end
    end
  end
end
```

- [ ] **Step 4: Write the test double**

`test/support/fake_addon_source.rb`:

```ruby
# Test double for Maker::Addons::Source, mirroring test/support/fake_boxes.rb. Injected via
# `Maker::Addons::Source.stub = FakeAddonSource.new(...)`; reset in teardown.
class FakeAddonSource
  attr_reader :manifests, :assets

  def initialize(manifests: [], assets: {})
    @manifests = manifests
    @assets = assets
  end

  # Mirrors the real Source's refusal so a test cannot pass against a fake that is more permissive
  # than the code — a fake sharing the code's misunderstanding confirms it (§14e).
  def asset(key, path)
    Maker::Addons::Source.new("http://fake").asset_path!(path)
    @assets.fetch("#{key}/#{path}") { raise Maker::Addons::Source::Error, "missing #{key}/#{path}" }
  end
end
```

- [ ] **Step 5: Run the tests**

Run: `bin/rails test test/services/maker/addons/source_test.rb`

Expected: `4 runs, 0 failures, 0 errors, 0 skips`

- [ ] **Step 6: Mutation-check the traversal guard (§15)**

Temporarily replace `asset_path!`'s body with `path.to_s`. Run the test.

Expected: **RED** on "asset_path! rejects traversal instead of normalizing it". Restore and confirm green. A guard that has never failed has not been shown to work.

- [ ] **Step 7: Commit**

```bash
git add app/services/maker/addons/source.rb test/support/fake_addon_source.rb \
        test/services/maker/addons/source_test.rb
git commit -m "feat(addons): Maker::Addons::Source — fetch addon manifests and assets

Rejects traversal in asset paths rather than normalizing, the same rule as
FileLayer::S3#key_for. Mutation-checked.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 2: Manifest-driven `Registry`

**Files:**
- Modify: `app/services/maker/addons/registry.rb` (replace whole file)
- Test: `test/services/maker/addons/registry_test.rb`

- [ ] **Step 1: Write the failing test**

`test/services/maker/addons/registry_test.rb`:

```ruby
require "test_helper"
require_relative "../../../support/fake_addon_source"

module Maker
  module Addons
    class RegistryTest < ActiveSupport::TestCase
      MANIFEST = {
        "key" => "generators", "title" => "Generators", "icon" => "✏️",
        "description" => "Parametric 2D drawings", "api_version" => "1",
        "entry" => "generators.js", "pins" => { "makerjs" => "makerjs.js" }
      }.freeze

      setup do
        Rails.cache.clear
        Source.stub = FakeAddonSource.new(manifests: [ MANIFEST ])
      end

      teardown do
        Source.reset!
        Rails.cache.clear
      end

      test "builds addons from the source's manifests" do
        addon = Registry.find("generators")
        assert_equal "Generators", addon.title
        assert_equal "generators.js", addon.entry
        assert_equal({ "makerjs" => "makerjs.js" }, addon.pins)
        assert addon.available?
      end

      test "all is ordered by [title, key], not source order" do
        Source.stub = FakeAddonSource.new(manifests: [
          MANIFEST.merge("key" => "z", "title" => "Zebra"),
          MANIFEST.merge("key" => "a", "title" => "Aardvark")
        ])
        Rails.cache.clear
        assert_equal %w[Aardvark Zebra], Registry.all.map(&:title)
      end

      test "an addon declaring an unsupported api_version is skipped, not raised on" do
        # One bad addon must not take the gallery down. Greying out is the whole point of the
        # `available?` design; refusing to boot would be strictly worse.
        Source.stub = FakeAddonSource.new(manifests: [ MANIFEST.merge("api_version" => "99") ])
        Rails.cache.clear
        assert_empty Registry.all
      end

      test "a manifest missing a required key is skipped, not raised on" do
        Source.stub = FakeAddonSource.new(manifests: [ MANIFEST.except("entry") ])
        Rails.cache.clear
        assert_empty Registry.all
      end

      test "an unreachable source degrades to no addons rather than raising" do
        # THE FAILURE THAT MATTERS. /tools must render an empty gallery, never a 500, when the
        # addon host is down.
        failing = Object.new
        def failing.manifests = raise(Source::Error, "boom")
        Source.stub = failing
        Rails.cache.clear
        assert_empty Registry.all
      end

      test "a failed fetch is NOT cached, so recovery does not wait out the TTL" do
        failing = Object.new
        def failing.manifests = raise(Source::Error, "boom")
        Source.stub = failing
        assert_empty Registry.all

        Source.stub = FakeAddonSource.new(manifests: [ MANIFEST ])
        assert_equal 1, Registry.all.size, "a transient outage must not grey addons out for the TTL"
      end
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/services/maker/addons/registry_test.rb`

Expected: failures — the current `Registry` has a frozen `REGISTRY` hash with three hardcoded addons and no `entry`/`pins`, so `find("generators").entry` raises `NoMethodError`.

- [ ] **Step 3: Rewrite the registry**

`app/services/maker/addons/registry.rb` — replace the whole file:

```ruby
module Maker
  module Addons
    # Addons are declared by MANIFESTS fetched from the addon source (Maker::Addons::Source), not
    # listed here — that is what lets an addon ship without editing this repo, and what makes
    # republishing a bundle the deploy.
    #
    # `available?` is retained from the frozen-hash design and still earns its place: an addon whose
    # source is unreachable, whose api_version we don't speak, or whose manifest is malformed greys
    # out rather than 500ing. One bad addon must never take /tools down.
    Addon = Data.define(:key, :title, :icon, :description, :entry, :pins) do
      def available? = true # a registered addon is by definition fetchable; see Registry#manifests
    end

    module Registry
      module_function

      API_VERSION = "1"
      CACHE_KEY = "maker/addons/manifests"
      TTL = 5.minutes
      REQUIRED = %w[key title icon description api_version entry].freeze

      # Sorted by [title, key]: sort_by is not stable, and source order must never be user-visible.
      def all = manifests.filter_map { |m| build(m) }.sort_by { |a| [ a.title, a.key ] }

      def find(key) = all.find { |a| a.key == key.to_s }

      # A fetch failure returns [] for THIS request and caches nothing — rescuing outside
      # `Rails.cache.fetch` is deliberate. Rescuing inside would cache the empty result, so a
      # two-second blip would grey every addon out for the whole TTL.
      def manifests
        Rails.cache.fetch(CACHE_KEY, expires_in: TTL) { Source.current.manifests }
      rescue StandardError => e
        Rails.logger.warn("addon source unavailable: #{e.class}: #{e.message}")
        []
      end

      def build(manifest)
        return unless manifest.is_a?(Hash)
        return unless REQUIRED.all? { |k| manifest[k].present? }
        return unless manifest["api_version"].to_s == API_VERSION

        Addon.new(
          key: manifest["key"].to_s, title: manifest["title"].to_s, icon: manifest["icon"].to_s,
          description: manifest["description"].to_s, entry: manifest["entry"].to_s,
          pins: manifest["pins"].is_a?(Hash) ? manifest["pins"] : {}
        )
      end
    end
  end
end
```

- [ ] **Step 4: Run the tests**

Run: `bin/rails test test/services/maker/addons/registry_test.rb`

Expected: `6 runs, 0 failures, 0 errors, 0 skips`

- [ ] **Step 5: Mutation-check the no-cache-on-failure guard (§15)**

Move the `rescue` inside the `Rails.cache.fetch` block:

```ruby
      def manifests
        Rails.cache.fetch(CACHE_KEY, expires_in: TTL) do
          begin
            Source.current.manifests
          rescue StandardError
            []
          end
        end
      end
```

Run the test. Expected: **RED** on "a failed fetch is NOT cached". Restore and confirm green.

- [ ] **Step 6: Mutation-check the api_version filter (§15)**

Temporarily delete the `return unless manifest["api_version"].to_s == API_VERSION` line. Run the test.

Expected: **RED** on "an addon declaring an unsupported api_version is skipped". Restore and confirm green.

- [ ] **Step 7: Commit**

```bash
git add app/services/maker/addons/registry.rb test/services/maker/addons/registry_test.rb
git commit -m "feat(addons): Registry is manifest-driven, cached, and degrades to empty

Addons come from manifests fetched from the addon source, not a frozen hash.
A source outage greys addons out for one request without caching the failure.
Mutation-checked twice.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 3: The shell page

**Files:**
- Create: `app/controllers/tools/addons_controller.rb`
- Create: `app/views/tools/addons/show.html.erb`
- Create: `app/javascript/controllers/addon_controller.js`
- Modify: `app/views/layouts/application.html.erb`
- Modify: `config/routes.rb`
- Test: `test/controllers/tools/addons_controller_test.rb`

**If Task 0 reported NO-GO on pins**, omit the `@importmap` lines from the controller and the layout change, and omit `pins` handling — report that you did so.

- [ ] **Step 1: Write the failing test**

`test/controllers/tools/addons_controller_test.rb`:

```ruby
require "test_helper"
require_relative "../../support/fake_addon_source"

module Tools
  class AddonsControllerTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze
    MANIFEST = {
      "key" => "generators", "title" => "Generators", "icon" => "✏️",
      "description" => "Parametric 2D drawings", "api_version" => "1",
      "entry" => "generators.js", "pins" => { "makerjs" => "makerjs.js" }
    }.freeze

    setup do
      Rails.cache.clear
      Maker::Addons::Source.stub = FakeAddonSource.new(manifests: [ MANIFEST ])
      @user = User.create!(email: "addons@example.com", password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
    end

    teardown do
      Maker::Addons::Source.reset!
      Rails.cache.clear
    end

    test "requires login" do
      reset!
      get tools_addon_path("generators")
      assert_redirected_to new_user_session_path
    end

    test "renders the shell with the addon's entry URL and host context" do
      get tools_addon_path("generators")
      assert_response :success
      assert_select "[data-controller=addon][data-addon-entry-value=?]",
                    tools_addon_asset_path("generators", "generators.js")
      assert_select "[data-addon-save-url-value=?]", tools_addon_path("generators")
    end

    test "an unknown addon key is a 404, not a 500" do
      get tools_addon_path("nope")
      assert_response :not_found
    end

    test "the addon's pins are merged into the page importmap" do
      get tools_addon_path("generators")
      assert_response :success
      assert_includes response.body, tools_addon_asset_path("generators", "makerjs.js")
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/controllers/tools/addons_controller_test.rb`

Expected: `NameError: undefined local variable or method 'tools_addon_path'` — the route does not exist yet.

- [ ] **Step 3: Add the routes**

In `config/routes.rb`, replace the whole `# --- Addons (Tools) ---` block (the `get "tools"` line, the `namespace :tools do … end` block, the hand-written OpenSCAD routes, and the `tools/addon_states` line) with:

```ruby
  # --- Addons (Tools) — the gallery + ONE generic surface for every addon ---
  #
  # ORDER IS LOAD-BEARING. `tools/:key` is a wildcard, so every more-specific /tools/* route must be
  # declared ABOVE it or be swallowed — `tools/addon_states/...` would otherwise match with
  # key="addon_states". The generic surface is also why the two inflector traps that used to live
  # here are gone: there is no longer a per-addon route helper to inflect.
  get "tools", to: "tools/home#index", as: :tools

  # The params behind ANY addon state, as a download. ONE route for every addon: `Maker::AddonState`
  # is addon-agnostic (`data` IS each addon's own shape), so there is nothing per-addon to branch on.
  get "tools/addon_states/:id/params", to: "tools/addon_params#show", as: :tools_addon_params

  # Boxes and OpenSCAD still have their own controllers until their own migration lands.
  namespace :tools do
    resources :boxes, only: %i[index new show create] do
      post :preview, on: :collection
      get "thumb/:key", to: "boxes#thumb", on: :collection, as: :thumb, constraints: { key: /[A-Za-z0-9]+/ }
    end
  end
  get  "tools/openscad",         to: "tools/openscad#index",   as: :tools_openscad
  get  "tools/openscad/new",     to: "tools/openscad#new",     as: :new_tools_openscad
  post "tools/openscad/preview", to: "tools/openscad#preview", as: :preview_tools_openscad
  post "tools/openscad",         to: "tools/openscad#create"
  get  "tools/openscad/:id",     to: "tools/openscad#show",    as: :tools_openscad_design

  # The generic addon surface. LAST, because :key is a wildcard.
  get  "tools/:key/asset/*path", to: "tools/addons#asset", as: :tools_addon_asset, format: false
  post "tools/:key",             to: "tools/addons#create"
  get  "tools/:key",             to: "tools/addons#show",  as: :tools_addon
```

- [ ] **Step 4: Write the controller**

`app/controllers/tools/addons_controller.rb`:

```ruby
module Tools
  # THE generic addon surface. Nothing here knows about any particular addon — that is precisely why
  # shipping a new addon needs no Rails redeploy (spec §3.1).
  class AddonsController < BaseController
    include Tools::LibraryFolders

    before_action :load_addon

    def show
      @importmap = merged_importmap
      @default_parent_node_id = current_project_folder_node_id
      @folders = folder_options
    end

    private

    def load_addon
      @addon = Maker::Addons::Registry.find(params[:key])
      head :not_found unless @addon
    end

    # The host's own pins plus the addon's, as ONE map — a document may only have one importmap, and
    # the browser honours only the first. Built per-request because the addon's pins vary; the host's
    # own pins are re-drawn from config.importmap.paths rather than mutating the shared
    # Rails.application.importmap, which is process-global and must not acquire addon entries.
    def merged_importmap
      map = Importmap::Map.new
      Rails.application.config.importmap.paths.each { |path| map.draw(path) }
      @addon.pins.each { |name, asset| map.pin name, to: tools_addon_asset_path(@addon.key, asset) }
      map
    end
  end
end
```

- [ ] **Step 5: Write the shell view and the layout change**

`app/views/tools/addons/show.html.erb`:

```erb
<% content_for :title, "#{@addon.title} — Tinkerex" %>

<div class="page-head"><h1><%= @addon.icon %> <%= @addon.title %></h1>
  <p class="page-subtitle muted"><%= @addon.description %></p>
</div>

<%# The whole addon UI mounts here. Every value the addon needs from the host arrives as a data
    attribute, so the bundle never has to know a Rails route or guess at context. %>
<div data-controller="addon"
     data-addon-entry-value="<%= tools_addon_asset_path(@addon.key, @addon.entry) %>"
     data-addon-save-url-value="<%= tools_addon_path(@addon.key) %>"
     data-addon-folders-value="<%= @folders.to_json %>"
     data-addon-default-folder-value="<%= @default_parent_node_id %>">
  <div data-addon-target="mount"></div>
</div>
```

In `app/views/layouts/application.html.erb`, replace the `javascript_importmap_tags` line with:

```erb
    <%= javascript_importmap_tags "application", importmap: (@importmap || Rails.application.importmap) %>
```

- [ ] **Step 6: Write the addon loader**

`app/javascript/controllers/addon_controller.js`:

```javascript
import { Controller } from "@hotwired/stimulus"

// Loads an addon bundle and hands it the host context. Addon-AGNOSTIC by construction: it never
// names an addon, and the bundle's only contract is a default export with mount(element, context).
// The bundle is NOT a Stimulus controller — an addon must not have to know the host's JS framework.
export default class extends Controller {
  static targets = ["mount"]
  static values = { entry: String, saveUrl: String, folders: Array, defaultFolder: String }

  async connect() {
    try {
      const module = await import(this.entryValue)
      await module.default.mount(this.mountTarget, {
        saveUrl: this.saveUrlValue,
        folders: this.foldersValue,
        defaultFolder: this.defaultFolderValue,
        csrfToken: document.querySelector("meta[name=csrf-token]")?.content,
      })
    } catch (e) {
      this.mountTarget.textContent = `This tool failed to load: ${e.message}`
    }
  }
}
```

- [ ] **Step 7: Run the tests**

Run: `bin/rails test test/controllers/tools/addons_controller_test.rb`

Expected: `4 runs, 0 failures, 0 errors, 0 skips`

- [ ] **Step 8: Mutation-check the route ordering (§15)**

Move the `get "tools/:key"` line ABOVE the `tools/addon_states` line. Run:

`bin/rails test test/controllers/tools/addon_params_controller_test.rb`

Expected: **RED** — the addon-params route is now swallowed by the wildcard. Restore the order and confirm green. This is the ordering hazard the routes comment describes; prove the comment is true.

- [ ] **Step 9: Commit**

```bash
git add app/controllers/tools/addons_controller.rb app/views/tools/addons \
        app/javascript/controllers/addon_controller.js \
        app/views/layouts/application.html.erb config/routes.rb \
        test/controllers/tools/addons_controller_test.rb
git commit -m "feat(addons): one generic shell for every addon

Tools::AddonsController#show renders a mount point plus the host context, and
merges the addon's declared pins into a per-request importmap. Route ordering is
load-bearing and mutation-checked.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 4: The asset proxy

**Files:**
- Modify: `app/controllers/tools/addons_controller.rb`
- Test: `test/controllers/tools/addons_controller_test.rb`

- [ ] **Step 1: Write the failing test**

Add to `test/controllers/tools/addons_controller_test.rb`, inside the class. Note the `setup` must also supply assets, so replace the existing `Maker::Addons::Source.stub = …` line in `setup` with:

```ruby
      Maker::Addons::Source.stub = FakeAddonSource.new(
        manifests: [ MANIFEST ],
        assets: { "generators/generators.js" => "export default { mount() {} }" }
      )
```

Then add these tests:

```ruby
    test "serves an addon asset as JavaScript" do
      get tools_addon_asset_path("generators", "generators.js")
      assert_response :success
      assert_equal "text/javascript", response.media_type
      assert_equal "export default { mount() {} }", response.body
    end

    test "a missing asset is a 404, not a 500" do
      get tools_addon_asset_path("generators", "nope.js")
      assert_response :not_found
    end

    test "a traversing asset path is refused" do
      # Belt and braces: Source#asset_path! refuses it too, but the controller is the door an
      # attacker actually knocks on, and a 404 here must not depend on the layer below.
      get "/tools/generators/asset/../../secret"
      assert_response :not_found
    end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/controllers/tools/addons_controller_test.rb`

Expected: `AbstractController::ActionNotFound: The action 'asset' could not be found`

- [ ] **Step 3: Add the action**

In `app/controllers/tools/addons_controller.rb`, add above `private`:

```ruby
    # Same-origin proxy for the addon's bundle and its pinned modules. Same-origin is not a
    # convenience: the sidecars and the addon source are internal-only (no `port:` in deploy.yml), so
    # a browser cannot reach them, and CSP is script_src :self (spec §4.2). Proxying is what lets the
    # addon's JS run with the host's session and no token (spec §3.3).
    def asset
      body = Maker::Addons::Source.current.asset(@addon.key, params[:path])
      send_data body, type: content_type_for(params[:path]), disposition: "inline"
    rescue Maker::Addons::Source::Error
      head :not_found
    end
```

and in the `private` section:

```ruby
    def content_type_for(path)
      case File.extname(path.to_s)
      when ".js"   then "text/javascript"
      when ".css"  then "text/css"
      when ".json" then "application/json"
      when ".svg"  then "image/svg+xml"
      else "application/octet-stream"
      end
    end
```

- [ ] **Step 4: Run the tests**

Run: `bin/rails test test/controllers/tools/addons_controller_test.rb`

Expected: `7 runs, 0 failures, 0 errors, 0 skips`

- [ ] **Step 5: Mutation-check the traversal refusal (§15)**

**Mutate `asset_path!`, not `asset`.** `FakeAddonSource#asset` calls `asset_path!` directly and does
not go through `Source#asset`, so weakening `asset` would leave the controller test green and prove
nothing — the guard the controller path actually depends on is `asset_path!`.

In `app/services/maker/addons/source.rb`, temporarily replace `asset_path!`'s body with `path.to_s`.

Run: `bin/rails test test/controllers/tools/addons_controller_test.rb test/services/maker/addons/source_test.rb`

Expected: **RED** on both "a traversing asset path is refused" (controller) and "asset_path! rejects
traversal instead of normalizing it" (unit). Restore and confirm green.

If the controller test stays GREEN while the unit test goes red, stop and report: it means Rails
normalized the `..` out of the URL before routing, so the controller was never actually exercising
the guard, and the test needs a payload that survives routing (try an encoded `%2e%2e`).

- [ ] **Step 6: Commit**

```bash
git add app/controllers/tools/addons_controller.rb test/controllers/tools/addons_controller_test.rb
git commit -m "feat(addons): same-origin asset proxy for addon bundles

Mutation-checked the traversal refusal at the controller door, not only in Source.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 5: The save endpoint

**Files:**
- Modify: `app/controllers/tools/addons_controller.rb`
- Test: `test/controllers/tools/addons_controller_test.rb`

- [ ] **Step 1: Write the failing test**

Add to `test/controllers/tools/addons_controller_test.rb`:

```ruby
    test "save writes the file to the library and records an AddonState" do
      assert_difference -> { @user.maker_addon_states.count } => 1 do
        post tools_addon_path("generators"), params: {
          name: "3mm birch test",
          data: { generator: "material-test-grid", params: { cols: "5" } }.to_json,
          files: [ { name: "grid.svg", content_type: "image/svg+xml", body: "<svg/>" } ].to_json
        }
      end
      assert_redirected_to tools_addon_path("generators")

      state = @user.maker_addon_states.last
      assert_equal "generators", state.addon_key
      assert_equal "3mm birch test", state.name
      assert_equal "material-test-grid", state.data["generator"]
      assert_equal 1, state.files.count
    end

    test "save refuses a payload over the size cap" do
      post tools_addon_path("generators"), params: {
        name: "huge", data: "{}",
        files: [ { name: "big.svg", content_type: "image/svg+xml",
                   body: "x" * (Tools::AddonsController::MAX_FILE_BYTES + 1) } ].to_json
      }
      assert_response :unprocessable_entity
    end

    test "save refuses a file count over the cap" do
      files = Array.new(Tools::AddonsController::MAX_FILES + 1) do |i|
        { name: "f#{i}.svg", content_type: "image/svg+xml", body: "<svg/>" }
      end
      post tools_addon_path("generators"), params: { name: "many", data: "{}", files: files.to_json }
      assert_response :unprocessable_entity
    end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/controllers/tools/addons_controller_test.rb`

Expected: `AbstractController::ActionNotFound: The action 'create' could not be found`

- [ ] **Step 3: Add the action**

In `app/controllers/tools/addons_controller.rb`, add the caps at the top of the class:

```ruby
    MAX_FILES = 8
    MAX_FILE_BYTES = 5_000_000
```

and the action above `private`:

```ruby
    # The ONE save door for every addon. Generation happens in the browser, so the bytes arrive in
    # the request — bounded here, because a client-supplied body is not a trusted size.
    def create
      files = parse_files
      return head(:unprocessable_entity) if files.nil?

      state = current_user.maker_addon_states.create!(
        addon_key: @addon.key, name: params.require(:name), data: parse_data
      )
      addon_files = Maker::Addons::LibraryOutput.write(
        user: current_user, state:, parent_node_id: chosen_parent_node_id,
        files: files.map { |f| { name: f["name"], bytes: f["body"], content_type: f["content_type"], role: "output" } }
      )
      attach_addon_files_to_current_project(addon_files)
      redirect_to tools_addon_path(@addon.key), notice: "Saved “#{state.name}”."
    end
```

and in `private`:

```ruby
    # Returns nil (-> 422) rather than raising, so a malformed or oversized payload is a routine
    # refusal instead of a 500.
    def parse_files
      parsed = JSON.parse(params[:files].to_s)
      return nil unless parsed.is_a?(Array) && parsed.any? && parsed.size <= MAX_FILES
      return nil unless parsed.all? { |f| f.is_a?(Hash) && f["name"].present? && f["body"].is_a?(String) }
      return nil if parsed.sum { |f| f["body"].bytesize } > MAX_FILE_BYTES

      parsed
    rescue JSON::ParserError
      nil
    end

    def parse_data
      parsed = JSON.parse(params[:data].to_s)
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end
```

- [ ] **Step 4: Run the tests**

Run: `bin/rails test test/controllers/tools/addons_controller_test.rb`

Expected: `10 runs, 0 failures, 0 errors, 0 skips`

- [ ] **Step 5: Mutation-check the size cap (§15)**

Temporarily delete the `return nil if parsed.sum { … } > MAX_FILE_BYTES` line. Run the test.

Expected: **RED** on "save refuses a payload over the size cap". Restore and confirm green.

- [ ] **Step 6: Run the full gate and commit**

Run: `bin/ci`

Expected: all gates pass, three test legs identical.

```bash
git add app/controllers/tools/addons_controller.rb test/controllers/tools/addons_controller_test.rb
git commit -m "feat(addons): generic save endpoint onto LibraryOutput

Bytes are generated in the browser, so the payload is bounded — file count and
total size, both mutation-checked.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 6: Migrate `generators` to a bundle

**Files:**
- Create: `public/addons/manifests.json`
- Create: `public/addons/generators/generators.js`
- Create: `public/addons/generators/material_test_grid.js`
- Copy: `vendor/javascript/{makerjs,bezier-js,clone,graham_scan,kdbush}.js` → `public/addons/generators/`
- Modify: `config/environments/development.rb`, `config/environments/test.rb`
- Test: `test/system/addon_bundle_test.rb`

**Transitional by design:** serving from the host's own `public/` exercises the real HTTP path with no new infrastructure. Phase B moves these files to the addons repo's static container and repoints `ADDON_SOURCE_URL`.

- [ ] **Step 1: Write the manifest and copy the vendored deps**

`public/addons/manifests.json`:

```json
[
  {
    "key": "generators",
    "title": "Generators",
    "icon": "✏️",
    "description": "Parametric 2D drawings → SVG (laser & CNC)",
    "api_version": "1",
    "entry": "generators.js",
    "pins": {
      "makerjs": "makerjs.js",
      "bezier-js": "bezier-js.js",
      "clone": "clone.js",
      "graham_scan": "graham_scan.js",
      "kdbush": "kdbush.js"
    }
  }
]
```

All five pins are required: `makerjs.js` imports its four dependencies by **bare specifier**
(`from"bezier-js"`, `from"clone"`, `from"graham_scan"`, `from"kdbush"` — verified), so pinning only
`makerjs` leaves those unresolvable.

```bash
mkdir -p public/addons/generators
cp vendor/javascript/{makerjs,bezier-js,clone,graham_scan,kdbush}.js public/addons/generators/
```

- [ ] **Step 2: Write the bundle entry point**

`public/addons/generators/generators.js`:

```javascript
import materialTestGrid from "./material_test_grid.js"

// The Generators addon. Its only contract with the host is `mount(element, context)` — no Stimulus,
// no host framework. Adding a generator is a module + a line here, and no Ruby anywhere.
const REGISTRY = [materialTestGrid]

const build = (gen, values) => {
  try {
    return gen.generate(values)
  } catch (e) {
    const msg = String(e && e.message).replace(/[<&]/g, "")
    return `<svg xmlns="http://www.w3.org/2000/svg" width="240" height="40"><text x="4" y="24" fill="#c00">${msg}</text></svg>`
  }
}

export default {
  mount(el, ctx) {
    el.innerHTML = `
      <div class="generator-editor">
        <aside class="generator-side">
          <label class="generator-picker-label">Generator <select data-role="picker"></select></label>
          <div class="generator-params" data-role="fields"></div>
          <label class="generator-name-label">Name <input data-role="name" required></label>
          <label class="generator-folder-label">Save into <select data-role="folder"></select></label>
          <button data-role="save" class="generator-save">Save to library</button>
          <p class="muted" data-role="status"></p>
        </aside>
        <div class="generator-preview"><img data-role="preview" alt="live preview"></div>
      </div>`

    const $ = (role) => el.querySelector(`[data-role=${role}]`)
    const current = () => REGISTRY.find((g) => g.key === $("picker").value) || REGISTRY[0]

    for (const gen of REGISTRY) {
      $("picker").add(new Option(gen.title, gen.key))
    }
    for (const [label, id] of ctx.folders) {
      const opt = new Option(label, id)
      if (id === ctx.defaultFolder) opt.selected = true
      $("folder").add(opt)
    }

    const values = () => Object.fromEntries(
      [...$("fields").querySelectorAll("[data-param]")].map((i) =>
        [i.dataset.param, i.type === "checkbox" ? i.checked : i.value])
    )

    const render = () => {
      const svg = build(current(), values())
      $("preview").src = `data:image/svg+xml;utf8,${encodeURIComponent(svg)}`
      return svg
    }

    const buildFields = () => {
      $("fields").innerHTML = ""
      for (const p of current().params) {
        const wrap = document.createElement("label")
        wrap.className = "generator-field"
        wrap.textContent = p.label || p.name
        const input = document.createElement("input")
        input.dataset.param = p.name
        if (p.type === "bool") { input.type = "checkbox"; input.checked = !!p.default }
        else if (p.type === "text") { input.type = "text"; input.value = p.default ?? "" }
        else {
          input.type = "number"
          if (p.min != null) input.min = p.min
          if (p.max != null) input.max = p.max
          input.step = p.step ?? (p.type === "int" ? 1 : "any")
          input.value = p.default ?? 0
        }
        wrap.appendChild(input)
        $("fields").appendChild(wrap)
      }
      render()
    }

    $("picker").addEventListener("change", buildFields)
    $("fields").addEventListener("input", render)

    $("save").addEventListener("click", async () => {
      const name = $("name").value.trim()
      if (!name) { $("status").textContent = "Name is required."; return }
      const svg = render()
      const body = new FormData()
      body.append("name", name)
      body.append("parent_node_id", $("folder").value)
      body.append("data", JSON.stringify({ generator: current().key, params: values() }))
      body.append("files", JSON.stringify([
        { name: `${name.replace(/[^a-z0-9]+/gi, "-").toLowerCase()}.svg`,
          content_type: "image/svg+xml", body: svg }
      ]))
      const res = await fetch(ctx.saveUrl, {
        method: "POST", body, headers: { "X-CSRF-Token": ctx.csrfToken },
      })
      $("status").textContent = res.ok ? "Saved." : "Save failed."
    })

    buildFields()
  },
}
```

- [ ] **Step 3: Copy the generator module across unchanged**

```bash
cp app/javascript/generators/material_test_grid.js public/addons/generators/material_test_grid.js
```

Then change **only** its first line, from `import makerjs from "makerjs"` — leave it exactly as is. The bare specifier is correct: the manifest pins `makerjs`, so it resolves through the merged importmap. **Do not** rewrite it to a relative path; that would leave makerjs's own four bare imports unresolvable.

- [ ] **Step 4: Point the app at the local source in dev and test**

In `config/environments/development.rb` and `config/environments/test.rb`, add before the final `end`:

```ruby
  # Phase A: addon bundles are served from this app's own public/addons over real HTTP, so the proxy
  # path is genuinely exercised without standing up new infrastructure. Phase B repoints this at the
  # addons repo's static container and deletes public/addons.
  ENV["ADDON_SOURCE_URL"] ||= "http://127.0.0.1:#{ENV.fetch('PORT', 3000)}/addons"
```

- [ ] **Step 5: Write the system test**

`test/system/addon_bundle_test.rb`:

```ruby
require "application_system_test_case"

# The bundle-loading pipeline, end to end, in a real browser: the shell mounts, the proxied ESM
# resolves (including makerjs's own bare-specifier imports through the merged importmap), and the
# generator renders. None of this is observable from a request test — a rendered importmap that
# parses is not one that resolves (§14e).
class AddonBundleTest < ApplicationSystemTestCase
  setup { sign_in_as "bundle@example.com" }

  test "the generators bundle mounts and renders a preview" do
    visit "/tools/generators"
    assert_selector "[data-role=picker] option", text: "Material Test Grid"
    assert_selector "[data-role=preview]"
    assert_no_console_errors
  end
end
```

- [ ] **Step 6: Run the system test**

Run: `bin/rails test test/system/addon_bundle_test.rb`

Expected: `1 runs, 3 assertions, 0 failures, 0 errors, 0 skips`

If the preview is blank or the console shows a module-resolution error, that is the Task 0 spike's finding reappearing — report it rather than working around it.

- [ ] **Step 7: Commit**

```bash
git add public/addons config/environments/development.rb config/environments/test.rb \
        test/system/addon_bundle_test.rb
git commit -m "feat(addons): generators ships as a runtime-loaded manifest + ESM bundle

Served transitionally from public/addons over real HTTP so the proxy path is
exercised; Phase B moves it to the addons repo's static container.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 7: Delete the old `generators` Ruby, and the docs

**Files:**
- Delete: `app/controllers/tools/generators_controller.rb`, `app/views/tools/generators/`, `app/javascript/controllers/generator_controller.js`, `app/javascript/generators/`
- Modify: `config/importmap.rb`, `app/views/tools/home/index.html.erb`, `CLAUDE.md`, `docs/STATUS.md`
- Delete: `test/controllers/tools/generators_controller_test.rb`

- [ ] **Step 1: Delete the superseded code**

```bash
git rm -r app/controllers/tools/generators_controller.rb app/views/tools/generators \
          app/javascript/controllers/generator_controller.js app/javascript/generators \
          test/controllers/tools/generators_controller_test.rb
```

In `config/importmap.rb`, delete the `pin_all_from "app/javascript/generators", under: "generators"` line and the five Maker.js pins (`makerjs`, `bezier-js`, `clone`, `graham_scan`, `kdbush`) together with their explanatory comment block — the host no longer loads any of them; the addon's manifest pins them now. Leave `vendor/javascript/*.js` in place: Task 6 copied rather than moved them, and Phase B removes the originals when the bundle leaves this repo.

- [ ] **Step 2: Point the gallery at the generic route**

In `app/views/tools/home/index.html.erb`, replace:

```erb
      <%= link_to send("tools_#{addon.key}_path"), class: "addon-card" do %>
```

with:

```erb
      <%= link_to tools_addon_path(addon.key), class: "addon-card" do %>
```

**This breaks the gallery links for `boxes` and `openscad`**, which still have their own controllers and are not yet registered as manifests. Fix by adding them to `public/addons/manifests.json`? **No** — they have no bundle. Instead, in `app/views/tools/home/index.html.erb`, render only registered addons (which `@addons` already is), and add a temporary second list for the two unmigrated addons:

```erb
  <% if Tools::BoxesClient.configured? %>
    <%= link_to tools_boxes_path, class: "addon-card" do %>
      <span class="addon-icon">📦</span>
      <span class="addon-title">Box Generator</span>
      <span class="addon-desc muted">Parametric laser-cut / CNC boxes</span>
    <% end %>
  <% end %>
  <% if Tools::OpenscadClient.configured? %>
    <%= link_to tools_openscad_path, class: "addon-card" do %>
      <span class="addon-icon">🧊</span>
      <span class="addon-title">OpenSCAD</span>
      <span class="addon-desc muted">Parametric .scad + params → 3MF</span>
    <% end %>
  <% end %>
```

Mark it clearly as temporary — it disappears when each addon migrates. (On this branch the clients are the top-level `BoxesClient` / `OpenscadClient`, **not** `Tools::`-namespaced; that rename lived only on the abandoned PR #115.)

- [ ] **Step 3: Run the full gate**

Run: `bin/ci`

Expected: all gates pass; the three test legs report identical counts. `test/controllers/tools/home_controller_test.rb` must still pass — it asserts a `.addon-card` matching "Box Generator", which the temporary block above satisfies.

- [ ] **Step 4: Update `CLAUDE.md` §14c**

Replace the bullet reading **"`Registry` declares each addon with its own `available:` lambda, so an addon whose backing service is unconfigured greys out rather than 500ing."** with:

```markdown
- **Addons are declared by MANIFESTS fetched from `ADDON_SOURCE_URL`, not listed in this repo** —
  `Maker::Addons::Registry` builds them from `Maker::Addons::Source`, cached, so republishing a
  bundle *is* the deploy. Three refusals are load-bearing and each is mutation-checked: a manifest
  missing a key, or declaring an `api_version` we don't speak, is **skipped, not raised on** — one
  bad addon must never take `/tools` down; and a source outage returns `[]` for **that request
  only**, because the `rescue` sits OUTSIDE `Rails.cache.fetch` — inside, a two-second blip would
  grey every addon out for the whole TTL.
- **ONE generic surface serves every addon** (`Tools::AddonsController`: shell, asset proxy, save),
  which is why a new addon needs no Rails redeploy. **Route order is load-bearing** — `tools/:key`
  is a wildcard, so every specific `/tools/*` route must be declared above it or be swallowed. The
  asset proxy is same-origin because the addon source and the sidecars are internal-only and CSP is
  `script_src :self`; that is also what lets the addon's JS use the host session with **no token**.
  Asset paths are **REJECTED, never normalized** (§14a's `key_for` rule).
```

- [ ] **Step 5: Narrate the arc in `docs/STATUS.md`**

Follow the file's established convention: promote a new `## Latest (2026-08-02): …` heading, demote the previous one to a dated `##` heading, and update the top `**Updated:**` line. Record: the generic addon surface landed; `generators` now ships as a manifest + plain-ESM bundle served transitionally from `public/addons`; `boxes` and `openscad` still have their own controllers and are next; Phase B (the addons repo + static container, which is when independent deploy actually turns on) has not started. Include the Task 0 spike outcome.

- [ ] **Step 6: Run the full gate and commit**

Run: `bin/ci`

```bash
git add -A
git commit -m "refactor(addons): delete the per-addon generators Ruby; document the surface

The generators controller, views, Stimulus controller and JS registry are gone —
the addon is now a manifest + bundle. Maker.js pins move from the host importmap
to the addon's manifest.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Done when

- [ ] `bin/ci` green, three test legs reporting identical counts
- [ ] Task 0's outcome reported and recorded in `docs/STATUS.md`
- [ ] `/tools/generators` renders and saves in a real browser (Task 6's system test)
- [ ] `boxes` and `openscad` still work unchanged via their own controllers
- [ ] Every new guard mutation-checked: traversal (Tasks 1, 4), no-cache-on-failure and api_version (Task 2), route ordering (Task 3), size cap (Task 5)
- [ ] No spike artefacts remain — `git status --short` clean

Then per CLAUDE.md's close-out rule: on a `claude/*` branch with green gates, commit, push and open the PR without asking. Merging still needs an explicit go-ahead.
