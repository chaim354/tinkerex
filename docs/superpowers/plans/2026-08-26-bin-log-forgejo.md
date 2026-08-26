# `bin/log` + Forgejo Setup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `bin/log`, the single write door onto the self-hosted Forgejo that will replace `docs/STATUS.md`, and prove it works before anything depends on it.

**Architecture:** A stdlib-only Ruby CLI at `bin/log` talking to Forgejo's REST API. It resolves its token through the existing `bin/secret` door, never handles the value on stderr, and spools to `tmp/log-pending/<branch>.md` when the box is unreachable. Tests run against a stub HTTP server on localhost and assert the **wire format**, never a round-trip through a fake that could share the code's misunderstanding.

**Tech Stack:** Ruby 3.4.7, stdlib only (`net/http`, `json`, `uri`, `open3`) — deliberately no Bundler and no Rails boot. Minitest via `ActiveSupport::TestCase`. Forgejo 11.0.16 at `forgejo.home`.

**Spec:** `docs/superpowers/specs/2026-08-26-status-to-forgejo-design.md`

**This is PR 1 of 2.** It deletes nothing; `docs/STATUS.md` still works throughout. PR 2 (the migration) is scoped at the end of this document and gets its detailed plan once this merges.

---

## Why stdlib only, and no `require "bundler/setup"`

`bin/secrets-preflight` requires Bundler because it needs the `kamal` gem. `bin/log` needs no gem at all, so it must not.

CLAUDE.md §14j records the trap: a bundled Ruby process sets `BUNDLE_GEMFILE` and a `RUBYOPT` that force-requires `bundler/setup` **process-wide**, and every child inherits both. `bin/log` will be invoked from inside `bin/ci`, from `/finish-branch`, and from `/deploy`. Requiring nothing keeps it indifferent to what launched it, and it boots in ~50 ms rather than paying a Rails boot.

---

## File Structure

| File | Responsibility |
|---|---|
| **Create** `bin/log` | The whole CLI. One file — it is a single door by design (spec §5), and splitting it would be the first step toward the two-write-paths shape §14a forbids |
| **Create** `test/log_cli_test.rb` | Guards: usage, wire format, token handling, unreachable behaviour, spool, `status` |
| **Create** `test/support/stub_forgejo.rb` | A localhost HTTP server that **records requests verbatim** and replays canned responses |
| **Modify** `CLAUDE.md` §13 | Add the `bin/log` cheatsheet block |

`tmp/log-pending/` is created at runtime and is already covered by the repo's `.gitignore` of `tmp/` — verify in Task 1, do not assume.

---

## Design corrections (2026-08-26, from Task 1's code review)

Task 1 shipped clean and passed both gates, then its code review found four defects **in this plan**. All four were reproduced before acting. They bind on every task below; where a later task's code block contradicts this section, **this section wins**.

### C1 [Critical] A helper that `exit`s never spools — and 502 is the likeliest outage

`exit` raises `SystemExit`, which is not a `StandardError` and not `Unreachable`, so it sails past the top-level `rescue`. Every helper that ended `exit EXIT_UNREACHABLE` — `token`, `create_issue`, `comment`, `setup`, `pull_request` — therefore exits 3 **without writing a spool file**, while Task 9 would have put the opposite in CLAUDE.md ("the entry lands in `tmp/log-pending/`").

Worse, `Unreachable` only fires on TCP-level failures. Forgejo's container down behind a live proxy is a **502** — an HTTP *response* — so the single most likely way the box breaks is the path that silently loses the arc. A rotated token (401) and a locked vault are the same class.

Reproduced: a helper calling `exit(3)` inside `begin/rescue Unreachable` never runs the rescue.

**Rule: no `exit` inside any helper. Raise `Unreachable`; `main` decides the exit code in one place.** This is §14a's `finalize_upload` argument — default to the safe answer so an unwritten caller that forgets gets working behaviour, not a silent gap.

### C2 [Critical] The payload rides on the exception; `PENDING_BODY`/`ARGV_SNAPSHOT` are deleted

A module-level accumulator is the seven-doors-and-no-funnel shape §14f rejects: only `create_issue` appended, `comment` never would, a future verb forgets, and the failure is a spool file with an empty body. It also **accumulates across calls**, so PR 2's import loop would spool issues already filed, and "file this" would duplicate them.

`api` already holds the built request, so it sets the payload at the one `raise` site. **A GET carries no payload, so a read verb spools nothing by construction** rather than by a rule someone has to remember — which also fixes read verbs (`show`, `search`) reporting phantom unfiled work forever.

### C3 [Critical] `assert_includes usage, "arc"` cannot fail — `se`**`arc`**`h` contains it

Reproduced: delete the entire `bin/log arc --from-pr N` usage line and the assertion stays green. Seven of the eight carry weight; the eighth is the subcommand this whole migration exists for.

**Rule: anchor to the documented line —** `assert_match(/^\s*bin\/log #{Regexp.escape(name)}\b/, usage)`.

### C4 Four lists of subcommands, already drifted at 62 lines

The set lived in the header comment, the `USAGE` heredoc, the `when` clause, and the test's `%w[]` — and the first two had *already* diverged ("read one" vs "Print one issue"). Nothing caught a `when`-vs-`USAGE` gap at all.

**Rule: one `SUBCOMMANDS` table. `USAGE` is derived from it and `main` dispatches on it.** §14d's "ONE file-type vocabulary", where `EXT_FAMILIES` is derived from `ROLE_BY_EXT` for exactly this reason.

### C5 Structure: `module Log` with `module_function`, and `Log.main(ARGV)` at the bottom

Top-level `def`s become private methods on `Object`. The live hazard is Task 3's natural spelling, `def open(title)`, which **shadows `Kernel#open` process-wide with no warning**. ~15 lines of diff now versus reindenting 300 later.

### C6 Two later tasks cannot run as written — both reproduced

- **Task 3's stub requires `webrick`**, which left stdlib in Ruby 3.0 and is **not in this repo's `Gemfile.lock`** (`LoadError`, verified). **Build the recorder on `TCPServer`** — ~20 lines — rather than adding a gem.
- **Task 2's `PATH => "/usr/bin:/bin"` resolves `#!/usr/bin/env ruby` to Ruby 2.6.10** (verified), which cannot parse the endless method `def repo_path(suffix) = ...` (verified: `syntax error, unexpected '='`). The test would see a SyntaxError and exit 1 while blaming credentials. **Do not nuke `PATH`** — put a failing `op` stub on a prepended tmpdir instead.

### C7 Test-harness hygiene — three rules for `run_log`

1. **Strip the inherited Bundler env.** `Open3.capture3(env, …)` *merges*, so every test today runs `bin/log` as a bundled child — the property "indifferent to its launcher" is exercised only in the direction that cannot fail. Reproduced: `BUNDLE_GEMFILE=/nonexistent RUBYOPT=-rbundler/setup ./bin/log status` dies with `Bundler::GemfileNotFound` before line 1. Clear the seven names `bin/sync-server`'s `unset_inherited_bundler_env` already lists. **A hostile-env test was considered and deliberately NOT written:** `RUBYOPT` is applied by the ruby binary before line 1, so `bin/log` genuinely cannot survive `RUBYOPT=-rbundler/setup` with a bad `BUNDLE_GEMFILE`, and no re-exec helps because the crash precedes it. The achievable guard is the **stale-`BUNDLE_GEMFILE`** test, which passes today and goes red the moment anyone adds `require "bundler/setup"` — it guards the property that actually matters operationally, "needs no `bundle install`". Stripping those names is the CALLER's obligation, recorded in Task 9's CLAUDE.md block.
2. **Default `FORGEJO_URL` to an unroutable address.** It defaults to `http://forgejo.home`, so a test that forgets to override it POSTs a real issue into the live instance. Reaching the network must be opt-in.
3. **Pass the command as `[BIN_LOG, BIN_LOG]`.** With zero trailing args Ruby takes the single-string form and word-splits, so a checkout path containing a space breaks — and the only committed test is exactly the zero-arg call.

### C8 Spool location must be overridable — the suite forks

