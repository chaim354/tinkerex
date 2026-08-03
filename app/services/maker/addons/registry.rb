module Maker
  module Addons
    # Addons are declared by MANIFESTS fetched from the addon source (Maker::Addons::Source), not
    # listed here — that is what lets an addon ship without editing this repo, and what makes
    # republishing a bundle the deploy.
    #
    # `available?` is retained from the frozen-hash design and still earns its place: an addon whose
    # source is unreachable, whose api_version we don't speak, or whose manifest is malformed greys
    # out rather than 500ing. One bad addon must never take /tools down.
    Addon = Data.define(:key, :title, :icon, :description, :entry, :pins, :services) do
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
          services: manifest["services"].is_a?(Array) ? manifest["services"].map(&:to_s) : []
        )
      end
    end
  end
end
