module Users
  class PasswordsController < Devise::PasswordsController
    # Each POST sends a real email, so an unthrottled endpoint is a mail cannon aimed at
    # whichever address the attacker names — and a fast way to get our sending domain listed as
    # a spam source. Devise :lockable does nothing here: no password is being guessed.
    rate_limit to: 5, within: 15.minutes, only: :create,
               with: -> {
                 redirect_to new_user_password_path,
                             alert: "Too many reset requests. Try again later."
               }
  end
end
