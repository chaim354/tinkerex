require "test_helper"
require "support/public_fixture"

module Web
  # THE FRONT DOOR, SECOND PASS (2026-10-16). Signed out, `/` has two answers and DEMO MODE picks:
  # on the public demo's box (DEMO_ACCOUNT_EMAIL set) it is the marketing landing -- the pitch, a wall
  # of twelve of the app's own renders, how it works, four features, Try the demo as its one accent;
  # anywhere else it is the plain sign-in card, because a self-hosted box has nobody to pitch to.
  # /users/sign_in is the plain card in both. Signed in, `/` is Recent. config/routes.rb declares
  # three roots in an order that matters; these are what go red if it changes.
  class LandingTest < ActionDispatch::IntegrationTest
    include PublicFixture # make_owner!, sign_in_as

    INSTALL_URL = Tinkerex::Landing::INSTALL_URL
    SOURCE_URL = Tinkerex::Landing::SOURCE_URL

    setup do
      # Recent (the signed-in `/`) reads the library; a fresh share root keeps every leg the same.
      @root = use_fresh_share_library!
      @prior_demo = ENV["DEMO_ACCOUNT_EMAIL"]
      ENV.delete("DEMO_ACCOUNT_EMAIL")
    end

    teardown do
      @prior_demo.nil? ? ENV.delete("DEMO_ACCOUNT_EMAIL") : ENV["DEMO_ACCOUNT_EMAIL"] = @prior_demo
    end

    # The only account, so on share and s3 no other library sharer closes the demo's door
    # (Tinkerex::Demo.available?).
    def demo_on!(account: true)
      ENV["DEMO_ACCOUNT_EMAIL"] = "demo@example.com"
      return unless account

      User.create!(email: "demo@example.com", password: SecureRandom.base58(32),
                   confirmed_at: Time.current, handle: "demo")
    end

    test "demo mode off, / is the plain sign-in card and nothing of the landing" do
      get "/"
      assert_response :success
      assert_select "main#main.container.auth-main", 1
      assert_select ".auth-card .brand .brand-name", text: "Tinkerex"
      assert_select ".auth-card form[action=?] input[name='user[email]']", user_session_path
      assert_select ".landing", 0
    end

    test "demo mode on, / is the landing: nav, pitch, the twelve-tile wall, how it works, four features" do
      demo_on!
      get "/"
      assert_response :success

      assert_select "main#main.container.landing-main", 1
      assert_select ".landing-nav .brand .brand-name", text: "Tinkerex"
      assert_select ".landing-nav a[href=?]", INSTALL_URL, text: "Install"
      assert_select ".landing-nav a[href=?]", SOURCE_URL, text: "Source"
      assert_select ".landing-nav a[href=?]", new_user_session_path, text: "Log in"
      assert_select ".landing-hero h1", text: "Every file your workshop makes, previewed."
      # THE WALL IS THE APP'S OWN RENDERS (Tinkerex::Landing): one tile per TILES entry, each served
      # from app/assets/images/landing/wall with its alt text -- the only picture above the fold.
      assert_select ".landing-wall li", Tinkerex::Landing::TILES.size
      Tinkerex::Landing::TILES.each do |tile|
        assert_select ".landing-wall img[src^=?][alt=?]", "/assets/#{tile.asset.delete_suffix('.png')}-", tile.alt
      end
      assert_select ".landing-wall-figure figcaption", text: /one maker's laser-cut board-game set/
      assert_select ".landing-steps ol > li", 3
      assert_select ".landing-feature", 4
      assert_select ".landing-feature img[loading=lazy][width='1120'][height='700']", 4
      assert_select ".landing-feature img:not([alt])", 0
      assert_select ".landing-own li", 4
      assert_select ".landing-footer a[href=?]", new_user_session_path
      # The visitor's shell: no rail, no public header, and no sign-in form -- Log in is a link.
      assert_select "aside.rail", 0
      assert_select "header.public-header", 0
      assert_select ".auth-card", 0
      # template_hygiene_test.rb's sweep is signed in and never reaches this page (its
      # UNSWEPT_TEMPLATES names this test), so the check that sweep would make is made here: an ERB
      # comment ending at a quoted `%>` prints its own prose and leaks the delimiter (§14d).
      assert_not_includes response.body, "<%", "the landing leaked an ERB opener"
      assert_not_includes response.body, "%>", "the landing leaked an ERB closer"
    end

    # THE ACCENT IS SPENT ONCE (design-system.md rule 13), on the action this page exists for.
    test "the accent is Try the demo while the demo is available" do
      demo_on!
      get "/"
      assert_select "main .primary", 1
      assert_select ".landing-hero form[action=?] button.btn.primary", demo_session_path, text: "Try the demo"
      assert_select ".landing-hero a.btn:not(.primary)[href=?]", INSTALL_URL, text: "Install it yourself"
      assert_select ".landing-hint", text: "No sign-up. A shared account that resets every night."
      assert_select ".landing-closing form[action=?] button.btn:not(.primary)", demo_session_path
    end

    # Mid-reset, or before tinkerex:demo:setup, there is no account and POST /demo answers 404, so
    # there is no button -- and the page still spends its accent exactly once, on Install.
    test "with no demo account to sign into, Install takes the accent and no demo button renders" do
      demo_on!(account: false)
      get "/"
      assert_response :success
      assert_select "form[action=?]", demo_session_path, 0
      assert_select ".landing-hint", 0
      assert_select "main .primary", 1
      assert_select ".landing-hero a.btn.primary[href=?]", INSTALL_URL
    end

    test "the sign-in page is the plain card in both modes" do
      get new_user_session_path
      assert_select ".auth-card .brand .brand-name", text: "Tinkerex"
      assert_select ".landing", 0

      demo_on!
      get new_user_session_path
      assert_select "main#main.container.auth-main", 1
      assert_select ".auth-card form[action=?]", user_session_path
      assert_select ".landing", 0
    end

    test "signed in, / is Recent in both modes" do
      sign_in_as(make_owner!(handle: "ada"))
      get "/"
      assert_select ".page-head h1", text: "Recent"

      ENV["DEMO_ACCOUNT_EMAIL"] = "demo@example.com"
      get "/"
      assert_select ".page-head h1", text: "Recent"
      assert_select ".landing", 0
    end

    test "the landing names the product for a crawler and a tab" do
      demo_on!
      get "/"
      assert_select "title", text: /Tinkerex/
      assert_select "head meta[name='description'][content*='Tinkerex']", 1
    end
  end
end
