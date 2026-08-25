require "test_helper"

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
#   * `ruby/setup-ruby@v1` does not work on the self-hosted Mac. nightly.yml's e2e-macos job says so
#     in a comment and uses the runner's own Ruby instead. Retargeting a Rails job at macos while
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

  # Every self-hosted family we may target. Anything else is either GitHub-hosted (billed) or a typo.
  FAMILIES = %w[macos linux windows].freeze

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
    # KNOWN LIMIT, deliberately not closed: `runs-on` also has a MAP form,
    # `{ group: ..., labels: [...] }`, and `Array(hash)` yields `[key, value]` PAIRS rather than a
    # flat label list — so a map-form job can never match `"self-hosted"` and therefore always FAILS
    # this check. Left alone for two reasons. It fails in the SAFE direction (loudly over-flagging,
    # never silently passing a billed runner, which is the whole point of the file), and a correct
    # reading is genuinely ambiguous: an org-level HOSTED larger-runner group and a self-hosted
    # runner group use the identical YAML shape, so static inspection cannot tell them apart. No
    # workflow here uses the map form today (verified: all 15 `runs-on` values are Array-shaped —
    # down from 38 before the client/ extraction moved four workflow files to tinkerex-client).
    # If this repo ever adopts runner groups, that ambiguity is the problem to solve first.
    offenders = []
    each_job do |file, name, job|
      raw = Array(job["runs-on"])
      next if raw.map { |l| l.to_s.downcase }.include?("self-hosted")
      offenders << "#{file}: job `#{name}` runs-on `#{raw.join(', ')}` — add the literal " \
                   "`self-hosted` label"
    end
    assert_empty offenders,
                 "GitHub-hosted runners are the only BILLED kind (CLAUDE.md §15) — every job's " \
                 "runs-on must include the literal `self-hosted` label:\n  #{offenders.join("\n  ")}"
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
    ".github/workflows/nightly.yml",        # ci_hygiene_test globs EVERY workflow, not just ci.yml
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
    "docs/STATUS.md",
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
    # THE SCAN MUST BE NON-EMPTY, EVEN THOUGH THE SUBJECT SET MAY LEGITIMATELY BE EMPTY.
    # This repo has no linux/windows jobs since the sync<->client suites moved out
    # (docs/superpowers/specs/2026-08-25-cross-repo-ci-handoff.md), so `ungated` below is
    # expected to be empty and assert_empty alone would pass over NOTHING. §14e: a guard whose
    # subject is a path is silently retired by a move. Assert what was actually looked at.
    scanned = []
    each_job { |file, name, _job| scanned << "#{file}:#{name}" }
    assert_operator scanned.size, :>=, 2,
                    "this guard scanned #{scanned.size} job(s) — it can no longer fail for the " \
                    "reason it exists. Point WORKFLOW_DIR at the real workflows."

    ungated = []
    each_job do |file, name, job|
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
  # exactly how the first green in this branch was worthless (see docs/STATUS.md).
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

  private

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
    # `**.md` matches a root-level CLAUDE.md as well as docs/STATUS.md.
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
    def each_job
      # GitHub Actions accepts both extensions; `*.yml` alone would leave a `*.yaml` workflow
      # invisible to every guard in this file — the same close-the-class reasoning as the
      # self-hosted-label check above, applied to file discovery instead of label shape.
      WORKFLOW_DIR.glob("*.{yml,yaml}").sort.each do |path|
        jobs = YAML.load_file(path, aliases: true).fetch("jobs")
        jobs.each { |name, job| yield path.basename.to_s, name, job }
      end
    end
end
