# Addon SDK — host-side prep + asset spike — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the addon registry into a registration API with self-declared paths, namespace the three addon clients under `Tools::`, add an SDK version gate, and answer the go/no-go asset question — so a `maker-addons` engine gem can be extracted next without editing the host.

**Architecture:** Everything here lands in the host repo and is independently valuable. `Maker::Addons::Registry` stops being a frozen hash and gains `register(...)`; the three host addons register from `config/initializers/addons.rb` inside `to_prepare`. Each addon declares its own `path:` proc, which deletes the gallery's dependency on `send("tools_#{key}_path")` — the sole cause of the two inflector traps in `config/routes.rb`. Separately and throwaway, a scratch engine proves (or disproves) that engine-supplied JS resolves through importmap + propshaft in a real browser.

**Tech Stack:** Rails 8.1, Ruby 3.4.7, Zeitwerk, importmap-rails, propshaft, Minitest, Capybara + headless Chrome.

---

## Corrections found during execution

Recorded here, not silently fixed in place, so a future re-derivation from this plan doesn't
reproduce the same three defects. All three were found by running the plan, not by reading it.

1. **Task 1 Step 4's `sed -i '' -E` command does not work on macOS.** BSD sed's extended regex
   has no `\b`; the command exits 0 and reports success while changing nothing. Reproduced live
   on the build Mac. Use `perl -pi -e 's/(^|[^:\w])(BoxesClient|OpenscadClient|OpenscadParams)\b/\1Tools::\2/g'`
   instead — `\w`/`\b` are supported in Perl regex, and `(^|[^:\w])` still guards against
   double-prefixing an already-qualified `Tools::BoxesClient`. Caught only because the
   implementer diffed the files rather than trusting the exit code.
2. **Task 4 Step 1's `assert_select` three-argument form is wrong.** As written,
   `assert_select "a.addon-card[href=?]", addon.path_for(helpers), "no gallery link for #{addon.key}"`
   consumes the message string as the equality comparator (`assert_select` shifts one value per
   `?` for substitution, then shifts the next remaining value as the comparator) — so it
   silently asserts the card's text content equals that message, not that a matching link
   exists. Needs an explicit `nil` in the comparator slot before the message:
   `assert_select "a.addon-card[href=?]", addon.path_for(helpers), nil, "no gallery link for #{addon.key}"`.
3. **Task 4's "renders a working link for every available addon" test does not pin the fix, and
   cannot be made to.** It loops over `Registry.all.select(&:available?)`; in the test env that
   is one addon (`generators`) unless the sidecar env vars are forced, and even with all three
   forced available, all three real keys inflect cleanly to their own route helper — so the old
   `send("tools_#{key}_path")` code and the new `path_for` code produce identical output for
   every addon this repo ships. Only a test with a deliberately non-inflecting key (`"weird.key"`)
   pins the change; the all-addons loop is an end-to-end smoke test and should be labeled as one,
   not as a regression guard.

