# The `scan` gate's verdict on `bin/importmap audit`, separated from RUNNING it so it can be tested.
#
# WHY THIS EXISTS. `bin/importmap audit` POSTs the pinned package list to the npm registry's bulk
# advisory endpoint, which makes it the only check in `bin/ci` that needs a remote host to answer.
# On 2026-09-03 that endpoint went unreachable and the gate failed on a documentation-only pull
# request — twice, at a consistent ~65 s, and from the developer's machine as well as the CI runners.
# §15 makes a red `bin/ci` block the branch, so somebody else's outage halted every PR here for a
# cause nothing in this repository could fix, retry around, or wait out.
#
# §14e SETTLED THE SAME ARGUMENT ONE SCANNER OVER: `bin/brakeman`'s `--ensure-latest` made the gate
# exit non-zero with ZERO warnings on an untouched tree every time brakeman cut a release, and the
# resolution was that a security gate reports on the CODE, never on how current — or how reachable —
# its upstream is. Gem freshness went to Dependabot, off the critical path. This is that rule applied
# to the one network-dependent check that remained.
#
# FAILING OPEN ON A SECURITY CHECK NEEDS ITS OWN ARGUMENT, so here it is, and it is deliberately
# narrow: a transport error is not a statement about the code, and `Importmap::Npm::HTTPError` is the
# gem's OWN exception class — the line between "I could not ask" and "I asked, and here is a
# vulnerability" is drawn by the tool rather than guessed by us. Anything else that exits non-zero
# still fails, including a silent crash.
#
# WHAT THIS DOES NOT DO: it does not make the audit optional. An unreachable run is reported loudly
# on stderr by `bin/importmap-audit` and the gate continues; it is not silence. If the endpoint is
# down for a week that is worth knowing, and `.github/dependabot.yml` (weekly) is what actually
# notices a new advisory in the meantime — the same division of labour brakeman ended up with.
module ImportmapAudit
  # The gem's own class, matched by name because that is what reaches us — the audit runs in a
  # subprocess, so the exception object does not. Narrow on purpose: "the output mentions npm" or
  # "the output mentions a timeout" would tolerate a future advisory whose TEXT happens to contain
  # either, which is precisely the failure this must not have.
  TRANSPORT_ERROR = /Importmap::Npm::HTTPError/

  # :ok | :unreachable | :vulnerable
  #
  # A ZERO STATUS WINS OVER EVERYTHING, including output naming the transport class: if the tool
  # exited 0 the audit ran, whatever it printed on the way. Reading the pattern first would turn a
  # future exit-0-with-warnings mode into a tolerated failure.
  def self.verdict(status:, output:)
    return :ok if status.to_i.zero?
    return :unreachable if output.to_s.match?(TRANSPORT_ERROR)

    :vulnerable
  end
end
