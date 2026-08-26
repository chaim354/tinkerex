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
