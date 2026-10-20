require "test_helper"
require "open3"
require "tmpdir"
require "fileutils"
require "support/stub_kaneo"

# Guards bin/log — the SINGLE write door onto the record (CLAUDE.md §11).
#
# WHY A TEST FILE FOR A bin/ SCRIPT. bin/log is the only thing that records an arc, so a silent
# failure here loses the record with nothing going red — this repo's dominant failure shape
# (CLAUDE.md §15, "a green suite over something that never worked").
#
# THESE TESTS NEVER REACH kaneo.home, and that is enforced rather than asserted: run_log
# defaults KANEO_URL to an unroutable address, so touching the network is opt-in. Left at
# bin/log's own default a test that merely forgot to override it would POST a real issue into the
# live instance from anywhere on the LAN.
#
# THEY ASSERT THE WIRE FORMAT — exact path, headers, JSON body. §14e records why: FakeS3 decoded
# with CGI.unescape while the adapter encoded with CGI.escape, exact inverses, so 79/80 tests were
# green over silent permanent data loss. A fake that shares the code's misunderstanding confirms
# it rather than catching it.
class LogCliTest < ActiveSupport::TestCase
  BIN_LOG = Rails.root.join("bin/log").to_s

  # WHAT THE LIVE INSTANCE ACTUALLY RETURNS, measured 2026-08-31 — not what the OpenAPI implies.
  # Kaneo keeps label DEFINITIONS and label ATTACHMENTS in one table: a row with `taskId` null is
  # vocabulary, a row with a taskId is an attachment, and GET /label/workspace/:id returns BOTH. So a
  # fixture has to carry the null explicitly, or a test cannot tell the two apart and the filter that
  # separates them looks unnecessary.
  #
  # THE IDS ARE STRINGS, AND NOTHING SENDS THEM BACK. The record this replaced took int64 label ids
  # and REFUSED names on issue-create; Kaneo takes the name directly on POST /label and attaches in
  # that same call, so a task-create payload never carries a label at all.
  LABEL_NAMES = %w[arc open-work deploy blocked deliberate
                   filelayer library-scan addons previews maker-web ci].freeze
  LABEL_FIXTURE = LABEL_NAMES.each_with_index.map do |n, i|
    { "id" => "lbl#{i + 1}", "name" => n, "taskId" => nil }
  end.freeze

  # The seven names that pin a Ruby process to one Gemfile — CLAUDE.md §14j lists them, and this is
  # the one place in the repo that still clears them (bin/sync-server did too, for the Ruby sync host
  # it booted, until Phase 6). A bundled parent exports these process-wide and every child inherits
  # them, so a harness that MERGES its own environment runs bin/log as a bundled child every time —
  # exercising "needs no gem" only in the direction that cannot fail. Deliberately NOT
  # PATH/GEM_HOME/GEM_PATH, which is how the shell finds ruby at all.
  BUNDLER_ENV = %w[BUNDLE_GEMFILE BUNDLE_BIN_PATH BUNDLE_LOCKFILE BUNDLER_VERSION
                   BUNDLER_SETUP RUBYOPT RUBYLIB].freeze

  # LOG_SPOOL_DIR DEFAULTS TO A THROWAWAY, so reaching the developer's REAL spool is opt-in — the
  # same shape as KANEO_URL defaulting to an unroutable address. Two write-verb tests were
  # unguarded and passed only because their stubs happened to succeed; the moment one failed it
  # appended to tmp/log-pending/<branch>.md, which `bin/log status` then reports as unfiled work
  # forever. tmp/ is gitignored, so git status never shows it. Observed once, during a mutation
  # check, before this existed.
  setup { @spool = Dir.mktmpdir }
  teardown { FileUtils.remove_entry(@spool) if @spool && File.exist?(@spool) }

  # [BIN_LOG, BIN_LOG] is the explicit argv[0] form. With no trailing arguments Ruby takes the
  # single-string form and word-splits it, so a checkout path containing a space fails with ENOENT
  # on the first fragment — and the zero-argument call is exactly what the usage test makes.
  def run_log(*args, env: {})
    cleared = BUNDLER_ENV.to_h { |name| [ name, nil ] }
    base = cleared.merge("KANEO_URL" => "http://127.0.0.1:1", "LOG_SPOOL_DIR" => @spool)

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

  # THE TOKEN MUST NEVER REACH fd2. bin/secret's header records the mechanism: writing
  # `op read "$ref" 2>&1 >/dev/null` points fd2 at the CURRENT stdout and only then moves fd1, so
  # the value lands in whatever captured the command. That printed a live ghcr PAT into an agent
  # transcript on 2026-07-29 and the token had to be rotated. Open3.capture3 keeps the streams
  # apart, which is why bin/log must use it rather than a backtick or a merging redirect.
  test "a resolved token never appears on either stream" do
    out, err, _code = run_log("show", "1", env: { "KANEO_TOKEN" => "sentinel-token-value" })

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
  test "an exported KANEO_TOKEN is used without consulting 1Password" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "op"), "#!/bin/sh\necho 'op: vault locked' >&2\nexit 1\n")
      File.chmod(0o755, File.join(dir, "op"))

      _out, err, code = run_log("show", "1", env: {
        "KANEO_TOKEN" => "exported-wins",
        "PATH"          => "#{dir}:#{ENV['PATH']}"
      })

      assert_equal 3, code, "expected the UNREACHABLE exit, not a credential failure"
      refute_includes err, "vault locked",
                      "bin/log consulted the vault despite an exported value — the override was lost"
    end
  end

  # exit(nil) is a TypeError and exit(false) is a SILENT status 1 — Ruby's own uncaught-exception
  # status, distinct from any EXIT_* constant of ours now that EXIT_UNFILED has moved off 1. An
  # arm that forgets its return value must still be LOUD, not silently misread as some other
  # outcome. Note an `assert_equal 0, code` test cannot catch a `true`-returning arm.
  test "main returning a non-integer is loud, not a wrong exit code" do
    _out, err, code = run_log("--help", env: { "LOG_FORCE_BAD_RETURN" => "1" })

    assert_equal 1, code
    assert_match(/not an exit code/, err,
                 "a non-integer return exited silently instead of naming the bad value")
  end

  # US-ASCII IS THE DEFAULT EXTERNAL ENCODING WHENEVER LANG/LC_ALL IS UNSET — cron, systemd,
  # Docker, a bare runner. bin/secret's diagnostics carry a UTF-8 ellipsis, so `err.strip` raised
  # Encoding::CompatibilityError and the credential path exited 1 — which was EXIT_UNFILED, so a
  # locked vault told /finish-branch there was a backlog. No developer shell reproduces this, which
  # is why the test unsets the locale itself.
  test "a credential failure with no locale exits cleanly, not as a stack trace" do
    Dir.mktmpdir do |dir|
      op = File.join(dir, "op")
      File.write(op, "#!/bin/sh\nprintf 'op: vault locked \\342\\200\\246\\n' >&2\nexit 1\n")
      File.chmod(0o755, op)

      _out, err, code = run_log("show", "1", env: {
        # LC_CTYPE TOO, NOT JUST LANG/LC_ALL. Ruby resolves the default external encoding from
        # whichever of the three is set, so clearing two of them leaves the guard vacuous on any
        # machine that sets the third — measured: this mutation went GREEN in one environment and
        # RED in another, for no reason but an ambient LC_CTYPE.
        "PATH" => "#{dir}:#{ENV['PATH']}", "KANEO_TOKEN" => nil,
        "LANG" => nil, "LC_ALL" => nil, "LC_CTYPE" => nil
      })

      assert_equal 3, code, "a locale-less credential failure did not reach the clean unreachable exit"
      refute_includes err, "Encoding::CompatibilityError",
                      "the encoding crash is back — bin/log must set default_external"
      refute_includes err, "in 'Log.token'", "a stack trace reached the user"
    end
  end

  # THE CATCH-ALL AND EXIT_BUG, DRIVEN BY A REAL TRIGGER RATHER THAN A TEST HOOK. A server answers
  # an error as a JSON OBJECT where a list was expected, and the workspace resolve's
  # `orgs.find { |o| o["slug"] == ... }` then indexes an Array with a String — TypeError, because
  # Hash#find yields a PAIR. Nothing else in the suite reaches main's
  # `rescue StandardError`, so before this both its existence and its EXIT_BUG return were asserted
  # nowhere: the mutation sweep found removing the catch-all, and changing its return code, BOTH
  # green.
  test "an unexpected error is EXIT_BUG and says plainly that nothing was spooled" do
    stub = StubKaneo.new(status: 200, response: { "message" => "repository not found" })

    _out, err, code = run_log("search", "anything", env: {
      "KANEO_TOKEN" => "t0ken", "KANEO_URL" => stub.url
    })

    assert_equal 5, code, "a bug in bin/log reported itself as a recoverable outage"
    assert_includes err, "unexpected failure"
    assert_includes err, "NOT SPOOLED",
                     "the user was not told the record is unrecorded"
  ensure
    stub&.shutdown
  end

  # THE WIRE FORMAT IS THE ASSERTION. Not "the issue came back with our title" — that passes even
  # when both sides share a bug. Path, auth header and JSON body, each checked literally.
  test "open POSTs the documented task payload, then attaches the label" do
    stub = StubKaneo.new(routes: {
      "GET /auth/organization/list" => [ 200, [ { "id" => "w1", "slug" => "tinkerex" } ] ],
      "GET /project" => [ 200, [ { "id" => "p1", "slug" => "tinkerex" } ] ]
    })

    # THE TRAILING NEWLINE IS DELIBERATE, NOT A TYPO. `bin/secret` returns an EXPORTED override
    # verbatim (`printf '%s'`, no stripping — only the 1Password path is `--no-newline`), so this
    # is exactly what a value like `export KANEO_TOKEN=$(pass show ...)` can hand `token` when
    # the source appends one. Without `.chomp` this reaches the header as "Bearer t0ken\n" — Ruby's
    # own Net::HTTP raises `ArgumentError: header field value cannot include CR/LF` for that, so a
    # dropped `.chomp` doesn't corrupt the request, it crashes it outright.
    out, err, code = run_log("open", "The scan tombstones a live node", env: {
      "KANEO_TOKEN" => "t0ken\n", "KANEO_URL" => stub.url,
      "KANEO_WORKSPACE" => "tinkerex", "KANEO_PROJECT" => "tinkerex"
    })

    assert_equal 0, code, "bin/log open failed: #{err}"
    assert_includes out, "#42"

    # FOUR CALLS, AND ALL FOUR ARE THE CONTRACT: resolve the workspace, resolve the project, create
    # the task, attach the label. Creation is NOT atomic here — `POST /task/:projectId` has no
    # labels field — so a test asserting only the create would pass over a task with no label.
    assert_equal %w[GET GET POST POST], stub.requests.map(&:method)

    request = stub.requests[2]
    assert_equal "/api/task/p1", request.path
    assert_equal "Bearer t0ken", request.headers["authorization"],
                "a trailing newline on the exported token reached the Authorization header uncleaned"
    assert_equal "application/json", request.headers["content-type"]

    assert_equal "The scan tombstones a live node", request.json["title"]
    assert_equal "no-priority", request.json["priority"]
    refute request.json.key?("labels"),
           "a label rode along on the create — Kaneo has no such field and would drop it silently"

    label = stub.requests[3]
    assert_equal "/api/label", label.path
    assert_equal "open-work", label.json["name"], "labels are attached BY NAME, in one call"
    assert_equal "task_stub", label.json["taskId"],
                 "the attachment must name the task just created, or it lands as a definition"
    assert_equal "w1", label.json["workspaceId"]
  ensure
    stub&.shutdown
  end

  # A 2xx WHOSE BODY IS NOT JSON IS AN OUTAGE, NOT A CRASH. A proxy error page and Kaneo's own
  # login page on a session redirect both arrive as 200 text/html. Unwrapped, JSON::ParserError
  # escaped to Ruby's default handler and exited 1 — which was EXIT_UNFILED, so a broken proxy
  # reported a backlog.
  test "a 2xx with a non-JSON body is unreachable, not a stack trace" do
    stub = StubKaneo.new(status: 200, response: "<html>502 Bad Gateway</html>")

    _out, err, code = run_log("show", "1", env: {
      "KANEO_TOKEN" => "t0ken", "KANEO_URL" => stub.url
    })

    assert_equal 3, code, "a non-JSON 2xx did not reach the clean unreachable exit"
    assert_includes err, "non-JSON body"
    refute_includes err, "JSON::ParserError:", "a raw parser error reached the user"
    assert_empty stub.errors, "the stub itself raised: #{stub.errors.map(&:message)}"
  ensure
    stub&.shutdown
  end

  # THE TEST ABOVE ONLY DRIVES A READ (`show`). `create_task` goes through `parse` too, but
  # nothing exercised that on a WRITE — so a revert of `create_task` back to a bare `JSON.parse`
  # would raise an unwrapped `JSON::ParserError` on exactly this response and stay invisible: the
  # read-side guard cannot see a write-side regression. Unwrapped, that error is neither
  # `Unreachable` nor spooled, and used to exit 1 outright.
  #
  # THE TWO RESOLUTION ROUTES ANSWER PROPERLY, and that is what makes this test about the write.
  # With the html default answering everything, the FIRST call to fail is the workspace resolve —
  # a read, which spools nothing — so the guard would go green having never reached `create_task`.
  test "a write receiving a non-JSON 2xx is unreachable and spools" do
    stub = StubKaneo.new(status: 200, response: "<html>proxy</html>", routes: {
      "GET /auth/organization/list" => [ 200, [ { "id" => "w1", "slug" => "tinkerex" } ] ],
      "GET /project" => [ 200, [ { "id" => "p1", "slug" => "tinkerex" } ] ]
    })

    Dir.mktmpdir do |spool|
      _out, err, code = run_log("open", "filed through a broken proxy", env: {
        "KANEO_TOKEN" => "t0ken", "KANEO_URL" => stub.url,
        "LOG_SPOOL_DIR" => spool, "LOG_BRANCH" => "claude/example"
      })

      assert_equal 3, code
      assert_includes err, "non-JSON body"
      assert_includes File.read(File.join(spool, "claude-example.md")), "filed through a broken proxy"
    end
  ensure
    stub&.shutdown
  end

  # THE ARC BODY IS THE PR BODY. /finish-branch already specifies that document — symptom, root
  # cause, why tests missed it, verification table, scope. Rewriting it into a second document by
  # hand is exactly the per-PR tax that made STATUS.md unworkable, so bin/log reads it back
  # out of the PR. GH_BIN stubs `gh`; Task 8 mutation-checks that the stub is actually consulted.
  test "arc --from-pr builds the issue from the PR body and links back to it" do
    stub = StubKaneo.new(routes: {
      "GET /auth/organization/list" => [ 200, [ { "id" => "w1", "slug" => "tinkerex" } ] ],
      "GET /project" => [ 200, [ { "id" => "p1", "slug" => "tinkerex" } ] ]
    })

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
        "KANEO_TOKEN" => "t0ken", "KANEO_URL" => stub.url,
        "KANEO_WORKSPACE" => "tinkerex", "KANEO_PROJECT" => "tinkerex", "GH_BIN" => gh
      })

      assert_equal 0, code, "bin/log arc failed: #{err}"
      request = stub.requests.find { |r| r.method == "POST" }

      assert_equal "Fix the tombstone cascade", request.json["title"]
      # `description`, NOT `body`. The key moved with the record; a payload still spelling it `body`
      # is accepted by the server and stores an EMPTY description — the arc arrives titled and blank.
      assert_includes request.json["description"], "The delete was applied per-node.",
                      "the PR body was not carried into the arc issue"
      assert_includes request.json["description"], "https://github.com/chaim354/tinkerex/pull/261",
                      "the arc must link the PR it describes, or the diff is unreachable from the record"

      label = stub.requests.select { |r| r.method == "POST" }.last
      assert_equal "arc", label.json["name"], "an arc with no arc label is invisible to every search"
    end
  ensure
    stub&.shutdown
  end

  # THE CHOSEN FAILURE MODE: loud, spooled, NON-BLOCKING. Blocking the close-out was considered and
  # declined; so was a spool that replays automatically, because a queue that silently drains is
  # data loss wearing a fix. What remains must make the debt VISIBLE — that is `bin/log status`.
  #
  # LOG_SPOOL_DIR IS NOT A TEST CONVENIENCE. test_helper parallelizes by processor, so without it
  # these tests write the SAME absolute path from several forked workers at once — and that path is
  # the developer's real spool.
  test "an unreachable Kaneo spools the write, says so, and exits 3" do
    Dir.mktmpdir do |spool|
      _out, err, code = run_log("open", "Something worth keeping", env: {
        "KANEO_TOKEN" => "t0ken", "LOG_SPOOL_DIR" => spool, "LOG_BRANCH" => "claude/example"
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
    stub = StubKaneo.new(status: 502, response: { "message" => "bad gateway" })

    Dir.mktmpdir do |spool|
      _out, err, code = run_log("open", "Filed during an outage", env: {
        "KANEO_TOKEN" => "t0ken", "KANEO_URL" => stub.url,
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

  # RUBY DOES NOT ROUTE AN EXCEPTION RAISED INSIDE A `rescue` CLAUSE TO THAT BEGIN'S SIBLING
  # RESCUES — it escapes straight to the caller. So a spool failure (a read-only filesystem, a
  # container with no git on PATH, tmp/ owned by another user) used to skip main's catch-all
  # entirely and exit 1 with a raw FileUtils trace, having already printed the reassuring
  # "unreachable" message. The record was simply gone. This pins the recovered behaviour: the
  # spool failure is caught, and the payload is printed so the entry is not unrecoverable.
  test "a spool that cannot be written says so and prints the payload rather than losing it" do
    Dir.mktmpdir do |dir|
      blocked = File.join(dir, "blocked")
      FileUtils.mkdir_p(blocked)
      File.chmod(0o500, blocked)

      _out, err, code = run_log("open", "an arc worth keeping", env: {
        "KANEO_TOKEN" => "t0ken", "LOG_SPOOL_DIR" => File.join(blocked, "spool"),
        "LOG_BRANCH" => "claude/example"
      })

      assert_includes err, "THE SPOOL ALSO FAILED"
      assert_includes err, "an arc worth keeping",
                       "the payload was not printed — the record is unrecoverable"
      refute_equal 1, code, "the spool failure escaped to Ruby's default handler"
    ensure
      File.chmod(0o700, blocked) if File.exist?(blocked)
    end
  end

  # A READ VERB HAS NOTHING TO FILE. Spooling one would make `bin/log status` report unfiled work
  # that never existed, permanently, since nothing drains it — a false positive in the one
  # mechanism whose whole job is making real debt visible.
  test "a failed read spools nothing" do
    Dir.mktmpdir do |spool|
      _out, _err, code = run_log("show", "1", env: {
        "KANEO_TOKEN" => "t0ken", "LOG_SPOOL_DIR" => spool
      })

      assert_equal 3, code
      assert_empty Dir.glob(File.join(spool, "*.md")),
                   "a read verb spooled phantom work — status will report it forever"
    end
  end

  # THE GUARD FOR THE ABOVE. Without the default, this test's failed write lands in the real spool.
  test "a failed write never reaches the developer's real spool" do
    # COMPARE CONTENT, NOT A FILE COUNT. spool! APPENDS, so a count cannot tell "nothing was
    # written" from "a line was added to a file that already existed" — and a developer with an
    # unfiled entry for this branch has exactly that file. Measured: the count version reported a
    # false GREEN under mutation because of one stray pre-existing spool file.
    branch = `git branch --show-current`.strip.tr("/", "-")
    real = Rails.root.join("tmp/log-pending", "#{branch}.md")
    before = File.exist?(real) ? File.read(real) : nil

    _out, _err, code = run_log("open", "must not reach the real spool", env: { "KANEO_TOKEN" => "t0ken" })

    assert_equal 3, code
    after = File.exist?(real) ? File.read(real) : nil
    # A plain `assert` rather than assert_equal: the ordinary case is nil == nil (no such file
    # before or after), and minitest refuses assert_equal against nil.
    assert after == before,
           "a test wrote into the developer's real spool — LOG_SPOOL_DIR is not defaulted"
  end

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
  # A DETACHED HEAD IS THE ENVIRONMENT THIS SCRIPT IS PROMISED TO WORK IN. §13 names CI, cloud
  # sessions, subagents and worktrees; GitHub Actions checks out a SHA, so `git branch
  # --show-current` prints "" there and `git bisect` does the same locally.
  #
  # THE BUG THIS PINS WAS SILENT IN THE WORST DIRECTION. An empty branch made the spool file
  # `<spool>/.md`, and `Dir.glob("<spool>/*.md")` does not match a leading dot — so `status` reported
  # "nothing unfiled" over a record that was sitting right there, and EXIT_UNFILED could never fire.
  # /finish-branch reads that exit code to decide whether there is unrecorded work.
  #
  # DRIVEN THROUGH BOTH VERBS, because either alone is only half the claim: a write must produce a
  # findable file, and `status` must find it. Found by CI, not by this suite — the suite ran on a
  # named branch, where the name is never empty.
  test "a detached HEAD spools to a findable file, not an invisible dotfile" do
    stub = StubKaneo.new(status: 503, response: { "message" => "down" })

    _out, _err, code = run_log("open", "work done while detached",
                               env: { "KANEO_URL" => stub.url, "KANEO_TOKEN" => "k", "LOG_BRANCH" => "" })

    assert_equal 3, code, "an unreachable write must spool and exit 3"

    written = Dir.children(@spool)
    assert_equal 1, written.size, "exactly one spool file: #{written.inspect}"
    refute written.first.start_with?("."),
           "a dotfile is invisible to status's glob — got #{written.first.inspect}"

    out, _err, status_code = run_log("status")

    assert_equal 4, status_code, "status must report the backlog it can now see"
    assert_match(/1 unfiled record/, out)
  ensure
    stub&.shutdown
  end

  test "status names every spooled entry and exits EXIT_UNFILED" do
    Dir.mktmpdir do |spool|
      File.write(File.join(spool, "claude-example.md"), "# unfiled: open
")

      out, _err, code = run_log("status", env: { "LOG_SPOOL_DIR" => spool })

      assert_equal 4, code, "an outstanding record must fail loud, not print a note and exit 0"
      refute_equal 1, code,
                   "EXIT_UNFILED must not be Ruby's own crash status, or a crash reads as a backlog"
      assert_includes out, "claude-example.md"
    end
  end

  # THE EXPECTED SET IS WRITTEN OUT HERE, NOT READ OUT OF bin/log's OWN LABELS CONSTANT — a test
  # that derives its expectation from the code under test can never disagree with it, and so
  # asserts nothing about that code being right. This is bin/log's LABELS as of this writing; a
  # deliberate change there must update this list BY HAND, which is the point.
  # IDEMPOTENCY IS ASKING WHAT EXISTS, NOT TOLERATING A REFUSAL. The record this replaced ALLOWED
  # DUPLICATE LABEL NAMES — measured against the live instance: a second `setup` run created a
  # second copy of all eleven and reported "11 labels present" both times, leaving 22. The test
  # before THAT one asserted a 422 the server never sends, and passed because the stub answered 422
  # because the test said to.
  test "setup creates nothing when every label already exists" do
    stub = StubKaneo.new(routes: {
      "GET /auth/organization/list" => [ 200, [ { "id" => "w1", "slug" => "tinkerex" } ] ],
      "GET /label/workspace" => [ 200, LABEL_FIXTURE ]
    })

    out, err, code = run_log("setup", env: {
      "KANEO_TOKEN" => "t0ken", "KANEO_URL" => stub.url,
      "KANEO_WORKSPACE" => "tinkerex", "KANEO_PROJECT" => "tinkerex"
    })

    assert_equal 0, code, "bin/log setup failed: #{err}"
    assert_empty stub.requests.select { |r| r.method == "POST" },
                 "setup POSTed a label that already existed — nothing refuses a DUPLICATE name"
    assert_includes out, "0 created"
    assert_includes stub.requests.last.path, "/api/label/workspace/w1",
                    "the vocabulary is asked for by workspace, not by project"
  ensure
    stub&.shutdown
  end

  # AND IT VERIFIES RATHER THAN ASSUMING ITS POSTs WORKED. "I sent eleven requests" is not the claim
  # this command makes; "eleven labels exist" is. The first GET lacks the `ci` DEFINITION; the
  # second, after the POST, has it.
  #
  # THE ATTACHED `ci` ROW IN THE FIRST ANSWER IS THE WHOLE POINT OF THIS FIXTURE, and without it
  # this test cannot see the bug it exists for. Kaneo returns definitions and attachments from ONE
  # endpoint, so a vocabulary index that does not filter `taskId.nil?` counts 135 labelled arcs as
  # proof the `arc` definition exists — and goes on counting them after someone deletes it. Here:
  # the definition of `ci` is gone while a task still carries the label. Drop the filter and setup
  # reports "0 created" for a vocabulary that is missing an entry, which is the one thing it exists
  # to notice. A fixture whose attachment duplicates a definition that IS present cannot show this:
  # `to_h` collapses the duplicate name and the count comes out right by accident.
  test "setup creates only what is missing, then confirms the whole set" do
    attached_ci = { "id" => "lbl-attached", "name" => "ci", "taskId" => "t1" }
    partial = LABEL_FIXTURE.reject { |l| l["name"] == "ci" } + [ attached_ci ]
    stub = StubKaneo.new(routes: {
      "GET /auth/organization/list" => [ 200, [ { "id" => "w1", "slug" => "tinkerex" } ] ],
      "GET /label/workspace" => [ [ 200, partial ], [ 200, LABEL_FIXTURE + [ attached_ci ] ] ],
      "POST /label" => [ 201, { "id" => "lbl11", "name" => "ci" } ]
    })

    out, err, code = run_log("setup", env: { "KANEO_TOKEN" => "t0ken", "KANEO_URL" => stub.url })

    assert_equal 0, code, "bin/log setup failed: #{err}"
    posts = stub.requests.select { |r| r.method == "POST" }
    assert_equal [ "ci" ], posts.map { |r| r.json["name"] },
                 "setup POSTed a label that already existed, or skipped one that did not"
    assert_equal "w1", posts.first.json["workspaceId"]
    refute posts.first.json.key?("taskId"),
           "a definition POSTed with a taskId is an ATTACHMENT — the vocabulary would stay empty"
    assert_includes out, "1 created"
  ensure
    stub&.shutdown
  end

  # A WRITE'S FIRST WIRE CALL IS A READ, and that must not turn a write into a no-record. It was
  # the label resolve before the move and it is the workspace/project resolve now — the same trap
  # with a different first call, which is why this test survives it unchanged. Regression the
  # moment id resolution landed: the payload was built in one expression whose own lookup raised,
  # leaving it nil, so the rescue reported "nothing to file" for an unambiguous write.
  test "a write whose id resolution fails still spools what it was going to send" do
    Dir.mktmpdir do |spool|
      _out, err, code = run_log("open", "must survive a failed resolve", env: {
        "KANEO_TOKEN" => "t0ken", "LOG_SPOOL_DIR" => spool, "LOG_BRANCH" => "claude/example"
      })

      assert_equal 3, code
      refute_includes err, "nothing to file", "a write was reported as having nothing to spool"
      assert_includes File.read(File.join(spool, "claude-example.md")),
                      "must survive a failed resolve"
    end
  end

  # AN EM DASH IN A TITLE, UNDER A LOCALE-LESS SHELL, ARRIVES AS ASCII-8BIT. Measured:
  # ARGV[0].encoding is ASCII-8BIT for "smoke test — safe" with LANG unset, and JSON.generate warns
  # today and RAISES in json 3.0. This repo's titles use em dashes constantly, so it is not an edge
  # case — and none of the thirty mutations found it. The live smoke test did, on its first run.
  test "a non-ASCII title survives a locale-less environment" do
    stub = StubKaneo.new(routes: {
      "GET /auth/organization/list" => [ 200, [ { "id" => "w1", "slug" => "tinkerex" } ] ],
      "GET /project" => [ 200, [ { "id" => "p1", "slug" => "tinkerex" } ] ]
    })

    _out, err, code = run_log("open", "an arc — with an em dash", env: {
      "KANEO_TOKEN" => "t0ken", "KANEO_URL" => stub.url,
      "LANG" => nil, "LC_ALL" => nil, "LC_CTYPE" => nil
    })

    assert_equal 0, code, "bin/log open failed: #{err}"
    refute_includes err, "BINARY", "JSON.generate warned — json 3.0 raises on this"
    assert_equal "an arc — with an em dash",
                 stub.requests.find { |r| r.method == "POST" }.json["title"]
  ensure
    stub&.shutdown
  end

  # THE NUMBER THE SERVER ASSIGNS IS WHAT EVERY LATER CITATION USES, so a create that does not
  # print it back leaves the caller with an arc they cannot cite. Two calls, and both are asserted:
  # the task, then the label attached to the id that create returned.
  test "creating an arc posts the task, then attaches the label, and reports the number" do
    stub = StubKaneo.new(routes: {
      "GET /auth/organization/list" => [ 200, [ { "id" => "w1", "slug" => "tinkerex" } ] ],
      "GET /project" => [ 200, [ { "id" => "p1", "slug" => "tinkerex" } ] ],
      "POST /task/p1" => [ 201, { "id" => "t9", "number" => 194, "title" => "An arc", "status" => "to-do" } ],
      "POST /label" => [ 201, { "id" => "l1", "name" => "arc" } ]
    })
    Dir.mktmpdir do |dir|
      path = File.join(dir, "entry.md")
      File.write(path, "## An arc\n\nWhat it did.\n")

      out, err, code = run_log("arc", "--from-file", path,
                               env: { "KANEO_URL" => stub.url, "KANEO_TOKEN" => "k" })

      assert_equal 0, code, err
      create = stub.requests.find { |r| r.method == "POST" && r.path.include?("/task/p1") }
      assert_equal "no-priority", create.json["priority"]
      assert_equal "An arc", create.json["title"]
      label = stub.requests.find { |r| r.method == "POST" && r.path == "/api/label" }
      assert_equal "arc", label.json["name"]
      assert_equal "t9", label.json["taskId"]
      assert_match(/#194/, out)
    end
  ensure
    stub&.shutdown
  end

  # A LABEL PROBLEM NAMES ITSELF RATHER THAN SURFACING A SERVER ERROR THAT DESCRIBES OUR BUG. The
  # test this replaces drove a label the repo did not have, because label NAMES had to be resolved
  # to int64 ids before a create and a missing one produced "cannot unmarshal string into ...
  # int64". That refusal cannot happen here: Kaneo takes the name on `POST /label` and creates the
  # row if it is new, so there is no lookup to miss. The condition that DID appear in its place is
  # the one below — creation is two calls now, and the second can fail on its own.
  #
  # CREATED-BUT-UNLABELLED IS REPORTED, NAMING THE NUMBER. An arc with no `arc` label is invisible
  # to every search that filters by kind, and silently so; and the number has to be in the message
  # because the task exists — a caller told only "the label failed" cannot tell whether to retry the
  # whole command, which would file a duplicate arc at a new number that no citation points at.
  test "a task created but left unlabelled is reported, never reported as success" do
    stub = StubKaneo.new(routes: {
      "GET /auth/organization/list" => [ 200, [ { "id" => "w1", "slug" => "tinkerex" } ] ],
      "GET /project" => [ 200, [ { "id" => "p1", "slug" => "tinkerex" } ] ],
      "POST /task/p1" => [ 201, { "id" => "t9", "number" => 194, "title" => "An arc", "status" => "to-do" } ],
      "POST /label" => [ 500, { "message" => "boom" } ]
    })
    Dir.mktmpdir do |dir|
      path = File.join(dir, "entry.md")
      File.write(path, "## An arc\n\nWhat it did.\n")

      _out, err, code = run_log("arc", "--from-file", path,
                                env: { "KANEO_URL" => stub.url, "KANEO_TOKEN" => "k" })

      refute_equal 0, code
      assert_match(/#194 was created/, err)
      assert_match(/label/, err)
      assert_includes err, '"arc" label',
                      "the failure must name the label, not just say one failed"

      # WHAT IS SPOOLED MUST BE THE LABEL ATTACHMENT, NEVER THE CREATE. With the create record
      # spooled instead, refiling that entry files a SECOND arc at a new number -- one that no
      # tinkerex#N citation points at -- while the original stays unlabelled and invisible to every
      # search that filters by kind. Two things in bin/log keep it out, and either alone suffices:
      # the attachment is its own `filing` phase, a SIBLING of the create's rather than nested in
      # it, and `filing` keeps the innermost record (`||=`) if anyone ever does nest them.
      #
      # THE RECORD SAYS WHAT IT IS IN THE RECORD'S OWN TERMS — the issue and the label — where it
      # used to name the endpoint. An endpoint line recorded whichever request FAILED, so a create
      # against a dead server was filed under the workspace lookup.
      spooled = File.read(Dir.glob(File.join(@spool, "*.md")).first)
      assert_match(/^# unfiled: .*#194 was created.*"arc" label/, spooled,
                   "the record must name the attachment that failed: the issue and its label")
      assert_includes spooled, '"taskId": "t9"',
                      "the spooled payload must name the task the label belongs to"
      refute_includes spooled, '"description"',
                      "spooling the CREATE payload invites a duplicate arc at a new number on refile"
    end
  ensure
    stub&.shutdown
  end

  test "deploy --dest share files a record naming only share, not the other two backends" do
    stub = StubKaneo.new(routes: {
      "GET /auth/organization/list" => [ 200, [ { "id" => "w1", "slug" => "tinkerex" } ] ],
      "GET /project" => [ 200, [ { "id" => "p1", "slug" => "tinkerex" } ] ]
    })

    _out, err, code = run_log("deploy", "--image", "e079d433", "--dest", "share", env: {
      "KANEO_TOKEN" => "t0ken", "KANEO_URL" => stub.url,
      "KANEO_WORKSPACE" => "tinkerex", "KANEO_PROJECT" => "tinkerex"
    })

    assert_equal 0, code, "bin/log deploy failed: #{err}"
    request = stub.requests.find { |r| r.method == "POST" && r.path.include?("/task/") }

    assert_includes request.json["title"], "e079d433"
    assert_includes request.json["description"], "share"
    refute_includes request.json["description"], "chunk_remote",
                    "--dest share still filed chunk_remote — --dest is being ignored"

    label = stub.requests.find { |r| r.method == "POST" && r.path == "/api/label" }
    assert_equal "deploy", label.json["name"], "labels are attached by name, in their own call"
  ensure
    stub&.shutdown
  end

  # REFUSE, NEVER GUESS. `--dest` used to be read positionally (`argv[0] == "--dest" ? argv[1] :
  # ...`), so a typo'd flag name fell straight through to the three-destination default — filing a
  # deploy record claiming chunk_remote, share AND s3 were deployed when the operator named only
  # one. That is a false record from the very tool that exists because the old record kept going
  # stale, and it fails silently: the command exits 0.
  test "an unrecognised deploy flag is refused, never silently defaulted" do
    _out, err, code = run_log("deploy", "--image", "abc123", "--destination", "only-share",
                              env: { "KANEO_TOKEN" => "t0ken" })

    assert_equal 2, code, "a typo'd flag filed a record instead of being refused"
    assert_includes err, "unrecognised argument"
  end

  test "deploy --dest with no value is a usage error, not a crash" do
    _out, _err, code = run_log("deploy", "--image", "abc123", "--dest",
                               env: { "KANEO_TOKEN" => "t0ken" })

    assert_equal 2, code
  end

  # A CORRECTION IS A COMMENT, NOT AN EDIT. This is the whole reason the move helps: STATUS.md's
  # recurring failure was a stale claim buried mid-file, and CLAUDE.md records several in its own
  # voice ("this bullet went on asserting a single even bound for months"). A dated comment appends
  # visibly; finding and rewriting a paragraph at line 4,700 does not happen.
  test "note posts a comment against the resolved task id and never rewrites the description" do
    stub = StubKaneo.new(routes: {
      "GET /auth/organization/list" => [ 200, [ { "id" => "w1", "slug" => "tinkerex" } ] ],
      "GET /project" => [ 200, [ { "id" => "p1", "slug" => "tinkerex" } ] ],
      "GET /task/tasks" => [ 200, { "data" => { "columns" => [
        { "slug" => "done", "tasks" => [ { "id" => "abc", "number" => 178, "title" => "x", "status" => "done" } ] }
      ] }, "pagination" => { "totalPages" => 1 } } ],
      "POST /comment" => [ 201, { "id" => "c1" } ]
    })
    _out, err, code = run_log("note", "178", "The measured figure was 7.8 ms, not 5.", env: {
      "KANEO_URL" => stub.url, "KANEO_TOKEN" => "k",
      "KANEO_WORKSPACE" => "tinkerex", "KANEO_PROJECT" => "tinkerex"
    })

    assert_equal 0, code, "bin/log note failed: #{err}"
    comment = stub.requests.find { |r| r.method == "POST" }

    # THE PATH CARRIES THE OPAQUE id, NOT THE CITED NUMBER — 178 resolved to "abc" off the board
    # first. A path built from the number reaches a real endpoint and comments on a DIFFERENT task.
    assert_equal "/api/comment/abc", comment.path
    assert_equal "The measured figure was 7.8 ms, not 5.", comment.json["content"]
    refute comment.json.key?("title"), "note sent a title — it is editing the task, not commenting"
    # STRICTER THAN "no PUT naming a description": Kaneo's task update is PUT /task/:id, whose path
    # says nothing about what it writes, so the only honest assertion is that note sends no PUT.
    assert_empty stub.requests.select { |r| r.method == "PUT" },
                 "note sent a PUT — a correction is a comment, never a rewrite of the record"
  ensure
    stub&.shutdown
  end

  # `note` IS THE ONE VERB WHOSE TARGET IS IN NEITHER THE PAYLOAD NOR THE PATH. It used to be in
  # the path (/issues/128/comments), so spooling path + payload carried it for free. Kaneo addresses
  # a comment by the task's opaque id and resolving that id is note's FIRST wire call, so an outage
  # fails inside the board fetch — whose path names the board. A correction spooled without the
  # number is unrecoverable by hand: the text says what was wrong and nothing says about what.
  test "a note spooled during an outage records which issue it belongs to" do
    Dir.mktmpdir do |spool|
      run_log("note", "128", "The measured figure was 7.8 ms.", env: {
        "KANEO_TOKEN" => "t0ken", "LOG_SPOOL_DIR" => spool, "LOG_BRANCH" => "claude/example"
      })

      spooled = File.read(File.join(spool, "claude-example.md"))
      assert_includes spooled, "128",
                      "the issue number is only in the URL, so without it the correction is orphaned"
    end
  end

  # REJECT, NEVER NORMALIZE — CLAUDE.md §14a's `key_for` rule, same repo, different subsystem.
  # Net::HTTP does not normalise a `..` segment, so it reaches the wire verbatim and a normalising
  # reverse proxy in front of Kaneo can resolve it somewhere the caller never named.
  test "an issue number containing path traversal is refused before it reaches the wire" do
    _out, err, code = run_log("show", "../../../../admin/users", env: { "KANEO_TOKEN" => "t0ken" })

    assert_equal 2, code, "a traversal segment was sent to the server"
    assert_includes err, "not an issue number"
  end

  # THE QUERY MUST BE PERCENT-ENCODED, NOT JUST PRESENT. "chunk_remote" has nothing in it that
  # needs encoding, so a search query built by straight interpolation instead of
  # `URI.encode_www_form_component` passed that query unnoticed. `&` and `#` are both wire-active
  # characters — a bare `&` starts a new query param and a bare `#` starts a fragment — so a query
  # containing either breaks the request unless encoded.
  #
  # NOTHING ASKS FOR A STATE ANY MORE, and that is a real change rather than a dropped assertion.
  # The old search defaulted to open issues and needed an explicit state=all or it found no finished
  # work at all — which is most of the record. Kaneo's search spans every column already.
  test "search percent-encodes the query and scopes it to the workspace" do
    stub = StubKaneo.new(routes: {
      "GET /auth/organization/list" => [ 200, [ { "id" => "w1", "slug" => "tinkerex" } ] ],
      "GET /project" => [ 200, [ { "id" => "p1", "slug" => "tinkerex" } ] ],
      "GET /search" => [ 200, { "results" => [], "totalCount" => 0 } ]
    })

    out, err, code = run_log("search", "502 & the proxy #2", env: {
      "KANEO_TOKEN" => "t0ken", "KANEO_URL" => stub.url,
      "KANEO_WORKSPACE" => "tinkerex", "KANEO_PROJECT" => "tinkerex"
    })

    assert_equal 0, code, "bin/log search failed: #{err}"
    request = stub.requests.find { |r| r.path.include?("/search") }

    assert_equal "GET", request.method
    assert_includes request.path, "workspaceId=w1",
                    "without the workspace Kaneo answers 400, Workspace ID could not be determined"
    assert_includes request.path, "%26", "the query's & must be percent-encoded, not sent bare"
    assert_includes request.path, "%23", "the query's # must be percent-encoded, not sent bare"
    refute_includes request.path, "& the proxy #2",
                    "the raw query reached the path unencoded"
    assert_includes out, "no issues matching"
  ensure
    stub&.shutdown
  end

  # THE TWO NEGATIVE ASSERTIONS ARE THE POINT. Kaneo's search returns comments and activities
  # alongside tasks, and ignores projectId entirely — measured: passing it changed nothing, and
  # totalCount stayed identical — so a verb that filtered only ONE of the two would still pass a
  # test that asserted the happy line alone. A task row also carries `taskNumber`, not `number`,
  # so reading `number` prints "#" and nothing else for results that are otherwise correct.
  test "search asks Kaneo's search endpoint, scoped to the project, and percent-encodes the query" do
    stub = StubKaneo.new(routes: {
      "GET /auth/organization/list" => [ 200, [ { "id" => "w1", "slug" => "tinkerex" } ] ],
      "GET /project" => [ 200, [ { "id" => "p1", "slug" => "tinkerex" } ] ],
      "GET /search" => [ 200, { "results" => [
        { "type" => "task", "projectId" => "p1", "taskNumber" => 12, "title" => "a & b", "status" => "done" },
        { "type" => "comment", "projectId" => "p1", "taskNumber" => 12, "title" => "a & b noise" },
        { "type" => "task", "projectId" => "OTHER", "taskNumber" => 99, "title" => "a & b elsewhere" }
      ], "totalCount" => 3 } ]
    })
    out, err, code = run_log("search", "a & b", env: { "KANEO_URL" => stub.url, "KANEO_TOKEN" => "k" })

    assert_equal 0, code, err
    search = stub.requests.find { |r| r.path.include?("/search") }
    assert_includes search.path, "q=a+%26+b"
    assert_includes search.path, "workspaceId=w1"
    # THE CAP IS 50 HERE AND 100 ON THE BOARD, AND THIS ASSERTION CANNOT PROVE IT — the stub takes
    # whatever it is sent. It is here so the value is not "tidied" to match task_index's 100, which
    # /api/search refuses outright with `400 {"expected":"<=50"}`. Found by pointing bin/log at the
    # real server after a fully green suite; §15's rule that a probe beats an argument, in the one
    # direction a stub structurally cannot cover.
    assert_includes search.path, "limit=50"
    assert_match(/#12 \[done\] a & b/, out)
    refute_match(/noise/, out, "a matching comment must not print as though it were an issue")
    refute_match(/#99/, out, "projectId does not filter server-side; this verb must filter itself")
  ensure
    stub&.shutdown
  end

  # A SCHEME-LESS KANEO_URL parses to host=nil, and Net::HTTP.start(nil, nil) then reports
  # "connection refused for nil port 80" — a confident, wrong answer to a malformed env var.
  test "a KANEO_URL with no scheme is a usage error, not a phantom connection refusal" do
    _out, err, code = run_log("show", "1", env: {
      "KANEO_TOKEN" => "t0ken", "KANEO_URL" => "kaneo.home"
    })

    assert_equal 2, code, "a malformed KANEO_URL was reported as a network failure"
    assert_includes err, "no scheme or host"
  end

  # gh ANSWERING NON-JSON — an auth prompt, a rate-limit notice — must name gh and the PR. Left
  # unwrapped it surfaces through main's catch-all as "unexpected failure", which names neither.
  test "gh returning non-JSON names gh and the PR" do
    Dir.mktmpdir do |dir|
      gh = File.join(dir, "gh")
      File.write(gh, "#!/bin/sh\necho 'gh auth login required'\n")
      File.chmod(0o755, gh)

      _out, err, code = run_log("arc", "--from-pr", "261", env: {
        "KANEO_TOKEN" => "t0ken", "GH_BIN" => gh
      })

      assert_equal 3, code, "a non-JSON gh reply did not become a clean unreachable exit"
      assert_includes err, "gh returned non-JSON"
      assert_includes err, "261"
    end
  end

  # HISTORICAL ARCS ARRIVE ALREADY FINISHED, so they must be created CLOSED. There is no closed
  # FLAG to set: statuses are kebab-case board columns, measured, and a POST carrying "Done" is
  # refused with a 400 naming the whole set. Closed means the `done` column and nothing else.
  test "arc --from-file imports a section, closed, with its first heading as the title" do
    stub = StubKaneo.new(routes: {
      "GET /auth/organization/list" => [ 200, [ { "id" => "w1", "slug" => "tinkerex" } ] ],
      "GET /project" => [ 200, [ { "id" => "p1", "slug" => "tinkerex" } ] ]
    })

    Dir.mktmpdir do |dir|
      path = File.join(dir, "entry.md")
      File.write(path, "## 2026-07-29: the audit-fix arc\n\nTwo security gates ran zero.\n")

      _out, err, code = run_log("arc", "--from-file", path, "--closed", env: {
        "KANEO_TOKEN" => "t0ken", "KANEO_URL" => stub.url,
        "KANEO_WORKSPACE" => "tinkerex", "KANEO_PROJECT" => "tinkerex"
      })

      assert_equal 0, code, "import failed: #{err}"
      post = stub.requests.find { |r| r.method == "POST" }

      assert_equal "2026-07-29: the audit-fix arc", post.json["title"],
                   "the leading '## ' must be stripped, or every title starts with markup"
      assert_includes post.json["description"], "Two security gates ran zero."
      assert_equal "done", post.json["status"], "a finished arc must not import as open work"

      label = stub.requests.select { |r| r.method == "POST" }.last
      assert_equal "arc", label.json["name"]
    end
  ensure
    stub&.shutdown
  end

  # WITHOUT --closed IT STAYS OPEN. The same verb serves a live arc (opened at PR time, closed at
  # merge) and a historical import, so the default must be the live case — an import that forgets
  # the flag leaves a visible open issue, while the reverse silently closes live work.
  #
  # THE ASSERTION IS NOW POSITIVE, AND IT HAD TO BECOME ONE. Under a `closed:` flag the guard was
  # "the key is absent"; a task must name a column, so there is no absence to assert and the only
  # honest check is that the column named is the OPEN one.
  test "arc --from-file without --closed opens in the to-do column" do
    stub = StubKaneo.new(routes: {
      "GET /auth/organization/list" => [ 200, [ { "id" => "w1", "slug" => "tinkerex" } ] ],
      "GET /project" => [ 200, [ { "id" => "p1", "slug" => "tinkerex" } ] ]
    })

    Dir.mktmpdir do |dir|
      path = File.join(dir, "entry.md")
      File.write(path, "## live arc\n\nbody\n")
      run_log("arc", "--from-file", path, env: { "KANEO_TOKEN" => "t0ken", "KANEO_URL" => stub.url })

      post = stub.requests.find { |r| r.method == "POST" }
      assert_equal "to-do", post.json["status"],
                   "an import default of done would silently close live work"
    end
  ensure
    stub&.shutdown
  end

  # `closed:` DEFAULTS TO FALSE, AND SINCE 2026-09-01 `open` IS ITS ONLY EXERCISER. **Do not delete
  # this test on the grounds that `deploy` covers the same ground — it no longer does.** `arc` has
  # always passed an explicit boolean and `deploy` now passes one too, so from every OTHER call site
  # Ruby's keyword default is dead code: the mutation "default `closed:` to true" stayed GREEN when
  # it was run against those call sites. Observed, not predicted. This is the one test left that
  # makes the default real, which is exactly why it is now a test of its own.
  test "an ordinary open item never arrives closed" do
    stub = StubKaneo.new(routes: {
      "GET /auth/organization/list" => [ 200, [ { "id" => "w1", "slug" => "tinkerex" } ] ],
      "GET /project" => [ 200, [ { "id" => "p1", "slug" => "tinkerex" } ] ]
    })

    run_log("open", "an ordinary item", env: { "KANEO_TOKEN" => "t0ken", "KANEO_URL" => stub.url })

    posts = stub.requests.select { |r| r.method == "POST" && r.path.include?("/task/") }
    assert_equal 1, posts.size, "expected one task POST from open"
    assert_equal "to-do", posts.first.json["status"],
                 "an open item arrived already closed — it is live work, not history"
  ensure
    stub&.shutdown
  end

  # A DEPLOY RECORD IS HISTORY AND ARRIVES CLOSED — the opposite of the item above, and the reason
  # is the WORKFLOW rather than anything about the payload. `bin/log deploy` runs as the LAST step
  # of a deploy that has already rolled and been verified (`.claude/commands/deploy.md` §4). An arc
  # is filed open because its open→closed transition tracks a real later event, the merge. **A
  # deploy has no later event to wait for**, which is why nothing in this repo has ever closed one.
  #
  # MEASURED, NOT ASSUMED. On 2026-09-01 the record held six OPEN deploy issues and twelve closed
  # ones — and all twelve were Forgejo-migration imports carrying their state across, not closures
  # anyone performed. The open state had never meant anything; it just added one false entry to the
  # record's open list per deploy, which is the stale-open-list failure CLAUDE.md §14e calls worse
  # than no list at all.
  test "a deploy record arrives closed, because the deploy already happened" do
    stub = StubKaneo.new(routes: {
      "GET /auth/organization/list" => [ 200, [ { "id" => "w1", "slug" => "tinkerex" } ] ],
      "GET /project" => [ 200, [ { "id" => "p1", "slug" => "tinkerex" } ] ]
    })

    run_log("deploy", "--image", "abc123", env: { "KANEO_TOKEN" => "t0ken", "KANEO_URL" => stub.url })

    posts = stub.requests.select { |r| r.method == "POST" && r.path.include?("/task/") }
    assert_equal 1, posts.size, "expected one task POST from deploy"
    assert_equal "done", posts.first.json["status"],
                 "a deploy record arrived open — nothing ever closes one, so it would sit there forever"
  ensure
    stub&.shutdown
  end

  # A FILE WITH NO HEADING IS REFUSED, not imported under a guessed title. 112 sections import
  # unattended; one silently titled "" is one nobody finds again.
  test "arc --from-file refuses a file with no leading heading" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "bad.md")
      File.write(path, "no heading here\n")

      _out, err, code = run_log("arc", "--from-file", path, env: { "KANEO_TOKEN" => "t0ken" })

      assert_equal 2, code
      assert_includes err, "no leading heading"
    end
  end

  # --- the transport, and the number that is not an address ------------------------------------

  # THE TWO THINGS EVERY REQUEST MUST CARRY, ASSERTED ACROSS ALL OF THEM RATHER THAN THE LAST ONE.
  # A `show` is now three wire calls — the workspace, the project, then the board — and a header set
  # on the first but dropped on a later one is exactly the shape a single-request assertion misses.
  test "every request carries a Bearer token and reaches the /api prefix" do
    stub = StubKaneo.new(routes: {
      "GET /auth/organization/list" => [ 200, [ { "id" => "w1", "slug" => "tinkerex" } ] ],
      "GET /project" => [ 200, [ { "id" => "p1", "slug" => "tinkerex" } ] ],
      "GET /task/tasks" => [ 200, { "data" => { "columns" => [
        { "slug" => "to-do", "tasks" => [ { "id" => "t1", "number" => 7, "title" => "x", "status" => "to-do" } ] }
      ] }, "pagination" => { "totalPages" => 1 } } ]
    })
    _out, err, code = run_log("show", "7", env: { "KANEO_URL" => stub.url, "KANEO_TOKEN" => "secret-key" })

    assert_equal 0, code, err
    refute_empty stub.requests, "nothing reached the wire, so this guard asserted nothing"
    stub.requests.each do |request|
      assert_equal "Bearer secret-key", request.headers["authorization"]
      assert request.path.start_with?("/api/"), "#{request.path} is not under /api"
    end
  ensure
    stub&.shutdown
  end

  # THE WORKSPACE IS RESOLVED BEFORE THE PROJECT, AND THE ORDER IS FORCED BY THE SERVER: GET
  # /api/project answers 400 without a workspaceId, so the project list cannot be the thing that
  # tells you the workspace. Reversing the two reads as a harmless refactor and is a hard 400.
  test "the workspace is resolved first, and the project list is asked with its id" do
    stub = StubKaneo.new(routes: {
      "GET /auth/organization/list" => [ 200, [ { "id" => "w1", "slug" => "other" },
                                                { "id" => "w2", "slug" => "tinkerex" } ] ],
      "GET /project" => [ 200, [ { "id" => "p9", "slug" => "tinkerex" } ] ],
      "GET /task/tasks" => [ 200, { "data" => { "columns" => [
        { "slug" => "to-do", "tasks" => [ { "id" => "t1", "number" => 7, "title" => "x", "status" => "to-do" } ] }
      ] }, "pagination" => { "totalPages" => 1 } } ]
    })
    _out, err, code = run_log("show", "7", env: { "KANEO_URL" => stub.url, "KANEO_TOKEN" => "k" })

    assert_equal 0, code, err
    paths = stub.requests.map(&:path)
    assert_equal "/api/auth/organization/list", paths.first,
                 "the workspace must be resolved before anything asks for a project"
    assert_includes paths[1], "workspaceId=w2",
                    "the project list was asked without the workspace id, or with the wrong slug's"
    assert_includes paths[2], "/api/task/tasks/p9",
                    "the board was fetched for something other than the resolved project"
  ensure
    stub&.shutdown
  end

  # KANEO ADDRESSES A TASK BY AN OPAQUE id; the citable `number` is not addressable at all, so every
  # verb naming an issue has to walk the board first. The record this replaced needed nothing like
  # this: its own path took the number.
  test "a number resolves to the task id before any addressed call is made" do
    stub = StubKaneo.new(routes: {
      "GET /auth/organization/list" => [ 200, [ { "id" => "w1", "slug" => "tinkerex" } ] ],
      "GET /project" => [ 200, [ { "id" => "p1", "slug" => "tinkerex" } ] ],
      "GET /task/tasks" => [ 200, { "data" => { "columns" => [
        { "slug" => "done", "tasks" => [ { "id" => "abc", "number" => 178, "title" => "Staging panel", "status" => "done" } ] }
      ] }, "pagination" => { "totalPages" => 1 } } ]
    })
    out, err, code = run_log("show", "178", env: { "KANEO_URL" => stub.url, "KANEO_TOKEN" => "k" })

    assert_equal 0, code, err
    assert_match(/#178 Staging panel/, out)
  ensure
    stub&.shutdown
  end

  test "a number that no task carries is a clear refusal, not a crash" do
    stub = StubKaneo.new(routes: {
      "GET /auth/organization/list" => [ 200, [ { "id" => "w1", "slug" => "tinkerex" } ] ],
      "GET /project" => [ 200, [ { "id" => "p1", "slug" => "tinkerex" } ] ],
      "GET /task/tasks" => [ 200, { "data" => { "columns" => [] }, "pagination" => { "totalPages" => 1 } } ]
    })
    _out, err, code = run_log("show", "999", env: { "KANEO_URL" => stub.url, "KANEO_TOKEN" => "k" })

    assert_equal 3, code
    assert_match(/no issue #999/, err)
  ensure
    stub&.shutdown
  end

  # THE TWO OFF-BOARD BUCKETS ARE NOT DECORATION, AND WITHOUT THIS FIXTURE THE GUARD IS VACUOUS.
  # `archivedTasks` and `plannedTasks` sit BESIDE `columns` in the board envelope and appear in no
  # column, so a resolver that walks only the columns answers "no issue #N" for a record that is
  # present and intact. Measured 2026-08-31: both keys come back at the top level of `data`.
  # Deleting those two lines from task_index goes green against a fixture whose tasks all sit in
  # columns — §14e's rule that a guard must be shown to scan a NON-EMPTY set, in miniature.
  test "a task in an off-board bucket resolves like any other" do
    stub = StubKaneo.new(routes: {
      "GET /auth/organization/list" => [ 200, [ { "id" => "w1", "slug" => "tinkerex" } ] ],
      "GET /project" => [ 200, [ { "id" => "p1", "slug" => "tinkerex" } ] ],
      "GET /task/tasks" => [ 200, { "data" => {
        "columns" => [ { "slug" => "to-do", "tasks" => [] } ],
        "archivedTasks" => [ { "id" => "arch", "number" => 41, "title" => "Retired scan guard", "status" => "archived" } ],
        "plannedTasks" => [ { "id" => "plan", "number" => 42, "title" => "Selective sync", "status" => "planned" } ]
      }, "pagination" => { "totalPages" => 1 } } ]
    })
    env = { "KANEO_URL" => stub.url, "KANEO_TOKEN" => "k" }

    archived, err, code = run_log("show", "41", env: env)
    assert_equal 0, code, err
    assert_match(/#41 Retired scan guard/, archived, "an archived task is off-board, not absent")

    planned, err, code = run_log("show", "42", env: env)
    assert_equal 0, code, err
    assert_match(/#42 Selective sync/, planned, "a planned task is off-board, not absent")
  ensure
    stub&.shutdown
  end

  # THE LIMIT IS CAPPED SERVER-SIDE, SO ONE PAGE IS A WELL-FORMED LIE. A request for limit=200 came
  # back with pageSize 100 (measured), and the record holds 193 tasks — so a resolver that trusts
  # the first page cannot see roughly half of them, and reports "no issue #N" for every one. The
  # answer is not a bigger limit; it is reading `pagination.totalPages` and walking.
  test "the task index walks every page rather than trusting the first" do
    page = lambda do |task, total|
      [ 200, { "data" => { "columns" => [ { "slug" => "to-do", "tasks" => [ task ] } ] },
               "pagination" => { "totalPages" => total } } ]
    end
    stub = StubKaneo.new(routes: {
      "GET /auth/organization/list" => [ 200, [ { "id" => "w1", "slug" => "tinkerex" } ] ],
      "GET /project" => [ 200, [ { "id" => "p1", "slug" => "tinkerex" } ] ],
      "GET /task/tasks" => [
        page.call({ "id" => "a", "number" => 1, "title" => "first page", "status" => "to-do" }, 2),
        page.call({ "id" => "b", "number" => 193, "title" => "second page", "status" => "to-do" }, 2)
      ]
    })
    out, err, code = run_log("show", "193", env: { "KANEO_URL" => stub.url, "KANEO_TOKEN" => "k" })

    assert_equal 0, code, err
    assert_match(/#193 second page/, out, "the walk stopped at page 1 — half the record is invisible")

    pages = stub.requests.map(&:path).select { |p| p.include?("/task/tasks") }
    assert_equal 2, pages.size, "expected one request per page, got #{pages.inspect}"
    assert_includes pages[1], "page=2"
  ensure
    stub&.shutdown
  end

  # --- close -----------------------------------------------------------------------------------

  # CLOSING IS A COLUMN MOVE, NOT A STATE CHANGE. Kaneo has no open/closed flag — the board column
  # IS the state — so this is PUT /task/status/:id carrying the `done` slug, addressed by the
  # opaque id the number resolved to. Two things ride on one call here: the write, and the
  # already-closed report that keeps a redundant write from reading as "I closed it" for something
  # somebody else closed for a different reason.
  test "close moves the task to Done and reports an already-closed one instead of re-sending" do
    stub = StubKaneo.new(routes: {
      "GET /auth/organization/list" => [ 200, [ { "id" => "w1", "slug" => "tinkerex" } ] ],
      "GET /project" => [ 200, [ { "id" => "p1", "slug" => "tinkerex" } ] ],
      "GET /task/tasks" => [ 200, { "data" => { "columns" => [
        { "slug" => "to-do", "tasks" => [ { "id" => "a", "number" => 10, "title" => "open one", "status" => "to-do" } ] },
        { "slug" => "done",  "tasks" => [ { "id" => "b", "number" => 11, "title" => "done one", "status" => "done" } ] }
      ] }, "pagination" => { "totalPages" => 1 } } ],
      "PUT /task/status" => [ 200, { "id" => "a", "status" => "done" } ]
    })
    out, err, code = run_log("close", "10", "11", env: { "KANEO_URL" => stub.url, "KANEO_TOKEN" => "k" })

    assert_equal 0, code, err
    puts_sent = stub.requests.select { |r| r.method == "PUT" }
    assert_equal 1, puts_sent.size, "only the open one should be written"
    assert_equal "/api/task/status/a", puts_sent.first.path
    assert_equal "done", puts_sent.first.json["status"]

    # NOTHING ELSE MAY RIDE ALONG. A status write that carried a title or a description would
    # rewrite the record, and corrections are kept as COMMENTS precisely so it never is (§15).
    refute puts_sent.first.json.key?("description"),
           "close sent a description — it is rewriting the task, not moving it"
    refute puts_sent.first.json.key?("title"),
           "close sent a title — it is rewriting the task, not moving it"

    assert_match(/closed #10/, out)
    assert_match(/#11 was already closed/, out)
  ensure
    stub&.shutdown
  end

  # SEVERAL NUMBERS, EACH ITS OWN REQUEST. The unit of work is "this branch is done", which
  # routinely resolves an arc plus the issues it answers; a failure part way through leaves the
  # earlier ones closed and says which, rather than pretending the batch was atomic.
  test "close takes several issues and closes each one" do
    stub = StubKaneo.new(routes: {
      "GET /auth/organization/list" => [ 200, [ { "id" => "w1", "slug" => "tinkerex" } ] ],
      "GET /project" => [ 200, [ { "id" => "p1", "slug" => "tinkerex" } ] ],
      "GET /task/tasks" => [ 200, { "data" => { "columns" => [ { "slug" => "to-do", "tasks" => [
        { "id" => "fk", "number" => 152, "title" => "FKs", "status" => "to-do" },
        { "id" => "im", "number" => 153, "title" => "Item vs Model", "status" => "to-do" }
      ] } ] }, "pagination" => { "totalPages" => 1 } } ],
      "PUT /task/status" => [ 200, { "status" => "done" } ]
    })

    _out, err, code = run_log("close", "152", "153", env: {
      "KANEO_TOKEN" => "t0ken", "KANEO_URL" => stub.url,
      "KANEO_WORKSPACE" => "tinkerex", "KANEO_PROJECT" => "tinkerex"
    })

    assert_equal 0, code, "bin/log close failed: #{err}"
    written = stub.requests.select { |r| r.method == "PUT" }.map(&:path)
    assert_equal [ "/api/task/status/fk", "/api/task/status/im" ], written

    # ONE BOARD FETCH FOR THE PAIR, NOT ONE PER NUMBER. The index is memoized for the process
    # precisely because closing several issues is the ordinary case, and the board is ~193 tasks.
    boards = stub.requests.count { |r| r.path.include?("/task/tasks") }
    assert_equal 1, boards, "the board was re-fetched per number: #{boards} times"
  ensure
    stub&.shutdown
  end

  test "close rejects a non-numeric issue and sends nothing" do
    stub = StubKaneo.new

    _out, err, code = run_log("close", "../../etc/passwd", env: {
      "KANEO_TOKEN" => "t0ken", "KANEO_URL" => stub.url,
      "KANEO_WORKSPACE" => "tinkerex", "KANEO_PROJECT" => "tinkerex"
    })

    assert_equal 2, code, "expected a usage error, got #{code}"
    assert_match(/not an issue number/, err)
    assert_empty stub.requests, "close sent a request for a rejected issue number"
  ensure
    stub&.shutdown
  end

  test "close with no arguments is a usage error" do
    _out, err, code = run_log("close")

    assert_equal 2, code
    assert_match(/close needs at least one issue number/, err)
  end

  # AN OUTAGE IS EXIT 3, AND FOR close IT SPOOLS NOTHING — WHICH IS TRUE OF THE OLD RECORD TOO,
  # despite what this test used to be called. Both versions resolve the issue BEFORE writing, so an
  # unreachable server fails on that read, and the read sits OUTSIDE close's `filing` phase. The
  # number is not lost by it: what asked for the close is the branch, which is still there. The
  # default KANEO_URL in run_log points at a dead port, which is the outage.
  #
  # THE EMPTY SPOOL IS ASSERTED, NOT ASSUMED. Moving the read inside the phase reads like tidying,
  # and it would make `close 99` — a number no task carries — spool a record nobody can file.
  test "close during an outage exits 3 rather than reporting a close that never happened" do
    _out, err, code = run_log("close", "152", env: { "KANEO_TOKEN" => "t0ken" })

    assert_equal 3, code, "expected EXIT_UNREACHABLE, got #{code}: #{err}"
    refute_match(/closed #152/, err, "an unreachable close claimed to have closed something")
    assert_empty Dir.glob(File.join(@spool, "*.md")), "close spooled a record for a READ that failed"
  end

  # --- unfiled records -------------------------------------------------------------------------
  #
  # EVERY WRITE NAMES ITS OWN UNFILED RECORD, THROUGH ONE HELPER. bin/log's `filing(what, payload)`
  # wraps each write phase and puts the record on the Unreachable passing through it; `main` spools
  # that record, or nothing when no phase was open. These tests pin what each record SAYS, because
  # the record is all a human has to refile from — nothing replays the spool (CLAUDE.md §13).

  RESOLVED = {
    "GET /auth/organization/list" => [ 200, [ { "id" => "w1", "slug" => "tinkerex" } ] ],
    "GET /project" => [ 200, [ { "id" => "p1", "slug" => "tinkerex" } ] ]
  }.freeze

  def board(*tasks)
    [ 200, { "data" => { "columns" => [ { "slug" => "to-do", "tasks" => tasks } ] },
             "pagination" => { "totalPages" => 1 } } ]
  end

  # Asserts the file exists first, so a write that spooled nothing fails with a message rather than
  # erroring on ENOENT.
  def spooled_record(branch = "claude/example")
    path = File.join(@spool, "#{branch.tr('/', '-')}.md")
    assert File.exist?(path), "nothing was spooled for #{branch} — the write is simply lost"
    File.read(path)
  end

  # THE DEFECT THE HELPER EXISTS FOR. close had no record of its own: a PUT failing after a good
  # board read spooled `{"status": "done"}` under the PUT's path, an opaque task id, with no issue
  # number in the entry or in the message. Nobody could refile it.
  test "a close whose write fails spools a record naming the issue" do
    stub = StubKaneo.new(routes: RESOLVED.merge(
      "GET /task/tasks" => board({ "id" => "a", "number" => 10, "title" => "open one", "status" => "to-do" }),
      "PUT /task/status" => [ 502, { "message" => "bad gateway" } ]
    ))

    out, err, code = run_log("close", "10", env: {
      "KANEO_URL" => stub.url, "KANEO_TOKEN" => "k", "LOG_BRANCH" => "claude/example"
    })

    assert_equal 3, code, "a failed close must spool and exit 3: #{err}"
    refute_match(/closed #10/, out, "a close that was never filed reported success")
    spooled = spooled_record
    assert_match(/^# unfiled: close .*#10\b/, spooled,
                 "the record names no issue — a bare {\"status\": \"done\"} cannot be refiled")
    assert_includes spooled, '"status": "done"'
    assert_match(/#10\b/, err, "the message must say which close was not filed")
  ensure
    stub&.shutdown
  end

  # A CLOSE THAT FAILS PART WAY NAMES EVERY ISSUE IT DID NOT CLOSE, not only the one whose write
  # failed: the ones after it were never attempted, and a record naming one of three is refiled as
  # one of three, leaving the rest open with nothing anywhere saying so. The one that WAS closed is
  # left out — its close is filed.
  test "a close that fails part way names every issue it did not close" do
    stub = StubKaneo.new(routes: RESOLVED.merge(
      "GET /task/tasks" => board({ "id" => "a", "number" => 10, "title" => "first", "status" => "to-do" },
                                 { "id" => "b", "number" => 11, "title" => "second", "status" => "to-do" },
                                 { "id" => "c", "number" => 12, "title" => "third", "status" => "to-do" }),
      "PUT /task/status" => [ [ 200, { "status" => "done" } ], [ 502, { "message" => "bad gateway" } ] ]
    ))

    out, err, code = run_log("close", "10", "11", "12", env: {
      "KANEO_URL" => stub.url, "KANEO_TOKEN" => "k", "LOG_BRANCH" => "claude/example"
    })

    assert_equal 3, code, err
    assert_match(/closed #10/, out)
    header = spooled_record[/^# unfiled: .*$/].to_s
    assert_match(/#11\b/, header, "the issue whose write failed is not in the record")
    assert_match(/#12\b/, header, "an issue never attempted after the failure is not in the record")
    refute_match(/#10\b/, header, "#10 WAS closed; naming it misstates what is unfiled")
  ensure
    stub&.shutdown
  end

  # A 502 ANSWERS EVERY CALL, SO THE FIRST TO FAIL IS THE WORKSPACE LOOKUP. note's issue resolution
  # sits inside its phase, which is what lets an outage spool the comment at all; the record must
  # carry the issue and the text, and must not name the lookup that failed — the endpoint line this
  # replaced filed this very comment under /api/auth/organization/list.
  test "a note filed against a 502 spools its issue and its text, not the request that failed" do
    stub = StubKaneo.new(status: 502, response: { "message" => "bad gateway" })

    _out, err, code = run_log("note", "128", "The measured figure was 7.8 ms.", env: {
      "KANEO_URL" => stub.url, "KANEO_TOKEN" => "k", "LOG_BRANCH" => "claude/example"
    })

    assert_equal 3, code, err
    spooled = spooled_record
    assert_match(/^# unfiled: note .*#128\b/, spooled, "the comment's issue is not in the record")
    assert_includes spooled, '"content": "The measured figure was 7.8 ms."'
    refute_includes spooled, "/api/", "the record names a wire path instead of what is unfiled"
  ensure
    stub&.shutdown
  end

  # setup's writes are its definition POSTs. The vocabulary read before them is outside every phase:
  # until it answers, nothing is known to be missing, so there is nothing to record. Re-running
  # setup refiles the rest, because it asks what exists.
  test "a setup whose definition POST fails spools the label it was defining" do
    stub = StubKaneo.new(routes: {
      "GET /auth/organization/list" => [ 200, [ { "id" => "w1", "slug" => "tinkerex" } ] ],
      "GET /label/workspace" => [ 200, LABEL_FIXTURE.reject { |l| l["name"] == "ci" } ],
      "POST /label" => [ 502, { "message" => "bad gateway" } ]
    })

    _out, err, code = run_log("setup", env: {
      "KANEO_URL" => stub.url, "KANEO_TOKEN" => "k", "LOG_BRANCH" => "claude/example"
    })

    assert_equal 3, code, err
    spooled = spooled_record
    assert_match(/^# unfiled: setup .*"ci"/, spooled, "the record does not say which label it was defining")
    assert_includes spooled, '"name": "ci"'
    refute_includes spooled, '"taskId"', "a definition carries no taskId; one that does is an attachment"
  ensure
    stub&.shutdown
  end

  # THE FUNNEL. The verbs come from bin/log's own --help, which is derived from SUBCOMMANDS, so a
  # verb added there arrives here unclassified and this fails until it is listed as one that never
  # writes or given a failing run whose record is checked. A new write verb that forgets `filing`
  # then fails here, rather than answering "nothing to file" to the first outage that hits it.
  #
  # WHAT EACH RECORD MUST CARRY is what a human needs to refile it through the one door: the title
  # and body of a create, the PR link of an arc, the image and destination of a deploy, the issue and
  # text of a note, the issue of a close, the label of a definition. And no wire path — that names
  # the request that FAILED, not the work that is unfiled.
  NEVER_WRITES = %w[show search status].freeze

  test "every write verb's spooled record carries what a human needs to refile it" do
    Dir.mktmpdir do |dir|
      gh = File.join(dir, "gh")
      File.write(gh, <<~SH)
        #!/bin/sh
        echo '{"title":"Fix the tombstone cascade","body":"Applied per node.","url":"https://github.com/chaim354/tinkerex/pull/261"}'
      SH
      File.chmod(0o755, gh)

      # verb => [ argv, routes (nil: the dead default port), what the record must name ]
      cases = {
        "open"   => [ [ "open", "Refile me", "with this body" ], nil, [ "Refile me", "with this body" ] ],
        "arc"    => [ [ "arc", "--from-pr", "261" ], nil,
                      [ "Fix the tombstone cascade", "github.com/chaim354/tinkerex/pull/261" ] ],
        "deploy" => [ [ "deploy", "--image", "abc1234", "--dest", "share" ], nil, [ "Deploy abc1234", "- share" ] ],
        "note"   => [ [ "note", "128", "a correction" ], nil, [ "#128", "a correction" ] ],
        "close"  => [ [ "close", "10" ],
                      RESOLVED.merge("GET /task/tasks" => board({ "id" => "a", "number" => 10, "status" => "to-do" }),
                                     "PUT /task/status" => [ 502, { "message" => "down" } ]),
                      [ "#10" ] ],
        "setup"  => [ [ "setup" ],
                      { "GET /auth/organization/list" => RESOLVED["GET /auth/organization/list"],
                        "GET /label/workspace" => [ 200, LABEL_FIXTURE.reject { |l| l["name"] == "ci" } ],
                        "POST /label" => [ 502, { "message" => "down" } ] },
                      [ '"ci"' ] ]
      }

      verbs = run_log("--help").first.scan(/^\s+bin\/log ([a-z]+)/).flatten
      assert_operator verbs.size, :>, NEVER_WRITES.size, "parsed no verbs out of --help, so this is vacuous"
      assert_equal (verbs - NEVER_WRITES).sort, cases.keys.sort,
                   "every verb bin/log lists must be classified here: as one that never writes, or with a failing run"

      cases.each do |verb, (argv, routes, names)|
        stub = routes && StubKaneo.new(routes: routes)
        env = { "KANEO_TOKEN" => "k", "GH_BIN" => gh, "LOG_BRANCH" => "funnel/#{verb}" }
        env["KANEO_URL"] = stub.url if stub

        _out, err, code = run_log(*argv, env: env)

        assert_equal 3, code, "#{verb}: expected a spooled write, exit 3: #{err}"
        spooled = spooled_record("funnel/#{verb}")
        assert_match(/^# unfiled: #{verb} /, spooled, "#{verb}: the record does not say which command it was")
        names.each { |name| assert_includes spooled, name, "#{verb}: cannot be refiled without #{name.inspect}" }
        refute_includes spooled, "/api/", "#{verb}: the record names a wire path instead of what is unfiled"
      ensure
        stub&.shutdown
      end
    end
  end
end
