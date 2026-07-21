module Tools
  # The /tools gallery — an app launcher for the registered addons.
  class HomeController < BaseController
    def index
      @addons = Maker::Addons::Registry.all
    end
  end
end
