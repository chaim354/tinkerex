module Users
  class ConfirmationsController < Devise::ConfirmationsController
    # Same reasoning as password reset: one POST, one email. Only #create is limited — #show
    # redeems a token from a link the user was mailed and must stay freely reachable.
    rate_limit to: 5, within: 15.minutes, only: :create,
               with: -> {
                 redirect_to new_user_confirmation_path,
                             alert: "Too many confirmation requests. Try again later."
               }
  end
end
