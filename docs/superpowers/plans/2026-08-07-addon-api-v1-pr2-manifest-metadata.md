# Addon API v1 — PR 2: manifest metadata Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Teach the manifest to describe itself — version, authorship, licence, the host level it needs, the permissions it asks for, and who may share its saved states — and make two of those declarations behave: a too-new addon greys out with a reason instead of failing at runtime, and `states_key` stops being an unconstrained claim on another addon's data.

**Architecture:** All new keys are optional and degrade rather than raise, per the Registry's existing rule that one bad addon must never take `/tools` down. `min_host` turns `Addon#available?` — hardcoded `true` since the frozen-hash design — into a real answer backed by `unavailable_reason`, which the gallery already has a branch for. The `states_key` constraint needs the whole manifest index rather than one manifest, so the check moves to `Registry.all`. A new `Maker::Addons::Permissions` module owns the permission vocabulary so the display never becomes a second copy of it.

**Tech Stack:** Rails 8, Minitest. No JavaScript changes at all — this PR is server-side and view-side only.

**Spec:** `docs/superpowers/specs/2026-08-07-addon-api-v1-design.md` §4 and §4.1; §12 row 2. Closes `docs/AUDIT-2026-08-03.md` §2.1.

**Branch:** `claude/addon-api-pr2-manifest-metadata`, stacked on `claude/todo-list-review-6beccc` (PR #161). PR 2 needs `Maker::Addons::Host`, which exists only on that branch — so open the PR with `--base claude/todo-list-review-6beccc`, not against `main`.

---

## Scope, stated before the tasks

**In:** the seven metadata keys, the `min_host` gate, the `states_key` mutual constraint, and permission DISPLAY.

**Out, deliberately:** permission ENFORCEMENT. Spec §12 row 2 says display, and the vocabulary is not finished — `data:read:<addon>/<collection>` does not exist until PR 4, and `service:<name>` has to reconcile with today's `services` key, which the spec says it eventually subsumes. Enforcing a half-built vocabulary would mean churning every manifest twice. **This must be said out loud in the documentation**, or a reader meets a permission list on a gallery card and reasonably assumes it is a gate. Task 6 owns saying it.

**Also out:** `collections` (PR 4), `service_timeouts` and `integrity` (PR 6), `contributes` (PR 5). Each lands with the consumer that gives it meaning. A key parsed into an `Addon` field that nothing reads is dead code, and the "not yet accepted" section of `docs/addon-api-v1.md` exists precisely so an author is not misled about which of these the host reads today.

---

## File Structure

| File | Responsibility |
|---|---|
| `app/services/maker/addons/permissions.rb` **(create)** | The permission vocabulary: the known names and their human labels, in one place. |
| `app/services/maker/addons/registry.rb` **(modify)** | Parse the new keys onto `Addon`; `available?`/`unavailable_reason`; the `states_key` constraint in `.all`. |
| `app/views/tools/home/index.html.erb` **(modify)** | Render the real unavailable reason and the permission list on each card. |
| `app/views/tools/addons/show.html.erb` **(modify)** | Render the permission list and version/author line on the addon page. |
| `test/services/maker/addons/permissions_test.rb` **(create)** | The vocabulary's fallback behaviour. |
| `test/services/maker/addons/registry_test.rb` **(modify)** | Parsing, degradation, the `min_host` gate, the `states_key` constraint. |
| `test/controllers/tools/home_controller_test.rb` **(modify)** | The gallery renders reason and permissions. |
| `docs/addon-api-v1.md`, `CLAUDE.md`, `docs/STATUS.md`, the spec **(modify)** | Close-out, in this branch (§15). |

---

### Task 1: The permission vocabulary

**Files:**
- Create: `app/services/maker/addons/permissions.rb`
- Test: `test/services/maker/addons/permissions_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/services/maker/addons/permissions_test.rb`:

```ruby
require "test_helper"

module Maker
  module Addons
    # The permission vocabulary has ONE definition, for the same reason the capability map does
    # (CLAUDE.md §14d, "ONE file-type vocabulary"): a label table copied into a view drifts, and the
    # drift is invisible because both copies still render something.
    class PermissionsTest < ActiveSupport::TestCase
      test "a known permission gets a human label" do
        assert_equal "Write files to your library", Permissions.label_for("library:write")
      end

      # THE FALLBACK IS THE POINT. Manifests come from a source this process does not control, and a
      # newer addon may declare a permission this host has never heard of. Rendering blank would
      # make the card silently understate what the addon asked for — worse than showing a raw name.
      test "an unknown permission falls back to its own name rather than rendering blank" do
        assert_equal "data:read:machine-library/machines",
                     Permissions.label_for("data:read:machine-library/machines")
      end

      test "a parameterised service permission is labelled with the service it names" do
        assert_equal "Call the boxes service", Permissions.label_for("service:boxes")
      end

      test "every known name has a non-blank label" do
        Permissions::LABELS.each do |name, label|
          assert label.present?, "#{name} has a blank label"
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/services/maker/addons/permissions_test.rb`
Expected: FAIL — `NameError: uninitialized constant Maker::Addons::Permissions`

- [ ] **Step 3: Write the implementation**

Create `app/services/maker/addons/permissions.rb`:

```ruby
module Maker
  module Addons
    # WHAT AN ADDON ASKS FOR, AS A VOCABULARY WITH ONE DEFINITION. Distinct from
    # Maker::Addons::Host::CAPABILITIES, and the distinction is worth holding: a CAPABILITY is what
    # this host can do, a PERMISSION is what an addon declares it wants. They share some names
    # (`library:write`) and will diverge (`data:read:<addon>/<collection>` names another addon).
    #
    # DECLARED AND DISPLAYED, NOT ENFORCED — see docs/addon-api-v1.md. Nothing here gates a request.
    # Saying so in the code is the point: a permission list rendered on a gallery card looks exactly
    # like a boundary, and this one is an author's statement of intent that the operator can read at
    # publish time.
    module Permissions
      module_function

      LABELS = {
        "library:read"  => "Read files from your library",
        "library:write" => "Write files to your library",
        "state"         => "Save and reload its own settings",
        "project:read"  => "See which project you are working in"
      }.freeze

      # `service:<name>` and `data:read:<addon>/<collection>` are PARAMETERISED — the name carries a
      # value, so they cannot be table entries. Handled by pattern, and anything still unmatched
      # falls through to its own raw name.
      SERVICE_PREFIX = "service:".freeze

      def label_for(name)
        name = name.to_s
        return LABELS[name] if LABELS.key?(name)
        return "Call the #{name.delete_prefix(SERVICE_PREFIX)} service" if name.start_with?(SERVICE_PREFIX)

        # A permission this host has never heard of: show the author's own spelling rather than
        # nothing, so the card cannot understate what was asked for.
        name
      end
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/services/maker/addons/permissions_test.rb`
Expected: PASS — 4 runs, 0 failures

- [ ] **Step 5: Mutation-check the fallback**

Temporarily change `label_for`'s final line from `name` to `""`.
Run: `bin/rails test test/services/maker/addons/permissions_test.rb`
Expected: FAIL on "an unknown permission falls back to its own name rather than rendering blank".
**Restore and re-run — expected PASS.**

- [ ] **Step 6: Commit**

```bash
git add app/services/maker/addons/permissions.rb test/services/maker/addons/permissions_test.rb
git commit -m "feat(addons): give the permission vocabulary one definition"
```

---

### Task 2: Registry parses the metadata keys

**Files:**
- Modify: `app/services/maker/addons/registry.rb`
- Test: `test/services/maker/addons/registry_test.rb`

- [ ] **Step 1: Write the failing tests**

> **A trap to avoid while writing these, which cost this plan a revision.** `Registry.manifests`
> caches the whole index under `CACHE_KEY`, and `registry_test.rb`'s `setup` installs a real
> `MemoryStore` so that caching is observable. So **one test may not stub the source twice**: the
> first `Registry.find` populates the cache, and a second stub is then invisible — the test passes
> or fails against the FIRST manifest either way. Give each stub its own test (setup hands every
> test a fresh store), or bust `Registry::CACHE_KEY` explicitly between them. Every test below
> follows the first rule.

Add to `test/services/maker/addons/registry_test.rb`, inside the `RegistryTest` class:

```ruby
      # The metadata keys are all OPTIONAL and all degrade. A manifest is fetched from a source this
      # process does not control, so a malformed value must never take /tools down — the same rule
      # `layout` already follows.
      test "the metadata keys carry onto the Addon when the manifest declares them" do
        Source.stub = FakeAddonSource.new(manifests: [ MANIFEST.merge(
          "version" => "2.1.0", "author" => "Chaim", "license" => "MIT",
          "homepage" => "https://example.com/gen"
        ) ])
        addon = Registry.find("generators")
        assert_equal "2.1.0", addon.version
        assert_equal "Chaim", addon.author
        assert_equal "MIT", addon.license
        assert_equal "https://example.com/gen", addon.homepage
      end

      test "the metadata keys default to nil when the manifest omits them" do
        addon = Registry.find("generators")
        assert_nil addon.version
        assert_nil addon.author
        assert_nil addon.license
        assert_nil addon.homepage
      end

      test "permissions carry onto the Addon as name/reasoning pairs" do
        Source.stub = FakeAddonSource.new(manifests: [ MANIFEST.merge(
          "permissions" => [
            { "name" => "library:write", "reasoning" => "to save your drawing" },
            { "name" => "service:boxes" }
          ]
        ) ])
        addon = Registry.find("generators")
        assert_equal 2, addon.permissions.size
        assert_equal "library:write", addon.permissions.first["name"]
        assert_equal "to save your drawing", addon.permissions.first["reasoning"]
        assert_nil addon.permissions.second["reasoning"]
      end

      # A MALFORMED ENTRY IS DROPPED, NOT RAISED ON, AND NOT RENDERED AS A BLANK ROW. A bare string
      # is the likeliest authoring mistake (the key reads like a list of names), so it is worth
      # naming: it is dropped rather than coerced, because coercing invents a `reasoning` the author
      # never wrote and the card would then vouch for it.
      test "permission entries that are not name-bearing hashes are dropped" do
        Source.stub = FakeAddonSource.new(manifests: [ MANIFEST.merge(
          "permissions" => [ { "name" => "state" }, "library:write", { "reasoning" => "no name" }, nil ]
        ) ])
        assert_equal [ "state" ], Registry.find("generators").permissions.map { |p| p["name"] }
      end

      test "permissions defaults to [] when the manifest omits it" do
        assert_equal [], Registry.find("generators").permissions
      end

      test "shares_states_with defaults to [] when the manifest omits it" do
        assert_equal [], Registry.find("generators").shares_states_with
      end

      test "a manifest's declared shares_states_with carries onto the Addon" do
        Source.stub = FakeAddonSource.new(manifests: [ MANIFEST.merge(
          "shares_states_with" => [ "boxes-next" ]
        ) ])
        assert_equal [ "boxes-next" ], Registry.find("generators").shares_states_with
      end

      test "min_host defaults to 0 when the manifest omits it" do
        assert_equal 0, Registry.find("generators").min_host
      end

      # NON-INTEGER min_host DEGRADES TO NO FLOOR, WHICH IS THE SAFER DIRECTION. A typo that made an
      # addon vanish from the gallery would read as "the deploy broke"; a typo that leaves it
      # available reads as "the floor did not apply", which is what actually happened. `"2".to_i` is
      # 2, so coercion would silently honour a value a JSON manifest should not contain.
      test "a non-integer min_host is ignored rather than coerced" do
        Source.stub = FakeAddonSource.new(manifests: [ MANIFEST.merge("min_host" => "2") ])
        assert_equal 0, Registry.find("generators").min_host
      end

      test "an integer min_host carries onto the Addon" do
        Source.stub = FakeAddonSource.new(manifests: [ MANIFEST.merge("min_host" => 2) ])
        assert_equal 2, Registry.find("generators").min_host
      end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/services/maker/addons/registry_test.rb`
Expected: FAIL — `NoMethodError: undefined method 'version' for an instance of Maker::Addons::Addon`

- [ ] **Step 3: Extend the Addon and the build**

In `app/services/maker/addons/registry.rb`, replace the `Addon = Data.define(...)` block with:

```ruby
    Addon = Data.define(:key, :title, :icon, :description, :entry, :pins, :services, :layout,
                        :states_key, :version, :author, :license, :homepage, :permissions,
                        :min_host, :shares_states_with) do
      # NO LONGER HARDCODED TRUE. It was, for as long as a registered addon was by definition
      # fetchable; `min_host` gives it a second, real answer — an addon can be perfectly fetchable
      # and still ask for a host this deployment does not have. The gallery already had the
      # unavailable branch waiting.
      def available? = unavailable_reason.nil?

      # A REASON, NOT A BOOLEAN, because the gallery previously hardcoded "Not configured on this
      # deployment" as the only explanation there could be. A too-new addon greying out under that
      # label would send an operator to check env vars that are fine.
      def unavailable_reason
        return unless min_host > Maker::Addons::Host::LEVEL

        "Needs a newer version of this host (asks for level #{min_host}, this host is level " \
          "#{Maker::Addons::Host::LEVEL})"
      end
    end
```

Then, in `Registry.build`, add these keyword arguments to the `Addon.new(...)` call, after `states_key:`:

```ruby
          # ALL OPTIONAL, ALL DEGRADING — the rule `layout` already follows. A manifest comes from a
          # source this process does not control.
          version: manifest["version"].presence&.to_s,
          author: manifest["author"].presence&.to_s,
          license: manifest["license"].presence&.to_s,
          homepage: manifest["homepage"].presence&.to_s,
          # Kept as an array of hashes rather than a richer object: the only consumers are a view and
          # an operator reading a card. An entry without a `name` is dropped rather than coerced —
          # coercion would invent a `reasoning` the author never wrote.
          permissions: Array(manifest["permissions"]).select { |p| p.is_a?(Hash) && p["name"].present? },
          # AN INTEGER OR NOTHING. `"2".to_i` is 2, which would silently honour a string a JSON
          # manifest should not contain; refusing it leaves the addon available, which is the
          # failure direction an operator can actually diagnose.
          min_host: manifest["min_host"].is_a?(Integer) ? manifest["min_host"] : 0,
          shares_states_with: Array(manifest["shares_states_with"]).map(&:to_s)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/rails test test/services/maker/addons/registry_test.rb`
Expected: PASS — the whole file, 0 failures

- [ ] **Step 5: Run the broader suites this touches**

Run: `bin/rails test test/services/maker/addons/ test/controllers/tools/`
Expected: PASS, 0 failures. `Addon` gained members; anything constructing one positionally would break here.

- [ ] **Step 6: Commit**

```bash
git add app/services/maker/addons/registry.rb test/services/maker/addons/registry_test.rb
git commit -m "feat(addons): parse the manifest metadata keys onto the Addon"
```

---

### Task 3: `min_host` greys an addon out with a reason

**Files:**
- Modify: `app/views/tools/home/index.html.erb`
- Test: `test/services/maker/addons/registry_test.rb`, `test/controllers/tools/home_controller_test.rb`

- [ ] **Step 1: Write the failing tests**

Add to `test/services/maker/addons/registry_test.rb`:

```ruby
      # THE ADDON IS STILL BUILT AND STILL LISTED. Skipping it would be the easy implementation and
      # the wrong one: an operator who published an addon needs to see WHY it is not usable, and an
      # addon that silently never appears reads as a broken deploy.
      test "an addon asking for a newer host is listed but unavailable, with a reason naming both levels" do
        Source.stub = FakeAddonSource.new(manifests: [
          MANIFEST.merge("min_host" => Maker::Addons::Host::LEVEL + 1)
        ])
        addon = Registry.find("generators")
        assert_not_nil addon, "the addon must still be listed"
        assert_not addon.available?
        assert_match(/level #{Maker::Addons::Host::LEVEL + 1}/, addon.unavailable_reason)
        assert_match(/level #{Maker::Addons::Host::LEVEL}/, addon.unavailable_reason)
      end

      test "an addon asking for exactly this host level is available" do
        Source.stub = FakeAddonSource.new(manifests: [
          MANIFEST.merge("min_host" => Maker::Addons::Host::LEVEL)
        ])
        assert Registry.find("generators").available?
      end
```

Add to `test/controllers/tools/home_controller_test.rb` (read the file first for its existing `setup` and how it stubs the source; reuse them):

```ruby
    # THE GALLERY SHOWS THE REASON, NOT A FIXED SENTENCE. Before this, the disabled card's tooltip
    # said "Not configured on this deployment" for every cause there could be — which for a
    # too-new addon points an operator at env vars that are perfectly fine.
    test "a too-new addon renders its own unavailable reason" do
      Maker::Addons::Source.stub = FakeAddonSource.new(manifests: [
        MANIFEST.merge("min_host" => Maker::Addons::Host::LEVEL + 1)
      ])
      get tools_path
      assert_response :success
      assert_select ".addon-card.disabled" do
        assert_select "[title=?]", /Needs a newer version of this host/
      end
    end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/services/maker/addons/registry_test.rb test/controllers/tools/home_controller_test.rb`
Expected: the Registry tests PASS already (Task 2 built `unavailable_reason`); the controller test FAILS, because the view still hardcodes the tooltip.

If the two Registry tests do not pass, stop — Task 2 is incomplete and this task is built on it.

- [ ] **Step 3: Render the real reason**

In `app/views/tools/home/index.html.erb`, replace the disabled-card `<div>` opening tag:

```erb
      <div class="addon-card disabled" title="<%= addon.unavailable_reason %>">
```

and replace the line reading `<span class="addon-desc muted">Unavailable here</span>` with:

```erb
        <span class="addon-desc muted"><%= addon.unavailable_reason %></span>
```

Leave the hardcoded OpenSCAD block at the bottom of that file alone — it is not manifest-driven and its own comment says it disappears when that addon migrates.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/rails test test/services/maker/addons/registry_test.rb test/controllers/tools/home_controller_test.rb`
Expected: PASS, 0 failures

- [ ] **Step 5: Mutation-check the gate**

Temporarily change `unavailable_reason`'s guard from `min_host > Maker::Addons::Host::LEVEL` to `min_host > 999`.
Run: `bin/rails test test/services/maker/addons/registry_test.rb test/controllers/tools/home_controller_test.rb`
Expected: FAIL on the "listed but unavailable" test and the gallery test.
**Restore and re-run — expected PASS.** Report the exact failure.

- [ ] **Step 6: Commit**

```bash
git add app/views/tools/home/index.html.erb test/services/maker/addons/registry_test.rb test/controllers/tools/home_controller_test.rb
git commit -m "feat(addons): grey out a too-new addon with a reason that names both levels"
```

---

### Task 4: The `states_key` mutual constraint — closes audit §2.1

**Files:**
- Modify: `app/services/maker/addons/registry.rb`
- Test: `test/services/maker/addons/registry_test.rb`

- [ ] **Step 1: Write the failing tests**

Add to `test/services/maker/addons/registry_test.rb`:

```ruby
      # AUDIT §2.1, CLOSED. `states_key` let a manifest declare itself the reader AND WRITER of
      # another addon's saved states — for every user, unconditionally, with nothing checking that
      # the other addon agreed or even existed. It was safe only because every manifest was
      # first-party. The constraint is MUTUAL: the claimant names the target, and the target must
      # name the claimant back.
      test "an addon claiming another's states_key is skipped unless that addon shares back" do
        Source.stub = FakeAddonSource.new(manifests: [
          MANIFEST,
          MANIFEST.merge("key" => "thief", "title" => "Thief", "states_key" => "generators")
        ])
        assert_nil Registry.find("thief"), "an unreciprocated states_key claim must not be registered"
        assert_not_nil Registry.find("generators"), "the target addon is unaffected"
      end

      test "a mutual declaration is honoured" do
        Source.stub = FakeAddonSource.new(manifests: [
          MANIFEST.merge("shares_states_with" => [ "boxes-next" ]),
          MANIFEST.merge("key" => "boxes-next", "title" => "Boxes Next", "states_key" => "generators")
        ])
        assert_equal "generators", Registry.find("boxes-next").states_key
      end

      # A CLAIM ON AN ADDON THAT IS NOT THERE IS STILL REFUSED. The target might appear later, or
      # might be a typo; either way nothing has agreed to the sharing, so the permissive reading
      # ("no target, no harm") would let a typo silently grant itself a private namespace and then
      # start colliding the day the real addon shipped.
      test "a states_key naming an addon that does not exist is refused" do
        Source.stub = FakeAddonSource.new(manifests: [
          MANIFEST.merge("key" => "orphan", "title" => "Orphan", "states_key" => "nobody")
        ])
        assert_nil Registry.find("orphan")
      end

      test "the ordinary case — states_key equal to the addon's own key — is untouched" do
        Source.stub = FakeAddonSource.new(manifests: [ MANIFEST.merge("states_key" => "generators") ])
        assert_equal "generators", Registry.find("generators").states_key
      end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/services/maker/addons/registry_test.rb -n "/states_key/"`
Expected: FAIL — "an unreciprocated states_key claim must not be registered" and the orphan test both fail, because today every claim is honoured.

- [ ] **Step 3: Move the check into `.all`**

In `app/services/maker/addons/registry.rb`, replace `def all` with:

```ruby
      # Sorted by [title, key]: sort_by is not stable, and source order must never be user-visible.
      #
      # THE states_key CHECK NEEDS THE WHOLE INDEX, WHICH IS WHY IT IS HERE AND NOT IN `build`.
      # `build` is handed one manifest and cannot see whether the addon being claimed agreed — the
      # question is about a PAIR of manifests, so it is asked where both are in scope.
      def all
        index = manifests
        index.filter_map { |m| build(m) }
             .select { |addon| states_key_permitted?(addon, index) }
             .sort_by { |a| [ a.title, a.key ] }
      end
```

Then add, below `build`:

```ruby
      # MUTUAL DECLARATION, OR NO SHARING. The claimant names the target in `states_key`; the target
      # must name the claimant in `shares_states_with`. Anything else is refused, INCLUDING a claim
      # on an addon that is not in the index at all — see the test for why the permissive reading is
      # the dangerous one.
      #
      # A refusal SKIPS the addon, exactly as an unsupported api_version does, rather than raising:
      # one bad manifest must never take /tools down. The consequence is worth stating because it is
      # silent — an addon that gets this wrong simply does not appear, and the operator's only clue
      # is the log line below.
      def states_key_permitted?(addon, index)
        return true if addon.states_key == addon.key

        target = index.find { |m| m.is_a?(Hash) && m["key"].to_s == addon.states_key }
        permitted = Array(target && target["shares_states_with"]).map(&:to_s).include?(addon.key)
        unless permitted
          Rails.logger.warn("addon #{addon.key.inspect} claims states_key #{addon.states_key.inspect} " \
                            "without a matching shares_states_with — skipping it")
        end
        permitted
      end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/rails test test/services/maker/addons/registry_test.rb`
Expected: PASS — the whole file, 0 failures

- [ ] **Step 5: Update the `states_key` comment in `build`**

The comment above `states_key:` in `Registry.build` currently says the trust widening has "NO HOST-SIDE CONSTRAINT" and that if the trust model widens "this line stops being safe and needs a real constraint … not a comment." That is now false. Rewrite that paragraph to say the constraint exists, name `states_key_permitted?` as where it lives, and keep the explanation of WHAT the key does. Do not delete the description of the sharing itself — a future reader still needs to know why one addon may read another's states at all.

- [ ] **Step 6: Mutation-check the constraint**

Temporarily change `states_key_permitted?`'s first line to `return true`.
Run: `bin/rails test test/services/maker/addons/registry_test.rb -n "/states_key/"`
Expected: FAIL on the unreciprocated-claim test and the orphan test.
**Restore and re-run — expected PASS.** Report the exact failure.

- [ ] **Step 7: Commit**

```bash
git add app/services/maker/addons/registry.rb test/services/maker/addons/registry_test.rb
git commit -m "feat(addons): require a mutual declaration for a shared states_key"
```

---

### Task 5: Permission display

**Files:**
- Modify: `app/views/tools/home/index.html.erb`, `app/views/tools/addons/show.html.erb`
- Test: `test/controllers/tools/home_controller_test.rb`, `test/controllers/tools/addons_controller_test.rb`

- [ ] **Step 1: Write the failing tests**

Add to `test/controllers/tools/home_controller_test.rb`:

```ruby
    # WHAT THE OPERATOR SEES AT PUBLISH TIME. The point of rendering these is scope drift: a
    # republished bundle that quietly starts asking for more shows up on the card, in a deployment
    # where publishing the bundle IS the deploy and Rails is never rebuilt.
    test "a card lists the permissions its manifest declares, by label" do
      Maker::Addons::Source.stub = FakeAddonSource.new(manifests: [
        MANIFEST.merge("permissions" => [ { "name" => "library:write" }, { "name" => "service:boxes" } ])
      ])
      get tools_path
      assert_response :success
      assert_select ".addon-permissions", text: /Write files to your library/
      assert_select ".addon-permissions", text: /Call the boxes service/
    end

    test "a card with no declared permissions renders no permission list at all" do
      get tools_path
      assert_response :success
      assert_select ".addon-permissions", count: 0
    end
```

Add to `test/controllers/tools/addons_controller_test.rb`:

```ruby
    # THE REASONING STRING IS SHOWN WHERE THERE IS ROOM FOR IT. A gallery card has space for a
    # label; the addon's own page has space for the author's justification, which is the part that
    # tells an operator whether the ask is proportionate.
    test "the addon page lists declared permissions with their reasoning" do
      Maker::Addons::Source.stub = FakeAddonSource.new(
        manifests: [ MANIFEST.merge(
          "permissions" => [ { "name" => "library:write", "reasoning" => "to save your box" } ]
        ) ],
        assets: { "#{FIXTURE_KEY}/generators.js" => "export default { mount() {} }" }
      )
      get tools_addon_path(FIXTURE_KEY)
      assert_response :success
      assert_select ".addon-permissions", text: /Write files to your library/
      assert_select ".addon-permissions", text: /to save your box/
    end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/controllers/tools/home_controller_test.rb test/controllers/tools/addons_controller_test.rb`
Expected: FAIL — no element matches `.addon-permissions`.

- [ ] **Step 3: Render them on the gallery card**

In `app/views/tools/home/index.html.erb`, inside the `link_to … class: "addon-card"` block, after the `addon-desc` span, add:

```erb
        <% if addon.permissions.any? %>
          <span class="addon-permissions muted">
            This tool can:
            <%= addon.permissions.map { |p| Maker::Addons::Permissions.label_for(p["name"]) }.to_sentence %>
          </span>
        <% end %>
```

- [ ] **Step 4: Render them on the addon page**

In `app/views/tools/addons/show.html.erb`, directly after the `page-head` div, add:

```erb
<% if @addon.permissions.any? %>
  <ul class="addon-permissions muted">
    <% @addon.permissions.each do |permission| %>
      <li>
        <%= Maker::Addons::Permissions.label_for(permission["name"]) %>
        <% if permission["reasoning"].present? %>— <%= permission["reasoning"] %><% end %>
      </li>
    <% end %>
  </ul>
<% end %>
```

**Watch the §14d ERB hazard while editing this file:** an ERB comment ends at its FIRST `%>`, so do not write `<%= … %>` or a bare `%>` inside the long `<%# … %>` comment that already sits below this insertion point. You are adding markup above it; do not disturb it.

- [ ] **Step 5: Run tests to verify they pass**

Run: `bin/rails test test/controllers/tools/home_controller_test.rb test/controllers/tools/addons_controller_test.rb`
Expected: PASS, 0 failures

- [ ] **Step 6: Verify the rendered output has no leaked ERB**

Run: `bin/rails test test/integration/web/template_hygiene_test.rb`
Expected: PASS. This is the guard for a comment that terminates early and prints its own prose into the page — the defect that shipped once in `files/_ext_filter.html.erb` and that no `assert_select` can see, because it produces a text node rather than an element.

- [ ] **Step 7: Commit**

```bash
git add app/views/tools/home/index.html.erb app/views/tools/addons/show.html.erb test/controllers/tools/home_controller_test.rb test/controllers/tools/addons_controller_test.rb
git commit -m "feat(addons): show what an addon asks for, on the card and on its page"
```

---

### Task 6: Close out — docs, invariants, gates, PR

**Files:**
- Modify: `docs/addon-api-v1.md`, `CLAUDE.md` (§14c), `docs/STATUS.md`, `docs/superpowers/specs/2026-08-07-addon-api-v1-design.md`

- [ ] **Step 1: Move the now-accepted keys in `docs/addon-api-v1.md` §2**

Seven keys move out of "Not yet accepted — coming in a later host level" and into the accepted table: `version`, `author`, `license`, `homepage`, `min_host`, `permissions`, `shares_states_with`. Four stay deferred: `collections`, `service_timeouts`, `integrity`, `contributes`.

Document for each accepted key what the host actually does with it, including the degradations an author can hit: a non-integer `min_host` is ignored rather than honoured; a permission entry that is not a hash with a `name` is dropped; an unreciprocated `states_key` makes the addon **disappear from the gallery entirely**, with only a log line to say why.

- [ ] **Step 2: State plainly that permissions are not enforced**

In the same section, and again in §4 (Capability discovery) where an author will look for the boundary: **a declared permission is displayed, not enforced.** Nothing on the server refuses a request because a manifest failed to declare something. Say why it is still worth declaring — the operator sees the ask at publish time, and enforcement arrives with the sandbox — and say what it is NOT, so a reader does not mistake the card for a gate.

- [ ] **Step 3: Add the invariants to `CLAUDE.md` §14c**

One line each, consequence named:

```markdown
- **A `states_key` POINTING AT ANOTHER ADDON REQUIRES A MUTUAL DECLARATION** — the claimant names
  the target, the target names the claimant back in `shares_states_with`, and anything else is
  SKIPPED (including a claim on an addon that is not in the index, because a typo would otherwise
  grant itself a private namespace and start colliding the day the real addon shipped). Closes the
  2026-08-03 audit's §2.1. The check lives in `Registry.all`, not `build`, because it is a question
  about a PAIR of manifests and `build` is handed one.
- **`Addon#available?` IS NO LONGER HARDCODED TRUE, AND THE GALLERY SHOWS A REASON RATHER THAN A
  FIXED SENTENCE.** A too-new addon (`min_host` above `Host::LEVEL`) is still BUILT and still
  LISTED — skipping it is the easy wrong answer, because an addon that silently never appears reads
  as a broken deploy rather than as a version floor.
- **A NON-INTEGER `min_host` IS IGNORED, NOT COERCED.** `"2".to_i` is 2, which would honour a value
  a JSON manifest should not contain. Ignoring it leaves the addon AVAILABLE — the failure
  direction an operator can diagnose, rather than one that makes an addon vanish.
- **DECLARED PERMISSIONS ARE DISPLAYED, NOT ENFORCED.** Nothing refuses a request over them. They
  exist so an operator sees scope drift at publish time in a deployment where republishing a bundle
  IS the deploy. Do not describe the card as a boundary, and do not add enforcement without the
  finished vocabulary — `data:read:<addon>/<collection>` does not exist until PR 4 and
  `service:<name>` must reconcile with today's `services` key.
- **THE PERMISSION VOCABULARY HAS ONE DEFINITION** (`Maker::Addons::Permissions`), and an unknown
  name falls back to its own raw spelling rather than rendering blank — a card that silently
  understates what an addon asked for is worse than one showing a developer-facing string.
```

- [ ] **Step 4: Write the STATUS entry and amend the spec**

Add a `## Latest (…)` entry to `docs/STATUS.md` covering what shipped, demoting the previous Latest to a plain dated heading. Cover the audit §2.1 closure, the `available?` change and why the addon is listed rather than skipped, the display-not-enforcement scope decision and its reason, and the measured suite counts from Step 5.

In `docs/superpowers/specs/2026-08-07-addon-api-v1-design.md` §12, mark row 2 shipped, and note that permission enforcement was scoped OUT of it and why.

- [ ] **Step 5: Run the gates**

```bash
bin/ci; echo "exit=$?"
```

Judge by the EXIT CODE, not by reading output. All seven gates; the three test legs must report **identical** counts. Record the numbers for the STATUS entry.

- [ ] **Step 6: Commit, push, open the PR against PR 1's branch**

```bash
git add CLAUDE.md docs/STATUS.md docs/addon-api-v1.md docs/superpowers/specs/2026-08-07-addon-api-v1-design.md
git commit -m "docs: record the manifest-metadata arc and its invariants"
git push -u origin HEAD
gh pr create --base claude/todo-list-review-6beccc --title "..." --body "..."
```

**`--base` is load-bearing.** This branch is stacked on PR #161; targeting `main` would show PR 1's commits in the diff and make the review meaningless.

State in the body what was verified and what was not — specifically that permissions are displayed and NOT enforced, and that no published manifest in the addons repo declares any of these keys yet, so nothing here is exercised against a real bundle.

---

## Self-review notes

**Spec coverage.** Spec §4's table: `version`/`author`/`license`/`homepage` → Task 2; `min_host` → Tasks 2–3; `permissions` → Tasks 1, 2, 5; `shares_states_with` → Tasks 2, 4. `collections`, `service_timeouts`, `contributes`, `integrity` are explicitly deferred with their consumers, and Task 6 Step 1 keeps `docs/addon-api-v1.md`'s deferred list honest about which. Spec §4.1 (`states_key`) → Task 4, including the "skipped like any other invalid manifest" rule.

**Naming consistency.** `unavailable_reason` is defined in Task 2 and consumed in Task 3's view and tests. `Permissions.label_for` is defined in Task 1 and consumed in Task 5's views. `states_key_permitted?` is defined and mutation-checked in Task 4 only.

**A known consequence, accepted:** `Registry.all` now calls `manifests` and iterates the raw index a second time inside `states_key_permitted?`. At the scale of a manifest index — a handful of entries, already cached for five minutes — that is not worth an index by key. If the addon list ever reaches a size where it is, the fix is a `key`-keyed hash built once in `all`, not a change to where the check lives.
