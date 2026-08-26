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

1. **Strip the inherited Bundler env.** `Open3.capture3(env, …)` *merges*, so every test today runs `bin/log` as a bundled child — the property "indifferent to its launcher" is exercised only in the direction that cannot fail. Reproduced: `BUNDLE_GEMFILE=/nonexistent RUBYOPT=-rbundler/setup ./bin/log status` dies with `Bundler::GemfileNotFound` before line 1. Clear the seven names `bin/sync-server`'s `unset_inherited_bundler_env` already lists, and add a test that runs under a hostile bundler env.
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

## Task 2: Token resolution through `bin/secret`, with the value never on stderr

**Files:**
- Modify: `bin/log`
- Modify: `test/log_cli_test.rb`

- [ ] **Step 1: Write the failing tests**

Append to `LogCliTest`:

```ruby
  # THE TOKEN MUST NEVER REACH fd2. bin/secret's header records the exact mechanism: writing
  # `op read "$ref" 2>&1 >/dev/null` points fd2 at the CURRENT stdout and only then moves fd1, so
  # the value lands in whatever captured the command. That printed a live ghcr PAT into an agent
  # transcript on 2026-07-29 and the token had to be rotated. Open3.capture3 keeps the two streams
  # separate, which is why bin/log must use it rather than a backtick or `2>&1`.
  test "a resolved token never appears on stderr" do
    out, err, _code = run_log("show", "1", env: {
      "FORGEJO_TOKEN" => "sentinel-token-value",
      "FORGEJO_URL"   => "http://127.0.0.1:1"   # refused; we are asserting about the diagnostics
    })

    refute_includes err, "sentinel-token-value",
                    "the token reached stderr — see bin/secret's header for how this happens"
    refute_includes out, "sentinel-token-value",
                    "the token reached stdout"
  end

  # An EXPORTED value wins over the vault. This is bin/secret's own documented order, and bin/log
  # gets it for free by going through that door instead of calling `op` itself. Asserting it here
  # is what stops someone "simplifying" bin/log into a direct `op read`, which would silently drop
  # the override every test below depends on.
  test "an exported FORGEJO_TOKEN is used without invoking 1Password" do
    # PATH without `op`, so a direct `op read` would fail loudly rather than pass by luck.
    _out, err, code = run_log("show", "1", env: {
      "FORGEJO_TOKEN" => "exported-wins",
      "FORGEJO_URL"   => "http://127.0.0.1:1",
      "PATH"          => "/usr/bin:/bin"
    })

    assert_equal 3, code, "expected the UNREACHABLE exit, not a credential failure"
    refute_includes err, "1Password",
                    "bin/log consulted the vault despite an exported value — the override was lost"
  end
```

- [ ] **Step 2: Run to verify they fail**

```bash
bin/rails test test/log_cli_test.rb
```

Expected: FAIL — `show` exits 2 (not implemented), not 3.

- [ ] **Step 3: Implement token resolution and the HTTP layer**

In `bin/log`, replace the `case command` block with the following, keeping everything above it:

