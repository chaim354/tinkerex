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
# ONE SCAFFOLD STEP WAS DROPPED, DELIBERATELY: `Tests: Seeds` (`db:seed:replant`). It asserts
# nothing here — `db/seeds.rb` is comments only, so replanting an empty seed set cannot fail for a
# reason anyone wants to hear about — and `ci.yml` never ran it, so keeping it would re-open the same
# gap in the other direction: a gate `bin/ci` runs and CI does not. If `db/seeds.rb` ever gains real
# content, add a `seeds` gate here AND a job in ci.yml, together.
#
# Usage:
#   bin/ci                 # every gate, in this order
#   bin/ci test test-s3    # exactly those gates
#   bin/ci --list          # the gate names, one per line
#   bin/ci --list-ci       # the gates ci.yml must have a job for (what ci_hygiene_test reads)

GATES = {
  # Local convenience only — ci.yml does its own `bundle install` per job and never calls this.
  # This is the ONE gate CI deliberately does not run, which is why it is named in
  # LOCAL_ONLY_GATES below rather than being a sentence somebody has to remember.
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
    #
    # AND IT CLEANS UP AFTER ITSELF, which the first version did not. Our runners are SELF-HOSTED and
    # therefore PERSISTENT (§15) — nothing reclaims a stray tmpdir between runs the way a fresh
    # hosted image would. A review of this file found 334 accumulated `tmp.*` directories on the mac
    # runner, some holding real share-fixture bytes dated weeks back: kilobytes per run, but
    # unbounded, and this codebase treats unbounded accumulation as a bug everywhere else it appears
    # (Sync::ChunkReaper, Library::TrashPurgeJob).
    #
    # `trap ... EXIT` fires however the shell leaves — pass, fail, or interrupt — so a red run does
    # not leak either. `${d:?}` is the guard that matters: if `mktemp -d` failed and `d` is empty, the
    # trap aborts instead of handing `rm -rf` an empty argument.
    ci.step "Tests: Rails (share backend)",
            'd=$(mktemp -d); trap \'rm -rf "${d:?}"\' EXIT; ' \
            'env LIBRARY_BACKEND=share LIBRARY_PATH="$d" SYNC_ENGINE=1 bin/rails db:test:prepare test'
  end,

  "test-s3" => ->(ci) do
    # These knobs point at NOTHING REAL on purpose: the suite injects a stubbed Aws::S3::Client, and
    # the s3 boot guard is config-PRESENCE only and never touches the network (boot must not depend
    # on a third party being reachable). Any test that made a real S3 call fails here. That is the
    # point, not an oversight.
    ci.step "Tests: Rails (s3 backend)",
            "env LIBRARY_BACKEND=s3 LIBRARY_S3_BUCKET=ci-not-a-real-bucket " \
            "LIBRARY_S3_REGION=us-east-1 LIBRARY_S3_ACCESS_KEY_ID=ci " \
            "LIBRARY_S3_SECRET_ACCESS_KEY=ci LIBRARY_S3_PREFIX=library SYNC_ENGINE=1 " \
            "bin/rails db:test:prepare test"
  end,

  # THE FOURTH BACKEND LEG, AND THE ONLY ONE WHERE THE ENGINE IS GENUINELY ABSENT.
  #
  # The three legs above now set SYNC_ENGINE=1, so they keep the engine loaded even on share and s3
  # and go on reporting IDENTICAL run and assertion counts -- §15's guard against a test quietly
  # depending on the ambient LIBRARY_BACKEND is unchanged by any of this. That guard is worth more
  # than the convenience of letting the counts drift.
  #
  # But it means those legs no longer execute the no-engine path at all, and a conditional nobody
  # runs is CLAUDE.md §14a's recorded bug verbatim: a boot guard that passed the entire suite and
  # took production down. So this leg boots share with SYNC_ENGINE=0 and runs ONE focused file that
  # asserts what "no engine" is supposed to mean. Its counts differ from the other three by design,
  # which is why it is a separate suite rather than the same suite with a flag.
  "test-no-engine" => ->(ci) do
    ci.step "Tests: share with NO sync engine loaded",
            'd=$(mktemp -d); trap \'rm -rf "${d:?}"\' EXIT; ' \
            'env LIBRARY_BACKEND=share LIBRARY_PATH="$d" SYNC_ENGINE=0 ' \
            "bin/rails db:test:prepare test TEST=test/integration/no_engine_boot_test.rb"
  end,

  # THE chunk_remote JOURNEY, AGAINST A REAL STANDALONE tinkerex-sync HOST.
  #
  # Used to be .github/workflows/sync-contract.yml -- a SEPARATE workflow, deliberately kept OUT of
  # bin/ci, because test/ci_hygiene_test.rb asserts SET EQUALITY between `bin/ci --list-ci` and
  # ci.yml's gate jobs (plus a second test allowing only `setup` into LOCAL_ONLY_GATES above), so a
  # red gate is a red main -- and this suite was DELIBERATELY RED on arrival while Stage 5 Arc B
  # measured, then closed, four real gaps (docs/superpowers/plans/2026-08-23-arc-b-worklist.md). It
  # lived beside bin/ci on the client-contract.yml precedent: a cross-repo wire-contract workflow
  # that boots a real server and never calls bin/ci. Arc B closed all four gaps -- the suite is
  # 10/10 against a real server (docs/STATUS.md) -- so it moves in here now: ONE definition, same
  # as every other gate, and the workflow file is deleted rather than left running the same suite
  # a second way.
  #
  # BOOTS ITS OWN SERVER, RATHER THAN REQUIRING ONE ALREADY RUNNING, so `bin/ci` (bare, or `bin/ci
  # test-chunk-remote` alone) just works for a developer who already has the sibling checkout --
  # the same convenience the cross-stack demos in the cheatsheet below already get from
  # `bin/sync-server`. The failure mode for a MISSING sibling checkout is `bin/sync-server`'s own,
  # reused rather than reimplemented: `bin/sync-server prepare`'s `require_checkout` names the repo
  # and the `gh repo clone` command and exits 1 before this script goes anywhere near a socket, so
  # a developer without ../tinkerex-sync gets that message -- never a bare connection-refused.
  #
  # THE SKIP-ASSERTION ARGUMENT, CARRIED OVER FROM sync-contract.yml VERBATIM because it is still
  # exactly true: nothing INSIDE the suite can vouch for its own siblings' skips. The in-suite
  # canary ("the journey suite does not skip when a server is configured") proves only that IT ran
  # -- measured under a deliberately broken skip_unless_remote_server, the suite still went `9
  # runs, 1 assertions, 0 failures, 8 skips` and exit 0. Nothing inside a suite can assert about
  # its own siblings' skips; CLAUDE.md §14j's "a guard that skips on the thing it asserts is
  # vacuous" rebuilt one layer up, inside the very test meant to prevent it. This step is the one
  # place that KNOWS a server is up -- it just probed /up and whoami below -- so it is what greps
  # the captured run for a skip and fails outright. With a server configured, a skip is never
  # legitimate.
  #
  # `bash -c`, NOT the single-string form every other multi-command gate above uses:
  # `${PIPESTATUS[0]}` is a bashism -- the single-string form runs under `/bin/sh -c`, which has no
  # PIPESTATUS at all -- and it is load-bearing: after `... | tee file`, a bare `$?` is tee's exit
  # status, which is always 0, so a real journey failure would be swallowed and this gate would
  # report green over a red suite. That exact mistake already put a wrong "exits 0" claim into an
  # earlier plan. Passing `"bash", "-c", script` as three separate arguments (rather than one
  # string) also means the script never passes through an outer shell at all, so nothing in it
  # needs escaping for Ruby's sake.
  "test-chunk-remote" => ->(ci) do
    script = <<~'SCRIPT'
      set -euo pipefail
      PORT="${SYNC_PORT:-3002}"

      # LEFTOVER-PROCESS GUARD, before anything tries to bind the port. Harmless if nothing is
      # listening: lsof exits 1 when it finds nothing, which would trip `set -e` under `pipefail`
      # before the port is ever touched -- `|| true` on the whole pipe is what keeps that ordinary
      # case from failing the step. Matters most on a persistent, self-hosted runner, where a
      # cancelled run (ci.yml's own `cancel-in-progress`) can leave a backgrounded server behind
      # for the next run to collide with.
      lsof -ti tcp:"$PORT" | xargs kill -9 2>/dev/null || true

      bin/sync-server prepare
      set -a; . tmp/sync-server.env; set +a

      bin/sync-server start &
      SRV=$!
      trap 'kill "$SRV" 2>/dev/null || true' EXIT

      # TWO PROBES, TWO DIFFERENT QUESTIONS, and neither substitutes for the other. /up runs
      # User.count on that host and answers 503 on an empty schema -- it exists because its first
      # real deploy reported healthy with no tables. whoami then proves the credential
      # bin/sync-server just minted is actually accepted. A bare port check answers neither, and a
      # schema-less server would otherwise surface as ten confusing journey failures instead of
      # one clear failure here.
      for i in $(seq 1 60); do
        curl -sf "$CHUNK_REMOTE_URL/up" >/dev/null && break
        sleep 1
      done
      curl -sf "$CHUNK_REMOTE_URL/up" >/dev/null || {
        echo "sync server never became ready"; exit 1; }
      curl -sf -H "Authorization: Bearer $CHUNK_REMOTE_TOKEN" \
        "$CHUNK_REMOTE_URL/v1/devices/whoami" >/dev/null || {
          echo "the device token was rejected"; exit 1; }

      set +e
      LIBRARY_BACKEND=chunk_remote bin/rails db:test:prepare \
        test TEST=test/integration/chunk_remote_journey_test.rb 2>&1 | tee tmp/journey-ci.txt
      code=${PIPESTATUS[0]}
      set -e

      # THE SKIP ASSERTION IS THE REAL GUARD -- see this gate's own comment in config/ci.rb for why
      # nothing inside the suite itself can stand in for this check.
      if grep -qE ', [1-9][0-9]* skips' tmp/journey-ci.txt; then
        echo "::error::the journey suite SKIPPED with a sync server configured and reachable."
        echo "A skip here means skip_unless_remote_server stopped discriminating, and the suite"
        echo "reported success having asserted nothing -- the failure this gate exists to make"
        echo "impossible."
        exit 1
      fi
      exit "$code"
    SCRIPT
    ci.step "Tests: chunk_remote journey (real sync server)", "bash", "-c", script
  end,

  "system" => ->(ci) do
    ci.step "Tests: System (real browser)", "bin/rails db:test:prepare test:system"
  end
}.freeze

