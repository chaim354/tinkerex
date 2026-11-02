require "test_helper"
require_relative "../../support/fake_addon_source"

module Web
  # The Tools gallery after PR 4 (spec §8): each card is a surface with the icon and title on one
  # row, the description under it, and the permission line as a quiet footer; an unavailable addon
  # keeps its reason. The count and the link texts are what test/controllers/tools/home_controller_test.rb
  # pins; this asserts the structure around them.
  #
  # STUBS ITS OWN Maker::Addons::Source RATHER THAN RELYING ON AMBIENT MANIFESTS. A plain
  # `get tools_path` on this box (no ADDON_SOURCE_PATH/ADDON_SOURCE_URL set, no stub) renders ZERO
  # cards — Source.current falls through to the HTTP branch, ENV.fetch("ADDON_SOURCE_URL") raises
  # KeyError, and Registry.manifests rescues that to `[]` — confirmed by running this file before
  # adding the stubs below (both assertions failed at "found 0"). test/fixtures/addons/manifests.json
  # is only reached when a test explicitly points ADDON_SOURCE_PATH there (see box_sections_test.rb),
  # and even then its titles are "Fixture Addon"/"Box Generator"/"SDK Fixture", not "Generators". So
  # this file follows home_controller_test.rb's own door — FakeAddonSource via
  # Maker::Addons::Source.stub= — using the same MANIFEST shape (key "widgetkit", title
  # "Generators") that file's "lists registered addons" test already pins.
  class ToolsGalleryTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    MANIFEST = {
      "key" => "widgetkit", "title" => "Generators", "icon" => "✏️",
      "description" => "Parametric 2D drawings", "api_version" => "1", "entry" => "generators.js"
    }.freeze

    setup do
      @user = User.create!(email: "tg-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
    end

    teardown { Maker::Addons::Source.reset! }

    # THE CARD IS A <div> AND ITS TITLE IS THE LINK (2026-11-02): a card that holds a pin <form>
    # cannot itself be an <a>. The link is stretched over the card in CSS, so "the whole card opens
    # the tool" is pages/tools.css's to keep; this pins that the title link is the ONE way in and
    # that it names the tool rather than every word on the card.
    test "an available card has a head row, a description and a permissions footer" do
      Maker::Addons::Source.stub = FakeAddonSource.new(manifests: [
        MANIFEST.merge("permissions" => [ { "name" => "library:write" } ])
      ])
      get tools_path
      assert_response :success
      assert_select ".tools-home .tools-grid div.addon-card .addon-card-head .addon-icon"
      assert_select ".tools-grid div.addon-card .addon-card-head a.addon-title.addon-card-link[href=?]",
                    tools_addon_path("widgetkit"), text: "Generators"
      assert_select ".tools-grid div.addon-card a[href=?]", tools_addon_path("widgetkit"), count: 1
      assert_select ".tools-grid div.addon-card .addon-desc"
      assert_select ".tools-grid div.addon-card .addon-permissions.addon-card-foot", text: /This tool can:/
    end

    test "an unavailable card keeps its reason and its title attribute" do
      Maker::Addons::Source.stub = FakeAddonSource.new(manifests: [
        MANIFEST.merge("min_host" => Maker::Addons::Host::LEVEL + 1)
      ])
      get tools_path
      assert_response :success
      assert_select ".tools-grid div.addon-card.disabled[title] .addon-desc", minimum: 1
    end

    # NO EMOJI IN THE GALLERY, WHATEVER THE MANIFESTS SAY (UX audit G1). test/no_emoji_test.rb reads
    # this repo's source and cannot see a manifest, which is where the three on the cards came from
    # (U+1F4E6, U+270F U+FE0F, U+1F9CA) — so this renders the page over manifests whose icons ARE
    # emoji and reads the RESPONSE. Wider than no_emoji_test's pictograph block on purpose: the
    # pencil is U+270F plus the emoji presentation selector U+FE0F, outside U+1F300-U+1FAFF, so the
    # selector and the joiner (U+200D) count too. The dingbat block itself does NOT: ✓, ✕ and ✎ are
    # typographic marks the shell may draw (design-system.md rule 13), and a guard that fires on the
    # layout's own marks would be switched off rather than read.
    EMOJI = /[\u{1F000}-\u{1FAFF}\u{FE0F}\u{200D}]/

    test "the gallery draws a monogram, never a manifest's emoji icon" do
      Maker::Addons::Source.stub = FakeAddonSource.new(manifests: [
        MANIFEST, # icon U+270F U+FE0F
        MANIFEST.merge("key" => "boxkit", "title" => "Box Generator", "icon" => "\u{1F4E6}"),
        MANIFEST.merge("key" => "scadkit", "title" => "OpenSCAD", "icon" => "\u{1F9CA}",
                       "min_host" => Maker::Addons::Host::LEVEL + 1)
      ])
      get tools_path
      assert_response :success
      assert_select ".addon-card", count: 3, message: "the manifests did not reach the page"
      drawn = response.body.scan(EMOJI).uniq
      assert_empty drawn, "the Tools gallery draws emoji: #{drawn.map { |c| format("U+%04X", c.ord) }.inspect}"
      # The mark is the title's first letter, on the runnable and the greyed card alike.
      assert_equal %w[B G O], css_select(".addon-card .addon-icon").map { |m| m.text.strip }.sort
      assert_select ".addon-card .addon-icon[aria-hidden=true]", count: 3
    end

    test "a title with no letter or digit takes the key's, and failing that the Tools glyph" do
      Maker::Addons::Source.stub = FakeAddonSource.new(manifests: [
        MANIFEST.merge("title" => "--"),
        MANIFEST.merge("key" => "-", "title" => "..")
      ])
      get tools_path
      assert_response :success
      marks = css_select(".addon-card .addon-icon")
      assert_equal "W", marks.first.text.strip, "the key's first letter stands in"
      assert_equal 1, marks.last.css("svg.rail-icon").size, "with neither, the Tools glyph"
    end

    # AN ADDON THAT CANNOT RUN HERE IS NOT A LINK, ON ITS CARD (UX audit G3). Its page answers too
    # (addons_controller_test.rb), but the card must not invite the click in the first place.
    test "an unavailable card is not a link and carries no pin" do
      Maker::Addons::Source.stub = FakeAddonSource.new(manifests: [
        MANIFEST.merge("services" => [ "nosuchsvc" ])
      ])
      get tools_path
      assert_response :success
      assert_select ".addon-card.disabled .addon-desc", text: "Needs the nosuchsvc service, which this server doesn't run"
      assert_select ".addon-card.disabled a", count: 0
      assert_select ".tools-grid a[href=?]", tools_addon_path("widgetkit"), count: 0
      assert_select ".addon-card.disabled form", count: 0
    end
  end
end