Also, **Task 2 Step 4's expected output is wrong**: it reads `3 runs, 4 assertions, 0 failures,
0 errors, 0 skips`. The true count, reproduced by running the test, is **`3 runs, 5 assertions,
0 failures, 0 errors, 0 skips`**.

---

## Scope

This plan covers **steps 0 and 1** of `docs/superpowers/specs/2026-08-02-tools-addons-separate-repo-design.md` §9 only.

Steps 2–5 (create the repo, move `generators`, then `openscad`, then `boxes`, then the sidecars and docs) get their **own plan**, written after Task 0 resolves. Planning them now would mean writing detailed tasks on top of an unverified assumption about engine assets — which spec §5 explicitly says to spike first. Prefer a probe over an argument (CLAUDE.md §15).

**Task 0 does not gate Tasks 1–5.** Spec §9 step 1 is "reversible and valuable on its own — improves the host whether or not the split happens," and that holds even on a NO-GO: registration, path procs and client namespacing are prerequisites for the reduced (Ruby/ERB-only) split too. Task 0 is first because it is the highest-information, lowest-cost action, and its result decides what the *next* plan looks like.

---

## File Structure

**Created:**

| Path | Responsibility |
|---|---|
| `app/services/maker/addons.rb` | The `Maker::Addons` namespace made explicit: `SDK_VERSION`, `IncompatibleSDK`, `require_sdk!`. Nothing else. |
| `config/initializers/addons.rb` | Where the host's own three addons register. The only file that needs editing to add a *host* addon; a gem needs none. |
| `test/services/maker/addons_test.rb` | SDK version gate. |
| `test/services/maker/addons/registry_test.rb` | Registration, ordering, and the generalized path-resolves guard. |

**Modified:**

| Path | Change |
|---|---|
| `app/services/maker/addons/registry.rb` | Frozen hash → `register`/`all`/`find`/`reset!`; `Addon` gains `path` + `path_for`. |
| `app/views/tools/home/index.html.erb` | `send("tools_#{addon.key}_path")` → `addon.path_for(self)`. |
| `app/controllers/tools/home_controller.rb` | Unchanged in behaviour; verify `Registry.all` still fits. |
| `app/services/{boxes_client,openscad_client,openscad_params}.rb` | Moved to `app/services/tools/`, wrapped in `module Tools`. |
| 16 further files | Reference updates for the rename — full list in Task 1. |
| `config/routes.rb:159-170` | The inflector-trap comment asserts a mechanism that no longer exists. Must be corrected. |
| `test/controllers/tools/openscad_controller_test.rb` | Same stale mechanism in its guard comment. |
| `CLAUDE.md` §14c | The `Registry` bullet describes the frozen hash. |
| `docs/STATUS.md` | Narrate the arc. |

---

## Task 0: Asset-pipeline spike (GO/NO-GO)

Not TDD — an experiment with one falsifiable question: **can a non-isolated Rails engine contribute importmap pins and asset paths that resolve in a real browser in this app?** Two mechanisms are under test at once: `pin_all_from` an engine directory reaching `eagerLoadControllersFrom("controllers", …)`, and a bare `pin` of an engine-vendored ESM module.

**Files:**
- Create (throwaway, in the scratchpad — **do not commit**): `$SCRATCH/spike-engine/**`
- Modify (temporary, **reverted in step 8**): `Gemfile`, `app/views/tools/home/index.html.erb`
- Create (temporary, **reverted in step 8**): `test/system/engine_assets_spike_test.rb`

Use `$SCRATCH` = the session scratchpad directory given in the environment.

- [ ] **Step 1: Create the scratch engine's gemspec and entry point**

```bash
mkdir -p "$SCRATCH/spike-engine/lib/spike_engine" \
         "$SCRATCH/spike-engine/app/javascript/controllers" \
         "$SCRATCH/spike-engine/vendor/javascript" \
         "$SCRATCH/spike-engine/config"
```

`$SCRATCH/spike-engine/spike_engine.gemspec`:

```ruby
Gem::Specification.new do |s|
  s.name        = "spike_engine"
  s.version     = "0.0.1"
  s.authors     = [ "spike" ]
  s.summary     = "Throwaway engine proving importmap/propshaft asset contribution."
  s.license     = "MIT"
  s.files       = Dir["lib/**/*", "app/**/*", "config/**/*", "vendor/**/*"]
  s.required_ruby_version = ">= 3.4"
  s.add_dependency "rails", ">= 8.1"
end
```

`$SCRATCH/spike-engine/lib/spike_engine.rb`:

```ruby
require "spike_engine/engine"

module SpikeEngine
end
```

- [ ] **Step 2: Write the engine's asset initializer**

`$SCRATCH/spike-engine/lib/spike_engine/engine.rb`:

```ruby
module SpikeEngine
  # NOT isolate_namespace — the real engine is non-isolated (spec §3), and isolation changes
  # helper/layout lookup, so a spike using it would not be testing the same thing.
  class Engine < ::Rails::Engine
    initializer "spike_engine.assets", before: "importmap" do |app|
      app.config.importmap.paths << root.join("config/importmap.rb")
      app.config.importmap.cache_sweepers << root.join("app/javascript")
      app.config.assets.paths << root.join("app/javascript")
      app.config.assets.paths << root.join("vendor/javascript")
    end
  end
end
```

`$SCRATCH/spike-engine/config/importmap.rb`:

```ruby
# pin_all_from needs an ABSOLUTE path from an engine — the host's relative form resolves against
# Rails.root, which is the application, not here.
pin_all_from File.expand_path("../app/javascript/controllers", __dir__), under: "controllers"
pin "spikelib", to: "spikelib.js"
```

- [ ] **Step 3: Write the two JS files under test**

`$SCRATCH/spike-engine/app/javascript/controllers/spike_controller.js`:

```javascript
import { Controller } from "@hotwired/stimulus"
import spikelib from "spikelib"

