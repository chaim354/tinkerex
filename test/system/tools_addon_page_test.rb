require "application_system_test_case"
require_relative "../support/fake_addon_source"

# WHAT THE TOOLS PAGES DO IN A BROWSER (UX audit G2, G3; 2026-11-02). The request tests see the
# markup: the gallery's toggle and its state (tool_pins_test.rb), the addon page's loading line and
# the hidden failure block beside the mount (addons_controller_test.rb). Only a browser can see them
# change: that a bundle which throws while importing turns into "Could not load NAME" with the error
# folded away, that the loading line goes once a bundle mounts even when the bundle appends rather
# than replaces, and that the card's visible Pin toggle pins, says so, and leaves the rest of the
# card a link to the tool.
#
# A STUBBED SOURCE, NOT test/fixtures/addons: each bundle here exists to misbehave in one way, and
# the shared fixture's bundles are other tests' contracts. Source.stub is a class-level ivar, so the
# server thread Capybara drives reads it too.
class ToolsAddonPageTest < ApplicationSystemTestCase
  BASE = { "icon" => "x", "description" => "A test tool", "api_version" => "1" }.freeze
  BROKEN = BASE.merge("key" => "brokenkit", "title" => "Broken Kit", "entry" => "broken.js").freeze
  APPENDER = BASE.merge("key" => "appendkit", "title" => "Append Kit", "entry" => "append.js").freeze
  WIDGET = BASE.merge("key" => "widgetkit", "title" => "Widget Kit", "entry" => "widget.js").freeze

  setup do
    Maker::Addons::Source.stub = FakeAddonSource.new(
      manifests: [ BROKEN, APPENDER, WIDGET ],
      assets: {
        # Throws during module EVALUATION, so `import()` itself rejects: the case where the bundle
        # never reaches mount() at all.
        "brokenkit/broken.js" => "throw new Error('boom at import')\nexport default {}",
        # APPENDS rather than replacing the mount's contents, unlike every shipped bundle, so only
        # addon_controller.js's own removal can take the loading line away.
        "appendkit/append.js" => <<~JS,
          export default { mount(el) {
            const p = document.createElement("p")
            p.dataset.role = "appended"
            p.textContent = "appended-ok"
            el.appendChild(p)
          } }
        JS
        "widgetkit/widget.js" => <<~JS
          export default { mount(el) { el.innerHTML = '<p data-role="widget">widget-ok</p>' } }
        JS
      }
    )
    sign_in_as("tools-page@example.com")
  end

  teardown { Maker::Addons::Source.reset! }

  test "a bundle that throws while importing says it could not load, the error folded away" do
    visit tools_addon_path("brokenkit")

    assert_selector ".addon-load-failed", text: "Could not load Broken Kit."
    assert_no_selector ".addon-loading"
    assert_no_selector "[data-addon-target=mount] *"
    # The raw message is for whoever reports it: present, but behind a closed <details>.
    assert_selector ".addon-load-failed details:not([open])"
    assert_no_text "boom at import"
    find(".addon-load-failed details summary", text: "Details").click
    assert_selector ".addon-load-failed pre.addon-load-detail", text: "boom at import"
    # Caught, so nothing is left uncaught on the console.
    assert_no_console_errors
  end

  test "the loading line goes once a bundle mounts, even one that appends to the mount" do
    visit tools_addon_path("appendkit")

    assert_selector "[data-role=appended]", text: "appended-ok"
    assert_no_selector ".addon-loading"
    assert_no_selector ".addon-load-failed"
    assert_no_console_errors
  end

  test "the card's Pin toggle pins and unpins, and the rest of the card opens the tool" do
    visit tools_path
    card = find(".addon-card", text: "Widget Kit")
    card.find("button.tool-pin[aria-pressed=false]", text: "Pin to sidebar").click

    assert_selector ".flash", text: "Pinned Widget Kit to the sidebar."
    assert_selector "aside.rail a.rail-tool-pin", text: "Widget Kit"
    card = find(".addon-card", text: "Widget Kit")
    card.find("button.tool-pin[aria-pressed=true]", text: "Pinned to sidebar").click

    assert_selector ".flash", text: "Unpinned Widget Kit from the sidebar."
    assert_no_selector "aside.rail a.rail-tool-pin"
    card = find(".addon-card", text: "Widget Kit")
    assert card.has_selector?("button.tool-pin[aria-pressed=false]", text: "Pin to sidebar")

    # THE STRETCHED TITLE LINK: a click in the middle of the card, away from its title, still opens
    # the tool — the whole card stayed a way in when it stopped being an <a>. (The card itself is
    # clicked: what the browser hits there is the title link's overlay, a descendant, which is the
    # only hit WebDriver accepts as reaching the card.)
    card.click
    assert_current_path tools_addon_path("widgetkit")
    assert_selector "[data-role=widget]", text: "widget-ok"
    assert_no_console_errors
  end
end
