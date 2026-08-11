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
      #
      # THE states_key CHECK NEEDS THE WHOLE INDEX, WHICH IS WHY IT IS HERE AND NOT IN `build`.
      # `build` is handed one manifest and cannot see whether the addon being claimed agreed — the
      # question is about a PAIR of manifests, so it is asked where both are in scope.
      def all
        index = manifests
        index.filter_map { |m| build(m) }
             .select { |addon| states_key_permitted?(addon, index) }
             .sort_by { |a| [ a.title, a.key ] }
      end

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
          # THIS IS A DELIBERATE TRUST WIDENING, AND IT NOW HAS A HOST-SIDE CONSTRAINT. A manifest
          # that declares `states_key: "other-addon"` asks for both read AND write access to
          # "other-addon"'s saved states — for every user — which is real power, not a naming
          # convenience, so it is worth knowing why an addon can ask for it at all: the field exists
          # for a successor addon (e.g. "boxes-next") to keep reading and writing a predecessor's
          # saved states under its own key. The grant is no longer unconditional: `Registry.all`'s
          # `states_key_permitted?` refuses the claim unless "other-addon" names this addon back in
          # its own `shares_states_with` — including when "other-addon" does not exist in the index
          # at all (audit §2.1). It was safe with no constraint only because the trust model was
          # "just me / trusted forks," and manifests are fetched from a private repo we control
          # (Maker::Addons::Source) — an addon we didn't write could not appear in the list to begin
          # with. That is exactly why it was cheap to make the constraint real now, before that trust
          # model ever needs to widen to third-party sources or manifests we don't author ourselves.
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
          # `Array()` means a BARE STRING is accepted here as a one-element list, unlike `services`
          # and `pins` which type-check. Lenient in the CONSENT direction — the worst case is an
          # author writing `"shares_states_with": "boxes-next"` and it working — so it is safe, but
          # it is leniency rather than validation and the doc says "array of strings".
          shares_states_with: Array(manifest["shares_states_with"]).map(&:to_s)
        )
      end

      # MUTUAL DECLARATION, OR NO SHARING. The claimant names the target in `states_key`; the target
      # must name the claimant in `shares_states_with`. Anything else is refused, INCLUDING a claim
      # on an addon that is not in the index at all — see the test for why the permissive reading is
      # the dangerous one.
      #
      # THE TARGET MUST ALSO BUILD, NOT MERELY APPEAR IN THE RAW INDEX. Finding the entry by key is
      # not enough: an entry `build` itself REJECTS — missing a REQUIRED key, or declaring an
      # api_version this host doesn't speak — would otherwise CONFER a grant on its own behalf while
      # never appearing in `Registry.all`, leaving an operator no surface on which to see it, let
      # alone audit what it granted. `build` is pure and reads only the one manifest handed to it, so
      # calling it again here costs nothing and introduces no ordering dependency on `index`.
      #
      # WHAT THIS DOES *NOT* CLOSE, STATED PLAINLY BECAUSE AN EARLIER DRAFT OF THIS COMMENT CLAIMED
      # OTHERWISE AND WAS FALSE. There are TWO ways a target can be invisible in the gallery, and
      # this clause closes ONE: `build` rejecting it. The other is the target being skipped by THIS
      # SAME CHECK, and such a target still confers a grant. Probed, against the exact index the old
      # comment offered as its example (A claims B, B reciprocates A, B claims C unreciprocated, C
      # malformed): **A IS ADMITTED with states_key "b" while B is absent from `Registry.all`** — so
      # the "transitively too" claim was simply not true of the code. It is also HARMLESS, which is
      # why the check is not made recursive: that target still had to write `shares_states_with`
      # itself, so no addon ever receives a namespace whose owner did not consent. Consent is the
      # property that matters here; gallery visibility is not.
      #
      # SKIP, NOT GREY OUT — DELIBERATELY THE OPPOSITE OF `min_host`'S CHOICE ABOVE, and the two do
      # not generalise to each other. `min_host` leaves a too-new addon LISTED with an
      # `unavailable_reason`, on the grounds that an addon which silently never appears reads as a
      # broken deploy. That argument does not reach here, because `Tools::AddonsController` never
      # gates on `available?` at all — its ONE consumer is the `if addon.available?` in
      # `app/views/tools/home/index.html.erb` that decides how a gallery card renders (two further
      # lines there render `unavailable_reason`), and nothing else in the app asks. A
      # listed-but-unavailable addon is still `Registry.find`-able, `load_addon` still succeeds, and
      # `#states`/`#create` still serve `@addon.states_key` exactly as if nothing were wrong. Greying
      # this out would leave the hole wide open while LOOKING closed. A future editor harmonising the
      # two decisions is the mistake to watch for — don't.
      #
      # A refusal SKIPS the addon, exactly as an unsupported api_version does, rather than raising:
      # one bad manifest must never take /tools down. The consequence is worth stating because it is
      # silent — an addon that gets this wrong simply does not appear, and the operator's only clue
      # is the log line below. That line fires ONCE PER `Registry.all`, i.e. once per request, NOT
      # once per deploy: only `manifests` is cached, and `.all` re-filters the cached index on every
      # call — which is every `/tools` render and every `Registry.find` through `load_addon`.
      # Measured: 5 calls, 5 lines, with the index cached. Left as-is deliberately (deduplicating it
      # means process-global state for a log line), but a standing unreciprocated claim in production
      # is one warn per request until the manifest is fixed, and that is a log-volume fact worth
      # knowing before reading it as a loop.
      #
      # A↔B CYCLES ARE ADMITTED, NOT A BUG. Two addons each naming the other in both `states_key` AND
      # `shares_states_with` are both admitted, and their saved-state namespaces SWAP rather than one
      # inheriting the other. It cannot loop — this method reads the raw TARGET HASH directly and
      # never calls itself (or `states_key_permitted?`) on the target — and it requires both manifest
      # authors to deliberately opt in. Nothing downstream keys a foreign key, a route, or an
      # authorization decision on `addon_key`; the one cosmetic consequence is
      # `Tools::AddonParamsController#show` falling back to `state.addon_key` for a download filename
      # when the state's own name parameterizes to blank.
      def states_key_permitted?(addon, index)
        return true if addon.states_key == addon.key

        target = index.find { |m| m.is_a?(Hash) && m["key"].to_s == addon.states_key }
        permitted = target && build(target) &&
                    Array(target["shares_states_with"]).map(&:to_s).include?(addon.key)
        unless permitted
          Rails.logger.warn("addon #{addon.key.inspect} claims states_key #{addon.states_key.inspect} " \
                            "without a matching shares_states_with — skipping it")
        end
        permitted
      end
    end
  end
end