`test_helper.rb` runs `parallelize(workers: :number_of_processors)`, and Tasks 5–6 `rm -rf`/`mkdir_p`/write the same absolute `tmp/log-pending` from different workers concurrently — flaky, and it is the developer's live spool. **Add a `LOG_SPOOL_DIR` override** (as `LOG_BRANCH` already does for the branch) and give each test a `Dir.mktmpdir`.

### C9 Minor, all confirmed

- **`--help`/`-h`/`help` print to stdout and exit 0**; a no-arg invocation stays stderr + exit 2. An asked-for usage is not an error.
- **Name `EXIT_UNFILED = 1`** rather than leaving `status`'s backlog code as a bare literal beside two named constants.
- **`URI.join(FORGEJO_URL, "/api/v1/…")` drops a path prefix** — Forgejo behind a subpath is an ordinary self-host shape. Build the URL by concatenation instead.
- **`.chomp` the token.** It relies on `bin/secret`'s `--no-newline` and nothing asserts it; a trailing newline is an `ArgumentError` inside the header assignment.
- **The test header claims "every assertion below is mutation-checked in Task 8"** — Task 8 never mutated the usage test. Task 8 now opens with that mutation.


---

## Task 0: Forgejo setup (owned by the user — blocks only Task 9's smoke test)

**These are not automatable — they need credentials this session must never handle.**

**Tasks 1–8 do not depend on this.** Every one of them drives a stub on localhost and never reaches `forgejo.home`, so implementation can start immediately and in parallel with these steps. The first thing that genuinely needs a live instance is Task 9 Step 4.

- [ ] **Step 1: Create the access token**

In Forgejo → Settings → Applications → Generate New Token. Scopes: `write:issue`, `read:repository`.

- [ ] **Step 2: Store it in 1Password**

Store as item `Forgejo`, field `token`, in the `tinkerex` vault, so the reference is `op://tinkerex/Forgejo/token`. Verify without printing it:

```bash
op read --no-newline op://tinkerex/Forgejo/token | wc -c
```

Expected: a byte count > 0. **Never** a command that prints the value.

- [ ] **Step 3: Create or pull-mirror the three repos**

`tinkerex`, `tinkerex-sync`, `tinkerex-client`. Forgejo → New Migration → GitHub, with "This repository will be a mirror" checked.

- [ ] **Step 4: Confirm the owner name and record it**

```bash
curl -sS -H "Authorization: token $(op read --no-newline op://tinkerex/Forgejo/token)" \
  'http://forgejo.home/api/v1/user' | python3 -c 'import sys,json; print(json.load(sys.stdin)["login"])'
```

Expected: the owner login, e.g. `chaim354`. If it is **not** `chaim354`, change the `FORGEJO_OWNER` default in Task 2 Step 3 — the stub tests pass either way because they set it explicitly, so a wrong default would survive the whole suite and fail only against the real box.

---

## Task 1 (REVISED): `bin/log` skeleton, usage, and the test harness

> **Supersedes commit `9ede0ec`.** That commit was spec-compliant and green; its code review found the four plan defects in "Design corrections" above. This task now restructures it. Land the change as a follow-up commit — the branch is unpushed but history rewriting buys nothing here.

**Files:**
- Modify: `bin/log`
- Modify: `test/log_cli_test.rb`

- [ ] **Step 1: Rewrite the test**

Replace `test/log_cli_test.rb` entirely:

```ruby
require "test_helper"
require "open3"
require "tmpdir"
require "fileutils"

# Guards bin/log — the SINGLE write door onto the Forgejo that replaces docs/STATUS.md.
#
# WHY A TEST FILE FOR A bin/ SCRIPT. bin/log is the only thing that records an arc, so a silent
# failure here loses the record with nothing going red — this repo's dominant failure shape
# (CLAUDE.md §15, "a green suite over something that never worked").
#
# THESE TESTS NEVER REACH forgejo.home, and that is enforced rather than asserted: run_log
# defaults FORGEJO_URL to an unroutable address, so touching the network is opt-in. Left at
# bin/log's own default a test that merely forgot to override it would POST a real issue into the
# live instance from anywhere on the LAN.
#
# THEY ASSERT THE WIRE FORMAT — exact path, headers, JSON body. §14e records why: FakeS3 decoded
# with CGI.unescape while the adapter encoded with CGI.escape, exact inverses, so 79/80 tests were
# green over silent permanent data loss. A fake that shares the code's misunderstanding confirms
# it rather than catching it.
class LogCliTest < ActiveSupport::TestCase
  BIN_LOG = Rails.root.join("bin/log").to_s

  # The seven names bin/sync-server's unset_inherited_bundler_env already clears. §14j: a bundled
  # parent exports these process-wide and every child inherits them, so a harness that MERGES its
  # own environment runs bin/log as a bundled child every time — exercising "needs no gem" only in
  # the direction that cannot fail. Deliberately NOT PATH/GEM_HOME/GEM_PATH, which is how the shell
  # finds ruby at all.
  BUNDLER_ENV = %w[BUNDLE_GEMFILE BUNDLE_BIN_PATH BUNDLE_LOCKFILE BUNDLER_VERSION
                   BUNDLER_SETUP RUBYOPT RUBYLIB].freeze

  # [BIN_LOG, BIN_LOG] is the explicit argv[0] form. With no trailing arguments Ruby takes the
  # single-string form and word-splits it, so a checkout path containing a space fails with ENOENT
  # on the first fragment — and the zero-argument call is exactly what the usage test makes.
  def run_log(*args, env: {})
    cleared = BUNDLER_ENV.to_h { |name| [ name, nil ] }
    base = cleared.merge("FORGEJO_URL" => "http://127.0.0.1:1")

    out, err, status = Open3.capture3(base.merge(env), [ BIN_LOG, BIN_LOG ], *args,
                                      chdir: Rails.root.to_s)
    [ out, err, status.exitstatus ]
  end

  test "no arguments prints usage on stderr and exits 2" do
    out, err, code = run_log

    assert_equal 2, code, "no-args must be a usage error, not a success"
    assert_empty out, "a usage printed because of an ERROR belongs on stderr"

    # ANCHORED TO THE DOCUMENTED LINE, NOT A SUBSTRING. `assert_includes usage, "arc"` cannot
    # fail — "se-arc-h" contains it — so deleting the arc line entirely left the guard green,
    # and arc is the subcommand this whole migration exists for. Reproduced before this changed.
    %w[setup arc open deploy note show search status].each do |name|
      assert_match(/^\s*bin\/log #{Regexp.escape(name)}\b/, err,
                   "usage has no line documenting `#{name}`")
    end
  end

  test "--help prints usage on stdout and exits 0" do
    out, _err, code = run_log("--help")

    assert_equal 0, code, "an asked-for usage is not an error"
    assert_match(/^\s*bin\/log arc\b/, out,
                 "--help must reach stdout, so `bin/log --help | less` works")
  end

  # THE STDLIB-ONLY RULE, GUARDED RATHER THAN CLAIMED. A stale BUNDLE_GEMFILE is inert only
  # because nothing here loads bundler; add `require "bundler/setup"` to bin/log and this goes red.
  # (It cannot guard against an inherited RUBYOPT force-requiring bundler — that is applied by the
  # ruby binary before line 1, so the script has no opportunity to defend itself. Stripping those
  # names is the CALLER's obligation, which is why run_log does it and why Task 9 records it.)
  test "runs with a stale BUNDLE_GEMFILE, because it loads no gem" do
    out, err, code = run_log("--help", env: { "BUNDLE_GEMFILE" => "/nonexistent/Gemfile" })

    assert_equal 0, code, "bin/log consulted a Gemfile it does not need: #{err}"
    assert_match(/^\s*bin\/log arc\b/, out)
  end

  test "an unknown command names it and exits 2" do
    _out, err, code = run_log("frobnicate")

    assert_equal 2, code
    assert_includes err, "frobnicate"
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rails test test/log_cli_test.rb
```

Expected: FAIL. The old `bin/log` has no `--help` arm (exits 2, prints nothing to stdout) and writes its no-arg usage where the new assertions do not expect it.

- [ ] **Step 3: Rewrite `bin/log`**

Replace it entirely:

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

# THE SINGLE WRITE DOOR onto the Forgejo that replaces docs/STATUS.md.
# `bin/log --help` lists the subcommands; they are defined once, in SUBCOMMANDS.
#
# WHY ONE DOOR. An MCP write path plus a CLI write path is one verb with two answers — the shape
# CLAUDE.md §14a forbids and the shape §14d spent five copies of the `port_writable?` branch
# learning to avoid. MCP stays available for READING and browsing; it is never required, and it
# never writes. A CLI also works everywhere MCP does not: CI, cloud sessions, subagents, worktrees.
#
# NO BUNDLER, NO RAILS, STDLIB ONLY. §14j records that a bundled Ruby process exports
# BUNDLE_GEMFILE and a RUBYOPT force-requiring bundler/setup process-wide, and every child
# inherits both. Loading no gem means this script never needs `bundle install` — a fresh clone, a
# worktree and a cloud session all run it. It is NOT full immunity: an inherited RUBYOPT is applied
# by the ruby binary before line 1, so a caller launching this from inside a bundled process must
# clear those names itself, exactly as bin/sync-server does.
#
# NOTHING BELOW CALLS `exit`. Helpers raise; Log.main decides the code in ONE place. A helper that
# exited raised SystemExit — not a StandardError, not Unreachable — so it sailed straight past the
# rescue that spools, losing the record on the likeliest outage there is (a 502 from a dead
# container behind a live proxy) while the docs promised a spool file.
require "fileutils"
require "json"
require "net/http"
require "open3"
require "uri"

module Log
  module_function

  EXIT_OK          = 0
  EXIT_UNFILED     = 1   # `status` found a backlog. Loud on purpose, like bin/backup-status.
  EXIT_USAGE       = 2   # the caller spelled the command wrong
  EXIT_UNREACHABLE = 3   # Forgejo or the vault could not be reached; any write is spooled

  # ONE TABLE, NOT FOUR LISTS. USAGE is DERIVED from this and `main` dispatches on it, so a
  # subcommand cannot exist in one place and be missing from another. §14d's "ONE file-type
  # vocabulary": EXT_FAMILIES is derived from ROLE_BY_EXT precisely because the second inline list
  # had already drifted. This file's own first draft drifted between its header and its usage text
  # before it was 62 lines old.
  SUBCOMMANDS = {
    "setup"  => [ "",               "Create the labels, idempotently" ],
    "arc"    => [ "--from-pr N",    "Arc issue built from PR N's body" ],
    "open"   => [ '"<title>"',      "File an open item" ],
    "deploy" => [ "--image SHA",    "Record a deploy" ],
    "note"   => [ 'ISSUE "<text>"', "Append a comment to a past issue" ],
    "show"   => [ "ISSUE",          "Print one issue" ],
    "search" => [ '"<query>"',      "Search issues" ],
    "status" => [ "",               "Report anything unfiled" ]
  }.freeze

  def usage_text
    rows = SUBCOMMANDS.map do |name, (args, description)|
      "    " + "bin/log #{name} #{args}".rstrip.ljust(34) + description
    end

    ([ "bin/log — record work in Forgejo. The single write door.", "" ] + rows + [
      "",
      "Env: FORGEJO_URL (default http://forgejo.home), FORGEJO_OWNER, FORGEJO_REPO,",
      "     LOG_SPOOL_DIR (default tmp/log-pending), LOG_BRANCH"
    ]).join("\n")
  end

  def main(argv)
    command = argv.shift

    # AN ASKED-FOR USAGE IS NOT AN ERROR: stdout, exit 0, so `bin/log --help | less` works.
    # A no-argument invocation IS one, so it goes to stderr and exits 2.
    if [ "--help", "-h", "help" ].include?(command)
      puts usage_text
      return EXIT_OK
    end

    if command.nil?
      warn usage_text
      return EXIT_USAGE
    end

    unless SUBCOMMANDS.key?(command)
      warn "bin/log: unknown command #{command.inspect}"
      warn usage_text
      return EXIT_USAGE
    end

    dispatch(command, argv)
  end

  # Tasks 2-7 replace this arm by arm. Every subcommand is declared in SUBCOMMANDS from the start
  # so an unbuilt one says "not implemented yet" rather than "unknown command" — the caller learns
  # which of the two it is.
  def dispatch(command, _argv)
    warn "bin/log: #{command} is not implemented yet"
    EXIT_USAGE
  end
end

exit Log.main(ARGV)
```

