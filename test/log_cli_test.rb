require "test_helper"
require "open3"
require "tmpdir"
require "fileutils"
require "support/stub_forgejo"

# Guards bin/log — the SINGLE write door onto the Forgejo that replaced STATUS.md.
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

  # WHAT THE LIVE INSTANCE ACTUALLY RETURNS. Issue-create takes int64 label IDs and REFUSES names
  # (measured: 422 "cannot unmarshal string into ... type int64"), so every wire assertion below is
  # written against ids. The earlier tests asserted names and passed, because the stub records what
  # we send and validates nothing — a contract invented rather than observed.
  LABEL_NAMES = %w[arc open-work deploy blocked deliberate
                   filelayer library-scan addons previews maker-web ci].freeze
  LABEL_FIXTURE = LABEL_NAMES.each_with_index.map { |n, i| { "id" => i + 1, "name" => n } }.freeze

  # The seven names bin/sync-server's unset_inherited_bundler_env already clears. §14j: a bundled
  # parent exports these process-wide and every child inherits them, so a harness that MERGES its
  # own environment runs bin/log as a bundled child every time — exercising "needs no gem" only in
  # the direction that cannot fail. Deliberately NOT PATH/GEM_HOME/GEM_PATH, which is how the shell
  # finds ruby at all.
  BUNDLER_ENV = %w[BUNDLE_GEMFILE BUNDLE_BIN_PATH BUNDLE_LOCKFILE BUNDLER_VERSION
                   BUNDLER_SETUP RUBYOPT RUBYLIB].freeze

  # LOG_SPOOL_DIR DEFAULTS TO A THROWAWAY, so reaching the developer's REAL spool is opt-in — the
  # same shape as FORGEJO_URL defaulting to an unroutable address. Two write-verb tests were
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
    base = cleared.merge("FORGEJO_URL" => "http://127.0.0.1:1", "LOG_SPOOL_DIR" => @spool)

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
        "PATH" => "#{dir}:#{ENV['PATH']}", "FORGEJO_TOKEN" => nil,
        "LANG" => nil, "LC_ALL" => nil, "LC_CTYPE" => nil
      })

      assert_equal 3, code, "a locale-less credential failure did not reach the clean unreachable exit"
      refute_includes err, "Encoding::CompatibilityError",
                      "the encoding crash is back — bin/log must set default_external"
      refute_includes err, "in 'Log.token'", "a stack trace reached the user"
    end
  end

  # THE CATCH-ALL AND EXIT_BUG, DRIVEN BY A REAL TRIGGER RATHER THAN A TEST HOOK. Forgejo answers
  # an error as a JSON OBJECT where a list was expected, and `issues.each { |i| i["number"] }` then
  # indexes an Array with a String — TypeError. Nothing else in the suite reaches main's
  # `rescue StandardError`, so before this both its existence and its EXIT_BUG return were asserted
  # nowhere: the mutation sweep found removing the catch-all, and changing its return code, BOTH
  # green.
  test "an unexpected error is EXIT_BUG and says plainly that nothing was spooled" do
    stub = StubForgejo.new(status: 200, response: { "message" => "repository not found" })

    _out, err, code = run_log("search", "anything", env: {
      "FORGEJO_TOKEN" => "t0ken", "FORGEJO_URL" => stub.url
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
  test "open POSTs the documented issue payload to the documented path" do
    stub = StubForgejo.new(routes: { "GET /labels" => [ 200, LABEL_FIXTURE ] })

    # THE TRAILING NEWLINE IS DELIBERATE, NOT A TYPO. `bin/secret` returns an EXPORTED override
    # verbatim (`printf '%s'`, no stripping — only the 1Password path is `--no-newline`), so this
    # is exactly what a value like `export FORGEJO_TOKEN=$(pass show ...)` can hand `token` when
    # the source appends one. Without `.chomp` this reaches the header as "token t0ken\n" — Ruby's
    # own Net::HTTP raises `ArgumentError: header field value cannot include CR/LF` for that, so a
    # dropped `.chomp` doesn't corrupt the request, it crashes it outright.
    out, err, code = run_log("open", "The scan tombstones a live node", env: {
      "FORGEJO_TOKEN" => "t0ken\n", "FORGEJO_URL" => stub.url,
      "FORGEJO_OWNER" => "chaim354", "FORGEJO_REPO" => "tinkerex"
    })

    assert_equal 0, code, "bin/log open failed: #{err}"
    assert_includes out, "#42"

    # The GET resolves names to ids; the POST carries the ids. Both halves are the real contract.
    assert_equal %w[GET POST], stub.requests.map(&:method)
    assert_includes stub.requests.first.path, "/labels"

    request = stub.requests.last
    assert_equal "POST", request.method
    assert_equal "/api/v1/repos/chaim354/tinkerex/issues", request.path
    assert_equal "token t0ken", request.headers["authorization"],
                "a trailing newline on the exported token reached the Authorization header uncleaned"
    assert_equal "application/json", request.headers["content-type"]

    assert_equal "The scan tombstones a live node", request.json["title"]
    assert_equal [ 2 ], request.json["labels"],
                 "labels must be int64 ids — Forgejo answers 422 for names (measured, live)"
  ensure
    stub&.shutdown
  end

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

  # THE TEST ABOVE ONLY DRIVES A READ (`show`). `create_issue` goes through `parse` too, but
  # nothing exercised that on a WRITE — so a revert of `create_issue` back to a bare `JSON.parse`
  # would raise an unwrapped `JSON::ParserError` on exactly this response and stay invisible: the
  # read-side guard cannot see a write-side regression. Unwrapped, that error is neither
  # `Unreachable` nor spooled, and used to exit 1 outright.
  test "a write receiving a non-JSON 2xx is unreachable and spools" do
    stub = StubForgejo.new(status: 200, response: "<html>proxy</html>")

    Dir.mktmpdir do |spool|
      _out, err, code = run_log("open", "filed through a broken proxy", env: {
        "FORGEJO_TOKEN" => "t0ken", "FORGEJO_URL" => stub.url,
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
    stub = StubForgejo.new(routes: { "GET /labels" => [ 200, LABEL_FIXTURE ] })

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
      request = stub.requests.find { |r| r.method == "POST" }

      assert_equal "Fix the tombstone cascade", request.json["title"]
      assert_includes request.json["body"], "The delete was applied per-node.",
                      "the PR body was not carried into the arc issue"
      assert_includes request.json["body"], "https://github.com/chaim354/tinkerex/pull/261",
                      "the arc must link the PR it describes, or the diff is unreachable from the record"
      assert_equal [ 1 ], request.json["labels"], "labels must be int64 ids, not names"
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
        "FORGEJO_TOKEN" => "t0ken", "LOG_SPOOL_DIR" => File.join(blocked, "spool"),
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
        "FORGEJO_TOKEN" => "t0ken", "LOG_SPOOL_DIR" => spool
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

    _out, _err, code = run_log("open", "must not reach the real spool", env: { "FORGEJO_TOKEN" => "t0ken" })

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
  # IDEMPOTENCY IS ASKING WHAT EXISTS, NOT TOLERATING A REFUSAL. Forgejo ALLOWS DUPLICATE LABEL
  # NAMES — measured against the live instance: a second `setup` run created a second copy of all
  # eleven and reported "11 labels present" both times, leaving 22. The test this replaces asserted
  # a 422 the server never sends, and passed because the stub answered 422 because the test said to.
  test "setup creates nothing when every label already exists" do
    stub = StubForgejo.new(routes: { "GET /labels" => [ 200, LABEL_FIXTURE ] })

    out, err, code = run_log("setup", env: {
      "FORGEJO_TOKEN" => "t0ken", "FORGEJO_URL" => stub.url,
      "FORGEJO_OWNER" => "chaim354", "FORGEJO_REPO" => "tinkerex"
    })

    assert_equal 0, code, "bin/log setup failed: #{err}"
    assert_empty stub.requests.select { |r| r.method == "POST" },
                 "setup POSTed a label that already existed — Forgejo creates a DUPLICATE, silently"
    assert_includes out, "0 created"
  ensure
    stub&.shutdown
  end

  # AND IT VERIFIES RATHER THAN ASSUMING ITS POSTs WORKED. "I sent eleven requests" is not the claim
  # this command makes; "eleven labels exist" is. The first GET lacks `ci`; the second, after the
  # POST, has it.
  test "setup creates only what is missing, then confirms the whole set" do
    partial = LABEL_FIXTURE.reject { |l| l["name"] == "ci" }
    stub = StubForgejo.new(routes: {
      "GET /labels" => [ [ 200, partial ], [ 200, LABEL_FIXTURE ] ],
      "POST /labels" => [ 201, { "id" => 11, "name" => "ci" } ]
    })

    out, err, code = run_log("setup", env: { "FORGEJO_TOKEN" => "t0ken", "FORGEJO_URL" => stub.url })

    assert_equal 0, code, "bin/log setup failed: #{err}"
    assert_equal [ "ci" ], stub.requests.select { |r| r.method == "POST" }.map { |r| r.json["name"] },
                 "setup POSTed a label that already existed"
    assert_includes out, "1 created"
  ensure
    stub&.shutdown
  end

  # A WRITE'S FIRST WIRE CALL IS NOW A READ (the label resolve), and that must not turn a write into
  # a no-record. Regression the moment id resolution landed: the payload was built in one expression
  # whose own label lookup raised, leaving it nil, so the rescue reported "nothing to file" for an
  # unambiguous write.
  test "a write whose label lookup fails still spools what it was going to send" do
    Dir.mktmpdir do |spool|
      _out, err, code = run_log("open", "must survive a failed label resolve", env: {
        "FORGEJO_TOKEN" => "t0ken", "LOG_SPOOL_DIR" => spool, "LOG_BRANCH" => "claude/example"
      })

      assert_equal 3, code
      refute_includes err, "nothing to file", "a write was reported as having nothing to spool"
      assert_includes File.read(File.join(spool, "claude-example.md")),
                      "must survive a failed label resolve"
    end
  end

  # AN EM DASH IN A TITLE, UNDER A LOCALE-LESS SHELL, ARRIVES AS ASCII-8BIT. Measured:
  # ARGV[0].encoding is ASCII-8BIT for "smoke test — safe" with LANG unset, and JSON.generate warns
  # today and RAISES in json 3.0. This repo's titles use em dashes constantly, so it is not an edge
  # case — and none of the thirty mutations found it. The live smoke test did, on its first run.
  test "a non-ASCII title survives a locale-less environment" do
    stub = StubForgejo.new(routes: { "GET /labels" => [ 200, LABEL_FIXTURE ] })

    _out, err, code = run_log("open", "an arc — with an em dash", env: {
      "FORGEJO_TOKEN" => "t0ken", "FORGEJO_URL" => stub.url,
      "LANG" => nil, "LC_ALL" => nil, "LC_CTYPE" => nil
    })

    assert_equal 0, code, "bin/log open failed: #{err}"
    refute_includes err, "BINARY", "JSON.generate warned — json 3.0 raises on this"
    assert_equal "an arc — with an em dash",
                 stub.requests.find { |r| r.method == "POST" }.json["title"]
  ensure
    stub&.shutdown
  end

  # A LABEL THE REPO DOES NOT HAVE NAMES ITSELF AND SAYS WHAT TO RUN, rather than surfacing Forgejo's
  # "cannot unmarshal string into ... int64", which describes our bug and not the user's.
  test "a missing label names itself and points at setup" do
    stub = StubForgejo.new(routes: {
      "GET /labels" => [ 200, LABEL_FIXTURE.reject { |l| l["name"] == "open-work" } ]
    })

    _out, err, code = run_log("open", "x", env: { "FORGEJO_TOKEN" => "t0ken", "FORGEJO_URL" => stub.url })

    assert_equal 3, code
    assert_includes err, "open-work"
    assert_includes err, "bin/log setup"
  ensure
    stub&.shutdown
  end

  test "deploy --dest share files a record naming only share, not the other two backends" do
    stub = StubForgejo.new(routes: { "GET /labels" => [ 200, LABEL_FIXTURE ] })

    _out, err, code = run_log("deploy", "--image", "e079d433", "--dest", "share", env: {
      "FORGEJO_TOKEN" => "t0ken", "FORGEJO_URL" => stub.url,
      "FORGEJO_OWNER" => "chaim354", "FORGEJO_REPO" => "tinkerex"
    })

    assert_equal 0, code, "bin/log deploy failed: #{err}"
    request = stub.requests.find { |r| r.method == "POST" }

    assert_equal [ 3 ], request.json["labels"], "labels must be int64 ids, not names"
    assert_includes request.json["title"], "e079d433"
    assert_includes request.json["body"], "share"
    refute_includes request.json["body"], "chunk_remote",
                    "--dest share still filed chunk_remote — --dest is being ignored"
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
                              env: { "FORGEJO_TOKEN" => "t0ken" })

    assert_equal 2, code, "a typo'd flag filed a record instead of being refused"
    assert_includes err, "unrecognised argument"
  end

  test "deploy --dest with no value is a usage error, not a crash" do
    _out, _err, code = run_log("deploy", "--image", "abc123", "--dest",
                               env: { "FORGEJO_TOKEN" => "t0ken" })

    assert_equal 2, code
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
    request = stub.requests.find { |r| r.method == "POST" }

    assert_equal "POST", request.method
    assert_equal "/api/v1/repos/chaim354/tinkerex/issues/128/comments", request.path
    assert_equal "The measured figure was 7.8 ms, not 5.", request.json["body"]
    refute request.json.key?("title"), "note sent a title — it is editing the issue, not commenting"
  ensure
    stub&.shutdown
  end

  # `note` IS THE ONLY VERB WHOSE TARGET LIVES IN THE URL RATHER THAN THE PAYLOAD. Spooling only
  # the payload during an outage left the text with no way to say which issue it corrects — a
  # correction spooled and later replayed by hand is unrecoverable without the issue number.
  test "a note spooled during an outage records which issue it belongs to" do
    Dir.mktmpdir do |spool|
      run_log("note", "128", "The measured figure was 7.8 ms.", env: {
        "FORGEJO_TOKEN" => "t0ken", "LOG_SPOOL_DIR" => spool, "LOG_BRANCH" => "claude/example"
      })

      spooled = File.read(File.join(spool, "claude-example.md"))
      assert_includes spooled, "128",
                      "the issue number is only in the URL, so without it the correction is orphaned"
    end
  end

  # REJECT, NEVER NORMALIZE — CLAUDE.md §14a's `key_for` rule, same repo, different subsystem.
  # Net::HTTP does not normalise a `..` segment, so it reaches the wire verbatim and a normalising
  # reverse proxy in front of Forgejo can resolve it outside the repo scope.
  test "an issue number containing path traversal is refused before it reaches the wire" do
    _out, err, code = run_log("show", "../../../../admin/users", env: { "FORGEJO_TOKEN" => "t0ken" })

    assert_equal 2, code, "a traversal segment was sent to the server"
    assert_includes err, "not an issue number"
  end

  # SEARCH SPANS OPEN AND CLOSED. An arc issue is CLOSED the moment its PR merges, so a search
  # defaulting to Forgejo's state=open would find no finished work at all — which is most of the
  # record.
  #
  # THE QUERY MUST BE PERCENT-ENCODED, NOT JUST PRESENT. "chunk_remote" has nothing in it that
  # needs encoding, so a search query built by straight interpolation instead of
  # `URI.encode_www_form_component` passed that query unnoticed. `&` and `#` are both wire-active
  # characters — a bare `&` starts a new query param and a bare `#` starts a fragment — so a query
  # containing either breaks the request unless encoded.
  test "search asks for both states and percent-encodes the query" do
    stub = StubForgejo.new(status: 200, response: [])

    _out, err, code = run_log("search", "502 & the proxy #2", env: {
      "FORGEJO_TOKEN" => "t0ken", "FORGEJO_URL" => stub.url,
      "FORGEJO_OWNER" => "chaim354", "FORGEJO_REPO" => "tinkerex"
    })

    assert_equal 0, code, "bin/log search failed: #{err}"
    request = stub.requests.first

    assert_equal "GET", request.method
    assert_includes request.path, "/api/v1/repos/chaim354/tinkerex/issues"
    assert_includes request.path, "state=all",
                    "search defaulted to open issues, which excludes every finished arc"
    assert_includes request.path, "%26", "the query's & must be percent-encoded, not sent bare"
    assert_includes request.path, "%23", "the query's # must be percent-encoded, not sent bare"
    refute_includes request.path, "& the proxy #2",
                    "the raw query reached the path unencoded"
  ensure
    stub&.shutdown
  end

  # A SCHEME-LESS FORGEJO_URL parses to host=nil, and Net::HTTP.start(nil, nil) then reports
  # "connection refused for nil port 80" — a confident, wrong answer to a malformed env var.
  test "a FORGEJO_URL with no scheme is a usage error, not a phantom connection refusal" do
    _out, err, code = run_log("show", "1", env: {
      "FORGEJO_TOKEN" => "t0ken", "FORGEJO_URL" => "forgejo.home"
    })

    assert_equal 2, code, "a malformed FORGEJO_URL was reported as a network failure"
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
        "FORGEJO_TOKEN" => "t0ken", "GH_BIN" => gh
      })

      assert_equal 3, code, "a non-JSON gh reply did not become a clean unreachable exit"
      assert_includes err, "gh returned non-JSON"
      assert_includes err, "261"
    end
  end

  # HISTORICAL ARCS ARRIVE ALREADY FINISHED, so they must be created CLOSED. Probed against the
  # live instance: CreateIssueOption accepts `closed: true` and returns state "closed".
  test "arc --from-file imports a section, closed, with its first heading as the title" do
    stub = StubForgejo.new(routes: { "GET /labels" => [ 200, LABEL_FIXTURE ] })

    Dir.mktmpdir do |dir|
      path = File.join(dir, "entry.md")
      File.write(path, "## 2026-07-29: the audit-fix arc\n\nTwo security gates ran zero.\n")

      _out, err, code = run_log("arc", "--from-file", path, "--closed", env: {
        "FORGEJO_TOKEN" => "t0ken", "FORGEJO_URL" => stub.url,
        "FORGEJO_OWNER" => "chaim354", "FORGEJO_REPO" => "tinkerex"
      })

      assert_equal 0, code, "import failed: #{err}"
      post = stub.requests.find { |r| r.method == "POST" }

      assert_equal "2026-07-29: the audit-fix arc", post.json["title"],
                   "the leading '## ' must be stripped, or every title starts with markup"
      assert_includes post.json["body"], "Two security gates ran zero."
      assert_equal true, post.json["closed"], "a finished arc must not import as open work"
      assert_equal [ 1 ], post.json["labels"]
    end
  ensure
    stub&.shutdown
  end

  # WITHOUT --closed IT STAYS OPEN. The same verb serves a live arc (opened at PR time, closed at
  # merge) and a historical import, so the default must be the live case — an import that forgets
  # the flag leaves a visible open issue, while the reverse silently closes live work.
  test "arc --from-file without --closed does not send closed" do
    stub = StubForgejo.new(routes: { "GET /labels" => [ 200, LABEL_FIXTURE ] })

    Dir.mktmpdir do |dir|
      path = File.join(dir, "entry.md")
      File.write(path, "## live arc\n\nbody\n")
      run_log("arc", "--from-file", path, env: { "FORGEJO_TOKEN" => "t0ken", "FORGEJO_URL" => stub.url })

      post = stub.requests.find { |r| r.method == "POST" }
      refute post.json.key?("closed"), "an import default of closed would silently close live work"
    end
  ensure
    stub&.shutdown
  end

  # `closed:` DEFAULTS TO FALSE, AND ONLY open/deploy EXERCISE THAT DEFAULT. `arc` always passes an
  # explicit boolean, so Ruby's keyword default is dead code from its call site — which means the
  # mutation "default closed: to true" stayed GREEN when it was run. Observed, not predicted. This
  # is the test that makes the default real: an ordinary open item or deploy record must never
  # arrive already closed.
  test "open and deploy never send closed" do
    stub = StubForgejo.new(routes: { "GET /labels" => [ 200, LABEL_FIXTURE ] })

    run_log("open", "an ordinary item", env: { "FORGEJO_TOKEN" => "t0ken", "FORGEJO_URL" => stub.url })
    run_log("deploy", "--image", "abc123", env: { "FORGEJO_TOKEN" => "t0ken", "FORGEJO_URL" => stub.url })

    posts = stub.requests.select { |r| r.method == "POST" }
    assert_equal 2, posts.size, "expected one POST each from open and deploy"
    posts.each do |post|
      refute post.json.key?("closed"),
             "#{post.json['title'].inspect} arrived already closed — it is live work, not history"
    end
  ensure
    stub&.shutdown
  end

  # A FILE WITH NO HEADING IS REFUSED, not imported under a guessed title. 112 sections import
  # unattended; one silently titled "" is one nobody finds again.
  test "arc --from-file refuses a file with no leading heading" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "bad.md")
      File.write(path, "no heading here\n")

      _out, err, code = run_log("arc", "--from-file", path, env: { "FORGEJO_TOKEN" => "t0ken" })

      assert_equal 2, code
      assert_includes err, "no leading heading"
    end
  end

  # --- close -----------------------------------------------------------------------------------

  test "close PATCHes state closed, and reads the issue first so it can tell you it was open" do
    stub = StubForgejo.new(routes: {
      "GET /issues/152" => [ 200, { "number" => 152, "title" => "Database foreign keys", "state" => "open" } ],
      "PATCH /issues/152" => [ 200, { "number" => 152, "state" => "closed" } ]
    })

    out, err, code = run_log("close", "152", env: {
      "FORGEJO_TOKEN" => "t0ken", "FORGEJO_URL" => stub.url,
      "FORGEJO_OWNER" => "chaim354", "FORGEJO_REPO" => "tinkerex"
    })

    assert_equal 0, code, "bin/log close failed: #{err}"
    patch = stub.requests.find { |r| r.method == "PATCH" }
    assert patch, "close never sent a PATCH — requests: #{stub.requests.map(&:method).inspect}"
    assert_equal "/api/v1/repos/chaim354/tinkerex/issues/152", patch.path
    assert_equal "closed", patch.json["state"]

    # THE BODY MUST NOT RIDE ALONG. Forgejo's edit endpoint takes title/body on the same verb, so a
    # close that sent either would silently rewrite the issue — and this record keeps corrections
    # as COMMENTS precisely so a body is never edited (§15).
    refute patch.json.key?("body"), "close sent a body — it is rewriting the issue, not closing it"
    refute patch.json.key?("title"), "close sent a title — it is rewriting the issue, not closing it"
    assert_match(/closed #152/, out)
  ensure
    stub&.shutdown
  end

  test "close reports an already-closed issue instead of sending a redundant write" do
    stub = StubForgejo.new(routes: {
      "GET /issues/99" => [ 200, { "number" => 99, "title" => "Done ages ago", "state" => "closed" } ]
    })

    out, err, code = run_log("close", "99", env: {
      "FORGEJO_TOKEN" => "t0ken", "FORGEJO_URL" => stub.url,
      "FORGEJO_OWNER" => "chaim354", "FORGEJO_REPO" => "tinkerex"
    })

    assert_equal 0, code, "bin/log close failed: #{err}"
    assert_match(/#99 was already closed/, out)
    assert_nil stub.requests.find { |r| r.method == "PATCH" },
      "close re-sent a write for an issue that was already closed"
  ensure
    stub&.shutdown
  end

  test "close takes several issues and closes each one" do
    stub = StubForgejo.new(routes: {
      "GET /issues/152" => [ 200, { "number" => 152, "title" => "FKs", "state" => "open" } ],
      "GET /issues/153" => [ 200, { "number" => 153, "title" => "Item vs Model", "state" => "open" } ],
      "PATCH /issues/152" => [ 200, { "number" => 152, "state" => "closed" } ],
      "PATCH /issues/153" => [ 200, { "number" => 153, "state" => "closed" } ]
    })

    _out, err, code = run_log("close", "152", "153", env: {
      "FORGEJO_TOKEN" => "t0ken", "FORGEJO_URL" => stub.url,
      "FORGEJO_OWNER" => "chaim354", "FORGEJO_REPO" => "tinkerex"
    })

    assert_equal 0, code, "bin/log close failed: #{err}"
    patched = stub.requests.select { |r| r.method == "PATCH" }.map(&:path)
    assert_equal [ "/api/v1/repos/chaim354/tinkerex/issues/152",
                   "/api/v1/repos/chaim354/tinkerex/issues/153" ], patched
  ensure
    stub&.shutdown
  end

  test "close rejects a non-numeric issue and sends nothing" do
    stub = StubForgejo.new

    _out, err, code = run_log("close", "../../etc/passwd", env: {
      "FORGEJO_TOKEN" => "t0ken", "FORGEJO_URL" => stub.url,
      "FORGEJO_OWNER" => "chaim354", "FORGEJO_REPO" => "tinkerex"
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

  # A CLOSE IS A WRITE, SO AN OUTAGE MUST SPOOL IT LIKE ANY OTHER. The default FORGEJO_URL in
  # run_log points at a dead port, which is the outage.
  test "close spools when Forgejo is unreachable, naming the issue it belongs to" do
    _out, err, code = run_log("close", "152", env: { "FORGEJO_TOKEN" => "t0ken" })

    assert_equal 3, code, "expected EXIT_UNREACHABLE, got #{code}: #{err}"
  end
end
