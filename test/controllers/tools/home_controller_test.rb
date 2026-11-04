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
    # republished bundle that quietly starts asking for more shows up on the card, in a deployment
    # where publishing the bundle IS the deploy and Rails is never rebuilt.
    test "a card lists the permissions its manifest declares, by label" do
      Maker::Addons::Source.stub = FakeAddonSource.new(manifests: [
        MANIFEST.merge("permissions" => [ { "name" => "library:write" }, { "name" => "service:boxes" } ])
      ])
      get tools_path
      assert_response :success
      assert_select ".addon-permissions", text: /Write files to your library/
      assert_select ".addon-permissions", text: /Call the boxes service/
    end

    test "a card with no declared permissions renders no permission list at all" do
      get tools_path
      assert_response :success
      assert_select ".addon-permissions", count: 0
    end

    # ---- the gallery in sections ----------------------------------------------------------------

    def manifest(key, title, **extra) = MANIFEST.merge("key" => key, "title" => title, **extra)

    # The add-on sections the page draws, in order: each `.tools-section` AFTER the built-in one,
    # read as [heading, [card titles]].
    def addon_sections
      css_select(".tools-home .tools-section").drop(1).map do |section|
        [ section.css(".tools-section-head").text.strip, section.css(".addon-card .addon-title").map { |t| t.text.strip } ]
      end
    end

    # FOUR SECTIONS IN A FIXED ORDER, EACH DRAWN ONLY WHEN POPULATED. The manifests are listed in
    # the reverse of the order the page must draw, so source order and the spec's order disagree.
    test "the gallery groups add-ons by category, in a fixed order, drawing only populated sections" do
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
                     [ "Look inside a file", [ "G-code Inspector", "Model Stats" ] ],
                     [ "Calculate and look up", [ "Fasteners" ] ],
                     [ "Other", [ "Bare Tool" ] ] ], addon_sections
      # EVERY CARD IS STILL `.addon-card`, so the count the test above pins keeps meaning what it says.
      assert_select ".addon-card", count: 5
    end

    test "an empty section is not drawn, and a greyed-out tool stays in its section" do
      Maker::Addons::Source.stub = FakeAddonSource.new(manifests: [
        manifest("gears", "Gears", "category" => "generate"),
        manifest("stats", "Model Stats", "category" => "inspect", "min_host" => Maker::Addons::Host::LEVEL + 1)
      ])
      get tools_path
      assert_response :success
      assert_equal [ [ "Make a file", [ "Gears" ] ], [ "Look inside a file", [ "Model Stats" ] ] ], addon_sections
      assert_select ".tools-section-head", text: "Other", count: 0
      assert_select ".tools-section-head", text: "Calculate and look up", count: 0
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