- [ ] **Step 4: Run to verify it passes**

```bash
bin/rails test test/log_cli_test.rb
```

Expected: PASS, 4 tests.

- [ ] **Step 5: Check rubocop, since this is new structure**

```bash
bin/rubocop bin/log test/log_cli_test.rb
```

Expected: no offenses. Fix any that appear rather than adding a `rubocop:disable`.

- [ ] **Step 6: Mutation-check the assertion the review found vacuous**

Delete the `"arc" => [ "--from-pr N", ... ]` row from `SUBCOMMANDS`, run the usage test, and confirm it now goes **RED** (the previous spelling stayed green, because "search" contains "arc"). Restore, confirm green.

```bash
bin/rails test test/log_cli_test.rb -n /no arguments/
```

- [ ] **Step 7: Commit**

```bash
git add bin/log test/log_cli_test.rb
git commit -m "bin/log: one subcommand table, no exit inside helpers, and a usage guard that can fail

Task 1's code review found four defects in the plan, all reproduced. The
assertion for \`arc\` could never fail, because \"search\" contains \"arc\" —
deleting the arc line left the guard green. The subcommand set lived in four
places and two had already drifted. Top-level defs would have let Task 3's
natural \`def open\` shadow Kernel#open process-wide. And a helper calling exit
raises SystemExit, which is neither StandardError nor Unreachable, so it would
have sailed past the rescue that spools — losing the record on a 502, the
likeliest outage, while CLAUDE.md promised a spool file.

USAGE is now derived from one SUBCOMMANDS table, helpers raise rather than exit,
the harness clears the inherited bundler env instead of merging it, and
FORGEJO_URL defaults to an unroutable address so reaching the network is opt-in.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---
## Task 2: The transport — token, `api`, and an exit code that cannot be forgotten

Everything below is written against the `module Log` structure Task 1 landed. There is no `case command` block and no top-level `def`; add methods **inside `module Log`**, above `main`.

**Files:** modify `bin/log`, `test/log_cli_test.rb`

- [ ] **Step 1: Write the failing tests**

Append inside `LogCliTest`:

```ruby
  # THE TOKEN MUST NEVER REACH fd2. bin/secret's header records the mechanism: writing
  # `op read "$ref" 2>&1 >/dev/null` points fd2 at the CURRENT stdout and only then moves fd1, so
  # the value lands in whatever captured the command. That printed a live ghcr PAT into an agent
  # transcript on 2026-07-29 and the token had to be rotated. Open3.capture3 keeps the streams
  # apart, which is why bin/log must use it rather than a backtick or a merging redirect.
  test "a resolved token never appears on either stream" do
    out, err, _code = run_log("show", "1", env: { "FORGEJO_TOKEN" => "sentinel-token-value" })

    refute_includes err, "sentinel-token-value", "the token reached stderr"
    refute_includes out, "sentinel-token-value", "the token reached stdout"
  end

  # AN EXPORTED VALUE WINS OVER THE VAULT — bin/secret's own documented order, which bin/log gets
  # for free by going through that door instead of calling `op` itself. Asserting it is what stops
  # someone "simplifying" bin/log into a direct `op read` and silently dropping the override.
  #
  # THE VAULT IS DEFEATED WITH A STUB `op` ON A PREPENDED PATH, NOT BY NUKING PATH. Setting
  # PATH=/usr/bin:/bin resolves `#!/usr/bin/env ruby` to /usr/bin/ruby, which is 2.6.10 on this
  # box and cannot parse an endless method — the test would have died of SyntaxError while its
  # message blamed credentials. Reproduced before this was written.
  test "an exported FORGEJO_TOKEN is used without consulting 1Password" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "op"), "#!/bin/sh\necho 'op: vault locked' >&2\nexit 1\n")
      File.chmod(0o755, File.join(dir, "op"))

      _out, err, code = run_log("show", "1", env: {
        "FORGEJO_TOKEN" => "exported-wins",
        "PATH"          => "#{dir}:#{ENV['PATH']}"
      })

      assert_equal 3, code, "expected the UNREACHABLE exit, not a credential failure"
      refute_includes err, "vault locked",
                      "bin/log consulted the vault despite an exported value — the override was lost"
    end
  end

  # exit(nil) is a TypeError and exit(false) is a SILENT status 1 — and 1 is EXIT_UNFILED, so an
  # arm that forgets its return value would report a SUCCESSFUL file to /finish-branch as a
  # backlog. Note an `assert_equal 0, code` test cannot catch a `true`-returning arm.
  test "main returning a non-integer is loud, not a wrong exit code" do
    _out, err, code = run_log("--help", env: { "LOG_FORCE_BAD_RETURN" => "1" })

    assert_equal 1, code
    assert_match(/not an exit code/, err,
                 "a non-integer return exited silently — 1 is EXIT_UNFILED, so success reads as a backlog")
  end