export default class extends Controller {
  connect() {
    this.element.textContent = `spike-ok:${spikelib()}`
  }
}
```

`$SCRATCH/spike-engine/vendor/javascript/spikelib.js`:

```javascript
export default function spikelib() {
  return "lib-ok"
}
```

The controller importing the vendored lib is deliberate: if the text reads `spike-ok:lib-ok`, **both** mechanisms work. If the element stays `pending`, neither the pin nor the eager-load fired. If the browser console shows a module-resolution error naming `spikelib`, `pin_all_from` works and the bare `pin` does not — three distinguishable outcomes from one probe.

- [ ] **Step 4: Wire the engine into the host, temporarily**

Append to `Gemfile` (use the real absolute scratchpad path):

```ruby
gem "spike_engine", path: "<absolute $SCRATCH path>/spike-engine"
```

Then:

```bash
bundle install
```

Expected: `Using spike_engine 0.0.1 from source at ...`

- [ ] **Step 5: Add the probe element**

In `app/views/tools/home/index.html.erb`, immediately after the `<div class="page-head">…</div>` line, add:

```erb
<div data-controller="spike" id="spike-probe">pending</div>
```

- [ ] **Step 6: Write the spike system test**

`test/system/engine_assets_spike_test.rb`:

```ruby
require "application_system_test_case"

# THROWAWAY (spec §5 / plan Task 0). Answers one question: does a non-isolated engine's JS resolve
# in a real browser here? Asserted in the browser, not by reading the importmap — a rendered
# importmap that parses is not an importmap that resolves, the same lesson as the CSP nonce (§14e).
class EngineAssetsSpikeTest < ApplicationSystemTestCase
  setup { sign_in_as "spike@example.com" }

  test "an engine-supplied Stimulus controller connects and imports an engine-vendored module" do
    visit tools_path
    assert_selector "#spike-probe", text: "spike-ok:lib-ok"
    assert_no_console_errors
  end
end
```

- [ ] **Step 7: Run it — this is the GO/NO-GO**

Run: `bin/rails test:system TEST=test/system/engine_assets_spike_test.rb`

Read the outcome against the three cases in Step 3:

| Outcome | Meaning | Consequence for the next plan |
|---|---|---|
| PASS | Both mechanisms work | **GO** — full split as specced |
| `#spike-probe` still `pending` | Engine controllers never eager-loaded | **NO-GO** — fall back to Ruby/ERB-only split |
| Console error naming `spikelib` | `pin_all_from` works, bare `pin` does not | **PARTIAL** — engine ships controllers, host keeps `vendor/javascript` |

- [ ] **Step 8: Tear the spike down completely**

```bash
git checkout -- Gemfile Gemfile.lock app/views/tools/home/index.html.erb
rm -f test/system/engine_assets_spike_test.rb
rm -rf "$SCRATCH/spike-engine"
bundle install
git status --short
```

Expected: `git status --short` prints nothing. The spike is never committed; only its *answer* matters.

- [ ] **Step 9: Report the result to the user before continuing**

State which of the three outcomes occurred and what it means for steps 2–5. On PARTIAL or NO-GO, **stop and ask** — spec §5 records this as a decision for the owner, not something to work around silently. Tasks 1–5 below remain correct either way and may proceed.

---

## Task 1: Namespace the three addon clients under `Tools::`

`BoxesClient`, `OpenscadClient` and `OpenscadParams` are top-level constants — the only real collision risk a gem introduces into the host's global namespace (spec §3). Purely mechanical; the existing suite is the test.

**Files:**
- Move: `app/services/boxes_client.rb` → `app/services/tools/boxes_client.rb`
- Move: `app/services/openscad_client.rb` → `app/services/tools/openscad_client.rb`
- Move: `app/services/openscad_params.rb` → `app/services/tools/openscad_params.rb`
- Move: `test/services/boxes_client_test.rb` → `test/services/tools/boxes_client_test.rb`
- Move: `test/services/openscad_client_test.rb` → `test/services/tools/openscad_client_test.rb`
- Modify (references): `app/controllers/tools/boxes_controller.rb`, `app/controllers/tools/openscad_controller.rb`, `app/services/maker/addons/registry.rb`, `app/views/tools/boxes/_form.html.erb`, `app/views/tools/openscad/_field.html.erb`, `test/controllers/tools/boxes_controller_test.rb`, `test/controllers/tools/openscad_controller_test.rb`, `test/integration/tools/boxes_live_test.rb`, `test/integration/tools/openscad_live_test.rb`, `test/support/fake_boxes.rb`, `test/support/fake_openscad.rb`, `test/system/box_sections_test.rb`, `test/system/tray_layout_test.rb`, `test/system/tray_top_view_test.rb`

- [ ] **Step 1: Confirm the reference set before touching anything**

Run:

```bash
grep -rln "\bBoxesClient\b\|\bOpenscadClient\b\|\bOpenscadParams\b" app lib test config | sort
```

Expected: exactly 19 files. If the count differs, the codebase moved since this plan was written — re-derive the list before continuing rather than trusting it.

Also confirm there are no string or `constantize` references, which a rename would miss:

```bash
grep -rn "[\"']BoxesClient\|[\"']OpenscadClient\|[\"']OpenscadParams" app lib test config || echo "none"
```

