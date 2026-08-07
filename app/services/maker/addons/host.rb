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
    # >= X" (the VS Code `engines` lesson, spec §4).
    module Host
      module_function

      LEVEL = 1

      CAPABILITIES = {
        "library:write"   => true,   # POST /tools/:key — the save door
        "library:read"    => false,  # PR 5
        "state:list"      => true,   # GET /tools/:key/states
        "state:crud"      => false,  # PR 3
        "data"            => false,  # PR 4 — addon-owned collections
        "maker:read"      => false,  # deferred (spec §13)
        "project:current" => false,  # PR 3
        "service"         => true,   # the sidecar proxy
        "pick:folder"     => true,   # ctx.chooseFolder, already shipped
        "pick:file"       => false   # PR 5
      }.freeze

      def capabilities = CAPABILITIES

      def level = LEVEL
    end
  end
end
