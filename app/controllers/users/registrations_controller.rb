# Devise registration (sign-up). :registerable + :confirmable means a new account is created
# unconfirmed and a confirmation email is sent; it cannot sign in until confirmed.
module Users
  class RegistrationsController < Devise::RegistrationsController
  end
end
