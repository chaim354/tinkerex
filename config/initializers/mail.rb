# MAIL BY ENVIRONMENT (B, 2026-10-13). production.rb shipped the scaffold's commented smtp_settings
# for a year, so no deployment could send a confirmation or a reset; with Devise :confirmable that
# meant nobody could finish signing up. SMTP_ADDRESS turns SMTP on (lib/tinkerex/mail_settings.rb
# lists the knobs). Production only: development and test keep their own delivery methods.
# after_initialize, like library_backend_check.rb: ActionMailer::Base is loaded by then, and the
# settings are class attributes read at delivery time.
Rails.application.config.after_initialize do
  next unless Rails.env.production?

  if (settings = Tinkerex::MailSettings.from_env)
    ActionMailer::Base.delivery_method = :smtp
    ActionMailer::Base.smtp_settings = settings
  else
    Rails.logger.warn("SMTP_ADDRESS is not set: confirmation and password-reset mail cannot be sent. " \
                      "The first account (the owner) needs no mail; set SMTP_ADDRESS before opening " \
                      "sign-ups or inviting a second account. bin/rails tinkerex:owner and " \
                      "tinkerex:password are the console doors meanwhile.")
  end
end
