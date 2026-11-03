module Tools
  # The /tools gallery — an app launcher for the registered addons.
  class HomeController < BaseController
    # THE GALLERY'S SECTIONS, IN THE ORDER THE PAGE DRAWS THEM, keyed by the manifest `category`
    # Registry normalised (nil for anything but the three names). The heading is the maker's
    # question, not the manifest's word: "generate" is what a tool does, "Make a file" is what the
    # maker came to do. "Other" holds the uncategorised, which is every bundle published before the
    # key existed — so it is a real section and not a dumping ground, and it comes last.
    SECTIONS = [
      [ "Make a file", "generate" ],
      [ "Look inside a file", "inspect" ],
      [ "Calculate and look up", "reference" ],
      [ "Other", nil ]
    ].freeze

    def index
      @addons = Maker::Addons::Registry.all
      # SECTIONS COMPUTED HERE, AN EMPTY ONE DROPPED: a heading over nothing reads as a tool that
      # failed to load. Each addon lands in exactly one section, so the cards the page draws are
      # exactly `@addons` — home_controller_test.rb counts them through the sections.
      @sections = SECTIONS.filter_map do |heading, category|
        addons = @addons.select { |addon| addon.category == category }
        [ heading, addons ] if addons.any?
      end
      # TWO WAYS TO HAVE NO TOOLS, AND THE PAGE SAYS WHICH (UI-cohesion spec §2.4). `Registry.all`
      # returns [] both when no source is configured at all and when a configured one is empty or
      # unreachable — it rescues and logs rather than 500ing, which is right, but it meant a
      # deployment with a mis-set ADDON_SOURCE_URL looked exactly like one with nothing installed.
      # docs/invariants/addons.md names both states as live: OVH blanks ADDON_SOURCE_URL today and
      # gets an empty gallery on purpose. Asking the SOURCE, not the addon list, is what tells them
      # apart.
      @addon_source_configured = Maker::Addons::Source.configured?
      # WHY A TOOL NEVER APPEARED — Registry.problems, the host's own definition of a skipped
      # manifest. LOCAL ENVIRONMENTS ONLY: the author editing a bundle is looking at this page, and
      # in production the cards are read by the maker, who can act on none of it. Production keeps
      # the log line Registry.all writes per problem.
      @addon_problems = Rails.env.local? ? Maker::Addons::Registry.problems : []
    end

    # The top bar's New ▾ menu loads this into a lazy frame when it opens (layouts/_topbar.html.erb).
    # Available tools only — an unavailable one would be an entry that opens an apology — and none
    # at all without a configured source, where Source.current would raise and Registry log it.
    #
    # TOOLS THAT MAKE SOMETHING ONLY: New ▾ makes a thing in the folder it was opened from, so an
    # inspector or a reference listed there would open a tool that makes nothing in that folder.
    # `generate` and nil — nil because every bundle published before `category` existed is a
    # generator (Generators, Box Generator, OpenSCAD), and the key's absence must change nothing.
    def new_menu
      @addons = available_addons.select { |addon| [ nil, "generate" ].include?(addon.category) }
      # The folder the menu was opened from (layouts/_topbar.html.erb's frame src), echoed into each
      # tool link as `?in=`. A String only; the tool page validates it
      # (Tools::AddonsController#destination_from_param), so a bad value costs a link to the tool's
      # own default.
      @in = params[:in].presence if params[:in].is_a?(String)
      render layout: false
    end

    # GET /tools/open_with?file=<id> — the file page's "Open in <tool>" buttons (host level 4), for
    # the lazy frame files/show.html.erb points at this: one link per AVAILABLE addon whose manifest
    # `opens` names the file's extension, each carrying the file as the tool's `?file=` hint.
    #
    # THE FRAME IS WHY THIS IS AN ENDPOINT AND NOT PART OF THE FILE PAGE'S RENDER. Listing tools
    # means reading the addon registry — a manifest fetch over HTTP behind a 5-minute cache — and the
    # file page must never depend on it: on an addon-source outage that is a slow file page for a
    # maker who has never opened /tools, the cost `Maker::AddonOrigin` is built to avoid (it consults
    # the registry only when a node query found addon output). A frame the page merely points at
    # costs the page nothing, and `loading="lazy"` costs the maker nothing until the buttons are in
    # view. The same argument keeps this OUT of the right-click file menu, which is built per row on
    # the Files index — there it would be a registry read on every Files render.
    #
    # EMPTY, NEVER AN ERROR, FOR EVERY MISS. `?file=` is a hint here exactly as it is on the tool
    # page (Tools::AddonsController#launch_file): a String only (an Array is an IN lookup that
    # resolves to a file nobody named), a live FILE of this user's, with an extension, that at least
    # one available tool opens — anything else renders the frame with nothing in it. The frame is
    # drawn on every file page, so a miss has to cost nothing the page can see.
    #
    # `available?` IS COSMETIC EVERYWHERE ELSE AND COSMETIC HERE: a greyed tool is left off the list
    # because its link would open an apology, not because the omission guards anything — its page
    # still answers by URL (docs/invariants/addons.md).
    def open_with
      @file = params[:file].is_a?(String) ? current_user.nodes.present.find_by(node_id: params[:file], kind: "file") : nil
      extension = @file && File.extname(@file.name).downcase
      @addons = extension.present? ? available_addons.select { |addon| addon.opens.include?(extension) } : []
      render layout: false
    end

    private

    # The addons a menu or a frame may link to: available ones, and none at all without a configured
    # source, where Source.current would raise and Registry log it on every open.
    def available_addons
      Maker::Addons::Source.configured? ? Maker::Addons::Registry.all.select(&:available?) : []
    end
  end
end