# THE ONE EXCEPTION TO "every gate has a ci.yml job", AS DATA RATHER THAN AS PROSE. It used to be
# a third hand-maintained list — test/ci_hygiene_test.rb carried its own REQUIRED_GATES literal
# and compared it against this file, never against ci.yml — so the contract lived in three places
# and only one direction was ever checked. Three mutations passed that whole test file: deleting
# ci.yml's `system-test` job (the browser tier silently off CI), adding a gate here with no job
# (exactly what the header above forbids), and deleting the `test-app-js` job. The hand-copied
# list had already gone stale: `test-app` landed on 2026-08-19 and was never added to it.
#
# With this here, `--list` and `--list-ci` are derived from ONE definition and ci_hygiene_test
# asserts SET EQUALITY between `--list-ci` and ci.yml's gate jobs — both directions, no literal.
# Adding a gate CI genuinely must not run means adding it here, in the same commit, deliberately.
LOCAL_ONLY_GATES = %w[setup].freeze

if ARGV.include?("--list")
  puts GATES.keys
  exit 0
end

# The gates ci.yml must have a job for. Answered BEFORE the unknown-gate abort below, which would
# otherwise reject `--list-ci` as a gate name.
if ARGV.include?("--list-ci")
  puts GATES.keys - LOCAL_ONLY_GATES
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
