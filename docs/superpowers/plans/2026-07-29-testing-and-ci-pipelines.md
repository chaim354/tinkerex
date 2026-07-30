# Testing & CI Pipelines Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Get CI running green again (it has been dark since 2026-06-24), make a missing runner fail fast instead of queueing silently for 24 h, collapse the three drifting definitions of "the gates" into one `bin/ci`, and build `test/system` into a real browser tier starting with the three highest-risk Stimulus controllers.

**Architecture:** Retarget the OS-agnostic Rails jobs at the one runner that exists (macOS — every gate is measured green on it), and gate every Linux/Windows job on a **preflight** job that reads a declared fleet from the repo variable `CI_RUNNERS`, so a job whose runner is absent is never *scheduled* and therefore cannot queue. `config/ci.rb` becomes the single definition of every gate and `ci.yml` invokes it by name (`bin/ci scan`), with `test/ci_hygiene_test.rb` asserting the two lists cannot drift. The browser tier gets a shared harness, a written admission policy, and three real tests.

**Tech Stack:** GitHub Actions (self-hosted runners only — §15), `ActiveSupport::ContinuousIntegration` (Rails 8.1's `bin/ci` DSL, already present), Minitest, Capybara + selenium-webdriver + headless Chrome, bash, rubyzip.

**Spec:** `docs/superpowers/specs/2026-07-29-testing-and-ci-pipelines-design.md`. Read §3 before touching any workflow — it records two feasibility findings that rule out the obvious implementation.

---

## Context an engineer starting here needs

**Nothing is wrong with the code.** Measured on the maker-mac box on 2026-07-29: `bin/rails test` is
1628 runs / 0 failures / 0 errors on **all three** `LIBRARY_BACKEND` values, `test:system` is 6/0/0,
`bin/rubocop` is clean, and all three security scanners exit 0. The failure is entirely in the
pipeline.

**Three facts that will otherwise cost you an afternoon each:**

1. **`gh api repos/:owner/:repo/actions/runners` works in your shell and 403s inside a workflow.**
   Listing self-hosted runners needs the `administration` permission, which is **not** among those a
   workflow `GITHUB_TOKEN` can be granted. Your shell works because your personal token has admin
   scope. `ci/runners/README.md:53` documents that command as *the* way to check runners, which
   reinforces the wrong instinct. This is why the preflight reads a repo **variable**.
2. **`ruby/setup-ruby@v1` is not usable on the self-hosted Mac.** `nightly.yml`'s `e2e-macos` job
   says so in a comment and deliberately uses the runner's own Ruby instead. The runner's service
   PATH (`~/actions-runner-tinkerex/.path`) already carries mise's **ruby 3.4.7** — exactly
   `.ruby-version` — plus bundler 4.0.3, `/opt/homebrew/bin` (so `resvg`, `f3d`, `vipsthumbnail`
   resolve) and `~/.cargo/bin`. So: `bundle install --quiet`, never `setup-ruby`.
3. **`YAML.load_file` on a workflow parses the `on:` key as the boolean `true`** (Psych resolves
   YAML 1.1 booleans). Verified: `ci.yml`'s top-level keys come back as
   `["name", true, "concurrency", "jobs"]`. Every test in this plan reads only `"jobs"`, so it never
   matters — but do not go looking for `d["on"]`.

**GitHub Actions does not support YAML anchors**, so the repeated job preamble in `ci.yml` is
repeated on purpose. Do not "DRY it up" with `&`/`*`; the workflow will fail to parse.

---

## File structure

**Create:**

| Path | Responsibility |
|---|---|
| `ci/preflight.sh` | The only place that decides which runner families are available. Two output modes: `family=bool` lines for `$GITHUB_OUTPUT`, `--summary` markdown for `$GITHUB_STEP_SUMMARY`. Extracted from the workflow so it is **testable** — inline YAML bash is not. |
| `test/ci_preflight_test.rb` | Drives `ci/preflight.sh` as a subprocess and asserts its **output**, not its internals. |
| `test/ci_hygiene_test.rb` | Guards the workflow invariants no other test can see, following the established `test/deploy_hygiene_test.rb` pattern. |
| `test/system/support/web_helpers.rb` | The browser-tier harness: sign-in (with the Turbo-redirect wait the two existing tests both hand-roll) and a library/project fixture. |
| `test/system/README.md` | The admission policy for the tier (spec §5.3). |
| `test/system/uploader_test.rb` | Priority 1: the chunk two-phase upload, in a real browser. |
| `test/system/importer_test.rb` | Priority 2: client-side JSZip unzip → upload → attach. |
| `test/system/file_menu_test.rb` | Priority 3: the attach/move/rename menu. |

**Modify:**

| Path | Change |
|---|---|
| `config/ci.rb` | Becomes the single gate definition: adds the share/s3/system gates it was missing, plus gate selection and `--list`. |
| `.github/workflows/ci.yml` | Retarget at macos, drop `setup-ruby`, one `bin/ci <gate>` per job, `scan_ruby`+`scan_js` → one `scan`, fixed resvg step, new `preflight` job. |
| `.github/workflows/rust-client.yml` | `changes` → macos; linux/windows jobs preflight-gated. |
| `.github/workflows/nightly.yml` | linux/windows jobs preflight-gated. |
| `.github/workflows/cross-os-e2e.yml` | `seed` → macos; linux/windows legs preflight-gated. |
| `docs/STATUS.md`, `CLAUDE.md`, `ci/runners/README.md` | Spec §9. |

**Deliberately untouched:** `.github/workflows/build-app.yml` and `install-app-on-runners.yml`. Both
are `workflow_dispatch`-only and both derive their runner from a dynamic matrix
(`[self-hosted, "${{ matrix.runner }}"]`) that no static check can resolve. A human triggering a
manual workflow can see it queue; the silent-rot failure mode this plan fixes needs an *automatic*
trigger. `test/ci_hygiene_test.rb` allowlists these two files with that reason inline.

---

## Scope note: what this plan covers of the spec's browser priorities

Spec §5.4 lists six priorities in risk order. **This plan implements the harness, the policy, and
priorities 1–3** (`uploader`, `importer`, `filemenu`). Priorities 4–6 (`thumbs`/`thumbfallback`, the
tool UIs, `modelviewer`) are a follow-up plan: each needs its own fixture work, and a plan that is
half speculative test code is a plan that gets abandoned at task 9. The harness built in Task 8 is
what makes the follow-up cheap.

---

## Task 1: Guard the two workflow invariants that must exist BEFORE the retarget

Both assertions pass today. That is the point: they are the tripwires for the change Task 4 makes,
and a tripwire installed after the change guards nothing.

**Files:**
- Create: `test/ci_hygiene_test.rb`

- [ ] **Step 1: Write the test**

```ruby
require "test_helper"

# Guards the CI invariants that live in .github/workflows/*.yml — files the Rails process never
# loads, so no other test in the suite can see them. Modelled on test/deploy_hygiene_test.rb, which
# guards deployment facts for the same reason.
#
# Each assertion here corresponds to something that has already gone wrong or that CLAUDE.md forbids
# outright. None of them is hypothetical:
#
#   * A `*-latest` runner is the only BILLED kind (§15: self-hosted is free, macOS-hosted is 10x).
#     Nothing guarded this before, and "just use ubuntu-latest" is the first thing anyone reaches
#     for when a self-hosted runner is missing — which is exactly the situation this repo is in.
#   * `ruby/setup-ruby@v1` does not work on the self-hosted Mac. nightly.yml's e2e-macos job says so
#     in a comment and uses the runner's own Ruby instead. Retargeting a Rails job at macos while
#     keeping the action fails at step 2 of every job, on infrastructure rather than on code, which
#     is the least legible kind of red.
class CiHygieneTest < ActiveSupport::TestCase
  WORKFLOW_DIR = Rails.root.join(".github/workflows")

  # build-app.yml and install-app-on-runners.yml are exempt from the runner-family rules below.
  # Both are workflow_dispatch-ONLY and both take their runner from a dynamic matrix
  # (`[self-hosted, "${{ matrix.runner }}"]`), which no static check can resolve. The failure this
  # file exists to prevent — a job queueing 24h against a runner that does not exist, with nobody
  # watching — needs an AUTOMATIC trigger. A human who pressed "Run workflow" is watching.
  DYNAMIC_MATRIX_WORKFLOWS = %w[build-app.yml install-app-on-runners.yml].freeze

  # Every self-hosted family we may target. Anything else is either GitHub-hosted (billed) or a typo.
  FAMILIES = %w[macos linux windows].freeze

  test "no workflow targets a GitHub-hosted runner" do
    # §15: GitHub bills ONLY hosted runners. Matching on the `-latest` suffix rather than an
    # exhaustive image list is deliberate — `ubuntu-24.04` and `macos-15` are billed too, so the
    # check is "does this name look like a GitHub image at all", which the version-pinned forms
    # also satisfy via the second pattern.
    offenders = []
    each_job do |file, name, job|
      Array(job["runs-on"]).map(&:to_s).each do |label|
        next if label.include?("${{")           # dynamic matrix — resolved at run time
        if label.match?(/-latest\z/) || label.match?(/\A(ubuntu|macos|windows)-\d/)
          offenders << "#{file}: job `#{name}` runs-on `#{label}`"
        end
      end
    end
    assert_empty offenders,
                 "GitHub-hosted runners are the only BILLED kind (CLAUDE.md §15) — use " \
                 "[self-hosted, <family>]:\n  #{offenders.join("\n  ")}"
  end

  test "no job running on macos uses ruby/setup-ruby" do
    # The action assumes the GitHub-hosted /Users/runner layout the self-hosted Mac does not have
    # (see nightly.yml's e2e-macos, which works around it). The runner's own PATH already carries
    # mise ruby 3.4.7 — exactly .ruby-version — so `bundle install` is all a job needs.
    offenders = []
    each_job do |file, name, job|
      next unless Array(job["runs-on"]).map { |l| l.to_s.downcase }.include?("macos")
      used = Array(job["steps"]).filter_map { |s| s["uses"] }
      offenders << "#{file}: job `#{name}`" if used.any? { |u| u.start_with?("ruby/setup-ruby") }
    end
    assert_empty offenders,
                 "ruby/setup-ruby does not work on the self-hosted Mac; use the runner's own Ruby " \
                 "(`bundle install --quiet`) instead:\n  #{offenders.join("\n  ")}"
  end

  private

    # Yields [basename, job_name, job_hash] for every job in every workflow.
    #
    # Reads only the "jobs" key. NOTE for anyone extending this: Psych resolves YAML 1.1 booleans,
    # so a workflow's `on:` key parses as the BOOLEAN true, not the string "on" — ci.yml's top-level
    # keys come back as ["name", true, "concurrency", "jobs"]. Reach for `d[true]`, not `d["on"]`.
    def each_job
      WORKFLOW_DIR.glob("*.yml").sort.each do |path|
        jobs = YAML.load_file(path, aliases: true).fetch("jobs")
        jobs.each { |name, job| yield path.basename.to_s, name, job }
      end
    end

    # The workflows subject to the runner-family rules: everything except the dynamic-matrix pair.
    def each_static_job
      each_job do |file, name, job|
        next if DYNAMIC_MATRIX_WORKFLOWS.include?(file)
        yield file, name, job
      end
    end
end
```

- [ ] **Step 2: Run it and confirm both tests pass**

Run:
```bash
bin/rails test test/ci_hygiene_test.rb
```
Expected: `2 runs, 2 assertions, 0 failures, 0 errors`.

`each_static_job` is defined but unused until Task 5 — that is intentional; it lands with the helper
that uses it. Rubocop does not flag an unused private method, but confirm:

```bash
bin/rubocop test/ci_hygiene_test.rb
```
Expected: `1 file inspected, no offenses detected`.

- [ ] **Step 3: Mutation-check both assertions — a guard that cannot fail is not a guard**

Temporarily change `ci.yml`'s `lint` job to `runs-on: ubuntu-latest`, run the test, and confirm the
first test goes **RED** naming `ci.yml: job \`lint\``. Then revert.

Temporarily add `- uses: ruby/setup-ruby@v1` to `nightly.yml`'s `e2e-macos` job steps, run the test,
and confirm the second goes **RED** naming `nightly.yml: job \`e2e-macos\``. Then revert.

```bash
git diff --stat   # must be empty before committing
```

- [ ] **Step 4: Commit**

```bash
git add test/ci_hygiene_test.rb
git commit -m "test(ci): guard the no-hosted-runner and no-setup-ruby-on-macos invariants

Both pass today. They are installed BEFORE the macos retarget because a tripwire
added after the change it guards guards nothing. Mutation-checked: ubuntu-latest on
one job and setup-ruby on one macos job each turn the corresponding test red."
```

---

## Task 2: Make `config/ci.rb` the single definition of every gate

`bin/ci` already exists (Rails 8.1 ships it) and **already lies**: it runs 7 steps, prints
"Continuous Integration passed", and omits three gates `ci.yml` runs — the share leg, the s3 leg,
and system tests (commented out in the scaffold). Verified: `bin/ci` passes in 14.15 s today while
never touching `LIBRARY_BACKEND` or a browser.

**Files:**
- Modify: `config/ci.rb` (whole file replaced)
- Modify: `test/ci_hygiene_test.rb` (add the gate-coverage assertion)

- [ ] **Step 1: Write the failing test — add this test to `test/ci_hygiene_test.rb`**

Insert after the `"no job running on macos uses ruby/setup-ruby"` test:

```ruby
  # The gates bin/ci must define. This list is the CONTRACT: ci.yml invokes these by name (Task 4
  # pins that direction), and every one of them is a gate that has to run somewhere.
  #
  # `test-share` and `test-s3` are on this list because they were the drift. They were added to
  # ci.yml on 2026-07-16 and never reached config/ci.rb, so `bin/ci` reported a green
  # "Continuous Integration" while running two thirds of the backend matrix. `system` is here
  # because the Rails scaffold ships it COMMENTED OUT, and this repo now has a browser tier.
  REQUIRED_GATES = %w[style scan test test-share test-s3 system].freeze

  test "bin/ci defines every gate CI depends on" do
    missing = REQUIRED_GATES - bin_ci_gates
    assert_empty missing,
                 "config/ci.rb is missing gate(s) #{missing.inspect}. `bin/ci` printing " \
                 "\"passed\" while omitting a gate ci.yml runs is the drift this list exists to " \
                 "stop — see the comment above REQUIRED_GATES."
  end
```

and add this to the `private` section, above `each_job`:

```ruby
    # The real gate list, read by RUNNING bin/ci rather than by parsing config/ci.rb.
    #
    # Shelling out costs ~1s (it boots config/boot) and is worth it: a regex over the source would
    # assert that the file LOOKS like it defines a gate, and this asserts that `bin/ci <gate>` will
    # actually resolve. The repo has already been bitten once by a hermetic check that shared the
    # code's misunderstanding (FakeS3 / CGI.escape) — assert the wire, not the round-trip.
    def bin_ci_gates
      out = IO.popen([ Rails.root.join("bin/ci").to_s, "--list" ], err: [ :child, :out ], &:read)
      assert_equal 0, $?.exitstatus, "`bin/ci --list` failed:\n#{out}"
      out.split("\n").map(&:strip).reject(&:empty?)
    end
```

- [ ] **Step 2: Run it and verify it FAILS**

> ⚠️ **DO NOT run the new test against the unmodified `config/ci.rb`. It is a fork bomb.**
>
> This was the plan's own bug, hit during implementation on 2026-07-29 (~95 processes, load average
> 17.8) and corrected here. The old scaffold **ignores `ARGV` entirely**, so `bin/ci --list` runs its
> hardcoded `bin/rails test` — the *unscoped* suite. That suite includes `test/ci_hygiene_test.rb`,
> whose new test shells out to `bin/ci --list`, which runs the unscoped suite again. **There is no
> base case.** Scoping the outer command with `-n` does not help: the recursion is inside the test
> body, against the unpatched script's fixed behaviour.
>
> The hazard disappears the moment Step 3 lands, because `--list` then exits before `CI.run` is
> reached. It exists only in this one window — which is exactly why the red-check has to be taken a
> different way.

