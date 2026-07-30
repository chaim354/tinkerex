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
