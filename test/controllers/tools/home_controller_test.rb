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

    # Same save/restore-in-teardown shape as Tools::OpenscadControllerTest's setup: `configured?` for
    # both sidecar-backed host addons is a bare ENV presence check (no network probe), so a bogus URL
    # is enough to flip them from "greys out" to "available" without either sidecar ever being called
    # from this file. Needed so "renders a working link for every available addon" actually exercises
    # all three host addons rather than only whichever one needs no configuration (`generators`) —
    # otherwise its loop body runs once, over the one addon whose key was never at risk.
    setup do
      @prior_boxes_url = ENV["BOXES_SIDECAR_URL"]
      @prior_openscad_url = ENV["OPENSCAD_SIDECAR_URL"]
      ENV["BOXES_SIDECAR_URL"] = "http://boxes.invalid"
      ENV["OPENSCAD_SIDECAR_URL"] = "http://openscad.invalid"
    end

    teardown do
      ENV["BOXES_SIDECAR_URL"] = @prior_boxes_url
      ENV["OPENSCAD_SIDECAR_URL"] = @prior_openscad_url
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
      # NOT a regression guard for the inflector bug — that claim does not survive mutation
      # (verified: reverting the view to send("tools_#{addon.key}_path") leaves this test GREEN).
      # All three HOST addons (boxes, generators, openscad) keep keys that inflect cleanly to their
      # own route helper — that is exactly why the old send(...) mechanism worked fine for them, and
      # no amount of forcing them "available" changes that. The driver test above, with its
      # deliberately non-inflecting synthetic key, is what actually pins the fix.
      #
      # What this test DOES check, honestly: with all three host addons forced available (below),
      # the rendered gallery HTML contains a working anchor at each addon's own declared href — an
      # end-to-end smoke test of registration -> controller -> view for the addons this deployment
      # actually ships. That is distinct from test/services/maker/addons/registry_test.rb, which
      # resolves path_for for every REGISTERED addon regardless of availability, but never renders
      # HTML.
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