Establish RED **statically** instead. This is better evidence than a hung test anyway: it shows
*why* the test cannot pass rather than merely that it doesn't.

```bash
grep -c "ARGV" config/ci.rb
```
Expected: `0`. The scaffold contains no `ARGV` handling whatsoever, so `--list` cannot be understood,
`bin/ci` falls through to its hardcoded step list, and `bin_ci_gates` can never receive a gate list.
That *is* the failure, proven at the source and costing nothing.

```bash
grep -n "step \"" config/ci.rb
```
Expected: the scaffold's hardcoded steps, with **no** `LIBRARY_BACKEND` anywhere and `Tests: System`
commented out — the three-gate drift this task exists to close, visible in one command.

**Do not try to demonstrate it by executing the old script**, even with a timeout or a background
kill. `timeout` is not installed on this box, and `kill -- -$!` is actively unsafe here: without job
control a background job shares the *shell's* process group, so that PGID kill can take out the shell
running it. There is no bounded way to run the recursive version, which is why the check is static.

- [ ] **Step 3: Replace `config/ci.rb` entirely**

```ruby
# Run using bin/ci [GATE ...]
#
# ONE definition per gate, and .github/workflows/ci.yml invokes these BY NAME — one job per gate. So
# the PR keeps a separate status per gate while there is exactly one definition of what each gate
# does. test/ci_hygiene_test.rb asserts the two lists cannot drift apart.
#
# THE DRIFT THIS REPLACES WAS REAL AND LIVE. Before this, three lists claimed to be "the gates":
# this file (the untouched Rails scaffold), ci.yml, and a hand-copied 8-command checklist in
# docs/STATUS.md. `bin/ci` printed "Continuous Integration passed" while running neither backend leg
# and no system tests.
#
# WHY ALL THREE SCANNERS SIT IN ONE GATE: ci.yml used to run brakeman as step 1 of `scan_ruby` and
# bundler-audit as step 2. brakeman exited 3 for weeks, so the job stopped there and the audit gate
# NEVER EXECUTED — the job looked like two gates and was zero, which is how five gems drifted behind
# 18 published advisories, one High on the always-on /cable path. `CI.step` records a result and
# CONTINUES, so every scanner here runs whatever any other one does. That is a structural fix, not a
# convention, and it is the reason not to split these back into separate gates.
#
# Usage:
#   bin/ci                 # every gate, in this order
#   bin/ci test test-s3    # exactly those gates
#   bin/ci --list          # the gate names, one per line (what ci_hygiene_test reads)

GATES = {
  # Local convenience only — ci.yml does its own `bundle install` per job and never calls this.
  "setup" => ->(ci) do
    ci.step "Setup", "bin/setup --skip-server"
  end,

  "style" => ->(ci) do
    ci.step "Style: Ruby", "bin/rubocop"
  end,

  "scan" => ->(ci) do
    ci.step "Security: Gem audit", "bin/bundler-audit"
    ci.step "Security: Importmap vulnerability audit", "bin/importmap audit"
    ci.step "Security: Brakeman code analysis",
            "bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error"
  end,

  # THE THREE FILELAYER BACKENDS. The suites are identical; what the share and s3 legs buy is
  # narrower than it looks and is argued at length in ci.yml — they catch tests that silently depend
  # on the AMBIENT LIBRARY_BACKEND. The share leg found nine of them on the way in.
  "test" => ->(ci) do
    ci.step "Tests: Rails (chunk backend)", "bin/rails db:test:prepare test"
  end,

  "test-share" => ->(ci) do
    # A fresh empty dir per run. LIBRARY_PATH must exist and be writable or the boot guard refuses
    # to start — it TOUCH-PROBES, because File.writable? reads POSIX mode bits rather than effective
    # access and is wrong under exactly the NFS/SMB ACLs this backend targets.
    ci.step "Tests: Rails (share backend)",
            'env LIBRARY_BACKEND=share LIBRARY_PATH="$(mktemp -d)" bin/rails db:test:prepare test'
  end,

  "test-s3" => ->(ci) do
    # These knobs point at NOTHING REAL on purpose: the suite injects a stubbed Aws::S3::Client, and
    # the s3 boot guard is config-PRESENCE only and never touches the network (boot must not depend
    # on a third party being reachable). Any test that made a real S3 call fails here. That is the
    # point, not an oversight.
    ci.step "Tests: Rails (s3 backend)",
            "env LIBRARY_BACKEND=s3 LIBRARY_S3_BUCKET=ci-not-a-real-bucket " \
            "LIBRARY_S3_REGION=us-east-1 LIBRARY_S3_ACCESS_KEY_ID=ci " \
            "LIBRARY_S3_SECRET_ACCESS_KEY=ci LIBRARY_S3_PREFIX=library " \
            "bin/rails db:test:prepare test"
  end,

  "system" => ->(ci) do
    ci.step "Tests: System (real browser)", "bin/rails db:test:prepare test:system"
  end
}.freeze

if ARGV.include?("--list")
  puts GATES.keys
  exit 0
end

selected = ARGV.empty? ? GATES.keys : ARGV
unknown  = selected - GATES.keys
unless unknown.empty?
  abort "bin/ci: unknown gate(s): #{unknown.join(", ")}\n" \
        "       known gates: #{GATES.keys.join(" ")}"
end

CI.run do
  selected.each { |gate| GATES.fetch(gate).call(self) }
end
```

- [ ] **Step 4: Verify the test passes and the script behaves**

```bash
bin/rails test test/ci_hygiene_test.rb
```
Expected: `3 runs, 3 assertions, 0 failures, 0 errors`.

```bash
bin/ci --list
```
Expected exactly:
```
setup
style
scan
test
test-share
test-s3
system
```

```bash
bin/ci nonsense-gate; echo "exit=$?"
```
Expected: `bin/ci: unknown gate(s): nonsense-gate` followed by the known-gate list, and `exit=1`.

```bash
bin/ci scan
```
Expected: three ✅ steps (Gem audit, Importmap, Brakeman) and `✅ Continuous Integration passed`.

```bash
bin/ci test-share
```
Expected: `✅ Tests: Rails (share backend)` — 1628 runs, 0 failures.

- [ ] **Step 5: Verify the structural scanner fix actually holds**

This is the assertion that matters most and the one nobody checks. Break brakeman deliberately and
confirm the *other two scanners still run*:

```bash
bin/ci scan 2>&1 | grep -E "✅|❌"
```
Then break brakeman deliberately: insert `raise "boom"` into `bin/brakeman` **immediately after its
`#!/usr/bin/env ruby` shebang — line 2, not line 1.** Putting it on line 1 displaces the shebang, so
the kernel exec fails and `sh` interprets the Ruby file, producing `raise: command not found` instead
of a Ruby exception. The step still fails and the proof still stands, but you are then testing a
broken *shebang* rather than a broken *scanner*, which is not the thing being claimed.

Re-run the same command and confirm the output shows **✅ Gem audit, ✅ Importmap, ❌ Brakeman** —
three results, not one — and that the overall run is ❌ with a non-zero exit. Revert `bin/brakeman`
and confirm `git diff bin/brakeman` is empty.

This is the exact bug that hid for five weeks, inverted: under `ci.yml`'s old step ordering a
brakeman failure meant bundler-audit never ran at all.

- [ ] **Step 6: Commit**

```bash
git add config/ci.rb test/ci_hygiene_test.rb
git commit -m "ci: make config/ci.rb the single gate definition

bin/ci shipped as the untouched Rails scaffold and reported a green
'Continuous Integration' while running neither the share nor the s3 backend leg
and no system tests — three lists claiming to be 'the gates' (this file, ci.yml,
and a hand-copied checklist in STATUS.md), already drifted.

All three scanners now sit in ONE gate: CI.step records a result and continues, so
a brakeman failure no longer prevents bundler-audit from running. That sequencing
is how brakeman's exit 3 kept the audit gate from EVER executing, and with it five
gems behind 18 advisories. Verified by breaking brakeman and watching the other
two still report."
```

---

## Task 3: `ci/preflight.sh` — the fail-fast guard, extracted so it can be tested

