# Password reset (Rails 8 generator pattern). `new`/`create` request a reset email;
# `edit`/`update` redeem the single-use, expiring token and set a new password. No
# enumeration: requesting a reset always reports the same generic message.
class PasswordsController < ApplicationController
  include WebAuthentication

  # GET /password/new — request-a-reset form.
  def new; end

  # POST /password — email a reset link (if the account exists).
  def create
    user = User.find_by(email: params[:email].to_s.strip.downcase)
    if user
      token = user.generate_reset_token!
      UserMailer.password_reset(user, token).deliver_later
    end
    redirect_to login_path,
                notice: "If that email is registered, we've sent reset instructions."
  end

  # GET /password/edit?token=... — set-a-new-password form.
  def edit
    @user = User.find_by_reset_token(params[:token])
    redirect_to new_password_path, alert: "That reset link is invalid or has expired." unless @user
  end

  # PATCH /password?token=... — apply the new password.
  def update
    @user = User.find_by_reset_token(params[:token])
    return redirect_to new_password_path, alert: "That reset link is invalid or has expired." unless @user

    if @user.update(password: params[:password], password_confirmation: params[:password_confirmation])
      @user.clear_reset_token!
      # A reset proves email control, so confirm the account if it wasn't already.
      @user.confirm! unless @user.confirmed?
      # Invalidate any existing sessions after a password change (defense in depth).
      @user.sessions.destroy_all
      redirect_to login_path, notice: "Password updated. You can now sign in."
    else
      render :edit, status: :unprocessable_entity
    end
  end
end
