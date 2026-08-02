require "test_helper"

module Tools
  class HomeControllerTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "tools@example.com", password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
    end

    # The registry is process-global. Snapshot it so a test can register a throwaway addon without
    # leaking into the rest of the suite.
    setup { @snapshot = Maker::Addons::Registry.all.map(&:to_h) }

    teardown do
      Maker::Addons::Registry.reset!
      @snapshot.each { |attrs| Maker::Addons::Registry.register(**attrs) }
    end

    test "requires login" do
      reset!
      get tools_path
      assert_redirected_to new_user_session_path
    end

    test "lists registered addons" do
      get tools_path
      assert_response :success
      assert_select ".addon-card", text: /Box Generator/
    end

    test "renders a link for an addon whose key does not inflect to a route helper" do
      # THE DRIVER. `send("tools_#{key}_path")` raises NoMethodError for this key, taking /tools down
      # for every user — which is exactly the class of failure the two inflector traps in
      # config/routes.rb describe. An addon that declares its own path cannot cause it.
      Maker::Addons::Registry.register(
        key: "weird.key", title: "Weird", icon: "?", description: "",
        available: -> { true }, path: ->(_r) { "/tools/weird" }
      )

      get tools_path
      assert_response :success
      assert_select "a.addon-card[href=?]", "/tools/weird"
    end

    test "renders a working link for every available addon" do
      # Characterization, not a driver: asserts the RENDERED href against each addon's own declared
      # path, so a registration whose path proc drifts from its routes fails here rather than 500ing
      # for a user.
      get tools_path
      assert_response :success
      helpers = Rails.application.routes.url_helpers
      Maker::Addons::Registry.all.select(&:available?).each do |addon|
        # The extra `nil` is load-bearing, not decorative: assert_select shifts one value per `?`
        # in the selector for substitution, then shifts THE NEXT value as the equality comparator —
        # a bare (selector, value, message) triple silently reinterprets the message string as a
        # required TEXT-CONTENT match (and fails against the card's actual text). `nil` occupies the
        # comparator slot ("at least one match", the default) so the string that follows lands where
        # it belongs, as the failure message. Verified by mutation: dropping the `nil` here makes
        # this test fail even after the view is fixed.
        assert_select "a.addon-card[href=?]", addon.path_for(helpers), nil,
                      "no gallery link for #{addon.key}"
      end
    end
  end
end
