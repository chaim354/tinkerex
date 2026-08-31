# Moving CI to the Unraid box — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: this repo's `.claude/commands/execute-plan.md` is the
> default and overrides any generic subagent loop (CLAUDE.md §15). Batch by FILE, run independent
> tasks in PARALLEL, no spec-compliance stage. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move all seven CI jobs off the developer's MacBook onto four container runners on the
Unraid Docker host, deployed as a Portainer stack.

**Architecture:** A committed `ci/runner/Dockerfile` built natively on the box (x86_64) bakes Ruby
3.4.7, Chrome and all four preview binaries. `ops/ci-runner-stack.yml` runs four independent runner
services through Portainer. Two guards must change first or the move breaks them: `WorkerBudget`
reads the host's memory inside a container, and `ci_hygiene_test`'s preflight exemption is
hard-coded to `macos`.

**Tech Stack:** GitHub Actions self-hosted runners, Docker, Portainer 2.39.6, Ruby 3.4.7, Minitest.

**Design doc:** `docs/superpowers/specs/2026-08-31-ci-to-unraid-design.md`

---

## Sequencing — read this before starting

**The Linux runners must be ONLINE before the `ci.yml` change merges.** If `ci.yml` retargets every
job to `linux` while no Linux runner exists, that PR's own CI queues for 24h at 0 elapsed and is
auto-cancelled — the exact five-week-dark-CI failure `ci/preflight.sh` exists to prevent, inflicted
on the very PR that is supposed to fix it.

So the order is: **code guards (A) → committed artifacts (B) → the box, runners online (C) →
retarget `ci.yml` (D) → docs (E) → cutover (F).** `CI_RUNNERS` is set to `macos,linux` in Phase C
and narrowed to `linux` only in Phase F, so both families are declared during the transition.

**Task 7 is yours, not the agent's.** It mints a credential and places it in a secret store.

---

## File Structure

| file | disposition | responsibility |
|---|---|---|
| `test/support/worker_budget.rb` | modify | Add cgroup v2 reading ahead of `/proc/meminfo`. |
| `test/worker_budget_test.rb` | modify | Cases for a container limit, `max`, and an absent file. |
| `test/ci_hygiene_test.rb` | modify | Derive the preflight exemption; extend the fixture test. |
| `ci/preflight.sh` | modify | `DEFAULT` becomes `linux`. |
| `test/ci_preflight_test.rb` | modify | The two default assertions follow. |
| `ci/runner/Dockerfile` | **create** | The runner image: Ruby, Chrome, four preview binaries. |
| `ops/ci-runner-stack.yml` | **create** | Four runner services; the reviewable copy of what Portainer runs. |
| `.github/workflows/ci.yml` | modify | Seven jobs retargeted `macos` → `linux`. |
| `ci/runners/README.md` | modify | The Unraid container path becomes live; fix the .95/.146 error. |
| `CLAUDE.md` | modify | §15 CI bullets and §12.6. **Net line count must not rise** — see Task 10. |
| `test/application_system_test_case.rb` | modify | One stale premise in a comment. |

---

# Phase A — the two guards, before anything else

## Task 1: `WorkerBudget` reads the cgroup limit, not the host's memory

**Files:**
- Modify: `test/support/worker_budget.rb`
- Test: `test/worker_budget_test.rb`

**Why:** inside a container `/proc/meminfo`'s `MemTotal` reports the **host's** 33 GB whatever limit
the container carries, so `browser_workers` plans for 8 Chromes (~17 GB by this file's own measured
figures) in a container sized far smaller.

- [ ] **Step 1: Write the failing tests**

Add to `test/worker_budget_test.rb`, immediately before the `# --- the detector itself` divider:

```ruby
  # --- the cgroup limit, which is the only honest answer inside a container -------------------

  # /proc/meminfo's MemTotal reports the HOST's memory inside a container, whatever limit the
  # container carries. Measured on the CI box: 33.35 GB host, so browser_workers planned for 8
  # Chromes (~17 GB by this file's own figures) in a container sized far smaller.
  test "a cgroup limit below MemTotal is what total_memory_bytes reports" do
    with_cgroup(max: 8 * (1024**3)) do
      assert_equal 8 * (1024**3), WorkerBudget.total_memory_bytes
    end
  end

  # A container with no memory limit set writes the literal string "max". That is not a number and
  # must not be read as one — fall back to the platform figure, which is then correct.
  test "memory.max reading `max` falls back to the platform figure" do
    with_cgroup(max: "max") do
      assert_equal platform_total, WorkerBudget.total_memory_bytes
    end
  end

  # Bare metal, cgroup v1, or macOS: the file is simply not there.
  test "an absent memory.max falls back to the platform figure" do
    with_cgroup(max: :absent) do
      assert_equal platform_total, WorkerBudget.total_memory_bytes
    end
  end

  test "available is the limit minus what the cgroup is currently using" do
    with_cgroup(max: 8 * (1024**3), current: 3 * (1024**3)) do
      assert_equal 5 * (1024**3), WorkerBudget.available_memory_bytes
    end
  end

  # Never negative: memory.current can exceed memory.max transiently under reclaim.
  test "available floors at zero when current exceeds the limit" do
    with_cgroup(max: 8 * (1024**3), current: 9 * (1024**3)) do
      assert_equal 0, WorkerBudget.available_memory_bytes
    end
  end

  test "an unreadable memory.current leaves available at the whole limit" do
    with_cgroup(max: 8 * (1024**3), current: :absent) do
      assert_equal 8 * (1024**3), WorkerBudget.available_memory_bytes
    end
  end

  # THE BEHAVIOURAL ASSERTION, and the reason the four above are worth having. This is the number
  # that decides how many Chromes start.
  test "the worker count follows the container limit, not the host's memory" do
    with_cgroup(max: 8 * (1024**3)) do
      WorkerBudget.singleton_class.alias_method :__real_cores2, :processor_count
      WorkerBudget.define_singleton_method(:processor_count) { 36 }
      begin
        with_concurrent_suite(false) do
          assert_equal 2, WorkerBudget.browser_workers,
                       "8 GB of container budget at 4 GB per worker is 2, not the host's 8"
        end
      ensure
        WorkerBudget.singleton_class.alias_method :processor_count, :__real_cores2
      end
    end
  end
```

And add these two private helpers, immediately after the existing `swap_pidfile_dir`:

```ruby
    # REAL FILES AT SWAPPED CONSTANTS, matching with_pidfiles above rather than stubbing the reader.
    # The methods under test parse file contents, so stubbing the read away would assert nothing
    # about the parsing — which is where "max" and a trailing newline live.
    #
    # `:absent` points the constant at a path inside the tmpdir that is never created, which is the
    # honest way to model "not a container" — Errno::ENOENT through the real rescue.
    def with_cgroup(max:, current: nil)
      require "fileutils"
      require "tmpdir"
      dir = Dir.mktmpdir("worker-budget-cgroup")
      real_max, real_current = WorkerBudget::CGROUP_MEMORY_MAX, WorkerBudget::CGROUP_MEMORY_CURRENT

      max_path = File.join(dir, "memory.max")
      File.write(max_path, "#{max}\n") unless max == :absent
      swap_const(:CGROUP_MEMORY_MAX, max_path)

      current_path = File.join(dir, "memory.current")
      File.write(current_path, "#{current}\n") unless current.nil? || current == :absent
      swap_const(:CGROUP_MEMORY_CURRENT, current_path)

      yield
    ensure
      FileUtils.remove_entry(dir) rescue nil
      real_max && swap_const(:CGROUP_MEMORY_MAX, real_max)
      real_current && swap_const(:CGROUP_MEMORY_CURRENT, real_current)
    end

    # What this box would report with no cgroup limit in play — the fallback the two tests above
    # assert against. Read through the real reader with the constant pointed at nothing.
    def platform_total
      with_cgroup(max: :absent) { WorkerBudget.send(:platform_total_memory_bytes) }
    end

    # Generalised from swap_pidfile_dir, and for the same recorded reason: a constant assigned in a
    # `class << self` body belongs to the SINGLETON, so the remove_const must be sent to whichever
    # object actually owns it.
    def swap_const(name, value)
      owner = WorkerBudget.singleton_class.const_defined?(name, false) ? WorkerBudget.singleton_class : WorkerBudget
      owner.send(:remove_const, name)
      owner.const_set(name, value)
    end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
bin/rails test test/worker_budget_test.rb
```
Expected: FAIL — `NameError: uninitialized constant WorkerBudget::CGROUP_MEMORY_MAX`.

