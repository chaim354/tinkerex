module Tinkerex
  # Mail is configured by ENVIRONMENT, never by editing production.rb (which shipped the scaffold's
  # commented smtp_settings for a year, so no deployment could send a confirmation). SMTP_ADDRESS
  # turns SMTP on; everything else has the common default. Pure: the initializer applies it.
  module MailSettings
    def self.configured?(env = ENV) = env["SMTP_ADDRESS"].to_s.strip.present?

    # The Hash ActionMailer::Base.smtp_settings takes, or nil when mail is not configured.
    def self.from_env(env = ENV)
      return nil unless configured?(env)

      settings = {
        address: env["SMTP_ADDRESS"].strip,
        port: Integer(env["SMTP_PORT"].presence || 587),
        domain: (env["SMTP_DOMAIN"].presence || env["APP_HOST"].presence)
      }.compact
      if env["SMTP_USER_NAME"].present?
        settings[:user_name] = env["SMTP_USER_NAME"]
        settings[:password] = env["SMTP_PASSWORD"].to_s
        settings[:authentication] = (env["SMTP_AUTHENTICATION"].presence || "plain").to_sym
      end
      settings[:enable_starttls_auto] = env["SMTP_STARTTLS"].to_s.strip.downcase != "false"
      settings
    end

    # The From address: MAIL_FROM, else no-reply at the mail-link host, else the historical literal
    # (kept so a deployment that sets neither still sends from a syntactically valid address).
    def self.sender(env = ENV)
      env["MAIL_FROM"].presence || (env["APP_HOST"].present? ? "no-reply@#{env['APP_HOST']}" : "no-reply@tinkerex.app")
    end
  end
end