Expected: `none`

- [ ] **Step 2: Move the files**

```bash
mkdir -p app/services/tools test/services/tools
git mv app/services/boxes_client.rb    app/services/tools/boxes_client.rb
git mv app/services/openscad_client.rb app/services/tools/openscad_client.rb
git mv app/services/openscad_params.rb app/services/tools/openscad_params.rb
git mv test/services/boxes_client_test.rb    test/services/tools/boxes_client_test.rb
git mv test/services/openscad_client_test.rb test/services/tools/openscad_client_test.rb
```

- [ ] **Step 3: Wrap each moved class in `module Tools`**

In each of the three moved service files, wrap the existing top-level `class …` in `module Tools … end` and indent its body by two spaces. The leading `require` lines stay at the top of the file, **outside** the module. For example `app/services/tools/boxes_client.rb` becomes:

```ruby
require "net/http"
require "json"

module Tools
  # Typed client for the boxes sidecar (the forked boxes.py). Real HTTP; the sidecar itself is Plan B.
  # `configured?` gates the addon's availability (no BOXES_SIDECAR_URL -> the Box Generator shows as
  # unavailable, the same graceful degradation the preview renderers use). Tests inject FakeBoxes via
  # `Tools::BoxesClient.stub` (test/support/fake_boxes.rb).
  class BoxesClient
    # ... existing body, indented two more spaces, unchanged ...
  end
end
```

Do the same for `Tools::OpenscadClient` and `Tools::OpenscadParams`. Internal references inside these files (`Generator`, `Error`) resolve unchanged inside the module and must **not** be rewritten.

- [ ] **Step 4: Update every external reference**

```bash
grep -rl "\bBoxesClient\b\|\bOpenscadClient\b\|\bOpenscadParams\b" app lib test config \
  | xargs sed -i '' -E 's/(^|[^:[:alnum:]_:])(BoxesClient|OpenscadClient|OpenscadParams)\b/\1Tools::\2/g'
```

The `[^:[:alnum:]_:]` guard prevents double-prefixing an already-qualified `Tools::BoxesClient` on a re-run.

Then check for damage inside the moved files, where the sed would have wrongly qualified the class's own definition:

```bash
grep -n "Tools::" app/services/tools/*.rb
```

Expected: no `class Tools::BoxesClient` or similar. If the definition lines were rewritten, revert them to bare `class BoxesClient` — they are already inside `module Tools`.

- [ ] **Step 5: Verify Zeitwerk resolves the new constants**

Run: `bin/rails zeitwerk:check`

Expected: `All is good!`

- [ ] **Step 6: Run the full local gate**

Run: `bin/ci`

Expected: all seven gates pass, and the three test legs (`test`, `test-share`, `test-s3`) report **identical** counts.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "refactor(addons): namespace the three addon clients under Tools::

BoxesClient, OpenscadClient and OpenscadParams were top-level constants — the
only real collision risk once addons ship as a gem contributing to the same
Tools:: namespace. Pure rename; no behaviour change.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 2: The SDK version gate

An addon gem declares the SDK version it was written against; the host fails the **boot** if it is older. Loud beats a `NoMethodError` at the first user click — a green suite over something that never worked is this repo's dominant failure mode (§15).

**Files:**
- Create: `app/services/maker/addons.rb`
- Test: `test/services/maker/addons_test.rb`

- [ ] **Step 1: Write the failing test**

`test/services/maker/addons_test.rb`:

```ruby
require "test_helper"

module Maker
  class AddonsTest < ActiveSupport::TestCase
    test "SDK_VERSION parses as a semantic version" do
      assert_nothing_raised { Gem::Version.new(Maker::Addons::SDK_VERSION) }
    end

    test "require_sdk! returns true for a requirement the host satisfies" do
      assert Maker::Addons.require_sdk!("~> #{Maker::Addons::SDK_VERSION}")
    end

    test "require_sdk! raises when the host is older than the addon needs" do
      next_major = Gem::Version.new(Maker::Addons::SDK_VERSION).segments.first + 1
      error = assert_raises(Maker::Addons::IncompatibleSDK) do
        Maker::Addons.require_sdk!("~> #{next_major}.0")
      end
      assert_match(/host provides #{Regexp.escape(Maker::Addons::SDK_VERSION)}/, error.message)
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/services/maker/addons_test.rb`

Expected: 3 errors, `NameError: uninitialized constant Maker::Addons::SDK_VERSION`

- [ ] **Step 3: Write the implementation**

`app/services/maker/addons.rb`:

