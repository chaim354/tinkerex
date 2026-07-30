# Devise registration (sign-up). :registerable + :confirmable means a new account is created
# unconfirmed and a confirmation email is sent; it cannot sign in until confirmed.
module Users
  class RegistrationsController < Devise::RegistrationsController
    # Bounds automated signup floods (each one also sends a confirmation email). Deliberately
    # looser than the sign-in limit: a household or an office behind one NAT address may
    # legitimately create several accounts in a sitting.
    rate_limit to: 5, within: 15.minutes, only: :create,
               with: -> {
                 redirect_to new_user_registration_path,
                             alert: "Too many sign-up attempts. Try again later."
               }

    # A human web sign-up MUST supply a password. The model's `password_required?` returns
    # false whenever no password is set (so the OmniAuth seam + the device-token bootstrap can
    # create passwordless accounts), which means a blank-password web form would otherwise
    # persist an inert, can't-authenticate row. Reject that at the web boundary instead of
    # broadly flipping `password_required?` — which would break every programmatic passwordless
    # `User.create!` (from_omniauth, the v1 bootstrap, identity-backed accounts) and the suite.
    def create
      if params.dig(:user, :password).blank?
        build_resource(sign_up_params)
        resource.errors.add(:password, :blank)
        clean_up_passwords(resource)
        set_minimum_password_length
        respond_with_navigational(resource) { render :new, status: :unprocessable_entity }
        return
      end

      super
    end
  end
end
