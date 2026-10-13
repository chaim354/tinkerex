module Maker
  module Addons
    # WHERE A DECLARED SIDECAR LIVES ON *THIS* DEPLOYMENT — one definition, because there are now
    # two callers asking the same question for different reasons.
    #
    # THE MANIFEST-VS-ENV SPLIT (spec §4.1) IS THE WHOLE POINT AND IT STAYS WHERE IT WAS. A manifest
    # says WHICH services an addon speaks to; only the host's own environment says WHERE any of them
    # is. A manifest-supplied URL would be an SSRF primitive aimed at the internal network, so the
    # name is all an addon may contribute — and that is why the lookup below takes a NAME and builds
    # the env key itself rather than accepting anything URL-shaped from a manifest.
    #
    # WHY THIS IS ITS OWN MODULE RATHER THAN A METHOD ON EITHER CALLER. The two callers ask at
    # opposite ends of the request: `Addon#unavailable_reason` asks BEFORE anything is rendered, to
    # decide whether the gallery card is clickable; `Tools::AddonsController#sidecar_url_for` asks
    # mid-request, to route one proxied call. Putting the derivation in either one makes the other
    # reach across a layer or — far likelier — spell `"#{name.upcase}_SIDECAR_URL"` a second time.
    # A guard that exists at one call site and silently does not at another is this repo's recorded
    # failure shape (CLAUDE.md §14c), and an env-var NAME is exactly the kind of string that drifts
    # silently: get it wrong and the lookup simply returns nil, which reads as "not deployed".
    #
    # NOT `ServiceProxy`, deliberately — that class's own header states it "does NOT decide which
    # service or URL to use", and it is right to: by the time a call reaches it the URL is already
    # trusted. This module is the deciding half, so putting it there would contradict a comment that
    # is load-bearing about where trust is established.
    module Services
      module_function

      # The env var an operator sets to point this deployment at `name`'s sidecar.
      #
      # `tr("-", "_")` because a service name is manifest-supplied and may be kebab-case (the test
      # fixture's `fixture-svc` is), while an env var cannot carry a hyphen portably. Exposed rather
      # than kept private so there is ONE derivation to cite: until F (2026-10-13) `unavailable_reason`
      # named this key in the greyed card; the card now speaks to the maker and names only the
      # SERVICE, and the variable reaches the operator through Help's collapsed "for the person
      # running this server" section and docs/INSTALL.md instead.
      def env_key_for(name) = "#{name.to_s.upcase.tr('-', '_')}_SIDECAR_URL"

      # -> the configured base URL, or nil. `.presence` because Kamal's `env.clear` blanks a key
      # rather than removing it on a destination that has no such accessory (CLAUDE.md §14c — the
      # OVH overlay does exactly this), so "" is the SHAPE a real unconfigured deployment has. An
      # `ENV.key?` test would read that blank as configured and hand "" to URI.parse.
      def url_for(name) = ENV[env_key_for(name)].presence
    end
  end
end