```ruby
module Maker
  # The addon SDK's version gate. `Maker::Addons` was until now an implicit namespace created by the
  # files beneath it; it is explicit here because an addon gem needs something to ask a question of.
  #
  # An addon calls `require_sdk!` from its engine at BOOT. That timing is the point: the alternative
  # is a NoMethodError the first time a user clicks the addon, on a deployment whose suite was green
  # — the exact shape §15 exists to prevent.
  module Addons
    # The six surfaces this version covers are enumerated in
    # docs/superpowers/specs/2026-08-02-tools-addons-separate-repo-design.md §3.
    # MINOR when adding a surface; MAJOR when changing or removing one.
    SDK_VERSION = "1.0.0".freeze

    class IncompatibleSDK < StandardError; end

    module_function

    # `requirement` is any Gem::Requirement string, e.g. "~> 1.0".
    def require_sdk!(requirement)
      return true if Gem::Requirement.new(requirement).satisfied_by?(Gem::Version.new(SDK_VERSION))

      raise IncompatibleSDK,
            "addon requires Maker::Addons SDK #{requirement}, host provides #{SDK_VERSION}"
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/services/maker/addons_test.rb`

Expected: `3 runs, 4 assertions, 0 failures, 0 errors, 0 skips`

- [ ] **Step 5: Mutation-check the gate (§15)**

Temporarily change `require_sdk!`'s body to `return true` unconditionally. Run the test again.

Expected: the third test FAILS with `Maker::Addons::IncompatibleSDK expected but nothing was raised`. Restore the real body and confirm green. A guard that has never failed has not been shown to work.

- [ ] **Step 6: Commit**

```bash
git add app/services/maker/addons.rb test/services/maker/addons_test.rb
git commit -m "feat(addons): SDK_VERSION + require_sdk! boot-time compatibility gate

An addon gem declares the SDK version it was built against; the host raises at
boot if it is older, rather than NoMethodError-ing at the first user click.
Mutation-checked.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 3: `Registry.register` replaces the frozen hash

**Files:**
- Modify: `app/services/maker/addons/registry.rb`
- Create: `config/initializers/addons.rb`
- Test: `test/services/maker/addons/registry_test.rb`

- [ ] **Step 1: Write the failing test**

`test/services/maker/addons/registry_test.rb`:

```ruby
require "test_helper"

module Maker
  module Addons
    class RegistryTest < ActiveSupport::TestCase
      # The registry is process-global and populated at to_prepare. Snapshot and restore it so these
      # tests can register throwaway addons without leaking into the rest of the suite.
      setup { @snapshot = Registry.entries.values.map(&:to_h) }

      teardown do
        Registry.reset!
        @snapshot.each { |attrs| Registry.register(**attrs) }
      end

      test "every registered addon's path resolves with no arguments" do
        # REGRESSION GUARD, GENERALIZED. The gallery renders link_to addon.path_for(self) for every
        # available addon, so a path proc needing an id 500s /tools for every user. This was guarded
        # for OpenSCAD alone, as a naming-convention accident; it now covers ANY addon — including
        # ones living in gems this repo has never seen.
        helpers = Rails.application.routes.url_helpers
        assert Registry.all.any?, "no addons registered — this guard would assert nothing"
        Registry.all.each do |addon|
          path = addon.path_for(helpers)
          assert path.to_s.start_with?("/"), "#{addon.key}: path_for returned #{path.inspect}"
        end
      end

      test "the three host addons are registered at boot" do
        assert_equal %w[boxes generators openscad], Registry.all.map(&:key).sort
      end

      test "register overwrites by key, so a dev reload does not duplicate" do
        2.times do
          Registry.register(key: "dup", title: "Dup", icon: "x", description: "d",
                            available: -> { true }, path: ->(_r) { "/dup" })
        end
        assert_equal 1, Registry.all.count { |a| a.key == "dup" }
      end

      test "all is ordered by title, not by registration order" do
        Registry.reset!
        Registry.register(key: "z", title: "Zebra", icon: "z", description: "",
                          available: -> { true }, path: ->(_r) { "/z" })
        Registry.register(key: "a", title: "Aardvark", icon: "a", description: "",
                          available: -> { true }, path: ->(_r) { "/a" })
        assert_equal %w[Aardvark Zebra], Registry.all.map(&:title)
      end

      test "find accepts a string or a symbol" do
        assert_equal "boxes", Registry.find(:boxes).key
        assert_equal "boxes", Registry.find("boxes").key
      end

      test "available? is evaluated lazily, not at registration" do
        calls = 0
        Registry.register(key: "lazy", title: "Lazy", icon: "l", description: "",
                          available: -> { calls += 1; true }, path: ->(_r) { "/lazy" })
        assert_equal 0, calls, "registration must not evaluate availability"
        Registry.find("lazy").available?
        assert_equal 1, calls
      end
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/services/maker/addons/registry_test.rb`

Expected: errors — `NoMethodError: undefined method 'entries' for module Maker::Addons::Registry`

- [ ] **Step 3: Rewrite the registry**

`app/services/maker/addons/registry.rb` — replace the whole file:

```ruby
module Maker
  module Addons
    # ext-registry pattern (mirrors Maker::Previews::Registry), but addons REGISTER themselves rather
    # than being listed in a frozen hash here — that is what lets an addon ship as a gem without
    # editing this repo. The host's own three register in config/initializers/addons.rb.
    #
    # `path` is a PROC over url_helpers, not a naming convention, and that is load-bearing. The
    # gallery used to call send("tools_#{key}_path"), which is the entire reason for the two
    # inflector traps documented in config/routes.rb: an addon whose key does not inflect to a
    # working zero-argument helper took /tools down for every user. An addon that names its own path
    # cannot make that mistake. The traps remain real for whoever WRITES an addon's routes; what
    # changed is that the gallery no longer depends on the naming.
    #
    # `available` stays a lambda so an addon whose backing service is unconfigured greys out instead
    # of 500ing — it must not be evaluated at registration time, when ENV may not be settled.
    Addon = Data.define(:key, :title, :icon, :description, :available, :path) do
      def available? = available.call
      def path_for(url_helpers) = path.call(url_helpers)
    end

    module Registry
      module_function

      def register(key:, title:, icon:, description:, available:, path:)
        addon = Addon.new(key: key.to_s, title:, icon:, description:, available:, path:)
        entries[addon.key] = addon
      end

      # Sorted by TITLE, never by registration order: once gems register from their own engines, load
      # order is an implementation detail the gallery must not expose to the user.
      def all = entries.values.sort_by(&:title)

      def find(key) = entries[key.to_s]

      # Test support. `to_prepare` re-registers on every dev reload, which is why `register`
      # overwrites by key; this exists so a test can assert against a registry it controls.
      def reset! = @entries = nil

      def entries = @entries ||= {}
    end
  end
