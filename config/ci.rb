# Run using bin/ci [GATE ...]
#
# ONE definition per gate, and .github/workflows/ci.yml invokes these BY NAME — one job per gate. So
# the PR keeps a separate status per gate while there is exactly one definition of what each gate
# does. test/ci_hygiene_test.rb asserts the two lists cannot drift apart.
#
# THE DRIFT THIS REPLACES WAS REAL AND LIVE. Before this, three lists claimed to be "the gates":
# this file (the untouched Rails scaffold), ci.yml, and a hand-copied 8-command checklist in
# what was then STATUS.md. `bin/ci` printed "Continuous Integration passed" while running neither backend leg
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
    # `bin/importmap-audit`, NOT `bin/importmap audit`: the endpoint it POSTs to is the only remote
    # host any check here depends on, and when it is unreachable the gate used to fail on somebody
    # else's uptime — see lib/importmap_audit.rb for the argument and tinkerex#228 for the outage.
    ci.step "Security: Importmap vulnerability audit", "bin/importmap-audit"
    ci.step "Security: Brakeman code analysis",
            "bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error"
  end,

  # THE THREE FILELAYER BACKENDS, WHICH ARE NOW share / s3 / chunk_remote. `test` ran embedded
  # chunk (the old default) and `test-share` ran share; Arc D Part 2 retired embedded chunk, so
  # those two would be the same leg twice and `test` becomes the share one. What the multiple legs
  # buy is narrower than it looks and is argued at length in ci.yml -- they catch tests that
  # silently depend on the AMBIENT LIBRARY_BACKEND. The share leg found nine of them on the way in.
  #
  # ALL THREE RUN THE FULL SUITE, which is new: the chunk-family leg used to be ten journey tests
  # against a real server while embedded chunk carried the full suite in-process. There is no
  # in-process chunk backend any more, so if `test-chunk-remote` did not run everything, the
  # PRIMARY deployment's backend would be the only one without full coverage.
  #
  # A fresh empty dir per run. LIBRARY_PATH must exist and be writable or the boot guard refuses to
  # boot -- it touch-probes rather than asking File.writable?, which tests POSIX mode bits, not
  # effective access, and is wrong under exactly the NFS/SMB ACLs this backend targets.
  #
  # AND IT CLEANS UP AFTER ITSELF. Our runners are SELF-HOSTED and therefore PERSISTENT (§15) --
  # nothing reclaims a stray tmpdir between runs the way a fresh hosted image would. A review of
  # this file found 334 accumulated `tmp.*` directories on the mac runner, some holding real
  # share-fixture bytes dated weeks back: kilobytes per run, but unbounded, and this codebase
  # treats unbounded accumulation as a bug everywhere else it appears (Library::TrashPurgeJob).
  #
  # `trap ... EXIT` fires however the shell leaves -- pass, fail, or interrupt -- so a red run does
  # not leak either. `${d:?}` is the guard that matters: if `mktemp -d` failed and `d` is empty, the
  # trap aborts instead of handing `rm -rf` an empty argument.
  "test" => ->(ci) do
    ci.step "Tests: Rails (share backend)",
            'd=$(mktemp -d); trap \'rm -rf "${d:?}"\' EXIT; ' \
            'env LIBRARY_BACKEND=share LIBRARY_PATH="$d" bin/rails db:test:prepare test'
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

  # `test-no-engine` WAS HERE AND IS GONE. It booted share with SYNC_ENGINE=0 and ran one focused
  # file, because the other legs forced the engine loaded (SYNC_ENGINE=1) so their counts would
  # stay identical, and a conditional nobody executes is CLAUDE.md §14a's recorded bug verbatim.
  # Arc D Part 2 removed the engine from this app entirely: "no engine loaded" is not a leg any
  # more, it is the only mode there is, and every gate above exercises it. Its one test file went
  # with it -- what remains of that claim is build_chunk_remote_test's structural assertion that
  # Sync is not even defined here, which goes red if the gem is ever re-added.

  # THE chunk_remote JOURNEY, AGAINST A REAL STANDALONE tinkerex-sync HOST.
  #
  # Used to be .github/workflows/sync-contract.yml -- a SEPARATE workflow, deliberately kept OUT of
  # bin/ci, because test/ci_hygiene_test.rb asserts SET EQUALITY between `bin/ci --list-ci` and
  # ci.yml's gate jobs (plus a second test allowing only `setup` into LOCAL_ONLY_GATES above), so a
  # red gate is a red main -- and this suite was DELIBERATELY RED on arrival while Stage 5 Arc B
  # measured, then closed, four real gaps (docs/superpowers/plans/2026-08-23-arc-b-worklist.md). It
  # lived beside bin/ci on the client-contract.yml precedent: a cross-repo wire-contract workflow
  # that boots a real server and never calls bin/ci. (That workflow was deleted on 2026-08-25 --
  # it had never run once -- so the precedent is history, not a live example; the argument for
  # folding this gate INTO bin/ci is what survives.) Arc B closed all four gaps -- the suite is
  # 10/10 against a real server (the record)  -- so it moves in here now: ONE definition, same
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
      #
      # $CHUNK_REMOTE_TOKEN HERE IS A LOCAL SMOKE-TEST CREDENTIAL, NOT A DEPLOYMENT REQUIREMENT --
      # this is the one legitimate place it still belongs. It answers "did sync:device:issue mint a
      # device this ephemeral server actually accepts," a narrower question than "can a real
      # deployment run." That second question is lib/library_backend_check.rb's
      # CHUNK_REMOTE_REQUIRED, which stopped naming this var once Arc C moved ordinary traffic to
      # per-user `users.sync_device_token` and named SYNC_ADMIN_TOKEN instead -- see that constant's
      # own comment for the full history. Do not read this probe's continued use of
      # $CHUNK_REMOTE_TOKEN as evidence a deployment still needs it.
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
      # TWO RUNS, AND THE SPLIT IS THE SKIP ASSERTION -- IT IS NOT A CONVENIENCE.
      #
      # The journey file runs FIRST, alone, and must report ZERO skips. That check is this gate's
      # real guard and the reason the gate exists in this shape: nothing inside the suite can
      # vouch for its own skips (CLAUDE.md §14j -- "a guard that skips on the thing it asserts is
      # vacuous"), and measured under a deliberately broken skip_unless_remote_server the journey
      # suite still reported `9 runs, 1 assertions, 0 failures, 8 skips` and exit 0. This step is
      # the one place that KNOWS a server is up -- it just probed /up and whoami -- so it is what
      # can call a skip illegitimate.
      #
      # THE FULL SUITE RUNS SECOND AND MAY LEGITIMATELY SKIP, which is exactly why it cannot share
      # the check. It carries ~30 honest skips -- renderers whose toolchain is absent on this box,
      # suites gated on an optional binary -- so grepping ITS output for skips would fail every
      # run, and "loosen the guard until it passes" would have quietly destroyed the one assertion
      # that has already caught a vacuous skip once. Running the file twice is a few seconds; the
      # alternative is a guard that means nothing.
      LIBRARY_BACKEND=chunk_remote bin/rails db:test:prepare \
        test TEST=test/integration/chunk_remote_journey_test.rb 2>&1 | tee tmp/journey-ci.txt
      journey_code=${PIPESTATUS[0]}

      LIBRARY_BACKEND=chunk_remote bin/rails test 2>&1 | tee tmp/chunk-remote-full.txt
      full_code=${PIPESTATUS[0]}
      set -e

      if grep -qE ', [1-9][0-9]* skips' tmp/journey-ci.txt; then
        echo "::error::the journey suite SKIPPED with a sync server configured and reachable."
        echo "A skip here means skip_unless_remote_server stopped discriminating, and the suite"
        echo "reported success having asserted nothing -- the failure this gate exists to make"
        echo "impossible."
        exit 1
      fi
      [ "$journey_code" -eq 0 ] || exit "$journey_code"
      exit "$full_code"
    SCRIPT
    ci.step "Tests: chunk_remote (journey + full suite, real sync server)", "bash", "-c", script
  end,

  # THE SYSTEM GATE NOW NEEDS A LIBRARY_PATH, AND IT DID NOT BEFORE. It sets no LIBRARY_BACKEND,
  # so it takes FileLayer.build's DEFAULT -- which was embedded `chunk` (needs no configuration at
  # all) and is `share` since Arc D Part 2 (reads ENV.fetch("LIBRARY_PATH") and raises without it).
  # Left alone, 82 of these tests failed with `KeyError: key not found: "LIBRARY_PATH"` several
  # frames from anything mentioning a backend.
  #
  # Same mktemp + trap discipline as the `test` gate above, and for the same reason: self-hosted
  # runners are PERSISTENT, so a stray tmpdir per run accumulates unbounded.
  "system" => ->(ci) do
    ci.step "Tests: System (real browser)",
            'd=$(mktemp -d); trap \'rm -rf "${d:?}"\' EXIT; ' \
            'env LIBRARY_BACKEND=share LIBRARY_PATH="$d" bin/rails db:test:prepare test:system'
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
