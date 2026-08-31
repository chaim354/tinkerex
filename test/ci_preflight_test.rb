require "test_helper"
require "tmpdir"

# ci/preflight.sh is what stops a job being SCHEDULED against a runner family that does not exist.
# That matters because a job whose labels match no online runner does not fail — it queues for 24h
# and is then auto-cancelled, at 0 elapsed, with mergeStateStatus stuck at UNSTABLE. That is how CI
# stayed dark from 2026-06-24 to 2026-07-29 without ever going red.
#
# The logic lives in a SCRIPT rather than inline in the workflow for one reason: inline YAML bash
# cannot be tested, and this decides whether coverage runs at all. Asserted by running the script
# and reading its OUTPUT — the interface the workflow consumes.
class CiPreflightTest < ActiveSupport::TestCase
  SCRIPT = Rails.root.join("ci/preflight.sh").to_s

  test "an unset CI_RUNNERS declares linux ONLY — never everything" do
    # The most important test in the file. A default of "assume everything is available" reproduces
    # the original bug exactly: jobs scheduled against runners that do not exist. The conservative
    # default is what makes a forgotten variable safe. It names LINUX because that is where this
    # repo's runners are (2026-08-31); the property under test is "one family, not all three".
    out, status = preflight(nil)
    assert_equal 0, status, out
    assert_equal "macos=false\nlinux=true\nwindows=false\n", out
  end

  test "an empty or whitespace CI_RUNNERS falls back to the same conservative default" do
    [ "", "   " ].each do |value|
      out, status = preflight(value)
      assert_equal 0, status, out
      assert_equal "macos=false\nlinux=true\nwindows=false\n", out,
                   "CI_RUNNERS=#{value.inspect} must behave as unset"
    end
  end

  test "a declared family is reported available" do
    out, status = preflight("macos,linux")
    assert_equal 0, status, out
    assert_equal "macos=true\nlinux=true\nwindows=false\n", out
  end

  test "the declaration tolerates whitespace and case" do
    out, _ = preflight(" macOS , LINUX ")
    assert_equal "macos=true\nlinux=true\nwindows=false\n", out
  end

  test "a family name is matched whole, not as a substring" do
    # Without the comma-delimiting, a declared "linux-arm64" would satisfy a "linux" lookup and
    # schedule x86 FUSE jobs onto an arm box.
    out, _ = preflight("macos,linux-arm64")
    assert_equal "macos=true\nlinux=false\nwindows=false\n", out
  end

  # THE SUMMARY HAS THREE STATES, NOT TWO, AND THE THIRD IS WHY THESE TESTS PLANT A WORKFLOW.
  #
  # Until 2026-08-25 a family was either declared-available or "absent — its jobs were SKIPPED".
  # Then the cross-repo suites left (docs/superpowers/specs/2026-08-25-cross-repo-ci-handoff.md)
  # and this repo stopped having any linux or windows job at all, so the second state started
  # warning about SKIPPED JOBS THAT DO NOT EXIST. The script now derives a third state by grepping
  # `runs-on` across the workflow dir.
  #
  # Consequence for THIS file: the "absent" branch is no longer reachable from this repo's own
  # workflows, so a test asserting it must ESTABLISH ITS PRECONDITION rather than assume it. That
  # is what CI_WORKFLOW_DIR is for. A test that simply dropped the ⛔ assertions would be green
  # over a branch nothing exercises — §15's dominant failure shape, and the very branch that
  # protects against five weeks of dark CI.

  test "--summary warns that a targeted family's jobs were SKIPPED when its runner is absent" do
    # Precondition, established rather than assumed: a workflow with a linux job.
    # Both families present: macos registered, linux not. Omitting the macos job would make macos
    # report `—` too, and the test would fail for the wrong reason (it did, first time).
    fixture = "jobs:\n  a:\n    runs-on: [self-hosted, macos]\n  b:\n    runs-on: [self-hosted, linux]\n"
    out, status = with_workflows("jobs.yml" => fixture) do
      preflight("macos", "--summary")
    end
    assert_equal 0, status, out
    assert_match(/CI runner preflight/, out)
    assert_match(/`macos` \| ✅/, out)
    assert_match(/`linux` \| ⛔/, out)
    # The declared value is echoed so a STALE declaration is visible at the point of damage.
    assert_match(/CI_RUNNERS.*`macos`/, out)
    assert_match(/skipped, not passed/i, out)
  end

  test "--summary does NOT claim skipped coverage for a family no job targets" do
    # The state this repo is actually in. The old wording said "absent — its jobs were SKIPPED"
    # about jobs that do not exist, which reads as a coverage gap where there is none to close.
    out, status = with_workflows("mac-job.yml" => "jobs:\n  x:\n    runs-on: [self-hosted, macos]\n") do
      preflight("macos", "--summary")
    end
    assert_equal 0, status, out
    assert_match(/`macos` \| ✅/, out)
    assert_match(/`linux` \| — no job in this repo targets it/, out)
    assert_match(/`windows` \| — no job in this repo targets it/, out)
    refute_match(/skipped, not passed/i, out)
    # But it must not read as a clean bill of health either.
    assert_match(/NOT a passing row/, out)
  end

  test "--summary says so plainly when every targeted family is available" do
    out, _ = with_workflows("all.yml" => "jobs:\n  a:\n    runs-on: [self-hosted, linux]\n  b:\n    runs-on: [self-hosted, windows]\n") do
      preflight("macos,linux,windows", "--summary")
    end
    assert_match(/no coverage skipped/i, out)
    refute_match(/⛔/, out)
  end

  test "the real workflow dir targets linux, and the summary tracks whether linux is declared" do
    # THE PREMISE FLIPPED ON 2026-08-31, EXACTLY AS THIS TEST PREDICTED IT MIGHT. It used to read
    # "the real workflow dir has no linux or windows job", and its own comment said that if a linux
    # job ever returned, this would go red and CLAUDE.md §12.6's wording would need revisiting —
    # "the conversation worth having, rather than a summary quietly warning again". CI moved to four
    # Linux container runners on the Unraid box (ops/ci-runner-stack.yml), every job here is `linux`,
    # and §12.6 was rewritten in the same change.
    #
    # ASSERTED IN BOTH DIRECTIONS NOW, which the single-direction original could not do. With linux
    # declared there must be no warning; with it UNDECLARED there must be one — and that second half
    # is what keeps the ⛔ branch reachable for the REAL workflow dir rather than only for the
    # planted fixtures above. Without it this would pass just as well over a script that had stopped
    # warning at all.
    available, _ = preflight("linux", "--summary")
    refute_match(/⛔/, available,
                 "linux is declared and every job in this repo targets it, so nothing is skipped")
    assert_match(/`macos` \| — no job in this repo targets it/, available)
    assert_match(/`windows` \| — no job in this repo targets it/, available)

    absent, _ = preflight("macos", "--summary")
    assert_match(/`linux` \| ⛔/, absent,
                 "with linux undeclared, the summary must still report this repo's jobs as skipped")
  end

  private

    # Passing nil UNSETS CI_RUNNERS rather than setting it to empty. Those are different inputs and
    # the first two tests assert both, so IO.popen's env hash is the right instrument here — a
    # `ENV[...] = nil` in setup would leak into the parent process.
    def preflight(ci_runners, *args)
      env = { "CI_RUNNERS" => ci_runners }
      env["CI_WORKFLOW_DIR"] = @workflow_dir if @workflow_dir
      out = IO.popen(env, [ SCRIPT, *args ], err: [ :child, :out ], &:read)
      [ out, $?.exitstatus ]
    end

    # Runs the block against a THROWAWAY workflow dir holding exactly the given files.
    #
    # Deliberately NOT the real .github/workflows/: a probe file dropped there would fail
    # ci_hygiene_test (an ungated linux job is precisely what that file forbids) and would race
    # between parallel test workers, which fork and share the tree.
    def with_workflows(files)
      Dir.mktmpdir do |dir|
        files.each { |name, body| File.write(File.join(dir, name), body) }
        @workflow_dir = dir
        begin
          yield
        ensure
          @workflow_dir = nil
        end
      end
    end
end
