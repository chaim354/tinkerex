require "test_helper"

module Web
  # FIRST RUN AND RECOVERY, AS A VISITOR MEETS THEM (UX audit F5).
  #
  # A fresh install with no account showed a sign-in form for an account that did not exist, with a
  # 12px "Sign up" link as the only way forward; the sign-up and closed pages told strangers to set
  # REGISTRATION=open (refused at boot on share and s3), to run `bin/rails tinkerex:owner` and to set
  # SMTP_ADDRESS; and the password-reset page promised a mail that a server with no SMTP never sends.
  #
  # The first-run card is the EXISTING first-account door (Tinkerex::Registration, read and not
  # changed): these tests drive it through the card's own form and assert the account it makes is the
  # confirmed owner and admin, so the card cannot drift from the door it advertises.
  class AuthFirstRunTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    # What a visitor must never be shown: the operator's knobs, which live in docs/INSTALL.md.
    OPERATOR_WORDS = [ "REGISTRATION", "tinkerex:owner", "SMTP_ADDRESS", "bin/rails" ].freeze

    def replacing(owner, name, replacement)
      mod = owner.singleton_class
      own = mod.instance_methods(false).include?(name)
      original = mod.instance_method(name)
      mod.define_method(name, &replacement)
      yield
    ensure
      own ? mod.define_method(name, original) : mod.remove_method(name)
    end

    def without_mail(&) = replacing(Tinkerex::MailSettings, :deliverable?, ->(*, **) { false }, &)

    def assert_no_operator_words(page)
      # assert_not, not assert_not_includes: the latter prints the whole page on a failure.
      OPERATOR_WORDS.each { |word| assert_not response.body.include?(word), "#{page} shows #{word} to a visitor" }
    end

    setup do
      @prior = ENV.to_h.slice("REGISTRATION", "DEMO_ACCOUNT_EMAIL")
      # Demo mode off: with it on, a signed-out `/` is the landing (design-system.md rule 15).
      ENV.delete("DEMO_ACCOUNT_EMAIL")
      User.delete_all
    end

    teardown { %w[REGISTRATION DEMO_ACCOUNT_EMAIL].each { |k| @prior.key?(k) ? ENV[k] = @prior[k] : ENV.delete(k) } }

    # ============================================================ the first-run card

    test "with no account, the sign-in page and / show the owner card instead of a sign-in form" do
      [ new_user_session_path, root_path ].each do |path|
        get path
        assert_response :success
        assert_select "title", "Create the owner account — Tinkerex"
        assert_select "h1", { count: 1, text: "Create the owner account" }, path
        assert_select ".auth-card form[action=?]", user_registration_path, { count: 1 }, path
        assert_select "form[action=?]", user_session_path, { count: 0 }, "#{path} offers a sign-in form for nobody"
        assert_select ".auth-card", /first account.*owner/m
        assert_select "input[type=submit][value=?].primary", "Create the owner account"
        assert_no_operator_words(path)
      end
    end

    test "the card's form makes the confirmed owner and admin, signed in" do
      get new_user_session_path
      assert_select ".auth-card form[action=?]", user_registration_path do
        %w[user[email] user[password] user[password_confirmation]].each do |name|
          assert_select "input[name=?]", name
        end
      end

      post user_registration_path, params: { user: { email: "owner@example.com", password: PASSWORD,
                                                     password_confirmation: PASSWORD } }

      owner = User.find_by!(email: "owner@example.com")
      assert owner.confirmed?
      assert owner.admin?
      assert_equal owner.id, controller.current_user&.id, "the owner is signed straight in"
    end

    test "a refused first sign-up shows the owner card again with the error and the typed email" do
      post user_registration_path, params: { user: { email: "owner@example.com", password: "short",
                                                     password_confirmation: "short" } }

      assert_response :unprocessable_entity
      assert_select "h1", "Create the owner account"
      assert_select ".auth-card .form-errors", /Password is too short/
      assert_select "input[name=?][value=?]", "user[email]", "owner@example.com"
      assert_select "#error_explanation", 0
    end

    test "once an account exists the sign-in page is the sign-in form again" do
      User.create!(email: "owner@example.com", password: PASSWORD, confirmed_at: Time.current)
      get new_user_session_path
      assert_select "h1", "Sign in"
      assert_select "form[action=?]", user_session_path, 1
      assert_select "h1", { text: "Create the owner account", count: 0 }
    end

    # ============================================================ nothing operational for a visitor

    # MUTATION-CHECKED: putting `<code>REGISTRATION=open</code>` back into registrations/closed reddens
    # this (the run's output is in the UX-audit T6 report).
    test "the closed page names who adds accounts and nothing an operator types" do
      ENV["REGISTRATION"] = "closed"
      User.create!(email: "owner@example.com", password: PASSWORD, confirmed_at: Time.current)

      get new_user_registration_path

      assert_response :forbidden
      assert_select "h1", "Sign-ups are closed"
      assert_select ".auth-card p", /administrator adds accounts/
      assert_no_operator_words("the closed page")
    end

    test "the sign-up page's notes name no operator setting, with mail or without" do
      User.create!(email: "owner@example.com", password: PASSWORD, confirmed_at: Time.current)
      ENV["REGISTRATION"] = "open"

      get new_user_registration_path
      assert_select "h1", "Sign up"
      assert_no_operator_words("sign-up")

      without_mail do
        get new_user_registration_path
        assert_select ".auth-hint", /can't send email yet.*administrator to add your account/m
        assert_no_operator_words("sign-up with no mail")
      end
    end

    # ============================================================ recovery

    test "with no mail, the reset page says no link will arrive and names the admin reset" do
      User.create!(email: "owner@example.com", password: PASSWORD, confirmed_at: Time.current)

      get new_user_password_path
      assert_select ".auth-hint", { text: /can't send email/, count: 0 }, "a server that sends mail promises nothing extra"

      without_mail do
        get new_user_password_path
        assert_select ".auth-hint", /can't send email yet, so no reset link will arrive/
        assert_select ".auth-hint", /administrator can set a new password for you under Settings → Users/
        assert_no_operator_words("the reset page")

        get new_user_confirmation_path
        assert_select ".auth-hint", /can't send email yet/
        assert_select ".auth-hint", /Settings → Users/
        assert_no_operator_words("the resend page")
      end
    end
  end
end