end
```

- [ ] **Step 4: Register the host's three addons**

`config/initializers/addons.rb`:

```ruby
# The host's own three addons register here. Inside `to_prepare`, NOT at initializer top level: app
# constants are not autoloadable while initializers run — §14a records the share boot guard raising
# `uninitialized constant Library` for exactly this and taking the boot down while every test stayed
# green (the test env skipped it). `to_prepare` runs after autoloading is set up, and again on each
# dev reload, which is why Registry#register overwrites by key rather than appending.
#
# An addon GEM does not appear here; it registers from its own engine. This file is the host's
# three only.
Rails.application.config.to_prepare do
  Maker::Addons::Registry.register(
    key: "boxes", title: "Box Generator", icon: "📦",
    description: "Parametric laser-cut / CNC boxes",
    available: -> { Tools::BoxesClient.configured? },
    path: ->(r) { r.tools_boxes_path }
  )

  Maker::Addons::Registry.register(
    key: "generators", title: "Generators", icon: "✏️",
    description: "Parametric 2D drawings → SVG (laser & CNC)",
    available: -> { true }, # client-only (Maker.js in the browser); always available
    path: ->(r) { r.tools_generators_path }
  )

  Maker::Addons::Registry.register(
    key: "openscad", title: "OpenSCAD", icon: "🧊",
    description: "Parametric .scad + params → 3MF",
    available: -> { Tools::OpenscadClient.configured? },
    path: ->(r) { r.tools_openscad_path }
  )
end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bin/rails test test/services/maker/addons/registry_test.rb`

Expected: `6 runs, 0 failures, 0 errors, 0 skips`

- [ ] **Step 6: Mutation-check the path guard (§15)**

In `config/initializers/addons.rb`, temporarily change the OpenSCAD registration's path to the member helper, which requires an id:

```ruby
    path: ->(r) { r.tools_openscad_design_path }
```

Run: `bin/rails test test/services/maker/addons/registry_test.rb`

Expected: **RED** — `ActionController::UrlGenerationError: No route matches {...} missing required keys: [:id]`. This is the exact failure the old OpenSCAD-only guard existed to catch, now caught generically. Restore `r.tools_openscad_path` and confirm green.

- [ ] **Step 7: Mutation-check the lazy-availability guard (§15)**

Temporarily change `Addon#available?` to evaluate at construction — in `register`, replace `available:` with `available: -> { available.call }` after calling it once:

```ruby
        resolved = available.call
        addon = Addon.new(key: key.to_s, title:, icon:, description:, available: -> { resolved }, path:)
```

Run the registry test. Expected: **RED** on "available? is evaluated lazily". Restore and confirm green.