```

- [ ] **Step 2: Run to verify they fail**

`bin/rails test test/log_cli_test.rb` — `show` exits 2 (not implemented), not 3.

- [ ] **Step 3: Implement, inside `module Log`**

Add after `SUBCOMMANDS`:

```ruby
  TOKEN_REF = "op://tinkerex/Forgejo/token"

  # THE PAYLOAD RIDES ON THE EXCEPTION, never on a module-level accumulator. `api` knows both what
  # failed and what was being sent, so it attaches the payload at the ONE raise site. Two things
  # fall out that a shared accumulator could not give: a GET carries no payload, so a READ verb
  # spools nothing BY CONSTRUCTION rather than by a rule someone remembers to apply; and nothing
  # accumulates across calls, so a loop failing on its Nth write cannot re-spool the N-1 already
  # filed. (PR 2's import is exactly that loop.)
  class Unreachable < StandardError
    attr_reader :payload

    def initialize(message, payload: nil)
      super(message)
      @payload = payload
    end
  end

  def forgejo_url = ENV.fetch("FORGEJO_URL", "http://forgejo.home")
  def owner       = ENV.fetch("FORGEJO_OWNER", "chaim354")
  def repo        = ENV.fetch("FORGEJO_REPO", "tinkerex")

  def repo_path(suffix) = "/api/v1/repos/#{owner}/#{repo}#{suffix}"

  # THROUGH bin/secret, NEVER `op read` DIRECTLY. That file is this repo's single definition of
  # where a credential comes from, and it is what makes an exported value win over the vault.
  # capture3 keeps the streams apart: bin/secret sends the value only on fd1 and its diagnostics
  # only on fd2, so forwarding err cannot leak. Any rewrite that merges them re-opens the
  # 2026-07-29 leak. `.chomp` because nothing else asserts bin/secret's --no-newline contract, and
  # a trailing newline is an ArgumentError inside the header assignment.
  def token
    @token ||= begin
      out, err, status = Open3.capture3(File.expand_path("secret", __dir__), "FORGEJO_TOKEN", TOKEN_REF)
      raise Unreachable, "could not resolve FORGEJO_TOKEN from #{TOKEN_REF}: #{err.strip}" if !status.success? || out.empty?

      out.chomp
    end
  end

  def api(method, path, body = nil)
    perform(method, path, body)
  rescue Unreachable => e
    # Attach what was being sent, at the one place that knows both. A failure raised from `token`
    # carries no payload of its own, and a WRITE must still be spooled.
    raise(e.payload ? e : Unreachable.new(e.message, payload: body))
  rescue SystemCallError, Net::OpenTimeout, Net::ReadTimeout, SocketError => e
    raise Unreachable.new("#{forgejo_url}: #{e.message}", payload: body)
  end

  # URI.join DROPS A PATH PREFIX — URI.join("http://host/git", "/api/v1/x") is
  # "http://host/api/v1/x". Forgejo behind a subpath is an ordinary self-host shape, so the URL is
  # built by concatenation instead.
  def perform(method, path, body)
    uri = URI.parse("#{forgejo_url.chomp('/')}#{path}")

    request = case method
              when :get  then Net::HTTP::Get.new(uri)
              when :post then Net::HTTP::Post.new(uri)
              else raise ArgumentError, "unsupported method #{method.inspect}"
              end

    request["Authorization"] = "token #{token}"
    request["Content-Type"]  = "application/json"
    request.body = JSON.generate(body) if body

    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                                   open_timeout: 5, read_timeout: 15) do |http|
      http.request(request)
    end

    # A NON-2xx IS UNREACHABLE TOO, AND THAT IS THE POINT OF THIS METHOD. A dead container behind
    # a live proxy answers 502 and a rotated token answers 401 — both are HTTP RESPONSES, so a
    # handler that only caught connection errors would let the LIKELIEST outage exit without
    # spooling, which is how an arc gets lost while the docs promise otherwise.
    unless response.code.to_i.between?(200, 299)
      raise Unreachable, "HTTP #{response.code} from #{path}: #{response.body.to_s[0, 200]}"
    end

    response
  end

  def show(argv)
    number = argv.shift or raise UsageError, "show needs an issue number"
    issue = JSON.parse(api(:get, repo_path("/issues/#{number}")).body)

    puts "##{issue['number']} #{issue['title']} [#{issue['state']}]"
    puts
    puts issue["body"]
    EXIT_OK
  end

  class UsageError < StandardError; end
```

Replace `dispatch` with a real table, and extend `main`:

```ruby
  # EVERY ARM ENDS IN AN EXPLICIT EXIT_* CONSTANT. `puts` returns nil, and exit(nil) is a
  # TypeError whose status is 1 — which is EXIT_UNFILED. An arm that forgets would report a
  # successful file as a backlog. The guard at the bottom of the file makes that loud.
  def dispatch(command, argv)
    case command
    when "show" then show(argv)
    else
      warn "bin/log: #{command} is not implemented yet"
      EXIT_USAGE
    end
  end
```

In `main`, add `UsageError` handling and the `Unreachable` rescue (the spool arrives in Task 5):

```ruby
    dispatch(command, argv)
  rescue UsageError => e
    warn "bin/log: #{e.message}"
    warn usage_text
    EXIT_USAGE
  rescue Unreachable => e
    warn "bin/log: Forgejo is unreachable — #{e.message}"
    EXIT_UNREACHABLE
  end
```

And replace the file's last line:

```ruby
code = Log.main(ARGV)
code = "not-an-integer" if ENV["LOG_FORCE_BAD_RETURN"]   # exercises the guard below; see the test

raise "bin/log: main returned #{code.inspect}, not an exit code" unless code.is_a?(Integer)

exit code
```

- [ ] **Step 4: Run to verify they pass** — `bin/rails test test/log_cli_test.rb`, expect PASS, 7 tests.
- [ ] **Step 5: `bin/rubocop bin/log test/log_cli_test.rb`** — expect no offenses.
- [ ] **Step 6: Commit** — subject: `bin/log: the transport, with a 502 treated as unreachable`. Body: name why a non-2xx must raise rather than exit, and why the token goes through `bin/secret`. End with the `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>` trailer.

---

## Task 3: The stub Forgejo, and the wire format for `open`

**Files:** create `test/support/stub_forgejo.rb`; modify `bin/log`, `test/log_cli_test.rb`

- [ ] **Step 1: Write the stub — `TCPServer`, not WEBrick**

`webrick` left stdlib in Ruby 3.0 and is **not in this repo's `Gemfile.lock`** — `require "webrick"` is a `LoadError` here (verified). Rather than add a gem for a test double, hand-roll the recorder. Create `test/support/stub_forgejo.rb`:

```ruby
require "socket"
require "json"

