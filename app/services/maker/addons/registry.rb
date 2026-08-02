module Maker
  module Addons
    # Same key-lookup shape as Maker::Previews::Registry, but mutable and self-registering rather
    # than a frozen constant — addons REGISTER themselves rather than being listed in a frozen hash
    # here, which is what lets an addon ship as a gem without editing this repo. The host's own
    # three register in config/initializers/addons.rb.
    #
    # `path` is a PROC over url_helpers, not a naming convention, and that is load-bearing.
    # Resolving an addon's link by inflecting its key — send("tools_#{key}_path") — is the entire
    # reason for the two inflector traps documented in config/routes.rb: an addon whose key does not
    # inflect to a working zero-argument helper takes /tools down for every user. An addon that names
    # its own path cannot make that mistake. The traps remain real for whoever WRITES an addon's
    # routes; what a declared path removes is the GALLERY's dependence on the naming.
    #
    # `available` stays a lambda so an addon whose backing service is unconfigured greys out instead
    # of 500ing — it must not be evaluated at registration time, when ENV may not be settled.
    #
    # NOTE: Addon carries lambdas, so Data's value equality is meaningless here — never compare or
    # dedupe Addons by ==.
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
      # order is an implementation detail the gallery must not expose to the user. KEY is the
      # tiebreaker: sort_by is not stable, so two addons sharing a title (plausible once independent
      # gem authors pick names) would otherwise order nondeterministically across boots.
      def all = entries.values.sort_by { |a| [ a.title, a.key ] }

      def find(key) = entries[key.to_s]

      # Test support. `to_prepare` re-registers on every dev reload, which is why `register`
      # overwrites by key; this exists so a test can assert against a registry it controls.
      def reset! = @entries = nil

      # INTERNAL — not part of the SDK surface. Kept private so nothing outside register/all/find can
      # mutate the live table directly (a stray `entries["x"] = "not an addon"` would otherwise raise
      # only later, in `all`, far from the mistake).
      def entries = @entries ||= {}
      private_class_method :entries
    end
  end
end
