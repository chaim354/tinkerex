# PLACEHOLDER dev login — see WebAuthentication. Signs in as an existing User by email
# (creating one on first use for convenience), with NO password. Replace with real auth.
class WebSessionsController < ApplicationController
  include WebAuthentication

  def new
    redirect_to files_path and return if logged_in?
  end

  def create
    email = params[:email].to_s.strip.downcase
    if email.blank?
      redirect_to login_path, alert: "Enter an email." and return
    end
    user = User.find_or_create_by!(email:)
    log_in(user)
    redirect_to files_path, notice: "Signed in as #{user.email} (placeholder auth)."
  end

  def destroy
    log_out
    redirect_to login_path, notice: "Signed out."
  end
end
