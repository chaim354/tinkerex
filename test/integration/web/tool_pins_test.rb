require "test_helper"
require_relative "../../support/fake_addon_source"

module Web
  # ANY TOOL PINS TO THE SIDEBAR, BY ITS CARD'S TOGGLE OR A RIGHT CLICK (2026-10-22, the toggle
  # 2026-11-02; Maker::ToolPins, Tools::PinsController, toolmenu_controller.js). The calculator's own
  # pin is calculator_shell_test.rb's; this is the addons: what the gallery offers, what the door refuses, what the rail draws and lights, and that
  # the rail still never reads the addon registry. The menu opening on a right click, which only a
  # browser can see, is test/system/tool_pins_test.rb's.
  class ToolPinsTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    READY = { "key" => "widgetkit", "title" => "Widget Kit", "icon" => "x", "description" => "Draws widgets",
              "api_version" => "1", "entry" => "widgetkit.js" }.freeze
    # Greyed out: it names a service this server has no URL for (Addon#unavailable_reason).
    GREYED = { "key" => "needsvc", "title" => "Needs Service", "icon" => "x", "description" => "Cannot run here",
               "api_version" => "1", "entry" => "needsvc.js", "services" => [ "nosuchsvc" ] }.freeze

    # The house stub helper (new_menu_test.rb carries the same body; Minitest 6 has no Object#stub).
    def replacing(owner, name, replacement)
      mod = owner.singleton_class
      own = mod.instance_methods(false).include?(name)
      original = mod.instance_method(name)
      mod.define_method(name, &replacement)
      yield
    ensure
      own ? mod.define_method(name, original) : mod.remove_method(name)
    end

    # Counts manifest fetches, so "the rail did not read the registry" is a zero that is known to
    # be counting (the pin itself reads it, and must show up here).
    def counting_registry_reads
      calls = 0
      real = Maker::Addons::Registry.method(:manifests)
      replacing(Maker::Addons::Registry, :manifests, -> { calls += 1; real.call }) { yield -> { calls } }
    end

    setup do
      @prior_cache = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
      @source = FakeAddonSource.new(manifests: [ READY, GREYED ], assets: { "widgetkit/widgetkit.js" => "export default { mount() {} }" })
      Maker::Addons::Source.stub = @source
      # A per-test email: on the chunk_remote leg a first library touch provisions a remote library,
      # whose database does not roll back (addons_controller_test.rb says why).
      @user = User.create!(email: "pins-#{SecureRandom.hex(4)}@example.com", password: PASSWORD,
                           confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
    end

    teardown do
      Rails.cache = @prior_cache
      Maker::Addons::Source.reset!
    end

    test "every runnable card carries the right-click pin; a greyed one carries none" do
      get tools_path
      assert_select "div.addon-card[data-action=?][data-tool-pin-url=?][data-tool-pinned=false][data-tool-name=?]",
                    "contextmenu->toolmenu#open", tools_pin_path("widgetkit"), "Widget Kit" do
        assert_select "a.addon-card-link[href=?]", tools_addon_path("widgetkit"), text: "Widget Kit"
      end
      assert_select ".addon-card.disabled", 1
      assert_select ".addon-card.disabled[data-tool-pin-url]", 0
      # The gallery and its cards share ONE menu controller.
      assert_select "main [data-controller=toolmenu] .addon-card:not(.disabled)", 1
    end

    # PINNING YOU CAN SEE (UX audit G2): the sentence that explained the right click is gone, and
    # every runnable card, the calculator's included, carries a toggle posting to the same door.
    # Its state is the WORD and `aria-pressed` together — never the ink fill alone — and the button
    # is described by the tool's title, since every card's button says the same thing.
    test "every runnable card carries a visible pin toggle that says whether it is pinned" do
      get tools_path
      assert_select "main .tools-pin-hint", 0
      assert_select "main", text: /Right-click a tool/, count: 0

      card = css_select("div.addon-card:not(.disabled)").first
      toggle = card.css("form.tool-pin-form[action='#{tools_pin_path("widgetkit")}'] button.tool-pin").first
      assert toggle, "the runnable card has no pin toggle"
      assert_equal "false", toggle["aria-pressed"]
      assert_equal "Pin to sidebar", toggle.text.strip
      assert_equal card.css("a.addon-card-link").first["id"], toggle["aria-describedby"],
                   "the toggle is not described by the tool's title"
      assert_empty card.css("form.tool-pin-form input[name=_method]"), "pinning is a POST"
      assert_select ".addon-card.disabled .tool-pin", 0
      assert_select "#calculator .calculator-card-actions form.tool-pin-form[action=?] button.tool-pin[aria-pressed=false][aria-describedby=tool-title-calculator]",
                    tools_pin_path("calculator"), text: "Pin to sidebar"

      post tools_pin_path("widgetkit"), headers: { "Referer" => tools_url }
      follow_redirect!
      card = css_select("div.addon-card:not(.disabled)").first
      toggle = card.css("button.tool-pin").first
      assert_equal "true", toggle["aria-pressed"]
      assert_equal "Pinned to sidebar", toggle.text.strip
      assert_equal "delete", card.css("form.tool-pin-form input[name=_method]").first&.[]("value"),
                   "a pinned card's toggle unpins"
      assert_match(/Unpin Widget Kit/, toggle["title"])
    end

    test "pinning an addon puts a link to it under Tools on every page, by the title it had" do
      post tools_pin_path("widgetkit"), headers: { "Referer" => tools_url }
      assert_redirected_to tools_url
      assert_equal "Pinned Widget Kit to the sidebar.", flash[:notice]
      assert_equal [ { "key" => "widgetkit", "title" => "Widget Kit" } ], @user.reload.pinned_tools

      [ root_path, files_path, tools_path ].each do |path|
        get path
        assert_select "aside.rail .rail-nav--foot[data-controller=toolmenu] a.rail-tool-pin[href=?][title=?]",
                      tools_addon_path("widgetkit"), "Widget Kit", { count: 1 }, path
        assert_select "aside.rail a.rail-tool-pin .rail-label", "Widget Kit"
        # The rail's Unpin is the same right click.
        assert_select "aside.rail a.rail-tool-pin[data-action=?][data-tool-pin-url=?][data-tool-pinned=true]",
                      "contextmenu->toolmenu#open", tools_pin_path("widgetkit")
      end
      foot = css_select("aside.rail .rail-nav--foot li a").map { |a| a["title"] }
      assert_equal foot.index("Tools") + 1, foot.index("Widget Kit"), "pinned tools sit under Tools"

      get tools_path
      assert_select "div.addon-card[data-tool-pin-url=?][data-tool-pinned=true]", tools_pin_path("widgetkit")
    end

    test "pinning twice keeps one pin; tools stay in the order they were pinned" do
      post tools_pin_path("widgetkit")
      post tools_pin_path("calculator")
      post tools_pin_path("widgetkit")
      # The COLUMN, not the reader: the reader also drops a duplicate key, so asserting through it
      # stays green with the write's own guard gone.
      assert_equal [ { "key" => "widgetkit", "title" => "Widget Kit" }, { "key" => "calculator" } ],
                   @user.reload.pinned_tools

      get root_path
      foot = css_select("aside.rail .rail-nav--foot li a").map { |a| a["class"] }
      assert_operator foot.index { |c| c.include?("rail-tool-pin") }, :<, foot.index { |c| c.include?("rail-calculator") }
    end

    test "a greyed-out addon and an unknown key are refused, and nothing is pinned" do
      [ "needsvc", "nosuchtool" ].each do |key|
        post tools_pin_path(key), headers: { "Referer" => tools_url }
        assert_redirected_to tools_url
        assert_equal "That tool can't be pinned here.", flash[:alert], key
      end
      assert_equal [], @user.reload.pinned_tools
    end

    test "a pinned addon's page lights its own link, and Tools lights for it in the icon rail and the tab bar" do
      post tools_pin_path("widgetkit")
      get tools_addon_path("widgetkit")
      assert_response :success
      assert_select "aside.rail a.rail-tool-pin[aria-current=page]", 1
      assert_select "aside.rail [aria-current='page']", 1
      # Collapsed, the pinned link hides (shell.css), so its family link wears the mark instead.
      assert_select "aside.rail a.rail-link.rail-family-lit[title=Tools]", 1
      assert_select "nav.tabbar a.tabbar-link[aria-current=page]", text: "Tools"

      get tools_path # the gallery itself is still Tools
      assert_select "aside.rail a[title=Tools][aria-current=page]", 1
      assert_select "aside.rail a.rail-tool-pin[aria-current]", 0
    end

    test "an addon that is not pinned lights Tools on its page, as before" do
      get tools_addon_path("widgetkit")
      assert_select "aside.rail a[title=Tools][aria-current=page]", 1
      assert_select "aside.rail .rail-family-lit", 0
    end

    # THE LAYOUT NEVER READS THE ADDON REGISTRY (docs/invariants/addons.md), pinned addons included:
    # the rail draws from the user row. Counted, with the pin itself as the proof the count is live.
    test "the rail draws a pinned addon without reading the registry; pinning reads it" do
      counting_registry_reads do |calls|
        post tools_pin_path("widgetkit")
        assert_operator calls.call, :>=, 1, "pinning must ask the registry whether the tool is real"

        before = calls.call
        get root_path
        get files_path
        assert_select "aside.rail a.rail-tool-pin", 1
        assert_equal before, calls.call, "a page render read the addon registry"
      end
    end

    # A PIN OUTLIVES ITS ADDON, AND UNPINNING NEVER ASKS THE REGISTRY, so a tool the source stopped
    # serving (or a source that is down) can still be taken out of the rail.
    test "an addon the source stopped serving stays pinned by its old title and can still be unpinned" do
      post tools_pin_path("widgetkit")
      Maker::Addons::Source.stub = FakeAddonSource.new(manifests: [])
      Rails.cache.clear

      get root_path
      assert_select "aside.rail a.rail-tool-pin[title=?]", "Widget Kit"

      counting_registry_reads do |calls|
        delete tools_pin_path("widgetkit"), headers: { "Referer" => root_url }
        assert_equal 0, calls.call, "unpinning read the registry"
      end
      assert_redirected_to root_url
      assert_equal "Unpinned Widget Kit from the sidebar.", flash[:notice]
      assert_equal [], @user.reload.pinned_tools
      get root_path
      assert_select "aside.rail a.rail-tool-pin", 0
    end

    test "unpinning what is not pinned changes nothing and still answers" do
      delete tools_pin_path("widgetkit")
      assert_redirected_to tools_path
      assert_equal [], @user.reload.pinned_tools
    end

    test "a junk entry in the column is skipped, never raised on in the layout" do
      @user.update_column(:pinned_tools, [ "widgetkit", { "key" => 5 }, { "title" => "No key" }, {},
                                           { "key" => "widgetkit", "title" => "Widget Kit" },
                                           { "key" => "widgetkit", "title" => "Duplicate" } ])
      get root_path
      assert_response :success
      assert_select "aside.rail a.rail-tool-pin", 1
      assert_select "aside.rail a.rail-tool-pin[title=?]", "Widget Kit"

      # A write rewrites the column from what was readable, so the junk goes with it.
      post tools_pin_path("calculator")
      assert_equal [ { "key" => "widgetkit", "title" => "Widget Kit" }, { "key" => "calculator" } ],
                   @user.reload.pinned_tools
    end

    test "pins are per user" do
      post tools_pin_path("widgetkit")
      other = User.create!(email: "pins-other-#{SecureRandom.hex(4)}@example.com", password: PASSWORD,
                           confirmed_at: Time.current)
      delete destroy_user_session_path
      sign_in_web!(other, password: PASSWORD)
      get root_path
      assert_select "aside.rail a.rail-tool-pin", 0
    end

    test "signed out, the pin door goes to sign-in" do
      reset!
      post tools_pin_path("widgetkit")
      assert_redirected_to new_user_session_path
      delete tools_pin_path("widgetkit")
      assert_redirected_to new_user_session_path
    end
  end
end