**Files:**
- Create: `ci/preflight.sh`
- Create: `test/ci_preflight_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
require "test_helper"

# ci/preflight.sh is what stops a job being SCHEDULED against a runner family that does not exist.
# That matters because a job whose labels match no online runner does not fail — it queues for 24h
# and is then auto-cancelled, at 0 elapsed, with mergeStateStatus stuck at UNSTABLE. That is how CI
# stayed dark from 2026-06-24 to 2026-07-29 without ever going red.
#
# The logic lives in a SCRIPT rather than inline in the workflow for one reason: inline YAML bash
# cannot be tested, and this decides whether coverage runs at all. Asserted by running the script
# and reading its OUTPUT — the interface the workflow consumes.
class CiPreflightTest < ActiveSupport::TestCase
  SCRIPT = Rails.root.join("ci/preflight.sh").to_s

  test "an unset CI_RUNNERS declares macos ONLY — never everything" do
    # The most important test in the file. A default of "assume everything is available" reproduces
    # the original bug exactly: jobs scheduled against runners that do not exist. The conservative
    # default is what makes a forgotten variable safe.
    out, status = preflight(nil)
    assert_equal 0, status, out
    assert_equal "macos=true\nlinux=false\nwindows=false\n", out
  end

  test "an empty or whitespace CI_RUNNERS falls back to the same conservative default" do
    [ "", "   " ].each do |value|
      out, status = preflight(value)
      assert_equal 0, status, out
      assert_equal "macos=true\nlinux=false\nwindows=false\n", out,
                   "CI_RUNNERS=#{value.inspect} must behave as unset"
    end
  end

  test "a declared family is reported available" do
    out, status = preflight("macos,linux")
    assert_equal 0, status, out
    assert_equal "macos=true\nlinux=true\nwindows=false\n", out
  end

  test "the declaration tolerates whitespace and case" do
    out, _ = preflight(" macOS , LINUX ")
    assert_equal "macos=true\nlinux=true\nwindows=false\n", out
  end

  test "a family name is matched whole, not as a substring" do
    # Without the comma-delimiting, a declared "linux-arm64" would satisfy a "linux" lookup and
    # schedule x86 FUSE jobs onto an arm box.
    out, _ = preflight("macos,linux-arm64")
    assert_equal "macos=true\nlinux=false\nwindows=false\n", out
  end

  test "--summary names the absent families and says the run is green about less" do
    out, status = preflight("macos", "--summary")
    assert_equal 0, status, out
    assert_match(/CI runner preflight/, out)
    assert_match(/`macos` \| ✅/, out)
    assert_match(/`linux` \| ⛔/, out)
    assert_match(/`windows` \| ⛔/, out)
    # The declared value is echoed so a STALE declaration is visible at the point of damage.
    assert_match(/CI_RUNNERS.*`macos`/, out)
    assert_match(/skipped, not passed/i, out)
  end

  test "--summary says so plainly when nothing was skipped" do
    out, _ = preflight("macos,linux,windows", "--summary")
    assert_match(/no coverage skipped/i, out)
    refute_match(/⛔/, out)
  end

  private

    # Passing nil UNSETS CI_RUNNERS rather than setting it to empty. Those are different inputs and
    # the first two tests assert both, so IO.popen's env hash is the right instrument here — a
    # `ENV[...] = nil` in setup would leak into the parent process.
    def preflight(ci_runners, *args)
      out = IO.popen({ "CI_RUNNERS" => ci_runners }, [ SCRIPT, *args ],
                     err: [ :child, :out ], &:read)
      [ out, $?.exitstatus ]
    end
end
```

- [ ] **Step 2: Run it and verify it FAILS**

Run:
```bash
bin/rails test test/ci_preflight_test.rb
```
Expected: **7 errors** — `Errno::ENOENT`, no such file `ci/preflight.sh`.

- [ ] **Step 3: Write the script**

```bash
#!/usr/bin/env bash
# Which self-hosted runner families are available for this run?
#
# WHY THIS IS A DECLARATION AND NOT AN API CALL — do not "fix" this into `gh api`:
# listing self-hosted runners requires the `administration` permission, which is NOT among the
# permissions a workflow GITHUB_TOKEN can be granted. `gh api repos/:owner/:repo/actions/runners`
# 403s from inside Actions. It works from a developer shell only because a personal token carries
# admin scope — and ci/runners/README.md documents it that way, which is the trap. So the fleet is
# DECLARED in the repo variable CI_RUNNERS and read here.
#
# Usage:
#   ci/preflight.sh              # `family=true|false` lines, one per family, for $GITHUB_OUTPUT
#   ci/preflight.sh --summary    # a markdown report, for $GITHUB_STEP_SUMMARY
#
# THE DEFAULT IS DELIBERATELY CONSERVATIVE. An unset or blank CI_RUNNERS means "macos only", never
# "everything". A default of everything-available reproduces the exact bug this script exists to
# prevent: jobs scheduled against runners that do not exist, queueing for 24h before GitHub cancels
# them, at 0 elapsed, with no red signal anywhere. Five weeks of dark CI came from that.
#
# The summary deliberately does NOT enumerate the skipped JOBS. GitHub already lists them by name in
# the run, and a hand-maintained job list here would be a fourth thing to drift. What the summary
# owes the reader is the REASON and the declared value — so a stale declaration is visible at the
# point where it does damage.
set -euo pipefail

FAMILIES="macos linux windows"
DEFAULT="macos"

declared="${CI_RUNNERS:-}"
if [ -z "${declared//[[:space:]]/}" ]; then
  declared="$DEFAULT"
fi

# Lowercase, strip all whitespace, and wrap in commas on BOTH ends so a lookup matches a whole
# family name. Without the wrapping, a declared "linux-arm64" would satisfy a "linux" lookup and
# schedule x86 FUSE jobs onto an arm box.
normalised=",$(printf '%s' "$declared" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]'),"

available() {
  case "$normalised" in
    *",$1,"*) return 0 ;;
    *)        return 1 ;;
  esac
}

if [ "${1:-}" = "--summary" ]; then
  absent=""
  for family in $FAMILIES; do
    available "$family" || absent="$absent \`$family\`"
  done

  echo "## CI runner preflight"
  echo
  echo "Declared fleet (repo variable \`CI_RUNNERS\`): \`$declared\`"
  echo
  echo "| Runner family | Status |"
  echo "|---|---|"
  for family in $FAMILIES; do
    if available "$family"; then
      echo "| \`$family\` | ✅ available |"
    else
      echo "| \`$family\` | ⛔ **absent — its jobs were SKIPPED** |"
    fi
  done
  echo

  if [ -n "$absent" ]; then
    echo "> **This coverage was skipped, not passed.** Jobs requiring$absent were never scheduled,"
    echo "> so a green run here is green about less than a full run would be. The skipped jobs are"
    echo "> listed by name in this run's job list."
    echo ">"
    echo "> Register the runner (\`ci/runners/README.md\`) and add the family to the \`CI_RUNNERS\`"
    echo "> repo variable, or accept the gap knowingly."
  else
    echo "> Full fleet declared; no coverage skipped."
  fi
  exit 0
fi

for family in $FAMILIES; do
  if available "$family"; then
    echo "$family=true"
  else
    echo "$family=false"
  fi
done
```

- [ ] **Step 4: Make it executable and verify the tests pass**

```bash
chmod +x ci/preflight.sh
bin/rails test test/ci_preflight_test.rb
```
Expected: `7 runs, … 0 failures, 0 errors`.

Then check the two modes by hand, because the workflow consumes them literally:

```bash
CI_RUNNERS=macos ci/preflight.sh
```
Expected exactly:
```
macos=true
linux=false
windows=false
```

```bash
CI_RUNNERS="macos, linux" ci/preflight.sh --summary
```
Expected: a markdown table with `macos` and `linux` ✅, `windows` ⛔, and the "skipped, not passed"
note naming `` `windows` ``.

- [ ] **Step 5: Mutation-check the conservative default**

Change `DEFAULT="macos"` to `DEFAULT="macos,linux,windows"`, run the tests, and confirm the first two
tests go **RED**. Revert. A default that silently re-enables everything is the original bug, and this
is the assertion that stops it coming back.

- [ ] **Step 6: Commit**

```bash
git add ci/preflight.sh test/ci_preflight_test.rb
git commit -m "ci: add the runner preflight, extracted from YAML so it is testable

A job whose labels match no online runner does not fail — it queues for 24h at 0
elapsed and is then auto-cancelled, which is why CI was dark for five weeks with
no red signal. Gating those jobs off means never scheduling them.

The fleet is DECLARED in vars.CI_RUNNERS rather than queried: listing self-hosted
runners needs the administration permission, which a workflow GITHUB_TOKEN cannot
be granted, so the obvious gh-api implementation 403s on every run. The default is
macos-only; mutation-checked that widening it turns two tests red."
```

---

## Task 4: Retarget `ci.yml` at the Mac and route every job through `bin/ci`

**Files:**
- Modify: `.github/workflows/ci.yml` (whole file replaced)
- Modify: `test/ci_hygiene_test.rb` (add the job↔gate assertion)

- [ ] **Step 1: Write the failing test — add to `test/ci_hygiene_test.rb`**

Insert after the `"bin/ci defines every gate CI depends on"` test:

```ruby
  test "every ci.yml gate job invokes bin/ci with a gate that exists" do
    # The other direction of the contract. Task 2's test proves bin/ci DEFINES the gates; this
    # proves ci.yml USES them and does not hand-roll a command that can drift from the definition.
    # Without this, ci.yml could keep its own `bin/rails test` line and the single-source property
    # would quietly stop being true.
    gates = bin_ci_gates
    jobs  = YAML.load_file(WORKFLOW_DIR.join("ci.yml"), aliases: true).fetch("jobs")

    gate_jobs = jobs.except("preflight")
    assert gate_jobs.any?, "expected ci.yml to have gate jobs besides preflight"

    gate_jobs.each do |name, job|
      commands = Array(job["steps"]).filter_map { |s| s["run"] }
      invocations = commands.flat_map { |c| c.scan(%r{\bbin/ci\s+([a-z0-9-]+)}) }.flatten
      assert_equal 1, invocations.size,
                   "ci.yml job `#{name}` must invoke `bin/ci <gate>` exactly once, found " \
                   "#{invocations.inspect}"
      assert_includes gates, invocations.first,
                      "ci.yml job `#{name}` runs `bin/ci #{invocations.first}`, which config/ci.rb " \
                      "does not define"
    end
  end
```

- [ ] **Step 2: Run it and verify it FAILS**

```bash
bin/rails test test/ci_hygiene_test.rb -n /ci\.yml_gate_job/
```
Expected: **FAIL** — the current `ci.yml` jobs run `bin/rails db:test:prepare test` and
`bin/brakeman` directly, so `invocations` is empty and the `assert_equal 1` fails on the first job.

- [ ] **Step 3: Replace `.github/workflows/ci.yml` entirely**

```yaml
name: CI

on:
  pull_request:
    # Rails app only — skip on docs-only or client/** (Rust) changes (those gate via rust-client.yml).
    paths:
      - 'app/**'
      - 'config/**'
      - 'db/**'
      - 'lib/**'
      - 'test/**'
      - 'bin/**'
      - 'ci/**'
      - 'Gemfile'
      - 'Gemfile.lock'
      - '.ruby-version'
      - '.github/workflows/ci.yml'
  push:
    branches: [ main ]

# Serialize runs on the single self-hosted runner (a newer run cancels the older for the ref).
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

