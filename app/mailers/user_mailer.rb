# Transactional auth emails (email confirmation + password reset). Action Mailer is the
# one new operational dependency for the auth baseline (SMTP creds in production) — see
# docs/parity-roadmap.md §A. Links carry a single-use, expiring raw token; only its digest
# is stored server-side.
class UserMailer < ApplicationMailer
  def confirmation(user, token)
    @user = user
    @url = confirm_email_url(token: token)
    mail(to: user.email, subject: "Confirm your Tinkerex email")
  end

  def password_reset(user, token)
    @user = user
    @url = edit_password_url(token: token)
    mail(to: user.email, subject: "Reset your Tinkerex password")
  end
end