- [ ] **Step 8: Commit**

```bash
git add app/services/maker/addons/registry.rb config/initializers/addons.rb \
        test/services/maker/addons/registry_test.rb
git commit -m "feat(addons): Registry.register replaces the frozen hash

An addon registers itself with its own path proc instead of being listed here,
so a gem can ship an addon without editing this repo. all is sorted by title so
gem load order is never user-visible. The generalized path-resolves guard
replaces the OpenSCAD-only inflector guard. Mutation-checked twice.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 4: The gallery uses `path_for`

**Files:**
- Modify: `app/views/tools/home/index.html.erb:7`
- Test: `test/controllers/tools/home_controller_test.rb`

- [ ] **Step 1: Write the failing test**

A note on why the driver test looks the way it does. The obvious test — "every registered addon
renders a link" — would **pass before the change**: the view's `send("tools_#{addon.key}_path")` is
sent to the view context, which does respond, and for all three host addons it produces exactly the
href `path_for` produces. It would drive nothing. The test below registers an addon whose key
**cannot** inflect to a helper, which is precisely the case `path:` exists to serve, and it is
therefore red before and green after.

Add the snapshot guard and both tests to `test/controllers/tools/home_controller_test.rb`, inside
the class:

```ruby
    # The registry is process-global. Snapshot it so a test can register a throwaway addon without
    # leaking into the rest of the suite.
    setup { @snapshot = Maker::Addons::Registry.entries.values.map(&:to_h) }

    teardown do
      Maker::Addons::Registry.reset!
      @snapshot.each { |attrs| Maker::Addons::Registry.register(**attrs) }
    end

    test "renders a link for an addon whose key does not inflect to a route helper" do
      # THE DRIVER. `send("tools_#{key}_path")` raises NoMethodError for this key, taking /tools down
      # for every user — which is exactly the class of failure the two inflector traps in
      # config/routes.rb describe. An addon that declares its own path cannot cause it.
      Maker::Addons::Registry.register(
        key: "weird.key", title: "Weird", icon: "?", description: "",
        available: -> { true }, path: ->(_r) { "/tools/weird" }
      )

      get tools_path
      assert_response :success
      assert_select "a.addon-card[href=?]", "/tools/weird"
    end

    test "renders a working link for every available addon" do
      # Characterization, not a driver: asserts the RENDERED href against each addon's own declared
      # path, so a registration whose path proc drifts from its routes fails here rather than 500ing
      # for a user.
      get tools_path
      assert_response :success
      helpers = Rails.application.routes.url_helpers
      Maker::Addons::Registry.all.select(&:available?).each do |addon|
        assert_select "a.addon-card[href=?]", addon.path_for(helpers),
                      "no gallery link for #{addon.key}"
      end
    end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/controllers/tools/home_controller_test.rb`

Expected: the `weird.key` test is **RED** with
`NoMethodError: undefined method 'tools_weird.key_path'` raised from
`app/views/tools/home/index.html.erb`. The other tests pass. If the `weird.key` test passes, the
view was already changed — back it out and re-run, because an unfalsified guard proves nothing
(§15).

- [ ] **Step 3: Update the view**

In `app/views/tools/home/index.html.erb`, replace:

```erb
      <%= link_to send("tools_#{addon.key}_path"), class: "addon-card" do %>
```

with:

```erb
      <%= link_to addon.path_for(self), class: "addon-card" do %>
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/controllers/tools/home_controller_test.rb`

Expected: all tests pass.

- [ ] **Step 5: Correct the two stale comments**

Both assert a mechanism that no longer exists. A comment that describes removed machinery is worse than none — it sends the next reader to "fix" working code (§15, and the retracted `never reach into Sync::` line in §14d).

In `config/routes.rb`, in the OpenSCAD comment block, replace the trap-1 paragraph:

```ruby
  # 1. NOT `resources :openscad`. Rails derives the collection helper from name.pluralize
  #    ("openscads") and the member helper from name.singularize ("openscad"), so `resources` would
  #    leave tools_openscad_path meaning SHOW — which requires an id. The gallery renders each
  #    addon's OWN declared `path:` proc (Maker::Addons::Registry), and this addon's names
  #    tools_openscad_path, so `resources` here would make /tools raise UrlGenerationError for
  #    every user. Guarded generically by test/services/maker/addons/registry_test.rb — "every
  #    registered addon's path resolves with no arguments".
```

In `test/controllers/tools/openscad_controller_test.rb`, replace the guard comment body:

```ruby
      # REGRESSION GUARD: `resources :openscad` would make tools_openscad_path the SHOW helper, which
      # needs an id — and this addon registers that helper as its `path:` proc, so /tools itself would
      # 500 for every user. The generic version of this guard, covering every registered addon
      # including gem-supplied ones, is in test/services/maker/addons/registry_test.rb.
