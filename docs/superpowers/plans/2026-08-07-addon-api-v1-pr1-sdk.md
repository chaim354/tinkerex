# Addon API v1 — PR 1: the host SDK Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `@maker/addon-sdk` — a host-served ESM module every addon bundle imports instead of hand-rolling `fetch` + CSRF + error parsing — together with `host.capabilities()`, a host capability level, and typed errors, proven end to end in a real browser.

**Architecture:** The server renders one `ctx` JSON blob into the addon shell (api version, host level, capability map, addon key, URLs). `addon_controller.js` merges that blob with the two browser-side values it already supplies (`chooseFolder`, `csrfToken`), calls `initHost(ctx)` on the SDK, then dynamic-imports the bundle and calls `mount(el, ctx)` exactly as it does today. The SDK is a host pin, so it lands in every addon's merged importmap without the addon declaring anything. Nothing existing is removed: every current data attribute and response key keeps being emitted, because bundles and Rails deploy independently.

**Tech Stack:** Rails 8, importmap-rails + Propshaft (no JS build step, no JS unit-test runner — the SDK's transport is proven in Capybara system tests), Minitest.

**Spec:** `docs/superpowers/specs/2026-08-07-addon-api-v1-design.md` §12 row 1.

---

## Scope correction — read before starting

The spec's §12 row 1 says "`generators` adopts it". **`generators` is not in this repo.** Bundles live in `chaim354/tinkerex-addons` (dev reads `../../../tinkerex-addons/addons`; production reads the `addons` Kamal accessory; `public/addons` does not exist here). So:

- **In this repo**, the SDK is proven by a **second hermetic fixture addon** that uses it, added beside the existing one. The existing `fixture` addon is left on the raw-`ctx` path **on purpose** — that is what proves the compatibility rule (an old bundle must keep working) rather than merely asserting it.
- **Migrating `generators` is a follow-up PR in the addons repo**, after this ships. It is out of scope here and must not block this branch.

Two things discovered while planning that the spec did not know, and that this plan uses:

1. `ctx.chooseFolder` **already exists** as a host-supplied function (`addon_controller.js:47`). `host.files.pickFolder()` wraps it — it is not new work.
2. The 409 overwrite dance (`saveWithOverwrite`) is **copied verbatim into every real bundle** (`test/fixtures/addons/fixture/save.js` is that copy). `host.files.save({onReplace})` absorbs it, which is the single most concrete "the SDK deletes per-bundle code" win available in PR 1.

---

## File Structure

| File | Responsibility |
|---|---|
| `app/services/maker/addons/host.rb` **(create)** | `LEVEL` + the capability map. One definition, server-side, so the client never carries a second copy. |
| `app/controllers/tools/addons_controller.rb` **(modify, `#show`)** | Build the `ctx` hash. |
| `app/views/tools/addons/show.html.erb` **(modify)** | Emit `data-addon-ctx-value`, keeping all nine existing attributes. |
| `app/javascript/maker/addon_sdk.js` **(create)** | The SDK: `initHost`, `host`, typed errors, `files`/`state`/`service`. |
| `config/importmap.rb` **(modify)** | `pin "@maker/addon-sdk"` — a host pin, so it is drawn into every merged addon importmap. |
| `app/javascript/controllers/addon_controller.js` **(modify)** | Parse the blob, init the SDK, still call `mount(el, ctx)`. |
| `test/services/maker/addons/host_test.rb` **(create)** | The capability map's shape. |
| `test/controllers/tools/addons_controller_test.rb` **(modify)** | The ctx blob, the SDK pin in the merged importmap, and the compatibility guard. |
| `test/fixtures/addons/sdk-fixture/sdk.js` **(create)** + `test/fixtures/addons/manifests.json` **(modify)** | A bundle that uses only the SDK. |
| `test/system/addon_sdk_test.rb` **(create)** | The proof, in a real browser. |
| `docs/addon-api-v1.md` **(create)** | The author-facing normative reference. |
| `CLAUDE.md` §14c, `docs/STATUS.md`, the spec **(modify)** | Close-out, in this branch (§15). |

---

### Task 1: The capability map and the host level

**Files:**
- Create: `app/services/maker/addons/host.rb`
- Test: `test/services/maker/addons/host_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/services/maker/addons/host_test.rb`:

```ruby
require "test_helper"

module Maker
  module Addons
    # The capability map is the ONE definition of what this host can do; it is serialized into the
    # addon shell's ctx and read by the SDK's `capabilities()`. The assertions here are about SHAPE,
    # because shape is what silently breaks the client: a nil value reads as `false` in JS with no
    # error anywhere, so an unimplemented capability and a typo'd key become indistinguishable.
    class HostTest < ActiveSupport::TestCase
      test "LEVEL is an integer that a manifest's min_host can be compared against" do
        assert_kind_of Integer, Maker::Addons::Host::LEVEL
        assert_operator Maker::Addons::Host::LEVEL, :>=, 1
      end

      test "every capability value is a real boolean, never nil" do
        Maker::Addons::Host.capabilities.each do |name, value|
          assert_kind_of String, name
          assert_includes [ true, false ], value, "capability #{name.inspect} is #{value.inspect}"
        end
      end

      test "the map is frozen, so a request cannot mutate the host's answer" do
        assert Maker::Addons::Host.capabilities.frozen?
      end

      test "the capabilities this PR implements are true and the rest are declared false" do
        caps = Maker::Addons::Host.capabilities
        assert caps.fetch("library:write")
        assert caps.fetch("state:list")
        assert caps.fetch("service")
        assert caps.fetch("pick:folder")
        # Named in the contract, answered false until their own PR. Present-and-false is the
        # point: an addon can be written against a capability before the host has it.
        assert_not caps.fetch("library:read")
        assert_not caps.fetch("state:crud")
        assert_not caps.fetch("data")
        assert_not caps.fetch("maker:read")
        assert_not caps.fetch("pick:file")
        assert_not caps.fetch("project:current")
      end
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/services/maker/addons/host_test.rb`
Expected: FAIL — `NameError: uninitialized constant Maker::Addons::Host`

- [ ] **Step 3: Write the implementation**

Create `app/services/maker/addons/host.rb`:

```ruby
module Maker
  module Addons
    # WHAT THIS HOST CAN DO, AS ONE SERVER-SIDE DEFINITION. Serialized into the addon shell's ctx
    # and returned by the SDK's `host.capabilities()`, so a bundle never carries a second copy of
    # this list — the failure shape CLAUDE.md §14d records for the extension->role vocabulary.
    #
    # A CAPABILITY IS NAMED HERE BEFORE IT IS BUILT, ANSWERED `false`. That is the whole
    # compatibility mechanism: an addon can be authored against `library:read` today and simply
    # degrade until the host answers true, instead of being written after the fact. Every value
    # must be a real boolean — a missing key reads as `undefined` in JS and a nil reads as `false`,
    # so neither can be told apart from "deliberately off".
    #
    # LEVEL is the integer a manifest's `min_host` is compared against (added in PR 2). BUMP IT IN
    # THE SAME COMMIT that flips a capability to true, never afterwards: an addon that requires a
    # capability has no other way to say so, and `api_version` equality cannot express "needs host
    # >= X" (the VS Code `engines` lesson, spec §4).
    module Host
      module_function

      LEVEL = 1

      CAPABILITIES = {
        "library:write"   => true,   # POST /tools/:key — the save door
        "library:read"    => false,  # PR 5
        "state:list"      => true,   # GET /tools/:key/states
        "state:crud"      => false,  # PR 3
        "data"            => false,  # PR 4 — addon-owned collections
        "maker:read"      => false,  # deferred (spec §13)
        "project:current" => false,  # PR 3
        "service"         => true,   # the sidecar proxy
        "pick:folder"     => true,   # ctx.chooseFolder, already shipped
        "pick:file"       => false   # PR 5
      }.freeze

      def capabilities = CAPABILITIES

      def level = LEVEL
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/services/maker/addons/host_test.rb`
Expected: PASS — 4 runs, 0 failures

- [ ] **Step 5: Mutation-check the boolean guard (§15)**

Temporarily change `"pick:file" => false` to `"pick:file" => nil` in `host.rb`.
Run: `bin/rails test test/services/maker/addons/host_test.rb`
Expected: FAIL on "every capability value is a real boolean" with `capability "pick:file" is nil`.
**Restore the file to `false` and re-run — expected PASS.**

- [ ] **Step 6: Commit**

```bash
git add app/services/maker/addons/host.rb test/services/maker/addons/host_test.rb
git commit -m "feat(addons): declare the host capability map and level"
```

---

### Task 2: The shell emits one ctx blob, and keeps every old attribute

**Files:**
- Modify: `app/controllers/tools/addons_controller.rb` (`#show`, around line 99–110)
- Modify: `app/views/tools/addons/show.html.erb`
- Test: `test/controllers/tools/addons_controller_test.rb`

- [ ] **Step 1: Write the failing tests**

Add to `test/controllers/tools/addons_controller_test.rb`, inside the `AddonsControllerTest` class:

```ruby
    # ONE ctx BLOB, PARSED — not a `assert_match` on a substring. A data attribute that contains the
    # right characters is not one that parses: the value is HTML-escaped JSON, and the escaping is
    # exactly what a substring assertion cannot see going wrong.
    def rendered_ctx
      get tools_addon_path(FIXTURE_KEY)
      assert_response :success
      value = css_select("[data-addon-ctx-value]").first["data-addon-ctx-value"]
      JSON.parse(value)
    end

    test "the shell renders a ctx blob carrying the host level and capability map" do
      ctx = rendered_ctx
      assert_equal Maker::Addons::Registry::API_VERSION, ctx["apiVersion"]
      assert_equal Maker::Addons::Host::LEVEL, ctx["hostLevel"]
      assert_equal Maker::Addons::Host.capabilities, ctx["capabilities"]
      assert_equal FIXTURE_KEY, ctx.dig("addon", "key")
    end

    test "the ctx blob carries every URL a bundle needs, from the routes rather than literals" do
      ctx = rendered_ctx
      assert_equal tools_addon_path(FIXTURE_KEY),        ctx.dig("urls", "save")
      assert_equal tools_addon_states_path(FIXTURE_KEY), ctx.dig("urls", "states")
      assert_equal library_children_path,                ctx.dig("urls", "children")
      assert_equal library_folders_path,                 ctx.dig("urls", "create")
      # A BASE that a bundle appends "<service>/<path>" to — it must keep its trailing slash, which
      # is the one property of this value a bundle depends on and the easiest to lose.
      assert ctx.dig("urls", "service").end_with?("/")
    end

    # THE COMPATIBILITY RULE, WITH TEETH (spec §10.1). The two repos deploy independently: a bundle
    # built against the old ctx may be running against a host built against the new one at any
    # moment. Dropping any of these is invisible to every other test in this suite and breaks
    # production silently, which is precisely why it is asserted as a list rather than trusted.
    test "every pre-SDK data attribute is still emitted" do
      get tools_addon_path(FIXTURE_KEY)
      assert_response :success
      mount = css_select("[data-controller=addon]").first
      %w[
        data-addon-entry-value data-addon-save-url-value data-addon-service-url-value
        data-addon-states-url-value data-addon-folders-value data-addon-default-folder-value
        data-addon-default-folder-label-value data-addon-children-url-value
        data-addon-create-url-value
      ].each do |attribute|
        assert mount[attribute], "#{attribute} is gone — a published bundle reads it"
      end
    end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/controllers/tools/addons_controller_test.rb -n "/ctx blob|pre-SDK/"`
Expected: FAIL — the first two error inside `rendered_ctx` with `NoMethodError: undefined method '[]' for nil` (no element carries `data-addon-ctx-value`); "every pre-SDK data attribute" PASSES already, which is correct — it is a regression guard, not a driver.

- [ ] **Step 3: Build the ctx hash in the controller**

In `app/controllers/tools/addons_controller.rb`, replace the body of `#show` (currently ending at `@service_url = service_base_url`) with:

```ruby
    def show
      @importmap = merged_importmap
      @default_parent_node_id = current_project_folder_node_id
      # BOTH shapes of "where does this save go?", because a bundle may be built against either.
      # `folders` is the flat [label, node_id] list the shipped bundles build a <select> from;
      # `default_folder_label` is the one path a chooser trigger shows. This repo cannot know which
      # a given bundle reads — publishing the bundle image is the addon deploy and Rails is never
      # rebuilt (§14c) — so it answers both until the addons repo says otherwise.
      @folders = folder_options
      @default_folder_label = folder_path_label(@default_parent_node_id)
      @service_url = service_base_url
      @ctx = addon_ctx
    end
```

Then add, in the `private` section:

```ruby
    # THE SDK's VIEW OF THE HOST, AS ONE SERIALIZED VALUE. Everything here is data the SERVER knows;
    # the two browser-side members of ctx (`chooseFolder`, which is a function, and the CSRF token,
    # which lives in a meta tag) are added by addon_controller.js. Splitting it that way keeps this
    # hash JSON-serializable and keeps the token out of a second place in the DOM.
    #
    # The nine legacy data attributes are NOT removed and this does not replace them — see the
    # compatibility rule in docs/addon-api-v1.md §6. This is an addition.
    def addon_ctx
      {
        apiVersion: Maker::Addons::Registry::API_VERSION,
        hostLevel: Maker::Addons::Host::LEVEL,
        capabilities: Maker::Addons::Host.capabilities,
        addon: { key: @addon.key },
        urls: {
          save: tools_addon_path(@addon.key),
          states: tools_addon_states_path(@addon.key),
          # A BASE, ending in "/" — a bundle builds `${service}/${path}` onto it. Derived from the
          # real route by service_base_url, never a literal.
          service: @service_url,
          children: library_children_path,
          create: library_folders_path
        },
        defaultFolder: { nodeId: @default_parent_node_id, label: @default_folder_label }
      }
    end
```

- [ ] **Step 4: Emit it in the view**

In `app/views/tools/addons/show.html.erb`, add one attribute to the existing `div data-controller="addon"` element, directly under `data-controller="addon"`:

```erb
     data-addon-ctx-value="<%= @ctx.to_json %>"
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bin/rails test test/controllers/tools/addons_controller_test.rb`
Expected: PASS — the whole file, 0 failures.

- [ ] **Step 6: Mutation-check the compatibility guard (§15)**

Temporarily delete the `data-addon-folders-value="<%= @folders.to_json %>"` line from the view.
Run: `bin/rails test test/controllers/tools/addons_controller_test.rb -n "/pre-SDK/"`
Expected: FAIL — `data-addon-folders-value is gone — a published bundle reads it`.
**Restore the line and re-run — expected PASS.**

- [ ] **Step 7: Commit**

```bash
git add app/controllers/tools/addons_controller.rb app/views/tools/addons/show.html.erb test/controllers/tools/addons_controller_test.rb
git commit -m "feat(addons): render one ctx blob into the addon shell"
```

---

### Task 3: The SDK module and its host pin

**Files:**
- Create: `app/javascript/maker/addon_sdk.js`
- Modify: `config/importmap.rb`
- Test: `test/controllers/tools/addons_controller_test.rb`

- [ ] **Step 1: Write the failing test**

Add to `test/controllers/tools/addons_controller_test.rb`:

```ruby
    # THE SDK IS A HOST PIN, WHICH IS WHAT MAKES IT FREE TO AN ADDON. merged_importmap draws every
    # host pin before the addon's own, so a bundle can `import { host } from "@maker/addon-sdk"`
    # without declaring anything in its manifest. If this pin is ever dropped, every SDK-based
    # bundle fails in the browser with a bare specifier error and nothing server-side notices.
    test "the merged importmap resolves the SDK specifier for every addon" do
      get tools_addon_path(FIXTURE_KEY)
      assert_response :success
      json = JSON.parse(css_select("script[type='importmap']").first.text)
      assert json["imports"].key?("@maker/addon-sdk"),
             "@maker/addon-sdk is not in the merged importmap: #{json["imports"].keys.sort.inspect}"
      assert_match %r{/maker/addon_sdk}, json["imports"]["@maker/addon-sdk"]
    end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/controllers/tools/addons_controller_test.rb -n "/SDK specifier/"`
Expected: FAIL — `@maker/addon-sdk is not in the merged importmap: [...]`

- [ ] **Step 3: Write the SDK**

Create `app/javascript/maker/addon_sdk.js`:

```js
// THE ADDON HOST SDK — the one thing an addon bundle should touch.
//
// WHY IT EXISTS RATHER THAN A DOCUMENTED ctx. Every bundle today hand-rolls the same fetch + CSRF +
// error handling, and each copy reads only the HTTP status, so a save that failed for a nameable
// reason reports "Save failed." More importantly: this module is the HINGE for the sandbox (Ring 2,
// spec §8.2). Today its transport is same-origin fetch; under a null-origin iframe the identical
// surface is implemented over postMessage. Addon code does not change. Talking to `ctx` directly
// forfeits that, which is why the raw values stay supported but undocumented for new bundles.
//
// `host` IS A LIVE BINDING, NOT A SINGLETON YOU CONSTRUCT. addon_controller.js calls initHost(ctx)
// BEFORE it dynamic-imports the bundle, so by the time any addon code runs the binding is set.
// Consequence worth knowing: destructuring at module top level (`const { files } = host`) captures
// null. Read through `host` at call time.

export let host = null

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

// Every failure an addon can act on is a class, so a bundle branches on `instanceof` rather than
// parsing a message. `code` is the server's own code (docs/addon-api-v1.md §5) and `body` is the
// parsed payload, kept so a caller can reach fields this SDK does not model yet.
export class AddonError extends Error {
  constructor(code, message, body = null, status = null) {
    super(message)
    this.name = new.target.name
    this.code = code
    this.body = body
    this.status = status
  }
}

// 422 — the destination name is taken. NEVER succeeds on retry, so it must not be offered as a
// question. This is the distinction save.js exists to make; getting it wrong offers an Overwrite
// button for a save that can never take one.
export class NameTakenError extends AddonError {}

// 409 — the save WOULD replace files the addon previously wrote. Answerable: re-send with
// overwrite. `files` is [{name, folder}].
export class WouldReplaceError extends AddonError {
  get files() { return this.body?.files ?? [] }
}

// 503 — the library is unreachable (an unmounted share). Retryable.
export class ServiceUnavailableError extends AddonError {}

// The host does not have this capability at this level. Thrown by the SDK itself, before any
// request, so the failure names the capability instead of surfacing as a 404.
export class UnsupportedCapabilityError extends AddonError {}

const ERROR_CLASSES = {
  would_replace: WouldReplaceError,
  name_taken: NameTakenError,
  unsupported_operation: NameTakenError,
  fetch_error: ServiceUnavailableError,
  service_unavailable: ServiceUnavailableError,
}

// READS BOTH BODY SHAPES ON PURPOSE. The nested {error: {code, message}} contract lands in PR 3;
// the host answers the flat {error: "code", message} today and keeps answering it for the life of
// api_version 1. An SDK that understood only one of them would break on whichever host it met.
async function errorFrom(res) {
  let body = null
  try { body = await res.json() } catch { /* a body-less or non-JSON failure is still a failure */ }

  const nested = body?.error && typeof body.error === "object" ? body.error : null
  const code = nested?.code ?? (typeof body?.error === "string" ? body.error : "request_failed")
  const message = nested?.message ?? body?.message ?? `Request failed (${res.status})`
  const Klass = ERROR_CLASSES[code] ?? AddonError
  return new Klass(code, message, body, res.status)
}

// ---------------------------------------------------------------------------
// The host
// ---------------------------------------------------------------------------

class Host {
  constructor(ctx) {
    this.ctx = ctx
    this.level = ctx.hostLevel
    this.addon = ctx.addon
    this._caps = ctx.capabilities ?? {}
    this._teardown = []
  }

  // Async because Ring 2 answers it over RPC. Returns a copy: a bundle must not be able to talk
  // itself into a capability by mutating the map.
  async capabilities() { return { ...this._caps } }

  _require(name) {
    if (!this._caps[name]) {
      throw new UnsupportedCapabilityError(
        "unsupported_capability",
        `This host (level ${this.level}) does not support "${name}". Check host.capabilities() first.`,
      )
    }
  }

  _post(url, body) {
    return fetch(url, { method: "POST", body, headers: { "X-CSRF-Token": this.ctx.csrfToken } })
  }

  files = {
    // Absorbs what every bundle copies today (save.js): POST, and if the host answers 409
    // would_replace, ask `onReplace` and re-send with overwrite=1. A bundle passing no onReplace
    // gets the WouldReplaceError thrown instead, which is the honest default — silently
    // overwriting is the one behaviour that must never be implicit.
    save: async ({ name, data = {}, folderNodeId = "", files = [], onReplace = null }) => {
      this._require("library:write")

      const build = (overwrite) => {
        const body = new FormData()
        body.append("name", name)
        body.append("data", JSON.stringify(data))
        body.append("parent_node_id", folderNodeId ?? "")
        body.append("files", JSON.stringify(files.map((f) => ({
          name: f.name, content_type: f.contentType, body: f.body,
        }))))
        if (overwrite) body.append("overwrite", "1")
        return body
      }

      const url = this.ctx.urls.save
      let res = await this._post(url, build(false))
      if (res.ok) return res.json().catch(() => ({}))

      const error = await errorFrom(res)
      if (!(error instanceof WouldReplaceError)) throw error
      if (!onReplace) throw error

      const proceed = await onReplace(error.files)
      if (!proceed) return { cancelled: true }

      res = await this._post(url, build(true))
      if (res.ok) return res.json().catch(() => ({}))
      throw await errorFrom(res)
    },

    // The host's own chooser, handed across as a function since before the SDK existed. Resolves
    // {nodeId, kind, path} or null for CANCEL — and null is deliberately NOT the same answer as
    // the library root ({nodeId: ""}); conflating them silently moves a save to the root on Esc.
    pickFolder: async (options = {}) => {
      this._require("pick:folder")
      if (typeof this.ctx.chooseFolder !== "function") return null
      return this.ctx.chooseFolder(options)
    },

    // A URL for an <img src> or a download link. A method rather than a documented path so the
    // route stays the host's to change without republishing every bundle.
    url: (nodeId) => `/files/${encodeURIComponent(nodeId)}`,
  }

  state = {
    list: async () => {
      this._require("state:list")
      const res = await fetch(this.ctx.urls.states, { headers: { Accept: "application/json" } })
      if (!res.ok) throw await errorFrom(res)
      return res.json()
    },
  }

  service = {
    // `${serviceUrl}${service}/${path}` — the base keeps its trailing slash for exactly this.
    get: async (service, path, params = {}) => {
      this._require("service")
      const qs = new URLSearchParams(params).toString()
      const url = `${this.ctx.urls.service}${service}/${path}${qs ? `?${qs}` : ""}`
      const res = await fetch(url)
      if (!res.ok) throw await errorFrom(res)
      return res
    },

    post: async (service, path, params = {}) => {
      this._require("service")
      const body = new FormData()
      Object.entries(params).forEach(([ k, v ]) => body.append(k, v))
      const res = await this._post(`${this.ctx.urls.service}${service}/${path}`, body)
      if (!res.ok) throw await errorFrom(res)
      return res
    },
  }

  // The only lifecycle event in v1. The shell calls it on disconnect so a bundle can stop timers.
  on(event, fn) {
    if (event !== "teardown") throw new AddonError("unknown_event", `Unknown event "${event}"`)
    this._teardown.push(fn)
  }

  _fireTeardown() {
    this._teardown.forEach((fn) => { try { fn() } catch { /* one bad handler must not block the rest */ } })
    this._teardown = []
  }
}

export function initHost(ctx) {
  host = new Host(ctx)
  return host
}

export function teardownHost() {
  host?._fireTeardown()
  host = null
}
```

- [ ] **Step 4: Add the host pin**

In `config/importmap.rb`, immediately after the `pin "lib/file_chooser", to: "lib/file_chooser.js"` block, add:

```ruby
# THE ADDON SDK — a HOST pin, which is the whole point: merged_importmap draws every host pin before
# the addon's own, so a bundle imports "@maker/addon-sdk" without declaring anything in its manifest
# and without the host shipping a copy per addon. Unlike lib/file_chooser directly above (which a
# bundle must NOT import — its contract is the ctx function), this specifier IS the public contract:
# it is what docs/addon-api-v1.md tells authors to import, so the SPECIFIER may never change while
# api_version 1 lives, even though the file behind it may move freely.
pin "@maker/addon-sdk", to: "maker/addon_sdk.js"
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bin/rails test test/controllers/tools/addons_controller_test.rb -n "/SDK specifier/"`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add app/javascript/maker/addon_sdk.js config/importmap.rb test/controllers/tools/addons_controller_test.rb
git commit -m "feat(addons): add the @maker/addon-sdk host module and pin it"
```

---

### Task 4: The shell initializes the SDK before the bundle loads

**Files:**
- Modify: `app/javascript/controllers/addon_controller.js`

- [ ] **Step 1: Modify the controller**

Replace `app/javascript/controllers/addon_controller.js` lines 1–2 (the imports) with:

```js
import { Controller } from "@hotwired/stimulus"
import { chooseFolder } from "lib/file_chooser"
import { initHost, teardownHost } from "@maker/addon-sdk"
```

Add `ctx: Object` to the `static values` block, so it reads:

```js
  static values = {
    entry: String, saveUrl: String, serviceUrl: String, statesUrl: String,
    folders: Array, defaultFolder: String, defaultFolderLabel: String,
    childrenUrl: String, createUrl: String, ctx: Object,
  }
```

Replace the body of `connect()` with:

```js
  async connect() {
    try {
      const chooser = (options = {}) => chooseFolder({
        childrenUrl: this.childrenUrlValue,
        createUrl: this.createUrlValue,
        value: this.defaultFolderValue,
        label: this.defaultFolderLabelValue,
        ...options,
      })
      const csrfToken = document.querySelector("meta[name=csrf-token]")?.content

      // INITIALIZED BEFORE THE BUNDLE IS IMPORTED, and the order is the contract: a bundle's
      // top-level code runs at import time, so `host` must already be bound by then. The two
      // members added here are the ones the server cannot serialize — a function, and a token
      // that already lives in a meta tag and must not be duplicated into a second DOM node.
      initHost({ ...this.ctxValue, chooseFolder: chooser, csrfToken })

      const module = await import(this.entryValue)
      await module.default.mount(this.mountTarget, {
        saveUrl: this.saveUrlValue,
        serviceUrl: this.serviceUrlValue,
        statesUrl: this.statesUrlValue,
        // THE FLAT LIST STAYS, and removing it is the one change here that would break production
        // without any test noticing. The two repos deploy INDEPENDENTLY — republishing a bundle IS
        // the addon deploy and Rails is never rebuilt (§14c) — so at any moment a bundle built
        // against either context may be running against a host built against the other. Every
        // shipped bundle today builds its own <select> from these two, and `bin/rollback` in the
        // addons repo can put one of those back at any time. `folders` goes when no reachable
        // bundle reads it, which is a decision for that repo, not this one.
        folders: this.foldersValue,
        defaultFolder: this.defaultFolderValue,
        // The default folder's PATH ("/Projects/harbor"), for a bundle that shows a chooser trigger
        // instead of a select. The select got its label from the `folders` pairs; a chooser has no
        // list to look one up in, so the host has to say it.
        defaultFolderLabel: this.defaultFolderLabelValue,
        // THE CHOOSER, AS A FUNCTION RATHER THAN MARKUP OR A MODULE PATH. Markup was the obvious
        // alternative — have Rails render shared/_folder_field into the shell — and it cannot work:
        // the bundle owns its own layout and the host has no idea where in it a destination field
        // belongs. A module specifier was the other, and it would make lib/file_chooser.js's path
        // part of the addon API, unmovable without republishing every bundle.
        //
        // -> Promise<{nodeId, kind, path} | null>. null is CANCEL, and is deliberately not the same
        // answer as choosing the library root ({nodeId: ""}): a bundle that conflates them silently
        // moves the user's destination to root when they press Esc.
        //
        // Absent on an older host, which is exactly why it is worth feature-detecting in the bundle
        // (`typeof ctx.chooseFolder === "function"`) rather than assuming.
        chooseFolder: chooser,
        csrfToken,
      })
    } catch (e) {
      this.mountTarget.textContent = `This tool failed to load: ${e.message}`
    }
  }

  disconnect() {
    teardownHost()
  }
```

- [ ] **Step 2: Verify nothing regressed**

Run: `bin/rails test:system TEST=test/system/addon_bundle_test.rb`
Expected: PASS — the pre-SDK fixture still mounts and still saves. This is the compatibility rule proven rather than asserted: that fixture imports no SDK and reads raw `ctx`.

- [ ] **Step 3: Commit**

```bash
git add app/javascript/controllers/addon_controller.js
git commit -m "feat(addons): initialize the SDK before importing a bundle"
```

---

### Task 5: A fixture bundle that uses only the SDK — the proof

**Files:**
- Create: `test/fixtures/addons/sdk-fixture/sdk.js`
- Modify: `test/fixtures/addons/manifests.json`
- Test: `test/system/addon_sdk_test.rb`

- [ ] **Step 1: Add the fixture manifest entry**

In `test/fixtures/addons/manifests.json`, add a third entry to the array, after the `boxes` object:

```json
  {
    "key": "sdk-fixture",
    "title": "SDK Fixture",
    "icon": "🔌",
    "description": "Hermetic fixture that touches the host ONLY through @maker/addon-sdk — no raw ctx, no hand-rolled fetch. Owned by test/system/addon_sdk_test.rb. The sibling `fixture` addon deliberately stays on the raw-ctx path so both halves of the compatibility rule are covered by something that runs.",
    "api_version": "1",
    "entry": "sdk.js"
  }
```

- [ ] **Step 2: Write the fixture bundle**

Create `test/fixtures/addons/sdk-fixture/sdk.js`:

```js
import { host, WouldReplaceError } from "@maker/addon-sdk"

// A bundle written the way docs/addon-api-v1.md tells an author to write one: it imports the SDK
// and touches `ctx` for nothing. Its job is to prove, in a real browser, that (a) the host pin
// resolves inside an addon's merged importmap, (b) initHost ran before this module was imported,
// (c) capabilities() answers the server's own map, and (d) files.save absorbs the 409 overwrite
// dance every bundle copies today.
//
// The destination and filename come from the QUERY STRING so the Ruby test can point the fixture at
// whatever project folder it just built, rather than the fixture hard-coding library state.
export default {
  mount(el, _ctx) {
    const q = new URLSearchParams(location.search)

    el.innerHTML = `<p data-role="sdk-level"></p>
      <p data-role="sdk-caps"></p>
      <button data-role="sdk-save">Save</button>
      <p data-role="sdk-status"></p>`

    // Rendering the LEVEL proves initHost ran before this module was imported — a fixture that only
    // asserted its own text would pass with the binding still null.
    el.querySelector("[data-role=sdk-level]").textContent = `level ${host.level}`

    host.capabilities().then((caps) => {
      el.querySelector("[data-role=sdk-caps]").textContent =
        `write:${caps["library:write"]} read:${caps["library:read"]}`
    })

    el.querySelector("[data-role=sdk-save]").addEventListener("click", async () => {
      const status = el.querySelector("[data-role=sdk-status]")
      try {
        const result = await host.files.save({
          name: "sdk fixture save",
          folderNodeId: q.get("parent") || "",
          files: [ { name: q.get("fname"), contentType: "image/svg+xml", body: "<svg>sdk</svg>" } ],
          // Answering TRUE here is what exercises the re-POST with overwrite=1. A real bundle would
          // call window.confirm; the fixture answers deterministically so no dialog is involved.
          onReplace: (files) => {
            status.dataset.replaced = files.map((f) => `${f.name}@${f.folder}`).join(",")
            return true
          },
        })
        status.textContent = result?.cancelled ? "Not saved." : "Saved."
      } catch (e) {
        // The typed error is the point: a bundle can say WHICH refusal happened, which is exactly
        // what today's hand-rolled "Save failed." cannot.
        status.textContent = e instanceof WouldReplaceError ? "Would replace." : `Failed: ${e.code}`
      }
    })
  },
}
```

- [ ] **Step 3: Write the failing system test**

Create `test/system/addon_sdk_test.rb`:

```ruby
require "application_system_test_case"

# THE SDK, IN THE ONLY PLACE IT IS REAL. There is no JS unit-test runner in this repo (no
# package.json, importmap + Propshaft only), and the SDK is transport — a fetch, a CSRF header, a
# 409 round trip, a bare specifier resolving through a per-request merged importmap. None of that is
# observable from a request test; §14e records two CSP defects that shipped past every integration
# test and were caught only by a browser.
#
# HERMETIC, like its sibling addon_bundle_test.rb: this reads test/fixtures/addons, never the
# chaim354/tinkerex-addons working copy, so a fresh clone can run it.
class AddonSdkTest < ApplicationSystemTestCase
  setup do
    @prior_addon_source_path = ENV["ADDON_SOURCE_PATH"]
    ENV["ADDON_SOURCE_PATH"] = Rails.root.join("test/fixtures/addons").to_s
    sign_in_as "sdk@example.com"
  end

  teardown do
    ENV["ADDON_SOURCE_PATH"] = @prior_addon_source_path
  end

  test "a bundle that imports the SDK mounts, sees the host level, and reads the capability map" do
    visit "/tools/sdk-fixture"
    assert_selector "[data-role=sdk-level]", text: "level #{Maker::Addons::Host::LEVEL}"
    # Asserted from the SERVER's own map rather than a literal, so flipping a capability in PR 4 or
    # PR 5 does not leave a stale literal here passing for the wrong reason.
    caps = Maker::Addons::Host.capabilities
    assert_selector "[data-role=sdk-caps]",
                    text: "write:#{caps["library:write"]} read:#{caps["library:read"]}"
    assert_no_console_errors
  end

  test "files.save writes through the real save door" do
    user = User.find_by!(email: "sdk@example.com")
    project = user.maker_projects.create!(name: "SDK Harbor")
    folder = project.ensure_library_folder!(user)

    visit "/tools/sdk-fixture?parent=#{folder.node_id}&fname=sdk-one.svg"
    click_button "Save"
    assert_selector "[data-role=sdk-status]", text: "Saved."
    assert_no_console_errors
  end

  # THE 409 DANCE, ABSORBED. Saving the same name twice is the bug CLAUDE.md §12 item 11 records:
  # the first copy is filed into a category subfolder by the intake sweep, leaving the picked folder
  # vacant, so the door accepts the second save and the sweep then cannot place it. The host answers
  # 409 would_replace BEFORE writing; what this proves is that the SDK reads that, calls onReplace,
  # and re-POSTs with overwrite=1 — the logic every bundle copies by hand today.
  test "files.save asks onReplace on a 409 and replaces when it answers true" do
    user = User.find_by!(email: "sdk@example.com")
    project = user.maker_projects.create!(name: "SDK Harbor")
    folder = project.ensure_library_folder!(user)

    visit "/tools/sdk-fixture?parent=#{folder.node_id}&fname=sdk-dup.svg"
    click_button "Save"
    assert_selector "[data-role=sdk-status]", text: "Saved."

    visit "/tools/sdk-fixture?parent=#{folder.node_id}&fname=sdk-dup.svg"
    click_button "Save"
    assert_selector "[data-role=sdk-status]", text: "Saved."
    # The onReplace callback ran and was told WHICH file and WHICH folder — a bundle that only knew
    # "something conflicted" could not write a truthful prompt.
    assert_selector "[data-role=sdk-status][data-replaced*='sdk-dup.svg']"
    assert_no_console_errors
  end
end
```

- [ ] **Step 4: Run the system test to verify it fails, then passes**

Run: `bin/rails test:system TEST=test/system/addon_sdk_test.rb`

Before Steps 1–2 exist this fails at `visit "/tools/sdk-fixture"` with a missing addon. With all three steps in place, expected: PASS — 3 runs, 0 failures.

If the first test fails with a console error naming a bare specifier, the host pin from Task 3 is not reaching the merged importmap — fix that, do not work around it in the fixture.

- [ ] **Step 5: Mutation-check that the fixture proves the SDK and not itself (§15)**

Temporarily change the pin in `config/importmap.rb` to `pin "@maker/addon-sdk-typo", to: "maker/addon_sdk.js"`.
Run: `bin/rails test:system TEST=test/system/addon_sdk_test.rb`
Expected: FAIL — the bundle cannot resolve `@maker/addon-sdk` and the shell renders "This tool failed to load: …".
**Restore the pin and re-run — expected PASS.**

- [ ] **Step 6: Commit**

```bash
git add test/fixtures/addons/manifests.json test/fixtures/addons/sdk-fixture/sdk.js test/system/addon_sdk_test.rb
git commit -m "test(addons): prove the SDK end to end with an SDK-only fixture bundle"
```

---

### Task 6: The author-facing reference

**Files:**
- Create: `docs/addon-api-v1.md`

- [ ] **Step 1: Write the document**

Create `docs/addon-api-v1.md` with these sections, extracted from `docs/superpowers/specs/2026-08-07-addon-api-v1-design.md` §4, §5, §9 and §10 — **written for an addon author, not for a maintainer** (no repo internals, no §14 citations, no rationale that only matters to this codebase):

1. **What an addon is** — a manifest plus an ESM bundle; `export default { mount(el, ctx) {} }`; publishing the bundle is the deploy.
2. **The manifest** — the six required keys with an example, then the optional ones this host understands **today** (`pins`, `services`, `layout`, `states_key`). Keys landing in PR 2 (`version`, `author`, `license`, `min_host`, `permissions`, `collections`, `contributes`, `integrity`) go in a clearly-marked **"Not yet accepted — coming in a later host level"** subsection, so an author is never told to write something the Registry will ignore.
3. **The SDK** — `import { host } from "@maker/addon-sdk"`, the live-binding note (do not destructure at module top level), and the surface that works at level 1: `host.level`, `host.addon`, `host.capabilities()`, `host.files.save`, `host.files.pickFolder`, `host.files.url`, `host.state.list`, `host.service.get/post`, `host.on("teardown")`. Each with a runnable example.
4. **Capability discovery** — the map, what each name means, and the rule: check before you call, degrade rather than crash; the SDK throws `UnsupportedCapabilityError` before making a request if you don't.
5. **Errors** — the class hierarchy, the code table, and the one distinction that matters: **409 `would_replace` is a question, 422 `name_taken` is not.**
6. **Compatibility** — what the host promises for the life of `api_version: "1"`: the raw `ctx` values and both error body shapes keep working; the SDK is additive; `mount(el, ctx)` never changes.
7. **Not in this version** — reading library files, binary output, state update/delete, collections, maker-model access, outbound HTTP. Each with the capability name that will announce it, so an author can write the feature detection now.

- [ ] **Step 2: Verify it matches the code**

Run: `bin/rails test test/services/maker/addons/host_test.rb`
Then check by hand that every capability name in `docs/addon-api-v1.md` §4 appears in `Maker::Addons::Host::CAPABILITIES` and vice versa. A name in one and not the other is the drift this whole arc exists to prevent.

- [ ] **Step 3: Commit**

```bash
git add docs/addon-api-v1.md
git commit -m "docs: the addon API v1 author reference"
```

---

### Task 7: Close out — invariants, STATUS, and the spec

**Files:**
- Modify: `CLAUDE.md` (§14c)
- Modify: `docs/STATUS.md`
- Modify: `docs/superpowers/specs/2026-08-07-addon-api-v1-design.md`

- [ ] **Step 1: Add the invariants to CLAUDE.md §14c**

Append these bullets to §14c (one line each, consequence named — §15's rule for what belongs in CLAUDE.md rather than STATUS):

```markdown
- **`@maker/addon-sdk` IS A HOST PIN AND ITS SPECIFIER IS PUBLIC API.** `merged_importmap` draws
  host pins before an addon's own, which is what lets a bundle import it without declaring
  anything. The FILE behind the pin may move freely; the SPECIFIER may not change while
  `api_version: "1"` lives — every published bundle names it, and Rails is never rebuilt when a
  bundle is (so nothing would notice until an addon 404s in a browser).
- **`initHost(ctx)` RUNS BEFORE THE BUNDLE IS IMPORTED, AND THE ORDER IS THE CONTRACT.** A bundle's
  top-level code executes at import time; `host` is a live ESM binding, so importing the entry
  module first leaves every addon reading `null`. The corollary an author must know: destructuring
  at module top level (`const { files } = host`) captures the pre-init value.
- **THE CAPABILITY MAP IS SERVER-SIDE AND HAS ONE DEFINITION** (`Maker::Addons::Host`). Every value
  is a real boolean because a missing key is `undefined` and a nil is `false` in JS — neither
  distinguishable from "deliberately off". A capability is NAMED before it is built, answered
  `false`; that is the mechanism that lets an addon be authored against a host level it has not met.
- **BUMP `Host::LEVEL` IN THE SAME COMMIT THAT FLIPS A CAPABILITY TO TRUE.** A manifest's `min_host`
  is the only way an addon can say "I need this", and `api_version` equality cannot express it.
- **A 409 `would_replace` IS A QUESTION; A 422 `name_taken` IS NOT.** The SDK throws distinct
  classes for exactly this: collapsing them offers an Overwrite button for a save that can never
  succeed on retry.
```

- [ ] **Step 2: Add the STATUS.md entry**

Insert a new `## 2026-08-07: …` section directly under the "Still open" block and above the current "Latest" section, and demote the current Latest to a plain dated heading (exactly one section is ever called Latest). Cover: what shipped, the scope correction (`generators` lives in the sibling repo, so the in-repo proof is a second fixture), the two planning discoveries (`ctx.chooseFolder` already existed; `saveWithOverwrite` is copied per bundle and the SDK absorbs it), the measured suite counts from Step 4, and what PR 1 deliberately left for PRs 2–8.

- [ ] **Step 3: Mark the spec row done**

In `docs/superpowers/specs/2026-08-07-addon-api-v1-design.md` §12, change row 1's PR cell to note it shipped in this branch, and amend §12's "generators adopts it" wording to match the scope correction at the top of this plan — the spec is amended in the branch that changes it, never afterwards.

- [ ] **Step 4: Run the full gates**

Run: `bin/ci`
Expected: **exit code 0**, all seven gates. Verify by exit code, not by reading output:

```bash
bin/ci; echo "exit=$?"
```

The three test legs (`test`, `test-share`, `test-s3`) must report **identical** run/assertion counts. Record those numbers for the STATUS entry.

- [ ] **Step 5: Commit and open the PR**

```bash
git add CLAUDE.md docs/STATUS.md docs/superpowers/specs/2026-08-07-addon-api-v1-design.md
git commit -m "docs: record the addon SDK arc and its invariants"
git push -u origin HEAD
```

Then open the PR per §15, stating plainly what was verified (the gate results and the browser proof) and what was not (the `generators` migration, which is a follow-up in the addons repo).

---

## Self-review notes

**Spec coverage for §12 row 1.** Spec §5 SDK surface → Task 3 (`capabilities`, `files.save`, `files.pickFolder`, `files.url`, `state.list`, `service.*`, `on("teardown")`); the remaining §5 methods (`files.read`, `files.pickFile`, `state.get/create/update/delete`, `data.*`, `project.current`) are PRs 3–5 and are represented here only as `false` capabilities, which is the spec's own §5 mechanism. Spec §9 error contract → Task 3's `errorFrom` reads **both** body shapes per §10; the nested shape is emitted by the server in PR 3. Spec §10 compatibility → Task 2 Step 6 and Task 4 Step 2 both prove it against something that runs. Spec §11 testing → system tests, mutation checks in Tasks 1, 2 and 5.

**Known gap, deliberate:** `host.files.url(nodeId)` hard-codes `/files/:id`, which is what the shipped bundles already do. Making it a server-supplied URL belongs with the read surface in PR 5, where there is a second URL to justify the plumbing.