```ruby
FORGEJO_URL   = ENV.fetch("FORGEJO_URL", "http://forgejo.home")
FORGEJO_OWNER = ENV.fetch("FORGEJO_OWNER", "chaim354")
FORGEJO_REPO  = ENV.fetch("FORGEJO_REPO", "tinkerex")
TOKEN_REF     = "op://tinkerex/Forgejo/token"

class Unreachable < StandardError; end

# THROUGH bin/secret, NEVER `op read` DIRECTLY. That file is the single definition of "where does
# a credential come from" for this repo, and it is what makes an exported value win over the vault.
#
# capture3 keeps stdout and stderr SEPARATE. bin/secret sends the value only on fd1 and its own
# diagnostics only on fd2, so forwarding err below cannot leak. Any rewrite that merges the two
# streams re-opens the 2026-07-29 leak.
def token
  @token ||= begin
    out, err, status = Open3.capture3(File.expand_path("secret", __dir__), "FORGEJO_TOKEN", TOKEN_REF)

    if !status.success? || out.empty?
      warn "bin/log: could not resolve FORGEJO_TOKEN from #{TOKEN_REF}"
      warn err unless err.empty?
      exit EXIT_UNREACHABLE
    end

    out
  end
end

def api(method, path, body = nil)
  uri = URI.join(FORGEJO_URL, path)

  request = case method
            when :get  then Net::HTTP::Get.new(uri)
            when :post then Net::HTTP::Post.new(uri)
            else raise ArgumentError, "unsupported method #{method}"
            end

  request["Authorization"] = "token #{token}"
  request["Content-Type"]  = "application/json"
  request.body = JSON.generate(body) if body

  Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                      open_timeout: 5, read_timeout: 15) do |http|
    http.request(request)
  end
rescue SystemCallError, Net::OpenTimeout, Net::ReadTimeout, SocketError => e
  raise Unreachable, "#{FORGEJO_URL}: #{e.message}"
end

def repo_path(suffix) = "/api/v1/repos/#{FORGEJO_OWNER}/#{FORGEJO_REPO}#{suffix}"

def show(number)
  response = api(:get, repo_path("/issues/#{number}"))
  issue = JSON.parse(response.body)
  puts "##{issue['number']} #{issue['title']} [#{issue['state']}]"
  puts
  puts issue["body"]
end

begin
  case command
  when "show"
    number = ARGV.shift or usage!("show needs an issue number")
    show(number)
  when "setup", "arc", "open", "deploy", "note", "search", "status"
    warn "bin/log: #{command} is not implemented yet"
    exit EXIT_USAGE
  else
    usage! "unknown command #{command.inspect}"
  end
rescue Unreachable => e
  warn "bin/log: Forgejo is unreachable — #{e.message}"
  exit EXIT_UNREACHABLE
end
```

- [ ] **Step 4: Run to verify they pass**

```bash
bin/rails test test/log_cli_test.rb
```

Expected: PASS, 3 tests.

- [ ] **Step 5: Commit**

```bash
git add bin/log test/log_cli_test.rb
git commit -m "bin/log: resolve the token through bin/secret, never onto stderr

capture3 keeps fd1 and fd2 separate — merging them is the exact shape that
printed a live PAT into a transcript on 2026-07-29.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 3: The stub Forgejo, and the wire format for `open`

**Files:**
- Create: `test/support/stub_forgejo.rb`
- Modify: `bin/log`
- Modify: `test/log_cli_test.rb`

- [ ] **Step 1: Write the stub server**

Create `test/support/stub_forgejo.rb`:

```ruby
require "webrick"
require "json"

# A localhost stand-in for Forgejo that RECORDS REQUESTS VERBATIM.
#
# It deliberately does NOT model Forgejo. It captures method, path, headers and raw body, and
# replays whatever the test told it to. §14e records why that distinction matters: FakeS3 decoded
# with CGI.unescape while the adapter encoded with CGI.escape — exact inverses — so 79 of 80 tests
# were green over silent permanent data loss on any filename containing a space. A fake that
# implements the same misunderstanding as the code confirms it rather than catching it.
#
# So: tests assert against `server.requests`, never against a round-trip through this object.
class StubForgejo
  Request = Struct.new(:method, :path, :headers, :body, keyword_init: true) do
    def json = JSON.parse(body)
  end

  attr_reader :requests

  def initialize(status: 201, response: { "number" => 42, "title" => "stub", "state" => "open", "body" => "" })
    @requests = []
    @status = status
    @response = response

    @server = WEBrick::HTTPServer.new(
      Port: 0, Logger: WEBrick::Log.new(File::NULL), AccessLog: []
    )

    @server.mount_proc "/" do |req, res|
      @requests << Request.new(
        method: req.request_method, path: req.path,
        headers: req.header.transform_values(&:first), body: req.body.to_s
      )
      res.status = @status
      res["Content-Type"] = "application/json"
      res.body = JSON.generate(@response)
    end

    @thread = Thread.new { @server.start }
  end

  def url = "http://127.0.0.1:#{@server.config[:Port]}"

  def shutdown
    @server.shutdown
    @thread.join(5)
  end
