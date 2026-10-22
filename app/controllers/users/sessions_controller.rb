# Devise session controller. Default behavior (authenticate email+password, reject unconfirmed
# via :confirmable); no account locks (config/initializers/devise.rb). Subclassed for the throttles.
module Users
  class SessionsController < Devise::SessionsController
    # THE TWO THROTTLES THAT REPLACED DEVISE :lockable's LOCK (pentest M4b; Tinkerex::SignInThrottle
    # has the argument and the numbers, shared with V1::DevicesController#login). Per SOURCE, they
    # stop one guess each at ten thousand addresses. Per ACCOUNT PER SOURCE, they stop ten an hour
    # at one address. Neither can keep the owner out from anywhere else, which the lock could, from
    # one IP. Both count in config.action_controller.cache_store (Solid Cache in production).
    #
    # They gate the ACTION, not just failures: an attacker who guesses correctly on attempt 11 must
    # not be let through. Pinned by test/integration/web/auth_throttle_test.rb.
    TOO_MANY = -> {
      redirect_to new_user_session_path, alert: "Too many sign-in attempts. Try again later."
    }
    rate_limit(**Tinkerex::SignInThrottle::PER_SOURCE, only: :create, name: "per-source",
               by: -> { Tinkerex::SignInThrottle.source(request.remote_ip) }, with: TOO_MANY)
    rate_limit(**Tinkerex::SignInThrottle::PER_ACCOUNT, only: :create, name: "per-account",
               by: -> { Tinkerex::SignInThrottle.account_key(attempted_email, request.remote_ip) },
               with: TOO_MANY)

    private

    # `user[email]`, or nil when `user` is not a hash at all. A hand-made POST can send `user=x`, and
    # `params.dig` would raise on the String inside this before_action, a 500 where Devise answers
    # a malformed sign-in with its own refusal.
    def attempted_email
      user = params[:user]
      user[:email] if user.respond_to?(:key?)
    end
  end
end
