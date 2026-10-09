module Tools
  # The /tools gallery — an app launcher for the registered addons.
  class HomeController < BaseController
    def index
      @addons = Maker::Addons::Registry.all
      # TWO WAYS TO HAVE NO TOOLS, AND THE PAGE SAYS WHICH (UI-cohesion spec §2.4). `Registry.all`
      # returns [] both when no source is configured at all and when a configured one is empty or
      # unreachable — it rescues and logs rather than 500ing, which is right, but it meant a
      # deployment with a mis-set ADDON_SOURCE_URL looked exactly like one with nothing installed.
      # docs/invariants/addons.md names both states as live: OVH blanks ADDON_SOURCE_URL today and
      # gets an empty gallery on purpose. Asking the SOURCE, not the addon list, is what tells them
      # apart.
      @addon_source_configured = Maker::Addons::Source.configured?
    end

    # The top bar's New ▾ menu loads this into a lazy frame when it opens (layouts/_topbar.html.erb).
    # Available tools only — an unavailable one would be an entry that opens an apology — and none
    # at all without a configured source, where Source.current would raise and Registry log it.
    def new_menu
      @addons = Maker::Addons::Source.configured? ? Maker::Addons::Registry.all.select(&:available?) : []
      render layout: false
    end
  end
end
