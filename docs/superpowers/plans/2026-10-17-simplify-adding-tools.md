# Simplify Adding a Tool — Implementation Plan

> **For agentic workers:** in THIS repo, execute with `.claude/commands/execute-plan.md` (CLAUDE.md
> §15) — it overrides the generic subagent-driven-development loop. Steps use checkbox (`- [ ]`)
> syntax for tracking.

**Goal:** Make adding a `/tools` addon three steps — `bin/new-addon`, edit, `bin/publish` — with a
skipped manifest explaining itself instead of vanishing.

**Architecture:** The host's `Maker::Addons::Registry` gains the one definition of *why* a manifest is
skipped (`problem_with`, `problems`). Three readers use it: a `bin/rails "addons:check[PATH]"` task
(via a small `Maker::Addons::Check` service that adds on-disk file checks), a notice on `/tools` in
local environments, and a production log line. In `chaim354/tinkerex-addons`, `bin/new-addon`
scaffolds a bundle and its manifest entry, and `bin/publish` chains check → secrets preflight →
build-push → accessory reboot → verify the running revision.

**Tech Stack:** Rails 8 / Minitest (host); Ruby + Bash scripts, nginx image, Kamal (addons repo).

**Spec:** `docs/superpowers/specs/2026-10-17-simplify-adding-tools-design.md`.

---

## File map

**PR 1 — `chaim354/tinkerex`, branch `claude/simplify-adding-tools`**

| File | Change | Responsibility |
|---|---|---|
| `app/services/maker/addons/registry.rb` | modify | `problem_with`, `problems`, `build` uses `problem_with`, `all` logs problems |
| `test/services/maker/addons/registry_test.rb` | modify | tests for the above |
| `app/services/maker/addons/check.rb` | create | `Maker::Addons::Check` — Registry.problems + on-disk file checks for a directory |
| `test/services/maker/addons/check_test.rb` | create | its tests |
| `lib/tasks/addons.rake` | create | `addons:check[PATH]` |
| `test/tasks/addons_tasks_test.rb` | create | exit status and output of the task |
| `app/controllers/tools/home_controller.rb` | modify | `@addon_problems` in local envs |
| `app/views/tools/home/index.html.erb` | modify | the notice |
| `test/controllers/tools/home_controller_test.rb` | modify | notice tests |
| `docs/addon-api-v1.md`, `docs/invariants/addons.md` | modify | where a skip reason now surfaces |

**PR 2 — `chaim354/tinkerex-addons`, branch `claude/new-addon-and-publish`** (after PR 1 is on the
sibling checkout — the scripts call its `addons:check`)

| File | Change | Responsibility |
|---|---|---|
| `bin/revision` | create | the ONE definition of the published revision (`<sha>` / `<sha>-dirty`) |
| `bin/build-push` | modify | uses `bin/revision` |
| `templates/addon.js` | create | the scaffold's bundle template (outside `addons/`, so never shipped) |
| `bin/new-addon` | create | scaffold |
| `test/new_addon_test.sh` | create | scaffold contract |
| `bin/publish` | create | the one-command publish |
| `README.md` | modify | lead with the two commands |

---

## Task 1: Registry — one definition of a skip reason

**Files:**
- Modify: `app/services/maker/addons/registry.rb` (`all` ~line 92, `build` ~line 125, `states_key_permitted?` ~line 258)
- Test: `test/services/maker/addons/registry_test.rb`

- [ ] **Step 1: Write the failing tests.** Append inside `class RegistryTest`, before its final `end`s:

```ruby
      # WHY A MANIFEST IS SKIPPED — the ONE definition that build, problems, addons:check and the
      # local /tools notice share. The reasons are asserted as TEXT because the text is the feature:
      # an author who reads "missing title" fixes it; one who reads nothing does not.
      test "problem_with is nil for a manifest that builds" do
        assert_nil Registry.problem_with(MANIFEST)
      end

      test "problem_with names a non-object entry" do
        assert_equal "not a JSON object", Registry.problem_with([ "generators" ])
      end

      test "problem_with names every missing required key, in REQUIRED order" do
        assert_equal "missing title, entry", Registry.problem_with(MANIFEST.except("entry", "title"))
      end

      test "problem_with treats a blank required value as missing, as build always has" do
        assert_equal "missing icon", Registry.problem_with(MANIFEST.merge("icon" => ""))
      end

      test "problem_with names both api versions" do
        assert_equal %(api_version "99" — this host speaks "1"),
                     Registry.problem_with(MANIFEST.merge("api_version" => "99"))
      end

      test "problems is empty for a clean index" do
        assert_equal [], Registry.problems
      end

      test "problems reports each skipped manifest by key, in index order" do
        Source.stub = FakeAddonSource.new(manifests: [
          MANIFEST.merge("key" => "a", "title" => "A", "api_version" => "99"),
          MANIFEST,
          MANIFEST.merge("key" => "b", "title" => "B").except("icon")
        ])
        assert_equal [ { key: "a", reason: %(api_version "99" — this host speaks "1") },
                       { key: "b", reason: "missing icon" } ], Registry.problems
      end

      test "problems names a keyless entry by its position, counting from 1" do
        Source.stub = FakeAddonSource.new(manifests: [ MANIFEST, MANIFEST.except("key"), "junk" ])
        assert_equal [ { key: "entry 2", reason: "missing key" },
                       { key: "entry 3", reason: "not a JSON object" } ], Registry.problems
      end

      test "problems reports an unreciprocated states_key claim, which all skips" do
        Source.stub = FakeAddonSource.new(manifests: [
          MANIFEST,
          MANIFEST.merge("key" => "thief", "title" => "Thief", "states_key" => "generators")
        ])
        assert_equal [ { key: "thief",
                         reason: %(claims states_key "generators", which does not name it back in shares_states_with) } ],
                     Registry.problems
      end

      # REPORTED, NOT SKIPPED. Registry.find serves whichever duplicate sorts first by [title, key];
      # changing what production serves is not this report's business.
      test "problems reports a duplicate key once, and both entries are still served" do
        Source.stub = FakeAddonSource.new(manifests: [
          MANIFEST, MANIFEST.merge("title" => "Generators Again")
        ])
        assert_equal [ { key: "generators",
                         reason: "duplicate key — 2 entries share it and only one is reachable" } ],
                     Registry.problems
        assert_equal 2, Registry.all.size
      end

      test "a skipped manifest sharing a served one's key is reported as skipped, not as a duplicate" do
        Source.stub = FakeAddonSource.new(manifests: [ MANIFEST, MANIFEST.merge("api_version" => "99") ])
        assert_equal [ { key: "generators", reason: %(api_version "99" — this host speaks "1") } ],
                     Registry.problems
      end

      test "problems answers [] when the source is unreachable, exactly as all does" do
        down = Object.new
        def down.cacheable? = false
        def down.manifests = raise(Source::Error, "down")
        Source.stub = down
        assert_equal [], Registry.problems
      end

      test "problems reads an index it is handed and never asks the source" do
        Source.stub = Object.new # answers nothing: any source call raises NoMethodError
        assert_equal [ { key: "x", reason: "missing title" } ],
                     Registry.problems([ MANIFEST.merge("key" => "x").except("title") ])
      end

      test "all logs each problem, so production still leaves the operator a clue" do
        Source.stub = FakeAddonSource.new(manifests: [ MANIFEST.except("icon") ])
        io = StringIO.new
        previous = Rails.logger
        Rails.logger = ActiveSupport::Logger.new(io)
        Registry.all
        assert_match(/addon "generators": missing icon/, io.string)
      ensure
        Rails.logger = previous
      end
```

