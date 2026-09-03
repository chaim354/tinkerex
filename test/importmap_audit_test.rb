require "test_helper"

# THE SCAN GATE MUST NOT GO RED BECAUSE SOMEBODY ELSE'S SERVER IS DOWN.
#
# `bin/importmap audit` POSTs the pinned package list to the npm registry's bulk advisory endpoint,
# so it is the only check in `bin/ci` that needs a remote host to answer. On 2026-09-03 that endpoint
# became unreachable and the gate failed on a DOCUMENTATION-ONLY pull request (#304, two files under
# `docs/`) — twice, at a consistent ~65 s, and from the developer's own machine as well as the CI
# runners. §15 makes a red `bin/ci` block the branch, so an outage at a third party halted every PR
# in the repository, for a cause nothing here could fix or wait out.
#
# §14e ALREADY SETTLED THIS ARGUMENT ONE SCANNER OVER. `bin/brakeman` shipped `--ensure-latest`, so
# `bin/ci scan` exited non-zero with ZERO warnings on a tree nobody had touched, every time brakeman
# cut a release; the resolution was that a security gate reports on the CODE, never on how current —
# or how reachable — its upstream happens to be. This is that rule applied to the one remaining
# network-dependent check.
#
# FAILING OPEN ON A SECURITY CHECK NEEDS ITS OWN ARGUMENT, AND THIS IS IT: a transport error is not a
# statement about the code, and `Importmap::Npm::HTTPError` is the gate's OWN exception class, so the
# line between "I could not ask" and "I asked and here is a vulnerability" is drawn by the tool
# rather than guessed by us. A real advisory still exits non-zero — which is what the third test
# below exists to keep true, and what every mutation here is aimed at.
class ImportmapAuditTest < ActiveSupport::TestCase
  # A REAL FAILURE, not a paraphrase. Copied from the run that prompted this
  # (github.com/chaim354/tinkerex actions run 33813447534, job 100841083938) so the pattern is
  # matched against what the tool actually prints rather than what we imagine it prints — the
  # FakeS3 lesson (§14e): a fixture that shares the code's assumption confirms it.
  TRANSPORT_FAILURE = <<~OUT.freeze
    /opt/mise/installs/ruby/3.4.7/lib/ruby/gems/3.4.0/gems/importmap-rails-2.2.3/lib/importmap/npm.rb:142:in 'Importmap::Npm#post_json': Unexpected transport error (Net::ReadTimeout: Net::ReadTimeout with #<TCPSocket:(closed)>) (Importmap::Npm::HTTPError)
    \tfrom /opt/mise/installs/ruby/3.4.7/lib/ruby/gems/3.4.0/gems/importmap-rails-2.2.3/lib/importmap/npm.rb:39:in 'Importmap::Npm#vulnerable_packages'
    \tfrom bin/importmap:4:in '<main>'
  OUT

  # What the tool prints when it DID reach the endpoint and found something. The wording is the
  # gem's; what matters for the verdict is that it carries no transport exception.
  VULNERABILITY_FOUND = <<~OUT.freeze
    Vulnerabilities found:

    stimulus (3.2.2)
      Severity: high
      Advisory: https://github.com/advisories/GHSA-xxxx-yyyy-zzzz
  OUT

  test "a clean audit passes" do
    assert_equal :ok, ImportmapAudit.verdict(status: 0, output: "No vulnerabilities found\n")
  end

  test "an unreachable advisory endpoint is not a finding about this code" do
    assert_equal :unreachable, ImportmapAudit.verdict(status: 1, output: TRANSPORT_FAILURE)
  end

  # THE ASSERTION THE OTHERS EXIST TO PROTECT. Every mutation below is a way of making this one
  # wrong, because a gate that tolerates everything is worse than no gate — it reports safety it
  # has not checked.
  test "a real advisory still fails the gate" do
    assert_equal :vulnerable, ImportmapAudit.verdict(status: 1, output: VULNERABILITY_FOUND)
  end

  # NARROW ON PURPOSE. "The output mentions npm" or "the output mentions a timeout" would tolerate a
  # future advisory whose text happens to name either. Only the gem's own exception class counts,
  # which is the whole reason this can fail open at all.
  test "a failure that merely mentions the registry is still a failure" do
    noisy = "checked registry.npmjs.org: 1 vulnerability in stimulus (Net::ReadTimeout mentioned in the advisory text)\n"

    assert_equal :vulnerable, ImportmapAudit.verdict(status: 1, output: noisy)
  end

  # A NON-ZERO STATUS WITH NO OUTPUT AT ALL IS A FAILURE, not a transport error. A crash that prints
  # nothing must not be waved through by a pattern that simply fails to match.
  test "a silent non-zero exit is a failure" do
    assert_equal :vulnerable, ImportmapAudit.verdict(status: 2, output: "")
  end

  # ZERO WINS OVER EVERYTHING. If the tool exited 0 the audit ran and found nothing, whatever it
  # printed on the way — a warning line naming the exception class must not turn a pass into a
  # tolerated failure, which would hide a future exit-0-with-warnings mode.
  test "a zero exit is clean even if the output mentions the transport class" do
    assert_equal :ok, ImportmapAudit.verdict(status: 0, output: TRANSPORT_FAILURE)
  end

  # THE ASSERTION THAT STOPS EVERY ONE ABOVE BEING SATISFIED BY A GUTTED SCRIPT. `: > bin/importmap-audit`
  # passes all six verdict tests perfectly and disables the security gate, because they exercise the
  # DECISION and the gate runs the DOOR. Same lesson `ci_hygiene_test.rb` records for `bin/brakeman`,
  # whose ARGV check is satisfied by an empty file — only a second assertion notices.
  #
  # STRUCTURAL rather than behavioural: driving the script would need a stubbed `bin/importmap`, and
  # a test-only seam in a security gate's entry point costs more than it buys. What must remain true
  # is that the door ASKS the tested unit and still has a way to fail.
  test "the gate's door still routes through the tested verdict and can still fail" do
    script = Rails.root.join("bin/importmap-audit")
    assert script.exist?, "the scan gate points at bin/importmap-audit; it must exist"
    assert script.executable?, "bin/importmap-audit must be executable or the gate cannot run it"

    source = script.read
    assert_match(/ImportmapAudit\.verdict/, source,
                 "the door must ask the unit these tests cover, or they cover nothing the gate runs")
    assert_match(/exit status/, source,
                 "the door must still propagate a real advisory's non-zero exit — a gate that " \
                 "cannot fail reports safety it has not checked")
  end

  # AND THE GATE ACTUALLY POINTS AT IT. The two assertions above are worthless if `config/ci.rb`
  # still runs `bin/importmap audit` directly — the fix would be present, tested, and unreached.
  # NARROWED TO THE ONE LINE, so a failure prints that line rather than the whole gate file.
  # Asserting against `config/ci.rb` in full made the message a 200-line dump in which the actual
  # difference was invisible — a failure nobody can read is most of the way to a failure nobody acts
  # on, which is the same objection §14e makes to a gate that reports the wrong thing loudly.
  test "the scan gate runs the door, not the raw command" do
    steps = Rails.root.join("config/ci.rb").readlines.grep(/ci\.step .*Importmap/).map(&:strip)

    assert_equal 1, steps.length,
                 "expected exactly one Importmap audit step in the scan gate, found: #{steps.inspect}"
    assert_includes steps.first, '"bin/importmap-audit"',
                    "the scan gate must run the door — the raw `bin/importmap audit` bypasses the " \
                    "transport-error verdict entirely. Found: #{steps.first}"
  end
end