# A localhost stand-in for Forgejo that RECORDS REQUESTS VERBATIM.
#
# It deliberately does NOT model Forgejo. It captures method, path, headers and raw body, and
# replays whatever the test told it to. §14e records why that distinction matters: FakeS3 decoded
# with CGI.unescape while the adapter encoded with CGI.escape — exact inverses — so 79 of 80 tests
# were green over silent permanent data loss on any filename containing a space. A fake that
# implements the same misunderstanding as the code under test confirms it rather than catching it.
# So: assert against `stub.requests`, never against a round-trip through this object.
#
# FIVE RULES, EACH A REAL WAY THIS BITES IN A FORKING SUITE (test_helper parallelizes by processor):
#
#   1. NEVER CONSTRUCT ONE BEFORE THE FORK. A child inherits the LISTENING SOCKET but not the
#      accept thread, so `connect` still succeeds and the request lands in the parent's backlog —
#      worker A's bin/log recorded by worker B's stub. Build it inside the test body. Never a
#      class constant, never parallelize_setup.
#   2. READ EXACTLY Content-Length BYTES, NEVER TO EOF. Net::HTTP holds the socket open awaiting a
#      response, so read-to-EOF deadlocks until the 15 s read timeout and the test then sees exit 3
#      with an empty `requests` — which reads as "bin/log sent nothing".
#   3. RESPOND WITH AN EXPLICIT Content-Length AND Connection: close.
#   4. THE ACCEPT LOOP RESCUES IOError/EBADF/ECONNRESET, AND close JOINS INSIDE A RESCUE. Closing
#      the socket while a thread blocks in accept raises there; unrescued it surfaces at `join`
#      inside an ensure and fails an otherwise-passing test, masking the real assertion.
#   5. PORT 0 binds and listens before `new` returns, so `url` is valid immediately — no
#      did-it-start race — and forked workers can never collide on a port.
class StubForgejo
  Request = Struct.new(:method, :path, :headers, :body, keyword_init: true) do
    def json = JSON.parse(body)
  end

  attr_reader :requests

  def initialize(status: 201, response: { "number" => 42, "title" => "stub", "state" => "open", "body" => "" })
    @requests = []
    @errors = []
    @server = TCPServer.new("127.0.0.1", 0)
    @payload = JSON.generate(response)
    @status = status

    @thread = Thread.new do
      loop do
        socket = @server.accept
        handle(socket)
      rescue IOError, Errno::EBADF, Errno::ECONNRESET
        break
      end
    end
  end

  def url = "http://127.0.0.1:#{@server.addr[1]}"

  def shutdown
    @server.close
  rescue IOError, Errno::EBADF
    nil
  ensure
    begin
      @thread&.join(5)
    rescue IOError, Errno::EBADF, Errno::ECONNRESET
      nil
    end
  end

  private

  # HANDLE RESCUES EVERYTHING, AND THAT CLOSES TWO FAILURES AT ONCE. Measured: if `handle` raises,
  # the `ensure socket.close` fires with no response written and the client sits on its 15 s read
  # timeout, after which bin/log reports "Forgejo is unreachable - Net::ReadTimeout" - so a STUB
  # BUG presents as a transport failure, costs 15 s per affected test, and multiplies by three
  # backend legs. Separately, a non-IO exception kills the accept thread, and `Thread#join`
  # RE-RAISES it from inside the test's `ensure`, masking the assertion that actually failed.
  # Answering 500 with the diagnostic fails the client fast AND keeps the thread alive; `errors`
  # lets a test assert the stub itself stayed healthy.
  attr_reader :errors

  def handle(socket)
    request_line = socket.gets.to_s
    method, path, = request_line.split(" ")

    headers = {}
    while (line = socket.gets) && line != "\r\n"
      key, value = line.split(":", 2)
      headers[key.to_s.strip.downcase] = value.to_s.strip
    end

    body = headers["content-length"] ? socket.read(headers["content-length"].to_i).to_s : ""
    @requests << Request.new(method: method, path: path, headers: headers, body: body)

    respond(socket, @status, @payload)
  rescue StandardError => e
    @errors << e
    respond(socket, 500, JSON.generate({ "stub_error" => "#{e.class}: #{e.message}" }))
  ensure
    socket.close rescue nil
  end

  def respond(socket, status, payload)
    socket.write("HTTP/1.1 #{status}\r\nContent-Type: application/json\r\n" \
                 "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
  end
end
```

- [ ] **Step 2: Write the failing wire-format test**

Add `require "support/stub_forgejo"` under the other requires, then:

```ruby
  # THE WIRE FORMAT IS THE ASSERTION. Not "the issue came back with our title" — that passes even
  # when both sides share a bug. Path, auth header and JSON body, each checked literally.
  test "open POSTs the documented issue payload to the documented path" do
    stub = StubForgejo.new

    out, err, code = run_log("open", "The scan tombstones a live node", env: {
      "FORGEJO_TOKEN" => "t0ken", "FORGEJO_URL" => stub.url,
      "FORGEJO_OWNER" => "chaim354", "FORGEJO_REPO" => "tinkerex"
    })

    assert_equal 0, code, "bin/log open failed: #{err}"
    assert_equal 1, stub.requests.size, "expected exactly one API call"
    assert_includes out, "#42"

    request = stub.requests.first
    assert_equal "POST", request.method
    assert_equal "/api/v1/repos/chaim354/tinkerex/issues", request.path
    assert_equal "token t0ken", request.headers["authorization"]
    assert_equal "application/json", request.headers["content-type"]

    assert_equal "The scan tombstones a live node", request.json["title"]
    assert_equal [ "open-work" ], request.json["labels"],
                 "an open item without the open-work label is invisible to the open-work view"
  ensure
    stub&.shutdown
  end
```

Add a second test — the real trigger for Task 2b's catch-all, covering it without a second test hook in production code:

```ruby
  # A 2xx WHOSE BODY IS NOT JSON IS AN OUTAGE, NOT A CRASH. A proxy error page and Forgejo's own
  # login page on a session redirect both arrive as 200 text/html. Unwrapped, JSON::ParserError
  # escaped to Ruby's default handler and exited 1 — which was EXIT_UNFILED, so a broken proxy
  # reported a backlog.
  test "a 2xx with a non-JSON body is unreachable, not a stack trace" do
    stub = StubForgejo.new(status: 200, response: "<html>502 Bad Gateway</html>")

    _out, err, code = run_log("show", "1", env: {
      "FORGEJO_TOKEN" => "t0ken", "FORGEJO_URL" => stub.url
    })

    assert_equal 3, code, "a non-JSON 2xx did not reach the clean unreachable exit"
    assert_includes err, "non-JSON body"
    refute_includes err, "JSON::ParserError:", "a raw parser error reached the user"
    assert_empty stub.errors, "the stub itself raised: #{stub.errors.map(&:message)}"
  ensure
    stub&.shutdown
  end
```

`StubForgejo#initialize` JSON-encodes `response`; this test needs it sent raw, so make it
`@payload = response.is_a?(String) ? response : JSON.generate(response)`.

- [ ] **Step 3: Run to verify it fails** — exit 2, `open is not implemented yet`.

- [ ] **Step 4: Implement, inside `module Log`**

```ruby
  # LABELS ARE NAMES ON THE WIRE, NOT IDS. Forgejo accepts either; names are what a human reads in
  # a diff and what survives the labels being recreated. `setup` guarantees they exist.
  def create_issue(title, body:, labels:)
    JSON.parse(api(:post, repo_path("/issues"), { title: title, body: body, labels: labels }).body)
  end

  # NOT `open` — inside this module that name would resolve ahead of Kernel#open for every other
  # method here, and File.open is one edit away from being needed.
  def open_item(argv)
    title = argv.shift or raise UsageError, "open needs a title"
    issue = create_issue(title, body: argv.shift.to_s, labels: [ "open-work" ])

    puts "##{issue['number']} #{issue['title']}"
    EXIT_OK
  end
```

Add `when "open" then open_item(argv)` to `dispatch`.

- [ ] **Step 5: Run to verify it passes** — PASS, 10 tests.
- [ ] **Step 6: Run the file 5× to shake out the fork/socket rules** — `for i in 1 2 3 4 5; do bin/rails test test/log_cli_test.rb || break; done`. Any hang or intermittent failure means one of the stub's five rules was not followed; fix it rather than retrying.
- [ ] **Step 7: rubocop, then commit** — subject: `bin/log open, asserted on the wire format rather than a round-trip`.

---

## Task 4: `arc --from-pr` — one document, filed rather than rewritten

**Files:** modify `bin/log`, `test/log_cli_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
  # THE ARC BODY IS THE PR BODY. /finish-branch already specifies that document — symptom, root
  # cause, why tests missed it, verification table, scope. Rewriting it into a second document by
  # hand is exactly the per-PR tax that made docs/STATUS.md unworkable, so bin/log reads it back
  # out of the PR. GH_BIN stubs `gh`; Task 8 mutation-checks that the stub is actually consulted.
  test "arc --from-pr builds the issue from the PR body and links back to it" do
    stub = StubForgejo.new

    Dir.mktmpdir do |dir|
      gh = File.join(dir, "gh")
      File.write(gh, <<~SH)
        #!/bin/sh
        cat <<'JSON'
        {"title":"Fix the tombstone cascade","body":"## Root cause\\nThe delete was applied per-node.","url":"https://github.com/chaim354/tinkerex/pull/261"}
        JSON
      SH
      File.chmod(0o755, gh)

      _out, err, code = run_log("arc", "--from-pr", "261", env: {
        "FORGEJO_TOKEN" => "t0ken", "FORGEJO_URL" => stub.url,
        "FORGEJO_OWNER" => "chaim354", "FORGEJO_REPO" => "tinkerex", "GH_BIN" => gh
      })

      assert_equal 0, code, "bin/log arc failed: #{err}"
      request = stub.requests.first

      assert_equal "Fix the tombstone cascade", request.json["title"]
      assert_includes request.json["body"], "The delete was applied per-node.",
                      "the PR body was not carried into the arc issue"
      assert_includes request.json["body"], "https://github.com/chaim354/tinkerex/pull/261",
                      "the arc must link the PR it describes, or the diff is unreachable from the record"
      assert_equal [ "arc" ], request.json["labels"]
    end
  ensure
    stub&.shutdown
  end
```

- [ ] **Step 2: Run to verify it fails.**
- [ ] **Step 3: Implement, inside `module Log`**

```ruby
  # GH_BIN is an override, not a convenience — it is what lets the suite drive this path with no
  # network and no GitHub credential. Defaulting to the PATH lookup keeps normal use unchanged.
  def pull_request(number)
    out, err, status = Open3.capture3(ENV.fetch("GH_BIN", "gh"), "pr", "view", number.to_s,
                                      "--json", "title,body,url")
    raise Unreachable, "could not read PR #{number}: #{err.strip}" unless status.success?

    JSON.parse(out)
  end

  def arc(argv)
    raise UsageError, "arc needs --from-pr N" unless argv.shift == "--from-pr"

    number = argv.shift or raise UsageError, "arc needs --from-pr N"
    pr = pull_request(number)
    issue = create_issue(pr["title"], body: "#{pr['body']}\n\n---\nPR: #{pr['url']}\n", labels: [ "arc" ])

    puts "##{issue['number']} #{issue['title']}"
    EXIT_OK
  end
```

Add `when "arc" then arc(argv)` to `dispatch`.

- [ ] **Step 4: Run to verify it passes** — PASS, 9 tests.
- [ ] **Step 5: rubocop, then commit** — subject: `bin/log arc --from-pr: file the PR body, do not rewrite it`.

---

## Task 5: Unreachable — fail loudly, spool, let the caller proceed

**Files:** modify `bin/log`, `test/log_cli_test.rb`

- [ ] **Step 1: Write the failing tests**

```ruby
  # THE CHOSEN FAILURE MODE: loud, spooled, NON-BLOCKING. Blocking the close-out was considered and
  # declined; so was a spool that replays automatically, because a queue that silently drains is
  # data loss wearing a fix. What remains must make the debt VISIBLE — that is `bin/log status`.
  #
  # LOG_SPOOL_DIR IS NOT A TEST CONVENIENCE. test_helper parallelizes by processor, so without it
  # these tests rm -rf and write the SAME absolute path from several forked workers at once — and
  # that path is the developer's real spool.
  test "an unreachable Forgejo spools the write, says so, and exits 3" do
    Dir.mktmpdir do |spool|
      _out, err, code = run_log("open", "Something worth keeping", env: {
        "FORGEJO_TOKEN" => "t0ken", "LOG_SPOOL_DIR" => spool, "LOG_BRANCH" => "claude/example"
      })

      assert_equal 3, code, "unreachable must be its own code, distinguishable from a usage error"

      spooled = File.join(spool, "claude-example.md")
      assert File.exist?(spooled), "the entry was not spooled — it is simply lost"
      assert_includes File.read(spooled), "Something worth keeping"
      assert_includes err, spooled, "the spool path must be PRINTED; an invisible spool drains silently"
    end
  end

  # A 502 FROM A DEAD CONTAINER BEHIND A LIVE PROXY IS THE LIKELIEST REAL OUTAGE, and it is an HTTP
  # RESPONSE — so a handler that only caught connection errors would exit 3 without spooling while
  # the docs promised a spool file. This is the case the whole raise-don't-exit restructure exists
  # for; it is asserted, not argued.
  test "an HTTP error response spools too, not just a refused connection" do
    stub = StubForgejo.new(status: 502, response: { "message" => "bad gateway" })

    Dir.mktmpdir do |spool|
      _out, err, code = run_log("open", "Filed during an outage", env: {
        "FORGEJO_TOKEN" => "t0ken", "FORGEJO_URL" => stub.url,
        "LOG_SPOOL_DIR" => spool, "LOG_BRANCH" => "claude/example"
      })

      assert_equal 3, code
      assert_includes err, "502"
      assert_includes File.read(File.join(spool, "claude-example.md")), "Filed during an outage",
                      "a 502 exited without spooling — the exact hole the raise-don't-exit rule closes"
    end
  ensure
    stub&.shutdown
  end

  # A READ VERB HAS NOTHING TO FILE. Spooling one would make `bin/log status` report unfiled work
  # that never existed, permanently, since nothing drains it — a false positive in the one
  # mechanism whose whole job is making real debt visible.
  test "a failed read spools nothing" do
    Dir.mktmpdir do |spool|
      _out, _err, code = run_log("show", "1", env: {
        "FORGEJO_TOKEN" => "t0ken", "LOG_SPOOL_DIR" => spool
      })

      assert_equal 3, code
      assert_empty Dir.glob(File.join(spool, "*.md")),
                   "a read verb spooled phantom work — status will report it forever"
    end
  end
```

- [ ] **Step 2: Run to verify they fail.**
- [ ] **Step 3: Implement, inside `module Log`**

```ruby
  def spool_dir = ENV.fetch("LOG_SPOOL_DIR", File.expand_path("../tmp/log-pending", __dir__))

  # THE BRANCH NAMES THE SPOOL FILE, so two branches cannot overwrite each other's unfiled record.
  def current_branch
    ENV["LOG_BRANCH"] || Open3.capture2("git", "branch", "--show-current").first.strip
  end

  def spool!(command, payload)
    FileUtils.mkdir_p(spool_dir)
    path = File.join(spool_dir, "#{current_branch.tr('/', '-')}.md")
    File.open(path, "a") { |f| f.puts("# unfiled: #{command}", "", JSON.pretty_generate(payload), "") }
    path
  end
```

Replace `main`'s `rescue Unreachable` arm:

```ruby
  rescue Unreachable => e
    warn "bin/log: Forgejo is unreachable — #{e.message}"

    if e.payload.nil?
      warn "bin/log: nothing to file (#{command} sends no payload)."
      return EXIT_UNREACHABLE
    end

    path = spool!(command, e.payload)
    warn "bin/log: the entry was NOT filed. It is spooled at #{path}"
    warn "bin/log: `bin/log status` will keep reporting it until you file it."
    EXIT_UNREACHABLE
  end
```

Add `LOG_SPOOL_DIR (default tmp/log-pending), LOG_BRANCH` to `usage_text`'s env line — it is real from this task on, and advertising it earlier would have been a false claim in the file whose whole point is being an honest record.

- [ ] **Step 4: Run to verify they pass** — PASS, 12 tests.
- [ ] **Step 5: rubocop, then commit** — subject: `bin/log: a 502 spools like a refused connection, and reads spool nothing`.

---

## Task 6: `bin/log status` and `bin/log setup`

**Files:** modify `bin/log`, `test/log_cli_test.rb`

- [ ] **Step 1: Write the failing tests**

```ruby
  test "status is quiet and exits 0 when nothing is unfiled" do
    Dir.mktmpdir do |spool|
      out, _err, code = run_log("status", env: { "LOG_SPOOL_DIR" => spool })

      assert_equal 0, code
      assert_includes out, "nothing unfiled"
    end
  end

  # STATUS FAILS LOUD ON A BACKLOG. bin/backup-status exists for the same reason and says so in its
  # header: a nightly that stops is silent, and the failure looks exactly like success right up
  # until the restore. An unfiled arc is the same shape.
  test "status names every spooled entry and exits EXIT_UNFILED" do
    Dir.mktmpdir do |spool|
      File.write(File.join(spool, "claude-example.md"), "# unfiled: open\n")

      out, _err, code = run_log("status", env: { "LOG_SPOOL_DIR" => spool })

      assert_equal 4, code, "an outstanding record must fail loud, not print a note and exit 0"
      refute_equal 1, code,
                   "EXIT_UNFILED must not be Ruby's own crash status, or a crash reads as a backlog"
      assert_includes out, "claude-example.md"
    end
  end

  test "setup creates each label idempotently, by name" do
    stub = StubForgejo.new(status: 201, response: { "id" => 1, "name" => "arc" })

    _out, err, code = run_log("setup", env: {
      "FORGEJO_TOKEN" => "t0ken", "FORGEJO_URL" => stub.url,
      "FORGEJO_OWNER" => "chaim354", "FORGEJO_REPO" => "tinkerex"
    })

    assert_equal 0, code, "bin/log setup failed: #{err}"

    created = stub.requests.select { |r| r.method == "POST" }.map { |r| r.json["name"] }
    assert_includes created, "arc"
    assert_includes created, "open-work"
    assert_includes created, "deploy"
    assert_operator created.size, :>=, 3, "setup created #{created.size} labels — the list went empty"
    assert_equal [ "/api/v1/repos/chaim354/tinkerex/labels" ], stub.requests.map(&:path).uniq
  ensure
    stub&.shutdown
  end
```

- [ ] **Step 2: Run to verify they fail.**
- [ ] **Step 3: Implement, inside `module Log`**

```ruby
  LABELS = %w[arc open-work deploy blocked deliberate
              filelayer library-scan addons previews maker-web ci].freeze

  def status
    pending = Dir.glob(File.join(spool_dir, "*.md")).sort

    if pending.empty?
      puts "bin/log: nothing unfiled."
      return EXIT_OK
    end

    puts "bin/log: #{pending.size} unfiled record(s) — these are NOT in Forgejo:"
    pending.each { |path| puts "    #{path}" }
    EXIT_UNFILED
  end

  # IDEMPOTENT BY DECLARING 422 ACCEPTABLE AT THE CALL SITE, not by matching on a message string.
  # Forgejo answers 422 for a label that already exists — the ordinary case on every run after the
  # first — so treating it as failure would make `setup` a one-shot command, and a one-shot setup
  # is one nobody re-runs after adding a label.
  #
  # `allow:` rather than a rescue, for two reasons. `perform`'s message embeds the RESPONSE BODY,
  # so `e.message.include?("HTTP 422")` would also swallow any other status whose body happened to
  # contain that text — and, far likelier, changing the message format would silently stop setup
  # being idempotent, failing only on the SECOND run. And a rescue around the call can grow to
  # swallow a genuine connection failure, which is exactly what C1 exists to prevent. An
  # expectation declared before the fact cannot drift.
  def setup
    LABELS.each do |name|
      api(:post, repo_path("/labels"), { name: name, color: "#666666" }, allow: [ 422 ])
    end

    puts "bin/log: #{LABELS.size} labels present."
    EXIT_OK
  end
```

Add `when "status" then status` and `when "setup" then setup` to `dispatch`.

`allow:` threads through the transport. Give `api` and `perform` a keyword defaulting to empty, and widen the acceptance test:

```ruby
  def api(method, path, body = nil, allow: [])
    perform(method, path, body, allow)
  # ...rescues unchanged

  def perform(method, path, body, allow)
    # ...
    code = response.code.to_i
    unless code.between?(200, 299) || allow.include?(code)
      raise Unreachable, "HTTP #{response.code} from #{path}: #{response.body.to_s[0, 200]}"
    end
```

- [ ] **Step 4: Run to verify they pass** — PASS, 17 tests.
- [ ] **Step 5: rubocop, then commit** — subject: `bin/log status and setup: make the debt visible, make the labels exist`.

---

## Task 7: `deploy`, `note` and `search` — the three PR 2 depends on

Not optional extras: §6.1 points CLAUDE.md §11 at `bin/log search`, §6.2 replaces `/deploy`'s STATUS step with `bin/log deploy`, and §4's "a correction is a comment" — the sharpest gain from the whole move — is `bin/log note`.

**Files:** modify `bin/log`, `test/log_cli_test.rb`

- [ ] **Step 1: Write the failing tests**

```ruby
  # A DEPLOY IS AN ISSUE, WHICH IS WHAT DELETES §15's PUSH-TO-MAIN EXCEPTION. Today a deploy record
  # is the one sanctioned direct commit to main, because a deploy happens after the merge and its
  # record cannot live in the work's own PR. As an issue that reasoning evaporates.
  test "deploy files an issue carrying the image and every destination" do
    stub = StubForgejo.new

    _out, err, code = run_log("deploy", "--image", "e079d433", "--dest", "chunk_remote,share,s3", env: {
      "FORGEJO_TOKEN" => "t0ken", "FORGEJO_URL" => stub.url,
      "FORGEJO_OWNER" => "chaim354", "FORGEJO_REPO" => "tinkerex"
    })

    assert_equal 0, code, "bin/log deploy failed: #{err}"
    request = stub.requests.first

    assert_equal [ "deploy" ], request.json["labels"]
    assert_includes request.json["title"], "e079d433"
    %w[chunk_remote share s3].each do |dest|
      assert_includes request.json["body"], dest,
                      "a deploy record naming fewer destinations than were deployed is a stale claim"
    end
  ensure
    stub&.shutdown
  end

  # A CORRECTION IS A COMMENT, NOT AN EDIT. This is the whole reason the move helps: STATUS.md's
  # recurring failure was a stale claim buried mid-file, and CLAUDE.md records several in its own
  # voice ("this bullet went on asserting a single even bound for months"). A dated comment appends
  # visibly; finding and rewriting a paragraph at line 4,700 does not happen.
  test "note posts to the comments endpoint and never rewrites the issue body" do
    stub = StubForgejo.new(status: 201, response: { "id" => 7 })

    _out, err, code = run_log("note", "128", "The measured figure was 7.8 ms, not 5.", env: {
      "FORGEJO_TOKEN" => "t0ken", "FORGEJO_URL" => stub.url,
      "FORGEJO_OWNER" => "chaim354", "FORGEJO_REPO" => "tinkerex"
    })

    assert_equal 0, code, "bin/log note failed: #{err}"
    request = stub.requests.first

    assert_equal "POST", request.method
    assert_equal "/api/v1/repos/chaim354/tinkerex/issues/128/comments", request.path
    assert_equal "The measured figure was 7.8 ms, not 5.", request.json["body"]
    refute request.json.key?("title"), "note sent a title — it is editing the issue, not commenting"
  ensure
    stub&.shutdown
  end

  # SEARCH SPANS OPEN AND CLOSED. An arc issue is CLOSED the moment its PR merges, so a search
  # defaulting to Forgejo's state=open would find no finished work at all — which is most of the
  # record.
  test "search asks for both states" do
    stub = StubForgejo.new(status: 200, response: [])

    _out, err, code = run_log("search", "chunk_remote", env: {
      "FORGEJO_TOKEN" => "t0ken", "FORGEJO_URL" => stub.url,
      "FORGEJO_OWNER" => "chaim354", "FORGEJO_REPO" => "tinkerex"
    })

    assert_equal 0, code, "bin/log search failed: #{err}"
    request = stub.requests.first

    assert_equal "GET", request.method
    assert_includes request.path, "/api/v1/repos/chaim354/tinkerex/issues"
    assert_includes request.path, "state=all",
                    "search defaulted to open issues, which excludes every finished arc"
    assert_includes request.path, "chunk_remote"
  ensure
    stub&.shutdown
  end
```

- [ ] **Step 2: Run to verify they fail.**
- [ ] **Step 3: Implement, inside `module Log`**

```ruby
  def deploy(argv)
    raise UsageError, "deploy needs --image SHA" unless argv.shift == "--image"

    image = argv.shift or raise UsageError, "deploy needs --image SHA"
    dests = (argv[0] == "--dest" ? argv[1] : "chunk_remote,share,s3").split(",")
    body = "Image: `#{image}`\n\nDestinations:\n#{dests.map { |d| "- #{d}" }.join("\n")}\n"
    issue = create_issue("Deploy #{image}", body: body, labels: [ "deploy" ])

    puts "##{issue['number']} #{issue['title']}"
    EXIT_OK
  end

  def note(argv)
    number = argv.shift or raise UsageError, "note needs an issue number"
    text = argv.shift or raise UsageError, "note needs text"
    api(:post, repo_path("/issues/#{number}/comments"), { body: text })

    puts "noted on ##{number}"
    EXIT_OK
  end

  # state=all is load-bearing: an arc closes when its PR merges, so the default would hide every
  # finished piece of work — which is most of the record.
  def search(argv)
    query = argv.shift or raise UsageError, "search needs a query"
    path = repo_path("/issues?state=all&q=#{URI.encode_www_form_component(query)}")
    issues = JSON.parse(api(:get, path).body)

    if issues.empty?
      puts "bin/log: no issues matching #{query.inspect}."
    else
      issues.each { |i| puts "##{i['number']} [#{i['state']}] #{i['title']}" }
    end
    EXIT_OK
  end
```

Add the three `dispatch` arms. Every subcommand in `SUBCOMMANDS` is now implemented, so `dispatch`'s `else` becomes unreachable — leave it, and make it `raise "unreachable: #{command}"` rather than a silent fallthrough.

- [ ] **Step 4: Run to verify they pass** — PASS, 18 tests.
- [ ] **Step 5: rubocop, then commit** — subject: `bin/log deploy, note and search — the three PR 2 calls`.

---

## Task 8: Mutation-check every guard

**No files change.** CLAUDE.md §15: *"After a test that exists to forbid something goes green, break the thing it guards and confirm it goes RED — then restore. A guard that has never failed has not been shown to work."*

One at a time. **Restore after each, and confirm green before the next.** Report every result explicitly — a mutation that stays green is a finding, not a formality.

- [ ] **1. Usage anchoring** — delete the `"arc"` row from `SUBCOMMANDS`. Expect RED. (The pre-review spelling stayed GREEN here, because "search" contains "arc".)
- [ ] **2. Token never on stderr** — add `warn "resolved: #{out}"` inside `token`. Expect RED.
- [ ] **3. The `bin/secret` override** — replace the `capture3` in `token` with a direct `op read --no-newline #{TOKEN_REF}`. Expect RED.
- [ ] **4. Non-integer exit guard** — delete the `raise ... unless code.is_a?(Integer)` line. Expect RED.
- [ ] **5. Wire format** — change `create_issue`'s `labels: labels` to `labels: []`. Expect RED.
- [ ] **6. `gh` stub consulted** — replace `ENV.fetch("GH_BIN", "gh")` with `"gh"`. Expect RED.
- [ ] **7. 502 spools** — in `perform`, change the non-2xx `raise` to `return response`. Expect RED on the 502 test.
- [ ] **8. Reads spool nothing** — in `main`'s rescue, drop the `e.payload.nil?` branch so every failure spools. Expect RED.
- [ ] **9. Spool exists at all** — delete the `spool!` call from the rescue. Expect RED.
- [ ] **10. `status` fails loud** — change `status`'s backlog return to `EXIT_OK`. Expect RED.
- [ ] **11. `note` comments rather than edits** — point `note` at `create_issue` instead of the comments endpoint. Expect RED.
- [ ] **12. `search` spans both states** — change `state=all` to `state=open`. Expect RED.
- [ ] **13. The encoding fix** — comment out `Encoding.default_external = Encoding::UTF_8`. Expect RED on the locale-less credential test. No developer shell reproduces this; the guard is the only thing that will ever notice.
- [ ] **14. The catch-all** — remove `main`'s `rescue StandardError` arm. Expect RED on the non-JSON-body test, exiting 1 rather than 3.
- [ ] **15. `EXIT_UNFILED` is not 1** — set `EXIT_UNFILED = 1`. Expect RED on `status`'s `refute_equal`.
- [ ] **16. `setup`'s `allow: [422]`** — drop the `allow:` argument. Expect RED against a stub answering 422.
- [ ] **17. Stdlib-only** — add `require "bundler/setup"` to the top of `bin/log`. Expect RED on the stale-`BUNDLE_GEMFILE` test.

- [ ] **Record the result**

```bash
git commit --allow-empty -m "Mutation-check bin/log's seventeen guards: all seventeen go red on cue

Per §15 — a guard that has never failed has not been shown to work. Each was
broken individually, confirmed red, and restored.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 9: Wire it into CLAUDE.md §13, and close out

**Files:** modify `CLAUDE.md` (§13 cheatsheet only — §11/§12/§15 belong to PR 2)

- [ ] **Step 1: Add the cheatsheet block**

In §13, after the `bin/secrets-preflight` block:

```sh
# RECORDING WORK. bin/log is the SINGLE write door onto the Forgejo at forgejo.home; MCP may read
# it and never writes. Token via bin/secret (op://tinkerex/Forgejo/token) — no `export`.
bin/log setup                    # create the labels, idempotently
bin/log arc --from-pr 261        # arc issue built from the merged PR body
bin/log open "<title>"           # file an open item
bin/log deploy --image e079d433  # record a deploy
bin/log status                   # anything unfiled? exits 1 if so
# UNREACHABLE IS LOUD, SPOOLED AND NON-BLOCKING (exit 3), and a 502 counts as unreachable — the
# entry lands in $LOG_SPOOL_DIR (default tmp/log-pending/<branch>.md) and `bin/log status` keeps
# saying so until you file it. THERE IS NO AUTOMATIC REPLAY.
# bin/log NEEDS NO GEM, but an inherited RUBYOPT force-requiring bundler still applies before its
# first line — a caller inside a bundled process must clear those names, as bin/sync-server does.
```

- [ ] **Step 2: Verify the line ceiling** — `bin/rails test test/docs_hygiene_test.rb`. If it trips, **trim the block; do not raise `MAX_LINES`.** PR 2 lowers the ceiling once §12 collapses.
- [ ] **Step 3: Run the full gate** — `bin/ci`. Every gate green, three backend legs reporting identical run counts (±2 assertions / ±1 skip is the known pre-existing flap).
- [ ] **Step 4: Verify against the real Forgejo, once.** The suite never touches it. This is the step Task 0's token blocks.

```bash
bin/log setup && bin/log setup && bin/log open "bin/log smoke test — close me" && bin/log status
```

**`setup` runs TWICE deliberately.** Idempotency is its entire claim, and one run cannot test it — the 422-tolerating path only executes on the second. A `setup` that silently stopped being idempotent would fail for the first time months later, in front of whoever added a label.

Expected: labels reported present both times, an issue number printed, `nothing unfiled`. Close the smoke-test issue in the UI afterwards.

- [ ] **Step 5: Close out** with `/finish-branch`. State plainly in the PR body that **PR 1 deletes nothing** and `docs/STATUS.md` stays canonical until PR 2.

---

## PR 2 — the migration (detailed plan written after this merges)

Deliberately not detailed here: its scripts consume `bin/log`'s output formats, and planning them in TDD detail before the tool exists means inventing an interface that Task 3–6 may adjust.

Headline tasks, from spec §7:

1. Mechanical split of `docs/STATUS.md`'s 110 `## <date>: <title>` sections into a scratch dir
2. Rubric-strict triage — the four keep-tests; expected survival ~35–50
3. Hand-dedupe the three open-work lists (19 + 9 + 7 → one issue each, body naming every source)
4. Import oldest-first, emitting a `heading → issue #` mapping
5. Rewrite the 20 code citations, plus CLAUDE.md §11/§12/§15 and the two commands
6. `test/docs_hygiene_test.rb`: assert **non-empty scanned set** before trusting it (§14e's vacuous-glob trap, which deleting `docs/STATUS.md` walks straight into), then mutation-check it
7. Verify every rewritten `#N` returns 200 from the API
8. Delete `docs/STATUS.md` and `docs/OPEN-WORK.md` — same PR as the rewrite, never before it
9. Ratchet `MAX_LINES` down to CLAUDE.md's new length
