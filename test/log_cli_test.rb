require "test_helper"
require "open3"     # capture3 — required explicitly, not inherited from whatever Rails happens to load
require "tmpdir"    # Task 4's fake `gh`
require "fileutils" # Task 5's spool assertions

# Guards bin/log — the SINGLE write door onto the Forgejo that replaces docs/STATUS.md.
#
# WHY A TEST FILE FOR A bin/ SCRIPT. bin/log is the only thing that records an arc, so a silent
# failure here loses the record with nothing going red — this repo's dominant failure shape
# (CLAUDE.md §15, "a green suite over something that never worked"). Every assertion below is
# mutation-checked in Task 8.
#
# THESE TESTS NEVER REACH forgejo.home. They point FORGEJO_URL at a stub on localhost and assert
# the WIRE FORMAT — the exact path, headers and JSON body sent. §14e records why: FakeS3 decoded
# with CGI.unescape while the adapter encoded with CGI.escape, exact inverses, so 79/80 tests were
# green over silent permanent data loss. A fake that shares the code's misunderstanding confirms
# it. Assert what goes on the wire, not that a round-trip returns what we put in.
class LogCliTest < ActiveSupport::TestCase
  BIN_LOG = Rails.root.join("bin/log").to_s

  # Runs bin/log with stdout and stderr kept SEPARATE. Merging them is not a convenience here —
  # it is the exact shape that printed a live ghcr PAT into a transcript on 2026-07-29 (see
  # bin/secret's header). Task 2 asserts the token never reaches fd2, which is unprovable if the
  # harness itself merges the streams.
  def run_log(*args, env: {})
    out, err, status = Open3.capture3(env, BIN_LOG, *args, chdir: Rails.root.to_s)
    [ out, err, status.exitstatus ]
  end

  test "bin/log with no arguments prints usage naming every subcommand and exits 2" do
    out, err, code = run_log

    assert_equal 2, code, "no-args must be a usage error, not a success"

    usage = out + err
    %w[arc open deploy note show search status setup].each do |subcommand|
      assert_includes usage, subcommand,
                      "usage does not mention `#{subcommand}` — a door nobody is told about is a door nobody uses"
    end
  end
end
