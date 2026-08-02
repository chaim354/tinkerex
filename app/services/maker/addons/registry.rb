module Maker
  module Addons
    # ext-registry pattern (mirrors Maker::Previews::Registry), but addons REGISTER themselves rather
    # than being listed in a frozen hash here — that is what lets an addon ship as a gem without
    # editing this repo. The host's own three register in config/initializers/addons.rb.
    #
    # `path` is a PROC over url_helpers, not a naming convention, and that is load-bearing. The
    # gallery used to call send("tools_#{key}_path"), which is the entire reason for the two
    # inflector traps documented in config/routes.rb: an addon whose key does not inflect to a
    # working zero-argument helper took /tools down for every user. An addon that names its own path
    # cannot make that mistake. The traps remain real for whoever WRITES an addon's routes; what
    # changed is that the gallery no longer depends on the naming.
    #
    # `available` stays a lambda so an addon whose backing service is unconfigured greys out instead
    # of 500ing — it must not be evaluated at registration time, when ENV may not be settled.
    Addon = Data.define(:key, :title, :icon, :description, :available, :path) do
      def available? = available.call
      def path_for(url_helpers) = path.call(url_helpers)
    end

    module Registry
      module_function

      def register(key:, title:, icon:, description:, available:, path:)
        addon = Addon.new(key: key.to_s, title:, icon:, description:, available:, path:)
        entries[addon.key] = addon
      end

      # Sorted by TITLE, never by registration order: once gems register from their own engines, load
      # order is an implementation detail the gallery must not expose to the user.
      def all = entries.values.sort_by(&:title)

      def find(key) = entries[key.to_s]

      # Test support. `to_prepare` re-registers on every dev reload, which is why `register`
      # overwrites by key; this exists so a test can assert against a registry it controls.
      def reset! = @entries = nil

      def entries = @entries ||= {}
    end
  end
end