end
```

- [ ] **Step 2: Write the failing wire-format test**

Add to `test/log_cli_test.rb` — put `require "support/stub_forgejo"` at the top, under `require "test_helper"`:

```ruby
  # THE WIRE FORMAT IS THE ASSERTION. Not "the issue came back with our title" — that passes even
  # when both sides share a bug. Path, auth header and JSON body, each checked literally.
  test "open POSTs the documented issue payload to the documented path" do
    stub = StubForgejo.new

    _out, err, code = run_log("open", "The scan tombstones a live node", env: {
      "FORGEJO_TOKEN" => "t0ken",
      "FORGEJO_URL"   => stub.url,
      "FORGEJO_OWNER" => "chaim354",
      "FORGEJO_REPO"  => "tinkerex"
    })

    assert_equal 0, code, "bin/log open failed: #{err}"
    assert_equal 1, stub.requests.size, "expected exactly one API call"

    request = stub.requests.first
    assert_equal "POST", request.method
    assert_equal "/api/v1/repos/chaim354/tinkerex/issues", request.path
    assert_equal "token t0ken", request.headers["authorization"]
    assert_equal "application/json", request.headers["content-type"]

    assert_equal "The scan tombstones a live node", request.json["title"]
    assert_equal [ "open-work" ], request.json["labels"],
                 "an open item must carry the open-work label or it is invisible to the open-work view"
  ensure
    stub&.shutdown
  end
```

- [ ] **Step 3: Run to verify it fails**

```bash
bin/rails test test/log_cli_test.rb -n /open POSTs/
```

Expected: FAIL — exit 2, `open is not implemented yet`.

- [ ] **Step 4: Implement `open`**

In `bin/log`, add above the `begin` block:

```ruby
# LABELS ARE NAMES ON THE WIRE, NOT IDS. Forgejo's issue-create accepts label IDs in `labels`,
# and it accepts names too; names are what a human reads in a diff and what survives the labels
# being recreated. `bin/log setup` (Task 6) is what guarantees they exist.
def create_issue(title, body:, labels:)
  response = api(:post, repo_path("/issues"), { title: title, body: body, labels: labels })

  unless response.code.to_i.between?(200, 299)
    warn "bin/log: Forgejo refused the issue (HTTP #{response.code}): #{response.body}"
    exit EXIT_UNREACHABLE
  end

  JSON.parse(response.body)
end
```

And in the `case command`, replace the `"open"` arm:

```ruby
  when "open"
    title = ARGV.shift or usage!("open needs a title")
    issue = create_issue(title, body: ARGV.shift.to_s, labels: [ "open-work" ])
    puts "##{issue['number']} #{issue['title']}"
```

Remember to drop `"open"` from the not-implemented list in the same `case`.

- [ ] **Step 5: Run to verify it passes**

```bash
bin/rails test test/log_cli_test.rb
```

Expected: PASS, 4 tests.

- [ ] **Step 6: Commit**

```bash
git add bin/log test/log_cli_test.rb test/support/stub_forgejo.rb
git commit -m "bin/log open, asserted on the wire format rather than a round-trip

The stub records requests verbatim and models nothing — §14e's FakeS3 lesson,
where exact-inverse encode/decode kept 79/80 tests green over data loss.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 4: `arc --from-pr` — one document, filed rather than rewritten