- [ ] **Step 3: Add the constants**

In `test/support/worker_budget.rb`, immediately after the existing `PIDFILE_DIR` assignment (and
**outside** `class << self` — the file already records that a constant assigned in a singleton-class
body belongs to the singleton, which is how `PIDFILE_DIR` shipped wrong once):

```ruby
  # WHERE A CONTAINER'S REAL MEMORY LIMIT LIVES (cgroup v2), READ BEFORE /proc/meminfo.
  #
  # MemTotal reports the HOST's memory inside a container, whatever limit the container carries. On
  # the CI box that is 33.35 GB, so the budget below planned for 8 browser workers — roughly 17 GB
  # by this file's own measured figures (~6.7 GB baseline + ~1.3 GB marginal) — inside a container
  # sized far smaller, and the suite is OOM-killed rather than merely slow.
  #
  # These are the questions the two readers already CLAIM to answer: how much memory may THIS
  # PROCESS use, and how much of it is left. On bare metal and on macOS the files are absent or read
  # `max`, so both fall through to exactly the behaviour they had before this existed.
  CGROUP_MEMORY_MAX     = "/sys/fs/cgroup/memory.max"
  CGROUP_MEMORY_CURRENT = "/sys/fs/cgroup/memory.current"
```

- [ ] **Step 4: Rename the existing platform readers and add the cgroup layer**

In `test/support/worker_budget.rb`, rename the two existing methods, keeping their bodies and
comments **exactly as they are**:

- `def available_memory_bytes` → `def platform_available_memory_bytes`
- `def total_memory_bytes` → `def platform_total_memory_bytes`

Then add these four methods immediately above them, inside `class << self`:

```ruby
    # The cgroup v2 memory limit in bytes, or nil when there is no limit to read: the file is absent
    # (bare metal, cgroup v1, macOS) or holds the literal "max" (a container with no limit set).
    # nil means "ask the platform", which is the pre-existing behaviour.
    def cgroup_limit_bytes
      raw = File.read(CGROUP_MEMORY_MAX).strip
      return nil if raw == "max"
      limit = Integer(raw, exception: false)
      limit if limit&.positive?
    rescue StandardError
      nil
    end

    # What the cgroup is using right now. nil when unreadable, which leaves `available` at the whole
    # limit — the same "a machine we cannot measure keeps the number it had" rule as everywhere else
    # in this file.
    def cgroup_used_bytes
      Integer(File.read(CGROUP_MEMORY_CURRENT).strip, exception: false)
    rescue StandardError
      nil
    end

    def total_memory_bytes
      cgroup_limit_bytes || platform_total_memory_bytes
    end

    def available_memory_bytes
      limit = cgroup_limit_bytes
      return platform_available_memory_bytes if limit.nil?

      used = cgroup_used_bytes
      used ? [ limit - used, 0 ].max : limit
    end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run:
```bash
bin/rails test test/worker_budget_test.rb
```
Expected: PASS, all examples, including the eight pre-existing ones.

- [ ] **Step 6: Mutation-check the guard (§15 — non-negotiable)**

Temporarily change `total_memory_bytes` to skip the cgroup layer:

```ruby
    def total_memory_bytes
      platform_total_memory_bytes
    end
