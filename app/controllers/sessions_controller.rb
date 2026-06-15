# Real password login (replaces the placeholder WebSessionsController). Authenticates by
# email + password (has_secure_password) and refuses unconfirmed accounts (email-ownership
# gate — §12 step 5). On success, starts a server-side Session via WebAuthentication#log_in.
class SessionsController < ApplicationController
  include WebAuthentication

  def new
    redirect_to files_path and return if logged_in?
  end

  def create
    user = User.find_by(email: params[:email].to_s.strip.downcase)
    if user&.authenticate(params[:password])
      unless user.confirmed?
        redirect_to login_path, alert: "Please confirm your email before signing in. " \
                                        "Check your inbox for the confirmation link." and return
      end
      log_in(user)
      redirect_to files_path, notice: "Signed in."
    else
      # One generic error for unknown email OR bad password (no account enumeration).
      redirect_to login_path, alert: "Invalid email or password."
    end
  end

  def destroy
    log_out
    redirect_to login_path, notice: "Signed out."
  end
end
