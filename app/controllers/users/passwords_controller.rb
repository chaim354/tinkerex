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

    # THE SHARED DEMO ACCOUNT'S PASSWORD IS NOBODY'S TO RESET, AND ASKING MUST NOT SAY SO
    # (Tinkerex::Demo). A reset would mail a link to an inbox no visitor reads, for a password nobody
    # signs in with -- and the address must answer like any other, or this form becomes the one place
    # that tells which address is the demo. So the demo address takes the path of an address with NO
    # account: the unsaved record with `:not_found` on its email that Devise's own lookup builds for
    # a miss, through Devise's own two branches below. Paranoid mode (config/initializers/devise.rb)
    # answers that exactly as it answers every address; nothing is sent and no token is minted.
    # Every other address reaches Devise unchanged. Guard: demo_guards_test.rb.
    def create
      return super unless Tinkerex::Demo.demo_email?(resource_params[:email])

      self.resource = resource_class.new(email: resource_params[:email])
      resource.errors.add(:email, :not_found)
      if successfully_sent?(resource)
        respond_with({}, location: after_sending_reset_password_instructions_path_for(resource_name))
      else
        respond_with(resource)
      end
    end
  end
end
