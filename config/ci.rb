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
  end,

  # The desktop app's JavaScript — the only JS gate in the repo. client/maker-app had no `test`
  # script, no test files and nothing in CI at all until 2026-08-19; the Rust `mod tests` next
  # door covers Prefs/creds_key/atomic writes and none of the frontend. §14c is the precedent for
  # landing the gate WITH the file rather than after it.
  #
  # No install step: `node` is on the mac runner's service PATH already (nvm 18.20.8, the first
  # entry in the runner's .path). If it ever is not, this goes RED — which is the right direction
  # for a gate whose whole content is the suite it runs.
  #
  # THE EMPTY-SUITE CHECK IS IN RUBY, AND NEITHER `node --test test/` NOR `node --test test/*.test.js`
  # IS A SUBSTITUTE — because which of them is safe DEPENDS ON THE NODE VERSION, and they invert.
  # Measured on this box: node 18.20.8 over an empty test dir gives directory-form exit 0 and
  # glob-form exit 1; node 24.16.0 gives the OPPOSITE, directory-form exit 1 and glob-form exit 0
  # (>=20 treats the argument as a pattern itself, so an unmatched pattern is 0 tests and success).
  # The runner's .path pins 18.20.8 today, but 24.16.0 is already installed on the same machine, so
  # a PATH bump would silently turn a gate written to refuse an empty suite into one that green-lights
  # it — this repo's dominant failure shape, one `nvm alias` away.
  #
  # So the file list is resolved HERE and passed to node EXPLICITLY. node then runs exactly those
  # files and its argument handling stops being load-bearing at all. A deleted suite aborts by name
  # instead of passing; a NEW *.test.js is still picked up with no edit here.
  "test-app" => ->(ci) do
    app   = File.expand_path("../client/maker-app", __dir__)
    files = Dir.glob("test/**/*.test.js", base: app).sort
    if files.empty?
      abort "bin/ci test-app: no *.test.js under client/maker-app/test — refusing to pass vacuously."
    end
    ci.step "Tests: Desktop app (node)", "cd client/maker-app && node --test #{files.join(" ")}"
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
