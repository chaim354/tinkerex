require "test_helper"
require "support/public_fixture"

module Web
  # THE FRONT DOOR (the landing, 2026-10-14). Signed out, `/` is the landing: the pitch, three
  # screenshots, the install link and the auth card, with no redirect -- a stranger typing
  # tinkerex.com met a bare sign-in form before, with nothing on it saying what the thing was.
  # Signed in, `/` is still Recent. Devise's `unauthenticated` constraint picks (config/routes.rb),
  # and it is declared BEFORE `root` because routes match in declaration order: the first test here
  # is what goes red if the two lines are ever swapped.
  class LandingTest < ActionDispatch::IntegrationTest
    include PublicFixture # make_owner!, sign_in_as

    INSTALL_URL = "https://github.com/chaim354/tinkerex/blob/main/docs/INSTALL.md".freeze
    SOURCE_URL = "https://github.com/chaim354/tinkerex".freeze

    setup do
      # Recent (the signed-in `/`) reads the library; a fresh share root keeps every leg the same.
      @root = use_fresh_share_library!
      @prior_demo = ENV["DEMO_ACCOUNT_EMAIL"]
      ENV.delete("DEMO_ACCOUNT_EMAIL")
    end

    teardown do
      @prior_demo.nil? ? ENV.delete("DEMO_ACCOUNT_EMAIL") : ENV["DEMO_ACCOUNT_EMAIL"] = @prior_demo
    end

    test "signed out, / is the landing and not a redirect: the pitch, three screenshots, the links and the card" do
      get "/"
      assert_response :success

      assert_select "main#main.container.landing-main", 1
      assert_select ".landing-hero .brand-name", text: "Tinkerex"
      assert_select ".landing-hero h1", 1
      assert_select ".landing-hero a.btn[href=?]", INSTALL_URL, text: "Install it yourself"
      assert_select ".landing-hero a[href=?]", SOURCE_URL
      # Three screenshots, each served by the asset pipeline from app/assets/images/landing and
      # each with alt text: a screenshot a screen reader cannot name is decoration, and these carry
      # the only picture of the product a stranger gets.
      assert_select ".landing-shots img[src^='/assets/landing/']", 3
      assert_select ".landing-shots img:not([alt])", 0
      assert_select ".landing-shots img[alt='']", 0
      assert_select ".landing-shots figcaption", 3
      # The same auth card every Devise page renders (auth_pages_test.rb pins its fields).
      assert_select ".landing-auth .auth-card form[action=?] input[name='user[email]']", user_session_path
      # The visitor's shell: no rail, no shell class, no public header (public_explore_test.rb).
      assert_select "aside.rail", 0
      assert_select "body.app-shell", 0
      assert_select "header.public-header", 0
    end

    test "the sign-in page is the same landing" do
      get new_user_session_path
      assert_response :success
      assert_select "main#main.container.landing-main", 1
      assert_select ".landing-hero h1", 1
      assert_select ".landing-shots img", 3
      assert_select ".auth-card form[action=?]", user_session_path
    end

    test "signed in, / is Recent, not the landing" do
      sign_in_as(make_owner!(handle: "ada"))
      get "/"
      assert_response :success
      assert_select ".page-head h1", text: "Recent"
      assert_select ".landing-hero", 0
      assert_select ".landing-shots", 0
      assert_select "body.app-shell", 1
    end

    # THE ACCENT IS SPENT ONCE, ON LOG IN (design-system.md rule 13). The landing adds two links and
    # a button beside the card; none of them is `.primary`. A hero whose install button were accent
    # would put two strong signals on the one page a stranger has to read.
    test "the accent stays on Log in: the hero's controls are quiet" do
      get "/"
      assert_select "main .primary", 1
      assert_select "main input[type=submit][value=?].primary", "Log in"
      assert_select ".landing-hero .primary", 0
      assert_select ".landing-hero .btn", 1
    end

    # The demo button is the card's (demo_session_test.rb owns its rules); this pins only that the
    # landing at `/` shows and hides it with the demo, since `/` and /users/sign_in are now one view.
    test "the demo button is on the landing exactly while the demo is available" do
      get "/"
      assert_select ".landing-auth .demo-entry", 0

      demo = User.create!(email: "demo@example.com", password: SecureRandom.base58(32),
                          confirmed_at: Time.current, handle: "demo")
      ENV["DEMO_ACCOUNT_EMAIL"] = demo.email
      get "/"
      assert_response :success
      assert_select ".landing-auth .demo-entry form[action=?]", demo_session_path, 1
      assert_select ".landing-hero form[action=?]", demo_session_path, 0
    end

    test "the landing names the product for a crawler and a tab" do
      get "/"
      assert_select "title", text: /Tinkerex/
      assert_select "head meta[name='description'][content*='Tinkerex']", 1
    end
  end
end
