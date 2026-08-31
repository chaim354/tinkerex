require "test_helper"
require "tmpdir"

# Guards the CI invariants that live in .github/workflows/*.yml — files the Rails process never
# loads, so no other test in the suite can see them. Modelled on test/deploy_hygiene_test.rb, which
# guards deployment facts for the same reason.
#
# Each assertion here corresponds to something that has already gone wrong or that CLAUDE.md forbids
# outright. None of them is hypothetical:
#
#   * A GitHub-hosted runner is the only BILLED kind (§15: self-hosted is free, macOS-hosted is
#     10x). Nothing guarded this before, and "just use ubuntu-latest" is the first thing anyone
#     reaches for when a self-hosted runner is missing — which is exactly the situation this repo
#     is in. This asserts PRESENCE of the literal `self-hosted` label rather than pattern-matching
#     hosted image names: an earlier version matched `-latest`/`ubuntu-NN.NN`-shaped labels and
#     missed GitHub's LARGER hosted runners (`ubuntu-latest-4-cores`, `macos-latest-xlarge`), which
#     are still hosted and billed at a PREMIUM over the standard images, yet match neither pattern.
#     Do not revert to matching a name shape — see the test body for the full argument.
#   * `ruby/setup-ruby@v1` does not work on the self-hosted Mac — it assumes the hosted
#     /Users/runner layout. Every job here uses the runner's own Ruby instead. (The job that
#     documented this in a comment, nightly.yml's e2e-macos, left with the cross-repo suites on
#     2026-08-25 — docs/superpowers/specs/2026-08-25-cross-repo-ci-handoff.md.) Retargeting a
#     Rails job at macos while
#     keeping the action fails at step 2 of every job, on infrastructure rather than on code, which
#     is the least legible kind of red.
#   * `bin/brakeman` shipped the Rails scaffold's `ARGV.unshift("--ensure-latest")`, which made the
#     `scan` gate fail whenever a newer BRAKEMAN was published — red with zero warnings and no code
#     change. That is a second, INVISIBLE definition of what the gate runs, which is exactly what
#     config/ci.rb's "ONE definition per gate" header exists to prevent. See the binstub.
#
# The binstub checks below extend this file past .github/workflows/. They belong here anyway: a
# binstub is CI's actual entry point, the Rails process never loads it either, and the failure it
# caused was a gate result rather than a code result.
#
# The importmap checks at the bottom extend it once more, for the same reason in a different
# direction: config/importmap.rb IS loaded by the Rails process, but what those tests guard is a
# fact about how a dependency was VENDORED, which no runtime assertion can reach. A second copy of
# @codemirror/state does not raise, warn, or log — CodeMirror 6 matches facets and StateFields by
# OBJECT identity, so an extension built against copy A is silently ignored by a view built on copy
# B and the editor just renders without the feature. There is no red anything to observe. See
# bin/build-codemirror.
class CiHygieneTest < ActiveSupport::TestCase
  WORKFLOW_DIR = Rails.root.join(".github/workflows")

  # build-app.yml and install-app-on-runners.yml used to be exempt from the runner-family rules
  # below (DYNAMIC_MATRIX_WORKFLOWS): both were workflow_dispatch-ONLY and took their runner from a
  # dynamic matrix (`[self-hosted, "${{ matrix.runner }}"]`), which no static check can resolve —
  # the failure this file exists to prevent needs an AUTOMATIC trigger, and a human who pressed
  # "Run workflow" is watching. Both files left in the client/ extraction
  # (docs/superpowers/plans/2026-08-20-stage-1-extract-client.md) — they moved wholesale to
  # chaim354/tinkerex-client, since they build/stage only client/maker-app — so no workflow left in
  # THIS repo uses a dynamic matrix for `runs-on`, and the exemption (and each_static_job, which
  # existed only to apply it) went with them. If a future workflow here reintroduces one, restore
  # the exemption rather than papering over a real "queues forever" gap.

  # Every self-hosted family we may target. Anything else is either GitHub-hosted (billed), a BOX
  # label (`maker-linux`, `maker-mac`, `maker-windows` — every runner self-applies one, see
  # ci/runners/setup-*.sh), or a typo. A box label is NOT a family label: see runner_labels and the
  # preflight-gating check.
  FAMILIES = %w[macos linux windows].freeze

  # What runner_labels returns when `runs-on` cannot be read as a label list. Every check that
  # consumes it treats this as an OFFENDER; the argument for refusing rather than resolving is on
  # runner_labels itself.
  UNRESOLVABLE = :unresolvable

  test "no workflow targets a GitHub-hosted runner" do
    # §15: GitHub bills ONLY hosted runners; self-hosted is free. This USED to pattern-match hosted
    # image names (`-latest` suffix, `ubuntu-NN.NN`-shaped version pins) — a losing strategy,
    # because GitHub also sells LARGER hosted runners (`ubuntu-latest-4-cores`,
    # `macos-latest-xlarge`) that are hosted and billed at a PREMIUM over the standard images, yet
    # match neither the `-latest`-suffix pattern nor the "digit after the OS name" pattern.
    # Enumerating what a hosted label CAN look like chases a product GitHub keeps adding SKUs to —
    # the same reason this codebase prefers directory-driven discovery over a hard-coded pair (see
    # deploy_hygiene_test.rb's licence sweep). That enumerating shape independently missed its own
    # worst case in BOTH files; do not bring it back here.
    #
    # So assert the thing GitHub itself keys on instead of a name shape: a job is routed to one of
    # OUR runners if and only if `runs-on` includes the literal `self-hosted` label — every box
    # self-applies it (ci/runners/README.md). Its absence is sufficient to know the job is hosted,
    # whatever the rest of the label is named; no pattern to keep current.
    #
    # Consequence for future workflows: every self-hosted job's `runs-on` MUST include the literal
    # `self-hosted` label — already this repo's documented convention, now enforced rather than
    # assumed. A dynamic matrix (`[self-hosted, "${{ matrix.runner }}"]`) would satisfy this with no
    # special-casing: the literal element is still there, unresolved template or not. (No workflow
    # here uses one today — build-app.yml and install-app-on-runners.yml, the two that did, moved to
    # chaim354/tinkerex-client with the rest of client/maker-app; see the WORKFLOW_DIR comment above
    # for why the exemption that once covered them is gone rather than kept unused.)
    #
    # The MAP form of `runs-on` is refused rather than resolved, and it always has been — that
    # refusal moved onto runner_labels, which is now the one place any of these three checks parses
    # a `runs-on`. The behaviour here is unchanged: a map-form job is still an offender.
    assert_workflows_scanned

    offenders = hosted_runner_offenders(WORKFLOW_DIR)
    assert_empty offenders,
                 "GitHub-hosted runners are the only BILLED kind (CLAUDE.md §15) — every job's " \
                 "runs-on must include the literal `self-hosted` label:\n  #{offenders.join("\n  ")}"
  end

  test "no job running on macos uses ruby/setup-ruby" do
    # The action assumes the GitHub-hosted /Users/runner layout the self-hosted Mac does not have.
    # The runner's own PATH already carries
    # mise ruby 3.4.7 — exactly .ruby-version — so `bundle install` is all a job needs.
    #
    # THE EXEMPTION IS "PROVABLY NOT A MAC", NOT "does not say macos" — see setup_ruby_offenders.
    assert_workflows_scanned

    offenders = setup_ruby_offenders(WORKFLOW_DIR)
    assert_empty offenders,
                 "ruby/setup-ruby does not work on the self-hosted Mac; use the runner's own Ruby " \
                 "(`bundle install --quiet`) instead:\n  #{offenders.join("\n  ")}"
  end

  # THE GATE CONTRACT, IN BOTH DIRECTIONS, AGAINST ONE DEFINITION.
  #
  # This used to be a THIRD hand-maintained list — `REQUIRED_GATES = %w[style scan test test-share
  # test-s3 system]` — compared against config/ci.rb and never against ci.yml. So the contract
  # ("config/ci.rb's gates ≡ ci.yml's jobs, modulo local-only") lived in three places with the
  # exception written as prose, and the direction that catches a DELETED CI job was not asserted
  # at all. Three mutations passed every assertion in this file:
  #
  #   * delete ci.yml's `system-test:` job    → green, with the browser tier silently off CI
  #   * add a gate to config/ci.rb, no job    → green, the exact case config/ci.rb's header forbids
  #   * delete ci.yml's `test-app-js:` job    → green
  #
  # And the list had already gone stale in the ordinary way: `test-app` landed on 2026-08-19 and
  # was never added to it, so the newest gate was unprotected in both directions within days.
  #
  # The exception is now DATA beside the definition (config/ci.rb's LOCAL_ONLY_GATES), `--list-ci`
  # derives from it, and this is set EQUALITY. Consequence, deliberately: a future gate CI must
  # not run has to be added to LOCAL_ONLY_GATES or this goes red. That is the point.
  test "ci.yml's gate jobs are exactly the gates bin/ci says CI must run" do
    expected  = bin_ci_gates(ci_only: true)
    gate_jobs = ci_yml_jobs.except("preflight")
    assert gate_jobs.any?, "expected ci.yml to have gate jobs besides preflight"

    invoked = gate_jobs.map do |name, job|
      # Also pins that ci.yml never hand-rolls a command that could drift from the gate's one
      # definition — a job keeping its own `bin/rails test` line invokes bin/ci zero times.
      commands    = Array(job["steps"]).filter_map { |s| s["run"] }
      invocations = commands.flat_map { |c| c.scan(%r{\bbin/ci\s+([a-z0-9-]+)}) }.flatten
      assert_equal 1, invocations.size,
                   "ci.yml job `#{name}` must invoke `bin/ci <gate>` exactly once, found " \
                   "#{invocations.inspect}"
      invocations.first
    end

    assert_equal expected.sort, invoked.sort,
                 "ci.yml's gate jobs and `bin/ci --list-ci` must name the same set. Missing a " \
                 "job means CI does not run a gate `bin/ci` reports as passing; an extra one " \
                 "means ci.yml invokes a gate config/ci.rb does not define. Add a gate to " \
                 "config/ci.rb's LOCAL_ONLY_GATES only when CI deliberately must not run it."
  end

  test "setup is the only gate exempt from needing a ci.yml job" do
    # The escape hatch above must not become the drift it replaced. `setup` is `bin/setup
    # --skip-server`: local convenience, and every ci.yml job does its own `bundle install`.
    # Anything else parked in LOCAL_ONLY_GATES is a gate that silently never runs in CI.
    exempt = bin_ci_gates - bin_ci_gates(ci_only: true)
    assert_equal [ "setup" ], exempt.sort,
                 "config/ci.rb's LOCAL_ONLY_GATES is the one place a gate can opt out of CI. " \
                 "Every entry is a gate `bin/ci` runs and CI does not — argue for it here or " \
                 "give it a ci.yml job."
  end

  # ---------------------------------------------------------------------------------------------
  # ci.yml's `paths:` trigger.
  #
  # WHAT THIS CANNOT DO, STATED FIRST: the filter is evaluated by GITHUB before any job starts, so
  # no test in this suite ever runs on the PRs it skips. A guard that tried to catch the real
  # failure would be one that cannot fail for the reason it exists — the shape argued against in
  # the brakeman block below. The `ci.yml` change IS the fix; this is a regression guard on the
  # parsed filter only.
  #
  # WHAT IT DOES PIN is where that fix can silently regress. GitHub evaluates the patterns in
  # order and the LAST match wins, so `client/maker-app/**` re-includes what `!client/**` just
  # excluded — swap those two lines and the desktop app's own sources stop triggering the
  # `test-app` gate that tests them, with nothing else in the repo noticing.
  #
  # Both lists are files a bin/ci gate actually reads (or, for the skip list, prose no gate
  # executes), not invented paths.
  PATHS_THAT_MUST_RUN_CI = [
    ".dockerignore",                        # deploy_hygiene_test: GPL sidecars out of the app image
    ".rubocop.yml",                         # the style gate's own config
    ".kamal/secrets.share",                 # deploy_hygiene_test: per-destination secrets
    ".github/workflows/ci.yml",             # ci_hygiene_test parses this file; a PR editing it must run it
    "sidecar/openscad/catalog/catalog.json", # deploy_hygiene_test: the bundled-.scad licence sweep
    "app/models/user.rb"                    # the ordinary case, and the old allowlist's first entry
  ].freeze

  # client/maker-app/package.json, client/maker-app/test/session.test.js (RUN), and
  # client/sync-engine/src/lib.rs, client/maker-app/README.md (SKIP) lived here until the client/
  # extraction (docs/superpowers/plans/2026-08-20-stage-1-extract-client.md) — client/ no longer
  # exists in this repo at all, so none of the four can stand as an example either way. The
  # `!client/**` line in ci.yml's filter (kept deliberately — see that file) has no representative
  # path left to assert on.
  PATHS_THAT_MUST_SKIP_CI = [
    "docs/DEPLOY.md",
    "CLAUDE.md"                    # root-level markdown: `**.md`, not `**/*.md`
  ].freeze

  test "ci.yml's paths filter runs CI for every file a bin/ci gate reads" do
    PATHS_THAT_MUST_RUN_CI.each do |path|
      assert Rails.root.join(path).exist?, "#{path} no longer exists — fix the list, not the filter"
      assert ci_paths_filter_runs?(path),
             "ci.yml's paths filter SKIPS `#{path}`, which a bin/ci gate reads. A PR touching " \
             "only that file would run zero jobs and report nothing."
    end
  end

  test "ci.yml's paths filter still skips docs and the Rust crates" do
    PATHS_THAT_MUST_SKIP_CI.each do |path|
      assert Rails.root.join(path).exist?, "#{path} no longer exists — fix the list, not the filter"
      assert_not ci_paths_filter_runs?(path),
                 "ci.yml's paths filter now runs the full job set for `#{path}`. Prose is the " \
                 "whole reason the filter exists; keep it excluded."
    end
  end

  test "every linux or windows job is preflight-gated so it can never queue against a missing runner" do
    # THE CORE INVARIANT. A job whose labels match no online runner does not fail — it queues for
    # 24h at 0 elapsed and is then auto-cancelled, leaving mergeStateStatus UNSTABLE and the merge
    # needing --admin. That is how CI went dark on 2026-06-24 and stayed dark for five weeks.
    #
    # macos jobs are exempt: the preflight job itself runs on macos, so if that family were absent
    # the gate could not start either and gating a macos job on it would be circular.
    #
    # A BOX LABEL IS NOT A FAMILY LABEL, AND THAT WAS THE HOLE. `runs-on: [self-hosted, maker-linux]`
    # routes to the Linux box exactly like `[self-hosted, linux]` does — every runner self-applies
    # BOTH (ci/runners/setup-linux.sh: `LABELS="self-hosted,linux,maker-linux"`), and
    # ci/runners/README.md sanctions the box name. But this check used to intersect the labels with
    # FAMILIES and `next` on an empty result, so such a job named no family, was skipped, and shipped
    # UNGATED with a fully green bin/ci — the exact "queues for 24h, UNSTABLE, merge needs --admin"
    # shape this test exists to prevent. Measured against a planted fixture before the rule below
    # existed. ci/preflight.sh's own `targeted()` happens to catch it (it greps the family name
    # ANYWHERE in a runs-on line, so "maker-linux" contains "linux"), which is why the crude shell
    # over-report is the safe direction there and an exact-match set intersection was not here.
    #
    # So a job that carries `self-hosted` and names NONE of FAMILIES is an offender: nothing static
    # can tell which preflight output would gate it. All 7 real jobs are `[self-hosted, macos]`, so
    # the rule is satisfiable and green today. A job with no `self-hosted` label at all is left to
    # the hosted-runner check above rather than reported twice.
    #
    # THE SCAN MUST BE NON-EMPTY, EVEN THOUGH THE SUBJECT SET MAY LEGITIMATELY BE EMPTY.
    # This repo has no linux/windows jobs since the sync<->client suites moved out
    # (docs/superpowers/specs/2026-08-25-cross-repo-ci-handoff.md), so `ungated` below is
    # expected to be empty and assert_empty alone would pass over NOTHING. §14e: a guard whose
    # subject is a path is silently retired by a move. Assert what was actually looked at.
    assert_workflows_scanned

    ungated = ungated_offenders(WORKFLOW_DIR)
    assert_empty ungated,
                 "these jobs would QUEUE FOREVER if their runner family is absent or unreadable — " \
                 "name a family in `runs-on` (#{FAMILIES.join('/')}) beside any box label, and add " \
                 "`needs: preflight` and `if: needs.preflight.outputs.<family> == 'true'`:\n  " \
                 "#{ungated.join("\n  ")}"
  end

  # THE THREE RUNNER CHECKS ABOVE, DRIVEN AGAINST PLANTED WORKFLOWS RATHER THAN THE SEVEN THIS REPO
  # HAPPENS TO SHIP.
  #
  # All 7 real jobs are `[self-hosted, macos]`, correctly gated, using no setup-ruby — so all three
  # checks are green over a set containing no offender of any kind, and neither the rules they
  # enforce nor the distinctions between them are exercised at all. That is the shape §15 warns
  # about: green, and unable to fail for the reason it exists.
  #
  # THIS IS WHERE THE ASYMMETRY WAS MEASURED. Before the shared runner_labels parse, the same three
  # fixtures produced: map-form flagged by the hosted-runner check ONLY (the other two `next`ed past
  # it), and `[self-hosted, maker-linux]` flagged by NOTHING. The negative controls are as
  # load-bearing as the offenders — a predicate that flags everything satisfies the positive
  # assertions perfectly (the same negative-case requirement §14b records for the `.git` write
  # guards).
  #
  # NOT the real .github/workflows/: a probe file dropped there is precisely what these checks
  # forbid, and parallel test workers fork and share the tree (ci_preflight_test.rb:128-130).
  test "the three runner checks read a planted map form, a bare box label, and setup-ruby" do
    with_workflows(<<~YAML) do |dir|
      jobs:
        preflight:
          runs-on: [self-hosted, macos]
          steps:
            - run: ci/preflight.sh
        control-macos:
          runs-on: [self-hosted, macos]
          steps:
            - run: bin/ci test
        gated-linux:
          runs-on: [self-hosted, linux]
          needs: preflight
          if: needs.preflight.outputs.linux == 'true'
          steps:
            - run: bin/ci test
        map-form:
          runs-on:
            group: my-group
            labels: [self-hosted, linux]
          steps:
            - uses: ruby/setup-ruby@v1
        box-label-linux:
          runs-on: [self-hosted, maker-linux]
          steps:
            - run: bin/ci test
        box-label-mac:
          runs-on: [self-hosted, maker-mac]
          steps:
            - uses: ruby/setup-ruby@v1
        macos-setup-ruby:
          runs-on: [self-hosted, macos]
          steps:
            - uses: ruby/setup-ruby@v1
    YAML
      # The offender strings carry their own location; the job name is what an assertion can compare.
      named = ->(offenders) { offenders.map { |o| o[/job `([^`]+)`/, 1] }.uniq.sort }

      assert_equal %w[map-form], named.call(hosted_runner_offenders(dir)),
                   "only the map form is unreadable; every other fixture carries `self-hosted`"

      assert_equal %w[box-label-mac macos-setup-ruby map-form], named.call(setup_ruby_offenders(dir)),
                   "setup-ruby is an offender unless the labels PROVE the job is not on the Mac — " \
                   "`macos` proves it is, a bare box label and the map form prove nothing"

      assert_equal %w[box-label-linux box-label-mac map-form], named.call(ungated_offenders(dir)),
                   "a job whose family cannot be read cannot be preflight-gated; `gated-linux` " \
                   "and the two `macos` jobs are the negative controls"
    end
  end

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

  # ---------------------------------------------------------------------------------------------
  # The scan gate reports on the CODE, never on how current the scanner itself is.
  #
  # THE BUG, probed at main@eb526c0 on 2026-08-12 and isolated by holding the version constant and
  # varying only the flag (brakeman 8.0.5, this app, the gate's own flags):
  #
  #     with --ensure-latest    -> exit 5   "Brakeman 8.0.5 is not the latest version 8.0.6"
  #     without it              -> exit 0   "No warnings found"
  #
  # So `bin/ci scan` exited 1 with ZERO security warnings, on a tree nobody had touched, because
  # someone upstream had cut a release. Under CLAUDE.md §15 a red `bin/ci` blocks opening a PR, so
  # that stops all work in the repo until the pin is bumped — and the next release re-breaks it.
  # Offline it is worse than red: `Gem.latest_spec_for` returns nil and ensure_latest raises
  # NoMethodError on `latest.date`, so the gate cannot run at all without reaching rubygems.org.
  #
  # "A newer brakeman exists" is answered by .github/dependabot.yml (bundler, weekly) as a
  # reviewable PR, which is where a dependency bump belongs.
  #
  # WHY THESE ARE STATIC READS AND NOT A RUN. A run cannot see this. With the flag present and
  # brakeman currently latest, `bin/brakeman` exits 0 — identical to the flag being absent — so a
  # run-based guard is green either way and only goes red once upstream releases: a test that
  # cannot fail for the reason it exists, which is this repo's dominant failure shape. That is
  # exactly how the first green in this branch was worthless (see the record, CLAUDE.md §11).
  #
  # THREE ASSERTIONS, each mutation-checked, because no one of them carries the invariant alone:
  # re-adding the unshift is caught only by the first, gutting the binstub only by the second, and
  # moving the flag up into the gate command only by the third.

  test "bin/brakeman injects no arguments of its own" do
    # STRUCTURAL, not a search for one literal. Any argument a binstub adds is invisible at the
    # only place that claims to define the gate (config/ci.rb), so the rule is that the binstub is
    # a plain loader and flags live in the gate definition. That catches the next injected flag as
    # well as this one — the repo's standing objection to enumerating what a bad value can look
    # like (see the self-hosted-label argument above, and deploy_hygiene_test.rb's licence sweep).
    #
    # DELIBERATELY NOT EXTENDED TO bin/bundler-audit, which legitimately injects
    # `--config config/bundler-audit.yml`. Narrow and argued beats broad with carve-outs: that
    # argument names a file in this repo, has no network or version semantics, and cannot change
    # what the audit reports. brakeman's injected flag was a network call that failed the gate on
    # its answer. Verified 2026-08-12 that neither bundler-audit nor `importmap audit` has any
    # self-version check at all, so brakeman is the only binstub that needs this rule.
    offenders = code_lines("bin/brakeman").grep(/\bARGV\b/)
    assert_empty offenders,
                 "bin/brakeman must be a plain loader — flags belong in config/ci.rb, the one " \
                 "definition of what the scan gate runs. Found:\n  #{offenders.join("\n  ")}"
  end

  test "bin/brakeman still resolves the brakeman that Gemfile.lock pins" do
    # THE ASSERTION THAT STOPS THE ONE ABOVE BEING SATISFIED BY AN EMPTY FILE. `: > bin/brakeman`
    # passes the ARGV check perfectly and disables the security gate; only running the thing
    # notices. Same lesson as ArchitectureInvariantsTest, where a mutation that keeps the count at
    # 1 while MOVING the reference is caught solely by the second assertion.
    locked = Rails.root.join("Gemfile.lock").read[/^ {4}brakeman \(([\d.]+)\)/, 1]
    assert locked, "could not read brakeman's pinned version out of Gemfile.lock"

    out = IO.popen([ Rails.root.join("bin/brakeman").to_s, "--version" ], err: [ :child, :out ], &:read)
    assert_equal 0, $?.exitstatus, "`bin/brakeman --version` failed:\n#{out}"
    assert_equal "brakeman #{locked}", out.strip,
                 "bin/brakeman must load the pinned brakeman; got #{out.strip.inspect}"
  end

  test "nothing in the CI surface asks a scanner whether a newer version of itself is published" do
    # The third re-entry route: leave the binstub a clean loader and put the flag in the gate
    # command instead, where the two checks above cannot see it. This one is necessarily a literal
    # — `--ensure-latest` is brakeman's own spelling and there is no structural tell in a YAML
    # `run:` string — so it is the WEAKEST of the three and is here to close a gap, not to be
    # relied on. Comments are stripped first, or this file's own documentation would trip it.
    surface = [ "config/ci.rb", *Dir.glob("bin/*"), *Dir.glob(".github/workflows/*.{yml,yaml}") ]
    offenders = surface.filter_map do |rel|
      hits = code_lines(rel).grep(/--ensure-latest/)
      "#{rel}: #{hits.join(" / ")}" if hits.any?
    end
    assert_empty offenders,
                 "--ensure-latest fails the scan gate on brakeman's own version rather than on " \
                 "this code; gem freshness is Dependabot's job:\n  #{offenders.join("\n  ")}"
  end

  # ---------------------------------------------------------------------------------------------
  # CodeMirror is ONE vendored bundle, and per-package pins are forbidden.

  test "the CodeMirror bundle is pinned once, and never per package" do
    importmap = Rails.root.join("config/importmap.rb").read
    pins = importmap.scan(/^\s*pin\s+"([^"]+)"/).flatten

    # NON-VACUOUS FIRST (§14e): a guard that scans a file dies silently when the file moves or the
    # syntax changes, and `assert_empty offenders` over an empty parse passes perfectly forever.
    assert_operator pins.size, :>, 5, "parsed #{pins.size} pins — the importmap parse is broken, " \
                                      "so everything below this line is vacuous"

    assert_includes pins, "codemirror", "the bundle pin is missing"

    offenders = pins.grep(%r{\A@codemirror/})
    assert_empty offenders,
                 "per-package CodeMirror pins (#{offenders.join(', ')}) load a second copy of " \
                 "@codemirror/state, which makes CM6 ignore extensions SILENTLY — no error, no " \
                 "console warning. Add languages to vendor/javascript/codemirror-entry.js and " \
                 "re-run bin/build-codemirror instead."
  end

  test "the pinned CodeMirror bundle file actually exists" do
    # The pin above names a filename; nothing else in the boot resolves it, so a missing artifact
    # is a 404 in the browser and a green suite. Propshaft serves vendor/javascript, so existence
    # here is the whole of the check.
    assert Rails.root.join("vendor/javascript/codemirror.js").exist?,
           "run bin/build-codemirror"
  end

  # ---------------------------------------------------------------------------------------------
  # Active Storage variants stay OFF, and the two scaffold gems that fed them stay OUT.
  #
  # These two are a PAIR, and they replace a protection that was spent rather than adding a new
  # one. While `image_processing` was still in the Gemfile, editing config/application.rb's
  # `variant_processor = :disabled` back to `:vips` KILLED BOOT loudly — activestorage 8.1.3.1's
  # eager `require "image_processing/vips"` raises a LoadError matching neither arm of the engine's
  # own rescue. With the gem gone that same edit degrades to a logged warning and a NIL transformer:
  # silent, and only at deploy time on someone's box. So the accidental tripwire is traded for a
  # deliberate one that fires in `bin/ci`, on the PR.
  #
  # `rails app:update` offers both gem lines back, which is this file's established job (the
  # brakeman binstub and the CodeMirror pin above are the same shape).

  test "Active Storage resolves to the null transformer, so no variant pipeline is live" do
    # NON-VACUOUS FIRST (§14e): a nil transformer is exactly what a `:vips`/`:mini_magick` setting
    # now produces with the gem absent, so "nil" is the failure this guard exists to catch — it must
    # never be mistaken for the pipeline simply not being there.
    refute_nil ActiveStorage.variant_transformer,
               "ActiveStorage.variant_transformer is nil — config/application.rb asks for a " \
               "processor whose gem is not installed, and every variant call now fails at runtime."

    # RESOLVED, NOT READ (§14e: resolve `Rails.application.config.cache_store` rather than reading
    # the file). The knob is one line in config/application.rb; whether it took effect is not.
    assert_equal ActiveStorage::Transformers::NullTransformer, ActiveStorage.variant_transformer,
                 "the Active Storage variant pipeline is live again. It has no gem behind it here " \
                 "and must not get one — CLAUDE.md §14e: ruby-vips reintroduces the in-process " \
                 "libvips thread pool that deadlocks the fork-based parallel test runner. See " \
                 "config/application.rb's variant_processor argument."
  end

  test "neither Active Storage variant gem is back in the Gemfile" do
    gemfile = Rails.root.join("Gemfile").read
    declared = gemfile.scan(/^\s*gem\s+"([^"]+)"/).flatten
    assert_operator declared.size, :>, 10, "parsed #{declared.size} gems — the Gemfile parse is " \
                                           "broken, so both assertions below are vacuous"

    # Asserted SEPARATELY, not as one combined `refute` over both names (§15: assert the narrowest
    # true thing, then mutate each arm). One re-added gem must not be able to hide behind the other.
    refute_includes declared, "image_processing",
                    "image_processing is back. Nothing calls it: thumbnails shell out to the " \
                    "`vipsthumbnail` BINARY and variant_processor is :disabled (§14e). Adding it " \
                    "re-opens CVE-2026-66066's code path and invites ruby-vips after it."
    refute_includes declared, "jbuilder",
                    "jbuilder is back. No .jbuilder view exists in this app — every v1 controller " \
                    "renders `render json:` directly."
  end

  private

    # `runs-on` normalised to a downcased label list — THE ONE PARSE, consumed by all three runner
    # checks above.
    #
    # It was pasted at each of them, and the copies had drifted into disagreeing about the safe
    # direction. Measured against a planted map-form job: the hosted-runner check went RED (safe)
    # while the setup-ruby and preflight-gating checks both PASSED over jobs that violate them. The
    # failure mode of three copies is not "a bad job ships silently" — it is that the author fixes
    # the one guard that went red and never learns the other two were also wrong.
    #
    # THE MAP FORM IS REFUSED, NOT RESOLVED, AND THE REFUSAL IS THE INVARIANT.
    # `runs-on: { group: ..., labels: [...] }` is legal YAML for a runner GROUP, and `Array(hash)`
    # yields `[key, value]` PAIRS rather than a flat label list. Flattening `labels` so a map-form
    # job could satisfy the `self-hosted` check would convert the one guard that currently fails
    # SAFE into one that fails OPEN — strictly worse than today — because an org-level HOSTED
    # larger-runner group and a self-hosted runner group use the IDENTICAL YAML shape and static
    # inspection cannot tell them apart. So it returns an explicit marker that every caller reports:
    # loud everywhere, rather than safe in one place and silent in two.
    #
    # No workflow here uses the map form today. The count of `runs-on` values used to be written
    # into this comment and had already drifted (it said 15 while the true answer was 7), so it is
    # left to the checks to establish rather than restated here. If this repo ever adopts runner
    # groups, that ambiguity is the problem to solve first.
    def runner_labels(job)
      raw = job["runs-on"]
      return UNRESOLVABLE if raw.is_a?(Hash)
      Array(raw).map { |l| l.to_s.downcase }
    end

    # Jobs whose `runs-on` does not name one of OUR boxes. Behaviour is what it has always been:
    # the literal `self-hosted` label, or an offender — with the map form now saying WHY it was
    # rejected instead of advising a label the job may well already carry.
    def hosted_runner_offenders(dir)
      offenders = []
      each_job(dir) do |file, name, job|
        labels = runner_labels(job)
        if labels == UNRESOLVABLE
          offenders << "#{file}: job `#{name}` uses the `runs-on` MAP form, which cannot be read " \
                       "statically — a hosted larger-runner group looks identical (see runner_labels)"
          next
        end
        next if labels.include?("self-hosted")
        offenders << "#{file}: job `#{name}` runs-on `#{labels.join(', ')}` — add the literal " \
                     "`self-hosted` label"
      end
      offenders
    end

    # Jobs using ruby/setup-ruby that this file cannot PROVE are off the self-hosted Mac.
    #
    # The exemption is deliberately the narrow direction. Asking `labels.include?("macos")` — what
    # this check used to do — exempts `[self-hosted, maker-mac]`, which is the Mac, and the map form,
    # which might be. A job is skipped only when its labels resolve AND name a family AND that
    # family set excludes macos; anything else is reported, because the failure it prevents happens
    # at step 2 of every job, on infrastructure rather than on code.
    def setup_ruby_offenders(dir)
      offenders = []
      each_job(dir) do |file, name, job|
        used = Array(job["steps"]).filter_map { |s| s["uses"] }
        next unless used.any? { |u| u.start_with?("ruby/setup-ruby") }

        labels = runner_labels(job)
        families = labels == UNRESOLVABLE ? [] : labels & FAMILIES
        next if families.any? && !families.include?("macos")

        reason = if labels == UNRESOLVABLE
          "`runs-on` uses the map form, so its family cannot be read"
        elsif families.empty?
          "runs-on `#{labels.join(', ')}` names no runner family"
        else
          "runs on macos"
        end
        offenders << "#{file}: job `#{name}` (#{reason})"
      end
      offenders
    end

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

    # Jobs that would QUEUE FOREVER against a missing runner — the core invariant. Three ways in:
    # an unreadable `runs-on`, a `self-hosted` job naming no family at all, and a linux/windows job
    # with no `needs: preflight` + `if:` pair.
    #
    # WHICHEVER FAMILY PREFLIGHT ITSELF RUNS ON is exempt from the last of those, because a missing
    # runner in that family stops preflight from starting too and the gate would be circular. Read
    # from the preflight job rather than named, so it stays true when CI changes boxes — see
    # preflight_family.
    def ungated_offenders(dir)
      exempt = preflight_family(dir)
      ungated = []
      each_job(dir) do |file, name, job|
        labels = runner_labels(job)
        if labels == UNRESOLVABLE
          ungated << "#{file}: job `#{name}` — `runs-on` uses the map form, so no preflight output " \
                     "can be matched to it (see runner_labels)"
          next
        end

        families = labels & FAMILIES
        if families.empty?
          next unless labels.include?("self-hosted")
          ungated << "#{file}: job `#{name}` runs-on `#{labels.join(', ')}` — names none of " \
                     "#{FAMILIES.join('/')}, so nothing static can say which runner it needs"
          next
        end

        gated_families = families - [ exempt ].compact
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
      ungated
    end

    # NON-VACUITY FOR EVERY SWEEP OVER THE REAL WORKFLOW DIR (CLAUDE.md §14e: "a guard that scans a
    # directory dies silently when the directory leaves"). All three runner checks end in
    # `assert_empty`, whose subject set may legitimately be empty, so each of them passes perfectly
    # over ZERO jobs. Written once here rather than three times, and asserted against WORKFLOW_DIR
    # specifically — the fixture test above deliberately scans a much smaller planted set.
    def assert_workflows_scanned
      scanned = []
      each_job { |file, name, _job| scanned << "#{file}:#{name}" }
      assert_operator scanned.size, :>=, 2,
                      "this guard scanned #{scanned.size} job(s) — it can no longer fail for the " \
                      "reason it exists. Point WORKFLOW_DIR at the real workflows."
    end

    # Runs the block against a THROWAWAY workflow dir holding one ci.yml, and yields its path.
    # Mirrors ci_preflight_test.rb's helper of the same name, for the reason recorded there: a probe
    # dropped in .github/workflows/ would trip the very checks it is probing and would race between
    # parallel workers, which fork and share the tree.
    def with_workflows(body)
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "ci.yml"), body)
        yield Pathname.new(dir)
      end
    end

    # Source lines with blanks and whole-line comments removed. Both `#` (ruby, yaml) and the
    # shebang go; nothing here needs to read a trailing comment.
    def code_lines(relative_path)
      path = Rails.root.join(relative_path)
      return [] unless path.file?
      path.readlines(chomp: true).reject { |l| l.strip.empty? || l.strip.start_with?("#") }
    end

    # The real gate list, read by RUNNING bin/ci rather than by parsing config/ci.rb.
    #
    # Shelling out costs ~1s (it boots config/boot) and is worth it: a regex over the source would
    # assert that the file LOOKS like it defines a gate, and this asserts that `bin/ci <gate>` will
    # actually resolve. The repo has already been bitten once by a hermetic check that shared the
    # code's misunderstanding (FakeS3 / CGI.escape) — assert the wire, not the round-trip.
    #
    # `ci_only: true` asks `--list-ci`, which is `--list` minus config/ci.rb's LOCAL_ONLY_GATES.
    # Both flags come from the SAME GATES hash, so there is no second list to keep in step.
    def bin_ci_gates(ci_only: false)
      flag = ci_only ? "--list-ci" : "--list"
      out  = IO.popen([ Rails.root.join("bin/ci").to_s, flag ], err: [ :child, :out ], &:read)
      assert_equal 0, $?.exitstatus, "`bin/ci #{flag}` failed:\n#{out}"
      out.split("\n").map(&:strip).reject(&:empty?)
    end

    def ci_yml_jobs
      YAML.load_file(WORKFLOW_DIR.join("ci.yml"), aliases: true).fetch("jobs")
    end

    # ci.yml's pull_request `paths:` list, in file order. Psych resolves YAML 1.1 booleans, so the
    # workflow's `on:` key parses as the BOOLEAN true — see each_job's note.
    def ci_paths_filter
      YAML.load_file(WORKFLOW_DIR.join("ci.yml"), aliases: true)
          .fetch(true).fetch("pull_request").fetch("paths")
    end

    # GitHub's own evaluation order: walk every pattern, LAST match wins, `!` negates.
    def ci_paths_filter_runs?(path)
      ci_paths_filter.reduce(false) do |included, pattern|
        negated = pattern.start_with?("!")
        glob    = negated ? pattern.delete_prefix("!") : pattern
        path_filter_regexp(glob).match?(path) ? !negated : included
      end
    end

    # One GitHub filter pattern as a Regexp. GitHub documents `*` as "zero or more characters but
    # does not match /" and `**` as "zero or more of ANY character, including /" — which is why
    # `**.md` matches a root-level CLAUDE.md as well as docs/DEPLOY.md.
    #
    # It also documents `?`, `+` and `[]`, and they do NOT mean what a shell glob means by them
    # (`?` is "zero or one of the PRECEDING character"). Rather than model those wrongly, this
    # refuses them: a filter edit reaching for one turns this file red instead of being evaluated
    # by a translator that quietly disagrees with GitHub.
    def path_filter_regexp(glob)
      assert_no_match(/[?+\[\]{}]/, glob,
                      "this test models only `*` and `**`; #{glob.inspect} uses a construct whose " \
                      "GitHub meaning differs from a shell glob — extend path_filter_regexp first")
      source = glob.scan(/\*\*|\*|[^*]+/).map do |token|
        case token
        when "**" then ".*"
        when "*"  then "[^/]*"
        else           Regexp.escape(token)
        end
      end.join
      /\A#{source}\z/
    end

    # Yields [basename, job_name, job_hash] for every job in every workflow.
    #
    # Reads only the "jobs" key. NOTE for anyone extending this: Psych resolves YAML 1.1 booleans,
    # so a workflow's `on:` key parses as the BOOLEAN true, not the string "on" — ci.yml's top-level
    # keys come back as ["name", true, "concurrency", "jobs"]. Reach for `d[true]`, not `d["on"]`.
    #
    # THE DIRECTORY IS AN ARGUMENT so the runner checks can be driven against planted fixtures
    # instead of only the seven jobs this repo happens to ship — see the fixture test above. It
    # defaults to WORKFLOW_DIR, which is what every real guard passes.
    def each_job(dir = WORKFLOW_DIR)
      # GitHub Actions accepts both extensions; `*.yml` alone would leave a `*.yaml` workflow
      # invisible to every guard in this file — the same close-the-class reasoning as the
      # self-hosted-label check above, applied to file discovery instead of label shape.
      dir.glob("*.{yml,yaml}").sort.each do |path|
        jobs = YAML.load_file(path, aliases: true).fetch("jobs")
        jobs.each { |name, job| yield path.basename.to_s, name, job }
      end
    end
end
