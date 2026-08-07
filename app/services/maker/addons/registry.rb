module Maker
  module Addons
    # Addons are declared by MANIFESTS fetched from the addon source (Maker::Addons::Source), not
    # listed here — that is what lets an addon ship without editing this repo, and what makes
    # republishing a bundle the deploy.
    #
    # `available?` is retained from the frozen-hash design and still earns its place: an addon whose
    # source is unreachable, whose api_version we don't speak, or whose manifest is malformed greys
    # out rather than 500ing. One bad addon must never take /tools down.
    Addon = Data.define(:key, :title, :icon, :description, :entry, :pins, :services, :layout,
                        :states_key, :version, :author, :license, :homepage, :permissions,
                        :min_host, :shares_states_with) do
      # NO LONGER HARDCODED TRUE. It was, for as long as a registered addon was by definition
      # fetchable; `min_host` gives it a second, real answer — an addon can be perfectly fetchable
      # and still ask for a host this deployment does not have. The gallery already had the
      # unavailable branch waiting.
      def available? = unavailable_reason.nil?

      # A REASON, NOT A BOOLEAN, because the gallery previously hardcoded "Not configured on this
      # deployment" as the only explanation there could be. A too-new addon greying out under that
      # label would send an operator to check env vars that are fine.
      def unavailable_reason
        return unless min_host > Maker::Addons::Host::LEVEL

        "Needs a newer version of this host (asks for level #{min_host}, this host is level " \
          "#{Maker::Addons::Host::LEVEL})"
      end
    end

    module Registry
      module_function

      API_VERSION = "1"
      CACHE_KEY = "maker/addons/manifests"
      TTL = 5.minutes
      REQUIRED = %w[key title icon description api_version entry].freeze

      # Sorted by [title, key]: sort_by is not stable, and source order must never be user-visible.
      def all = manifests.filter_map { |m| build(m) }.sort_by { |a| [ a.title, a.key ] }

      def find(key) = all.find { |a| a.key == key.to_s }

      # A fetch failure returns [] for THIS request and caches nothing — rescuing outside
      # `Rails.cache.fetch` is deliberate. Rescuing inside would cache the empty result, so a
      # two-second blip would grey every addon out for the whole TTL.
      def manifests
        Rails.cache.fetch(CACHE_KEY, expires_in: TTL) { Source.current.manifests }
      rescue StandardError => e
        Rails.logger.warn("addon source unavailable: #{e.class}: #{e.message}")
        []
      end

      def build(manifest)
        return unless manifest.is_a?(Hash)
        return unless REQUIRED.all? { |k| manifest[k].present? }
        return unless manifest["api_version"].to_s == API_VERSION

        Addon.new(
          key: manifest["key"].to_s, title: manifest["title"].to_s, icon: manifest["icon"].to_s,
          description: manifest["description"].to_s, entry: manifest["entry"].to_s,
          pins: manifest["pins"].is_a?(Hash) ? manifest["pins"] : {},
          services: manifest["services"].is_a?(Array) ? manifest["services"].map(&:to_s) : [],
          # Only "wide" is meaningful today. Anything else — absent, nil, a typo, a value a NEWER
          # addon invents for a host version we haven't shipped yet — collapses to the same default
          # as "absent" rather than erroring: a manifest is fetched from a source this process does
          # not control (Maker::Addons::Source), so an unrecognized value must degrade, not 500.
          layout: manifest["layout"].to_s == "wide" ? "wide" : nil,
          # The addon_key an addon's saved Maker::AddonState rows live under — read AND written
          # under this key (Tools::AddonsController#states / #create). Defaults to the addon's own
          # `key`, exactly as pins/services/layout default, so every existing addon is unaffected.
          #
          # THIS IS A DELIBERATE TRUST WIDENING WITH NO HOST-SIDE CONSTRAINT. A manifest that
          # declares `states_key: "other-addon"` grants itself both read AND write access to
          # "other-addon"'s saved states — for every user, unconditionally. Nothing here checks
          # that the two addons are "related," that the same person authored both, or that the
          # declaring addon even exists under that name. It works today because the trust model is
          # "just me / trusted forks," and manifests are fetched from a private repo we control
          # (Maker::Addons::Source) — an addon we didn't write cannot appear in the list to begin
          # with. If that trust model ever widens — third-party addon sources, manifests we don't
          # author ourselves — this line stops being safe and needs a real constraint (e.g. the host
          # asserting states_key == key unless explicitly allow-listed), not a comment.
          states_key: manifest["states_key"].presence || manifest["key"].to_s,
          # ALL OPTIONAL, ALL DEGRADING — the rule `layout` already follows. A manifest comes from a
          # source this process does not control.
          version: manifest["version"].presence&.to_s,
          author: manifest["author"].presence&.to_s,
          license: manifest["license"].presence&.to_s,
          homepage: manifest["homepage"].presence&.to_s,
          # Kept as an array of hashes rather than a richer object: the only consumers are a view and
          # an operator reading a card. An entry without a `name` is dropped rather than coerced —
          # coercion would invent a `reasoning` the author never wrote.
          permissions: Array(manifest["permissions"]).select { |p| p.is_a?(Hash) && p["name"].present? },
          # AN INTEGER OR NOTHING. `"2".to_i` is 2, which would silently honour a string a JSON
          # manifest should not contain; refusing it leaves the addon available, which is the
          # failure direction an operator can actually diagnose.
          min_host: manifest["min_host"].is_a?(Integer) ? manifest["min_host"] : 0,
          shares_states_with: Array(manifest["shares_states_with"]).map(&:to_s)
        )
      end
    end
  end
end
