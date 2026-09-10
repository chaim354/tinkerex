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
  end
end
