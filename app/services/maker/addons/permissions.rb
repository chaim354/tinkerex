module Maker
  module Addons
    # WHAT AN ADDON ASKS FOR, AS A VOCABULARY WITH ONE DEFINITION. Distinct from
    # Maker::Addons::Host::CAPABILITIES, and the distinction is worth holding: a CAPABILITY is what
    # this host can do, a PERMISSION is what an addon declares it wants. They share some names
    # (`library:write`) and will diverge (`data:read:<addon>/<collection>` names another addon).
    #
    # DECLARED AND DISPLAYED, NOT ENFORCED — see docs/addon-api-v1.md. Nothing here gates a request.
    # Saying so in the code is the point: a permission list rendered on a gallery card looks exactly
    # like a boundary, and this one is an author's statement of intent that the operator can read at
    # publish time.
    module Permissions
      module_function

      LABELS = {
        "library:read"  => "Read files from your library",
        "library:write" => "Write files to your library",
        "state"         => "Save and reload its own settings",
        "project:read"  => "See which project you are working in"
      }.freeze

      # `service:<name>` and `data:read:<addon>/<collection>` are PARAMETERISED — the name carries a
      # value, so they cannot be table entries. Handled by pattern, and anything still unmatched
      # falls through to its own raw name.
      SERVICE_PREFIX = "service:".freeze

      def label_for(name)
        name = name.to_s
        return LABELS[name] if LABELS.key?(name)
        return "Call the #{name.delete_prefix(SERVICE_PREFIX)} service" if name.start_with?(SERVICE_PREFIX)

        # A permission this host has never heard of: show the author's own spelling rather than
        # nothing, so the card cannot understate what was asked for.
        name
      end
    end
  end
end