```

- [ ] **Step 6: Run the full local gate**

Run: `bin/ci`

Expected: all seven gates pass; the three test legs report identical counts.

- [ ] **Step 7: Commit**

```bash
git add app/views/tools/home/index.html.erb \
        test/controllers/tools/home_controller_test.rb \
        config/routes.rb test/controllers/tools/openscad_controller_test.rb
git commit -m "feat(addons): gallery renders each addon's own declared path

Replaces send(\"tools_#{key}_path\"), which was the sole reason the gallery
depended on route-helper inflection. Corrects the two comments that still
described that mechanism.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 5: Docs

**Files:**
- Modify: `CLAUDE.md` §14c
- Modify: `docs/STATUS.md`

- [ ] **Step 1: Update the `Registry` invariant in CLAUDE.md §14c**

Replace the bullet reading **"`Registry` declares each addon with its own `available:` lambda, so an addon whose backing service is unconfigured greys out rather than 500ing."** with:

```markdown
- **`Registry` is a REGISTRATION API, not a list** — an addon calls
  `Maker::Addons::Registry.register` (the host's three from `config/initializers/addons.rb`, inside
  **`to_prepare`** because app constants are not autoloadable while initializers run — §14a). Two
  things there are load-bearing: `available:` stays a **lambda**, so an addon whose backing service
  is unconfigured greys out rather than 500ing; and `path:` is a **proc the addon declares**, not a
  `send("tools_#{key}_path")` naming convention. That convention was the sole reason the two
  inflector traps in `config/routes.rb` could take **/tools down for every user** — the guard is now
  generic ("every registered addon's path resolves with no arguments",
  `test/services/maker/addons/registry_test.rb`) and covers addons in gems this repo has never seen.
  `Registry.all` sorts by **title**, so gem load order is never user-visible.
- **`Maker::Addons::SDK_VERSION` + `require_sdk!` fail the BOOT**, not the first click, when an addon
  gem needs a newer host. The six SDK surfaces are enumerated in
  `docs/superpowers/specs/2026-08-02-tools-addons-separate-repo-design.md` §3.
```

- [ ] **Step 2: Narrate the arc in docs/STATUS.md**

Add an entry under the current in-progress section:

```markdown
### Addon SDK — host-side prep (2026-08-02, branch `claude/tools-addons-separate-repo-d44dc8`)

Step 1 of the `maker-addons` extraction (spec:
`docs/superpowers/specs/2026-08-02-tools-addons-separate-repo-design.md`). All in the host; no new
repo yet.

- `BoxesClient` / `OpenscadClient` / `OpenscadParams` → `Tools::` (19 files, pure rename) — they were
  the only top-level constants a gem contributing to `Tools::` could collide with.
- `Maker::Addons::Registry` frozen hash → `register(...)`; the host's three register from
  `config/initializers/addons.rb` in `to_prepare`. `all` sorts by title.
- Each addon declares its own `path:` proc; the gallery no longer calls
  `send("tools_#{key}_path")`. The OpenSCAD-only inflector guard is replaced by a generic one over
  every registered addon.
- `SDK_VERSION` + `require_sdk!` — a boot-time gate for gem/host skew.
- Asset spike (Task 0 of the plan): **<GO | PARTIAL | NO-GO — record the actual outcome and what it
  means for steps 2–5>**.

Still ahead: steps 2–5 (create the repo, move `generators`, `openscad`, `boxes`, then the sidecars
+ their Kamal deploy + the three-way guard split). Those get their own plan.
```

- [ ] **Step 3: Run the full local gate**

Run: `bin/ci`

Expected: all seven gates pass. `test/ci_hygiene_test.rb` and `test/architecture_invariants_test.rb` are both live and will object if a documented invariant drifted.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md docs/STATUS.md
git commit -m "docs: record the addon SDK's registration API and version gate

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Done when

- [ ] `bin/ci` green, three test legs reporting identical counts
- [ ] Task 0's outcome reported to the user and recorded in `docs/STATUS.md`
- [ ] Every new guard mutation-checked: SDK gate (Task 2 step 5), path resolution (Task 3 step 6), lazy availability (Task 3 step 7)
- [ ] No spike artefacts remain — `git status --short` clean, `$SCRATCH/spike-engine` removed, `Gemfile` unmodified
- [ ] Adding a *host* addon now touches `config/initializers/addons.rb` + its controller/routes; adding a *gem* addon touches nothing in this repo

Then per CLAUDE.md's close-out rule: on a `claude/*` branch with green gates, commit, push and open the PR without asking. Merging still needs an explicit go-ahead.
