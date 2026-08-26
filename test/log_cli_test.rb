require "test_helper"
require "open3"
require "tmpdir"
require "fileutils"
require "support/stub_forgejo"

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
        "PATH" => "#{dir}:#{ENV['PATH']}", "LANG" => nil, "LC_ALL" => nil, "FORGEJO_TOKEN" => nil
      })

      assert_equal 3, code, "a locale-less credential failure did not reach the clean unreachable exit"
      refute_includes err, "Encoding::CompatibilityError",
                      "the encoding crash is back — bin/log must set default_external"
      refute_includes err, "in 'Log.token'", "a stack trace reached the user"
    end
  end

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
    real = Rails.root.join("tmp/log-pending")
    before = Dir.glob(real.join("*.md")).size

    _out, _err, code = run_log("open", "must not reach the real spool", env: { "FORGEJO_TOKEN" => "t0ken" })

    assert_equal 3, code
    assert_equal before, Dir.glob(real.join("*.md")).size,
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

  # THE 422 PATH IS THE ONLY ONE THAT RUNS AFTER THE FIRST TIME, and a stub answering 201 never
  # reaches it. Without this test `allow: [422]` — the entire idempotency claim — is asserted
  # nowhere, and a setup that silently stopped being idempotent would fail for the first time
  # months later, in front of whoever added a label.
  test "setup tolerates 422, the ordinary case on every run after the first" do
    stub = StubForgejo.new(status: 422, response: { "message" => "label already exists" })

    _out, err, code = run_log("setup", env: {
      "FORGEJO_TOKEN" => "t0ken", "FORGEJO_URL" => stub.url
    })

    assert_equal 0, code, "setup treated an already-existing label as a failure: #{err}"
    assert_operator stub.requests.size, :>=, 3,
                    "setup stopped at the first 422 instead of continuing through the list"
  ensure
    stub&.shutdown
  end
end