**Files:**
- Modify: `bin/log`
- Modify: `test/log_cli_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
  # THE ARC BODY IS THE PR BODY. /finish-branch already specifies that document — symptom, root
  # cause, why tests missed it, verification table, scope. Rewriting it by hand into a second
  # document is exactly the per-PR tax that made docs/STATUS.md unworkable, so bin/log reads it
  # back out of the PR instead. The `gh` call is stubbed here via GH_BIN; Task 7 mutation-checks
  # that the stub is actually consulted.
  test "arc --from-pr builds the issue from the PR body and links back to it" do
    stub = StubForgejo.new
    fake_gh = File.join(Dir.mktmpdir, "gh")
    File.write(fake_gh, <<~SH)
      #!/bin/sh
      cat <<'JSON'
      {"title":"Fix the tombstone cascade","body":"## Root cause\\nThe delete was applied per-node.","url":"https://github.com/chaim354/tinkerex/pull/261"}
      JSON
    SH
    File.chmod(0o755, fake_gh)

    _out, err, code = run_log("arc", "--from-pr", "261", env: {
      "FORGEJO_TOKEN" => "t0ken", "FORGEJO_URL" => stub.url,
      "FORGEJO_OWNER" => "chaim354", "FORGEJO_REPO" => "tinkerex",
      "GH_BIN" => fake_gh
    })

    assert_equal 0, code, "bin/log arc failed: #{err}"
    request = stub.requests.first

    assert_equal "Fix the tombstone cascade", request.json["title"]
    assert_includes request.json["body"], "The delete was applied per-node.",
                    "the PR body was not carried into the arc issue"
    assert_includes request.json["body"], "https://github.com/chaim354/tinkerex/pull/261",
                    "the arc must link the PR it describes, or the diff is unreachable from the record"
    assert_equal [ "arc" ], request.json["labels"]
  ensure
    stub&.shutdown
  end
```

Add `require "tmpdir"` at the top of the test file.

- [ ] **Step 2: Run to verify it fails**

```bash
bin/rails test test/log_cli_test.rb -n /arc --from-pr/
```

Expected: FAIL — exit 2.

- [ ] **Step 3: Implement `arc`**

Add to `bin/log`:

```ruby
# GH_BIN is an override, not a convenience — it is what lets the suite drive this path without a
# network or a GitHub credential. Defaulting to the PATH lookup keeps normal use unchanged.
def pull_request(number)
  gh = ENV.fetch("GH_BIN", "gh")
  out, err, status = Open3.capture3(gh, "pr", "view", number.to_s, "--json", "title,body,url")

  unless status.success?
    warn "bin/log: could not read PR #{number} via #{gh}"
    warn err unless err.empty?
    exit EXIT_UNREACHABLE
  end

  JSON.parse(out)
end
```

And the `"arc"` arm:

```ruby
  when "arc"
    usage!("arc needs --from-pr N") unless ARGV.shift == "--from-pr"
    number = ARGV.shift or usage!("arc needs --from-pr N")
    pr = pull_request(number)
    body = "#{pr['body']}\n\n---\nPR: #{pr['url']}\n"
    issue = create_issue(pr["title"], body: body, labels: [ "arc" ])
    puts "##{issue['number']} #{issue['title']}"
```

- [ ] **Step 4: Run to verify it passes**

```bash
bin/rails test test/log_cli_test.rb
```

Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add bin/log test/log_cli_test.rb
git commit -m "bin/log arc --from-pr: file the PR body, do not rewrite it

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 5: Unreachable — fail loudly, spool, let the caller proceed

**Files:**
- Modify: `bin/log`
- Modify: `test/log_cli_test.rb`
- Modify: `.gitignore` (only if Task 1 Step 5 showed `tmp/` is not ignored)

- [ ] **Step 1: Write the failing tests**

```ruby
  # THE CHOSEN FAILURE MODE: loud, spooled, and NON-BLOCKING. The alternative — blocking the
  # close-out — was considered and declined; so was a spool that replays automatically, because a
  # queue that silently drains is data loss wearing a fix. What is left must therefore make the
  # debt VISIBLE, which is what `bin/log status` is for (Task 6).
  test "an unreachable Forgejo spools the entry, says so, and exits 3" do
    spool = Rails.root.join("tmp/log-pending")
    FileUtils.rm_rf(spool)

    _out, err, code = run_log("open", "Something worth keeping", env: {
      "FORGEJO_TOKEN" => "t0ken",
      "FORGEJO_URL"   => "http://127.0.0.1:1",
      "LOG_BRANCH"    => "claude/example"
    })

    assert_equal 3, code, "unreachable must be its own exit code, distinguishable from a usage error"

    spooled = spool.join("claude-example.md")
    assert spooled.exist?, "the entry was not spooled — it is simply lost"
    assert_includes spooled.read, "Something worth keeping"

    assert_includes err, spooled.to_s,
                    "the spool path must be PRINTED; an invisible spool is the silent-drain failure again"
  ensure
    FileUtils.rm_rf(Rails.root.join("tmp/log-pending"))
  end
```