- [ ] **Step 2: Run them and confirm they fail**

Run: `LIBRARY_PATH=$(mktemp -d) bin/rails test test/services/maker/addons/registry_test.rb`
Expected: the new tests ERROR with `NoMethodError: undefined method 'problem_with'` / `'problems'`; every pre-existing test still passes.

- [ ] **Step 3: Implement.** In `registry.rb`:

Replace `all` with:

```ruby
      def all
        index = manifests
        # ONE warn per problem, per call — the cadence the states_key warn always had (see
        # states_key_permitted?'s note). Before problems existed, a manifest `build` refused was
        # skipped with NO log line at all, so a typo'd manifest left an operator nothing to find.
        problems(index).each { |p| Rails.logger.warn("addon #{p[:key].inspect}: #{p[:reason]}") }
        index.filter_map { |m| build(m) }
             .select { |addon| states_key_permitted?(addon, index) }
             .sort_by { |a| [ a.title, a.key ] }
      end
```

Add, directly after `all` and `find`:

```ruby
      # WHY `build` WOULD REFUSE THIS MANIFEST, OR nil. The ONE definition of those refusals:
      # `build` asks it first, and `problems` — read by `addons:check` and the local /tools notice —
      # reports it, so an author learns why a tool never appeared instead of finding nothing.
      # Production behaviour is unchanged: a manifest with a problem is still SKIPPED, never raised
      # on (§14c — one bad addon must never take /tools down).
      def problem_with(manifest)
        return "not a JSON object" unless manifest.is_a?(Hash)

        missing = REQUIRED.reject { |k| manifest[k].present? }
        return "missing #{missing.join(', ')}" if missing.any?
        unless manifest["api_version"].to_s == API_VERSION
          return "api_version #{manifest['api_version'].to_s.inspect} — this host speaks #{API_VERSION.inspect}"
        end

        nil
      end

      # THE WHOLE-INDEX REPORT, `[{key:, reason:}]` in index order. Every manifest `build` refuses,
      # plus the two problems only a whole index can show:
      #
      #   - an unreciprocated states_key — `states_key_permitted?` DECIDES; this only reports it.
      #   - a DUPLICATE key among the addons `all` serves — REPORTED, NOT SKIPPED. `find` answers
      #     whichever sorts first by [title, key]; changing what production serves is not this
      #     method's business. A skipped manifest sharing a served one's key is reported as skipped,
      #     not as a duplicate, because only one of the two is actually reachable.
      #
      # A keyless entry is named by its position, counting from 1 ("entry 3"), so it can be found.
      # Handed no index, it reads `manifests` — so an unreachable source reports [] exactly as `all`
      # serves [].
      def problems(index = manifests)
        served = index.filter_map { |m| build(m) }.select { |addon| states_key_permitted?(addon, index) }
        counts = served.map(&:key).tally
        reported = Set.new

        index.each_with_index.filter_map do |manifest, position|
          reason = problem_with(manifest)
          if reason.nil?
            addon = build(manifest)
            if !states_key_permitted?(addon, index)
              reason = "claims states_key #{addon.states_key.inspect}, which does not name it back in shares_states_with"
            elsif counts[addon.key] > 1 && reported.add?(addon.key)
              reason = "duplicate key — #{counts[addon.key]} entries share it and only one is reachable"
            end
          end
          { key: problem_key(manifest, position), reason: } if reason
        end
      end

      def problem_key(manifest, position)
        manifest.is_a?(Hash) && manifest["key"].present? ? manifest["key"].to_s : "entry #{position + 1}"
      end
```

In `build`, replace its first three lines

```ruby
        return unless manifest.is_a?(Hash)
        return unless REQUIRED.all? { |k| manifest[k].present? }
        return unless manifest["api_version"].to_s == API_VERSION
```

with

```ruby
        return if problem_with(manifest)
```

In `states_key_permitted?`, delete the logging so it only decides (the warn now comes from `all` via
`problems`, and must not be written twice):

```ruby
      def states_key_permitted?(addon, index)
        return true if addon.states_key == addon.key

        target = index.find { |m| m.is_a?(Hash) && m["key"].to_s == addon.states_key }
        !!(target && build(target) && Array(target["shares_states_with"]).map(&:to_s).include?(addon.key))
      end
```

Then **rewrite the paragraph in its leading comment** that begins "A refusal SKIPS the addon, exactly
as an unsupported api_version does" so it says: the refusal is reported by `Registry.problems`
(read by `bin/rails addons:check` and the `/tools` notice in local environments) and logged by
`all` once per problem per call — still once per REQUEST, not once per deploy, because only
`manifests` is cached. Keep its "Measured: 5 calls, 5 lines" sentence (the cadence did not change)
and the "worth knowing before reading it as a loop" warning. Also update the module comment above
`Addon` if it still implies skipping is silent.

- [ ] **Step 4: Run the file and confirm it passes**

Run: `LIBRARY_PATH=$(mktemp -d) bin/rails test test/services/maker/addons/registry_test.rb`
Expected: all green, 0 failures, 0 errors.

- [ ] **Step 5: Mutation-check (CLAUDE.md §15) — report each actual output.** **Commit (Step 6)
  FIRST**, so every mutation below restores with `git checkout -- <file>`.
  1. In `build`, delete `return if problem_with(manifest)` → the two pre-existing tests "an addon declaring an unsupported api_version is skipped" and "a manifest missing a required key is skipped" must go RED.
  2. In `problems`, change `counts[addon.key] > 1` to `counts[addon.key] > 2` → the duplicate test goes RED.
  3. Remove `&& reported.add?(addon.key)` → the duplicate test goes RED (reported twice).
  4. In `all`, delete the `problems(index).each { … }` line → the log test goes RED.
  After each: `git checkout -- app/services/maker/addons/registry.rb`, then `rm -rf tmp/cache/bootsnap*` (bootsnap can mask an equal-length restore), and `git status --porcelain` shows only intended files.