```

Run:
```bash
bin/rails test test/worker_budget_test.rb
```
Expected: **RED** — "a cgroup limit below MemTotal is what total_memory_bytes reports" and "the
worker count follows the container limit" both fail. If either stays green, the test is not testing
what it claims. **Restore the method afterwards** and re-run to confirm green.

- [ ] **Step 7: Commit**

```bash
git add test/support/worker_budget.rb test/worker_budget_test.rb
git commit -m "MemTotal reports the host's memory inside a container, so read the cgroup first"
```

---

## Task 2: Derive the preflight exemption from preflight's own runner family

**Files:**
- Modify: `test/ci_hygiene_test.rb`

**Why:** `ungated_offenders` computes `families - ["macos"]`. Its own comment gives the reason —
*"the preflight job itself runs on macos… gating a macos job on it would be circular"* — which is
about **preflight's family**, not about macOS. Move preflight to Linux and the literal is wrong in
both directions.

- [ ] **Step 1: Write the failing fixture case**

In `test/ci_hygiene_test.rb`, add this test immediately after the existing
`test "the three runner checks read a planted map form, a bare box label, and setup-ruby"`:

```ruby
  # THE EXEMPTION FOLLOWS PREFLIGHT, RATHER THAN NAMING macos. The rule has always been "the family
  # preflight itself runs on cannot be gated on preflight, because it could not start either"; it
  # was WRITTEN as the literal `macos`, which was the same thing only for as long as preflight ran
  # there. With CI on the Unraid box preflight runs on linux, and the literal would exempt the wrong
  # family in both directions at once: six linux jobs carrying gates that protect nothing, and a
  # future macos job silently exempt from a gate it genuinely needs.
  test "the ungated check exempts whichever family preflight itself runs on" do
    with_workflows(<<~YAML) do |dir|
      jobs:
        preflight:
          runs-on: [self-hosted, linux]
          steps:
            - run: ci/preflight.sh
        ungated-linux:
          runs-on: [self-hosted, linux]
          steps:
            - run: bin/ci test
        ungated-macos:
          runs-on: [self-hosted, macos]
          steps:
            - run: bin/ci test
        gated-macos:
          runs-on: [self-hosted, macos]
          needs: preflight
          if: needs.preflight.outputs.macos == 'true'
          steps:
            - run: bin/ci test
    YAML
      named = ->(offenders) { offenders.map { |o| o[/job `([^`]+)`/, 1] }.uniq.sort }

      assert_equal %w[ungated-macos], named.call(ungated_offenders(dir)),
                   "with preflight on linux, linux jobs are the circular case and macos jobs are " \
                   "the ones that must carry a gate"
    end
  end

  # AND THE ORIGINAL DIRECTION STILL HOLDS, which is what proves the change is a generalisation
  # rather than a swap. Same fixture shape, preflight back on macos.
  test "the ungated check still exempts macos when preflight runs there" do
    with_workflows(<<~YAML) do |dir|
      jobs:
        preflight:
          runs-on: [self-hosted, macos]
          steps:
            - run: ci/preflight.sh
        ungated-macos:
          runs-on: [self-hosted, macos]
          steps:
            - run: bin/ci test
        ungated-linux:
          runs-on: [self-hosted, linux]
          steps:
            - run: bin/ci test
    YAML
      named = ->(offenders) { offenders.map { |o| o[/job `([^`]+)`/, 1] }.uniq.sort }

      assert_equal %w[ungated-linux], named.call(ungated_offenders(dir))
    end
  end

  # NO PREFLIGHT JOB AT ALL EXEMPTS NOTHING. The conservative direction: with nothing to be circular
  # about, every self-hosted job must carry its gate. A workflow that loses its preflight job must
  # not silently lose the protection along with it.
  test "a workflow with no preflight job exempts no family" do
    with_workflows(<<~YAML) do |dir|
      jobs:
        lonely-macos:
          runs-on: [self-hosted, macos]
          steps:
            - run: bin/ci test
        lonely-linux:
          runs-on: [self-hosted, linux]
          steps:
            - run: bin/ci test
    YAML
      named = ->(offenders) { offenders.map { |o| o[/job `([^`]+)`/, 1] }.uniq.sort }

      assert_equal %w[lonely-linux lonely-macos], named.call(ungated_offenders(dir))
    end
  end
```

- [ ] **Step 2: Run to verify they fail**

Run:
```bash
bin/rails test test/ci_hygiene_test.rb
```
Expected: FAIL — "the ungated check exempts whichever family preflight itself runs on" reports
`["ungated-linux"]` where `["ungated-macos"]` was expected, and "a workflow with no preflight job"
reports only `["lonely-linux"]`.

- [ ] **Step 3: Derive the exempt family**

In `test/ci_hygiene_test.rb`, add this helper immediately above `ungated_offenders`:

```ruby
    # The family the `preflight` job itself runs on — the one family that CANNOT be gated on
    # preflight, because a missing runner there stops preflight from starting too and the gate would
    # be circular. nil when there is no readable preflight job, which exempts nothing: with nothing
    # to be circular about, every job must carry its gate.
    #
    # DERIVED RATHER THAN NAMED. This was the literal `macos` for as long as preflight ran there,
    # and CLAUDE.md §15 records what a hand-maintained list costs every other place this repo kept
    # one.
    def preflight_family(dir)
      each_job(dir) do |_file, name, job|
        next unless name == "preflight"
        labels = runner_labels(job)
        return nil if labels == UNRESOLVABLE
        return (labels & FAMILIES).first
      end
      nil
    end
```

Then change the two lines in `ungated_offenders`. Replace:

```ruby
        gated_families = families - [ "macos" ]
```

with:

```ruby
        gated_families = families - [ exempt ].compact
```

and add, as the first line of the method body (before `ungated = []`):

```ruby
      exempt = preflight_family(dir)
```

Update `ungated_offenders`' doc comment — replace the sentence *"macos is exempt from the last of
those only: the preflight job itself runs on macos, so gating a macos job on it would be circular."*
with:

```ruby
    # WHICHEVER FAMILY PREFLIGHT ITSELF RUNS ON is exempt from the last of those, because a missing
    # runner in that family stops preflight from starting too and the gate would be circular. Read
    # from the preflight job rather than named, so it stays true when CI changes boxes — see
    # preflight_family.
```

- [ ] **Step 4: Run to verify they pass**

Run:
```bash
bin/rails test test/ci_hygiene_test.rb
```
Expected: PASS — including the pre-existing planted-fixture test, whose `preflight` job is on
`macos` and whose expectations are therefore unchanged.

- [ ] **Step 5: Mutation-check**

Revert `gated_families` to the hard-coded literal:

```ruby
        gated_families = families - [ "macos" ]
```

Run:
```bash
bin/rails test test/ci_hygiene_test.rb
```
Expected: **RED** on "exempts whichever family preflight itself runs on" and "a workflow with no
preflight job exempts no family". **Restore and re-run** to confirm green.

- [ ] **Step 6: Commit**

```bash
git add test/ci_hygiene_test.rb
git commit -m "The exempt family is preflight's own, not the literal macos it happened to be"
```

---

## Task 3: `ci/preflight.sh`'s conservative default becomes `linux`

**Files:**
- Modify: `ci/preflight.sh`
- Test: `test/ci_preflight_test.rb`

**Why:** with the exemption derived, linux jobs run whatever `CI_RUNNERS` says — the safety property
macOS jobs have today. But `--summary` reports `targeted && !available` as "**absent — its jobs were
SKIPPED**", so a blank `CI_RUNNERS` would produce a summary claiming the Linux jobs were skipped
while they in fact ran. This script exists so a stale declaration is visible where it does damage; a
summary that lies in the safe direction still lies.

- [ ] **Step 1: Update the two default assertions**

In `test/ci_preflight_test.rb`, in `test "an unset CI_RUNNERS declares macos ONLY — never
everything"`, rename it and change the expectation:

```ruby
  test "an unset CI_RUNNERS declares linux ONLY — never everything" do
    # The most important test in the file. A default of "assume everything is available" reproduces
    # the original bug exactly: jobs scheduled against runners that do not exist. The conservative
    # default is what makes a forgotten variable safe. It names LINUX because that is where this
    # repo's runners are (2026-08-31); the property under test is "one family, not all three".
    out, status = preflight(nil)
    assert_equal 0, status, out
    assert_equal "macos=false\nlinux=true\nwindows=false\n", out
  end
```

And in `test "an empty or whitespace CI_RUNNERS falls back to the same conservative default"`,
change both occurrences of the expected string to:

```ruby
      assert_equal "macos=false\nlinux=true\nwindows=false\n", out,
```

- [ ] **Step 2: Run to verify they fail**

Run:
```bash
bin/rails test test/ci_preflight_test.rb
```
Expected: FAIL — both default tests report `macos=true\nlinux=false\nwindows=false`.

- [ ] **Step 3: Change the default**

In `ci/preflight.sh`, change:

```sh
DEFAULT="macos"
```

to:

```sh
DEFAULT="linux"
```

And update the header paragraph. Replace *"An unset or blank CI_RUNNERS means "macos only", never
"everything"."* with:

```sh
# THE DEFAULT IS DELIBERATELY CONSERVATIVE: ONE FAMILY, NEVER ALL THREE. An unset or blank
# CI_RUNNERS means "linux only" — linux because that is where this repo's runners live since CI
# moved to the Unraid box (2026-08-31). A default of everything-available reproduces the exact bug
# this script exists to prevent: jobs scheduled against runners that do not exist, queueing for 24h
# before GitHub cancels them, at 0 elapsed, with no red signal anywhere. Five weeks of dark CI came
# from that.
```

- [ ] **Step 4: Run to verify they pass**

Run:
```bash
bin/rails test test/ci_preflight_test.rb
```
Expected: PASS. The other assertions in the file all pass `CI_RUNNERS` explicitly and are unaffected.

- [ ] **Step 5: Commit**

```bash
git add ci/preflight.sh test/ci_preflight_test.rb
git commit -m "The conservative default names the family we actually have runners for"
```

---

# Phase B — the committed artifacts

## Task 4: The runner image

**Files:**
- Create: `ci/runner/Dockerfile`

**Binary names are exact and each has an `available?` gate on PATH** —
`vipsthumbnail` (`VIPSTHUMBNAIL_BIN`), `resvg`, `pdfium` (`PDFIUM_BIN`, klippa pdfium-cli),
`stl-thumbnailer` (`STL_THUMBNAILER_BIN`). A missing one degrades that format to `unsupported`
silently, which is the condition this image exists to end.

- [ ] **Step 1: Write the Dockerfile**

```dockerfile
# The CI runner image for chaim354/tinkerex — built NATIVELY on the Unraid Docker host
# (192.168.1.146, x86_64), never cross-built on the ARM64 Mac. Emulated builds of Ruby, Chrome and a
# Rust crate are slow enough that nobody rebuilds, and an image nobody rebuilds drifts from this
# file — the same failure ops/kaneo-stack.yml's header describes for a compose file.
#
# Build:  ssh root@192.168.1.146 'docker build -t tinkerex-ci-runner:<tag> -f ci/runner/Dockerfile .'
# Deploy: ops/ci-runner-stack.yml, through Portainer.
#
# LICENSING (CLAUDE.md §9). myoung34/github-runner and actions/runner are MIT; resvg is MPL-2.0
# (already sanctioned in ci/ensure-resvg.sh); pdfium-cli is MIT wrapping BSD-3 pdfium;
# stl-thumbnailer is our own Apache-2.0. libvips is LGPL and Chrome is proprietary — NEITHER IS
# LINKED AND NEITHER IS SHIPPED: both are subprocesses on a build box, the same footing on which
# Maker::Previews::ImageThumb already shells out to the vipsthumbnail BINARY rather than binding
# ruby-vips (§14e). No artifact this repo distributes is affected; the Rails image is untouched.
#
# PINNED, NOT :latest — the same rule ops/kaneo-stack.yml states as its first deliberate departure
# from upstream. A floating base tag upgrades CI without anyone deciding to, and the first anyone
# would know is a green run that means something different.
FROM myoung34/github-runner:2.336.0

# The runner image is Ubuntu-based and runs jobs as the `runner` user. Everything below installs to
# a system path so that user can reach it without a login shell.
USER root

# ---------------------------------------------------------------------------------------------
# Base toolchain. lsof, curl and bash are NOT incidental: bin/ci test-chunk-remote's script uses
# `lsof -ti tcp:$PORT` as its leftover-process guard, two curl probes (/up and whoami) and
# ${PIPESTATUS[0]}, which is a bashism the gate deliberately depends on.
# ---------------------------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential git openssh-client curl ca-certificates lsof bash \
      libssl-dev zlib1g-dev libyaml-dev libffi-dev libreadline-dev \
      sqlite3 libsqlite3-dev \
      libvips-tools \
      xz-utils unzip \
 && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------------------------
# Ruby, via mise — the same manager the Mac runner used, so `.ruby-version` resolves the same way.
# Installed system-wide and shimmed onto PATH so `bundle install --quiet` is all a job needs, which
# is what every ci.yml job actually runs.
# ---------------------------------------------------------------------------------------------
ENV MISE_DATA_DIR=/opt/mise \
    MISE_CONFIG_DIR=/opt/mise \
    MISE_CACHE_DIR=/opt/mise/cache \
    PATH=/opt/mise/shims:/usr/local/cargo/bin:$PATH

RUN curl -fsSL https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh \
 && mise use --global ruby@3.4.7 \
 && mise reshim \
 && ruby --version | grep -q '3\.4\.7'

# ---------------------------------------------------------------------------------------------
# Chrome + chromedriver, for `bin/ci system` (driven_by :selenium, using: :headless_chrome).
# chromedriver is baked rather than left to Selenium Manager so a job never depends on a download
# at test time.
# ---------------------------------------------------------------------------------------------
RUN curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
      | gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg \
 && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" \
      > /etc/apt/sources.list.d/google-chrome.list \
 && apt-get update && apt-get install -y --no-install-recommends google-chrome-stable \
 && rm -rf /var/lib/apt/lists/*

RUN CHROME_VER="$(google-chrome-stable --version | grep -oE '[0-9]+(\.[0-9]+){3}')" \
 && curl -fsSL -o /tmp/chromedriver.zip \
      "https://storage.googleapis.com/chrome-for-testing-public/${CHROME_VER}/linux64/chromedriver-linux64.zip" \
 && unzip -j /tmp/chromedriver.zip 'chromedriver-linux64/chromedriver' -d /usr/local/bin \
 && rm /tmp/chromedriver.zip \
 && chmod +x /usr/local/bin/chromedriver \
 && chromedriver --version

# ---------------------------------------------------------------------------------------------
# THE FOUR PREVIEW BINARIES. Each has an `available?` gate on PATH, so a missing one degrades that
# format to `unsupported` and the suite stays GREEN about less — the condition this block ends.
# vipsthumbnail came from libvips-tools above; the other three are here.
#
# resvg is pinned to 0.47.0, matching ci/ensure-resvg.sh's own cargo fallback, so the two cannot
# disagree about which version this repo means.
# ---------------------------------------------------------------------------------------------
RUN curl -fsSL -o /tmp/resvg.tar.gz \
      "https://github.com/linebender/resvg/releases/download/v0.47.0/resvg-linux-x86_64.tar.gz" \
 && tar -xzf /tmp/resvg.tar.gz -C /usr/local/bin resvg \
 && rm /tmp/resvg.tar.gz \
 && chmod +x /usr/local/bin/resvg \
 && resvg --version

RUN curl -fsSL -o /usr/local/bin/pdfium \
      "https://github.com/klippa-app/pdfium-cli/releases/download/v0.2.0/pdfium-linux-x64" \
 && chmod +x /usr/local/bin/pdfium \
 && pdfium --help >/dev/null

# stl-thumbnailer is OUR crate (tools/stl-thumbnailer, Apache-2.0) and is ABSENT ON THE MAC RUNNER,
# so the STL preview path has never once run in CI. Building it here is the single largest coverage
# change in this move. Rust is installed for this build and kept, since rebuilding the crate is the
# only reason a future image change would need it.
ENV RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo
RUN curl -fsSL https://sh.rustup.rs | sh -s -- -y --no-modify-path --profile minimal

COPY tools/stl-thumbnailer /tmp/stl-thumbnailer
RUN cargo install --path /tmp/stl-thumbnailer --root /usr/local \
 && rm -rf /tmp/stl-thumbnailer \
 && stl-thumbnailer --version

# ---------------------------------------------------------------------------------------------
# BACK TO THE NON-ROOT RUNNER USER. Headless Chrome refuses to start as root without --no-sandbox,
# and dropping the sandbox is the wrong fix — running as an ordinary user keeps it.
# ---------------------------------------------------------------------------------------------
USER runner
```

- [ ] **Step 2: Verify the file parses as a Dockerfile before pushing it at the box**

Run:
```bash
docker build --check -f ci/runner/Dockerfile . 2>&1 | tail -20
```
Expected: no syntax errors reported. (`--check` does not execute the build; a real build happens on
the box in Task 6. A local ARM64 build would be emulated and is not worth the minutes.)

- [ ] **Step 3: Commit**

```bash
git add ci/runner/Dockerfile
git commit -m "The runner image bakes the four preview binaries, one of which CI has never had"
```

---

## Task 5: The Portainer stack

**Files:**
- Create: `ops/ci-runner-stack.yml`

- [ ] **Step 1: Write the stack**

```yaml
# The CI runner stack, deployed through Portainer (portainer.home, 2.39.6) on the Unraid box.
# Four self-hosted GitHub Actions runners for chaim354/tinkerex — CLAUDE.md §15.
#
# TWO HOSTS, AND CONFUSING THEM COSTS AN AFTERNOON — the same trap ops/kaneo-stack.yml records.
# Nginx Proxy Manager is 192.168.1.7, where the `*.home` wildcard resolves, INCLUDING
# portainer.home. Docker runs on 192.168.1.146 ("Tower", the Unraid host itself), so these
# containers live on .146. A THIRD address is in play here and is NOT this one: 192.168.1.95 is the
# Kamal VM (chunk/share/s3.tinkerex.local). ci/runners/README.md named .95 as the intended runner
# home until 2026-08-31; that was wrong, and it is the Kamal target, not the Docker host.
#
# THIS FILE IS NOT EXECUTED BY ANYTHING IN THIS REPO. Portainer holds the running copy; this is the
# reviewable one. Edit here, then paste into the stack editor — and when you change the running
# stack, change this file in the same breath. A committed file that has silently diverged from what
# runs reads as the truth and nothing can go red for it.
#
# THE ONE SECRET IS A PORTAINER STACK ENVIRONMENT VARIABLE, not a value in this file:
# RUNNER_ACCESS_TOKEN, a fine-grained PAT with repo administration:write on chaim354/tinkerex. It
# also lives in 1Password (§14g); nothing here is `export`ed.
#
# WHY A PAT AND NOT A REGISTRATION TOKEN. A registration token is single-use and expires in ~1h
# (ci/runners/README.md), which is the wrong shape for four containers that must re-register
# themselves across a host reboot. When the PAT expires, all four fail to register and every job
# queues — which looks exactly like "the box is down" and is fixed differently. See the README.
#
# FOUR SERVICES, NOT ONE WITH `replicas: 4`. Compose replicas share a volume definition, so four
# replicas would contend over one work directory and corrupt each other's checkouts. Four because
# ci.yml has seven jobs and the four heavy legs — test, test-s3, test-chunk-remote, system — then
# overlap instead of running serially. Eight was rejected: the Rails parallel runner forks per-core
# INSIDE each job, and eight concurrent suites oversubscribe a 36-core box in exactly the way
# test/sqlite_concurrency_test.rb is sensitive to.
#
# PORT 3002 DOES NOT COLLIDE ACROSS THESE FOUR. bin/ci test-chunk-remote boots a sync server on
# SYNC_PORT, but each container has its own network namespace, so four concurrent runs bind four
# distinct ports. The gate's own `lsof -ti tcp:$PORT | xargs kill -9` leftover guard correspondingly
# only ever sees its own container, which is what it wants.
#
# MEM_LIMIT IS LOAD-BEARING AND IS WHY test/support/worker_budget.rb READS THE CGROUP. Without that
# reader, /proc/meminfo inside these containers reports the HOST's 33.35 GB and the system gate
# plans for 8 browser workers (~17 GB) inside an 8 GB container. Change this number and that budget
# follows it; delete it and the suite plans for a box it does not have.

x-runner: &runner
  image: tinkerex-ci-runner:2026-08-31
  restart: unless-stopped
  environment:
    REPO_URL: https://github.com/chaim354/tinkerex
    ACCESS_TOKEN: ${RUNNER_ACCESS_TOKEN}
    RUNNER_SCOPE: repo
    # `linux` is the FAMILY label ci.yml's runs-on matches and ci/preflight.sh greps for;
    # `maker-unraid` is the BOX label. test/ci_hygiene_test.rb treats those as different things on
    # purpose — a job carrying only a box label names no family and is an offender.
    LABELS: self-hosted,linux,X64,maker-unraid
    DISABLE_AUTO_UPDATE: "true"
  mem_limit: 8g
  cpus: 8.0
  # SYS_PTRACE lets Chrome's own crash handling work; the sandbox itself is kept by running as the
  # non-root `runner` user (see the Dockerfile's final USER line), NOT by --no-sandbox.
  cap_add:
    - SYS_PTRACE
  security_opt:
    - seccomp:unconfined

services:
  runner-1:
    <<: *runner
    container_name: tinkerex-runner-1
    environment:
      RUNNER_NAME: tinkerex-unraid-1
    volumes:
      - runner1-work:/_work
  runner-2:
    <<: *runner
    container_name: tinkerex-runner-2
    environment:
      RUNNER_NAME: tinkerex-unraid-2
    volumes:
      - runner2-work:/_work
  runner-3:
    <<: *runner
    container_name: tinkerex-runner-3
    environment:
      RUNNER_NAME: tinkerex-unraid-3
    volumes:
      - runner3-work:/_work
  runner-4:
    <<: *runner
    container_name: tinkerex-runner-4
    environment:
      RUNNER_NAME: tinkerex-unraid-4
    volumes:
      - runner4-work:/_work

volumes:
  runner1-work:
  runner2-work:
  runner3-work:
  runner4-work:
```

> **Note for the implementer:** YAML merge keys (`<<: *runner`) do **not** deep-merge — a service's
> own `environment:` block **replaces** the anchor's entirely. Each service above therefore needs
> the anchor's five environment values repeated alongside its `RUNNER_NAME`. Expand them in Step 2
> rather than shipping the anchor form.

- [ ] **Step 2: Expand the environment blocks**

Replace each service's `environment:` with the full set, e.g. for `runner-1`:

```yaml
    environment:
      REPO_URL: https://github.com/chaim354/tinkerex
      ACCESS_TOKEN: ${RUNNER_ACCESS_TOKEN}
      RUNNER_SCOPE: repo
      LABELS: self-hosted,linux,X64,maker-unraid
      DISABLE_AUTO_UPDATE: "true"
      RUNNER_NAME: tinkerex-unraid-1
```

Repeat for `runner-2`, `runner-3`, `runner-4`, changing only `RUNNER_NAME`. Then remove
`environment:` from the `x-runner` anchor, leaving `image`, `restart`, `mem_limit`, `cpus`,
`cap_add` and `security_opt` there — those are scalars and lists that the merge key handles
correctly.

- [ ] **Step 3: Verify the compose file parses**

Run:
```bash
docker compose -f ops/ci-runner-stack.yml config >/dev/null && echo "compose OK"
```
Expected: `compose OK`. A warning about the unset `RUNNER_ACCESS_TOKEN` variable is expected and
correct — the value lives in Portainer, not here.

- [ ] **Step 4: Confirm each service got the full environment**

Run:
```bash
docker compose -f ops/ci-runner-stack.yml config | grep -c "REPO_URL"
```
Expected: `4` — one per service. A lower number means a merge key silently dropped an environment
block, which is the failure the note above describes.

- [ ] **Step 5: Commit**

```bash
git add ops/ci-runner-stack.yml
git commit -m "Four runner services, because compose replicas would share one work directory"
```

---

# Phase C — the box

## Task 6: Build the image on the Unraid host

**No files.** This runs against 192.168.1.146.

- [ ] **Step 1: Copy the build context to the box**

Run from the repo root:
```bash
git archive --format=tar HEAD | ssh root@192.168.1.146 'rm -rf /tmp/tinkerex-ci && mkdir -p /tmp/tinkerex-ci && tar -x -C /tmp/tinkerex-ci'
```
Expected: no output, exit 0. (`git archive` sends the committed tree only — no `.git`, no local
scratch files, and none of macOS's `" 2"`-suffixed duplicates CLAUDE.md §13 warns about.)

- [ ] **Step 2: Build**

Run:
```bash
ssh root@192.168.1.146 'cd /tmp/tinkerex-ci && docker build -t tinkerex-ci-runner:2026-08-31 -f ci/runner/Dockerfile .'
```
Expected: `naming to docker.io/library/tinkerex-ci-runner:2026-08-31`. Takes several minutes — Ruby
and the Rust crate are both compiled.

- [ ] **Step 3: Verify every baked binary is on PATH for the non-root runner user**

This is the step that proves the coverage claim. Run:
```bash
ssh root@192.168.1.146 'docker run --rm tinkerex-ci-runner:2026-08-31 bash -lc "ruby --version; for b in vipsthumbnail resvg pdfium stl-thumbnailer chromedriver google-chrome-stable sqlite3 lsof git; do printf \"%-20s \" \$b; command -v \$b || echo MISSING; done; whoami"'
```
Expected: `ruby 3.4.7`, a path for **every** binary with no `MISSING`, and `runner` (not `root`) as
the final line. A `MISSING` here is the whole reason this task exists — fix the Dockerfile and
rebuild rather than proceeding.

- [ ] **Step 4: Clean up the build context**

Run:
```bash
ssh root@192.168.1.146 'rm -rf /tmp/tinkerex-ci'
```

---

## Task 7: Mint the PAT and deploy the stack — **YOURS, NOT THE AGENT'S**

**This task mints a credential and places it in a secret store. Do it yourself.**

- [ ] **Step 1: Mint a fine-grained PAT**

On github.com → Settings → Developer settings → Fine-grained tokens. Scope it to
**`chaim354/tinkerex` only**, with **Repository permissions → Administration: Read and write**
(this is what runner registration requires). Set an expiry you will remember; note it.

- [ ] **Step 2: Store it in 1Password** alongside the repo's other credentials (§14g), so the
      Portainer value is not its only copy.

- [ ] **Step 3: Create the stack in Portainer**

At `http://portainer.home` → Stacks → Add stack → name **`ci-runners`** → paste the contents of
`ops/ci-runner-stack.yml` → under **Environment variables** add `RUNNER_ACCESS_TOKEN` with the PAT
→ Deploy.

- [ ] **Step 4: Tell the agent it is done**, so it can verify. Do not paste the token anywhere in
      the conversation.

---

## Task 8: Verify the fleet and declare both families

- [ ] **Step 1: Confirm four containers are running**

Verify through Portainer's Docker proxy (environment id **3**), not by trusting the deploy: a
Portainer mutation returns an empty body on success, which is indistinguishable from a swallowed
error.

Expected: four containers named `tinkerex-runner-1` … `-4`, all `running`.

- [ ] **Step 2: Confirm four runners are registered and ONLINE with GitHub**

Run:
```bash
gh api repos/chaim354/tinkerex/actions/runners --jq '.runners[] | "\(.name)\t\(.status)\t\(.labels | map(.name) | join(","))"'
```
Expected: five rows — the four `tinkerex-unraid-*` at `online` carrying
`self-hosted,linux,X64,maker-unraid`, plus the existing Mac runner. A container that is `running`
but absent here means the PAT was rejected; check `docker logs tinkerex-runner-1`.

- [ ] **Step 3: Declare BOTH families for the transition**

Run:
```bash
gh variable set CI_RUNNERS --body "macos,linux"
```

This is the bridge. `ci.yml` still targets `macos` at this point, and it must keep working until
Task 9 merges. Narrowing to `linux` happens in Task 13, after the retarget is live.

---

# Phase D — retarget CI

## Task 9: Move all seven jobs to linux

**Files:**
- Modify: `.github/workflows/ci.yml`

**Do not start this task until Task 8 Step 2 shows four online runners.** Retargeting before the
runners exist makes this PR's own CI queue for 24h.

- [ ] **Step 1: Replace every `runs-on`**

In `.github/workflows/ci.yml`, change all seven occurrences of:

```yaml
    runs-on: [self-hosted, macos]
```

to:

```yaml
    runs-on: [self-hosted, linux]
```

Add no `needs: preflight` or `if:` lines: with Task 2's derived exemption, `linux` is now the family
preflight itself runs on, so gating these on preflight would be the circular case the guard exempts.

- [ ] **Step 2: Replace the workflow's runner header comment**

The block beginning `# EVERY JOB HERE RUNS ON macos, and that is a measurement rather than a
preference.` is now false. Replace that paragraph (down to and including the sentence ending
`…dominated by checkout and bundle.`) with:

```yaml
# EVERY JOB HERE RUNS ON linux, on four container runners on the Unraid Docker host — see
# ops/ci-runner-stack.yml and ci/runner/Dockerfile. CI ran on a developer's own MacBook until
# 2026-08-31, one runner executing one job at a time, which is why the seven jobs below used to be
# serial and are now 4-wide.
#
# THE MOVE RAISED COVERAGE RATHER THAN LOWERING IT, which is the opposite of what changing OS
# usually does: `stl-thumbnailer` was ABSENT on the Mac runner, so Maker::Previews::Stl rendered
# `unsupported` and the STL preview path had never once run in CI. The image bakes it in along with
# vipsthumbnail, resvg and pdfium. Suite counts therefore differ from the Mac's history by design.
```

- [ ] **Step 3: Fix the concurrency comment**

Change:

```yaml
# Serialize runs on the single self-hosted runner (a newer run cancels the older for the ref).
```

to:

```yaml
# One run per ref at a time (a newer run cancels the older). The fleet is four runners, so the jobs
# WITHIN a run are 4-wide; this only stops two runs of the same ref overlapping.
```

- [ ] **Step 4: Update the `ruby/setup-ruby` note**

The header sentence beginning `# NO \`ruby/setup-ruby\` ANYWHERE BELOW, deliberately:` still holds
but for a changed reason. Replace that paragraph with:

```yaml
# NO `ruby/setup-ruby` ANYWHERE BELOW. test/ci_hygiene_test.rb would now PERMIT it — its exemption
# is "the labels prove this is not the Mac", which a linux job satisfies — so this is a choice, not
# a constraint: the runner image bakes mise ruby 3.4.7, exactly .ruby-version, so `bundle install`
# is all a job needs and no job spends time re-fetching a Ruby it already has.
```

- [ ] **Step 5: Run the guards**

Run:
```bash
bin/rails test test/ci_hygiene_test.rb test/ci_preflight_test.rb
```
Expected: PASS. If "every linux or windows job is preflight-gated" fails, Task 2 did not land — the
literal `macos` exemption is still in place.

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "Seven jobs move to the Unraid fleet, and the serial-runner comment goes with them"
```

---

# Phase E — the docs that go stale on merge

## Task 10: CLAUDE.md §15 and §12.6

**Files:**
- Modify: `CLAUDE.md`

> **HARD CONSTRAINT: `CLAUDE.md` is 1,355 lines and `test/docs_hygiene_test.rb`'s `MAX_LINES` is
> 1,355 — zero headroom.** The ceiling is a **ratchet**: lowering it as the file shrinks is
> sanctioned, raising it needs an argument in review. Aim for net-zero or net-negative. Check with
> `wc -l CLAUDE.md` before committing.

- [ ] **Step 1: Rewrite the two runner bullets in §15's `### CI` section**

Replace the bullet at line ~1295 beginning `- **RUNNERS ARE REGISTERED PER REPOSITORY, AND ALL THREE
REPOS NOW HAVE ONE — macOS ONLY.**` and the bullet at ~1303 beginning `- **\`ci.yml\`'s jobs target
\`macos\`…` with these two:

```markdown
- **RUNNERS ARE REGISTERED PER REPOSITORY. THIS REPO'S ARE FOUR LINUX CONTAINERS ON THE UNRAID
  BOX** — `ops/ci-runner-stack.yml`, image `ci/runner/Dockerfile`, on the Docker host **192.168.1.146**
  (NOT 192.168.1.7, which is NPM, and NOT 192.168.1.95, which is the Kamal VM). Measured 2026-08-31:
  four `tinkerex-unraid-*` online, labels `self-hosted,linux,X64,maker-unraid`. CI ran on a
  developer's own MacBook until then, one job at a time. **Re-measure rather than trusting this
  paragraph** — that is why it names a date. It needs an **admin-scoped** token: `administration` is
  not a permission a workflow `GITHUB_TOKEN` can be granted, so it **403s from inside Actions** and
  works only from a developer shell.
- **`ci.yml`'s jobs target `linux`, and it is the ONLY workflow here** since the cross-repo suites
  left (2026-08-25). The `if:`-gate on the repo variable **`CI_RUNNERS`** via `ci/preflight.sh` has
  nothing left to gate *in this repo* — linux is the family preflight itself runs on, so it is the
  circular case the guard exempts. **Keep the mechanism anyway**: it fixed a five-week outage, and
  the failure it prevents is silent. A job matching no online runner does **not** fail — it queues
  24 h at 0 elapsed and is auto-cancelled. Any future macos/windows job here MUST be
  `needs: preflight` + `if:`-gated; `test/ci_hygiene_test.rb` enforces it, deriving the exempt
  family from preflight's own `runs-on` rather than naming one. **Windows coverage is skipped, not
  passing.**
```

- [ ] **Step 2: Retarget the `ruby/setup-ruby` bullet**

Replace the bullet beginning `- **\`ruby/setup-ruby\` must NOT appear in a \`macos\` job**…` with:

```markdown
- **`ruby/setup-ruby` must NOT appear in a job that could be the Mac** — it assumes a hosted
  `/Users/runner` layout. The guard exempts a job whose labels prove otherwise, so a `linux` job may
  use it; none does, because the runner image bakes mise ruby 3.4.7 matching `.ruby-version` and
  `bundle install --quiet` suffices. `test/ci_hygiene_test.rb` guards this and four other workflow
  invariants.
```

- [ ] **Step 3: Update §12.6**

Change the §12 row:

```markdown
6. Linux and Windows CI coverage is skipped, not passing → `tinkerex#123`
```

to:

```markdown
6. Windows CI coverage is skipped, not passing (Linux landed 2026-08-31) → `tinkerex#123`
```

- [ ] **Step 4: Check the line ceiling**

Run:
```bash
wc -l CLAUDE.md
```
Expected: **1,355 or fewer**. If it is over, tighten the prose above — do not raise `MAX_LINES`. If
it came in under, lower `MAX_LINES` in `test/docs_hygiene_test.rb` to the new count and say so in
the commit message; that is the ratchet working as intended.

- [ ] **Step 5: Run the docs guard**

Run:
```bash
bin/rails test test/docs_hygiene_test.rb
```
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add CLAUDE.md test/docs_hygiene_test.rb
git commit -m "The runner paragraph names four Linux containers, and re-measures its own date"
```

---

## Task 11: `ci/runners/README.md`

**Files:**
- Modify: `ci/runners/README.md`

- [ ] **Step 1: Fix the labels table**

Change the macOS row's framing and add the Unraid row. Replace the table body with:

```markdown
| Box | Labels |
|---|---|
| **Unraid containers ×4 (live)** | `self-hosted, linux, X64, maker-unraid` |
| Linux (bare metal, unregistered) | `self-hosted, linux, maker-linux` |
| macOS (retired as a runner 2026-08-31) | `self-hosted, macos, maker-mac` |
| Windows (unregistered) | `self-hosted, windows, maker-windows` |
```

- [ ] **Step 2: Replace the "Adding a Linux runner on Unraid" section**

That section is written as a proposal and **names the wrong host** — 192.168.1.95 is the Kamal VM,
not the Docker host. Replace the whole section with:

```markdown
## The live runners: four containers on Unraid (since 2026-08-31)

CI runs on **four container runners on the Unraid Docker host, `192.168.1.146`** — the box Portainer
calls environment `3`. Not `192.168.1.7` (that is Nginx Proxy Manager, where `*.home` resolves,
including `portainer.home`) and **not `192.168.1.95`** (that is the Kamal VM the app deploys to).
This README named .95 until 2026-08-31; it was wrong.

- **Image:** `ci/runner/Dockerfile` — Ruby 3.4.7 via mise, Chrome + chromedriver, and all four
  preview binaries (`vipsthumbnail`, `resvg`, `pdfium`, `stl-thumbnailer`). Built **natively on the
  box**, never cross-built on the ARM64 Mac.
- **Stack:** `ops/ci-runner-stack.yml`, deployed through Portainer as stack `ci-runners`. Portainer
  holds the running copy; the file is the reviewable one, and the two change in the same breath.
- **Credential:** a fine-grained PAT (`chaim354/tinkerex`, Administration: read/write) as the
  Portainer stack variable `RUNNER_ACCESS_TOKEN`, also in 1Password.

### Rebuilding the image

```sh
git archive --format=tar HEAD | ssh root@192.168.1.146 \
  'rm -rf /tmp/tinkerex-ci && mkdir -p /tmp/tinkerex-ci && tar -x -C /tmp/tinkerex-ci'
ssh root@192.168.1.146 \
  'cd /tmp/tinkerex-ci && docker build -t tinkerex-ci-runner:<new-tag> -f ci/runner/Dockerfile .'
```

Then bump `image:` in `ops/ci-runner-stack.yml`, paste it into Portainer, and redeploy.

### When every job suddenly queues

Two causes look identical and are fixed differently:

1. **The PAT expired.** The containers are `running` but registered nowhere —
   `gh api repos/chaim354/tinkerex/actions/runners` lists none of them. Mint a new fine-grained PAT,
   update the Portainer stack variable, redeploy the stack.
2. **The box or the stack is down.** The containers are not running at all. Check Portainer.

`docker logs tinkerex-runner-1` distinguishes them in one command: a rejected credential says so.
```

- [ ] **Step 3: Fix the "Verify the runners are online" claim**

Replace `**As of 2026-07-29 only \`charless-MacBook-Pro-maker-mac\` is registered** — not all
three.` with:

```markdown
**As of 2026-08-31, four `tinkerex-unraid-*` Linux runners are registered and the Mac runner is
retired.** Linux and Windows *bare-metal* boxes remain unregistered; the Linux coverage comes from
the containers above, not from `setup-linux.sh`.
```

- [ ] **Step 4: Note that `setup-linux.sh` is not the live path**

Immediately above the "One-time setup" heading, add:

```markdown
> **`setup-*.sh` is not how this repo's CI runs any more.** The live runners are the Unraid
> containers described above. These scripts remain for a bare-metal or VM runner — `setup-linux.sh`
> is Debian/apt-shaped and will **not** run on Unraid itself, which is Slackware-based with a
> non-persistent root filesystem.
```

- [ ] **Step 5: Commit**

```bash
git add ci/runners/README.md
git commit -m "The README named the Kamal VM as the runner home, and the runners are containers"
```

---

## Task 12: The two comments whose premise is now false

**Files:**
- Modify: `test/application_system_test_case.rb`
- Modify: `test/support/worker_budget.rb`

Both assert *"the CI runner IS a developer's own Mac"*, and both use it as a **premise**, not decoration.
The conclusions stand; the reasons change.

- [ ] **Step 1: `application_system_test_case.rb`**

Replace the paragraph beginning `# THE CONTENTION IS THIS REPO'S ORDINARY CONFIGURATION, which is
why raising the budget is the right response…` with:

```ruby
  # THE CONTENTION WAS THIS REPO'S ORDINARY CONFIGURATION WHEN THIS WAS WRITTEN, and the headroom is
  # still right now that it is not. Until 2026-08-31 the CI runner WAS a developer's own Mac, so a
  # local `bin/ci` and a CI job shared one box; reproduced deliberately by running two browser
  # suites at once: **152 and 166 errors** across the pair, against 0 when either runs alone. CI now
  # runs on dedicated Unraid containers (ops/ci-runner-stack.yml), which removes that particular
  # collision — but four runners share one 36-core host, and the worker budget beside this is what
  # keeps them from each planning for an empty box. The 2 s default still has no headroom for a
  # five-step async chain, which is the reason that survives the move.
```

- [ ] **Step 2: `worker_budget.rb` — the header**

In the paragraph beginning `# DERIVED, NOT A LITERAL.`, replace the sentence `# and
\`docs/DEPLOY.md\`'s CI runner is a developer's own laptop today but need not stay one.` with:

```ruby
  # and this repo's CI runner WAS a developer's own laptop until 2026-08-31 and is now a container
  # with a cgroup memory limit — which is exactly the "next machine" that sentence anticipated, and
  # why the readers below consult the cgroup before /proc.
```

- [ ] **Step 3: `worker_budget.rb` — the `browser_workers` comment**

Replace the sentence `# That reached CI in milder form as BoxSectionsTest failing on two consecutive
PRs and passing on every re-run — the CI runner IS this Mac (§15), so a local \`bin/ci\` and a CI job
genuinely collide.` with:

```ruby
    # That reached CI in milder form as BoxSectionsTest failing on two consecutive PRs and passing on
    # every re-run, back when the CI runner WAS this Mac and a local `bin/ci` genuinely collided with
    # a CI job. CI moved to dedicated containers on 2026-08-31; the detector stays because four
    # runners still share one host, and because a developer's local suite still collides with itself.
```

- [ ] **Step 4: Replace the stale premise in the detector's own comment**

Replace `# The available-memory check above was a PROXY for "another browser suite is already
running", and on the box this repo actually runs on it is tripped permanently. Measured 2026-08-25:
\`system-test\` took 83-97s on NINE consecutive CI runs, median 84s, never once fast — because the CI
runner IS a developer's own Mac (§15) and macOS \`available\` (free + inactive) on a machine with
apps open never looks idle.` with:

```ruby
    # The available-memory check above was a PROXY for "another browser suite is already running",
    # and on the Mac runner it was tripped permanently. Measured 2026-08-25: `system-test` took
    # 83-97s on NINE consecutive CI runs, median 84s, never once fast — because the CI runner was a
    # developer's own Mac and macOS `available` (free + inactive) on a machine with apps open never
    # looks idle. So the budget returned **1** every time, the protection sat at maximum
    # permanently, and the cost was paid on every run including the vast majority with no second
    # suite anywhere.
```

...and delete the now-duplicated sentence beginning `# So the budget returned **1** every time` that
followed it.

- [ ] **Step 5: Verify nothing claims the Mac is the runner any more**

Run:
```bash
grep -rn "runner IS a developer\|runner IS this Mac\|CI runner is a developer's own laptop" test/ CLAUDE.md ci/
```
Expected: **no output**. Any hit is a premise this move falsified.

- [ ] **Step 6: Run the suite**

Run:
```bash
bin/rails test test/worker_budget_test.rb
```
Expected: PASS — comments only, but the file is the one Task 1 changed.

- [ ] **Step 7: Commit**

```bash
git add test/application_system_test_case.rb test/support/worker_budget.rb
git commit -m "Two comments rested on the runner being a Mac, and their conclusions outlive it"
```

---

# Phase F — verify, merge, cut over

## Task 13: Full gates, PR, then narrow the fleet

- [ ] **Step 1: Run every gate**

Run:
```bash
bin/ci
```
Expected: green. **Read the three backend legs' run counts** — `test` (share), `test-s3`,
`test-chunk-remote` — and confirm they match **each other**. Per §15 `bin/ci` prints them and never
compares them.

**Do not compare them against the Mac's history.** This move changes OS, architecture and available
binaries at once, and baking in `stl-thumbnailer` legitimately raises counts by un-skipping tests. A
structural difference *between the three legs* is still the real bug it always was;
`tinkerex#131`'s known ±2 assertion / ±1 skip flap still applies.

> `bin/ci test-chunk-remote` needs `../tinkerex-sync`. From a worktree, set `TINKEREX_SYNC_DIR` —
> see the memory note on this. Clone with
> `gh repo clone chaim354/tinkerex-sync ../tinkerex-sync` if absent.

- [ ] **Step 2: Push and open the PR**

Per CLAUDE.md §15 this is standing authorization on a `claude/*` branch once the gates are green.
Use `/finish-branch`. State in the PR body what was verified and what was not — specifically, that
the four-runner fleet was verified online but that **this PR's own run is the first real exercise of
the Linux jobs**.

- [ ] **Step 3: Watch this PR's own CI run land on the new fleet**

Run:
```bash
gh pr checks --watch
```
Expected: seven jobs, all green, and the run's job pages showing `tinkerex-unraid-*` as the runner.
**If any job sits at 0 elapsed, stop** — that is the queue-forever failure, and the fix is to check
the runners are still online, not to re-run.

Note the wall time of `system-test`. It was 83–97 s (median 84) on the Mac because `browser_workers`
returned 1 permanently. On a container with a correct cgroup reading it should return more than 1
and the gate should be materially faster. **If it is not, Task 1's fix is not working** and the run
is green about less than it appears.

- [ ] **Step 4: File the arc**

```bash
bin/log arc --from-pr <n>
```

`bin/log` exit code 3 means unreachable and the write was spooled — `bin/log status` exits 4 until
you file it. Exit 5 is a bug in `bin/log`; do not proceed.

- [ ] **Step 5: After merge — narrow the declared fleet**

```bash
gh variable set CI_RUNNERS --body "linux"
```

- [ ] **Step 6: After merge — deregister the Mac runner**

Get a removal token and deregister:

```bash
gh api -X POST repos/chaim354/tinkerex/actions/runners/remove-token --jq .token
```

On the Mac, stop and uninstall the service, then `./config.sh remove --token <that-token>`. Confirm:

```bash
gh api repos/chaim354/tinkerex/actions/runners --jq '.runners[] | "\(.name)\t\(.status)"'
```
Expected: **four rows**, all `tinkerex-unraid-*`, all `online`. No `charless-MacBook-Pro-maker-mac`.

- [ ] **Step 7: Close the arc**

```bash
bin/log close <n>
```

An arc never closes itself — the PRs are on GitHub, the record is a self-hosted Kaneo, and nothing
bridges them.

---

## Self-review notes

**Spec coverage.** §1 → Tasks 9, 13. §2 → measurements quoted into Tasks 6, 8, 13. §3 → Task 4
(including the licensing paragraph, in the Dockerfile header). §4 → Tasks 5, 7. §5 → Task 1. §6 →
Tasks 2, 3. §7 → Tasks 6, 8, 13. §8 → Tasks 10, 11, 12. §9's four risks: Chrome-as-root → Task 4's
final `USER runner` + Task 6 Step 3's `whoami` check; btrfs → observable in Task 13 Step 3's timing;
PAT expiry → Task 11 Step 2's two-causes section; §14e vacuity → Task 2's fixture cases.

**Known gap, stated rather than hidden.** The spec's btrfs small-file concern has no task: it is a
performance observation with no action until measured. Task 13 Step 3 is where it would show up.

---

## Corrections found during execution (2026-08-31)

**Recorded rather than edited into the tasks above.** Silently rewriting a task to look correct
would hide that the plan was wrong, which is the failure §15 names. Two of these were defects that
would have reached the box.

### Two real defects

1. **Task 5 specified Docker NAMED VOLUMES; they must be BIND MOUNTS onto the array.** Measured on
   192.168.1.146 after dispatch: `/var/lib/docker` is a **50 GB loop device with 20 GB free** (30 G
   used, 61%), holding 24 images / 19.74 GB and 74 volumes / 7.7 GB. Named volumes live inside that
   loop. Four runner work dirs — each a Rails checkout plus bundle plus a `tinkerex-sync` sibling —
   plus the ~5 GB image would crowd it, and **a full `docker.img` on Unraid takes down every
   container on the box, not just CI.** `/mnt/user` has 5.8 TB free and
   `/mnt/user/appdata` resolves to `/mnt/cache`, an NVMe pool with 365 GB free — faster as well as
   roomier. `ci/runners/README.md` had already said "with the runner's work dir on a persistent
   share"; the plan lost it. Corrected in `ops/ci-runner-stack.yml` with the figures in its header.

2. **The `chown` UID was wrong.** The correction above specified `1000:1000` from the usual
   first-user convention. Measured: `myoung34/github-runner:2.336.0` has
   `runner:x:1001:121::/home/runner:/bin/sh` — **uid 1001, gid 121**. A bind mount chowned to 1000
   leaves the non-root runner unable to write its own work dir, a first-boot failure that reads as a
   broken image. The Task 5 implementer wrote it as given but flagged it as confirm-don't-assume
   rather than asserting it, which is why it was caught before the deploy.

### One gap in coverage

3. **No task swept the guard's own body comment.** `test/ci_hygiene_test.rb` line ~227 read *"macos
   jobs are exempt: the preflight job itself runs on macos"* — the consequence stated as the rule,
   true only while preflight ran there. Task 2 changed the code; nothing was scheduled to change
   this sentence. Fixed in `c35cec2`. §14e's lesson generalises: when a change makes a rule
   derived rather than named, **grep for the prose that still names it**.

### Four inaccuracies with no consequence

4. Task 3 Step 1 says "both occurrences of the expected string"; that test has **one** assertion
   inside a two-element loop.
5. Task 2 Step 2's predicted failure output was short by one element — actual is
   `["preflight", "ungated-linux"]`, because the fixture's own preflight job is itself an ungated
   linux job under the literal.
6. Task 1 Step 5 says "the eight pre-existing" tests; there were **13** before the change, 20 after.
7. Task 12 Step 3's replacement text begins mid-line in the source, so applying it verbatim orphans
   `# header already warned about.`; the paragraph needs re-wrapping, keeping the wording.

### Task 6 took FIVE builds, and every failure was a defect in the plan's Dockerfile

None was findable statically: `docker build --check` passed every time and every pinned URL returned
200. Only running it on the real box surfaced any of them. Listed because the pattern is the lesson
— §14e's "checking beats reasoning", with the contribution being *probing* rather than thinking.

| # | failure | fix |
|---|---|---|
| 1 | `resvg: version 'GLIBC_2.32' not found` — the prebuilt needs 2.32/2.33/2.34 | build resvg from source, as `ci/ensure-resvg.sh` already falls back to |
| 2 | `pdfium: version 'GLIBC_2.34' not found` — **same cause, second binary** | the base was the bare `2.336.0` tag = **Ubuntu 20.04 Focal, glibc 2.31, EOL**. Moved to `2.336.0-ubuntu-noble` (24.04, glibc 2.39). Closing the class beat patching instances |
| 3 | `stl-thumbnailer --version` exit 1 — **the build was fine, the check was wrong**; the tool takes positional args only | render a generated tetrahedron, assert a non-empty PNG |
| 4 | `COPY test/fixtures/files/tetra.stl` not found — `.dockerignore` excludes `/test/` | generate the STL inline. **Do not add a `.dockerignore` exception**: that file is a §14c licensing guard |
| 5 | — | `cargo install` was **ignoring the committed `Cargo.lock`** ("Locking 37 packages to latest compatible versions"). Added `--locked`; `Maker::Previews::Stl` bumps `PAYLOAD_REVISION` *because the picture changed*, so a drifting renderer would change stored previews silently |

**A methodology error of mine is in there too:** the first build reported `BUILD_EXIT=0` while failing.
`docker build ... | tail -40` ran on the *remote* shell, which has no `pipefail`, so the status was
`tail`'s. That is exactly the trap `config/ci.rb` documents about `tee` and `${PIPESTATUS[0]}` in the
`test-chunk-remote` gate. Later builds propagate the real status explicitly.

**Disk, measured, and the reason the bind-mount correction mattered:** the box was 30 G used / 20 G
free; five builds took it to 41 G / 9.0 G (82%), 3.765 GB of that build cache. `docker builder prune
-af` returned it to 39 G / 12 G. The finished image is 4.39 GB. The rebuild recipe in
`ci/runner/Dockerfile` now carries the prune step and these figures.

### §7's success criterion for the WorkerBudget fix was itself wrong

The plan says: *"On a dedicated container with a correct cgroup reading it should return more than 1
and the gate should be materially faster. If it is not, §5's fix is not working."* **Measured: the
gate is SLOWER — 2m20.87s on the fleet against ~40s on the Mac — and the fix is working correctly.**

The arithmetic. `mem_limit: 8g` ÷ `BYTES_PER_BROWSER_WORKER` (4 GB) = **2 browser workers**, capped
by `cpus: 8.0`. The Mac has 24 GB and no cgroup, so it budgets 24 ÷ 4 = **6**. Two workers are
slower than six; that is the memory limit doing exactly what it was set to do.

**Where the criterion came from, and why it was stale.** It read the 83–97 s / median 84 s figure in
`worker_budget.rb` as the Mac's baseline. That figure is from *before* the 2026-08-25 pidfile fix,
when macOS `available` memory made the budget return **1 worker permanently**. After that fix the
Mac returns 6 and runs the gate in ~40 s. So the plan compared the container against a number the
Mac had not produced in a week — the same "a doc row that names a figure is a claim" problem §15
records, in a plan rather than a doc.

**Not treated as a defect, and the wall clock is why:** the whole run is ~3m30s across four runners
in parallel, against seven jobs serialized on one Mac before. If the browser gate alone ever needs
to be faster, the lever is `mem_limit` — but 4 × 8 GB already commits 32 of the box's 33 GB, so
raising it oversubscribes, and that is a deliberate decision rather than a tweak.

### Verified during execution, not assumed

- Containers on the box reach `github.com`, `api.github.com`, `objects.githubusercontent.com`,
  `rubygems.org` and `dl.google.com` on 443.
- Every Dockerfile pin resolves live, and `myoung34/github-runner:2.336.0` publishes a
  **linux/amd64** manifest — the right architecture for this host.
- The `with_cgroup` test helper nests correctly. Worth noting *how* that was established: the
  passing tests would **not** have proved it, because a helper that restored the real
  `/sys/fs/cgroup` path instead of the outer tmp path still falls through to the platform reader on
  macOS and still passes. It was driven directly instead.