- [ ] **Step 2: Run to verify it fails**

```bash
bin/rails test test/log_cli_test.rb -n /spools the entry/
```

Expected: FAIL — no spool file.

- [ ] **Step 3: Implement spooling**

In `bin/log`, add `require "fileutils"` at the top, then:

```ruby
SPOOL_DIR = File.expand_path("../tmp/log-pending", __dir__)

# THE BRANCH NAMES THE SPOOL FILE so two branches cannot overwrite each other's unfiled record.
# LOG_BRANCH is an override for the suite; normal use asks git.
def current_branch
  ENV["LOG_BRANCH"] || Open3.capture2("git", "branch", "--show-current").first.strip
end

def spool!(text)
  FileUtils.mkdir_p(SPOOL_DIR)
  path = File.join(SPOOL_DIR, "#{current_branch.tr('/', '-')}.md")
  File.open(path, "a") { |f| f.puts(text, "") }
  path
end
```

Change the top-level rescue to spool whatever was being filed:

```ruby
rescue Unreachable => e
  path = spool!("# unfiled: #{command} #{ARGV_SNAPSHOT.join(' ')}\n\n#{PENDING_BODY}")
  warn "bin/log: Forgejo is unreachable — #{e.message}"
  warn "bin/log: the entry was NOT filed. It is spooled at #{path}"
  warn "bin/log: `bin/log status` will keep reporting it until you file it."
  exit EXIT_UNREACHABLE
end
```

Capture the two values that rescue needs, immediately after `command = ARGV.shift`:

```ruby
ARGV_SNAPSHOT = ARGV.dup.freeze
PENDING_BODY = +""   # each command appends what it was about to send, before it sends it
```

and in `create_issue`, before the `api` call:

```ruby
  PENDING_BODY << "#{title}\n\n#{body}"
```

- [ ] **Step 4: Run to verify it passes**

```bash
bin/rails test test/log_cli_test.rb
```

Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add bin/log test/log_cli_test.rb
git commit -m "bin/log: an unreachable Forgejo spools loudly rather than losing the entry

Exit 3 is distinct from the usage error so /finish-branch can tell 'could not
file' from 'spelled it wrong'. No automatic replay — a queue that silently
drains is data loss wearing a fix.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 6: `bin/log status` and `bin/log setup`

**Files:**
- Modify: `bin/log`
- Modify: `test/log_cli_test.rb`

- [ ] **Step 1: Write the failing tests**

```ruby
  test "status is silent and exits 0 when nothing is unfiled" do
    FileUtils.rm_rf(Rails.root.join("tmp/log-pending"))

    out, _err, code = run_log("status")

    assert_equal 0, code
    assert_includes out, "nothing unfiled"
  end

  # STATUS FAILS LOUD ON A BACKLOG. bin/backup-status exists for the same reason and its header
  # says it: a nightly that stops is silent, and the failure looks exactly like success right up
  # until the restore. An unfiled arc is the same shape.
  test "status names every spooled entry and exits non-zero" do
    spool = Rails.root.join("tmp/log-pending")
    FileUtils.mkdir_p(spool)
    spool.join("claude-example.md").write("# unfiled: open Something\n")

    out, _err, code = run_log("status")

    assert_equal 1, code, "an outstanding record must fail loud, not print a note and exit 0"
    assert_includes out, "claude-example.md"
  ensure
    FileUtils.rm_rf(Rails.root.join("tmp/log-pending"))
  end

  test "setup creates each label idempotently and asks for names, not ids" do
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
  ensure
    stub&.shutdown
  end
```