- [ ] **Step 6: Commit** (before Step 5's mutations, per its note)

```bash
git add app/services/maker/addons/registry.rb test/services/maker/addons/registry_test.rb
git commit -F - <<'EOF'
Registry says why it skips a manifest: problem_with and problems

build asks problem_with first, so the refusal rules exist once; problems adds the
two whole-index problems (unreciprocated states_key, duplicate key — reported,
not skipped). all logs each problem once per call, replacing the states_key warn.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

## Task 2: `addons:check` — the pre-publish check, plus docs

Depends on Task 1 (`Registry.problems`, `Registry.build`).

**Files:**
- Create: `app/services/maker/addons/check.rb`, `test/services/maker/addons/check_test.rb`
- Create: `lib/tasks/addons.rake`, `test/tasks/addons_tasks_test.rb`
- Modify: `docs/addon-api-v1.md` (the manifest section, ~line 100–160), `docs/invariants/addons.md` (the "Addons are manifest-driven" bullet, ~line 54)

- [ ] **Step 1: Write the failing service test** — `test/services/maker/addons/check_test.rb`:

```ruby
require "test_helper"

module Maker
  module Addons
    # Maker::Addons::Check reads a REAL directory through Source::Local — the same reader dev uses —
    # so each test writes one. Never a fake source: the on-disk checks are the point.
    class CheckTest < ActiveSupport::TestCase
      MANIFEST = {
        "key" => "widget", "title" => "Widget", "icon" => "🛠️", "description" => "Makes widgets",
        "api_version" => "1", "entry" => "widget.js", "pins" => { "dep" => "dep.js" }
      }.freeze

      def with_addons(manifests, files: { "widget/widget.js" => "", "widget/dep.js" => "" })
        Dir.mktmpdir do |root|
          root = Pathname.new(root)
          root.join("manifests.json").write(JSON.generate(manifests))
          files.each do |rel, body|
            root.join(rel).dirname.mkpath
            root.join(rel).write(body)
          end
          yield root
        end
      end

      test "a clean directory is OK and counts its manifests" do
        with_addons([ MANIFEST ]) do |root|
          result = Check.run(root)
          assert result.ok?
          assert_equal 1, result.count
          assert_equal [], result.problems
        end
      end

      test "a manifest the registry would skip is reported with the registry's own reason" do
        with_addons([ MANIFEST.except("title") ]) do |root|
          assert_equal [ { key: "widget", reason: "missing title" } ], Check.run(root).problems
        end
      end

      test "a missing entry file is reported" do
        with_addons([ MANIFEST ], files: { "widget/dep.js" => "" }) do |root|
          assert_equal [ { key: "widget", reason: "entry: widget.js does not exist" } ], Check.run(root).problems
        end
      end

      test "a missing pinned file is reported, naming the specifier" do
        with_addons([ MANIFEST ], files: { "widget/widget.js" => "" }) do |root|
          assert_equal [ { key: "widget", reason: %(pin "dep": dep.js does not exist) } ], Check.run(root).problems
        end
      end

      test "a missing addon directory is reported once, not once per file" do
        with_addons([ MANIFEST ], files: {}) do |root|
          assert_equal [ { key: "widget", reason: "no widget/ directory beside manifests.json" } ],
                       Check.run(root).problems
        end
      end

      # REJECTED, NEVER RESOLVED (§14a's key_for rule, via Source.validate_asset_path!). The escape
      # target is PLANTED, so "refused" cannot be confused with "happened not to exist" — the
      # false-green shape docs/invariants/addons.md records for Source::Local's own test.
      test "a traversing entry is reported as unsafe, even when the target exists" do
        with_addons([ MANIFEST.merge("entry" => "../escape.js") ],
                    files: { "widget/dep.js" => "", "escape.js" => "" }) do |root|
          problem = Check.run(root).problems.sole
          assert_equal "widget", problem[:key]
          assert_match(/\Aentry: \.\.\/escape\.js is not a safe path/, problem[:reason])
        end
      end

      test "a directory with no manifests.json raises Source::Error naming it" do
        Dir.mktmpdir do |root|
          error = assert_raises(Source::Error) { Check.run(root) }
          assert_match(/manifests\.json/, error.message)
        end
      end

      test "a path that is not a directory raises Source::Error naming it" do
        error = assert_raises(Source::Error) { Check.run("/nonexistent/addons") }
        assert_match(%r{/nonexistent/addons is not a directory}, error.message)
      end
    end
  end
end
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `LIBRARY_PATH=$(mktemp -d) bin/rails test test/services/maker/addons/check_test.rb`
Expected: ERROR `NameError: uninitialized constant Maker::Addons::Check`.

- [ ] **Step 3: Implement** — `app/services/maker/addons/check.rb`:

```ruby
module Maker
  module Addons
    # WHAT `bin/rails "addons:check[PATH]"` RUNS — and tinkerex-addons' bin/publish runs it for the
    # author before a bundle ships. Two halves:
    #
    #   - `Registry.problems` — the host's OWN definition of a skipped manifest, never a second copy
    #     (a validator in the addons repo would drift from the rules this host enforces).
    #   - three checks only a directory on disk can answer, for each manifest that would build: its
    #     `<key>/` folder, its `entry` and every `pins` file exist. Over HTTP these would be a request
    #     per file, which is why they live here and not in Registry.
    #
    # READS PATH THROUGH Source::Local, NEVER Source.current: a check must not touch the network, a
    # cache, or whichever source this process happens to be configured with.
    class Check
      Result = Data.define(:count, :problems) do
        def ok? = problems.empty?
      end

      def self.run(path) = new(path).run

      def initialize(path) = @root = Pathname.new(path.to_s)

      def run
        raise Source::Error, "#{@root} is not a directory" unless @root.directory?

        index = Source::Local.new(@root).manifests
        file_problems = index.filter_map { |m| Registry.build(m) }.flat_map { |addon| files_for(addon) }
        Result.new(count: index.size, problems: Registry.problems(index) + file_problems)
      end

      private

      def files_for(addon)
        dir = @root.join(addon.key)
        return [ { key: addon.key, reason: "no #{addon.key}/ directory beside manifests.json" } ] unless dir.directory?

        { "entry" => addon.entry }.merge(addon.pins.to_h { |spec, file| [ "pin #{spec.to_s.inspect}", file ] })
                                  .filter_map do |label, file|
          reason = missing(dir, file.to_s)
          { key: addon.key, reason: "#{label}: #{reason}" } if reason
        end
      end

      # REJECT, NEVER NORMALIZE — the same guard the asset proxy uses, so a path this check passes is
      # one the host will actually serve.
      def missing(dir, file)
        Source.validate_asset_path!(file)
        "#{file} does not exist" unless dir.join(file).file?
      rescue Source::Error => e
        "#{file} is not a safe path (#{e.message})"
      end
    end
  end
end
```

- [ ] **Step 4: Run it and confirm it passes**

Run: `LIBRARY_PATH=$(mktemp -d) bin/rails test test/services/maker/addons/check_test.rb`
Expected: 8 runs, 0 failures, 0 errors.

- [ ] **Step 5: Write the failing task test** — `test/tasks/addons_tasks_test.rb`:

```ruby
require "test_helper"
require "rake"

# `bin/rails "addons:check[PATH]"` — loading and re-enabling follow landing_tasks_test.rb: task
# definitions load once per process, and a task runs its action only once until re-enabled.
class AddonsTasksTest < ActiveSupport::TestCase
  MANIFEST = {
    "key" => "widget", "title" => "Widget", "icon" => "🛠️", "description" => "Makes widgets",
    "api_version" => "1", "entry" => "widget.js"
  }.freeze

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("addons:check")
    Rake::Task["addons:check"].reenable
  end

  def addons_dir(manifests, files: [ "widget/widget.js" ])
    Dir.mktmpdir do |root|
      File.write(File.join(root, "manifests.json"), JSON.generate(manifests))
      files.each { |rel| FileUtils.mkdir_p(File.dirname(File.join(root, rel))); File.write(File.join(root, rel), "") }
      yield root
    end
  end

  test "a clean directory prints how many tools are OK and exits normally" do
    addons_dir([ MANIFEST ]) do |root|
      stdout, _stderr = capture_io { Rake::Task["addons:check"].invoke(root) }
      assert_match(/addons:check: 1 tool OK in /, stdout)
    end
  end

  test "problems exit non-zero with one key: reason line each" do
    addons_dir([ MANIFEST.except("icon"), MANIFEST.merge("key" => "gadget", "title" => "Gadget") ]) do |root|
      _stdout, stderr = capture_io do
        error = assert_raises(SystemExit) { Rake::Task["addons:check"].invoke(root) }
        assert_not error.success?
      end
      assert_match(/^widget: missing icon$/, stderr)
      assert_match(%r{^gadget: no gadget/ directory beside manifests.json$}, stderr)
    end
  end

  test "an unreadable directory exits non-zero naming the problem" do
    _stdout, stderr = capture_io do
      assert_raises(SystemExit) { Rake::Task["addons:check"].invoke("/nonexistent/addons") }
    end
    assert_match(%r{addons:check: /nonexistent/addons is not a directory}, stderr)
  end

  test "with no PATH it reads ADDON_SOURCE_PATH" do
    addons_dir([ MANIFEST ]) do |root|
      prior = ENV["ADDON_SOURCE_PATH"]
      ENV["ADDON_SOURCE_PATH"] = root
      stdout, _stderr = capture_io { Rake::Task["addons:check"].invoke }
      assert_match(/1 tool OK in #{Regexp.escape(root)}/, stdout)
    ensure
      prior.nil? ? ENV.delete("ADDON_SOURCE_PATH") : ENV["ADDON_SOURCE_PATH"] = prior
    end
  end
end
```

- [ ] **Step 6: Run it and confirm it fails**

Run: `LIBRARY_PATH=$(mktemp -d) bin/rails test test/tasks/addons_tasks_test.rb`
Expected: ERROR `Don't know how to build task 'addons:check'`.

- [ ] **Step 7: Implement** — `lib/tasks/addons.rake`:

```ruby
# The addon author's pre-publish check (Maker::Addons::Check): the host's own manifest rules plus
# on-disk file checks. tinkerex-addons' bin/publish runs it against that checkout; PATH defaults to
# ADDON_SOURCE_PATH, which development.rb points at ../tinkerex-addons/addons.
namespace :addons do
  desc 'Check addon manifests and their files: bin/rails "addons:check[PATH]" (default ADDON_SOURCE_PATH)'
  task :check, %i[path] => :environment do |_task, args|
    path = args[:path].presence || ENV["ADDON_SOURCE_PATH"]
    abort "addons:check: no PATH given and ADDON_SOURCE_PATH is not set" if path.blank?

    result = Maker::Addons::Check.run(path)
    abort result.problems.map { |p| "#{p[:key]}: #{p[:reason]}" }.join("\n") unless result.ok?

    puts "addons:check: #{result.count} #{'tool'.pluralize(result.count)} OK in #{path}"
  rescue Maker::Addons::Source::Error => e
    abort "addons:check: #{e.message}"
  end
end
```

- [ ] **Step 8: Run both new test files and `install_docs_test`** (it requires an INSTALL.md row for
  every variable `lib/tasks` reads; `ADDON_SOURCE_PATH` already has one at `docs/INSTALL.md:363`)

Run: `LIBRARY_PATH=$(mktemp -d) bin/rails test test/services/maker/addons/check_test.rb test/tasks/addons_tasks_test.rb test/install_docs_test.rb`
Expected: all green.

- [ ] **Step 9: Drive the real command against the real bundles**

Run (from the tinkerex root, plain shell): `bin/rails "addons:check[../tinkerex-addons/addons]"`
Expected: `addons:check: 3 tools OK in ../tinkerex-addons/addons`, exit 0. Then plant a problem in a
COPY, never the sibling: `cp -R ../tinkerex-addons/addons "$TMPDIR/a" && ruby -rjson -e 'f=ARGV[0]; j=JSON.parse(File.read(f)); j[0].delete("title"); File.write(f, JSON.generate(j))' "$TMPDIR/a/manifests.json" && bin/rails "addons:check[$TMPDIR/a]"; echo "exit=$?"`
Expected: `generators: missing title` and `exit=1`.

- [ ] **Step 10: Mutation-check — report each actual output**
  1. In `check.rb`, replace `Registry.problems(index) + file_problems` with `file_problems` → "a manifest the registry would skip" goes RED.
  2. Delete the `Source.validate_asset_path!(file)` line → the traversal test goes RED (the planted file exists, so it reports nothing).
  3. In `addons.rake`, change `abort … unless result.ok?` to `warn …` → "problems exit non-zero" goes RED.
  Restore each with `git checkout -- <file>` (commit Step 12 first), `rm -rf tmp/cache/bootsnap*`, `git status --porcelain`.

- [ ] **Step 11: Docs — sweep every place that describes skipping.** Run
  `grep -rn "silently dropped\|skipped, not raised\|is skipped\|silently skip" docs/addon-api-v1.md docs/invariants/addons.md`
  and update each hit that describes a skipped manifest so it also says where the reason surfaces:
  `bin/rails "addons:check[PATH]"` (exits 1 and names each problem — what tinkerex-addons'
  `bin/publish` runs), the notice on `/tools` in development and test only, and one production log
  warn per problem per request. In `docs/addon-api-v1.md`'s manifest section add one short paragraph
  "Checking a manifest before you ship it" with the command, what it checks (the registry's rules,
  duplicates, unreciprocated `states_key`, the `<key>/` folder, `entry`, every `pins` file) and that a
  duplicate key is reported but still served. The invariants bullet keeps its rule (skip, never
  raise) — add the reporting, change nothing else.

- [ ] **Step 12: Commit** (before Step 10's mutations)

```bash
git add app/services/maker/addons/check.rb test/services/maker/addons/check_test.rb lib/tasks/addons.rake test/tasks/addons_tasks_test.rb docs/addon-api-v1.md docs/invariants/addons.md
git commit -F - <<'EOF'
bin/rails addons:check: the host's manifest rules plus on-disk file checks

Maker::Addons::Check reads a directory through Source::Local, reports
Registry.problems, and adds what only a directory can answer: the addon's
folder, its entry and every pinned file. Exits 1 naming each problem — what
tinkerex-addons' bin/publish will run before shipping.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

## Task 3: The `/tools` notice in local environments

Depends on Task 1 (`Registry.problems`). Disjoint from Task 2.

**Files:**
- Modify: `app/controllers/tools/home_controller.rb` (`index`)
- Modify: `app/views/tools/home/index.html.erb` (after the `page-head` div)
- Test: `test/controllers/tools/home_controller_test.rb`

- [ ] **Step 1: Write the failing tests.** In `home_controller_test.rb`, add the house stub helper
  (Minitest 6 has no `Object#stub`) inside the class, then the tests:

```ruby
    # The house stub helper (help_page_test.rb carries the same body). Replaces a SINGLETON method
    # for the block, removing an inherited one after.
    def replacing(owner, name, replacement)
      mod = owner.singleton_class
      own = mod.instance_methods(false).include?(name)
      original = mod.instance_method(name)
      mod.define_method(name, &replacement)
      yield
    ensure
      own ? mod.define_method(name, original) : mod.remove_method(name)
    end

    # WHY A TOOL NEVER APPEARED, SHOWN WHERE THE AUTHOR IS LOOKING — but only in a local
    # environment. In production the cards are read by the maker, who can do nothing with
    # "missing icon" (the onboarding rule that moved sidecar env-var names off the cards).
    test "a skipped manifest is named, with its reason, in a local environment" do
      Maker::Addons::Source.stub = FakeAddonSource.new(manifests: [
        MANIFEST, MANIFEST.merge("key" => "broken", "title" => "Broken").except("icon")
      ])
      get tools_path
      assert_response :success
      assert_select ".addon-problems li", count: 1, text: /broken.*missing icon/
      assert_select ".addon-card", count: 1, message: "the notice must not add or remove a card"
    end

    test "a clean index renders no notice" do
      get tools_path
      assert_response :success
      assert_select ".addon-problems", count: 0
    end

    test "production never renders the notice, whatever the index holds" do
      Maker::Addons::Source.stub = FakeAddonSource.new(manifests: [ MANIFEST.except("icon") ])
      replacing(Rails, :env, -> { ActiveSupport::EnvironmentInquirer.new("production") }) do
        get tools_path
      end
      assert_response :success
      assert_select ".addon-problems", count: 0
    end
```

- [ ] **Step 2: Run them and confirm the first fails**

Run: `LIBRARY_PATH=$(mktemp -d) bin/rails test test/controllers/tools/home_controller_test.rb`
Expected: "a skipped manifest is named…" FAILS (`Expected exactly 1 element matching ".addon-problems li", found 0`); the other two pass — the production one is a guard that only bites once Step 3 exists, which Step 5 proves.

- [ ] **Step 3: Implement.** In `HomeController#index`, after `@addon_source_configured = …`:

```ruby
      # WHY A TOOL NEVER APPEARED — Registry.problems, the host's own definition of a skipped
      # manifest. LOCAL ENVIRONMENTS ONLY: the author editing a bundle is looking at this page, and
      # in production the cards are read by the maker, who can act on none of it. Production keeps
      # the log line Registry.all writes per problem.
      @addon_problems = Rails.env.local? ? Maker::Addons::Registry.problems : []
```

In `index.html.erb`, directly after `<div class="page-head"><h1>Tools</h1></div>`:

```erb
<%# WHY A TOOL NEVER APPEARED, for the author editing a bundle — development and test only
    (Tools::HomeController#index decides). Production makers never see it; the log keeps the clue. %>
<% if @addon_problems.any? %>
  <div class="form-errors flash-alert addon-problems" role="status">
    <p><%= pluralize(@addon_problems.size, "tool") %> <%= @addon_problems.size == 1 ? "wasn't" : "weren't" %>
      loaded from <code>manifests.json</code>:</p>
    <ul>
      <% @addon_problems.each do |problem| %>
        <li><code><%= problem[:key] %></code> — <%= problem[:reason] %></li>
      <% end %>
    </ul>
  </div>
<% end %>
```

(`form-errors flash-alert` is the existing error-list component used by three forms; `addon-problems`
is a hook for tests only and needs no CSS, so `css_hygiene_test.rb`'s component rule is untouched.)

- [ ] **Step 4: Run the file and confirm it passes**

Run: `LIBRARY_PATH=$(mktemp -d) bin/rails test test/controllers/tools/home_controller_test.rb test/integration/web/template_hygiene_test.rb`
Expected: all green.

If the production test errors because something else in the request reacts to a faked
`Rails.env` (a layout branch on `production?`), do not widen the fake: move the decision into a
one-line class method, `def self.addon_problems_visible? = Rails.env.local?` on
`Tools::HomeController`, call it from `index`, and have the test `replacing(Tools::HomeController,
:addon_problems_visible?, -> { false })` instead. Say which you used in your report.

- [ ] **Step 5: Mutation-check — report each actual output**
  1. Change `Rails.env.local?` to `true` → "production never renders the notice" goes RED.
  2. Change `Maker::Addons::Registry.problems` to `[]` → "a skipped manifest is named" goes RED.
  Restore with `git checkout -- app/controllers/tools/home_controller.rb` (commit first), `rm -rf tmp/cache/bootsnap*`.

- [ ] **Step 6: Commit** (before Step 5's mutations)

```bash
git add app/controllers/tools/home_controller.rb app/views/tools/home/index.html.erb test/controllers/tools/home_controller_test.rb
git commit -F - <<'EOF'
/tools names a skipped manifest and why, in development and test only

Reads Registry.problems; production makers never see it, and the log keeps
the clue there.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

## Task 4: PR 1 close-out (orchestrator, not a subagent)

- [ ] Run bare `bin/ci` (export `TINKEREX_SYNC_DIR=$PWD/../tinkerex-sync` if run from a worktree). Read the three backend legs' **run counts** — `test`, `test-s3`, `test-chunk-remote` must match (§15; ±2 assertions is the known flap).
- [ ] `/finish-branch` → PR, then `bin/log arc --from-pr <n>`.

---

## Task 5: `bin/revision` — one definition of the published revision

Repo: `../tinkerex-addons`, branch `claude/new-addon-and-publish` off an up-to-date `main`.

**Files:**
- Create: `bin/revision`
- Modify: `bin/build-push` (the `TAG=` / `REVISION=` block and its comment)

- [ ] **Step 1: Create `bin/revision`** and `chmod +x bin/revision`:

```bash
#!/usr/bin/env bash
# THE REVISION A BUNDLE IMAGE IS PUBLISHED UNDER: the HEAD SHA, or <SHA>-dirty when anything the
# image COPYs differs from HEAD. ONE definition — bin/build-push stamps it into the image and its
# tags, bin/publish verifies the running accessory against it — because two copies of the dirty rule
# would drift, and a verify step that disagrees with the stamp reports a failed deploy over a good one.
#
# DO NOT SPELL THE DIRTY CHECK `git describe --dirty` — it consults TRACKED files only, while the
# image COPYs addons/ FROM THE WORKING TREE and there is no .dockerignore, so an untracked
# addons/boxes/scratch.js ships while `--dirty` still reports a clean SHA: a stamp that READS as
# provenance and is not. `git status --porcelain` lists untracked files, so it decides.
#
# SCOPED TO WHAT THE IMAGE ACTUALLY CONTAINS (`addons/`, `nginx.conf`, `Dockerfile`), NOT the whole
# tree: macOS keeps minting a repo-root `.DS_Store` that no COPY touches, and a whole-tree check would
# stamp every build `-dirty` for a file that is not in the image. A warning that is always on is a
# warning nobody reads.
set -euo pipefail
cd "$(dirname "$0")/.."

revision="$(git rev-parse HEAD)"
if [ -n "$(git status --porcelain -- addons nginx.conf Dockerfile)" ]; then
  revision="$revision-dirty"
fi
echo "$revision"
```

- [ ] **Step 2: Make `bin/build-push` use it.** Replace

```bash
TAG="$(git rev-parse HEAD)"
```

with nothing (delete the line), and replace the block

```bash
REVISION="$TAG"
if [ -n "$(git status --porcelain -- addons nginx.conf Dockerfile)" ]; then
  REVISION="$TAG-dirty"
fi
```

with

```bash
REVISION="$(bin/revision)"
```

In the comment above it, delete the two paragraphs that begin "DO NOT SPELL THE DIRTY CHECK" and
"SCOPED TO WHAT THE IMAGE ACTUALLY CONTAINS" (they moved verbatim into `bin/revision`) and add one
line in their place: `# The dirty rule lives in bin/revision, shared with bin/publish's verify step.`
Keep the "PROVENANCE IS STAMPED TWICE" and "ONE VALUE FEEDS BOTH" paragraphs. Then
`grep -n 'TAG' bin/build-push` must print nothing.

- [ ] **Step 3: Verify both states**

Run: `bin/revision` → a 40-hex SHA equal to `git rev-parse HEAD`.
Run: `touch addons/zz-probe.js && bin/revision; rm addons/zz-probe.js` → the same SHA with `-dirty`.
Run: `touch .DS_Store && bin/revision; rm -f .DS_Store` → clean SHA (repo root is out of scope).
Run: `bash -n bin/build-push && echo syntax-ok`.

- [ ] **Step 4: Commit**

```bash
git add bin/revision bin/build-push
git commit -F - <<'EOF'
bin/revision: one definition of the published revision

build-push's dirty rule moves verbatim into bin/revision so bin/publish can
verify the running accessory against the same value build-push stamped.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

## Task 6: `bin/new-addon` — the scaffold

Repo: `../tinkerex-addons`. Depends on Task 2 being in the `../tinkerex` checkout (its test calls
`addons:check`). Disjoint from Task 5.

**Files:**
- Create: `templates/addon.js`, `bin/new-addon`, `test/new_addon_test.sh`

- [ ] **Step 1: Write the failing test** — `test/new_addon_test.sh`, `chmod +x`:

```bash
#!/usr/bin/env bash
# bin/new-addon's contract, run in a THROWAWAY COPY so the real index is never touched.
#
#   ./test/new_addon_test.sh
#
# The sibling half (the generated entry passing tinkerex's own `addons:check`) runs only when a
# tinkerex checkout is beside this repo, mirroring bin/check-fixture-drift's asymmetry: an absent
# sibling SKIPS with a notice, it never fails the repo.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok - $*"; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp -R "$REPO/bin" "$REPO/templates" "$REPO/addons" "$work/"
cd "$work"
before="$(cat addons/manifests.json; echo x)"; before="${before%x}"   # keep the trailing newline

# --- the happy path, hermetic (no sibling) ---
TINKEREX_PATH=/nonexistent bin/new-addon widget "Widget" "Makes widgets" >/dev/null \
  || fail "new-addon exited non-zero on a valid key"
[ -f addons/widget/widget.js ] || fail "entry addons/widget/widget.js not written"
pass "writes addons/<key>/<key>.js"

ruby -rjson -e '
  before, after = File.read(ARGV[0]), File.read(ARGV[1])
  index = JSON.parse(after)
  entry = index.last
  expected = { "key" => "widget", "title" => "Widget", "icon" => "🛠️", "description" => "Makes widgets",
               "api_version" => "1", "entry" => "widget.js", "min_host" => 1 }
  expected.each { |k, v| abort "manifest #{k}: #{entry[k].inspect} != #{v.inspect}" unless entry[k] == v }
  abort "no library:write permission" unless entry["permissions"].is_a?(Array) &&
    entry["permissions"].any? { |p| p["name"] == "library:write" && !p["reasoning"].to_s.empty? }
  # BYTES, not a re-parse: every earlier entry must be untouched text. Re-parsing would pass a
  # rewrite that reformatted siblings (JSON.generate instead of pretty_generate) — the churn this exists to forbid.
  prefix = before.sub(/\n\]\n\z/, "")
  abort "existing entries were rewritten" unless after.start_with?(prefix) && after.end_with?("]\n")
' "$REPO/addons/manifests.json" addons/manifests.json || fail "manifests.json entry wrong (above)"
pass "appends a complete entry and leaves every existing byte alone"

# The template is a real ES module. Syntax only: node does not resolve @maker/addon-sdk here.
if command -v node >/dev/null; then
  cp addons/widget/widget.js "$work/syntax-check.mjs"
  node --check "$work/syntax-check.mjs" || fail "generated bundle is not valid JS"
  pass "generated bundle parses as an ES module"
fi
grep -q '"Widget"' addons/widget/widget.js || fail "title not substituted into the bundle"
! grep -q '__TITLE_JSON__\|__KEY__' addons/widget/widget.js || fail "a template placeholder survived"
pass "placeholders substituted"

# --- refusals write nothing ---
snapshot="$(cat addons/manifests.json; echo x)"
refuse() {
  local why="$1"; shift
  if TINKEREX_PATH=/nonexistent bin/new-addon "$@" >/dev/null 2>&1; then fail "accepted: $why"; fi
  [ "$(cat addons/manifests.json; echo x)" = "$snapshot" ] || fail "manifests.json changed on refusal: $why"
}
refuse "uppercase key" Widget2 "W" "d";            [ ! -e addons/Widget2 ] || fail "dir made for bad key"
refuse "key starting with a digit" 2widget "W" "d"
refuse "key already in the index" generators "G" "d"
mkdir addons/orphan
refuse "directory already exists" orphan "O" "d"
refuse "missing description" lonely "L"
pass "refuses a bad key, a taken key, an existing directory and missing arguments, writing nothing"

# --- the sibling half: the host's own check accepts what we generate ---
TINKEREX="${TINKEREX_PATH:-$REPO/../tinkerex}"
if [ -x "$TINKEREX/bin/rails" ]; then
  out="$(TINKEREX_PATH="$TINKEREX" bin/new-addon gadget "Gadget" "Makes gadgets" 2>&1)" \
    || { echo "$out" >&2; fail "new-addon (with sibling check) exited non-zero"; }
  echo "$out" | grep -q "tools OK" || { echo "$out" >&2; fail "addons:check did not report OK"; }
  pass "the generated entry passes tinkerex's addons:check"
else
  echo "skip - no tinkerex checkout at $TINKEREX; the addons:check half did not run"
fi
```

Note: `rmdir addons/orphan` is unnecessary — the copy is deleted on exit — but the sibling check
reads the whole index, and `orphan` has no manifest entry, so it does not affect `addons:check`.

- [ ] **Step 2: Run it and confirm it fails**

Run: `./test/new_addon_test.sh`
Expected: `FAIL: new-addon exited non-zero on a valid key` (the script does not exist yet).

- [ ] **Step 3: Create `templates/addon.js`** — outside `addons/`, so the Dockerfile never ships it.
  `__KEY__` and `__TITLE_JSON__` are the only placeholders (`__TITLE_JSON__` becomes a JSON string
  literal, which is a valid JS string literal, so no title can break out of it):

```js
// __KEY__ — scaffolded by bin/new-addon. A working starting point: a name, some text, a "Save into"
// folder, and a Save button that writes <name>.txt into the library. Replace the fields and the
// file with whatever your tool makes; keep the save and error handling.
//
// THE ONE CONTRACT WITH THE HOST is the default export's `mount(element, ctx)`. Everything else goes
// through `@maker/addon-sdk`, which the host pins into this page's importmap — never vendor it, never
// list it in manifests.json's `pins`, never import it by path. Full reference: docs/addon-api-v1.md
// in the tinkerex repo.
import { host, AddonError, NameTakenError, ServiceUnavailableError, WouldReplaceError } from "@maker/addon-sdk"

const TITLE = __TITLE_JSON__

// 409 AND 422 STAY APART. WouldReplaceError reaches here only after onReplace already said yes and
// the host refused again; NameTakenError never succeeds on retry, so it must not offer an Overwrite.
const saveFailure = (e) => {
  if (e instanceof NameTakenError) return `Not saved. ${e.message}`
  if (e instanceof WouldReplaceError) return `Not saved: this would still replace ${e.files.map((f) => f.name).join(", ")}.`
  if (e instanceof ServiceUnavailableError) return "Couldn't reach your library — nothing was saved. Try again in a moment."
  if (e instanceof AddonError) return `Save failed: ${e.message}`
  return `Save failed: ${e.message || e}`
}

export default {
  mount(el, ctx) {
    el.innerHTML = `
      <h2 data-role="title"></h2>
      <p><label>Name <input type="text" data-role="name" value="untitled"></label></p>
      <p><label>Text <textarea data-role="body" rows="6"></textarea></label></p>
      <p>Save into <code data-role="folder"></code> <button type="button" data-role="pick">Change…</button></p>
      <p><button type="button" data-role="save">Save</button></p>
      <p class="muted" data-role="status" aria-live="polite"></p>`
    const $ = (role) => el.querySelector(`[data-role="${role}"]`)
    $("title").textContent = TITLE

    // WHERE THE SAVE STARTS is the host's choice: the folder the tool was opened from, the reopened
    // file's folder, or where this tool last saved. ctx.defaultFolder is a STRING node id ("" is the
    // library root) and has no SDK accessor, by design.
    let folderNodeId = ctx.defaultFolder || ""
    $("folder").textContent = ctx.defaultFolderLabel || "/ (library root)"

    // READ THROUGH `host` AT CALL TIME — never `const { files } = host` at the top of this module. A
    // Turbo re-mount builds a new host while this module's top level does not run again.
    $("pick").addEventListener("click", async () => {
      let folder
      try {
        folder = await host.files.pickFolder({ value: folderNodeId, label: $("folder").textContent })
      } catch (e) {
        $("status").textContent = `Couldn't open the folder chooser: ${e.message}`
        return
      }
      if (!folder) return // cancelled — NOT "the library root"; keep the previous choice
      folderNodeId = folder.nodeId
      $("folder").textContent = folder.path
    })

    $("save").addEventListener("click", async () => {
      const name = $("name").value.trim()
      if (!name) { $("status").textContent = "Name is required."; return }
      const body = $("body").value
      try {
        const result = await host.files.save({
          name,
          folderNodeId,
          data: { body },
          files: [ { name: `${name.replace(/[^a-z0-9]+/gi, "-").toLowerCase()}.txt`, contentType: "text/plain", body } ],
          // Saving again under the same name asks first; omit onReplace and the SDK throws
          // WouldReplaceError instead — overwriting is never implicit.
          onReplace: (files) => window.confirm(`Replace ${files.map((f) => f.name).join(", ")}?`),
        })
        // Both shapes are truthy — read `.cancelled`, never the object itself.
        $("status").textContent = result.cancelled ? "Not saved." : "Saved."
      } catch (e) {
        $("status").textContent = saveFailure(e)
        if (!(e instanceof AddonError)) throw e // a bug in this bundle, not a refusal: keep the stack
      }
    })
  },
}
```

- [ ] **Step 4: Create `bin/new-addon`** and `chmod +x bin/new-addon`:

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

# Scaffold a new addon: addons/<key>/<key>.js (a minimal working SDK bundle, from
# templates/addon.js) plus its entry in addons/manifests.json.
#
#   bin/new-addon <key> "<Title>" "<one-line description>" [--icon <glyph>]
#
# THE MANIFEST RULES ARE THE HOST'S, NOT THIS SCRIPT'S. It writes an entry that satisfies them, then
# asks tinkerex's own `addons:check` (Maker::Addons::Registry's definition) whether it does. A copy of
# the rules here would drift from the ones the host enforces. The check runs when a tinkerex checkout
# is beside this repo (TINKEREX_PATH, default ../tinkerex) and is skipped with a notice otherwise.
require "json"
require "optparse"
require "pathname"

ROOT = Pathname.new(__dir__).parent.expand_path
ADDONS = ROOT.join("addons")
INDEX = ADDONS.join("manifests.json")
TEMPLATE = ROOT.join("templates/addon.js")
KEY = /\A[a-z][a-z0-9-]*\z/
USAGE = 'usage: bin/new-addon <key> "<Title>" "<one-line description>" [--icon <glyph>]'
# The bundler context an inherited RUBYOPT/BUNDLE_GEMFILE would force on tinkerex's binstub — strip it,
# or the child boots against the wrong Gemfile (tinkerex CLAUDE.md §14j).
BUNDLER_ENV = %w[BUNDLE_GEMFILE BUNDLE_BIN_PATH BUNDLE_LOCKFILE BUNDLER_VERSION BUNDLER_SETUP RUBYOPT RUBYLIB]
              .to_h { |name| [ name, nil ] }

icon = "🛠️"
OptionParser.new { |o| o.on("--icon GLYPH") { |v| icon = v } }.parse!(ARGV)
key, title, description = ARGV
abort USAGE unless ARGV.size == 3 && [ key, title, description ].all? { |s| !s.to_s.strip.empty? }
unless KEY.match?(key)
  abort "new-addon: key #{key.inspect} must be lowercase letters, digits and dashes, starting with a letter " \
        "(it becomes the /tools/<key> URL and the addons/<key>/ folder)"
end

index = JSON.parse(INDEX.read)
abort "new-addon: #{key.inspect} is already in addons/manifests.json" if index.any? { |m| m.is_a?(Hash) && m["key"] == key }
dir = ADDONS.join(key)
abort "new-addon: addons/#{key}/ already exists" if dir.exist?

dir.mkpath
dir.join("#{key}.js").write(TEMPLATE.read.gsub("__KEY__", key).gsub("__TITLE_JSON__", title.to_json))
index << {
  "key" => key, "title" => title, "icon" => icon, "description" => description,
  "api_version" => "1", "entry" => "#{key}.js",
  # Level 1 is the SDK itself — files.save and files.pickFolder, everything the template uses.
  "min_host" => 1,
  "permissions" => [ { "name" => "library:write",
                       "reasoning" => "Saves the file it makes into the library folder you pick." } ]
}
# pretty_generate + newline round-trips this file byte-identically today (checked 2026-10-17), so the
# entries above the new one do not churn in the diff. test/new_addon_test.sh pins that on BYTES.
INDEX.write("#{JSON.pretty_generate(index)}\n")
puts "Created addons/#{key}/#{key}.js and its entry in addons/manifests.json."

tinkerex = Pathname.new(ENV.fetch("TINKEREX_PATH", ROOT.join("../tinkerex").to_s)).expand_path
if tinkerex.join("bin/rails").executable?
  ok = system(BUNDLER_ENV, "bin/rails", "addons:check[#{ADDONS}]", chdir: tinkerex.to_s)
  abort "new-addon: the files were written, but addons:check failed (above)." unless ok
else
  puts "Skipped addons:check — no tinkerex checkout at #{tinkerex} (set TINKEREX_PATH)."
end

puts <<~NEXT

  Try it:  in #{tinkerex}, run bin/dev and open http://localhost:3000/tools/#{key}
           Development reads this checkout directly, so an edit shows on reload.
  Ship it: bin/publish
NEXT
```

- [ ] **Step 5: Run the test and confirm it passes**

Run: `./test/new_addon_test.sh`
Expected: every line `ok - …`, ending with `ok - the generated entry passes tinkerex's addons:check`, exit 0.

- [ ] **Step 6: Mutation-check — report each actual output** (run the test after each, then restore with `git checkout -- <file>` — but `bin/new-addon` and the template are NEW files, so commit Step 7 first; `git checkout --` cannot restore an uncommitted new file)
  1. Delete the "already in addons/manifests.json" `abort` → "key already in the index" refusal FAILS.
  2. Change `JSON.pretty_generate(index)` to `JSON.generate(index)` → "existing entries were rewritten" FAILS.
  3. In the template, change `__TITLE_JSON__` to `"__TITLE_JSON__"` → the bundle fails `node --check`, or the placeholder check fails.
  4. Change the entry filename in `index <<` to `"#{key}-main.js"` → the sibling `addons:check` half FAILS with `entry: <key>-main.js does not exist`.

- [ ] **Step 7: Commit**

```bash
git add templates/addon.js bin/new-addon test/new_addon_test.sh
git commit -F - <<'EOF'
bin/new-addon: scaffold a working SDK bundle and its manifest entry

Writes addons/<key>/<key>.js from templates/addon.js (outside addons/, never
shipped) and appends the entry byte-preservingly, then runs tinkerex's own
addons:check when the sibling checkout is present.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

## Task 7: `bin/publish` and the README

Repo: `../tinkerex-addons`. Depends on Task 5 (`bin/revision`) and Task 2 (`addons:check`).

**Files:**
- Create: `bin/publish`
- Modify: `README.md` ("Adding or changing an addon" opening, "Deploying", "Repo layout")

- [ ] **Step 1: Confirm the verify command's output shape (read-only, safe).** From `../tinkerex`:
  `bin/kamal accessory exec addons --reuse -q "cat /usr/share/nginx/html/version.json"`
  Expected: output containing `{"version":"<sha>"}` (the currently running bundle). Note exactly
  how it appears; the `grep -o` in Step 2 must match it. If `-q` suppresses the command output
  itself, drop `-q`.

- [ ] **Step 2: Create `bin/publish`** and `chmod +x bin/publish`:

```bash
#!/usr/bin/env bash
# ONE COMMAND FROM "I CHANGED A BUNDLE" TO "IT IS LIVE". Stops at the first failure:
#
#   1. tinkerex's addons:check — refuse to ship a manifest the host would skip, or an entry/pin file
#      that is not there. The host's own rules (Maker::Addons::Registry), never a copy.
#   2. tinkerex's bin/secrets-preflight — `kamal accessory reboot` expands secrets through Ruby
#      backticks, which discard exit status, so an unreadable secret becomes an EMPTY one silently
#      (tinkerex docs/invariants/deploy-secrets.md).
#   3. bin/build-push — fixture-drift check, build, push, unchanged.
#   4. kamal accessory reboot addons — from tinkerex, where the accessory is declared.
#   5. VERIFY the running container's version.json IS the revision just pushed. On 2026-10-07 a ghcr
#      tag move was acknowledged, read back for a minute, then silently reverted at the origin, and
#      a reboot inside that window redeployed the OLD image while reporting success.
#
# Then /tools picks up manifest changes within Maker::Addons::Registry::TTL (5 minutes) — the cache
# is deliberately not busted (spec 2026-10-17 §2).
set -euo pipefail
cd "$(dirname "$0")/.."

TINKEREX="${TINKEREX_PATH:-../tinkerex}"
if [ ! -x "$TINKEREX/bin/rails" ]; then
  echo "publish: no tinkerex checkout at $TINKEREX — the addons accessory is declared there." >&2
  echo "         Clone chaim354/tinkerex beside this repo, or set TINKEREX_PATH." >&2
  exit 1
fi
TINKEREX="$(cd "$TINKEREX" && pwd)"
ADDONS="$(pwd)/addons"

# An inherited bundler context would boot tinkerex against the wrong Gemfile (tinkerex §14j).
in_tinkerex() {
  (cd "$TINKEREX" && env -u BUNDLE_GEMFILE -u BUNDLE_BIN_PATH -u BUNDLE_LOCKFILE -u BUNDLER_VERSION \
    -u BUNDLER_SETUP -u RUBYOPT -u RUBYLIB "$@")
}

echo "==> 1/5 checking manifests"
in_tinkerex bin/rails "addons:check[$ADDONS]"

echo "==> 2/5 preflighting secrets"
in_tinkerex bin/secrets-preflight

REVISION="$(bin/revision)"
echo "==> 3/5 building and pushing $REVISION"
# `:+set` expands to "set" or nothing — NEVER the value (a `:-` presence test echoes the secret).
if [ -n "${KAMAL_REGISTRY_PASSWORD:+set}" ]; then
  bin/build-push
else
  # The README's single-command form: scoped to this one child, never exported. An empty result
  # is caught by build-push's own `${KAMAL_REGISTRY_PASSWORD:?…}`, which prints no value.
  KAMAL_REGISTRY_PASSWORD="$(in_tinkerex bin/secret KAMAL_REGISTRY_PASSWORD op://tinkerex/ghcr.io/password)" bin/build-push
fi

echo "==> 4/5 rolling the addons accessory"
in_tinkerex bin/kamal accessory reboot addons

echo "==> 5/5 verifying what is running"
# Only the version field is kept; on a miss NOTHING from the buffer is printed — a diagnostic branch
# that dumps captured output is how this repo has leaked secrets before. Re-run the exec by hand.
running="$(in_tinkerex bin/kamal accessory exec addons --reuse -q "cat /usr/share/nginx/html/version.json" 2>/dev/null \
  | grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
if [ "$running" != "$REVISION" ]; then
  echo "publish: the accessory is serving '${running:-unreadable}', not $REVISION." >&2
  echo "         The registry tag may not have persisted (it reverted once, 2026-10-07)." >&2
  echo "         Re-run bin/publish — a fresh push persisted then. To look yourself, in tinkerex:" >&2
  echo "           bin/kamal accessory exec addons --reuse \"cat /usr/share/nginx/html/version.json\"" >&2
  exit 1
fi
echo "==> live: tinkerex-addons is serving $REVISION. /tools picks up manifest changes within 5 minutes."
```

(Adjust the `-q` / `grep -o` to whatever Step 1 showed.)

- [ ] **Step 3: Static checks** — `bash -n bin/publish && echo syntax-ok`; and
  `TINKEREX_PATH=/nonexistent bin/publish; echo "exit=$?"` → the "no tinkerex checkout" message and `exit=1`, having run nothing else.

- [ ] **Step 4: Prove step 1 refuses** without touching docker or kamal: in a throwaway copy,
  `cp -R . "$TMPDIR/pub" && cd "$TMPDIR/pub" && ruby -rjson -e 'f="addons/manifests.json"; j=JSON.parse(File.read(f)); j[0].delete("icon"); File.write(f, JSON.pretty_generate(j)+"\n")' && TINKEREX_PATH=<abs path to tinkerex> bin/publish; echo "exit=$?"`
  Expected: `==> 1/5 checking manifests`, `generators: missing icon`, `exit=1`, and no `2/5` line.

- [ ] **Step 5: README.**
  - "Repo layout": add `bin/new-addon`, `bin/publish`, `bin/revision`, `templates/addon.js` and
    `test/new_addon_test.sh`, one line each.
  - "Adding or changing an addon": open with a short "Quick start" before the manifest tables:
    `bin/new-addon <key> "<Title>" "<description>"`, then run tinkerex's `bin/dev` and open
    `/tools/<key>` (development reads this checkout directly, uncached), then `bin/publish`. Say that
    a manifest the host would skip is named by tinkerex's `bin/rails "addons:check[PATH]"` and on
    `/tools` in development — replacing "A manifest that fails validation is silently dropped" with
    that (it is still dropped in production, never raised on).
  - "Deploying": lead with `bin/publish` and its five steps in one sentence each; keep the existing
    manual `bin/build-push` + `kamal accessory reboot addons` text below it as "what publish runs, if
    you need a step on its own". Keep the "Which bundle is actually running" section.
  - Then `grep -n "silently dropped\|reboot addons" README.md` and confirm every hit now reads
    correctly.

- [ ] **Step 6: Commit**

```bash
git add bin/publish README.md
git commit -F - <<'EOF'
bin/publish: check, preflight, build-push, reboot, verify — one command

Refuses a manifest tinkerex's addons:check rejects, preflights secrets, runs
build-push unchanged, reboots the accessory from tinkerex, and verifies the
running version.json against bin/revision (the 2026-10-07 tag-revert failure).

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

- [ ] **Step 7: The real publish — ORCHESTRATOR ONLY, AND ONLY WITH THE OWNER'S GO-AHEAD.** It
  redeploys the live `addons` accessory. With approval, run `bin/publish` once from this branch
  (the bundles under `addons/` are identical to `main`'s, so nothing user-visible changes; the image
  revision will be this branch's SHA until the next publish from `main`). Report the five step lines
  and the final `live:` line. Then `./test/no_gpl_in_bundle_image_test.sh` and
  `./test/new_addon_test.sh`, push, open the PR, and state the real publish as the verification.

---

## Self-review notes (resolved)

- Spec §3.2 said a keyless entry is named `#<index position>`; the plan uses `entry N`, counting
  from 1 — friendlier, and the spec is amended to match.
- Spec §4 said `TINKEREX_DIR`; the addons repo already uses **`TINKEREX_PATH`**
  (`bin/check-fixture-drift`), so every script here uses that — spec amended.
- `pickFolder` resolves `{nodeId, path}` (not `label`) — the template reads `folder.path`, as
  `folder_field.js` does.
