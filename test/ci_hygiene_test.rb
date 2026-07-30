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
    # assumed. A dynamic matrix (`[self-hosted, "${{ matrix.runner }}"]`, build-app.yml /
    # install-app-on-runners.yml) satisfies this with no special-casing: the literal element is
    # still there, unresolved template or not — DYNAMIC_MATRIX_WORKFLOWS/each_static_job below are
    # for a different, still-unused check, not this one.
    #
    # KNOWN LIMIT, deliberately not closed: `runs-on` also has a MAP form,
    # `{ group: ..., labels: [...] }`, and `Array(hash)` yields `[key, value]` PAIRS rather than a
    # flat label list — so a map-form job can never match `"self-hosted"` and therefore always FAILS
    # this check. Left alone for two reasons. It fails in the SAFE direction (loudly over-flagging,
    # never silently passing a billed runner, which is the whole point of the file), and a correct
    # reading is genuinely ambiguous: an org-level HOSTED larger-runner group and a self-hosted
    # runner group use the identical YAML shape, so static inspection cannot tell them apart. No
    # workflow here uses the map form today (verified: all 38 `runs-on` values are Array-shaped).
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

  private

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

    # The workflows subject to the runner-family rules: everything except the dynamic-matrix pair.
    def each_static_job
      each_job do |file, name, job|
        next if DYNAMIC_MATRIX_WORKFLOWS.include?(file)
        yield file, name, job
      end
    end
end
