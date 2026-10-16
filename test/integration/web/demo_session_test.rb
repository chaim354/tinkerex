require "test_helper"

module Web
  # THE PUBLIC DEMO'S ONE CLICK (Tinkerex::Demo; H, 2026-10-14). The sign-in page offers it while
  # there is an account to sign into, POST /demo signs the visitor in with a plain session, and the
  # signed-in shell says where they are on every page. Off -- DEMO_ACCOUNT_EMAIL unset, which is
  # every deployment but the public box -- none of it exists: no button, a 404, not even a log line.
  #
  # The demo account here has a RANDOM password, as the real one does: nothing below may need it.
  class DemoSessionTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze
    SENTENCE = "A shared account that resets every night; nothing you do here is private.".freeze

    setup do
      @prior = ENV.to_h.slice("DEMO_ACCOUNT_EMAIL", "REGISTRATION")
      ENV.delete("DEMO_ACCOUNT_EMAIL")
      # Where a sign-in lands (Recent) reads the library; a fresh share root keeps every leg the same.
      @root = use_fresh_share_library!
      @demo = User.create!(email: "demo@example.com", password: SecureRandom.base58(32),
                           confirmed_at: Time.current, handle: "demo")
    end

    teardown do
      %w[DEMO_ACCOUNT_EMAIL REGISTRATION].each { |k| @prior.key?(k) ? ENV[k] = @prior[k] : ENV.delete(k) }
    end

    def demo_on! = ENV["DEMO_ACCOUNT_EMAIL"] = @demo.email

    def capture_log
      io = StringIO.new
      prior = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(io)
      yield
      io.string
    ensure
      Rails.logger = prior
    end

    test "off, nothing of the demo exists: no button, no sentence, and POST /demo is a quiet 404" do
      get new_user_session_path
      assert_response :success
      assert_select "form[action=?]", demo_session_path, count: 0
      assert_not_includes response.body, SENTENCE

      log = capture_log { post demo_session_path }
      assert_response :not_found
      assert_not_includes log, "DEMO_ACCOUNT_EMAIL", "off is a deployment's choice, not a misconfiguration to warn about"
      get root_path
      assert_response :success, "the sign-in card, not Recent: an account merely carrying the address is not a demo, and nobody was signed in"
      assert_select ".demo-banner", 0
      assert_select ".auth-card form[action=?]", user_session_path
    end

    test "on, the sign-in page offers the demo above the form, says what it is once, and keeps its accent on Log in" do
      demo_on!
      ENV["REGISTRATION"] = "closed"
      get new_user_session_path
      assert_response :success

      assert_select ".auth-card .demo-entry form[action=?][method=?]", demo_session_path, "post" do
        assert_select "button[type=submit]", text: "Try the demo"
      end
      assert_select ".auth-card .demo-entry .auth-hint", text: SENTENCE
      assert_operator response.body.index('class="demo-entry"'), :<, response.body.index(%(action="#{user_session_path}")),
                      "the demo comes before the form a stranger cannot use"
      # ONE SENTENCE, ONCE. With sign-ups closed, users/shared/_links puts the demo where "Sign up"
      # would stand -- on every auth page but this one, whose card already carries it above the form.
      assert_equal 1, response.body.scan(SENTENCE).size
      assert_select "ul.auth-links a[href=?]", new_user_registration_path, count: 0

      # THE ACCENT IS SPENT ONCE: on Log in, as every auth card spends it on its own form's submit
      # (auth_pages_test.rb). The demo button is a plain .btn.
      assert_select ".auth-card .primary", 1
      assert_select ".auth-card input[type=submit][value=?].primary", "Log in"
      assert_select ".demo-entry button.btn:not(.primary)", 1
    end

    test "with sign-ups closed, the other auth pages point a stranger at the demo where Sign up would be" do
      demo_on!
      ENV["REGISTRATION"] = "closed"
      [ new_user_password_path, new_user_confirmation_path, new_user_registration_path ].each do |page|
        get page
        assert_select "ul.auth-links a[href=?]", new_user_session_path, { text: "Try the demo" },
                      "#{page} should point at the demo"
        assert_select "ul.auth-links li", { text: /Try the demo\.\s+#{Regexp.escape(SENTENCE)}/ }, page
        assert_select "ul.auth-links a[href=?]", new_user_registration_path, { count: 0 }, page
      end

      ENV["REGISTRATION"] = "open"
      get new_user_password_path
      assert_select "ul.auth-links a[href=?]", new_user_registration_path, text: "Sign up"
      assert_select "ul.auth-links a", { text: "Try the demo", count: 0 }, "open sign-ups keep their own link"
    end

    test "one click signs the visitor into the demo with a plain session, and the shell says so" do
      demo_on!
      post demo_session_path
      assert_redirected_to root_path
      assert_nil cookies["remember_user_token"].presence, "a plain session: closing the browser ends it"
      assert_equal 1, @demo.reload.sign_in_count, "the demo account is the one signed in"

      follow_redirect!
      assert_response :success
      # Inline at the top of main, where the unreachable banner sits (it is absent here).
      assert_select "main#main > div.demo-banner:first-child", 1
      assert_select ".demo-banner", text: /You're in the shared demo\..*04:00 UTC.*nothing you do here is private/m
    end

    test "the banner is the demo's alone: another account on the same deployment never sees it" do
      demo_on!
      maker = User.create!(email: "maker@example.com", password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: maker.email, password: PASSWORD } }
      get root_path
      assert_response :success
      assert_select ".demo-banner", 0
    end

    test "demo mode on with no account yet is a 404 and a warning for the operator, and no button" do
      ENV["DEMO_ACCOUNT_EMAIL"] = "missing@example.com"
      get new_user_session_path
      assert_select "form[action=?]", demo_session_path, { count: 0 }, "no button while there is nothing to sign into"

      log = capture_log { post demo_session_path }
      assert_response :not_found
      assert_includes log, "DEMO_ACCOUNT_EMAIL"
      assert_includes log, "tinkerex:demo:setup"
    end

    # ON SHARE AND S3 EVERY ACCOUNT INDEXES THE ONE LIBRARY (§8), so a visitor signed into the demo
    # beside another account would be handed that account's files. The door stays shut while any other
    # account exists -- the same condition the nightly reset refuses (Tinkerex::DemoReset) -- and the
    # share root this suite pins is exactly such a library.
    test "while another account shares the library, there is no button and the click is a logged 404" do
      demo_on!
      User.create!(email: "owner@example.com", password: PASSWORD, confirmed_at: Time.current)

      get new_user_session_path
      assert_select "form[action=?]", demo_session_path, { count: 0 }, "no button beside another account's library"

      log = capture_log { post demo_session_path }
      assert_response :not_found
      assert_includes log, "1 other account shares"
      get root_path
      assert_response :success, "the landing, not Recent: nobody was signed in"
      assert_select ".demo-banner", 0
      assert_select ".landing-hero", 1
      assert_select "form[action=?]", demo_session_path, { count: 0 }, "no demo button on the landing either"
    end

    # LOCKABLE MUST NOT BECOME AN OFF SWITCH. The demo address is public; ten wrong passwords at the
    # ordinary sign-in form lock the account for an hour, and Warden would then refuse every click.
    test "a locked demo account still signs in by the click, which unlocks it" do
      demo_on!
      @demo.lock_access!
      assert @demo.reload.access_locked?

      post demo_session_path
      assert_redirected_to root_path
      follow_redirect!
      assert_select ".demo-banner", 1
      assert_not @demo.reload.access_locked?
    end

    # Per IP, in config.action_controller.cache_store (test_helper clears it per test).
    test "the 21st click from one address within a minute is refused and signs nobody in" do
      demo_on!
      20.times do
        post demo_session_path
        assert_redirected_to root_path, "clicks under the limit sign in"
      end

      reset! # a fresh browser behind the same address
      post demo_session_path
      assert_redirected_to new_user_session_path
      assert_match(/too many/i, flash[:alert].to_s)
      get root_path
      assert_response :success, "the landing, not Recent: the refused click signed nobody in"
      assert_select ".demo-banner", 0
      assert_select ".landing-hero", 1
    end
  end
end