- [ ] **Step 2: Run to verify they fail**

```bash
bin/rails test test/log_cli_test.rb
```

Expected: FAIL on all three.

- [ ] **Step 3: Implement both**

```ruby
LABELS = %w[arc open-work deploy blocked deliberate
            filelayer library-scan addons previews maker-web ci].freeze

def status
  pending = Dir.glob(File.join(SPOOL_DIR, "*.md")).sort

  if pending.empty?
    puts "bin/log: nothing unfiled."
    exit 0
  end

  puts "bin/log: #{pending.size} unfiled record(s) — these are NOT in Forgejo:"
  pending.each { |p| puts "    #{p}" }
  exit 1
end

# IDEMPOTENT BY IGNORING 422. Forgejo answers 422 for a label that already exists, which is the
# ordinary case on every run after the first. Treating that as failure would make `setup` a
# one-shot command, and a one-shot setup is one nobody re-runs after adding a label.
def setup
  LABELS.each do |name|
    response = api(:post, repo_path("/labels"), { name: name, color: "#666666" })
    code = response.code.to_i
    next if code.between?(200, 299) || code == 422

    warn "bin/log: could not create label #{name} (HTTP #{code}): #{response.body}"
    exit EXIT_UNREACHABLE
  end

  puts "bin/log: #{LABELS.size} labels present."
end
```

Wire both into the `case`, and remove them from the not-implemented arm.

- [ ] **Step 4: Run to verify they pass**

```bash
bin/rails test test/log_cli_test.rb
```

Expected: PASS, 9 tests.

- [ ] **Step 5: Commit**

```bash
git add bin/log test/log_cli_test.rb
git commit -m "bin/log status and setup: make the debt visible, make the labels exist

status exits non-zero on a backlog for bin/backup-status's reason — a record
that stops being written is silent, and looks like success until you need it.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 7: `deploy`, `note` and `search` — the three PR 2 depends on

**Files:**
- Modify: `bin/log`
- Modify: `test/log_cli_test.rb`

These are not optional extras. Spec §6.1 points CLAUDE.md §11 at `bin/log search`, §6.2 replaces `/deploy`'s STATUS step with `bin/log deploy`, and §4's "a correction is a comment" — the sharpest gain from the whole move — is `bin/log note`. PR 2 calls all three.

- [ ] **Step 1: Write the failing tests**

```ruby
  # A DEPLOY IS AN ISSUE, WHICH IS WHAT DELETES §15's PUSH-TO-MAIN EXCEPTION. Today a deploy
  # record is the one sanctioned direct commit to main, because the deploy happens after the merge
  # and its record cannot live in the work's own PR. As an issue that reasoning evaporates.
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
    assert_includes request.json["body"], "chunk_remote"
    assert_includes request.json["body"], "share"
    assert_includes request.json["body"], "s3",
                    "a deploy record naming fewer destinations than were deployed is the stale-claim shape §15 warns about"
  ensure
    stub&.shutdown
  end

  # A CORRECTION IS A COMMENT, NOT AN EDIT. This is the whole reason the move helps: STATUS.md's
  # recurring failure was a stale claim buried mid-file, and CLAUDE.md records several in its own
  # voice ("this bullet went on asserting a single even bound for months"). A dated comment appends
  # visibly; finding and rewriting a paragraph at line 4,700 does not happen.
  test "note posts to the comments endpoint, never re-writing the issue body" do
    stub = StubForgejo.new

    _out, err, code = run_log("note", "128", "The measured figure was 7.8 ms, not 5.", env: {
      "FORGEJO_TOKEN" => "t0ken", "FORGEJO_URL" => stub.url,
      "FORGEJO_OWNER" => "chaim354", "FORGEJO_REPO" => "tinkerex"
    })

    assert_equal 0, code, "bin/log note failed: #{err}"
    request = stub.requests.first

    assert_equal "POST", request.method
    assert_equal "/api/v1/repos/chaim354/tinkerex/issues/128/comments", request.path
    assert_equal "The measured figure was 7.8 ms, not 5.", request.json["body"]
    refute request.json.key?("title"),
           "note sent a title — it is editing the issue rather than commenting on it"
  ensure
    stub&.shutdown
  end

  # SEARCH SPANS OPEN AND CLOSED. An arc issue is CLOSED the moment its PR merges, so a search
  # defaulting to Forgejo's `state=open` would find no finished work at all — every arc, which is
  # most of the record.
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

