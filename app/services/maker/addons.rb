module Maker
  # The addon SDK's version gate. `Maker::Addons` was until now an implicit namespace created by the
  # files beneath it; it is explicit here because an addon gem needs something to ask a question of.
  #
  # An addon calls `require_sdk!` from its engine at BOOT. That timing is the point: the alternative
  # is a NoMethodError the first time a user clicks the addon, on a deployment whose suite was green
  # — the exact shape §15 exists to prevent.
  module Addons
    # The six surfaces this version covers are enumerated in
    # docs/superpowers/specs/2026-08-02-tools-addons-separate-repo-design.md §3.
    # MINOR when adding a surface; MAJOR when changing or removing one.
    SDK_VERSION = "1.0.0".freeze

    class IncompatibleSDK < StandardError; end

    module_function

    # `requirement` is any Gem::Requirement string, e.g. "~> 1.0".
    def require_sdk!(requirement)
      return true if Gem::Requirement.new(requirement).satisfied_by?(Gem::Version.new(SDK_VERSION))

      raise IncompatibleSDK,
            "addon requires Maker::Addons SDK #{requirement}, host provides #{SDK_VERSION} — " \
            "upgrade the host or pin an older addon release"
    end
  end
end
