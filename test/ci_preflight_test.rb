require "test_helper"

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

  test "an unset CI_RUNNERS declares macos ONLY — never everything" do
    # The most important test in the file. A default of "assume everything is available" reproduces
    # the original bug exactly: jobs scheduled against runners that do not exist. The conservative
    # default is what makes a forgotten variable safe.
    out, status = preflight(nil)
    assert_equal 0, status, out
    assert_equal "macos=true\nlinux=false\nwindows=false\n", out
  end

  test "an empty or whitespace CI_RUNNERS falls back to the same conservative default" do
    [ "", "   " ].each do |value|
      out, status = preflight(value)
      assert_equal 0, status, out
      assert_equal "macos=true\nlinux=false\nwindows=false\n", out,
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

  test "--summary names the absent families and says the run is green about less" do
    out, status = preflight("macos", "--summary")
    assert_equal 0, status, out
    assert_match(/CI runner preflight/, out)
    assert_match(/`macos` \| ✅/, out)
    assert_match(/`linux` \| ⛔/, out)
    assert_match(/`windows` \| ⛔/, out)
    # The declared value is echoed so a STALE declaration is visible at the point of damage.
    assert_match(/CI_RUNNERS.*`macos`/, out)
    assert_match(/skipped, not passed/i, out)
  end

  test "--summary says so plainly when nothing was skipped" do
    out, _ = preflight("macos,linux,windows", "--summary")
    assert_match(/no coverage skipped/i, out)
    refute_match(/⛔/, out)
  end

  private

    # Passing nil UNSETS CI_RUNNERS rather than setting it to empty. Those are different inputs and
    # the first two tests assert both, so IO.popen's env hash is the right instrument here — a
    # `ENV[...] = nil` in setup would leak into the parent process.
    def preflight(ci_runners, *args)
      out = IO.popen({ "CI_RUNNERS" => ci_runners }, [ SCRIPT, *args ],
                     err: [ :child, :out ], &:read)
      [ out, $?.exitstatus ]
    end
end
