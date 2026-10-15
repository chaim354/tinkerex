module Tinkerex
  # Mail is configured by ENVIRONMENT, never by editing production.rb (which shipped the scaffold's
  # commented smtp_settings for a year, so no deployment could send a confirmation). SMTP_ADDRESS
  # turns SMTP on; everything else has the common default. Pure: the initializer applies it.
  module MailSettings
    Error = Class.new(StandardError)

    def self.configured?(env = ENV) = env["SMTP_ADDRESS"].to_s.strip.present?

    # Whether a message sent from this environment reaches anyone. Production needs SMTP; the
    # other environments deliver to the log or the test mailbox, so a "this server can't send
    # email" note there would be wrong — and it is the note that keys on this, not delivery.
    def self.deliverable?(env = ENV, production: Rails.env.production?) = !production || configured?(env)

    # SMTP WITHOUT A HOST NAME IS REFUSED AT BOOT (I, 2026-10-14). APP_HOST feeds the links in every
    # message, the HELO domain and the default sender, and nothing else in the app -- so it is
    # required exactly when mail is, and an install that never sets SMTP_ADDRESS never sets it. The
    # same shape as library_backend_check.rb: a confirmation link to APP_HOST-IS-NOT-SET.invalid in
    # the one email a new account must click is worse than a boot that stops and says so.
    def self.validate!(env = ENV)
      return nil unless configured?(env)
      return nil if env["APP_HOST"].to_s.strip.present?

      raise Error, "SMTP_ADDRESS is set but APP_HOST is not: the links in confirmation and " \
                   "password-reset mail need the host name people reach this server at " \
                   "(maker.example.net or 192.168.1.20, no scheme). Set APP_HOST, or unset " \
                   "SMTP_ADDRESS to run without mail."
    end

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
