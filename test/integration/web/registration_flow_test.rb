require "test_helper"

module Web
  # WHAT A BRAND-NEW MAKER IS ACTUALLY TOLD AFTER SIGNING UP (slice 0, 2026-09-10).
  #
  # Found by signing up on an empty install and reading the screen, not by reading the controller.
  # Devise set its `signed_up_but_unconfirmed` notice and redirected to `root_path`; root is gated,
  # so Warden bounced to the sign-in page — and the notice was consumed by that INTERMEDIATE
  # request, which nobody sees. What reached the page the user lands on was the failure app's own
  # alert, "You need to sign in or sign up before continuing", telling someone who had just signed
  # up to sign up. The only way to learn the account existed but was unconfirmed was to fail a
  # login.
  #
  # THESE FOLLOW THE REDIRECT CHAIN RATHER THAN ASSERTING ON THE FIRST RESPONSE, because the whole
  # defect lived in the hop between them: a test that stopped at `assert_redirected_to` passed
  # throughout, which is precisely why nothing caught this (§14e — drive the real request).
  class RegistrationFlowTest < ActionDispatch::IntegrationTest
    PASSWORD = "plywood and glue and clamps".freeze

    # THE FIRST ACCOUNT IS THE OWNER (Tinkerex::Registration, 2026-10-13): it is confirmed on the
    # spot, signed in and sent no mail, whatever REGISTRATION says. Every test here is about the
    # SECOND and later accounts — the unconfirmed flow — so one confirmed account exists before
    # each; on an empty database the sign-up under test would be the owner and none of these
    # messages would be sent. registration_mode_test.rb covers the first account.
    setup do
      User.create!(email: "owner@example.test", password: PASSWORD, confirmed_at: Time.current)
    end

    # A REAL DELIVERY METHOD THAT FAILS, rather than a stub on the mailer: the defect is in what
    # happens when the SMTP CONNECTION fails, which is downstream of everything `mail` does, so
    # stubbing the mailer would prove the rescue catches a raise from a place the real failure
    # never comes from. This is the same door Net::SMTP goes through.
    class FailingDelivery
      class << self
        attr_accessor :error
      end
      def initialize(_settings = {}) = nil
      def deliver!(_mail) = raise(self.class.error || Errno::ECONNREFUSED)
    end
    ActionMailer::Base.add_delivery_method(:failing_for_test, FailingDelivery)

    def with_failing_mailer(error)
      previous_method = ActionMailer::Base.delivery_method
      previous_raise  = ActionMailer::Base.raise_delivery_errors
      FailingDelivery.error = error
      ActionMailer::Base.delivery_method = :failing_for_test
      # production's own default, which is what makes this a 500 rather than a silent no-op
      ActionMailer::Base.raise_delivery_errors = true
      yield
    ensure
      ActionMailer::Base.delivery_method = previous_method
      ActionMailer::Base.raise_delivery_errors = previous_raise
      FailingDelivery.error = nil
    end

    def sign_up!(email: "new-maker-#{SecureRandom.hex(4)}@example.test")
      post user_registration_path,
           params: { user: { email:, password: PASSWORD, password_confirmation: PASSWORD } }
      email
    end

    test "a new maker is told an email was sent, on the page they actually land on" do
      email = sign_up!
      assert User.exists?(email:), "the account should exist"

      follow_redirect!
      assert_response :success, "sign-up should land on a page, not another gated redirect"

      body = response.body
      assert_match(/confirmation link has been sent/i, body,
                   "the page the user lands on must say an email was sent; got flash " \
                   "#{flash.to_hash.inspect}")
      assert_no_match(/You need to sign in or sign up before continuing/i, body,
                      "a maker who just signed up must not be told to sign up")
    end

    test "it lands on the sign-in page, so the notice survives a single hop" do
      sign_up!
      assert_redirected_to new_user_session_path
    end

    # --- the self-host case: no mail server ------------------------------------------------
    #
    # Production leaves `raise_delivery_errors` at the framework default (true) and ships no
    # `smtp_settings`, so a self-hosted box with no mail server raised Errno::ECONNREFUSED from
    # localhost:25 and rendered a 500 — with the user already COMMITTED behind it, because Devise
    # mails from an after_commit. Retrying then answered "email has already been taken": a
    # lockout with no stated way out.

    test "a mail server that refuses the connection does not 500, and says what happened" do
      email = nil
      with_failing_mailer(Errno::ECONNREFUSED) { email = sign_up! }

      assert_response :redirect, "a delivery failure must not render a 500"
      assert User.exists?(email:),
             "the account is committed before the mail is attempted — the message must own that"
      follow_redirect!
      assert_match(/account was created/i, response.body)
      assert_match(/confirmation email could not be sent/i, response.body)
      # The link's HREF, not its text: the page escapes the apostrophe to `&#39;`, so a regex over
      # the raw body for "Didn't receive…" can never match what is actually rendered.
      assert_includes response.body, new_user_confirmation_path,
                      "the page must offer the resend link the message points at"
    end

    test "a bug in a mailer template still 500s rather than being laundered into a mail notice" do
      with_failing_mailer(NoMethodError.new("undefined method `oops'")) do
        assert_raises(NoMethodError) { sign_up! }
      end
    end
  end
end