- [ ] **Step 2: Run to verify they fail**

```bash
bin/rails test test/log_cli_test.rb
```

Expected: FAIL on all three — exit 2, `not implemented yet`.

- [ ] **Step 3: Implement all three**

Add to `bin/log`:

```ruby
def comment(number, text)
  response = api(:post, repo_path("/issues/#{number}/comments"), { body: text })

  unless response.code.to_i.between?(200, 299)
    warn "bin/log: Forgejo refused the comment (HTTP #{response.code}): #{response.body}"
    exit EXIT_UNREACHABLE
  end

  JSON.parse(response.body)
end

def search(query)
  # state=all is load-bearing: an arc closes when its PR merges, so the default `open` would hide
  # every finished piece of work — which is most of the record.
  path = repo_path("/issues?state=all&q=#{URI.encode_www_form_component(query)}")
  issues = JSON.parse(api(:get, path).body)

  if issues.empty?
    puts "bin/log: no issues matching #{query.inspect}."
  else
    issues.each { |i| puts "##{i['number']} [#{i['state']}] #{i['title']}" }
  end
end
```

Then the three `case` arms, removing each from the not-implemented list:

```ruby
  when "deploy"
    usage!("deploy needs --image SHA") unless ARGV.shift == "--image"
    image = ARGV.shift or usage!("deploy needs --image SHA")
    dests = (ARGV[0] == "--dest" ? ARGV[1] : "chunk_remote,share,s3").split(",")
    body = "Image: `#{image}`\n\nDestinations:\n#{dests.map { |d| "- #{d}" }.join("\n")}\n"
    issue = create_issue("Deploy #{image}", body: body, labels: [ "deploy" ])
    puts "##{issue['number']} #{issue['title']}"

  when "note"
    number = ARGV.shift or usage!("note needs an issue number")
    text = ARGV.shift or usage!("note needs text")
    comment(number, text)
    puts "noted on ##{number}"

  when "search"
    query = ARGV.shift or usage!("search needs a query")
    search(query)
```

- [ ] **Step 4: Run to verify they pass**

```bash
bin/rails test test/log_cli_test.rb
```

Expected: PASS, 12 tests.

- [ ] **Step 5: Commit**

```bash
git add bin/log test/log_cli_test.rb
git commit -m "bin/log deploy, note and search — the three PR 2 calls

deploy-as-an-issue is what deletes §15's push-to-main exception. note posts a
comment rather than editing a body, which is the whole reason corrections stop
going stale. search asks state=all, or every closed arc is invisible.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 8: Mutation-check every guard

**No files change.** This task exists because CLAUDE.md §15 requires it: *"After a test that exists to forbid something goes green, break the thing it guards and confirm it goes RED — then restore. A guard that has never failed has not been shown to work."*

Do these one at a time. **Restore after each**, and confirm green before the next.

- [ ] **Step 1: The wire-format guard**

In `bin/log`'s `create_issue`, change `labels: labels` to `labels: []`.

```bash
bin/rails test test/log_cli_test.rb -n /open POSTs/
```

Expected: **RED** — `[] != ["open-work"]`. Restore, confirm green.

- [ ] **Step 2: The stderr-leak guard**

In `token`, add `warn "resolved: #{out}"` before returning.

```bash
bin/rails test test/log_cli_test.rb -n /never appears on stderr/
```

Expected: **RED**. Restore, confirm green.

- [ ] **Step 3: The `bin/secret` override**

Replace the `Open3.capture3` call in `token` with a direct `op read --no-newline #{TOKEN_REF}`.

