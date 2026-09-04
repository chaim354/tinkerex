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
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
    end

    teardown { Maker::Addons::Source.reset! }

    test "an available card has a head row, a description and a permissions footer" do
      Maker::Addons::Source.stub = FakeAddonSource.new(manifests: [
        MANIFEST.merge("permissions" => [ { "name" => "library:write" } ])
      ])
      get tools_path
      assert_response :success
      assert_select ".tools-grid a.addon-card .addon-card-head .addon-icon"
      assert_select ".tools-grid a.addon-card .addon-card-head .addon-title", text: "Generators"
      assert_select ".tools-grid a.addon-card .addon-desc"
      assert_select ".tools-grid a.addon-card .addon-permissions.addon-card-foot", text: /This tool can:/
    end

    test "an unavailable card keeps its reason and its title attribute" do
      Maker::Addons::Source.stub = FakeAddonSource.new(manifests: [
        MANIFEST.merge("min_host" => Maker::Addons::Host::LEVEL + 1)
      ])
      get tools_path
      assert_response :success
      assert_select ".tools-grid div.addon-card.disabled[title] .addon-desc", minimum: 1
    end
  end
end
