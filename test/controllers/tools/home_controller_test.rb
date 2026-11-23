require "test_helper"
require_relative "../../support/fake_addon_source"

module Tools
  class HomeControllerTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    # Was `assert_select ".addon-card", text: /Box Generator/`, which passed against the TEMPORARY
    # hardcoded boxes card regardless of whether Registry had anything real in it — both the
    # "available" and "disabled" branches of that block rendered the title text. Boxes has since
    # migrated onto the generic manifest-driven surface (Tools::AddonsController), so "lists
    # registered addons" now has to mean what it says: stub Maker::Addons::Source, the same door
    # `boxes` itself goes through in production, and assert the @addons loop actually renders it.
    MANIFEST = {
      "key" => "widgetkit", "title" => "Generators", "icon" => "✏️",
      "description" => "Parametric 2D drawings", "api_version" => "1", "entry" => "generators.js"
    }.freeze

    setup do
      @user = User.create!(email: "tools@example.com", password: PASSWORD, confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
      @prior_cache = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
      Maker::Addons::Source.stub = FakeAddonSource.new(manifests: [ MANIFEST ])
    end

    teardown do
      Rails.cache = @prior_cache
      Maker::Addons::Source.reset!
    end

    test "requires login" do
      reset!
      get tools_path
      assert_redirected_to new_user_session_path
    end

    test "lists registered addons" do
      get tools_path
      assert_response :success
      assert_select ".addon-card", text: /Generators/ # from the registry-driven @addons loop
    end

    # EVERY CARD COMES FROM A MANIFEST — asserted as a COUNT, which is the only form that can see a
    # card the @addons loop did not produce. Until openscad migrated, this view ended with a
    # hand-written block rendering an OpenSCAD card whether or not the Registry had anything in it,
    # and the assertion guarding it (`assert_select ".addon-card", text: /OpenSCAD/`) matched BOTH
    # branches of that block — so it could not tell "this addon is registered" from "somebody
    # hardcoded a card". One manifest is stubbed above, so one card; a reintroduced hardcoded card
    # makes this 2 and fails here.
    test "the gallery renders no card the registry did not produce" do
      get tools_path
      assert_response :success
      assert_select ".addon-card", count: 1
    end

    # THE GALLERY SHOWS THE REASON, NOT A FIXED SENTENCE. Before this, the disabled card's tooltip
    # said "Not configured on this deployment" for every cause there could be — which for a
    # too-new addon points an operator at env vars that are perfectly fine.
    test "a too-new addon renders its own unavailable reason" do
      Maker::Addons::Source.stub = FakeAddonSource.new(manifests: [
        MANIFEST.merge("min_host" => Maker::Addons::Host::LEVEL + 1)
      ])
      get tools_path
      assert_response :success
      # THE TITLE IS READ OFF THE NODE AND COMPARED FOR EQUALITY, because both selector spellings of
      # this assertion looked right and could never go green. `[title=?]` with a Regexp:
      # rails-dom-testing substitutes it via #to_s into an exact CSS equality selector
      # (`[title="(?-mix:...)"]`). `:match('title', ?)` with a Regexp: green on nokogiri 1.19.4 and
      # 0 matches from 1.19.5 on, whose CSS parser decodes string escapes per CSS Syntax Level 3, so
      # the regex's `\A`, `\(` and `\z` reached rails-dom-testing's handler as a newline, `(` and
      # `z` -- one red test on every leg the day the gem was bumped (2026-11-04), over correct
      # markup. Equality is what the anchored regex was emulating, and it goes through neither
      # gem's quoting. In the maker's words, the levels after (UX audit H): "host" and "level" are
      # the API's.
      cards = css_select(".addon-card.disabled")
      assert_equal 1, cards.size, "expected exactly one disabled card"
      assert_equal "Needs a newer Tinkerex than this server runs (level #{Maker::Addons::Host::LEVEL + 1}; " \
                   "this server is level #{Maker::Addons::Host::LEVEL})",
                   cards.first["title"]
    end

    # WHAT THE OPERATOR SEES AT PUBLISH TIME. The point of rendering these is scope drift: a
    # republished bundle that quietly starts asking for more shows up in its card's Permissions
    # dialog, in a deployment where publishing the bundle IS the deploy and Rails is never rebuilt.
    # The dialog, not the card, since 2026-11-23: the card names the tool, and its right-click
    # menu's Permissions… opens the dialog its `data-tool-permissions` names.
    test "a card's permissions dialog lists what its manifest declares, by label, with the reasons" do
      Maker::Addons::Source.stub = FakeAddonSource.new(manifests: [
        MANIFEST.merge("permissions" => [ { "name" => "library:write", "reasoning" => "to save the drawing" },
                                          { "name" => "service:boxes" } ])
      ])
      get tools_path
      assert_response :success
      dialog_id = css_select("div.addon-card").first["data-tool-permissions"]
      assert_equal "tool-permissions-0", dialog_id
      assert_select "dialog.modal.tool-permissions##{dialog_id}[aria-labelledby=?]", "#{dialog_id}-title" do
        assert_select "h2##{dialog_id}-title", "Generators permissions"
        assert_select "form[method=dialog] button.modal-close[aria-label=Close]"
        assert_select ".tool-permissions-list li", 2
        assert_select ".tool-permissions-list li:nth-child(1) .tool-permission-name", "Write files to your library"
        assert_select ".tool-permissions-list li:nth-child(1) .tool-permission-reason", "to save the drawing"
        assert_select ".tool-permissions-list li:nth-child(2) .tool-permission-name", "Call the boxes service"
        assert_select ".tool-permissions-list li:nth-child(2) .tool-permission-reason", 0
      end
      # NOTHING OF IT IS ON THE CARD ANY MORE, and the dialog is not inside the card either, so a
      # click or a right click in the open dialog cannot reach the card's stretched link or menu.
      assert_select ".addon-card .addon-permissions", 0
      assert_select ".addon-card", text: /This tool can/, count: 0
      assert_select ".addon-card dialog", 0
    end

    test "an addon declaring no permissions still gets a dialog, which says so" do
      get tools_path
      assert_response :success
      assert_select "div.addon-card[data-tool-permissions=tool-permissions-0]"
      assert_select "dialog#tool-permissions-0" do
        assert_select ".tool-permissions-list", 0
        assert_select "p", "This tool does not ask for any permissions."
      end
    end

    # A GREYED-OUT CARD HAS NO MENU (it cannot run here), so nothing could open a dialog for it, and
    # none is drawn. Built-in tools declare nothing and have no Permissions… entry either.
    test "a greyed-out addon and the built-in tools have no permissions dialog" do
      Maker::Addons::Source.stub = FakeAddonSource.new(manifests: [
        MANIFEST.merge("min_host" => Maker::Addons::Host::LEVEL + 1, "permissions" => [ { "name" => "library:write" } ])
      ])
      get tools_path
      assert_response :success
      assert_select ".addon-card.disabled", 1
      assert_select ".addon-card.disabled[data-tool-permissions]", 0
      assert_select "dialog.tool-permissions", 0
      assert_select ".tool-card[data-tool-permissions]", 0
    end

    # ---- the gallery in sections ----------------------------------------------------------------

    def manifest(key, title, **extra) = MANIFEST.merge("key" => key, "title" => title, **extra)

    # The sections the page draws, in order, read as [heading, [card titles]]: a built-in tool's
    # `.tool-card` and a manifest's `.addon-card` alike, in the order the section draws them.
    def sections
      css_select(".tools-home .tools-section").map do |section|
        [ section.css(".tools-section-head").text.strip,
          section.css(".tool-card .addon-title, .addon-card .addon-title").map { |t| t.text.strip } ]
      end
    end

    # FOUR SECTIONS IN A FIXED ORDER, EACH DRAWN ONLY WHEN POPULATED. The manifests are listed in
    # the reverse of the order the page must draw, so source order and the spec's order disagree.
    # THE BUILT-IN TOOLS ARE IN THEM, FIRST (2026-11-23): the Material estimate under Look inside a
    # file, the calculator under Calculate and look up (Tools::HomeController::BUILT_IN).
    test "the gallery groups its tools by category, in a fixed order, drawing only populated sections" do
      Maker::Addons::Source.stub = FakeAddonSource.new(manifests: [
        manifest("bare", "Bare Tool"),
        manifest("fasteners", "Fasteners", "category" => "reference"),
        manifest("gcode", "G-code Inspector", "category" => "inspect"),
        manifest("gears", "Gears", "category" => "generate"),
        manifest("stats", "Model Stats", "category" => "inspect")
      ])
      get tools_path
      assert_response :success
      assert_equal [ [ "Make a file", [ "Gears" ] ],
                     [ "Look inside a file", [ "Material estimate", "G-code Inspector", "Model Stats" ] ],
                     [ "Calculate and look up", [ "Calculator", "Fasteners" ] ],
                     [ "Other", [ "Bare Tool" ] ] ], sections
      # EVERY CARD IS STILL `.addon-card`, so the count the test above pins keeps meaning what it says.
      assert_select ".addon-card", count: 5

      # EACH HEADING SAYS WHAT ITS TOOLS HAVE IN COMMON (2026-11-23): the sentence directly under
      # it, from SECTIONS, so the order of the sentences is the order of the headings.
      sentences = css_select(".tools-home .tools-section").map do |section|
        head = section.css(".tools-section-head").first
        assert_equal "tools-section-desc", head.next_element&.[]("class")&.split&.first,
                     "#{head.text} has no sentence directly under it"
        head.next_element.text.strip
      end
      assert_equal Tools::HomeController::SECTIONS.map(&:last), sentences
      # NO HEADING SORTS BY WHERE A TOOL COMES FROM: the "Built in" section and the "Add-ons" heading
      # over the categories are gone, so the page's section headings are SECTIONS' and nothing else.
      assert_equal Tools::HomeController::SECTIONS.map(&:first), css_select(".tools-section-head").map { |h| h.text.strip }

      # EVERY CARD'S MENU OPENS ITS OWN TOOL'S DIALOG. The cards are drawn by section and the
      # dialogs in registry order, so an id taken from the position in a SECTION would hand Gears
      # (first under Make a file, fourth in the registry) Bare Tool's dialog.
      css_select("div.addon-card").each do |card|
        title = card.css(".addon-title").text.strip
        dialog = css_select("dialog##{card["data-tool-permissions"]}").first
        assert dialog, "#{title}'s card names no dialog that exists"
        assert_equal "#{title} permissions", dialog.css("h2").text.strip
      end
    end

    test "an empty section is not drawn, and a greyed-out tool stays in its section" do
      Maker::Addons::Source.stub = FakeAddonSource.new(manifests: [
        manifest("gears", "Gears", "category" => "generate"),
        manifest("stats", "Model Stats", "category" => "inspect", "min_host" => Maker::Addons::Host::LEVEL + 1)
      ])
      get tools_path
      assert_response :success
      assert_equal [ [ "Make a file", [ "Gears" ] ],
                     [ "Look inside a file", [ "Material estimate", "Model Stats" ] ],
                     [ "Calculate and look up", [ "Calculator" ] ] ], sections
      assert_select ".tools-section-head", text: "Other", count: 0
    end

    # A SERVER WITH NO ADD-ONS STILL HAS ITS TWO TOOLS, each in its section, and the first-run state
    # comes after them. It says "add-ons", never "No tools": two tools are on the page above it.
    test "with no add-ons the built-in tools stand in their sections, above the first-run state" do
      Maker::Addons::Source.stub = FakeAddonSource.new(manifests: [])
      get tools_path
      assert_response :success
      assert_equal [ [ "Look inside a file", [ "Material estimate" ] ], [ "Calculate and look up", [ "Calculator" ] ] ], sections
      assert_select ".addon-card", 0
      assert_select ".tools-home > .tools-section:last-of-type + .empty", 1
      assert_select ".empty", text: /No add-ons (came back|are installed)/
      assert_select ".empty", text: /No tools/, count: 0
    end

    # EVERY BUILT-IN TOOL HAS ONE CARD, IN A SECTION THE GALLERY DRAWS. Maker::ToolPins::BUILT_IN is
    # what may be pinned; a key there and not in BUILT_IN would be a sidebar link with no card, and
    # a key under nil or an unnamed category would never be drawn.
    test "every built-in tool is placed once, under a category the gallery draws" do
      placed = Tools::HomeController::BUILT_IN.values.flatten
      assert_equal Maker::ToolPins::BUILT_IN.keys.sort, placed.sort
      assert_equal placed.uniq, placed
      assert_empty Tools::HomeController::BUILT_IN.keys - Tools::HomeController::SECTIONS.map { |_, category, _| category }.compact
      get tools_path
      assert_response :success
      Maker::ToolPins::BUILT_IN.each_key { |key| assert_select ".tools-section .tool-card##{key}", 1 }
    end

    # NO CARD HAS AN OPEN BUTTON (2026-11-23, the owner's call). A runnable card's one control is its
    # title, stretched over the card (pages/tools.css `.addon-card-link`), built-in and addon alike:
    # the Material estimate's is a link to its page, the calculator's a button that opens its modal.
    test "a runnable card's one control is its title, built-in and addon alike" do
      get tools_path
      assert_response :success
      cards = css_select(".tools-home .tool-card, .tools-home .addon-card:not(.disabled)")
      assert_equal Maker::ToolPins::BUILT_IN.size + 1, cards.size
      cards.each do |card|
        controls = card.css("a, button")
        label = card["id"] || card.text.squish
        assert_equal 1, controls.size, "#{label} has #{controls.map { |c| c.text.strip }.inspect}"
        assert_equal %w[addon-card-link addon-title], (controls.first["class"].split & %w[addon-title addon-card-link]).sort, label
        assert_equal card.css(".addon-title").text.strip, controls.first.text.strip, label
      end
      assert_select "#material a.addon-card-link[href=?]", tools_material_path, text: "Material estimate"
      assert_select "#calculator button.addon-card-link[type=button][data-calculator-open][aria-haspopup=dialog]", text: "Calculator"
      assert_select ".tools-home", text: /Open (calculator|material estimate)/, count: 0
    end

    # ---- the New menu ---------------------------------------------------------------------------

    # THE SOURCE MUST READ AS CONFIGURED, or #new_menu and #open_with list nothing: both ask
    # Source.configured?, which reads ENV alone — the stub decides what Source.current answers, not
    # whether a source exists (addon_destination_test.rb makes the same note).
    def with_configured_source
      prior = ENV["ADDON_SOURCE_PATH"]
      ENV["ADDON_SOURCE_PATH"] = Rails.root.join("test/fixtures/addons").to_s
      yield
    ensure
      prior ? ENV["ADDON_SOURCE_PATH"] = prior : ENV.delete("ADDON_SOURCE_PATH")
    end

    # NEW ▾ MAKES SOMETHING IN THE FOLDER IT WAS OPENED FROM. An inspector or a reference opened from
    # New makes nothing there, so only `generate` and an uncategorised tool are listed.
    test "the New menu lists generate and uncategorised tools, never an inspector or a reference" do
      Maker::Addons::Source.stub = FakeAddonSource.new(manifests: [
        manifest("bare", "Bare Tool"),
        manifest("fasteners", "Fasteners", "category" => "reference"),
        manifest("gcode", "G-code Inspector", "category" => "inspect"),
        manifest("gears", "Gears", "category" => "generate")
      ])
      with_configured_source { get tools_new_menu_path }
      assert_response :success
      assert_equal [ "Bare Tool", "Gears" ], css_select("turbo-frame#new-menu-tools a.menu-item").map { |a| a.text.strip }
    end

    # ---- the file page's "Open in <tool>" frame (host level 4) ----------------------------------

    def library_file(id, name, user: @user, kind: "file")
      user.nodes.create!(node_id: id, name:, kind:, mtime: 1, size: 1)
    end

    def open_with_links = css_select("turbo-frame#open-with a.btn").map { |a| [ a.text.strip, a["href"] ] }

    # ONE LINK PER AVAILABLE TOOL WHOSE `opens` NAMES THE FILE'S EXTENSION, case-folded, carrying the
    # file as the tool's `?file=` hint. The frame is the page's, so it is the whole body.
    test "open_with lists every available tool that opens the file's kind, and nothing else" do
      Maker::Addons::Source.stub = FakeAddonSource.new(manifests: [
        manifest("gcode", "G-code Inspector", "opens" => [ ".gcode", ".nc" ]),
        manifest("stats", "Model Stats", "opens" => [ ".stl" ]),
        manifest("bare", "Bare Tool"),
        manifest("inspector2", "Second Inspector", "opens" => [ "GCODE" ]),
        manifest("greyed", "Greyed Inspector", "opens" => [ ".gcode" ], "min_host" => Maker::Addons::Host::LEVEL + 1)
      ])
      library_file("n-part", "Part.GCODE")
      with_configured_source { get tools_open_with_path(file: "n-part") }
      assert_response :success
      assert_select "turbo-frame#open-with"
      assert_equal [ [ "Open in G-code Inspector", tools_addon_path("gcode", file: "n-part") ],
                     [ "Open in Second Inspector", tools_addon_path("inspector2", file: "n-part") ] ],
                   open_with_links
    end

    # EMPTY, NEVER AN ERROR, for every miss: no tool opens the kind, the file has no extension, the
    # id is a folder's, a stranger's, unknown, or not one id at all. The frame is drawn on every
    # file page, so a miss must cost nothing the page can see.
    test "open_with renders the frame empty for no match, no extension, a folder, a foreign file or no file" do
      Maker::Addons::Source.stub = FakeAddonSource.new(manifests: [
        manifest("gcode", "G-code Inspector", "opens" => [ ".gcode" ])
      ])
      library_file("n-svg", "plan.svg")
      library_file("n-bare", "LICENSE")
      library_file("d-cad", "cad", kind: "dir")
      other = User.create!(email: "other-#{SecureRandom.hex(4)}@example.com", password: PASSWORD, confirmed_at: Time.current)
      library_file("n-theirs", "theirs.gcode", user: other)

      [ "n-svg", "n-bare", "d-cad", "n-theirs", "nope", "" ].each do |id|
        with_configured_source { get tools_open_with_path(file: id) }
        assert_response :success, "?file=#{id.inspect} must still answer the frame"
        assert_select "turbo-frame#open-with"
        assert_equal [], open_with_links, "?file=#{id.inspect} must offer nothing"
      end
      with_configured_source { get "#{tools_open_with_path}?file[]=n-svg&file[]=nope" }
      assert_response :success
      assert_equal [], open_with_links
    end

    # The house stub helper (help_page_test.rb carries the same body). Replaces a SINGLETON method
    # for the block, removing an inherited one after.
    def replacing(owner, name, replacement)
      mod = owner.singleton_class
      own = mod.instance_methods(false).include?(name)
      original = mod.instance_method(name)
      mod.define_method(name, &replacement)
      yield
    ensure
      own ? mod.define_method(name, original) : mod.remove_method(name)
    end

    # WHY A TOOL NEVER APPEARED, SHOWN WHERE THE AUTHOR IS LOOKING — but only in a local
    # environment. In production the cards are read by the maker, who can do nothing with
    # "missing icon" (the onboarding rule that moved sidecar env-var names off the cards).
    test "a skipped manifest is named, with its reason, in a local environment" do
      Maker::Addons::Source.stub = FakeAddonSource.new(manifests: [
        MANIFEST, MANIFEST.merge("key" => "broken", "title" => "Broken").except("icon")
      ])
      get tools_path
      assert_response :success
      assert_select ".addon-problems li", count: 1, text: /broken.*missing icon/
      assert_select ".addon-card", count: 1, message: "the notice must not add or remove a card"
    end

    test "a clean index renders no notice" do
      get tools_path
      assert_response :success
      assert_select ".addon-problems", count: 0
    end

    test "production never renders the notice, whatever the index holds" do
      Maker::Addons::Source.stub = FakeAddonSource.new(manifests: [ MANIFEST.except("icon") ])
      replacing(Rails, :env, -> { ActiveSupport::EnvironmentInquirer.new("production") }) do
        get tools_path
      end
      assert_response :success
      assert_select ".addon-problems", count: 0
    end
  end
end