```bash
bin/rails test test/log_cli_test.rb -n /exported FORGEJO_TOKEN/
```

Expected: **RED** — the exported value is ignored. Restore, confirm green.

- [ ] **Step 4: The spool**

In the `rescue Unreachable` block, delete the `spool!` call.

```bash
bin/rails test test/log_cli_test.rb -n /spools the entry/
```

Expected: **RED** — no spool file. Restore, confirm green.

- [ ] **Step 5: `status` failing loud**

Change `status`'s backlog branch to `exit 0`.

```bash
bin/rails test test/log_cli_test.rb -n /names every spooled entry/
```

Expected: **RED**. Restore, confirm green.

- [ ] **Step 6: The `gh` stub is actually consulted**

In `pull_request`, replace `ENV.fetch("GH_BIN", "gh")` with `"gh"`.

```bash
bin/rails test test/log_cli_test.rb -n /arc --from-pr/
```

Expected: **RED** — it reaches the real `gh` and gets the wrong title (or fails outright). Restore, confirm green.

- [ ] **Step 7: `note` comments rather than edits**

In the `"note"` arm, replace `comment(number, text)` with
`create_issue(text, body: text, labels: [])`.

```bash
bin/rails test test/log_cli_test.rb -n /note posts to the comments endpoint/
```

Expected: **RED** — the path is `/issues`, not `/issues/128/comments`, and a `title` is sent. Restore, confirm green.

- [ ] **Step 8: `search` spans both states**

In `search`, change `state=all` to `state=open`.

```bash
bin/rails test test/log_cli_test.rb -n /search asks for both states/
```

Expected: **RED**. Restore, confirm green.

- [ ] **Step 9: Record the result**

```bash
git commit --allow-empty -m "Mutation-check bin/log's eight guards: all eight go red on cue

Per §15 — a guard that has never failed has not been shown to work. Each was
broken individually, confirmed red, and restored.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 9: Wire it into CLAUDE.md §13, and close out

**Files:**
- Modify: `CLAUDE.md` (§13 cheatsheet only — §11/§12/§15 are PR 2's job)

- [ ] **Step 1: Add the cheatsheet block**

In §13, after the `bin/secrets-preflight` block, add:

```sh
# RECORDING WORK. bin/log is the SINGLE write door onto the Forgejo at forgejo.home; MCP may read
# it, and never writes. Token via bin/secret (op://tinkerex/Forgejo/token) — no `export`.
bin/log setup                    # create the labels, idempotently
bin/log arc --from-pr 261        # arc issue built from the merged PR body
bin/log open "<title>"           # file an open item
bin/log deploy --image e079d433  # record a deploy
bin/log status                   # anything unfiled? exits 1 if so
# UNREACHABLE IS LOUD, SPOOLED AND NON-BLOCKING (exit 3): the entry lands in
# tmp/log-pending/<branch>.md and `bin/log status` keeps saying so until you file it.
```

- [ ] **Step 2: Verify the line ceiling still holds**

```bash
bin/rails test test/docs_hygiene_test.rb
```

Expected: PASS. If the ceiling trips, **do not raise `MAX_LINES`** — trim the block instead. PR 2 lowers the ceiling once §12 collapses.

- [ ] **Step 3: Run the full gate**

```bash
bin/ci
```

Expected: every gate green, and the three backend legs reporting identical run counts (±2 assertions / ±1 skip is the known flap recorded in STATUS.md's "Still open").

- [ ] **Step 4: Verify against the real Forgejo, once**

The suite never touches `forgejo.home`. Do this by hand before opening the PR:

```bash
bin/log setup && bin/log open "bin/log smoke test — close me" && bin/log status
```

Expected: labels reported present, an issue number printed, `nothing unfiled`. Close the smoke-test issue in the UI afterwards.

- [ ] **Step 5: Close out**

Use `/finish-branch`. It will run `bin/ci` again, commit, push, and open the PR. State plainly in the body that **PR 1 deletes nothing** and `docs/STATUS.md` remains canonical until PR 2.

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
