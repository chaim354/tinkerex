# Devise session controller. Default behavior (authenticate email+password, reject
# unconfirmed via :confirmable, reject locked via :lockable). Subclassed so we can keep our
# routing namespace and add hooks later.
module Users
  class SessionsController < Devise::SessionsController
    # Per-IP, ON TOP OF Devise :lockable, which is per-ACCOUNT. Lockable stops 10 guesses at one
    # address; this stops one guess each at ten thousand addresses, and it stops an attacker from
    # locking a known account over and over — lockable's own flip side. Counts in
    # config.action_controller.cache_store (Solid Cache in production).
    #
    # It gates the ACTION, not just failures: an attacker who guesses correctly on attempt 11
    # must not be let through. Pinned by test/integration/web/auth_throttle_test.rb.
    rate_limit to: 10, within: 3.minutes, only: :create,
               with: -> {
                 redirect_to new_user_session_path,
                             alert: "Too many sign-in attempts. Try again in a few minutes."
               }
  end
end
