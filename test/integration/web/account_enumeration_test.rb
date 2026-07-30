require "test_helper"

module Web
  # An unregistered email must be indistinguishable from a registered one.
  #
  # Without config.paranoid, Devise says "not found" for an unknown address and "invalid
  # password" for a known one — which turns both login and password reset into an oracle for
  # whether an address has an account here. That is the input to credential stuffing and to
  # targeted phishing, and RESET is the cleaner oracle of the two because it needs no password
  # guess at all: just POST an address and read the answer.
  class AccountEnumerationTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      User.create!(email: "known@example.com", password: PASSWORD, confirmed_at: Time.current)
    end

    test "a reset request for an unknown email answers exactly like a known one" do
      post user_password_path, params: { user: { email: "known@example.com" } }
      known_status = response.status
      known_location = response.location
      known_flash = flash[:notice].to_s

      post user_password_path, params: { user: { email: "nobody@example.com" } }

      assert_equal known_status, response.status
      assert_equal known_location, response.location
      assert_equal known_flash, flash[:notice].to_s,
                   "the response must not reveal whether the address has an account"
    end

    test "a reset request for an unknown email still sends no mail" do
      # Indistinguishable to the requester, but we must not mail a stranger either. Both halves
      # matter: answering identically while sending mail would leak through the inbox instead.
      assert_no_emails do
        post user_password_path, params: { user: { email: "nobody@example.com" } }
      end
    end

    test "login with an unknown email answers exactly like a wrong password" do
      post user_session_path, params: { user: { email: "known@example.com", password: "wrong" } }
      known_status = response.status
      known_flash = flash[:alert].to_s

      post user_session_path, params: { user: { email: "nobody@example.com", password: "wrong" } }

      assert_equal known_status, response.status
      assert_equal known_flash, flash[:alert].to_s
    end
  end
end
