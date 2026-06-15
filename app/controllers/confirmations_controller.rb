# Email confirmation (proves email ownership — §12 step 5). `show` redeems the single-use
# token from the mailer link; `create` re-sends a confirmation email. No enumeration: the
# resend path always reports the same generic message.
class ConfirmationsController < ApplicationController
  include WebAuthentication

  # GET /confirm?token=... — redeem the confirmation link.
  def show
    user = User.find_by_confirmation_token(params[:token])
    if user
      user.confirm!
      redirect_to login_path, notice: "Email confirmed. You can now sign in."
    else
      redirect_to login_path, alert: "That confirmation link is invalid or has expired."
    end
  end

  # GET /confirmations/new — resend form.
  def new; end

  # POST /confirmations — resend a confirmation email (only for an existing, unconfirmed
  # account). Generic response regardless, to avoid leaking which emails are registered.
  def create
    user = User.find_by(email: params[:email].to_s.strip.downcase)
    if user && !user.confirmed?
      token = user.generate_confirmation_token!
      UserMailer.confirmation(user, token).deliver_later
    end
    redirect_to login_path,
                notice: "If that email needs confirming, we've sent a new link."
  end
end
