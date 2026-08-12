module Maker
  module Addons
    # WHAT THIS HOST CAN DO, AS ONE SERVER-SIDE DEFINITION. Serialized into the addon shell's ctx
    # and returned by the SDK's `host.capabilities()`, so a bundle never carries a second copy of
    # this list — the failure shape CLAUDE.md §14d records for the extension->role vocabulary.
    #
    # A CAPABILITY IS NAMED HERE BEFORE IT IS BUILT, ANSWERED `false`. That is the whole
    # compatibility mechanism: an addon can be authored against `library:read` today and simply
    # degrade until the host answers true, instead of being written after the fact. Every value
    # must be a real boolean — a missing key reads as `undefined` in JS and a nil reads as `false`,
    # so neither can be told apart from "deliberately off".
    #
    # LEVEL is the integer a manifest's `min_host` is compared against (added in PR 2). BUMP IT IN
    # THE SAME COMMIT that flips a capability to true, never afterwards: an addon that requires a
    # capability has no other way to say so, and `api_version` equality cannot express "needs host
    # >= X" (the VS Code `engines` lesson, docs/superpowers/specs/2026-08-07-addon-api-v1-design.md
    # §4 — NAMED, because source.rb one file over cites the 2026-08-02 bundle design as a bare
    # "spec §" and that document has a §4 of its own).
    module Host
      module_function

      # 2 — PR 5's file plane. Bumped IN THE SAME COMMIT that flipped `library:read` and
      # `pick:file` to true, per the rule above.
      LEVEL = 2

      CAPABILITIES = {
        "library:write"   => true,   # POST /tools/:key — the save door
        "library:read"    => true,   # GET /tools/:key/file/:node_id — PR 5
        "state:list"      => true,   # GET /tools/:key/states
        "state:crud"      => false,  # PR 3
        "data"            => false,  # PR 4 — addon-owned collections
        "maker:read"      => false,  # deferred (spec §13)
        "project:current" => false,  # PR 3
        "service"         => true,   # the sidecar proxy
        "pick:folder"     => true,   # ctx.chooseFolder, already shipped
        "pick:file"       => true    # ctx.chooseFile — PR 5
      }.freeze

      # BINARY OUTPUT GOT NO CAPABILITY OF ITS OWN, AND THAT IS A DECISION RATHER THAN AN OMISSION.
      # It is not a new door — it is the SAME save door (`library:write`) growing a second wire
      # shape — so a second name would have to be answered `true` for exactly the hosts that answer
      # `library:write` true, forever, which is a name that carries no information. What tells a
      # bundle it may send bytes is `LEVEL >= 2`, which is precisely what `min_host` exists to
      # express (docs/addon-api-v1.md §3). Recorded here because "binary output" reads like a
      # capability and the next person WILL look for one.

      def capabilities = CAPABILITIES
    end
  end
end
