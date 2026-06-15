# Sign-up (create a human account with email + password). Sends a confirmation email; the
# account cannot sign in until confirmed (§12 step 5). This is purely the human-identity
# layer — it does NOT mint a device token. The first device's token is still issued by the
# unchanged v1 bootstrap (register / pairing); a signed-in web user already has a per-user
# `web_device` via WebAuthentication (parity-roadmap §A "two layers").
class RegistrationsController < ApplicationController
  include WebAuthentication

  def new
    redirect_to files_path and return if logged_in?
    @user = User.new
  end

  def create
    @user = User.new(email: params[:email], password: params[:password],
                     password_confirmation: params[:password_confirmation])
    if @user.password.blank?
      @user.errors.add(:password, "can't be blank")
      return render :new, status: :unprocessable_entity
    end

    if @user.save
      send_confirmation(@user)
      redirect_to login_path,
                  notice: "Account created. Check your email for a confirmation link."
    else
      render :new, status: :unprocessable_entity
    end
  end

  private

  def send_confirmation(user)
    token = user.generate_confirmation_token!
    UserMailer.confirmation(user, token).deliver_later
  end
end