# EVERY JOB HERE RUNS ON macos, and that is a measurement rather than a preference. On the
# maker-mac box (2026-07-29): the suite is 1628 runs / 0F / 0E in 5.2s on all THREE LIBRARY_BACKEND
# values, test:system is 6/0/0 with headless Chrome, rubocop is clean over 435 files, and all three
# scanners exit 0. The serialisation worry that kept these on `linux` is measured away — the whole
# job set is ~30s of actual work, and wall-clock is dominated by checkout and bundle.
#
# NO `ruby/setup-ruby` ANYWHERE BELOW, deliberately: it assumes the GitHub-hosted /Users/runner
# layout this self-hosted Mac does not have (nightly.yml's e2e-macos already works around it). The
# runner's service PATH carries mise ruby 3.4.7 — exactly .ruby-version — so `bundle install` is
# all a job needs. test/ci_hygiene_test.rb fails if the action reappears in a macos job.
#
# EVERY JOB INVOKES `bin/ci <gate>` and never a bare command. config/ci.rb is the single definition
# of what each gate does; ci_hygiene_test asserts both directions of that contract.
jobs:
  # Which runner families exist for this run — see ci/preflight.sh for why this is a DECLARATION
  # (the repo variable CI_RUNNERS) and not an API call.
  #
  # The jobs in THIS workflow are not gated on it: they all run on macos, and if the mac runner were
  # absent this job could not start either, so gating them on it would be circular. The outputs are
  # consumed by the linux/windows jobs in rust-client.yml, nightly.yml and cross-os-e2e.yml. What
  # this job buys ci.yml is the SUMMARY — a run that states, on its own page, which coverage it did
  # not run.
  preflight:
    runs-on: [self-hosted, macos]
    outputs:
      macos:   ${{ steps.p.outputs.macos }}
      linux:   ${{ steps.p.outputs.linux }}
      windows: ${{ steps.p.outputs.windows }}
    steps:
      - uses: actions/checkout@v6
      - id: p
        name: Resolve the declared runner fleet
        env:
          CI_RUNNERS: ${{ vars.CI_RUNNERS }}
        run: ci/preflight.sh | tee -a "$GITHUB_OUTPUT"
      - name: Report what is available, and what was therefore skipped
        env:
          CI_RUNNERS: ${{ vars.CI_RUNNERS }}
        run: ci/preflight.sh --summary >> "$GITHUB_STEP_SUMMARY"

  # All three security scanners in ONE job, because they are one gate. They used to be two jobs
  # running brakeman then bundler-audit in sequence; brakeman exited 3 for weeks, so the job stopped
  # at step 1 and the audit gate NEVER RAN. `bin/ci scan` uses CI.step, which records a result and
  # continues, so all three report whatever any one of them does.
  scan:
    runs-on: [self-hosted, macos]
    steps:
      - uses: actions/checkout@v6
      - name: Install gems (the runner's own Ruby — see ci/runners/README.md)
        run: bundle install --quiet
      - name: Security scanners (gems, importmap, brakeman)
        run: bin/ci scan

  lint:
    runs-on: [self-hosted, macos]
    env:
      RUBOCOP_CACHE_ROOT: tmp/rubocop
    steps:
      - uses: actions/checkout@v6
      - name: Install gems (the runner's own Ruby — see ci/runners/README.md)
        run: bundle install --quiet
      - name: Prepare RuboCop cache
        uses: actions/cache@v5
        env:
          DEPENDENCIES_HASH: ${{ hashFiles('.ruby-version', '**/.rubocop.yml', '**/.rubocop_todo.yml', 'Gemfile.lock') }}
        with:
          path: ${{ env.RUBOCOP_CACHE_ROOT }}
          key: rubocop-${{ runner.os }}-${{ env.DEPENDENCIES_HASH }}-${{ github.ref_name == github.event.repository.default_branch && github.run_id || 'default' }}
          restore-keys: |
            rubocop-${{ runner.os }}-${{ env.DEPENDENCIES_HASH }}-
      - name: Lint code for consistent style
        run: bin/ci style

  test:
    runs-on: [self-hosted, macos]
    steps:
      - uses: actions/checkout@v6
      - name: Install gems (the runner's own Ruby — see ci/runners/README.md)
        run: bundle install --quiet
      - name: Ensure resvg (SVG→PNG for the preview tests)
        run: ci/ensure-resvg.sh
      - name: Run the suite (chunk backend)
        env:
          RAILS_ENV: test
        run: bin/ci test

  # The whole suite, run again with the share backend selected.
  #
  # This is NOT what stops the two adapters diverging — the shared adapter contract already does
  # that, and it runs against BOTH in the `test:` job above (chunk_test.rb and share_test.rb each
  # include FileLayerAdapterContract and construct their adapter explicitly, so they need no ENV).
  #
  # What this leg catches is narrower and otherwise invisible: tests that silently depend on the
  # AMBIENT backend. It earned its place immediately — it found nine of them (seven preview-job
  # tests, the maker file-bytes shim, and a previews API test), all building chunk-shaped fixtures
  # while taking their adapter from the environment, including one whose name claimed an adapter
  # it never pinned. Those are now pinned; this leg is what keeps the habit from creeping back.
  test-share-backend:
    runs-on: [self-hosted, macos]
    steps:
      - uses: actions/checkout@v6
      - name: Install gems (the runner's own Ruby — see ci/runners/README.md)
        run: bundle install --quiet
      - name: Ensure resvg (SVG→PNG for the preview tests)
        run: ci/ensure-resvg.sh
      - name: Run the suite (share backend)
        env:
          RAILS_ENV: test
        run: bin/ci test-share

  # The sibling of test-share-backend, buying the same narrow thing for the same reason.
  #
  # HONEST RESULT, unlike the share leg's: this one found ZERO ambient-dependent tests on the way
  # in — all three legs report an identical count. The share leg earned its place immediately by
  # finding nine; this one is a regression guard from birth, which is the outcome to expect once the
  # habit it enforces is already established. It stays because it costs a tmpdir-free run with no
  # external services, and because "nothing depends on the ambient backend" is exactly the kind of
  # claim that decays silently without a leg asserting it.
  #
  # NO EXTERNAL SERVICE, deliberately — see the comment on the `test-s3` gate in config/ci.rb.
  test-s3-backend:
    runs-on: [self-hosted, macos]
    steps:
      - uses: actions/checkout@v6
      - name: Install gems (the runner's own Ruby — see ci/runners/README.md)
        run: bundle install --quiet
      - name: Ensure resvg (SVG→PNG for the preview tests)
        run: ci/ensure-resvg.sh
      - name: Run the suite (s3 backend)
        env:
          RAILS_ENV: test
        run: bin/ci test-s3

  # The browser tier. Its own job so its cost stays visible as it grows, rather than inflating the
  # unit-test job. See test/system/README.md for what earns a place in it.
  system-test:
    runs-on: [self-hosted, macos]
    steps:
      - uses: actions/checkout@v6
      - name: Install gems (the runner's own Ruby — see ci/runners/README.md)
        run: bundle install --quiet
      - name: Run the system tests
        env:
          RAILS_ENV: test
        run: bin/ci system
      - name: Keep screenshots from failed system tests
        uses: actions/upload-artifact@v7
        if: failure()
        with:
          name: screenshots
          path: ${{ github.workspace }}/tmp/screenshots
          if-no-files-found: ignore
```

- [ ] **Step 4: Create `ci/ensure-resvg.sh`, replacing the inline step that could not fail**

The old step was `cargo install resvg --version 0.47.0 || true`, repeated in three jobs. Two
problems, and the second is the serious one: on a cold box that is a multi-minute from-source build,
and `|| true` makes a failure **silent** — the preview tests then branch on
`Maker::Previews::SvgRasterizer.available?` and quietly render `unsupported`, so the job stays green
while the PNG path it exists to exercise never runs.

```bash
#!/usr/bin/env bash
# Ensure `resvg` is on PATH for the preview tests (SVG/DXF/LightBurn → PNG).
#
# NON-FATAL BY DESIGN, but LOUD when it degrades. The preview tests branch on
# Maker::Previews::SvgRasterizer.available?, so a box without resvg still PASSES — it just renders
# `unsupported` and never exercises the real PNG path. The previous version of this step was
# `cargo install resvg || true`, which turned that into a silent downgrade: green, about less.
# That is the same shape as brakeman's exit 3 — a gate that is not a gate.
#
# Order is cheapest-first. brew has a bottled resvg (0.47.0, MPL-2.0); `cargo install` builds it
# from source and takes minutes on a cold box.
set -uo pipefail

if command -v resvg >/dev/null 2>&1; then
  echo "resvg: already present at $(command -v resvg)"
  exit 0
fi

if command -v brew >/dev/null 2>&1 && brew install resvg; then
  echo "resvg: installed via brew ($(command -v resvg))"
  exit 0
fi

if command -v cargo >/dev/null 2>&1 && cargo install resvg --version 0.47.0; then
  echo "$HOME/.cargo/bin" >> "${GITHUB_PATH:-/dev/null}"
  echo "resvg: installed via cargo"
  exit 0
fi

{
  echo "### ⚠️ resvg unavailable — preview coverage DEGRADED"
  echo
  echo "\`Maker::Previews::SvgRasterizer.available?\` is false on this runner, so the SVG, DXF and"
  echo "LightBurn preview tests render \`unsupported\` instead of exercising the real PNG path."
  echo
  echo "**This job is still green. It is green about less than you think.** Install resvg on the"
  echo "runner (\`brew install resvg\`) to restore the coverage."
} >> "${GITHUB_STEP_SUMMARY:-/dev/stderr}"

exit 0
```

```bash
chmod +x ci/ensure-resvg.sh
```

- [ ] **Step 5: Verify locally**

```bash
ci/ensure-resvg.sh
```
Expected on this Mac: `resvg: already present at /opt/homebrew/bin/resvg`, exit 0.

```bash
bin/rails test test/ci_hygiene_test.rb
```
Expected: `4 runs, 4 assertions, 0 failures, 0 errors` — the new job↔gate test now passes.

```bash
ruby -ryaml -e 'd = YAML.load_file(".github/workflows/ci.yml", aliases: true); puts d.fetch("jobs").keys.inspect'
```
Expected: `["preflight", "scan", "lint", "test", "test-share-backend", "test-s3-backend", "system-test"]`

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/ci.yml ci/ensure-resvg.sh test/ci_hygiene_test.rb
git commit -m "ci: run the Rails gates on the runner that actually exists

All 7 ci.yml jobs targeted [self-hosted, linux] while the only registered runner
is macOS, so every job queued forever — CI has had no successful run since
2026-06-24. Every gate is measured green on the Mac (1628/0F/0E on all three
backends, 6/0/0 system tests, rubocop clean, scanners 0/0/0), and the
serialisation worry is ~30s of work.

No ruby/setup-ruby: it assumes a /Users/runner layout this box lacks. Each job now
runs bin/ci <gate>, so there is one definition of each gate. resvg moves to a
script that reports loudly when it degrades instead of \`|| true\`."
```

---

## Task 5: Gate `rust-client.yml`, and free the Mac job its Linux gate was blocking

`changes` is `runs-on: [self-hosted, linux]` and **every other job `needs: changes`** — including
`mac-tests`, which targets the runner that is online. So the whole Rust workflow is dark because its
gate is. `changes` is `git diff` plus bash; it has no Linux dependency.

**Files:**
- Modify: `.github/workflows/rust-client.yml`
- Modify: `test/ci_hygiene_test.rb` (turn on the repo-wide gating assertion)

- [ ] **Step 1: Write the failing test — add to `test/ci_hygiene_test.rb`**

```ruby
  test "every linux or windows job is preflight-gated so it can never queue against a missing runner" do
    # THE CORE INVARIANT. A job whose labels match no online runner does not fail — it queues for
    # 24h at 0 elapsed and is then auto-cancelled, leaving mergeStateStatus UNSTABLE and the merge
    # needing --admin. That is how CI went dark on 2026-06-24 and stayed dark for five weeks.
    #
    # macos jobs are exempt: the preflight job itself runs on macos, so if that family were absent
    # the gate could not start either and gating a macos job on it would be circular.
    ungated = []
    each_static_job do |file, name, job|
      families = Array(job["runs-on"]).map { |l| l.to_s.downcase } & FAMILIES
      gated_families = families - [ "macos" ]
      next if gated_families.empty?

      needs = Array(job["needs"]).map(&:to_s)
      condition = job["if"].to_s
      gated_families.each do |family|
        unless needs.include?("preflight") &&
               condition.include?("needs.preflight.outputs.#{family}")
          ungated << "#{file}: job `#{name}` (#{family})"
        end
      end
    end
    assert_empty ungated,
                 "these jobs would QUEUE FOREVER if their runner family is absent — add " \
                 "`needs: preflight` and `if: needs.preflight.outputs.<family> == 'true'`:\n  " \
                 "#{ungated.join("\n  ")}"
  end
```

- [ ] **Step 2: Run it and verify it FAILS loudly**

```bash
bin/rails test test/ci_hygiene_test.rb -n /preflight_gated/
```
Expected: **FAIL** listing **21 jobs** — 12 linux and 9 windows across `rust-client.yml`,
`nightly.yml` and `cross-os-e2e.yml`. This test stays red until Task 6 completes; that is why Tasks 5
and 6 are one continuous stretch and the commit in Step 5 below notes it.

- [ ] **Step 3: Edit `.github/workflows/rust-client.yml`**

Change the `changes` job's runner and add the preflight job. Replace:

```yaml
jobs:
  changes:
    # Decide which jobs run. workflow_dispatch -> the chosen target; PR -> native git-diff by
    # component; push to main -> the full build matrix (no live smoke). No GitHub API / 3rd-party
    # action, so no token-permission surprises.
    runs-on: [self-hosted, linux]
```

with:

```yaml
jobs:
  # Which runner families exist for this run. See ci/preflight.sh — this is a DECLARATION (the repo
  # variable CI_RUNNERS), not an API call, because a workflow GITHUB_TOKEN cannot list runners.
  preflight:
    runs-on: [self-hosted, macos]
    outputs:
      macos:   ${{ steps.p.outputs.macos }}
      linux:   ${{ steps.p.outputs.linux }}
      windows: ${{ steps.p.outputs.windows }}
    steps:
      - uses: actions/checkout@v6
        with: { clean: false }
      - id: p
        name: Resolve the declared runner fleet
        env:
          CI_RUNNERS: ${{ vars.CI_RUNNERS }}
        run: ci/preflight.sh | tee -a "$GITHUB_OUTPUT"
      - name: Report what is available, and what was therefore skipped
        env:
          CI_RUNNERS: ${{ vars.CI_RUNNERS }}
        run: ci/preflight.sh --summary >> "$GITHUB_STEP_SUMMARY"

  changes:
    # Decide which jobs run. workflow_dispatch -> the chosen target; PR -> native git-diff by
    # component; push to main -> the full build matrix (no live smoke). No GitHub API / 3rd-party
    # action, so no token-permission surprises.
    #
    # RUNS ON macos, NOT linux. This job is `git diff` plus bash — it has no Linux dependency — and
    # every other job in this workflow `needs:` it, INCLUDING mac-tests, which targets the runner
    # that is actually online. So a linux label here took the whole workflow down with the Linux
    # box, and moving it is what revives the hermetic Rust suite (fs-provider 192 tests,
    # sync-client, fs-cfapi, fs-fskit, the windows-gnu FFI cross-check, the native macOS build).
    runs-on: [self-hosted, macos]
```

Then, for **each** of the four linux jobs (`linux-build`, `engine-integration`,
`two-device-fuse-linux`) and the four windows jobs (`windows-build`, `windows-smoke`,
`cfapi-conformance`, `two-device-cfapi-windows`), add `preflight` to `needs:` and the family
condition to `if:`. Worked examples — apply the same shape to every one:

`linux-build`, currently:
```yaml
    needs: changes
    if: ${{ needs.changes.outputs.linux == 'true' }}
    runs-on: [self-hosted, linux]
```
becomes:
```yaml
    needs: [preflight, changes]
    if: ${{ needs.preflight.outputs.linux == 'true' && needs.changes.outputs.linux == 'true' }}
    runs-on: [self-hosted, linux]
```

`mac-tests`, currently `needs: changes`, becomes `needs: [preflight, changes]` with its `if:`
**unchanged** — it needs `preflight` only because `changes` now sits behind it in the graph, and per
Step 1's exemption a macos job is not gated on the macos output.

`windows-smoke`, currently:
```yaml
    needs: [changes, windows-build]
    if: ${{ needs.changes.outputs.smoke == 'true' }}
```
becomes:
```yaml
    needs: [preflight, changes, windows-build]
    if: ${{ needs.preflight.outputs.windows == 'true' && needs.changes.outputs.smoke == 'true' }}
```

`two-device-cfapi-windows`, currently:
```yaml
    needs: [changes, windows-build]
    if: ${{ needs.changes.outputs.twodev == 'true' }}
```
becomes:
```yaml
    needs: [preflight, changes, windows-build]
    if: ${{ needs.preflight.outputs.windows == 'true' && needs.changes.outputs.twodev == 'true' }}
```

`cfapi-conformance` takes the same shape as `windows-smoke` but with `needs.changes.outputs.conf`.
`engine-integration` and `two-device-fuse-linux` take `linux-build`'s shape with
`needs.changes.outputs.engine` and `needs.changes.outputs.twodev` respectively. `windows-build`
takes it with `needs.changes.outputs.windows` and the `windows` family.

- [ ] **Step 4: Verify the file parses and every job is wired**

```bash
ruby -ryaml -e '
d = YAML.load_file(".github/workflows/rust-client.yml", aliases: true)
d.fetch("jobs").each do |n, j|
  fams = Array(j["runs-on"]).map(&:to_s).join(",")
  printf("%-26s %-22s needs=%-34s if=%s\n", n, fams, Array(j["needs"]).join("+"), j["if"].to_s[0, 92])
end'
```
Expected: `preflight` and `changes` both on `self-hosted,macos`; every `linux`/`windows` job showing
`preflight` in `needs` and `needs.preflight.outputs.<family>` in `if`.

- [ ] **Step 5: Commit (the gating test is still red — Task 6 finishes it)**

```bash
git add .github/workflows/rust-client.yml test/ci_hygiene_test.rb
git commit -m "ci(rust): move the gate job off linux and preflight-gate the rest

changes was runs-on linux and EVERY other job needs it, including mac-tests, which
targets the one online runner — so a missing Linux box took down jobs that could
have run. changes is git diff plus bash and has no Linux dependency.

The repo-wide gating assertion lands here and is RED until nightly.yml and
cross-os-e2e.yml are converted in the next commit; it currently names 21 jobs."
```

---

## Task 6: Gate `nightly.yml` and `cross-os-e2e.yml`, turning the gating test green

**Files:**
- Modify: `.github/workflows/nightly.yml`
- Modify: `.github/workflows/cross-os-e2e.yml`

- [ ] **Step 1: Add the same `preflight` job to both workflows**

Insert as the **first** entry under `jobs:` in each file (identical to Task 5 Step 3's block,
including `with: { clean: false }` on the checkout, which both workflows use throughout):

```yaml
  # Which runner families exist for this run. See ci/preflight.sh — a DECLARATION (the repo variable
  # CI_RUNNERS), not an API call, because a workflow GITHUB_TOKEN cannot list runners.
  #
  # This matters most on a SCHEDULED workflow. Before the gate, the 08:00 and 08:30 crons fired daily
  # into a void: every job queued, GitHub cancelled them 24h later, and the run history filled with
  # `cancelled` at 24h0m0s. Now a scheduled run completes in seconds and says on its own page which
  # coverage it could not run.
  preflight:
    runs-on: [self-hosted, macos]
    outputs:
      macos:   ${{ steps.p.outputs.macos }}
      linux:   ${{ steps.p.outputs.linux }}
      windows: ${{ steps.p.outputs.windows }}
    steps:
      - uses: actions/checkout@v6
        with: { clean: false }
      - id: p
        name: Resolve the declared runner fleet
        env:
          CI_RUNNERS: ${{ vars.CI_RUNNERS }}
        run: ci/preflight.sh | tee -a "$GITHUB_OUTPUT"
      - name: Report what is available, and what was therefore skipped
        env:
          CI_RUNNERS: ${{ vars.CI_RUNNERS }}
        run: ci/preflight.sh --summary >> "$GITHUB_STEP_SUMMARY"
```

- [ ] **Step 2: Gate `nightly.yml`'s 11 non-macos jobs**

Five linux (`e2e-linux`, `fuser-mount-smoke-linux`, `stress-load-and-multifiletype-linux`,
`two-device-fuse-linux`, `mount-conformance`) and six windows (`windows-build`, `e2e-windows`,
`two-device-cfapi-windows`, `windows-smoke`, `cfapi-conformance`).

For a job with **no** existing `needs:` or `if:` (e.g. `e2e-linux`), add both:
```yaml
    needs: preflight
    if: ${{ needs.preflight.outputs.linux == 'true' }}
    runs-on: [self-hosted, linux]
```

For a job that **already has** `needs: windows-build` (e.g. `two-device-cfapi-windows`), extend it:
```yaml
    needs: [preflight, windows-build]
    if: ${{ needs.preflight.outputs.windows == 'true' }}
    runs-on: [self-hosted, windows]
```

For a job that already has an `if:`, **conjoin** — never replace. E.g. if a job reads
`if: ${{ github.event_name == 'schedule' }}` it becomes
`if: ${{ needs.preflight.outputs.windows == 'true' && github.event_name == 'schedule' }}`. Read each
job's existing `if:` before editing; `grep -n "if:" .github/workflows/nightly.yml` lists them.

Leave the two macos jobs (`e2e-macos`, `two-device-webdav-macos`) alone — no `needs`, no `if`
change. They already run on the family the preflight itself requires.

- [ ] **Step 3: Gate `cross-os-e2e.yml` and move `seed` to macos**

`seed` is `curl` plus `cargo run --example pair_three_devices` — no Linux dependency — and every leg
`needs: seed`, so a linux label there hangs the whole workflow. Change:

```yaml
  seed:
    runs-on: [self-hosted, linux]
```
to:
```yaml
  seed:
    # RUNS ON macos, not linux: this is curl + `cargo run --example`, and every leg below needs it,
    # so a linux label here hung the entire workflow on a box that no longer exists.
    #
    # NOTE the server-reachability caveat this does not fix: seed curls the deployed server at
    # $SERVER_URL and treats an unreachable one as BLOCKED (exit 0, clean skip). From the Mac,
    # `curl http://192.168.1.95/up` returns 404 — kamal-proxy routes by Host header, so a bare-IP
    # request matches no route. Do not claim cross-OS reachability from this runner without
    # re-testing with the right Host.
    needs: preflight
    runs-on: [self-hosted, macos]
```

Then gate the two linux legs (`linux-edit`) and the two windows legs (`win-push`, `win-pull-2`),
conjoining with their existing `needs:` chains. `win-push`, currently `needs: seed`, becomes:

```yaml
    needs: [preflight, seed]
    if: ${{ needs.preflight.outputs.windows == 'true' }}
```

`linux-edit`, currently `needs: [seed, win-push, mac-pull-1]`, becomes:

```yaml
    needs: [preflight, seed, win-push, mac-pull-1]
    if: ${{ needs.preflight.outputs.linux == 'true' }}
```

`mac-pull-1` (`needs: [seed, win-push]`) and `mac-pull-2` (`needs: [seed, linux-edit]`) get
`preflight` prepended to `needs` and **no** `if:` — macos jobs are exempt.

**Note the consequence and do not treat it as a bug:** with only `macos` declared, `win-push` skips,
so `mac-pull-1` — which `needs:` it — will also skip. A `needs:` on a skipped job skips the
dependent. That is correct: `mac-pull-1` asserts it can read what Windows wrote, and with no
Windows there is nothing to read. The point of this change is that the workflow now *completes and
says so* in seconds instead of hanging for 24 h.

- [ ] **Step 4: Verify the gating test is now GREEN**

```bash
bin/rails test test/ci_hygiene_test.rb
```
Expected: `5 runs, 5 assertions, 0 failures, 0 errors`.

```bash
ruby -ryaml -e '
%w[ci rust-client nightly cross-os-e2e].each do |w|
  YAML.load_file(".github/workflows/#{w}.yml", aliases: true).fetch("jobs").each do |n, j|
    fam = (Array(j["runs-on"]).map(&:to_s) & %w[linux windows macos]).first
    printf("%-14s %-34s %-8s needs=%-38s if=%s\n", w, n, fam, Array(j["needs"]).join("+"), j["if"].to_s[0, 60])
  end
end'
```
Expected: every `linux`/`windows` row has `preflight` in `needs` and `needs.preflight.outputs.…` in
`if`; every `macos` row has no family condition.

- [ ] **Step 5: Mutation-check the invariant**

Remove the `if:` line from one windows job in `nightly.yml`, run the test, and confirm it goes
**RED** naming that job. Revert and re-confirm green.

- [ ] **Step 6: Run the full suite and commit**

```bash
bin/ci test
```
Expected: 1628+ runs, 0 failures, 0 errors.

```bash
git add .github/workflows/nightly.yml .github/workflows/cross-os-e2e.yml
git commit -m "ci: preflight-gate every linux and windows job

Closes the queue-forever failure across all four automatic workflows: 21 jobs are
now if-gated on a declared runner family, so a job whose runner is absent is never
SCHEDULED and cannot queue. The nightly and cross-OS crons stop firing into a void
— they complete in seconds and state which coverage they skipped.

cross-os-e2e's seed also moves off linux for the same reason rust-client's changes
did: every leg needs it, so a linux gate hung the whole workflow.

build-app.yml and install-app-on-runners.yml stay untouched, allowlisted in
ci_hygiene_test: both are workflow_dispatch-only with dynamic-matrix runners, and
a human who pressed Run workflow is watching."
```

---

## Task 7: Set `CI_RUNNERS`, push, and verify a real green run

The first six tasks are unverified until GitHub runs them. This task is where the plan's central
claim gets tested.

- [ ] **Step 1: Set the repo variable**

```bash
gh variable set CI_RUNNERS --body "macos"
```

Verify:
```bash
gh variable list
```
Expected: `CI_RUNNERS  macos  …`

- [ ] **Step 2: Cancel the stale queue so the new run is readable**

11 runs are queued, some for over 24 h, including 4 Dependabot PRs. They will never start.

```bash
gh run list --limit 100 --json databaseId,status,name \
  --jq '.[] | select(.status=="queued") | "\(.databaseId)\t\(.name)"'
```

Then cancel each:
```bash
gh run list --limit 100 --json databaseId,status --jq '.[] | select(.status=="queued") | .databaseId' \
  | while read -r id; do gh run cancel "$id" || true; done
```

Confirm none remain:
```bash
gh run list --limit 100 --json status --jq '[.[] | select(.status=="queued")] | length'
```
Expected: `0`

- [ ] **Step 3: Push the branch and watch the run**

```bash
git push -u origin HEAD
```

```bash
gh run watch "$(gh run list --workflow=ci.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
```

- [ ] **Step 4: Assert the outcome by STATUS, not by wall-clock**

```bash
gh run list --workflow=ci.yml --limit 1 --json conclusion,status,databaseId
```
Expected: `"status": "completed"`, `"conclusion": "success"` — **the first green CI run since
2026-06-24.**

```bash
gh run view "$(gh run list --workflow=ci.yml --limit 1 --json databaseId --jq '.[0].databaseId')" \
  --json jobs --jq '.jobs[] | "\(.conclusion)\t\(.name)"'
```
Expected: 7 jobs, all `success`, **none** `queued` or `skipped`.

- [ ] **Step 5: Check the Rust workflow's revived Mac job**

```bash
gh run view "$(gh run list --workflow=rust-client.yml --limit 1 --json databaseId --jq '.[0].databaseId')" \
  --json jobs --jq '.jobs[] | "\(.conclusion)\t\(.name)"'
```
Expected: `preflight` and `changes` **success**; `mac-tests` **success** (this is the job that has
been blocked by its own gate — expect ~192 fs-provider tests to run); every linux/windows job
**skipped**, never queued.

- [ ] **Step 6: Read the preflight summary**

Open the run's summary page (or `gh run view --web`) and confirm the markdown table renders with
`macos` ✅, `linux`/`windows` ⛔, the declared value echoed, and the "**This coverage was skipped, not
passed**" note. **If that note is missing, the run is lying and Task 3 is not done.**

- [ ] **Step 7: If anything is red, expect it here first**

Spec §2.5: the two backend legs and the resvg step were added after the last green run and have
**never executed once**. A failure in `test-share-backend`, `test-s3-backend` or `ci/ensure-resvg.sh`
is a five-week-old latent bug surfacing, not a regression this branch introduced. Debug it, fix it,
and note in the commit that it was pre-existing.

---

## Task 8: The browser-tier harness and its admission policy

Both existing system tests hand-roll the same sign-in, including the same non-obvious wait, and both
record why in a comment. That is the signal to extract it.

**Files:**
- Create: `test/system/support/web_helpers.rb`
- Create: `test/system/README.md`
- Modify: `test/application_system_test_case.rb`

- [ ] **Step 1: Write the harness**

`test/system/support/web_helpers.rb`:

```ruby
# Shared setup for the browser tier. Extracted because sheet_grid_test and tray_layout_test both
# hand-rolled the same six lines, including the same non-obvious wait, and both explained it in a
# comment — the third copy is the one to avoid writing.
module WebHelpers
  PASSWORD = "correct horse battery staple".freeze

  # Creates a confirmed user and signs in THROUGH THE FORM, then waits for Turbo to actually follow
  # the redirect.
  #
  # THE `assert_current_path` IS NOT DECORATION — do not delete it as a redundant assertion. Without
  # it the next `visit` races the login redirect, arrives before the session cookie is set, and 401s
  # into the login page, which reads exactly like the page under test failing to render. Both
  # existing system tests hit this and both documented it.
  #
  # Signs in through the form rather than via a Warden test helper on purpose: a system test that
  # bypasses the real session path can pass while login itself is broken.
  def sign_in_as(email = "maker@example.com")
    user = User.create!(email:, password: PASSWORD, confirmed_at: Time.current)
    visit new_user_session_path
    fill_in "user[email]",    with: email
    fill_in "user[password]", with: PASSWORD
    click_on "Log in"
    assert_current_path "/files"
    user
  end

  # A project plus a library folder to upload into — the shape most of these tests need. Returns
  # [Maker::Project, Node], the folder being the leaf DIR NODE (not an id).
  #
  # Goes through Maker::LibraryFolder rather than creating a Node row directly, so the fixture uses
  # the same door the app does and cannot drift from it. That service is described in its own header
  # as "THE ONE PLACE the cross-backend folder-creation branch lives" — hand-rolling a node here
  # would bypass the port_writable? decision it exists to own, and would then behave differently
  # under `bin/ci test-share`.
  def project_with_folder(user, name: "Lamp", folder: "parts")
    project = user.maker_projects.create!(name:)
    # ensure_path! takes an ARRAY OF SEGMENTS and returns the leaf dir Node. There is no `mkdir`
    # class method on this service — verified against app/services/maker/library_folder.rb.
    folder_node = Maker::LibraryFolder.ensure_path!(user, [ folder ])
    [ project, folder_node ]
  end

  # Fails the test if the browser logged an error. Cheap, and it catches the whole class of bug
  # where a Stimulus controller throws, the DOM is left half-built, and the assertion below happens
  # to still pass — how the jspreadsheet async-factory bug rendered a permanently empty grid with no
  # error surfaced anywhere.
  #
  # VERIFIED NON-VACUOUS (2026-07-29), which is the only reason it is worth having. Rails' default
  # `driven_by :selenium, using: :headless_chrome` does not obviously enable browser logging, and a
  # helper that always reads [] is a FAKE GUARD in every test that calls it. Probed by provoking a
  # real uncaught error in the page: logs.get(:browser) returned one entry, level "SEVERE", message
  # "Uncaught ReferenceError: nonExistentFunctionCall is not defined". No extra `goog:loggingPrefs`
  # capability is needed.
  def assert_no_console_errors
    logs = page.driver.browser.logs.get(:browser).select { |l| l.level == "SEVERE" }
    assert_empty logs.map(&:message), "the browser logged errors"
  end
end
```

- [ ] **Step 2: Wire it into the base case**

`test/application_system_test_case.rb` becomes:

```ruby
require "test_helper"
require_relative "system/support/web_helpers"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1400 ]

  include WebHelpers
end
```

- [ ] **Step 3: Verify the two existing tests still pass unchanged**

They keep their own inline sign-in; the harness is additive. If including the module collided with
their `PASSWORD` constant this is where it shows.

```bash
bin/ci system
```
Expected: `6 runs, 28 assertions, 0 failures, 0 errors`.

- [ ] **Step 4: Prove `assert_no_console_errors` is not vacuous**

Three tests will lean on this helper, so confirm it *captures* rather than merely *runs*. Create a
throwaway test, run it, read the output, delete it:

```bash
cat > test/system/zz_scratch_logs_test.rb <<'RUBY'
require "application_system_test_case"

class ZzScratchLogsTest < ApplicationSystemTestCase
  test "a real browser error is captured" do
    visit new_user_session_path
    page.execute_script("setTimeout(function(){ nonExistentFunctionCall() }, 0)")
    sleep 1
    logs = page.driver.browser.logs.get(:browser)
    puts "CAPTURE severe=#{logs.count { |l| l.level == 'SEVERE' }} levels=#{logs.map(&:level).uniq.inspect}"
  end
end
RUBY
bin/rails test test/system/zz_scratch_logs_test.rb 2>&1 | grep CAPTURE
rm test/system/zz_scratch_logs_test.rb
```

Expected: `CAPTURE severe=1 levels=["SEVERE"]`. Confirmed on this box on 2026-07-29 — no
`goog:loggingPrefs` capability was needed. **If it reports `severe=0`, the helper is a fake guard**:
add `options.add_option("goog:loggingPrefs", { browser: "ALL" })` via a `driven_by` block in
`application_system_test_case.rb` and re-probe before writing any test that calls it.

Confirm the scratch file is gone:
```bash
ls test/system/
```
Expected: only `sheet_grid_test.rb` and `tray_layout_test.rb`.

- [ ] **Step 5: Write the policy**

`test/system/README.md`:

```markdown
# The browser tier

A system test costs **~932 ms**; a unit test costs **~3.2 ms** (measured 2026-07-29: 6 system
examples in 5.59 s, 1628 unit tests in 5.16 s). That is a factor of **294**. Without a rule this
tier either stays at six tests forever or grows until it dominates the suite — so:

> **A behaviour earns a system test if and only if it is observable only in a browser.**

## Qualifies

- Stimulus controller logic — DOM reading/writing, event wiring, `data-*` value plumbing
- Form-control semantics. `<input type="text">` silently strips newlines, which broke five box
  generators (one of them *silently*) and no server-side test could see it. That bug is why
  `tray_layout_test.rb` exists.
- Turbo visits, redirects and reloads. `<head>` merging on a Turbo visit is why the sheet grid
  needed `data-turbo-track="reload"`, and a direct `visit` is the one path where that bug does
  **not** reproduce.
- Rendered-HTML → JS contracts: does the view actually emit the attribute the controller reads?

## Does not qualify — keep these at the request level

Authorisation, persistence, the `FileLayer` port, and backend selection. They have cheap coverage
already: `test/integration/web` is 31 files, and the ambient-backend risk is covered by `ci.yml`'s
three `LIBRARY_BACKEND` legs.

**Do not re-run the three-backend matrix through the browser.** Pin one backend per test with
`pin_file_layer_backend` and let the port's own contracts do their job.

## Every test here is mutation-checked

Revert the behaviour the test pins and confirm it goes red — then say so in a comment, naming what
you reverted. This repo has already been bitten by a hermetic fake that shared the code's
misunderstanding and hid a silent data-loss bug behind 79/80 green tests. A test nobody has watched
fail is a test nobody should trust.

## Honest limits are better than false coverage

`modelviewer_controller.js` renders into a `<canvas>`, which is opaque to Capybara. The right test
asserts it mounts, requests the model URL, and logs no console error — **not** that geometry
appeared. A test that looks like it checks the render while checking nothing is worse than no test.
```

- [ ] **Step 6: Commit**

```bash
git add test/system/support/web_helpers.rb test/system/README.md test/application_system_test_case.rb
git commit -m "test(system): add the browser-tier harness and its admission policy

Both existing system tests hand-rolled the same sign-in including the same
non-obvious Turbo-redirect wait, and both explained it in a comment — extract it
before the third copy.

The README is the load-bearing half: at 294x the cost of a unit test this tier
needs a written rule for what it admits, or it either stays at six tests or eats
the suite."
```

---

## Task 9: System test — the chunk two-phase upload (spec §5.4 priority 1)

`uploader_controller.js` drives the **main deployment's** upload path and has zero browser coverage.
Its server endpoints have six request tests; the browser orchestration between them has none.

**This test can drive the real two-phase flow, bytes and all.** In test, `STORAGE_BACKEND` defaults
to `memory`, and `MemoryChunkStore` presigns to `PUT /dev/blobs/*key` — routes mounted
`unless Rails.env.production?`. Those are *relative* URLs, which is why the Rust integration suites
cannot follow them, but a browser on the same origin follows them fine. So the presigned PUT really
happens.

**Files:**
- Create: `test/system/uploader_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
require "application_system_test_case"

# The chunk two-phase presigned upload, driven through a real browser.
#
# WHY THIS IS THE FIRST TEST IN THE TIER: uploader_controller.js is the upload path of the product's
# MAIN deployment (LIBRARY_BACKEND=chunk) and had no browser coverage at all. Its three server
# endpoints have six request tests between them; the browser orchestration ACROSS them — hash the
# bytes, POST begin_upload, PUT to every presigned URL, POST finalize_upload, then attach — had
# none. Nothing server-side can see that sequence, because each request in it is individually valid.
#
# THE BYTES REALLY MOVE. In test STORAGE_BACKEND defaults to `memory`, and MemoryChunkStore presigns
# to PUT /dev/blobs/*key (mounted `unless Rails.env.production?`). Those URLs are RELATIVE — which
# is exactly why the Rust integration suites use STORAGE_BACKEND=local instead — but a browser on
# the same origin follows a relative URL without complaint. So this exercises the real transport,
# not a stub.
class UploaderTest < ApplicationSystemTestCase
  setup do
    # PINNED, not ambient: this test is chunk-shaped by construction (the two-phase flow IS
    # Sync::Commit), and under LIBRARY_BACKEND=share the view renders the other branch entirely —
    # a multipart form with no Stimulus controller — so the test would look for markup that is
    # legitimately absent. ci.yml runs the whole suite under all three backends.
    pin_file_layer_backend("chunk")
    Storage::ChunkStore.reset!
    @user = sign_in_as("uploader@example.com")
  end

  test "a file chosen in the browser lands in the library through the presigned two-phase flow" do
    visit files_path

    # /files renders an uploader in BOTH of its branches, and this test lands in the second one: with
    # no current project set, app/views/files/index.html.erb:80-90 renders the plain library uploader
    # — a <section data-controller="uploader"> carrying ONLY begin-url and finalize-url (no
    # attach-url, no redirect-url, no parent-node-id), so the file lands at the library root and the
    # controller finishes with window.location.reload() rather than a redirect. Nothing below depends
    # on which of those two it is; the assertions poll the database.
    #
    # If this selector is missing, capabilities.port_writable? came back true and the backend pin
    # above did not take — under share/s3 this branch renders a multipart form with no Stimulus
    # controller at all.
    assert_selector "[data-controller='uploader']"

    file = Rails.root.join("test/fixtures/files/sample.txt")
    # make_visible: the real input is `hidden` behind a styled label, so Capybara cannot attach to
    # it as-is. This unhides it for the duration of the attach only, which is the narrowest change
    # that lets a real file selection happen.
    attach_file(file, make_visible: "[data-uploader-target='input']")

    # The controller writes "Done." into its status target as the last thing it does before
    # navigating, so waiting on the NODE is what proves the whole chain finished rather than that
    # the fetch was merely dispatched.
    node = nil
    assert_eventually("the uploaded file never appeared in the library") do
      node = @user.nodes.find_by(name: "sample.txt", deleted: false)
      node.present?
    end

    # THE BYTES, not just the row. A node with a version but no reachable content is exactly what a
    # half-finished two-phase flow leaves behind — begin_upload creates the pending commit, and a
    # failed PUT or a missing finalize would still leave a name in the tree on a naive
    # implementation. Reading them back through the port is what distinguishes the two.
    expected = file.binread
    assert_equal expected, FileLayer.current.read(@user, node_id: node.node_id),
                 "the node exists but its bytes did not land — the presigned PUT or finalize failed"
    assert_equal expected.bytesize, node.current_version.size

    assert_no_console_errors
  end

  private

    # Polls a block until it is truthy. Capybara's waiting matchers only wait on the DOM, and what
    # matters here landed in the DATABASE. Same shape as sheet_grid_test's assert_persisted_cell,
    # and for the same reason.
    def assert_eventually(message, timeout: 15)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        return if yield
        flunk message if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.1
      end
    end
end
```

- [ ] **Step 2: Run it**

```bash
bin/rails test test/system/uploader_test.rb
```

Expected: **PASS.** If it fails, work through these in order — each is a real possibility, not a
hypothetical:

- **No `[data-controller='uploader']`** — the backend pin did not take. `/files` does host an
  uploader in both branches (verified at `app/views/files/index.html.erb:58` for the
  current-project one and `:80` for the plain library one), so a missing selector means
  `capabilities.port_writable?` answered true and the share/s3 multipart form rendered instead.
  Confirm with `bin/rails runner 'puts FileLayer.current.class'`.
- **The node never appears** — open `tmp/screenshots` and read the status text; the controller
  writes the fetch error into it. A `403` on `begin_upload` means CSRF: `chunk_upload.js` reads
  `meta[name="csrf-token"]`, so confirm the layout emits `csrf_meta_tags`.
- **The node appears but the bytes assertion fails** — the presigned PUT did not reach
  `/dev/blobs/*key`. Confirm `Storage::ChunkStore.current` is a `MemoryChunkStore` in the *server*
  process (a system test runs Rails in the same process as the test, so the `reset!` in `setup`
  applies) and that the route exists: `bin/rails routes | grep dev/blobs`.

- [ ] **Step 3: Mutation-check it — this is required, per `test/system/README.md`**

Break the flow in the browser and confirm the test catches it. In
`app/javascript/lib/chunk_upload.js`, comment out the finalize call:

```js
  // await postJSON(finalizeUrl, { commit_id: begin.commit_id })
```

Run the test. Expected: **RED** at `assert_eventually` — the commit never finalizes, so no node
appears. Restore the line, re-run, confirm green.

Then a second, sharper mutation: leave finalize in place but skip the chunk PUT loop. Expected:
**RED at the bytes assertion**, not at the node lookup — which is the whole reason that assertion
exists separately from the row check.

```bash
git diff --stat   # must be empty before committing
```

- [ ] **Step 4: Commit**

```bash
git add test/system/uploader_test.rb
git commit -m "test(system): cover the chunk two-phase upload in a real browser

uploader_controller.js is the upload path of the product's main deployment and had
zero browser coverage: its three endpoints have six request tests, the sequence
across them had none, and no server-side test can see that sequence because each
request in it is individually valid.

The bytes really move — MemoryChunkStore presigns to /dev/blobs/*key, and a
browser follows those relative URLs even though the Rust suites cannot.
Mutation-checked twice: dropping finalize reddens the node assertion, dropping the
chunk PUT reddens the bytes assertion."
```

---

## Task 10: System test — the model-bundle importer (spec §5.4 priority 2)

`test/integration/web/models_import_test.rb` says it outright: *"The actual in-browser unzip + byte
upload is manual-smoke only (no JS runner)."* This closes that.

**Files:**
- Create: `test/system/importer_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
require "application_system_test_case"
require "zip"

# The Printables-bundle importer, driven through a real browser: ONE file selection → JSZip unzips
# in the page → a Model is created with a folder map → every entry is uploaded through the chunk
# flow and attached with a server-derived role.
#
# models_import_test.rb covers the server sequence and says so plainly: "The actual in-browser
# unzip + byte upload is manual-smoke only (no JS runner)." This is that missing half. Nothing
# server-side can reach it — the zip is never POSTed anywhere (§15: no zip bytes reach Rails), so
# the unzip either happens in the browser or not at all.
#
# The zip is BUILT HERE rather than committed as a fixture: the interesting variable is the entry
# layout (nested dir, mixed roles, a dotfile), and a generated archive shows that layout in the
# source instead of hiding it in a binary.
class ImporterTest < ApplicationSystemTestCase
  setup do
    pin_file_layer_backend("chunk")   # chunk-shaped by construction — see uploader_test.rb
    Storage::ChunkStore.reset!
    @user = sign_in_as("importer@example.com")
    @zip = build_bundle
  end

  teardown { @zip&.close! }

  test "one zip selection becomes a model with its files unzipped in-browser and attached" do
    visit new_model_path

    assert_selector "[data-controller='importer']"
    fill_in "model[title]", with: "Articulated Dragon"
    attach_file(@zip.path, make_visible: "[data-importer-target='input']")

    # The controller summarises the selection BEFORE anything is uploaded. Asserting it first
    # separates "the unzip worked" from "the uploads worked" — if this passes and the next block
    # fails, JSZip is fine and the upload loop is not.
    assert_selector "[data-importer-target='summary']", text: /3 file/i

    click_on "Import"

    model = nil
    assert_eventually("the model was never created") do
      model = @user.maker_models.find_by(title: "Articulated Dragon")
      model.present?
    end

    # `file_attachments`, NOT `attachments` — verified against app/models/maker/model.rb:13, where it
    # is declared with an `-> { order(:position) }` scope.
    assert_eventually("not every bundle entry was attached") do
      model.file_attachments.reload.count == 3
    end

    names = model.file_attachments.map { |a| a.node.name }.sort
    assert_equal [ "dragon.stl", "instructions.pdf", "tail.stl" ], names

    # THE DOTFILE WAS SKIPPED. The controller drops entries whose basename starts with "." — macOS
    # puts __MACOSX/._foo in almost every real-world zip, and attaching those would litter every
    # imported model. Asserting the count alone would not catch it; asserting the names does.
    refute_includes names, ".DS_Store"

    # ROLES COME FROM THE SERVER, not from the browser. importer_controller.js has its own
    # extension→role table (a third hand-copy, already drifted twice — docs/STATUS.md), but only
    # node_id and cover are POSTed and Maker::FileAttachment.role_for re-derives authoritatively.
    # This pins that the persisted role is the server's answer, which is what makes the JS copy's
    # drift harmless.
    roles = model.file_attachments.to_h { |a| [ a.node.name, a.role ] }
    assert_equal "model",        roles.fetch("dragon.stl")
    assert_equal "model",        roles.fetch("tail.stl")
    assert_equal "instructions", roles.fetch("instructions.pdf")

    # NESTED PATHS BECAME REAL FOLDERS, not flattened names. tail.stl was at
    # tail_segments/tail.stl, so its node's parent must be a folder called tail_segments —
    # flattening would silently collapse a 40-part bundle into one directory.
    tail = model.file_attachments.find { |a| a.node.name == "tail.stl" }.node
    assert_equal "tail_segments", @user.nodes.find_by!(node_id: tail.parent_node_id).name

    assert_no_console_errors
  end

  private

    # A Printables-shaped bundle: a model at the root, a nested model, a PDF, and the macOS dotfile
    # that ships with nearly every real download.
    def build_bundle
      file = Tempfile.new([ "bundle", ".zip" ])
      file.close
      Zip::File.open(file.path, create: true) do |zip|
        zip.get_output_stream("dragon.stl")               { |io| io.write("solid dragon\nendsolid\n") }
        zip.get_output_stream("tail_segments/tail.stl")   { |io| io.write("solid tail\nendsolid\n") }
        zip.get_output_stream("instructions.pdf")         { |io| io.write(pdf_bytes) }
        zip.get_output_stream(".DS_Store")                { |io| io.write("\x00\x01junk") }
      end
      file
    end

    # A real (tiny) PDF rather than random bytes: the attach step dispatches
    # ExtractPdfMetadataJob for the `instructions` role, and handing it a non-PDF makes this test
    # fail inside a job for a reason that has nothing to do with importing.
    def pdf_bytes
      Rails.root.join("test/fixtures/files/sample.pdf").binread
    end

    def assert_eventually(message, timeout: 30)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        return if yield
        flunk message if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.1
      end
    end
end
```

- [ ] **Step 2: Reconcile the test against the real markup before running it**

The selectors, the field name, the button label, the route helper and the association names above
are written from `importer_controller.js`'s `static targets`/`static values` and from
`models_import_test.rb`. **Read the view and the model and fix any that differ** — do not adjust the
assertions to match whatever the app happens to do:

```bash
grep -rn "importer" app/views/models/ app/views/ | head -20
grep -n "static targets\|static values" app/javascript/controllers/importer_controller.js
bin/rails routes | grep -E "models#new|models#create"
```

**Already verified, do not re-derive:** the association is `model.file_attachments`
(`app/models/maker/model.rb:13`), roles come from `Maker::FileAttachment.role_for`
(`file_attachment.rb:53`, reading `ROLE_BY_EXT`), and `new_model_path` → `GET /models/new` exists.

**Still to check against the view:** the title field's exact `name` attribute, the submit button's
exact text, and whether the `summary` target renders a count in the form this asserts. Adjust the
*test mechanics*; keep every assertion's *intent*.

- [ ] **Step 3: Run it**

```bash
bin/rails test test/system/importer_test.rb
```
Expected: PASS. If the summary assertion passes but the attachment count never reaches 3, the unzip
is fine and the upload loop is failing — read the status target in `tmp/screenshots`.

- [ ] **Step 4: Mutation-check the two assertions that carry real weight**

In `app/javascript/controllers/importer_controller.js`, remove the dotfile guard:

```js
            if (!name) continue    // was: if (!name || name.startsWith(".")) continue
```
Run. Expected: **RED** on `refute_includes names, ".DS_Store"` (and on the count). Restore.

Then flatten the nesting — change `dir: parts.join("/")` to `dir: ""`. Run. Expected: **RED** on the
`tail_segments` parent assertion, and *green* everywhere else, which is exactly the point: the
flattening bug is invisible to every other assertion in the file. Restore.

```bash
git diff --stat   # must be empty
```

- [ ] **Step 5: Commit**

```bash
git add test/system/importer_test.rb
git commit -m "test(system): cover the in-browser bundle unzip and import

models_import_test.rb states the gap it is leaving: 'the actual in-browser unzip +
byte upload is manual-smoke only (no JS runner)'. No server-side test can reach it
— the zip bytes never leave the browser by design (§15).

Mutation-checked on the two assertions that carry weight: removing the dotfile
guard reddens the name list, and flattening nested entries reddens ONLY the
parent-folder assertion, which is why that one is written separately."
```

---

## Task 11: System test — the file menu (spec §5.4 priority 3)

`filemenu_controller.js` (97 lines) drives attach/move/rename from the Files page and touches
`Maker::MoveNode` and the collision-rename prompt. No browser coverage.

**Files:**
- Create: `test/system/file_menu_test.rb`

- [ ] **Step 1: Read the controller and the view first**

This is the one test in the plan whose interactions cannot be written accurately from the outside —
the menu's targets, actions and the rename prompt's mechanism (a `window.prompt`, an inline field, or
a dialog) determine the Capybara calls, and `window.prompt` in particular needs
`page.driver.browser.switch_to.alert` rather than `fill_in`.

```bash
cat app/javascript/controllers/filemenu_controller.js
grep -rn "filemenu" app/views/ | head -20
grep -rn "MoveNode\|collision" app/controllers/files_controller.rb app/services/maker/move_node.rb | head -20
cat test/integration/web/attach_auto_move_test.rb | head -40
```

- [ ] **Step 2: Write the failing test**

Write `test/system/file_menu_test.rb` covering exactly these three behaviours, in this order, using
the selectors and interaction mechanics discovered in Step 1:

1. **The menu opens and closes.** Click the menu trigger on a file row; assert the menu becomes
   visible. Click outside it; assert it hides. This is pure DOM/event wiring — the single cheapest
   thing in this controller to break and the least visible server-side.
2. **Attaching a file to a project moves it into the project folder.** Use
   `project_with_folder(@user)`, attach via the menu, then assert *both* that the attachment row
   exists **and** that the node's `parent_node_id` changed. The second assertion is the one with
   teeth: `Maker::AttachToProject` owns an attach-and-relocate policy, and an attach that records
   the link without relocating the bytes passes the first assertion alone.
3. **A name collision prompts rather than clobbering.** Create two files with the same basename in
   different folders, attach the second into the folder holding the first, and assert the rename
   prompt appears and that accepting it produces a node with the new name while **the original's
   bytes are unchanged**. Every backend here is current-state-only, so a silent clobber is the
   user's file permanently gone.

Structure it exactly as Tasks 9 and 10 do: `pin_file_layer_backend("chunk")` in `setup`,
`sign_in_as`, the same private `assert_eventually` helper, and `assert_no_console_errors` at the end
of each test.

**On the collision test:** if Step 1 shows the collision prompt is `window.prompt`, the interaction
is
```ruby
    alert = page.driver.browser.switch_to.alert
    alert.send_keys("bracket-v2.stl")
    alert.accept
```
and **not** `fill_in`. Chrome dismisses an unhandled prompt, so a test that ignores it reads as "the
rename silently did nothing".

- [ ] **Step 3: Run it**

```bash
bin/rails test test/system/file_menu_test.rb
```
Expected: 3 runs, 0 failures, 0 errors.

- [ ] **Step 4: Mutation-check each of the three**

- Break the outside-click handler in `filemenu_controller.js` (remove the document listener or its
  `disconnect`) → test 1 red on the close assertion.
- In `Maker::AttachToProject`, skip the relocate call → test 2 red on the `parent_node_id`
  assertion **and green on the attachment-row assertion**. Confirm both, because that asymmetry is
  the reason the second assertion is written.
- Make the collision path overwrite instead of prompting → test 3 red.

Restore after each and confirm `git diff --stat` is empty.

- [ ] **Step 5: Run the whole tier and commit**

```bash
bin/ci system
```
Expected: 6 existing + the new tests, 0 failures, 0 errors.

```bash
git add test/system/file_menu_test.rb
git commit -m "test(system): cover the file menu — open/close, attach-and-move, collision rename

filemenu_controller.js drives attach/move/rename and had no browser coverage. The
attach test asserts the node RELOCATED as well as that the attachment row exists:
AttachToProject owns an attach-and-relocate policy, and an attach that records the
link without moving the bytes passes the row assertion alone. Mutation-checked
that skipping the relocate reddens only the parent assertion."
```

---

## Task 12: Update the docs the spec names (§9)

Four documents currently assert things this branch made false. A stale open-list spends the next
reader's attention on finished work.

**Files:**
- Modify: `docs/STATUS.md`
- Modify: `CLAUDE.md`
- Modify: `ci/runners/README.md`

- [ ] **Step 1: Replace `docs/STATUS.md`'s "CI cannot run" section**

Find it:
```bash
grep -n "CI cannot run" docs/STATUS.md
```

Replace the whole section with a dated record of the new state. It must say:

- CI runs again on `[self-hosted, macos]`; the first green run since 2026-06-24 is **<run URL from
  Task 7>**.
- **Local verification is now one command: `bin/ci`.** Delete the 8-command hand-copied checklist
  and point at `bin/ci --list`. Keep the *reasoning* about exit codes — that is the durable lesson —
  and note that `CI.step` runs every scanner regardless of the others, which is the structural fix
  for brakeman's exit 3.
- The fleet is declared in the repo variable `CI_RUNNERS` (currently `macos`), and **a workflow
  `GITHUB_TOKEN` cannot list runners** — the `administration` permission is not grantable. Anyone
  who "fixes" the preflight into a `gh api` call will get a 403 on every run.
- Linux and Windows coverage is **skipped, not passed**: name what is not running (the FUSE mount
  path, `engine-integration`, `mount-conformance`, the two-device E2Es, every CfAPI job, and the
  cross-OS legs). Register a Linux runner on Unraid (`192.168.1.95`, SSH open, Docker host) and add
  `linux` to `CI_RUNNERS` to restore it.
- **Two known gaps left open on purpose:** `build-app.yml` and `install-app-on-runners.yml` each
  still have a linux `prepare` job and are not preflight-gated — both are `workflow_dispatch`-only
  with dynamic-matrix runners, so a human triggering them can see the queue. Manual runs of those
  two will hang until a Linux runner exists.

- [ ] **Step 2: Update `CLAUDE.md` §15**

The runner bullet already says only one runner is registered. Add:

- `ci.yml` targets `[self-hosted, macos]`; every linux/windows job is gated on `vars.CI_RUNNERS` via
  `ci/preflight.sh`.
- **`ruby/setup-ruby` must not be used in a macos job** — `test/ci_hygiene_test.rb` fails if it
  reappears.
- Local gates are `bin/ci`; `config/ci.rb` is the single definition and `test/ci_hygiene_test.rb`
  asserts `ci.yml` cannot drift from it.
- Keep the existing "verify with `gh api …/actions/runners` rather than trusting this line"
  instruction, and add that this only works from a **developer shell** — not from a workflow.

Correct the stale sentence in the same bullet that says all 7 `ci.yml` jobs "target linux and queue
forever". That is now false.

- [ ] **Step 3: Update `ci/runners/README.md`**

- At the verify command (`README.md:53`), add that it needs an **admin-scoped** token and therefore
  **cannot** be used from inside a workflow — with a pointer to `ci/preflight.sh` for why.
- Add a short "Adding a Linux runner on Unraid" section: `setup-linux.sh` is Debian/apt-shaped and
  Unraid is not, so the path is a container or a VM. State that registering the runner is only half
  the job — `CI_RUNNERS` must gain `linux` or every Linux job stays skipped:
  ```bash
  gh variable set CI_RUNNERS --body "macos,linux"
  ```
- Note that CHAIMDESK (Windows) is reachable on the LAN but unregistered, and that re-registering it
  needs the same two steps.

- [ ] **Step 4: Verify and commit**

```bash
bin/ci
```
Expected: every gate ✅ and `✅ Continuous Integration passed`.

```bash
grep -n "queue forever\|queues forever" CLAUDE.md docs/STATUS.md
```
Expected: no hit that still describes the *current* state as broken.

```bash
git add docs/STATUS.md CLAUDE.md ci/runners/README.md
git commit -m "docs: record the CI fix, and what is still skipped rather than passing

Replaces STATUS.md's 'CI cannot run' section and its hand-copied 8-command
checklist with bin/ci. Records the two facts most likely to be un-learned: a
workflow GITHUB_TOKEN cannot list runners (so the preflight declares rather than
queries), and ruby/setup-ruby does not work on the self-hosted Mac.

Names the Linux and Windows coverage that is now SKIPPED, not passed, and the two
workflow_dispatch-only workflows deliberately left ungated."
```

---

## Self-review

**Spec coverage.** §4.1 → Task 4. §4.2 → Tasks 5, 6. §4.3 → Tasks 3, 5, 6, 7. §4.4 (`bin/ci`) →
Task 2. §4.5 (schedules stay armed) → Task 6 Step 1's comment; no cron is edited. §5.1–5.3 → Task 8.
§5.4 priorities 1–3 → Tasks 9, 10, 11; priorities 4–6 are scoped out above with a reason. §5.5 →
Task 4's `system-test` job. §7 verification → Task 7, plus a mutation check in every test-writing
task. §9 docs → Task 12. §8's out-of-scope items are not implemented, as intended; the two
`workflow_dispatch` workflows are additionally recorded in Task 12 Step 1.

**Two known imperfections, stated rather than hidden.**

1. **Task 5 commits with a red test**, which Task 6 turns green. The alternative — one giant commit
   converting 21 jobs across three workflows — is worse to review and worse to bisect. The commit
   message says so explicitly.
2. **Task 11 is specified rather than fully written.** Its three behaviours, their assertions, the
   reason each assertion exists, and its mutation checks are all concrete, but the Capybara calls
   depend on facts only readable in `filemenu_controller.js` (notably whether the rename prompt is a
   `window.prompt`, which needs `switch_to.alert` and not `fill_in`). Guessing selectors and having
   the implementer "fix them up" is how a test drifts into asserting whatever the app already does.
   Step 1 is therefore a read step, and the assertions' *intent* is fixed even though their
   mechanics are not.

**Type/name consistency.** `assert_eventually(message, timeout:)` has the same signature in Tasks 9,
10 and 11. `bin_ci_gates`, `each_job`, `each_static_job`, `FAMILIES`, `WORKFLOW_DIR`,
`DYNAMIC_MATRIX_WORKFLOWS` and `REQUIRED_GATES` are each defined once in `test/ci_hygiene_test.rb`
(Tasks 1, 2, 4, 5) and referenced consistently. `ci/preflight.sh` emits `macos|linux|windows` and the
workflows read `needs.preflight.outputs.<same three>`. Gate names in `config/ci.rb` (`style`, `scan`,
`test`, `test-share`, `test-s3`, `system`) match `REQUIRED_GATES` and every `bin/ci <gate>` in
`ci.yml`. `sign_in_as`, `project_with_folder` and `assert_no_console_errors` are defined once in
`WebHelpers` and used as defined.

**Five corrections made inline during self-review.** Four were references to app API that does not
exist — the exact failure mode the "no placeholders" rule names, and none of them was findable by
reading the plan. Each was caught by checking the app:

1. **`Maker::LibraryFolder.mkdir` does not exist.** The API is
   `ensure_path!(user, segments)` — an array of segments — and it returns the leaf dir **Node**, not
   a node_id. Task 8's `project_with_folder` is corrected and now returns `[project, folder_node]`.
2. **`Maker::Model#attachments` does not exist.** It is `file_attachments`
   (`app/models/maker/model.rb:13`, scoped `-> { order(:position) }`). Corrected at all four call
   sites in Task 10 — the plan would have failed on its first run otherwise.
3. **`/files` renders its uploader in two different branches**, and Task 9 lands in the *second*
   (no current project → `files/index.html.erb:80`), which carries only `begin-url` and
   `finalize-url` and reloads rather than redirecting. The original draft asserted the selector with
   a speculative "if it isn't there, use the project page" fallback; the branch is now named and the
   fallback deleted.
4. **`assert_no_console_errors` could have been vacuous.** Rails' default `driven_by` does not
   obviously enable Chrome browser logging, and three tests lean on this helper. Probed: it captures
   a real uncaught error as `SEVERE`, no `goog:loggingPrefs` needed. Task 8 gained Step 4 so the
   implementer re-confirms rather than trusting this note, with the capability fix to apply if it
   ever reads `severe=0`.
5. Task 3's first draft of the `preflight` test helper inferred `--summary` from `caller_locations`,
   which breaks the moment a test is renamed. Rewritten to the plain form, with the flag passed
   explicitly at both call sites — and the draft removed rather than shown-then-corrected, since a
   plan that makes the implementer read a wrong version first is a plan that gets the wrong version
   typed in.

**Facts verified against the running app, so no task has to re-derive them:** `bin/ci` already exists
as the Rails 8.1 scaffold and currently passes in 14.15 s while omitting three gates; `rubyzip 3.4.0`
is available for Task 10's fixture; `brew info resvg` is a real bottled formula (0.47.0); Psych parses
a workflow's `on:` key as boolean `true`; `files_path`, `new_model_path` and `models_path` all exist;
`user.maker_projects` and `user.maker_models` are the correct associations; `/dev/blobs/*key` PUT/GET
are mounted `unless Rails.env.production?`, which is what lets Task 9 move real bytes.
