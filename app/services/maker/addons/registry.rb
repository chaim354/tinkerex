module Maker
  module Addons
    # Addons are declared by MANIFESTS fetched from the addon source (Maker::Addons::Source), not
    # listed here — that is what lets an addon ship without editing this repo, and what makes
    # republishing a bundle the deploy.
    #
    # `available?` is retained from the frozen-hash design and still earns its place: an addon whose
    # source is unreachable, whose api_version we don't speak, or whose manifest is malformed greys
    # out rather than 500ing. One bad addon must never take /tools down.
    Addon = Data.define(:key, :title, :icon, :description, :entry, :pins, :services, :layout, :states_key) do
      def available? = true # a registered addon is by definition fetchable; see Registry#manifests
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
          states_key: manifest["states_key"].presence || manifest["key"].to_s
        )
      end
    end
  end
end
