# What THIS deployment's library backend can do, for the two callers that must not lie about it:
# the views (which hide what the backend cannot do) and the v1 API (which answers 501 instead of
# pretending).
#
# THE 501 IS A CAPABILITY CHECK BEFORE THE CALL, NEVER A RESCUE, and the reasoning has to live
# here or someone will "add a backstop rescue NotImplementedError":
#
#   1. NotImplementedError is a ScriptError, NOT a StandardError. A controller's `rescue => e`
#      does not catch it and ActiveJob's retry_on/discard_on do not either, so a rescue-based
#      gate does not merely have a gap: it silently does not work, failing to exactly the 500
#      that spec §6 says not to produce.
#   2. It would be factually wrong. `Chunk#write` raising does not mean the deployment cannot
#      accept uploads -- chunk mode accepts uploads all day, through Sync::Commit's two-phase
#      flow. It means the CALLER USED THE WRONG DOOR. 501 would answer a true-sounding lie and
#      send the caller away instead of fixing the bug.
#   3. A controller rescue catches NotImplementedError from ANYWHERE below it -- FileLayer.build
#      (an s3 MISCONFIGURATION) and ChunkStore's abstract methods raise it too. Dressing a
#      boot-level misconfiguration as "this deployment can't do that" launders it into a
#      routine-looking response.
#
# So NotImplementedError stays un-rescued, and that is a feature: it is a programming error, it
# should be loud, and it should reach the error tracker. Every 501 below is instead a request for
# a capability the deployment TRULY LACKS -- and none of them involves NotImplementedError at all,
# because the v1 sync controllers never touch FileLayer.
module LibraryCapabilities
  extend ActiveSupport::Concern

  # What a deployment WITHOUT each capability cannot do, in the operator's terms. One sentence per
  # capability rather than one shared refusal: the FileLayer::Chunk header records what a single
  # shared message cost last time -- it told `delete` and `move` callers to use Sync::Commit, which
  # has neither path.
  #
  # ASCII on purpose: these are API response bodies, not comments.
  CAPABILITY_ABSENT = {
    versioned: "this deployment keeps no file history. A share- or s3-backed library is " \
               "current-state only (spec §2 decision 4), so there is nothing to list or restore.",
    syncable: "this deployment has no sync engine. A share- or s3-backed library has no " \
              "changelog, no chunks, and no devices syncing it (spec §3.3).",
    port_writable: "this deployment does not take file bytes through the server."
  }.freeze

  included do
    # ONE named mechanism for what this deployment can do, reachable from the views.
    #
    # A METHOD RATHER THAN AN IVAR, DELIBERATELY, AND THE REASON IS THAT .erb HAS NO TYPE CHECKER.
    # `<% if @caps&.versioned %>` on a nil @caps is silently FALSY -- the feature just vanishes
    # from the page and nothing anywhere goes red. `<% if capabilities.versioned? %>` raises
    # NameError if the helper is missing and NoMethodError if the predicate is misspelled. Both
    # are loud, at render, in a test. Prefer the form that raises: a capability gate that fails
    # open is a bug you find in production; one that fails closed is a feature you never notice
    # left.
    helper_method :capabilities
  end

  class_methods do
    # Gate an action on a capability this deployment may not have. Renders 501 + { error: } --
    # V1::BaseController's shape, matched rather than reinvented, because a second response idiom
    # in the same API is a divergence.
    #
    # `hint` names the door that DOES work, where one exists. That is not politeness: the whole
    # failure mode `port_writable` exists to prevent is a caller reading "no" as "uploads are
    # off" when the real answer is "uploads go the other way".
    def require_capability!(capability, hint: nil, **options)
      explanation = CAPABILITY_ABSENT.fetch(capability)
      before_action(**options) do
        unless capabilities.public_send(:"#{capability}?")
          render json: { error: [ "#{capability}_unavailable:", explanation, hint ].compact.join(" ") },
                 status: :not_implemented
        end
      end
    end
  end

  private

  def capabilities = FileLayer.current.capabilities
end
